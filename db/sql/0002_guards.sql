-- GMS | 0002 | Helpers, authorization context, immutability and validation triggers.
-- Trust model: ONLY the API login (member of gms_api) reaches the DB. It authenticates the
-- human, then sets gms.actor_id with SET LOCAL semantics. Table privileges (0006) are the
-- primary barrier; these triggers are defence in depth and also bind the table owner.

CREATE FUNCTION gms.fail(p_state text, p_code text, p_msg text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION USING ERRCODE = p_state, MESSAGE = p_msg, DETAIL = p_code;
END $$;
-- SQLSTATE classes used: GM403 authorization, GM404 not found, GM409 state conflict, GM422 validation.

CREATE FUNCTION gms.setting(p_key text) RETURNS text
LANGUAGE sql STABLE SET search_path = gms, pg_temp AS $$
 SELECT value FROM gms.system_settings WHERE key = p_key;
$$;
CREATE FUNCTION gms.business_tz() RETURNS text
LANGUAGE sql STABLE SET search_path = gms, pg_temp AS $$
 SELECT COALESCE(gms.setting('business_timezone'), 'Asia/Gaza');
$$;
CREATE FUNCTION gms.local_date(p_ts timestamptz) RETURNS date
LANGUAGE sql STABLE SET search_path = gms, pg_temp AS $$
 SELECT timezone(gms.business_tz(), p_ts)::date;
$$;

CREATE FUNCTION gms.actor_id() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
 v := nullif(current_setting('gms.actor_id', true), '');
 IF v IS NULL THEN
  RAISE EXCEPTION USING ERRCODE = 'GM403', MESSAGE = 'لا يوجد سياق مستخدم موثّق', DETAIL = 'missing_actor';
 END IF;
 BEGIN
  RETURN v::uuid;
 EXCEPTION WHEN invalid_text_representation THEN
  RAISE EXCEPTION USING ERRCODE = 'GM403', MESSAGE = 'سياق مستخدم غير صالح', DETAIL = 'malformed_actor';
 END;
END $$;

CREATE FUNCTION gms.require_role(p_role text) RETURNS uuid
LANGUAGE plpgsql STABLE SET search_path = gms, pg_temp AS $$
DECLARE v uuid;
BEGIN
 v := gms.actor_id();
 IF NOT EXISTS (SELECT 1 FROM gms.app_users WHERE id = v AND role = p_role AND is_active) THEN
  RAISE EXCEPTION USING ERRCODE = 'GM403', MESSAGE = 'العملية غير مصرح بها لهذا الدور', DETAIL = 'role_required:' || p_role;
 END IF;
 RETURN v;
END $$;

CREATE FUNCTION gms.tg_manager_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 PERFORM gms.require_role('manager');
 IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

CREATE FUNCTION gms.tg_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION USING ERRCODE = 'GM409', DETAIL = 'append_only:' || TG_TABLE_NAME,
  MESSAGE = 'سجل تاريخي غير قابل للتعديل أو الحذف؛ استخدم مسار التصحيح أو القيد العكسي';
END $$;

CREATE FUNCTION gms.tg_no_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION USING ERRCODE = 'GM409', DETAIL = 'no_delete:' || TG_TABLE_NAME,
  MESSAGE = 'لا يُسمح بحذف هذا السجل؛ السجل التاريخي محفوظ';
END $$;

DO $$ DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['opening_baselines','tariff_change_events','payment_receipts','payment_reversals',
   'financial_adjustments','ledger_entries','audit_logs','final_reading_allocations','opening_receivables',
   'statement_reading_lines','statement_versions','visit_reviews','reading_corrections','sync_operations','sync_rejections'] LOOP
  EXECUTE format('CREATE TRIGGER trg_append_only BEFORE UPDATE OR DELETE ON gms.%I FOR EACH ROW EXECUTE FUNCTION gms.tg_append_only()', t);
 END LOOP;
 EXECUTE 'CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON gms.ledger_entries FOR EACH STATEMENT EXECUTE FUNCTION gms.tg_append_only()';
 EXECUTE 'CREATE TRIGGER trg_no_truncate BEFORE TRUNCATE ON gms.audit_logs FOR EACH STATEMENT EXECUTE FUNCTION gms.tg_append_only()';
 FOREACH t IN ARRAY ARRAY['app_users','mobile_devices','generators','zones','subscribers','user_zone_grants','meters',
   'meter_installations','reading_cycles','cycle_price_decisions','subscriber_schedules','reading_tasks','field_visits',
   'visit_photos','visit_error_reports','meter_incident_reports','approved_readings','billing_accounts','backup_job_log'] LOOP
  EXECUTE format('CREATE TRIGGER trg_no_delete BEFORE DELETE ON gms.%I FOR EACH ROW EXECUTE FUNCTION gms.tg_no_delete()', t);
 END LOOP;
 FOREACH t IN ARRAY ARRAY['reading_cycles','cycle_price_decisions','tariff_change_events','visit_reviews','approved_readings',
   'statement_versions','statement_reading_lines','final_reading_allocations','financial_adjustments','payment_receipts',
   'payment_reversals','ledger_entries','opening_receivables','opening_baselines','meter_installations','meters',
   'user_zone_grants','generators','zones','subscribers','subscriber_schedules','reading_corrections','system_settings',
   'import_batches'] LOOP
  EXECUTE format('CREATE TRIGGER trg_manager_guard BEFORE INSERT OR UPDATE OR DELETE ON gms.%I FOR EACH ROW EXECUTE FUNCTION gms.tg_manager_guard()', t);
 END LOOP;
END $$;
CREATE TRIGGER trg_manager_guard BEFORE INSERT ON gms.device_enrollment_codes
 FOR EACH ROW EXECUTE FUNCTION gms.tg_manager_guard();

-- Accounts: only a manager creates/disables/renames; anyone may change only their own password.
-- Bootstrap: the very first row may be a manager created without context (CLI, see docs).
CREATE FUNCTION gms.tg_app_users_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
 IF TG_OP = 'INSERT' THEN
  IF NEW.role = 'manager' AND NOT EXISTS (SELECT 1 FROM gms.app_users) THEN RETURN NEW; END IF;
  NEW.created_by := gms.require_role('manager');
  RETURN NEW;
 END IF;
 IF NEW.id <> OLD.id OR NEW.created_at <> OLD.created_at THEN
  PERFORM gms.fail('GM409', 'immutable_user_identity', 'لا يمكن تغيير هوية الحساب');
 END IF;
 IF (NEW.role, NEW.is_active, NEW.username, NEW.full_name) IS DISTINCT FROM (OLD.role, OLD.is_active, OLD.username, OLD.full_name) THEN
  PERFORM gms.require_role('manager');
 END IF;
 IF NEW.password_hash IS DISTINCT FROM OLD.password_hash OR NEW.must_change_password IS DISTINCT FROM OLD.must_change_password THEN
  v_actor := gms.actor_id();
  IF v_actor <> OLD.id THEN PERFORM gms.require_role('manager'); END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_app_users_guard BEFORE INSERT OR UPDATE ON gms.app_users
 FOR EACH ROW EXECUTE FUNCTION gms.tg_app_users_guard();

CREATE FUNCTION gms.tg_subscriber_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.generator_id <> OLD.generator_id THEN
  PERFORM gms.fail('GM409', 'generator_fixed', 'لكل مشترك مولد واحد ثابت؛ النقل بين المولدات خارج النطاق');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_subscriber_guard BEFORE UPDATE ON gms.subscribers
 FOR EACH ROW EXECUTE FUNCTION gms.tg_subscriber_guard();

CREATE FUNCTION gms.tg_installation_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.id, NEW.subscriber_id, NEW.meter_id, NEW.kind, NEW.installed_at, NEW.installed_by)
    IS DISTINCT FROM (OLD.id, OLD.subscriber_id, OLD.meter_id, OLD.kind, OLD.installed_at, OLD.installed_by)
    OR OLD.removed_at IS NOT NULL THEN
  PERFORM gms.fail('GM409', 'installation_immutable', 'بيانات تركيب العداد غير قابلة للتعديل؛ يُسمح بتسجيل الإزالة مرة واحدة فقط');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_installation_guard BEFORE UPDATE ON gms.meter_installations
 FOR EACH ROW EXECUTE FUNCTION gms.tg_installation_guard();

