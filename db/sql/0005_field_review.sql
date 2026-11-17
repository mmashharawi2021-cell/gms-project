-- GMS | 0005 | Field sync intake, photos, manager review, approved chain, corrections.

-- Internal: store the outcome of a sync operation so that retries return the same answer.
CREATE FUNCTION gms._sync_result(p_operation uuid, p_kind text, p_actor uuid, p_device uuid, p_entity uuid,
 p_sha text, p_code text, p_data jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 INSERT INTO gms.sync_operations(operation_id, op_kind, employee_id, device_id, entity_id, payload_sha256, result_code, result_data)
 VALUES (p_operation, p_kind, p_actor, p_device, p_entity, lower(p_sha), p_code, p_data);
 RETURN jsonb_build_object('result', p_code) || p_data;
END $$;

-- Device sync intake (BR-26, FR-17). Results: accepted / already_received / conflict / rejected.
-- p_sha = SHA-256 of the canonical visit payload, computed BY THE API.
-- p_time_trust = API verdict on the device clock ('consistent' | 'suspicious'), p_estimated_at =
-- server-side estimate of the capture instant when the device supplied monotonic-clock evidence.
-- Raw data captured under a stale offline assignment is preserved and flagged, never dropped (BR-14).
CREATE FUNCTION gms.receive_visit(p_operation uuid, p_visit uuid, p_device uuid, p_payload jsonb, p_sha text,
 p_time_trust text DEFAULT 'suspicious', p_estimated_at timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_op gms.sync_operations; v_old gms.field_visits; v_task gms.reading_tasks;
 v_sub uuid; v_inst uuid; v_zone uuid; v_task_id uuid; v_payload_task uuid; v_kind text; v_reading numeric;
 v_reason text; v_note text; v_cap timestamptz; v_offset integer; v_cat text;
 v_flags text[] := '{}'; v_ts text; v_verified timestamptz; v_cycle gms.reading_cycles; v_tol interval; v_late interval;
BEGIN
 v_actor := gms.require_role('employee');
 IF p_operation IS NULL OR p_visit IS NULL OR p_device IS NULL OR p_payload IS NULL
    OR p_sha IS NULL OR p_sha !~ '^[0-9a-fA-F]{64}$' OR p_time_trust NOT IN ('consistent','suspicious') THEN
  PERFORM gms.fail('GM422', 'invalid_envelope', 'مغلف المزامنة غير صالح');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.mobile_devices d WHERE d.id = p_device AND d.employee_id = v_actor AND d.is_active) THEN
  PERFORM gms.fail('GM403', 'device_revoked', 'الجهاز غير مصرح له بالمزامنة');
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_visit::text, 62022));
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation::text, 62023));

 SELECT * INTO v_op FROM gms.sync_operations WHERE operation_id = p_operation;
 IF FOUND THEN
  IF v_op.employee_id = v_actor AND v_op.payload_sha256 = lower(p_sha) AND v_op.entity_id = p_visit AND v_op.op_kind = 'visit' THEN
   -- a replay returns the SAME verdict that was stored the first time (rejected/conflict stay so)
   IF v_op.result_code IN ('rejected','conflict') THEN RETURN jsonb_build_object('result', v_op.result_code) || v_op.result_data; END IF;
   SELECT * INTO v_old FROM gms.field_visits WHERE id = p_visit;
   RETURN jsonb_build_object('result', 'already_received', 'record_status', v_old.record_status, 'flags', to_jsonb(v_old.flags));
  END IF;
  RETURN jsonb_build_object('result', 'conflict', 'reason', 'operation_reused');
 END IF;
 SELECT * INTO v_old FROM gms.field_visits WHERE id = p_visit;
 IF FOUND THEN
  IF v_old.employee_id = v_actor AND v_old.device_payload_sha256 = lower(p_sha) THEN
   RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'already_received',
    jsonb_build_object('record_status', v_old.record_status, 'flags', to_jsonb(v_old.flags)));
  END IF;
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'conflict', jsonb_build_object('reason', 'visit_id_reused'));
 END IF;

 BEGIN
  v_sub := (p_payload->>'subscriber_id')::uuid;
  v_inst := (p_payload->>'installation_id')::uuid;
  v_zone := (p_payload->>'zone_id')::uuid;
  v_payload_task := nullif(p_payload->>'task_id', '')::uuid;
  v_kind := p_payload->>'event_kind';
  v_reading := nullif(p_payload->>'reading_value_kwh', '')::numeric;
  v_reason := nullif(trim(p_payload->>'reason'), '');
  v_note := nullif(trim(p_payload->>'note'), '');
  v_cap := (p_payload->>'captured_at_device')::timestamptz;
  v_offset := nullif(p_payload->>'captured_offset_minutes', '')::integer;
  v_cat := COALESCE(nullif(p_payload->>'incident_category', ''), 'other');
 EXCEPTION WHEN OTHERS THEN
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'malformed_payload'));
 END;
 IF v_sub IS NULL OR v_inst IS NULL OR v_zone IS NULL OR v_cap IS NULL
    OR v_kind IS NULL OR v_kind NOT IN ('reading','unreadable','meter_incident')
    OR v_cat NOT IN ('reset','replacement','fault','other') THEN
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'malformed_payload'));
 END IF;
 IF v_kind = 'reading' AND (v_reading IS NULL OR v_reading < 0 OR v_reading >= 100000000000000) THEN
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'invalid_reading'));
 END IF;
 -- FIX-01: more than two decimals is refused, never rounded.
 IF v_kind = 'reading' AND scale(v_reading) > 2 THEN
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'invalid_precision'));
 END IF;
 IF v_kind <> 'reading' AND (v_reading IS NOT NULL OR v_reason IS NULL) THEN
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'reason_required'));
 END IF;
 IF v_payload_task IS NULL AND v_reason IS NULL THEN -- BR-13: extra visit needs a reason
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'reason_required'));
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.meter_installations i WHERE i.id = v_inst AND i.subscriber_id = v_sub)
    OR NOT EXISTS (SELECT 1 FROM gms.zones z WHERE z.id = v_zone) THEN
  RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'unknown_reference'));
 END IF;
 -- Server-side zone authorisation: never trust what the app chose to show.
 IF NOT EXISTS (SELECT 1 FROM gms.user_zone_grants g WHERE g.employee_id = v_actor AND g.zone_id = v_zone
     AND g.valid_from <= v_cap AND (g.valid_until IS NULL OR v_cap < g.valid_until)) THEN
  IF EXISTS (SELECT 1 FROM gms.user_zone_grants g WHERE g.employee_id = v_actor AND g.zone_id = v_zone) THEN
   v_flags := array_append(v_flags, 'no_zone_grant');
  ELSE
   RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'rejected', jsonb_build_object('reason', 'forbidden_zone'));
  END IF;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.subscribers s WHERE s.id = v_sub AND s.zone_id = v_zone) THEN
  v_flags := array_append(v_flags, 'zone_changed');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.meter_installations i WHERE i.id = v_inst AND i.installed_at <= v_cap
     AND (i.removed_at IS NULL OR i.removed_at > v_cap)) THEN
  v_flags := array_append(v_flags, 'installation_inactive');
 END IF;
 IF v_payload_task IS NULL THEN
  v_flags := array_append(v_flags, 'unscheduled');
 ELSE
  SELECT * INTO v_task FROM gms.reading_tasks WHERE id = v_payload_task FOR UPDATE;
  IF NOT FOUND OR v_task.subscriber_id <> v_sub THEN
   v_flags := array_append(v_flags, 'task_missing');
  ELSE
   v_task_id := v_task.id;
   IF v_task.assigned_employee_id IS DISTINCT FROM v_actor OR v_task.installation_id <> v_inst
      OR v_task.status NOT IN ('assigned','in_progress','pending_review') THEN
    v_flags := array_append(v_flags, 'task_mismatch');
   END IF;
  END IF;
 END IF;
 -- BR-24: device time is evidence, not truth.
 v_tol := make_interval(mins => COALESCE(gms.setting('clock_skew_tolerance_minutes')::int, 5));
 v_late := make_interval(hours => COALESCE(gms.setting('late_sync_hours')::int, 36));
 v_ts := p_time_trust;
 IF v_cap > now() + v_tol THEN v_ts := 'suspicious'; v_flags := array_append(v_flags, 'clock_future'); END IF;
 IF v_ts = 'suspicious' AND NOT ('clock_future' = ANY (v_flags)) THEN v_flags := array_append(v_flags, 'clock_suspicious'); END IF;
 IF now() - v_cap > v_late THEN v_flags := array_append(v_flags, 'late_sync'); END IF;
 SELECT * INTO v_cycle FROM gms.reading_cycles c WHERE gms.local_date(v_cap) BETWEEN c.starts_on AND c.ends_on;
 IF FOUND AND v_cycle.state = 'closed' THEN v_flags := array_append(v_flags, 'cycle_closed'); END IF; -- BR-25
 v_verified := CASE WHEN v_ts = 'consistent' THEN v_cap END;

 INSERT INTO gms.field_visits(id, task_id, payload_task_id, subscriber_id, installation_id, zone_id, employee_id, device_id,
  event_kind, reading_value_kwh, reason, note, captured_at_device, captured_offset_minutes, server_estimated_captured_at,
  flags, device_payload_sha256, verified_captured_at, timestamp_status, record_status)
 VALUES (p_visit, v_task_id, v_payload_task, v_sub, v_inst, v_zone, v_actor, p_device, v_kind, v_reading, v_reason, v_note,
  v_cap, v_offset, p_estimated_at, v_flags, lower(p_sha), v_verified, v_ts, 'awaiting_photo');
 IF v_kind = 'meter_incident' THEN
  INSERT INTO gms.meter_incident_reports(visit_id, category, notes) VALUES (p_visit, v_cat, v_reason);
 END IF;
 IF v_task_id IS NOT NULL AND NOT ('task_mismatch' = ANY (v_flags)) AND v_task.status IN ('assigned','in_progress') THEN
  UPDATE gms.reading_tasks SET status = 'pending_review', updated_at = now() WHERE id = v_task_id;
 END IF;
 RETURN gms._sync_result(p_operation, 'visit', v_actor, p_device, p_visit, p_sha, 'accepted',
  jsonb_build_object('record_status', 'awaiting_photo', 'flags', to_jsonb(v_flags)));
