-- GMS | 0004 | Operations: cycles, provisional pricing, schedules, tasks, meters, devices, subscriptions.

CREATE FUNCTION gms.create_cycle(p_label text, p_starts date, p_ends date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_id uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF nullif(trim(p_label), '') IS NULL OR p_starts IS NULL OR p_ends IS NULL OR p_ends < p_starts THEN
  PERFORM gms.fail('GM422', 'invalid_cycle', 'يلزم اسم الدورة وتاريخ بداية ونهاية صحيحان');
 END IF;
 BEGIN
  INSERT INTO gms.reading_cycles(label, starts_on, ends_on, state, opened_by)
  VALUES (trim(p_label), p_starts, p_ends, 'draft', v_actor) RETURNING id INTO v_id;
 EXCEPTION
  WHEN exclusion_violation THEN PERFORM gms.fail('GM409', 'cycle_overlap', 'فترة الدورة تتداخل مع دورة أخرى');
  WHEN unique_violation THEN PERFORM gms.fail('GM409', 'cycle_label_exists', 'اسم الدورة مستخدم مسبقًا');
 END;
 RETURN v_id;
END $$;

CREATE FUNCTION gms.update_cycle(p_cycle uuid, p_label text, p_starts date, p_ends date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
BEGIN
 PERFORM gms.require_role('manager');
 IF nullif(trim(p_label), '') IS NULL OR p_starts IS NULL OR p_ends IS NULL OR p_ends < p_starts THEN
  PERFORM gms.fail('GM422', 'invalid_cycle', 'يلزم اسم الدورة وتاريخ بداية ونهاية صحيحان');
 END IF;
 BEGIN
  UPDATE gms.reading_cycles SET label = trim(p_label), starts_on = p_starts, ends_on = p_ends WHERE id = p_cycle;
  IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 EXCEPTION
  WHEN exclusion_violation THEN PERFORM gms.fail('GM409', 'cycle_overlap', 'فترة الدورة تتداخل مع دورة أخرى');
  WHEN unique_violation THEN PERFORM gms.fail('GM409', 'cycle_label_exists', 'اسم الدورة مستخدم مسبقًا');
 END;
END $$;

CREATE FUNCTION gms.open_cycle(p_cycle uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE c gms.reading_cycles;
BEGIN
 PERFORM gms.require_role('manager');
 PERFORM pg_advisory_xact_lock(6202201);
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 IF c.state <> 'draft' THEN PERFORM gms.fail('GM409', 'cycle_not_draft', 'الدورة ليست مسودة'); END IF;
 IF EXISTS (SELECT 1 FROM gms.reading_cycles WHERE state = 'open') THEN
  PERFORM gms.fail('GM409', 'another_cycle_open', 'توجد دورة مفتوحة أخرى؛ أغلقها أولًا');
 END IF;
 UPDATE gms.reading_cycles SET state = 'open' WHERE id = p_cycle;
END $$;

-- BR-18: provisional (display-only) rate; may change daily; history kept; never posts money.
CREATE FUNCTION gms.set_provisional_rate(p_cycle uuid, p_effective_on date, p_rate numeric, p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_id uuid; c gms.reading_cycles;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_rate IS NULL OR p_rate < 0 OR scale(p_rate) > 6 OR p_rate >= 10000000000 OR p_effective_on IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_rate', 'السعر يجب أن يكون غير سالب وبست منازل عشرية كحد أقصى مع تاريخ السريان');
 END IF;
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle FOR SHARE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 IF c.state = 'closed' THEN PERFORM gms.fail('GM409', 'cycle_closed', 'لا يمكن تسعير دورة مغلقة'); END IF;
 INSERT INTO gms.tariff_change_events(cycle_id, effective_on, proposed_rate_ils_per_kwh, recorded_by, reason)
 VALUES (p_cycle, p_effective_on, p_rate, v_actor, nullif(trim(p_reason), '')) RETURNING id INTO v_id;
 INSERT INTO gms.cycle_price_decisions(cycle_id, provisional_rate_ils_per_kwh) VALUES (p_cycle, p_rate)
 ON CONFLICT (cycle_id) DO UPDATE SET provisional_rate_ils_per_kwh = EXCLUDED.provisional_rate_ils_per_kwh;
 RETURN v_id;
END $$;

-- BR-04: next due = manager override, else last approved reading date + interval,
-- else (no reading yet) opening baseline date + interval.
CREATE FUNCTION gms.next_due_date(p_subscriber uuid) RETURNS date
LANGUAGE sql STABLE SET search_path = gms, pg_temp AS $$
 SELECT COALESCE(sc.next_due_override,
   (SELECT gms.local_date(a.verified_captured_at) FROM gms.approved_readings a
     WHERE a.installation_id = i.id AND a.state = 'active' ORDER BY a.verified_captured_at DESC LIMIT 1) + sc.interval_days,
   gms.local_date(GREATEST(i.installed_at, b.entered_at)) + sc.interval_days)
 FROM gms.subscribers s
 JOIN gms.subscriber_schedules sc ON sc.subscriber_id = s.id
 JOIN gms.meter_installations i ON i.subscriber_id = s.id AND i.removed_at IS NULL
 JOIN gms.opening_baselines b ON b.installation_id = i.id
 WHERE s.id = p_subscriber;
$$;

-- Internal: the single employee holding an open grant on a zone (else NULL -> manager assigns).
CREATE FUNCTION gms._default_employee(p_zone uuid) RETURNS uuid
LANGUAGE sql STABLE SET search_path = gms, pg_temp AS $$
 SELECT CASE WHEN count(*) = 1 THEN (array_agg(g.employee_id))[1] END
 FROM gms.user_zone_grants g JOIN gms.app_users u ON u.id = g.employee_id AND u.is_active AND u.role = 'employee'
 WHERE g.zone_id = p_zone AND g.valid_from <= now() AND (g.valid_until IS NULL OR g.valid_until > now());
$$;

CREATE FUNCTION gms._check_employee(p_employee uuid) RETURNS void
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF p_employee IS NOT NULL AND NOT EXISTS (SELECT 1 FROM gms.app_users WHERE id = p_employee AND role = 'employee' AND is_active) THEN
  PERFORM gms.fail('GM422', 'invalid_employee', 'الموظف غير موجود أو غير فعال');
 END IF;
END $$;

CREATE FUNCTION gms.create_task(p_cycle uuid, p_subscriber uuid, p_planned_for date, p_source text,
 p_employee uuid DEFAULT NULL, p_parent uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; c gms.reading_cycles; s gms.subscribers; v_inst uuid; v_id uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_source IS NULL OR p_source NOT IN ('manager_extra','revisit','unreadable_followup','closing','scheduled') OR p_planned_for IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_task', 'بيانات المهمة غير صالحة');
 END IF;
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle FOR SHARE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 IF c.state = 'closed' THEN PERFORM gms.fail('GM409', 'cycle_closed', 'لا يمكن إضافة مهمة إلى دورة مغلقة'); END IF;
 IF p_planned_for NOT BETWEEN c.starts_on AND c.ends_on THEN
  PERFORM gms.fail('GM422', 'planned_out_of_cycle', 'تاريخ المهمة خارج حدود الدورة');
 END IF;
 SELECT * INTO s FROM gms.subscribers WHERE id = p_subscriber;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'subscriber_not_found', 'المشترك غير موجود'); END IF;
 IF NOT s.is_active AND p_source <> 'closing' THEN PERFORM gms.fail('GM409', 'subscriber_inactive', 'الاشتراك موقوف'); END IF;
 SELECT i.id INTO v_inst FROM gms.meter_installations i JOIN gms.opening_baselines b ON b.installation_id = i.id
  WHERE i.subscriber_id = p_subscriber AND i.removed_at IS NULL;
 IF v_inst IS NULL THEN PERFORM gms.fail('GM409', 'no_meter', 'لا يوجد عداد مركب بقراءة افتتاحية لهذا المشترك'); END IF;
 PERFORM gms._check_employee(p_employee);
 INSERT INTO gms.reading_tasks(cycle_id, subscriber_id, installation_id, zone_id, assigned_employee_id, planned_for,
  source, parent_task_id, created_by)
 VALUES (p_cycle, p_subscriber, v_inst, s.zone_id, COALESCE(p_employee, gms._default_employee(s.zone_id)), p_planned_for,
  p_source, p_parent, v_actor)
 RETURNING id INTO v_id;
 RETURN v_id;
END $$;

-- BR-05: automatic tasks for subscribers whose next due date falls on/before the cycle end and
-- who have no unresolved task anywhere. Idempotent: re-running creates nothing new.
CREATE FUNCTION gms.generate_due_tasks(p_cycle uuid)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; c gms.reading_cycles; r record; n integer := 0; v_planned date; v_d date;
BEGIN
 v_actor := gms.require_role('manager');
 PERFORM pg_advisory_xact_lock(6202202);
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle FOR SHARE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 IF c.state = 'closed' THEN PERFORM gms.fail('GM409', 'cycle_closed', 'الدورة مغلقة'); END IF;
 FOR r IN
  SELECT s.id AS subscriber_id, s.zone_id, i.id AS installation_id, z.reading_weekday, gms.next_due_date(s.id) AS due
  FROM gms.subscribers s
  JOIN gms.zones z ON z.id = s.zone_id
  JOIN gms.meter_installations i ON i.subscriber_id = s.id AND i.removed_at IS NULL
  JOIN gms.opening_baselines b ON b.installation_id = i.id
  JOIN gms.subscriber_schedules sc ON sc.subscriber_id = s.id
  WHERE s.is_active
    AND NOT EXISTS (SELECT 1 FROM gms.reading_tasks t WHERE t.subscriber_id = s.id
         AND t.status IN ('assigned','in_progress','pending_review'))
  ORDER BY s.subscription_no
 LOOP
  CONTINUE WHEN r.due IS NULL OR r.due > c.ends_on;
  v_planned := GREATEST(r.due, c.starts_on);
  IF r.reading_weekday IS NOT NULL THEN
   -- first day on/after the due date, inside the cycle, matching the zone weekday; else keep the due date
   SELECT min(d::date) INTO v_d FROM generate_series(v_planned, c.ends_on, interval '1 day') d
    WHERE extract(dow FROM d)::int = r.reading_weekday;
   v_planned := COALESCE(v_d, v_planned);
  END IF;
  INSERT INTO gms.reading_tasks(cycle_id, subscriber_id, installation_id, zone_id, assigned_employee_id, planned_for, source, created_by)
  VALUES (p_cycle, r.subscriber_id, r.installation_id, r.zone_id, gms._default_employee(r.zone_id), v_planned, 'scheduled', v_actor);
  n := n + 1;
 END LOOP;
 RETURN n;
END $$;

CREATE FUNCTION gms.assign_task(p_task uuid, p_employee uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE t gms.reading_tasks;
BEGIN
 PERFORM gms.require_role('manager');
 SELECT * INTO t FROM gms.reading_tasks WHERE id = p_task FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'task_not_found', 'المهمة غير موجودة'); END IF;
 IF t.status NOT IN ('assigned','in_progress') THEN
  PERFORM gms.fail('GM409', 'task_not_assignable', 'لا يمكن تغيير تكليف مهمة في هذه الحالة');
 END IF;
 PERFORM gms._check_employee(p_employee);
 UPDATE gms.reading_tasks SET assigned_employee_id = p_employee, status = 'assigned', updated_at = now() WHERE id = p_task;
END $$;

CREATE FUNCTION gms.cancel_task(p_task uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE t gms.reading_tasks;
BEGIN
 PERFORM gms.require_role('manager');
 IF nullif(trim(p_reason), '') IS NULL THEN PERFORM gms.fail('GM422', 'reason_required', 'سبب الإلغاء إلزامي'); END IF;
 SELECT * INTO t FROM gms.reading_tasks WHERE id = p_task FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'task_not_found', 'المهمة غير موجودة'); END IF;
 IF t.status NOT IN ('assigned','in_progress') THEN
  PERFORM gms.fail('GM409', 'task_not_cancellable', 'لا يمكن إلغاء مهمة محسومة أو بانتظار المراجعة');
 END IF;
 IF EXISTS (SELECT 1 FROM gms.field_visits v WHERE v.task_id = p_task AND v.record_status IN ('awaiting_photo','pending_review','exception')) THEN
  PERFORM gms.fail('GM409', 'task_has_pending_visits', 'للمهمة زيارات بانتظار المراجعة؛ احسمها أولًا');
 END IF;
 UPDATE gms.reading_tasks SET status = 'cancelled', cancelled_at = now(), cancel_reason = trim(p_reason), updated_at = now() WHERE id = p_task;
END $$;

-- BR-16: an unfinished task carried to another (later, not closed) cycle keeps its history.
CREATE FUNCTION gms.move_task(p_task uuid, p_cycle uuid, p_planned_for date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE t gms.reading_tasks; c gms.reading_cycles;
BEGIN
 PERFORM gms.require_role('manager');
 SELECT * INTO t FROM gms.reading_tasks WHERE id = p_task FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'task_not_found', 'المهمة غير موجودة'); END IF;
 IF t.status NOT IN ('assigned','in_progress','pending_review') THEN
  PERFORM gms.fail('GM409', 'task_not_movable', 'لا يمكن ترحيل مهمة محسومة');
 END IF;
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle FOR SHARE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 IF c.state = 'closed' THEN PERFORM gms.fail('GM409', 'cycle_closed', 'لا يمكن الترحيل إلى دورة مغلقة'); END IF;
 IF p_planned_for IS NULL OR p_planned_for NOT BETWEEN c.starts_on AND c.ends_on THEN
  PERFORM gms.fail('GM422', 'planned_out_of_cycle', 'تاريخ المهمة خارج حدود الدورة');
 END IF;
 UPDATE gms.reading_tasks SET cycle_id = p_cycle, planned_for = p_planned_for, updated_at = now() WHERE id = p_task;
END $$;

-- Employee marks a task started (optional, informative).
CREATE FUNCTION gms.start_task(p_task uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
 v_actor := gms.require_role('employee');
 UPDATE gms.reading_tasks SET status = 'in_progress', updated_at = now()
  WHERE id = p_task AND assigned_employee_id = v_actor AND status = 'assigned';
END $$;

-- FR-04/05: first meter of a subscriber with the manager-entered opening reading (never billed).
CREATE FUNCTION gms.install_meter(p_subscriber uuid, p_serial text, p_type text, p_installed_at timestamptz,
 p_opening numeric, p_note text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_meter uuid; v_inst uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF nullif(trim(p_serial), '') IS NULL OR p_type IS NULL OR p_type NOT IN ('digital','mechanical') OR p_installed_at IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_meter', 'يلزم رقم العداد ونوعه وتاريخ التركيب');
 END IF;
 IF p_opening IS NULL OR p_opening < 0 OR scale(p_opening) > 2 THEN
  PERFORM gms.fail('GM422', 'invalid_precision', 'القراءة الافتتاحية يجب أن تكون غير سالبة وبمنزلتين عشريتين كحد أقصى (لا تقريب)');
 END IF;
 IF p_installed_at > now() + interval '1 day' THEN PERFORM gms.fail('GM422', 'future_date', 'تاريخ التركيب في المستقبل'); END IF;
 PERFORM 1 FROM gms.subscribers WHERE id = p_subscriber FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'subscriber_not_found', 'المشترك غير موجود'); END IF;
 IF EXISTS (SELECT 1 FROM gms.meter_installations WHERE subscriber_id = p_subscriber AND removed_at IS NULL) THEN
  PERFORM gms.fail('GM409', 'meter_already_installed', 'للمشترك عداد مركب حاليًا؛ استخدم إجراء الاستبدال');
 END IF;
 SELECT id INTO v_meter FROM gms.meters WHERE serial_no = trim(p_serial);
 IF v_meter IS NULL THEN
  INSERT INTO gms.meters(serial_no, meter_type) VALUES (trim(p_serial), p_type) RETURNING id INTO v_meter;
 ELSIF EXISTS (SELECT 1 FROM gms.meter_installations WHERE meter_id = v_meter AND removed_at IS NULL) THEN
  PERFORM gms.fail('GM409', 'meter_in_use', 'العداد مركب لدى مشترك آخر');
 END IF;
 INSERT INTO gms.meter_installations(subscriber_id, meter_id, kind, installed_at, installed_by)
 VALUES (p_subscriber, v_meter, 'initial', p_installed_at, v_actor) RETURNING id INTO v_inst;
 INSERT INTO gms.opening_baselines(installation_id, opening_value_kwh, entered_by, note)
 VALUES (v_inst, p_opening, v_actor, nullif(trim(p_note), ''));
 RETURN v_inst;
END $$;

-- FR-04 / AT-17: manager-only replacement or reset. Old installation is closed (never edited),
-- a new installation + opening baseline starts a new chain. Unresolved tasks follow the new meter.
CREATE FUNCTION gms.replace_meter(p_subscriber uuid, p_kind text, p_effective_at timestamptz, p_reason text,
 p_new_serial text, p_new_type text, p_new_opening numeric, p_incident_visit uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_old gms.meter_installations; v_meter uuid; v_inst uuid; v_last timestamptz;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_kind IS NULL OR p_kind NOT IN ('replacement','reset') OR p_effective_at IS NULL OR nullif(trim(p_reason), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_replacement', 'يلزم نوع الإجراء وتاريخه وسببه');
 END IF;
 IF p_new_opening IS NULL OR p_new_opening < 0 OR scale(p_new_opening) > 2 THEN
  PERFORM gms.fail('GM422', 'invalid_precision', 'القراءة الافتتاحية يجب أن تكون غير سالبة وبمنزلتين عشريتين كحد أقصى (لا تقريب)');
 END IF;
 IF p_effective_at > now() + interval '1 day' THEN PERFORM gms.fail('GM422', 'future_date', 'التاريخ في المستقبل'); END IF;
 PERFORM 1 FROM gms.subscribers WHERE id = p_subscriber FOR UPDATE;
 SELECT * INTO v_old FROM gms.meter_installations WHERE subscriber_id = p_subscriber AND removed_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM409', 'no_meter', 'لا يوجد عداد مركب حاليًا لهذا المشترك'); END IF;
 SELECT max(verified_captured_at) INTO v_last FROM gms.approved_readings WHERE installation_id = v_old.id AND state = 'active';
 IF p_effective_at <= v_old.installed_at OR (v_last IS NOT NULL AND p_effective_at <= v_last) THEN
  PERFORM gms.fail('GM409', 'effective_before_history', 'تاريخ الاستبدال يجب أن يلي تاريخ التركيب وآخر قراءة معتمدة');
 END IF;
 IF EXISTS (SELECT 1 FROM gms.field_visits v WHERE v.installation_id = v_old.id AND v.event_kind = 'reading'
     AND v.record_status IN ('awaiting_photo','pending_review','exception')) THEN
  PERFORM gms.fail('GM409', 'pending_visits_on_meter', 'توجد قراءات معلقة على العداد الحالي؛ احسمها قبل الاستبدال');
 END IF;
 UPDATE gms.meter_installations SET removed_at = p_effective_at, removed_by = v_actor, removal_reason = trim(p_reason) WHERE id = v_old.id;
 IF p_kind = 'reset' THEN
  v_meter := v_old.meter_id;
 ELSE
  IF nullif(trim(p_new_serial), '') IS NULL OR p_new_type IS NULL OR p_new_type NOT IN ('digital','mechanical') THEN
   PERFORM gms.fail('GM422', 'invalid_meter', 'يلزم رقم العداد الجديد ونوعه');
  END IF;
  SELECT id INTO v_meter FROM gms.meters WHERE serial_no = trim(p_new_serial);
  IF v_meter IS NULL THEN
   INSERT INTO gms.meters(serial_no, meter_type) VALUES (trim(p_new_serial), p_new_type) RETURNING id INTO v_meter;
  ELSIF v_meter = v_old.meter_id OR EXISTS (SELECT 1 FROM gms.meter_installations WHERE meter_id = v_meter AND removed_at IS NULL) THEN
   PERFORM gms.fail('GM409', 'meter_in_use', 'العداد الجديد مستخدم أو مطابق للقديم');
  END IF;
 END IF;
 INSERT INTO gms.meter_installations(subscriber_id, meter_id, kind, installed_at, installed_by)
 VALUES (p_subscriber, v_meter, p_kind, p_effective_at, v_actor) RETURNING id INTO v_inst;
 INSERT INTO gms.opening_baselines(installation_id, opening_value_kwh, entered_by, note)
 VALUES (v_inst, p_new_opening, v_actor, trim(p_reason));
 UPDATE gms.reading_tasks SET installation_id = v_inst, updated_at = now()
  WHERE subscriber_id = p_subscriber AND installation_id = v_old.id AND status IN ('assigned','in_progress');
 IF p_incident_visit IS NOT NULL THEN
  UPDATE gms.meter_incident_reports SET resolved_by = v_actor, resolved_at = now(),
    resolution_note = trim(p_reason), resulting_installation_id = v_inst
   WHERE visit_id = p_incident_visit AND resolved_at IS NULL;
  IF FOUND THEN
   INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, rationale) VALUES (p_incident_visit, v_actor, 'resolve_incident', trim(p_reason));
   UPDATE gms.field_visits SET record_status = 'incident_resolved' WHERE id = p_incident_visit AND record_status IN ('pending_review','exception');
   UPDATE gms.reading_tasks t SET status = 'completed_unreadable', updated_at = now()
    FROM gms.field_visits v WHERE v.id = p_incident_visit AND t.id = v.task_id AND t.status = 'pending_review';
  END IF;
 END IF;
 RETURN v_inst;
END $$;

-- BR-23: stop a subscription. History and receivables are kept; scheduling stops.
CREATE FUNCTION gms.stop_subscriber(p_subscriber uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
BEGIN
 PERFORM gms.require_role('manager');
 IF nullif(trim(p_reason), '') IS NULL THEN PERFORM gms.fail('GM422', 'reason_required', 'سبب الإيقاف إلزامي'); END IF;
 PERFORM 1 FROM gms.subscribers WHERE id = p_subscriber AND is_active FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM409', 'subscriber_not_active', 'المشترك غير موجود أو موقوف مسبقًا'); END IF;
 IF EXISTS (SELECT 1 FROM gms.field_visits v WHERE v.subscriber_id = p_subscriber
     AND v.record_status IN ('awaiting_photo','pending_review','exception')) THEN
  PERFORM gms.fail('GM409', 'pending_visits', 'توجد زيارات بانتظار المراجعة لهذا المشترك؛ احسمها قبل الإيقاف');
 END IF;
 UPDATE gms.reading_tasks SET status = 'cancelled', cancelled_at = now(), cancel_reason = 'إيقاف الاشتراك: ' || trim(p_reason), updated_at = now()
  WHERE subscriber_id = p_subscriber AND status IN ('assigned','in_progress');
 UPDATE gms.subscribers SET is_active = false, stopped_at = now(), stop_reason = trim(p_reason) WHERE id = p_subscriber;
END $$;

CREATE FUNCTION gms.reactivate_subscriber(p_subscriber uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
BEGIN
 PERFORM gms.require_role('manager');
 UPDATE gms.subscribers SET is_active = true, stopped_at = NULL, stop_reason = NULL WHERE id = p_subscriber AND NOT is_active;
 IF NOT FOUND THEN PERFORM gms.fail('GM409', 'subscriber_not_stopped', 'المشترك غير موجود أو غير موقوف'); END IF;
END $$;

-- BR-27: first online login on a phone consumes a manager-issued one-time code. The code is the
-- manager's authorisation, so a previously active phone of the same employee is revoked.
CREATE FUNCTION gms.enroll_device(p_code_sha text, p_install_id text, p_label text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_code gms.device_enrollment_codes; v_id uuid;
BEGIN
 v_actor := gms.require_role('employee');
 IF p_install_id IS NULL OR length(p_install_id) NOT BETWEEN 16 AND 128 OR nullif(trim(p_label), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_device', 'بيانات الجهاز غير صالحة');
 END IF;
 SELECT * INTO v_code FROM gms.device_enrollment_codes
  WHERE code_sha256 = p_code_sha AND employee_id = v_actor AND used_at IS NULL AND expires_at > now() FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM403', 'invalid_enrollment_code', 'رمز تفعيل الجهاز غير صالح أو منتهي'); END IF;
 UPDATE gms.mobile_devices SET is_active = false, revoked_at = now(), revoked_by = v_code.created_by, revoke_reason = 'استبدال بجهاز جديد'
  WHERE is_active AND (employee_id = v_actor OR install_id = p_install_id);
 UPDATE gms.auth_refresh_tokens SET revoked_at = now()
  WHERE user_id = v_actor AND client_kind = 'mobile' AND revoked_at IS NULL;
 INSERT INTO gms.mobile_devices(employee_id, install_id, device_label) VALUES (v_actor, p_install_id, trim(p_label)) RETURNING id INTO v_id;
 UPDATE gms.device_enrollment_codes SET used_at = now(), used_device_id = v_id WHERE id = v_code.id;
 RETURN v_id;
END $$;

CREATE FUNCTION gms.revoke_device(p_device uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF nullif(trim(p_reason), '') IS NULL THEN PERFORM gms.fail('GM422', 'reason_required', 'سبب إيقاف الجهاز إلزامي'); END IF;
 UPDATE gms.mobile_devices SET is_active = false, revoked_at = now(), revoked_by = v_actor, revoke_reason = trim(p_reason)
  WHERE id = p_device AND is_active;
 IF NOT FOUND THEN PERFORM gms.fail('GM409', 'device_not_active', 'الجهاز غير موجود أو موقوف مسبقًا'); END IF;
 UPDATE gms.auth_refresh_tokens SET revoked_at = now() WHERE device_id = p_device AND revoked_at IS NULL;
END $$;

CREATE FUNCTION gms.touch_device(p_device uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
 UPDATE gms.mobile_devices SET last_seen_at = now() WHERE id = p_device AND is_active
  AND employee_id = gms.actor_id() AND (last_seen_at IS NULL OR last_seen_at < now() - interval '1 minute');
$$;