-- FIX-02: raw captured content never changes; only review-side columns may move.
CREATE FUNCTION gms.tg_visit_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF (to_jsonb(NEW) - 'record_status' - 'timestamp_status' - 'verified_captured_at')
    IS DISTINCT FROM (to_jsonb(OLD) - 'record_status' - 'timestamp_status' - 'verified_captured_at') THEN
  PERFORM gms.fail('GM409', 'visit_immutable', 'محتوى الزيارة الميدانية الخام غير قابل للتعديل');
 END IF;
 IF OLD.record_status = 'approved' AND NEW.verified_captured_at IS DISTINCT FROM OLD.verified_captured_at THEN
  PERFORM gms.fail('GM409', 'visit_time_locked', 'لا يمكن تغيير وقت زيارة معتمدة');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_visit_guard BEFORE UPDATE ON gms.field_visits
 FOR EACH ROW EXECUTE FUNCTION gms.tg_visit_guard();

CREATE FUNCTION gms.tg_photo_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.id, NEW.visit_id, NEW.object_key, NEW.sha256_hex, NEW.size_bytes, NEW.content_type, NEW.is_primary, NEW.created_at)
    IS DISTINCT FROM (OLD.id, OLD.visit_id, OLD.object_key, OLD.sha256_hex, OLD.size_bytes, OLD.content_type, OLD.is_primary, OLD.created_at) THEN
  PERFORM gms.fail('GM409', 'photo_immutable', 'بيانات الصورة غير قابلة للتعديل');
 END IF;
 IF NOT ((OLD.state = 'uploading' AND NEW.state IN ('uploading','ready','failed'))
      OR (OLD.state = 'failed' AND NEW.state IN ('failed','uploading'))) THEN
  PERFORM gms.fail('GM409', 'photo_state', 'انتقال حالة صورة غير صالح');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_photo_guard BEFORE UPDATE ON gms.visit_photos
 FOR EACH ROW EXECUTE FUNCTION gms.tg_photo_guard();