END $$;

-- FR-13: employee reports a mistake in a visit they already sent (raw visit is not edited).
CREATE FUNCTION gms.receive_error_report(p_operation uuid, p_report uuid, p_device uuid, p_visit uuid, p_explanation text, p_sha text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_op gms.sync_operations;
BEGIN
 v_actor := gms.require_role('employee');
 IF p_operation IS NULL OR p_report IS NULL OR p_device IS NULL OR p_visit IS NULL OR p_sha IS NULL OR p_sha !~ '^[0-9a-fA-F]{64}$' THEN
  PERFORM gms.fail('GM422', 'invalid_envelope', 'مغلف المزامنة غير صالح');
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.mobile_devices d WHERE d.id = p_device AND d.employee_id = v_actor AND d.is_active) THEN
  PERFORM gms.fail('GM403', 'device_revoked', 'الجهاز غير مصرح له بالمزامنة');
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_report::text, 62022));
 PERFORM pg_advisory_xact_lock(hashtextextended(p_operation::text, 62023));
 SELECT * INTO v_op FROM gms.sync_operations WHERE operation_id = p_operation;
 IF FOUND THEN
  IF v_op.employee_id = v_actor AND v_op.payload_sha256 = lower(p_sha) AND v_op.entity_id = p_report AND v_op.op_kind = 'error_report' THEN
   RETURN jsonb_build_object('result', CASE WHEN v_op.result_code = 'accepted' THEN 'already_received' ELSE v_op.result_code END) || v_op.result_data;
  END IF;
  RETURN jsonb_build_object('result', 'conflict', 'reason', 'operation_reused');
 END IF;
 IF EXISTS (SELECT 1 FROM gms.visit_error_reports WHERE id = p_report) THEN
  RETURN gms._sync_result(p_operation, 'error_report', v_actor, p_device, p_report, p_sha, 'already_received', '{}'::jsonb);
 END IF;
 IF nullif(trim(p_explanation), '') IS NULL
    OR NOT EXISTS (SELECT 1 FROM gms.field_visits v WHERE v.id = p_visit AND v.employee_id = v_actor) THEN
  RETURN gms._sync_result(p_operation, 'error_report', v_actor, p_device, p_report, p_sha, 'rejected', jsonb_build_object('reason', 'unknown_reference'));
 END IF;
 INSERT INTO gms.visit_error_reports(id, visit_id, employee_id, explanation) VALUES (p_report, p_visit, v_actor, trim(p_explanation));
 RETURN gms._sync_result(p_operation, 'error_report', v_actor, p_device, p_report, p_sha, 'accepted', '{}'::jsonb);
END $$;

-- Photo step 1: declare the upload (idempotent on the device-generated photo id).
CREATE FUNCTION gms.begin_photo(p_photo uuid, p_visit uuid, p_sha text, p_size bigint, p_content_type text, p_primary boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits; ph gms.visit_photos; v_key text;
BEGIN
 v_actor := gms.require_role('employee');
 IF p_photo IS NULL OR p_size IS NULL OR p_size <= 0 OR p_sha IS NULL OR p_sha !~ '^[0-9a-fA-F]{64}$'
    OR p_content_type IS NULL OR p_content_type NOT IN ('image/jpeg','image/png','image/webp') OR p_primary IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_photo', 'بيانات الصورة غير صالحة');
 END IF;
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND OR v.employee_id <> v_actor THEN PERFORM gms.fail('GM404', 'visit_not_found', 'الزيارة غير موجودة لهذا الموظف'); END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.mobile_devices d WHERE d.id = v.device_id AND d.is_active) THEN
  PERFORM gms.fail('GM403', 'device_revoked', 'الجهاز غير مصرح له بالمزامنة');
 END IF;
 SELECT * INTO ph FROM gms.visit_photos WHERE id = p_photo;
 IF FOUND THEN
  IF ph.visit_id <> p_visit OR ph.sha256_hex <> lower(p_sha) OR ph.size_bytes <> p_size OR ph.is_primary <> p_primary THEN
   PERFORM gms.fail('GM409', 'photo_conflict', 'معرّف الصورة مستخدم ببيانات مختلفة');
  END IF;
  IF ph.state = 'failed' THEN UPDATE gms.visit_photos SET state = 'uploading', failure_reason = NULL WHERE id = p_photo; ph.state := 'uploading'; END IF;
  RETURN jsonb_build_object('state', ph.state, 'object_key', ph.object_key);
 END IF;
 IF p_primary AND EXISTS (SELECT 1 FROM gms.visit_photos WHERE visit_id = p_visit AND is_primary) THEN
  PERFORM gms.fail('GM409', 'primary_exists', 'للزيارة صورة أساسية مسجلة بالفعل');
 END IF;
 v_key := 'visits/' || p_visit || '/' || p_photo || CASE p_content_type WHEN 'image/jpeg' THEN '.jpg' WHEN 'image/png' THEN '.png' ELSE '.webp' END;
 INSERT INTO gms.visit_photos(id, visit_id, object_key, sha256_hex, size_bytes, content_type, is_primary)
 VALUES (p_photo, p_visit, v_key, lower(p_sha), p_size, p_content_type, p_primary);
 RETURN jsonb_build_object('state', 'uploading', 'object_key', v_key);
END $$;