CREATE FUNCTION gms.tg_error_report_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.id, NEW.visit_id, NEW.employee_id, NEW.explanation, NEW.submitted_at)
    IS DISTINCT FROM (OLD.id, OLD.visit_id, OLD.employee_id, OLD.explanation, OLD.submitted_at)
    OR OLD.acknowledged_at IS NOT NULL THEN
  PERFORM gms.fail('GM409', 'report_immutable', 'البلاغ غير قابل للتعديل');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_error_report_guard BEFORE UPDATE ON gms.visit_error_reports
 FOR EACH ROW EXECUTE FUNCTION gms.tg_error_report_guard();

CREATE FUNCTION gms.tg_incident_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.id, NEW.visit_id, NEW.category, NEW.notes) IS DISTINCT FROM (OLD.id, OLD.visit_id, OLD.category, OLD.notes)
    OR OLD.resolved_at IS NOT NULL THEN
  PERFORM gms.fail('GM409', 'incident_immutable', 'بلاغ العداد غير قابل للتعديل');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_incident_guard BEFORE UPDATE ON gms.meter_incident_reports
 FOR EACH ROW EXECUTE FUNCTION gms.tg_incident_guard();

-- Approved readings: values frozen; only active -> superseded/voided, tail first.
CREATE FUNCTION gms.tg_approved_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 -- consumption_kwh is GENERATED: not yet computed for NEW in a BEFORE trigger, so it is excluded here
 IF (to_jsonb(NEW) - 'state' - 'consumption_kwh') IS DISTINCT FROM (to_jsonb(OLD) - 'state' - 'consumption_kwh') THEN
  PERFORM gms.fail('GM409', 'approved_immutable', 'قيم القراءة المعتمدة غير قابلة للتعديل');
 END IF;
 IF OLD.state <> 'active' OR NEW.state NOT IN ('superseded','voided') THEN
  PERFORM gms.fail('GM409', 'approved_state', 'انتقال حالة قراءة معتمدة غير صالح');
 END IF;
 IF EXISTS (SELECT 1 FROM gms.approved_readings r WHERE r.previous_approved_id = OLD.id AND r.state = 'active') THEN
  PERFORM gms.fail('GM409', 'approved_has_successor', 'لا يمكن استبدال قراءة لها قراءة لاحقة فعالة دون إعادة بناء السلسلة');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_approved_guard BEFORE UPDATE ON gms.approved_readings
 FOR EACH ROW EXECUTE FUNCTION gms.tg_approved_guard();