-- Photo step 2: called by the API ONLY after it re-read the stored object and verified size,
-- SHA-256 and image signature. A ready primary photo releases the visit for review.
CREATE FUNCTION gms.complete_photo(p_photo uuid, p_verified_sha text, p_verified_size bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; ph gms.visit_photos; v gms.field_visits; v_status text;
BEGIN
 v_actor := gms.require_role('employee');
 SELECT * INTO ph FROM gms.visit_photos WHERE id = p_photo FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'photo_not_found', 'الصورة غير مسجلة'); END IF;
 SELECT * INTO v FROM gms.field_visits WHERE id = ph.visit_id FOR UPDATE;
 IF v.employee_id <> v_actor THEN PERFORM gms.fail('GM404', 'photo_not_found', 'الصورة غير مسجلة'); END IF;
 IF ph.state = 'ready' THEN RETURN jsonb_build_object('state', 'ready', 'record_status', v.record_status); END IF;
 IF lower(p_verified_sha) IS DISTINCT FROM ph.sha256_hex OR p_verified_size IS DISTINCT FROM ph.size_bytes THEN
  UPDATE gms.visit_photos SET state = 'failed', failure_reason = 'checksum_or_size_mismatch' WHERE id = p_photo;
  RETURN jsonb_build_object('state', 'failed', 'reason', 'checksum_or_size_mismatch', 'record_status', v.record_status);
 END IF;
 UPDATE gms.visit_photos SET state = 'ready', ready_at = now(), failure_reason = NULL WHERE id = p_photo;
 v_status := v.record_status;
 IF ph.is_primary AND v.record_status = 'awaiting_photo' THEN
  v_status := CASE WHEN cardinality(v.flags) > 0 OR v.timestamp_status = 'suspicious' THEN 'exception' ELSE 'pending_review' END;
  UPDATE gms.field_visits SET record_status = v_status WHERE id = v.id;
 END IF;
 RETURN jsonb_build_object('state', 'ready', 'record_status', v_status);
END $$;

-- Manager adjudication of the capture instant (a decision, not proof the device clock was right).
CREATE FUNCTION gms.verify_capture_time(p_visit uuid, p_verified_at timestamptz, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits; v_corrected boolean;
BEGIN
 v_actor := gms.require_role('manager');
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'visit_not_found', 'الزيارة غير موجودة'); END IF;
 IF v.record_status NOT IN ('awaiting_photo','pending_review','exception') THEN
  PERFORM gms.fail('GM409', 'visit_resolved', 'الزيارة محسومة؛ لا يمكن تغيير وقتها');
 END IF;
 IF p_verified_at IS NULL OR p_verified_at > now() + interval '10 minutes' THEN
  PERFORM gms.fail('GM422', 'invalid_time', 'وقت القراءة الموثّق مطلوب ولا يكون في المستقبل');
 END IF;
 v_corrected := p_verified_at IS DISTINCT FROM v.captured_at_device;
 IF nullif(trim(p_reason), '') IS NULL AND (v_corrected OR v.timestamp_status = 'suspicious') THEN
  PERFORM gms.fail('GM422', 'reason_required', 'توثيق سبب اعتماد/تصحيح الوقت إلزامي');
 END IF;
 UPDATE gms.field_visits SET verified_captured_at = p_verified_at,
  timestamp_status = CASE WHEN v_corrected THEN 'corrected' ELSE 'consistent' END WHERE id = p_visit;
 INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, corrected_capture_at, rationale)
 VALUES (p_visit, v_actor, 'correct_timestamp', p_verified_at, nullif(trim(p_reason), ''));
END $$;

-- Internal: after a task-linked visit is decided, settle the task status.
CREATE FUNCTION gms._settle_task(p_task uuid, p_outcome text) RETURNS void
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF p_task IS NULL THEN RETURN; END IF;
 IF p_outcome IN ('completed_reading','completed_unreadable','revisit_required') THEN
  UPDATE gms.reading_tasks SET status = p_outcome, updated_at = now()
   WHERE id = p_task AND status IN ('assigned','in_progress','pending_review');
 ELSIF p_outcome = 'reopen' THEN
  -- visit refused: the task goes back to the field unless another visit still awaits/has a decision
  UPDATE gms.reading_tasks t SET status = 'assigned', updated_at = now()
   WHERE t.id = p_task AND t.status = 'pending_review'
     AND NOT EXISTS (SELECT 1 FROM gms.field_visits v WHERE v.task_id = t.id
          AND v.record_status IN ('awaiting_photo','pending_review','exception'));
 END IF;
END $$;

-- Approve a raw reading as the next point of the linear chain (BR-09..12, BR-17, BR-25, BR-30).
CREATE FUNCTION gms.approve_visit(p_visit uuid, p_corrected_value numeric DEFAULT NULL, p_rationale text DEFAULT NULL,
 p_ack_exceptions boolean DEFAULT false, p_accept_late boolean DEFAULT false)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits; v_prior gms.approved_readings; v_base gms.opening_baselines; c gms.reading_cycles;
 v_value numeric; v_prev numeric; v_prev_id uuid; v_base_id uuid; v_new uuid; v_review uuid; v_decision text;
 v_rate numeric; v_amount numeric; v_at timestamptz;
BEGIN
 v_actor := gms.require_role('manager');
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'visit_not_found', 'الزيارة غير موجودة'); END IF;
 IF v.event_kind <> 'reading' THEN PERFORM gms.fail('GM409', 'not_a_reading', 'الزيارة ليست قراءة عداد'); END IF;
 IF v.record_status = 'awaiting_photo' THEN PERFORM gms.fail('GM409', 'photo_required', 'لا يمكن الاعتماد قبل وصول صورة أساسية سليمة'); END IF;
 IF v.record_status NOT IN ('pending_review','exception') THEN PERFORM gms.fail('GM409', 'visit_resolved', 'الزيارة محسومة مسبقًا'); END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.visit_photos WHERE visit_id = p_visit AND is_primary AND state = 'ready') THEN
  PERFORM gms.fail('GM409', 'photo_required', 'لا يمكن الاعتماد قبل وصول صورة أساسية سليمة');
 END IF;
 IF v.timestamp_status NOT IN ('consistent','corrected') OR v.verified_captured_at IS NULL THEN
  PERFORM gms.fail('GM409', 'timestamp_unverified', 'وقت الالتقاط مشكوك فيه؛ يجب أن يوثّقه المدير أولًا');
 END IF;
 v_at := v.verified_captured_at;
 IF cardinality(v.flags) > 0 AND (NOT COALESCE(p_ack_exceptions, false) OR nullif(trim(p_rationale), '') IS NULL) THEN
  PERFORM gms.fail('GM409', 'exceptions_need_ack', 'الزيارة عليها استثناءات (' || array_to_string(v.flags, ',') || ')؛ يلزم إقرار المدير مع توثيق السبب');
 END IF;
 v_value := COALESCE(p_corrected_value, v.reading_value_kwh);
 IF v_value IS NULL OR v_value < 0 OR scale(v_value) > 2 THEN
  PERFORM gms.fail('GM422', 'invalid_precision', 'القراءة يجب أن تكون غير سالبة وبمنزلتين عشريتين كحد أقصى (لا تقريب)');
 END IF;
 IF p_corrected_value IS NOT NULL AND nullif(trim(p_rationale), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'reason_required', 'تصحيح القيمة يتطلب توثيق السبب (من الصورة)');
 END IF;
 -- Serialise every approval/correction on this meter installation.
 PERFORM 1 FROM gms.meter_installations WHERE id = v.installation_id FOR UPDATE;
 -- BR-11/12: an earlier raw reading still waiting blocks out-of-sequence approval.
 IF EXISTS (SELECT 1 FROM gms.field_visits o WHERE o.installation_id = v.installation_id AND o.id <> v.id
     AND o.event_kind = 'reading' AND o.record_status IN ('awaiting_photo','pending_review','exception')
     AND COALESCE(o.verified_captured_at, o.captured_at_device) < v_at) THEN
  PERFORM gms.fail('GM409', 'earlier_visit_pending', 'توجد قراءة أسبق لنفس العداد بانتظار قرار المدير؛ احسمها أولًا');
 END IF;
 SELECT * INTO c FROM gms.reading_cycles WHERE gms.local_date(v_at) BETWEEN starts_on AND ends_on FOR SHARE;
 IF NOT FOUND THEN PERFORM gms.fail('GM409', 'no_cycle_for_date', 'لا توجد دورة تسعير تغطي تاريخ القراءة الموثّق'); END IF;
 IF c.state = 'draft' THEN PERFORM gms.fail('GM409', 'cycle_not_open', 'دورة تاريخ القراءة لم تُفتح بعد'); END IF;
 IF c.state = 'closed' AND NOT COALESCE(p_accept_late, false) THEN
  PERFORM gms.fail('GM409', 'cycle_closed', 'القراءة تتبع دورة مغلقة؛ يلزم قرار صريح بقبولها كقراءة متأخرة (تسوية لاحقة)');
 END IF;
 IF c.state = 'closed' AND nullif(trim(p_rationale), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'reason_required', 'قبول قراءة متأخرة يتطلب توثيق السبب');
 END IF;
 SELECT * INTO v_prior FROM gms.approved_readings WHERE installation_id = v.installation_id AND state = 'active'
  ORDER BY verified_captured_at DESC, id DESC LIMIT 1;
 IF FOUND THEN
  IF v_prior.verified_captured_at >= v_at THEN
   PERFORM gms.fail('GM409', 'out_of_order', 'توجد قراءة معتمدة أحدث أو مساوية زمنيًا؛ القراءة خارج التسلسل (صنّفها مكررة/مرفوضة أو صحّح الوقت)');
  END IF;
  v_prev_id := v_prior.id; v_prev := v_prior.current_value_kwh;
 ELSE
  SELECT * INTO v_base FROM gms.opening_baselines WHERE installation_id = v.installation_id;
  IF NOT FOUND THEN PERFORM gms.fail('GM409', 'no_opening_baseline', 'لا توجد قراءة افتتاحية لهذا العداد'); END IF;
  v_base_id := v_base.id; v_prev := v_base.opening_value_kwh;
 END IF;
 IF v_value < v_prev THEN -- BR-09
  PERFORM gms.fail('GM409', 'lower_than_previous', format('القراءة (%s) أقل من السابقة المعتمدة (%s): استثناء بلا أثر مالي حتى يصححها المدير من الصورة أو يطلب إعادة زيارة أو يسجل تصفير/استبدال العداد', v_value, v_prev));
 END IF;
 v_decision := CASE WHEN c.state = 'closed' THEN 'accept_late' WHEN p_corrected_value IS NOT NULL AND p_corrected_value <> v.reading_value_kwh THEN 'correct_reading' ELSE 'approve_reading' END;
 INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, corrected_value_kwh, rationale)
 VALUES (p_visit, v_actor, v_decision, CASE WHEN v_value <> v.reading_value_kwh THEN v_value END, nullif(trim(p_rationale), ''))
 RETURNING id INTO v_review;
 INSERT INTO gms.approved_readings(visit_id, review_id, subscriber_id, installation_id, cycle_id, opening_baseline_id,
  previous_approved_id, previous_value_kwh, current_value_kwh, verified_captured_at, approved_by)
 VALUES (p_visit, v_review, v.subscriber_id, v.installation_id, c.id, v_base_id, v_prev_id, v_prev, v_value, v_at, v_actor)
 RETURNING id INTO v_new;
 UPDATE gms.field_visits SET record_status = 'approved' WHERE id = p_visit;
 PERFORM gms._settle_task(v.task_id, 'completed_reading');
 UPDATE gms.subscriber_schedules SET next_due_override = NULL, changed_by = v_actor, changed_at = now()
  WHERE subscriber_id = v.subscriber_id AND next_due_override IS NOT NULL;
 -- BR-25: a reading that belongs to a closed week never reopens it; its exact cost at that
 -- week's final rate becomes an independent adjustment.
 IF c.state = 'closed' THEN
  SELECT final_rate_ils_per_kwh INTO v_rate FROM gms.cycle_price_decisions WHERE cycle_id = c.id;
  v_amount := round((v_value - v_prev) * v_rate, 8);
  IF v_amount <> 0 THEN
   PERFORM gms._lock_account(v.subscriber_id);
   PERFORM gms._post_adjustment(v_actor, v.subscriber_id, v_amount,
    'قراءة متأخرة تتبع دورة مغلقة (' || c.label || '): ' || trim(p_rationale), gen_random_uuid(), 'late_reading', c.id, NULL, v_new);
  END IF;
 END IF;
 RETURN v_new;