-- Insert-time validation of the approved chain (independent of the calling function).
CREATE FUNCTION gms.tg_approved_validate() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
DECLARE v_visit gms.field_visits; v_review gms.visit_reviews; v_base gms.opening_baselines;
 v_prev gms.approved_readings; v_cycle gms.reading_cycles;
BEGIN
 SELECT * INTO v_visit FROM gms.field_visits WHERE id = NEW.visit_id;
 SELECT * INTO v_review FROM gms.visit_reviews WHERE id = NEW.review_id;
 IF v_review.id IS NULL OR v_review.visit_id IS DISTINCT FROM NEW.visit_id
    OR v_review.decision NOT IN ('approve_reading','correct_reading','accept_late','rechain') THEN
  PERFORM gms.fail('GM409', 'review_required', 'يلزم قرار مراجعة مطابق من المدير');
 END IF;
 IF v_visit.event_kind <> 'reading' OR v_visit.installation_id <> NEW.installation_id
    OR v_visit.subscriber_id <> NEW.subscriber_id THEN
  PERFORM gms.fail('GM409', 'visit_mismatch', 'القراءة المعتمدة لا تطابق الزيارة الميدانية');
 END IF;
 IF v_visit.timestamp_status NOT IN ('consistent','corrected') OR v_visit.verified_captured_at IS NULL THEN
  PERFORM gms.fail('GM409', 'timestamp_unverified', 'لا يمكن اعتماد قراءة بوقت التقاط غير موثّق');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.visit_photos ph WHERE ph.visit_id = v_visit.id AND ph.state = 'ready' AND ph.is_primary) THEN
  PERFORM gms.fail('GM409', 'photo_required', 'صورة أساسية جاهزة واحدة على الأقل إلزامية');
 END IF;
 IF NEW.current_value_kwh IS DISTINCT FROM COALESCE(v_review.corrected_value_kwh, v_visit.reading_value_kwh) THEN
  PERFORM gms.fail('GM409', 'value_mismatch', 'القيمة المعتمدة يجب أن تطابق القيمة المراجَعة');
 END IF;
 IF NEW.verified_captured_at IS DISTINCT FROM v_visit.verified_captured_at THEN
  PERFORM gms.fail('GM409', 'time_mismatch', 'وقت القراءة المعتمد لا يطابق الوقت الموثّق');
 END IF;
 SELECT * INTO v_cycle FROM gms.reading_cycles WHERE id = NEW.cycle_id;
 IF v_cycle.id IS NULL OR gms.local_date(NEW.verified_captured_at) NOT BETWEEN v_cycle.starts_on AND v_cycle.ends_on THEN
  PERFORM gms.fail('GM409', 'cycle_date_mismatch', 'القراءة يجب أن تتبع دورة تاريخ التقاطها الموثّق');
 END IF;
 IF NOT (v_cycle.state = 'open' OR (v_cycle.state = 'closed' AND v_review.decision IN ('accept_late','correct_reading','rechain'))) THEN
  PERFORM gms.fail('GM409', 'cycle_not_open', 'دورة القراءة ليست مفتوحة');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.meter_installations i WHERE i.id = NEW.installation_id
     AND i.subscriber_id = NEW.subscriber_id AND i.installed_at <= NEW.verified_captured_at
     AND (i.removed_at IS NULL OR i.removed_at > NEW.verified_captured_at)) THEN
  PERFORM gms.fail('GM409', 'installation_inactive', 'تركيب العداد غير فعال في وقت القراءة الموثّق');
 END IF;
 IF EXISTS (SELECT 1 FROM gms.approved_readings a WHERE a.installation_id = NEW.installation_id
     AND a.state = 'active' AND a.verified_captured_at >= NEW.verified_captured_at) THEN
  PERFORM gms.fail('GM409', 'out_of_order', 'لا يمكن اعتماد قراءة خارج التسلسل الزمني أو مساوية لوقت قراءة معتمدة');
 END IF;
 IF NEW.opening_baseline_id IS NOT NULL THEN
  SELECT * INTO v_base FROM gms.opening_baselines WHERE id = NEW.opening_baseline_id;
  IF v_base.id IS NULL OR v_base.installation_id <> NEW.installation_id
     OR v_base.opening_value_kwh <> NEW.previous_value_kwh
     OR EXISTS (SELECT 1 FROM gms.approved_readings a WHERE a.installation_id = NEW.installation_id AND a.state = 'active') THEN
   PERFORM gms.fail('GM409', 'opening_mismatch', 'مرجع القراءة الافتتاحية غير صالح');
  END IF;
 ELSE
  SELECT * INTO v_prev FROM gms.approved_readings WHERE id = NEW.previous_approved_id AND state = 'active';
  IF v_prev.id IS NULL OR v_prev.installation_id <> NEW.installation_id OR v_prev.subscriber_id <> NEW.subscriber_id
     OR v_prev.current_value_kwh <> NEW.previous_value_kwh
     OR v_prev.verified_captured_at >= NEW.verified_captured_at THEN
   PERFORM gms.fail('GM409', 'chain_mismatch', 'عدم تطابق مع القراءة المعتمدة السابقة في السلسلة');
  END IF;
  IF EXISTS (SELECT 1 FROM gms.approved_readings a WHERE a.installation_id = NEW.installation_id
      AND a.state = 'active' AND a.verified_captured_at > v_prev.verified_captured_at) THEN
   PERFORM gms.fail('GM409', 'not_chain_head', 'القراءة السابقة ليست رأس السلسلة الحالي');
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_approved_validate BEFORE INSERT ON gms.approved_readings
 FOR EACH ROW EXECUTE FUNCTION gms.tg_approved_validate();

-- FIX-03/07: cycle lifecycle. Closing is possible only inside gms.finalize_cycle().
CREATE FUNCTION gms.tg_cycle_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF TG_OP = 'INSERT' THEN
  IF NEW.state <> 'draft' THEN PERFORM gms.fail('GM409', 'cycle_must_start_draft', 'تُنشأ الدورة كمسودة ثم تُفتح'); END IF;
  RETURN NEW;
 END IF;
 IF OLD.state = 'closed' THEN PERFORM gms.fail('GM409', 'cycle_closed', 'الدورة المغلقة غير قابلة للتعديل'); END IF;
 IF NOT ((OLD.state = NEW.state) OR (OLD.state = 'draft' AND NEW.state = 'open') OR (OLD.state = 'open' AND NEW.state = 'closed')) THEN
  PERFORM gms.fail('GM409', 'cycle_transition', 'انتقال حالة دورة غير صالح');
 END IF;
 IF (OLD.starts_on, OLD.ends_on) IS DISTINCT FROM (NEW.starts_on, NEW.ends_on)
    AND (EXISTS (SELECT 1 FROM gms.reading_tasks WHERE cycle_id = OLD.id)
      OR EXISTS (SELECT 1 FROM gms.approved_readings WHERE cycle_id = OLD.id)
      OR EXISTS (SELECT 1 FROM gms.tariff_change_events WHERE cycle_id = OLD.id)) THEN
  PERFORM gms.fail('GM409', 'cycle_dates_locked', 'لا يمكن تغيير حدود دورة لها مهام أو قراءات أو أسعار');
 END IF;
 IF OLD.state = 'draft' AND NEW.state = 'open' THEN
  IF EXISTS (SELECT 1 FROM gms.reading_cycles c WHERE c.starts_on < NEW.starts_on AND c.state <> 'closed') THEN
   PERFORM gms.fail('GM409', 'earlier_cycle_not_closed', 'يجب إغلاق الدورات الأسبق قبل فتح هذه الدورة');
  END IF;
  NEW.opened_at := now();
 END IF;
 IF NEW.state = 'closed' THEN
  IF COALESCE(current_setting('gms.finalizing', true), '') <> NEW.id::text THEN
   PERFORM gms.fail('GM409', 'close_requires_finalize', 'إغلاق الدورة يتم فقط عبر إجراء الإغلاق الذري');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM gms.cycle_price_decisions cp WHERE cp.cycle_id = NEW.id AND cp.finalized_at IS NOT NULL) THEN
   PERFORM gms.fail('GM409', 'final_rate_missing', 'لا يمكن الإغلاق دون سعر نهائي مثبت');
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_cycle_guard BEFORE INSERT OR UPDATE ON gms.reading_cycles
 FOR EACH ROW EXECUTE FUNCTION gms.tg_cycle_guard();