END $$;

CREATE FUNCTION gms.reject_visit(p_visit uuid, p_decision text, p_rationale text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits; v_review uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_decision IS NULL OR p_decision NOT IN ('reject','duplicate') OR nullif(trim(p_rationale), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_decision', 'يلزم نوع القرار (رفض/مكرر) مع السبب');
 END IF;
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'visit_not_found', 'الزيارة غير موجودة'); END IF;
 IF v.record_status NOT IN ('awaiting_photo','pending_review','exception') THEN PERFORM gms.fail('GM409', 'visit_resolved', 'الزيارة محسومة مسبقًا'); END IF;
 INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, rationale) VALUES (p_visit, v_actor, p_decision, trim(p_rationale)) RETURNING id INTO v_review;
 UPDATE gms.field_visits SET record_status = 'rejected' WHERE id = p_visit;
 PERFORM gms._settle_task(v.task_id, 'reopen');
 RETURN v_review;
END $$;

-- BR-10/15: manager asks for a new visit; the follow-up task belongs to the week of its own date (BR-16).
CREATE FUNCTION gms.request_revisit(p_visit uuid, p_planned_for date, p_employee uuid, p_rationale text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits; v_cycle uuid; v_task uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_planned_for IS NULL OR nullif(trim(p_rationale), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_revisit', 'يلزم تاريخ إعادة الزيارة وسببها');
 END IF;
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'visit_not_found', 'الزيارة غير موجودة'); END IF;
 IF v.record_status NOT IN ('awaiting_photo','pending_review','exception') THEN PERFORM gms.fail('GM409', 'visit_resolved', 'الزيارة محسومة مسبقًا'); END IF;
 SELECT id INTO v_cycle FROM gms.reading_cycles WHERE p_planned_for BETWEEN starts_on AND ends_on AND state <> 'closed';
 IF v_cycle IS NULL THEN PERFORM gms.fail('GM409', 'no_cycle_for_date', 'لا توجد دورة غير مغلقة تغطي تاريخ إعادة الزيارة؛ أنشئ الدورة أولًا'); END IF;
 INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, rationale) VALUES (p_visit, v_actor, 'request_revisit', trim(p_rationale));
 UPDATE gms.field_visits SET record_status = 'needs_revisit' WHERE id = p_visit;
 PERFORM gms._settle_task(v.task_id, 'revisit_required');
 v_task := gms.create_task(v_cycle, v.subscriber_id, p_planned_for, 'revisit', COALESCE(p_employee, v.employee_id), v.task_id);
 RETURN v_task;
END $$;