CREATE FUNCTION gms.tg_price_decision_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF OLD.finalized_at IS NOT NULL THEN PERFORM gms.fail('GM409', 'final_rate_locked', 'السعر النهائي غير قابل للتغيير'); END IF;
 IF EXISTS (SELECT 1 FROM gms.reading_cycles c WHERE c.id = OLD.cycle_id AND c.state = 'closed') THEN
  PERFORM gms.fail('GM409', 'cycle_closed', 'لا يمكن تغيير تسعير دورة مغلقة');
 END IF;
 IF NEW.cycle_id <> OLD.cycle_id THEN PERFORM gms.fail('GM409', 'immutable', 'لا يمكن تغيير الدورة'); END IF;
 IF NEW.finalized_at IS NOT NULL AND COALESCE(current_setting('gms.finalizing', true), '') <> NEW.cycle_id::text THEN
  PERFORM gms.fail('GM409', 'final_requires_finalize', 'تثبيت السعر النهائي يتم ضمن إجراء الإغلاق الذري');
 END IF;
 NEW.updated_at := now();
 RETURN NEW;
END $$;
CREATE TRIGGER trg_price_decision_guard BEFORE UPDATE ON gms.cycle_price_decisions
 FOR EACH ROW EXECUTE FUNCTION gms.tg_price_decision_guard();
CREATE FUNCTION gms.tg_price_decision_insert_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM gms.reading_cycles c WHERE c.id = NEW.cycle_id AND c.state IN ('draft','open')) THEN
  PERFORM gms.fail('GM409', 'cycle_closed', 'لا يمكن تسعير دورة مغلقة');
 END IF;
 IF NEW.finalized_at IS NOT NULL AND COALESCE(current_setting('gms.finalizing', true), '') <> NEW.cycle_id::text THEN
  PERFORM gms.fail('GM409', 'final_requires_finalize', 'تثبيت السعر النهائي يتم ضمن إجراء الإغلاق الذري');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_price_decision_insert_guard BEFORE INSERT ON gms.cycle_price_decisions
 FOR EACH ROW EXECUTE FUNCTION gms.tg_price_decision_insert_guard();

-- FIX-08: provisional price history only inside the dates of an unlocked cycle.
CREATE FUNCTION gms.tg_tariff_event_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM gms.reading_cycles c WHERE c.id = NEW.cycle_id
     AND NEW.effective_on BETWEEN c.starts_on AND c.ends_on AND c.state IN ('draft','open')) THEN
  PERFORM gms.fail('GM409', 'tariff_date_out_of_cycle', 'تاريخ تغيير السعر يجب أن يقع داخل دورة غير مغلقة');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_tariff_event_guard BEFORE INSERT ON gms.tariff_change_events
 FOR EACH ROW EXECUTE FUNCTION gms.tg_tariff_event_guard();

CREATE FUNCTION gms.tg_statement_insert_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF NEW.state <> 'final' OR COALESCE(current_setting('gms.finalizing', true), '') <> NEW.cycle_id::text THEN
  PERFORM gms.fail('GM409', 'statement_requires_finalize', 'الكشف النهائي يُنشأ فقط ضمن إجراء الإغلاق الذري');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.cycle_price_decisions cp WHERE cp.cycle_id = NEW.cycle_id
     AND cp.final_rate_ils_per_kwh = NEW.rate_snapshot_ils_per_kwh) THEN
  PERFORM gms.fail('GM409', 'statement_rate_mismatch', 'سعر الكشف لا يطابق السعر النهائي للدورة');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_statement_insert_guard BEFORE INSERT ON gms.statement_versions
 FOR EACH ROW EXECUTE FUNCTION gms.tg_statement_insert_guard();

CREATE FUNCTION gms.tg_statement_line_validate() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
DECLARE s gms.statement_versions; a gms.approved_readings;
BEGIN
 SELECT * INTO s FROM gms.statement_versions WHERE id = NEW.statement_id;
 SELECT * INTO a FROM gms.approved_readings WHERE id = NEW.approved_reading_id;
 IF s.id IS NULL OR a.id IS NULL OR a.state <> 'active' OR a.subscriber_id <> s.subscriber_id
    OR a.cycle_id <> s.cycle_id OR a.consumption_kwh <> NEW.consumption_kwh
    OR a.previous_value_kwh <> NEW.previous_value_kwh OR a.current_value_kwh <> NEW.current_value_kwh
    OR NEW.rate_snapshot <> s.rate_snapshot_ils_per_kwh
    OR NOT EXISTS (SELECT 1 FROM gms.reading_cycles c WHERE c.id = s.cycle_id AND c.state = 'open') THEN
  PERFORM gms.fail('GM409', 'statement_line_invalid', 'سطر الكشف لا يطابق المشترك أو الدورة أو القراءة أو السعر');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_statement_line_validate BEFORE INSERT ON gms.statement_reading_lines
 FOR EACH ROW EXECUTE FUNCTION gms.tg_statement_line_validate();

CREATE FUNCTION gms.tg_allocation_validate() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM gms.statement_versions s JOIN gms.approved_readings a
      ON a.subscriber_id = s.subscriber_id AND a.cycle_id = s.cycle_id
     WHERE s.id = NEW.statement_id AND s.state = 'final' AND a.id = NEW.approved_reading_id AND a.state = 'active')
    OR NOT EXISTS (SELECT 1 FROM gms.statement_reading_lines l
     WHERE l.statement_id = NEW.statement_id AND l.approved_reading_id = NEW.approved_reading_id) THEN
  PERFORM gms.fail('GM409', 'allocation_invalid', 'إسناد القراءة يجب أن يشير إلى كشف نهائي صالح وسطر تفصيلي وقراءة فعالة');
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_allocation_validate BEFORE INSERT ON gms.final_reading_allocations
 FOR EACH ROW EXECUTE FUNCTION gms.tg_allocation_validate();