-- BR-15: unreadable visit closed administratively: no consumption, no charge, manager picks the follow-up date.
CREATE FUNCTION gms.resolve_unreadable(p_visit uuid, p_followup_due date, p_rationale text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits; v_review uuid;
BEGIN
 v_actor := gms.require_role('manager');
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'visit_not_found', 'الزيارة غير موجودة'); END IF;
 IF v.event_kind <> 'unreadable' THEN PERFORM gms.fail('GM409', 'not_unreadable', 'الزيارة ليست حالة تعذر قراءة'); END IF;
 IF v.record_status NOT IN ('pending_review','exception') THEN
  PERFORM gms.fail('GM409', CASE WHEN v.record_status = 'awaiting_photo' THEN 'photo_required' ELSE 'visit_resolved' END,
   CASE WHEN v.record_status = 'awaiting_photo' THEN 'الصورة إلزامية حتى عند تعذر القراءة' ELSE 'الزيارة محسومة مسبقًا' END);
 END IF;
 IF NOT EXISTS (SELECT 1 FROM gms.visit_photos WHERE visit_id = p_visit AND state = 'ready' AND is_primary) THEN
  PERFORM gms.fail('GM409', 'photo_required', 'الصورة إلزامية حتى عند تعذر القراءة');
 END IF;
 IF p_followup_due IS NULL THEN PERFORM gms.fail('GM422', 'followup_required', 'يجب أن يحدد المدير موعد المتابعة'); END IF;
 INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, rationale)
 VALUES (p_visit, v_actor, 'approve_unreadable', COALESCE(nullif(trim(p_rationale), ''), 'إغلاق دون استهلاك') || ' — موعد المتابعة ' || p_followup_due)
 RETURNING id INTO v_review;
 UPDATE gms.field_visits SET record_status = 'unreadable_resolved' WHERE id = p_visit;
 PERFORM gms._settle_task(v.task_id, 'completed_unreadable');
 INSERT INTO gms.subscriber_schedules(subscriber_id, interval_days, next_due_override, changed_by)
 VALUES (v.subscriber_id, COALESCE(gms.setting('default_interval_days')::int, 7), p_followup_due, v_actor)
 ON CONFLICT (subscriber_id) DO UPDATE SET next_due_override = EXCLUDED.next_due_override, changed_by = EXCLUDED.changed_by, changed_at = now();
 RETURN v_review;
END $$;

-- Meter incident closed without replacing the meter (replacement/reset goes through gms.replace_meter).
CREATE FUNCTION gms.resolve_incident(p_visit uuid, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v gms.field_visits;
BEGIN
 v_actor := gms.require_role('manager');
 IF nullif(trim(p_note), '') IS NULL THEN PERFORM gms.fail('GM422', 'reason_required', 'توثيق قرار البلاغ إلزامي'); END IF;
 SELECT * INTO v FROM gms.field_visits WHERE id = p_visit FOR UPDATE;
 IF NOT FOUND OR v.event_kind <> 'meter_incident' THEN PERFORM gms.fail('GM404', 'visit_not_found', 'بلاغ العداد غير موجود'); END IF;
 IF v.record_status NOT IN ('pending_review','exception') THEN
  PERFORM gms.fail('GM409', CASE WHEN v.record_status = 'awaiting_photo' THEN 'photo_required' ELSE 'visit_resolved' END, 'البلاغ محسوم أو بانتظار الصورة');
 END IF;
 UPDATE gms.meter_incident_reports SET resolved_by = v_actor, resolved_at = now(), resolution_note = trim(p_note) WHERE visit_id = p_visit AND resolved_at IS NULL;
 INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, rationale) VALUES (p_visit, v_actor, 'resolve_incident', trim(p_note));
 UPDATE gms.field_visits SET record_status = 'incident_resolved' WHERE id = p_visit;
 PERFORM gms._settle_task(v.task_id, 'completed_unreadable');
END $$;