-- FIX-06: every ledger movement must point at a real source row with the same subscriber and amount.
CREATE FUNCTION gms.tg_ledger_source_validate() RETURNS trigger
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
DECLARE v_ok boolean := false;
BEGIN
 CASE NEW.source_type
 WHEN 'final_statement' THEN
  SELECT EXISTS (SELECT 1 FROM gms.statement_versions s WHERE s.id = NEW.source_id
    AND s.subscriber_id = NEW.subscriber_id AND s.state = 'final' AND s.charge_exact_ils = NEW.signed_amount_ils) INTO v_ok;
 WHEN 'payment' THEN
  SELECT EXISTS (SELECT 1 FROM gms.payment_receipts p WHERE p.id = NEW.source_id
    AND p.subscriber_id = NEW.subscriber_id AND NEW.signed_amount_ils = -p.amount_ils) INTO v_ok;
 WHEN 'payment_reversal' THEN
  SELECT EXISTS (SELECT 1 FROM gms.payment_reversals r JOIN gms.payment_receipts p ON p.id = r.payment_id
    WHERE r.id = NEW.source_id AND p.subscriber_id = NEW.subscriber_id AND NEW.signed_amount_ils = p.amount_ils) INTO v_ok;
 WHEN 'adjustment' THEN
  SELECT EXISTS (SELECT 1 FROM gms.financial_adjustments a WHERE a.id = NEW.source_id
    AND a.subscriber_id = NEW.subscriber_id AND a.adjustment_ils = NEW.signed_amount_ils) INTO v_ok;
 WHEN 'opening_receivable' THEN
  SELECT EXISTS (SELECT 1 FROM gms.opening_receivables o WHERE o.id = NEW.source_id
    AND o.subscriber_id = NEW.subscriber_id AND o.signed_amount_ils = NEW.signed_amount_ils) INTO v_ok;
 ELSE v_ok := false;
 END CASE;
 IF NOT v_ok THEN PERFORM gms.fail('GM409', 'ledger_source_invalid', 'مصدر القيد المالي غير موجود أو مبلغه غير مطابق'); END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_ledger_source_validate BEFORE INSERT ON gms.ledger_entries
 FOR EACH ROW EXECUTE FUNCTION gms.tg_ledger_source_validate();

-- Generic audit trail (append-only table). SECURITY DEFINER so it works for every writer.
CREATE FUNCTION gms.tg_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_new jsonb; v_old jsonb; v_id uuid;
BEGIN
 BEGIN v_actor := nullif(current_setting('gms.actor_id', true), '')::uuid;
 EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;
 IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD) - 'password_hash' - 'token_sha256' - 'code_sha256' - 'last_seen_at' - 'failed_logins' - 'locked_until'; END IF;
 IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW) - 'password_hash' - 'token_sha256' - 'code_sha256' - 'last_seen_at' - 'failed_logins' - 'locked_until'; END IF;
 IF TG_OP = 'UPDATE' AND v_old = v_new THEN RETURN NEW; END IF;
 BEGIN
  v_id := COALESCE(COALESCE(v_new, v_old)->>'id', COALESCE(v_new, v_old)->>'subscriber_id', COALESCE(v_new, v_old)->>'cycle_id')::uuid;
 EXCEPTION WHEN OTHERS THEN v_id := NULL; END;
 INSERT INTO gms.audit_logs(actor_id, action_code, entity_type, entity_id, before_data, after_data)
 VALUES (v_actor, 'DB_' || TG_OP, TG_TABLE_NAME, v_id, v_old, v_new);
 RETURN COALESCE(NEW, OLD);
END $$;
DO $$ DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['app_users','mobile_devices','device_enrollment_codes','generators','zones','subscribers',
   'subscriber_schedules','user_zone_grants','meters','meter_installations','opening_baselines','reading_cycles',
   'cycle_price_decisions','tariff_change_events','reading_tasks','field_visits','visit_photos','visit_reviews',
   'visit_error_reports','meter_incident_reports','approved_readings','reading_corrections','statement_versions',
   'payment_receipts','payment_reversals','financial_adjustments','opening_receivables','system_settings'] LOOP
  EXECUTE format('CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE ON gms.%I FOR EACH ROW EXECUTE FUNCTION gms.tg_audit()', t);
 END LOOP;
END $$;

-- Explicit audit entry for API-level events (login, export, backup download, refused attempts).
CREATE FUNCTION gms.audit(p_action text, p_entity_type text, p_entity_id uuid, p_data jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
 BEGIN v_actor := nullif(current_setting('gms.actor_id', true), '')::uuid;
 EXCEPTION WHEN OTHERS THEN v_actor := NULL; END;
 INSERT INTO gms.audit_logs(actor_id, action_code, entity_type, entity_id, after_data)
 VALUES (v_actor, p_action, p_entity_type, p_entity_id, p_data);
END $$;