CREATE FUNCTION gms.acknowledge_error_report(p_report uuid, p_note text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF nullif(trim(p_note), '') IS NULL THEN PERFORM gms.fail('GM422', 'reason_required', 'توثيق معالجة البلاغ إلزامي'); END IF;
 UPDATE gms.visit_error_reports SET acknowledged_by = v_actor, acknowledged_at = now(), resolution_note = trim(p_note)
  WHERE id = p_report AND acknowledged_at IS NULL;
 IF NOT FOUND THEN PERFORM gms.fail('GM409', 'report_not_open', 'البلاغ غير موجود أو معالج مسبقًا'); END IF;
END $$;

-- BR-10/21/22: correct the VALUE of an approved reading. Nothing is edited or deleted:
-- the reading and every later reading of the chain are superseded tail-first and re-created
-- with the corrected predecessor. Readings in an OPEN cycle are simply recomputed (no ledger row
-- exists yet). For readings of a CLOSED cycle the final statement stays untouched and the exact
-- difference at that cycle's final rate is posted ONCE as an independent adjustment.
CREATE FUNCTION gms.correct_approved_reading(p_reading uuid, p_new_value numeric, p_rationale text, p_idempotency uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_corr gms.reading_corrections; r gms.approved_readings; x gms.approved_readings; v_visit gms.field_visits;
 v_chain uuid[]; v_id uuid; v_prev_value numeric; v_prev_id uuid; v_base_id uuid; v_cur numeric; v_review uuid;
 v_new uuid; v_first_new uuid; v_state text; v_rate numeric; v_delta numeric; v_corr_id uuid := gen_random_uuid();
 v_adj jsonb := '[]'::jsonb; a jsonb; i integer; v_label text;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_idempotency IS NULL OR nullif(trim(p_rationale), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'reason_required', 'التصحيح يتطلب السبب ومفتاح عدم التكرار');
 END IF;
 IF p_new_value IS NULL OR p_new_value < 0 OR scale(p_new_value) > 2 THEN
  PERFORM gms.fail('GM422', 'invalid_precision', 'القراءة يجب أن تكون غير سالبة وبمنزلتين عشريتين كحد أقصى (لا تقريب)');
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency::text, 62024));
 SELECT * INTO v_corr FROM gms.reading_corrections WHERE idempotency_key = p_idempotency;
 IF FOUND THEN
  IF v_corr.original_reading_id <> p_reading OR v_corr.new_value_kwh <> p_new_value THEN
   PERFORM gms.fail('GM409', 'idempotency_conflict', 'أُعيد استخدام مفتاح عدم التكرار مع بيانات تصحيح مختلفة');
  END IF;
  RETURN v_corr.new_reading_id;
 END IF;
 SELECT * INTO r FROM gms.approved_readings WHERE id = p_reading;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'reading_not_found', 'القراءة المعتمدة غير موجودة'); END IF;
 PERFORM 1 FROM gms.meter_installations WHERE id = r.installation_id FOR UPDATE;
 SELECT * INTO r FROM gms.approved_readings WHERE id = p_reading;
 IF r.state <> 'active' THEN PERFORM gms.fail('GM409', 'reading_not_active', 'القراءة ليست النسخة الفعالة؛ صحّح النسخة الحالية'); END IF;
 IF p_new_value = r.current_value_kwh THEN PERFORM gms.fail('GM422', 'no_change', 'القيمة الجديدة مطابقة للحالية'); END IF;
 IF p_new_value < r.previous_value_kwh THEN
  PERFORM gms.fail('GM409', 'lower_than_previous', 'القيمة المصححة أقل من القراءة السابقة في السلسلة');
 END IF;
 -- chain from r to the head, in time order
 SELECT array_agg(id ORDER BY verified_captured_at) INTO v_chain FROM gms.approved_readings
  WHERE installation_id = r.installation_id AND state = 'active' AND verified_captured_at >= r.verified_captured_at;
 PERFORM gms._lock_account(r.subscriber_id);
 -- supersede tail-first (guard forbids superseding a reading that still has an active successor)
 FOR i IN REVERSE array_length(v_chain, 1)..1 LOOP
  UPDATE gms.approved_readings SET state = 'superseded' WHERE id = v_chain[i];
 END LOOP;
 v_prev_value := r.previous_value_kwh; v_prev_id := r.previous_approved_id; v_base_id := r.opening_baseline_id;
 FOR i IN 1..array_length(v_chain, 1) LOOP
  SELECT * INTO x FROM gms.approved_readings WHERE id = v_chain[i];
  SELECT * INTO v_visit FROM gms.field_visits WHERE id = x.visit_id;
  v_cur := CASE WHEN i = 1 THEN p_new_value ELSE x.current_value_kwh END;
  IF v_cur < v_prev_value THEN
   PERFORM gms.fail('GM409', 'chain_would_break', format('التصحيح يجعل قراءة لاحقة (%s) أقل من سابقتها (%s)؛ صحّح اللاحقة أولًا', v_cur, v_prev_value));
  END IF;
  INSERT INTO gms.visit_reviews(visit_id, reviewed_by, decision, corrected_value_kwh, rationale)
  VALUES (x.visit_id, v_actor, CASE WHEN i = 1 THEN 'correct_reading' ELSE 'rechain' END,
   CASE WHEN v_cur <> v_visit.reading_value_kwh THEN v_cur WHEN i = 1 THEN v_cur END,
   CASE WHEN i = 1 THEN trim(p_rationale) ELSE 'إعادة ربط السلسلة بعد تصحيح قراءة سابقة: ' || trim(p_rationale) END)
  RETURNING id INTO v_review;
  INSERT INTO gms.approved_readings(visit_id, review_id, subscriber_id, installation_id, cycle_id, opening_baseline_id,
   previous_approved_id, supersedes_id, previous_value_kwh, current_value_kwh, verified_captured_at, approved_by)
  VALUES (x.visit_id, v_review, x.subscriber_id, x.installation_id, x.cycle_id,
   CASE WHEN i = 1 THEN v_base_id END, CASE WHEN i = 1 THEN v_prev_id ELSE v_new END, x.id,
   v_prev_value, v_cur, x.verified_captured_at, v_actor)
  RETURNING id INTO v_new;
  IF i = 1 THEN v_first_new := v_new; END IF;
  SELECT c.state, c.label, cp.final_rate_ils_per_kwh INTO v_state, v_label, v_rate
   FROM gms.reading_cycles c LEFT JOIN gms.cycle_price_decisions cp ON cp.cycle_id = c.id WHERE c.id = x.cycle_id;
  IF v_state = 'closed' THEN
   v_delta := round(((v_cur - v_prev_value) - x.consumption_kwh) * v_rate, 8);
   IF v_delta <> 0 THEN
    v_adj := v_adj || jsonb_build_object('amount', v_delta, 'cycle', x.cycle_id, 'reading', v_new, 'label', v_label);
   END IF;
  END IF;
  v_prev_value := v_cur;
 END LOOP;
 INSERT INTO gms.reading_corrections(id, idempotency_key, original_reading_id, new_reading_id, old_value_kwh, new_value_kwh, rationale, corrected_by)
 VALUES (v_corr_id, p_idempotency, p_reading, v_first_new, r.current_value_kwh, p_new_value, trim(p_rationale), v_actor);
 FOR a IN SELECT * FROM jsonb_array_elements(v_adj) LOOP
  PERFORM gms._post_adjustment(v_actor, r.subscriber_id, (a->>'amount')::numeric,
   'تسوية تصحيح قراءة في دورة مغلقة (' || (a->>'label') || '): ' || trim(p_rationale),
   gen_random_uuid(), 'reading_correction', (a->>'cycle')::uuid, v_corr_id, (a->>'reading')::uuid);
 END LOOP;
 RETURN v_first_new;
END $$;
