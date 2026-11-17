-- GMS 2.2 | Transactional core functions (clean DB, after 20_hardening.sql).
-- SECURITY DEFINER assumes a fully authenticated trusted API sets
-- SET LOCAL gms.actor_id = authenticated_user_uuid; never take ID from client.
-- Privileged backend role MUST NOT have direct DML to business tables.
BEGIN;

CREATE OR REPLACE FUNCTION gms_ledger_balance(p_subscriber uuid) RETURNS numeric
LANGUAGE sql VOLATILE AS $$
 SELECT COALESCE(SUM(signed_amount_ils),0) FROM ledger_entries
 WHERE subscriber_id=p_subscriber;
$$;

CREATE OR REPLACE FUNCTION gms_reconcile_account(p_subscriber uuid) RETURNS numeric
LANGUAGE plpgsql AS $$
DECLARE b numeric;
BEGIN
 INSERT INTO billing_accounts(subscriber_id) VALUES(p_subscriber)
 ON CONFLICT(subscriber_id) DO NOTHING;
 PERFORM 1 FROM billing_accounts WHERE subscriber_id=p_subscriber FOR UPDATE;
 b:=gms_ledger_balance(p_subscriber);
 UPDATE billing_accounts SET
  carry_fraction_ils=CASE WHEN b>0 THEN b-trunc(b) ELSE 0 END,
  credit_balance_ils=GREATEST(0,-b),updated_at=now()
 WHERE subscriber_id=p_subscriber;
 RETURN b;
END $$;

CREATE OR REPLACE FUNCTION gms_record_opening_receivable(
 p_subscriber uuid,p_amount numeric,p_as_of date,p_justification text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; new_id uuid;
BEGIN
 actor:=gms_require_role('manager');
 IF p_amount IS NULL OR p_amount=0 OR scale(p_amount)>2 OR
    nullif(trim(p_justification),'') IS NULL THEN
  RAISE EXCEPTION 'Valid signed opening balance and explanation required';
 END IF;
 PERFORM 1 FROM subscribers WHERE id=p_subscriber FOR UPDATE;
 PERFORM gms_reconcile_account(p_subscriber);
 INSERT INTO opening_receivables(subscriber_id,signed_amount_ils,as_of,justification,approved_by)
 VALUES(p_subscriber,p_amount,p_as_of,p_justification,actor) RETURNING id INTO new_id;
 INSERT INTO ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils)
 VALUES(p_subscriber,'opening_receivable',new_id,p_amount);
 PERFORM gms_reconcile_account(p_subscriber);
 RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION gms_record_payment(
 p_subscriber uuid,p_amount numeric,p_paid_at timestamptz,
 p_method text,p_receipt_no text,p_idempotency uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; prev record; new_id uuid;
BEGIN
 actor:=gms_require_role('manager');
 IF p_amount IS NULL OR p_amount<=0 OR scale(p_amount)>2 OR
   p_paid_at IS NULL OR p_method NOT IN ('cash','bank_transfer','other') OR
   nullif(trim(p_receipt_no),'') IS NULL OR p_idempotency IS NULL THEN
  RAISE EXCEPTION 'Invalid payment parameters';
 END IF;
 PERFORM 1 FROM subscribers WHERE id=p_subscriber FOR UPDATE;
 SELECT * INTO prev FROM payment_receipts WHERE idempotency_key=p_idempotency;
 IF FOUND THEN
  IF prev.subscriber_id<>p_subscriber OR prev.amount_ils<>p_amount
     OR prev.paid_at<>p_paid_at OR prev.payment_method<>p_method
     OR prev.receipt_no<>p_receipt_no THEN
   RAISE EXCEPTION 'Payment idempotency key reused with different payload';
  END IF;
  RETURN prev.id;
 END IF;
 PERFORM gms_reconcile_account(p_subscriber);
 INSERT INTO payment_receipts(subscriber_id,receipt_no,amount_ils,paid_at,
  received_by,payment_method,idempotency_key)
 VALUES(p_subscriber,p_receipt_no,p_amount,p_paid_at,actor,p_method,p_idempotency)
 RETURNING id INTO new_id;
 INSERT INTO ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils)
 VALUES(p_subscriber,'payment',new_id,-p_amount);
 PERFORM gms_reconcile_account(p_subscriber);
 RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION gms_reverse_payment(p_payment_id uuid,p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; payment record; prev uuid; new_id uuid;
BEGIN
 actor:=gms_require_role('manager');
 IF nullif(trim(p_reason),'') IS NULL THEN RAISE EXCEPTION 'Reversal reason required'; END IF;
 SELECT * INTO payment FROM payment_receipts WHERE id=p_payment_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown payment'; END IF;
 PERFORM 1 FROM subscribers WHERE id=payment.subscriber_id FOR UPDATE;
 SELECT id INTO prev FROM payment_reversals WHERE payment_id=p_payment_id;
 IF FOUND THEN RETURN prev; END IF;
 PERFORM gms_reconcile_account(payment.subscriber_id);
 INSERT INTO payment_reversals(payment_id,reversed_by,reason)
 VALUES(p_payment_id,actor,p_reason) RETURNING id INTO new_id;
 INSERT INTO ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils)
 VALUES(payment.subscriber_id,'payment_reversal',new_id,payment.amount_ils);
 PERFORM gms_reconcile_account(payment.subscriber_id);
 RETURN new_id;
END $$;

CREATE OR REPLACE FUNCTION gms_record_adjustment(
 p_subscriber uuid,p_source_cycle uuid,p_target_cycle uuid,
 p_amount numeric,p_reason text,p_idempotency uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; prev record; new_id uuid;
BEGIN
 actor:=gms_require_role('manager');
 IF p_amount IS NULL OR p_amount=0 OR scale(p_amount)>8 OR
   nullif(trim(p_reason),'') IS NULL OR p_idempotency IS NULL THEN
  RAISE EXCEPTION 'Invalid adjustment';
 END IF;
 PERFORM 1 FROM subscribers WHERE id=p_subscriber FOR UPDATE;
 SELECT * INTO prev FROM financial_adjustments WHERE idempotency_key=p_idempotency;
 IF FOUND THEN
  IF prev.subscriber_id<>p_subscriber OR prev.adjustment_ils<>p_amount OR
    prev.description<>p_reason OR prev.source_cycle_id IS DISTINCT FROM p_source_cycle OR
    prev.target_cycle_id IS DISTINCT FROM p_target_cycle THEN
    RAISE EXCEPTION 'Adjustment idempotency key reused with different data';
  END IF;
  RETURN prev.id;
 END IF;
 PERFORM gms_reconcile_account(p_subscriber);
 INSERT INTO financial_adjustments(subscriber_id,source_cycle_id,target_cycle_id,
  adjustment_ils,description,recorded_by,idempotency_key)
 VALUES(p_subscriber,p_source_cycle,p_target_cycle,p_amount,p_reason,actor,p_idempotency)
 RETURNING id INTO new_id;
 INSERT INTO ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils)
 VALUES(p_subscriber,'adjustment',new_id,p_amount);
 PERFORM gms_reconcile_account(p_subscriber);
 RETURN new_id;
END $$;

-- Approval creates the next point in a linear, manager-reviewed chain.
-- Untrusted timestamps, missing photos, invalid assignments are refused.
CREATE OR REPLACE FUNCTION gms_approve_visit(p_visit uuid,p_corrected_value numeric DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; v record; prior record; baseline record;
 v_value numeric; v_prev numeric; v_prev_id uuid; v_base_id uuid;
 v_cycle uuid; v_new uuid; v_review uuid; tz text;
BEGIN
 actor:=gms_require_role('manager');
 SELECT * INTO v FROM field_visits WHERE id=p_visit FOR UPDATE;
 IF NOT FOUND OR v.event_kind<>'reading' OR v.record_status IN ('approved','rejected','unreadable_resolved') THEN
  RAISE EXCEPTION 'No approvable raw reading';
 END IF;
 IF v.timestamp_status NOT IN ('consistent','corrected') THEN
  RAISE EXCEPTION 'Manager must verify captured timestamp';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM visit_photos WHERE visit_id=p_visit AND is_primary AND state='ready') THEN
  RAISE EXCEPTION 'Ready primary photo required';
 END IF;
 v_value:=COALESCE(p_corrected_value,v.reading_value_kwh);
 IF v_value IS NULL OR v_value<0 OR scale(v_value)>2 THEN
  RAISE EXCEPTION 'Invalid reviewed reading precision';
 END IF;
 -- Installation lock serializes approvals across different visits on same meter.
 PERFORM 1 FROM meter_installations WHERE id=v.installation_id FOR UPDATE;
 tz:=COALESCE(NULLIF(current_setting('gms.business_timezone',true),''),'Asia/Gaza');
 SELECT id INTO v_cycle FROM reading_cycles WHERE state='open'
  AND timezone(tz,COALESCE(v.verified_captured_at,v.captured_at_device))::date BETWEEN starts_on AND ends_on;
 IF v_cycle IS NULL THEN RAISE EXCEPTION 'No open cycle for verified visit time'; END IF;
 IF v.task_id IS NOT NULL AND NOT EXISTS (
  SELECT 1 FROM reading_tasks t WHERE t.id=v.task_id AND t.cycle_id=v_cycle
   AND t.subscriber_id=v.subscriber_id AND t.installation_id=v.installation_id) THEN
  RAISE EXCEPTION 'Task relation conflict';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM user_zone_grants g WHERE g.employee_id=v.employee_id
   AND g.zone_id=v.zone_id AND g.valid_from <= v.captured_at_device
   AND (g.valid_until IS NULL OR v.captured_at_device<g.valid_until)) THEN
  RAISE EXCEPTION 'Historical area grant missing: manager must resolve authorization';
 END IF;
 SELECT * INTO prior FROM approved_readings WHERE installation_id=v.installation_id
  AND state='active' ORDER BY verified_captured_at DESC,id DESC LIMIT 1 FOR UPDATE;
 IF FOUND THEN
  v_prev_id:=prior.id;v_base_id:=NULL;v_prev:=prior.current_value_kwh;
  IF prior.verified_captured_at>=COALESCE(v.verified_captured_at,v.captured_at_device) THEN
   RAISE EXCEPTION 'Out of order: reconcile earlier reading first';
  END IF;
 ELSE
  SELECT * INTO baseline FROM opening_baselines WHERE installation_id=v.installation_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Missing opening baseline'; END IF;
  v_base_id:=baseline.id;v_prev_id:=NULL;v_prev:=baseline.opening_value_kwh;
 END IF;
 IF v_value<v_prev THEN RAISE EXCEPTION 'Lower reading requires separate manager incident review'; END IF;
 INSERT INTO visit_reviews(visit_id,reviewed_by,decision,corrected_value_kwh,rationale)
 VALUES(p_visit,actor,CASE WHEN p_corrected_value IS NULL THEN 'approve_reading' ELSE 'correct_reading' END,
  p_corrected_value,CASE WHEN p_corrected_value IS NULL THEN NULL ELSE 'Manager-verified image correction' END)
 RETURNING id INTO v_review;
 INSERT INTO approved_readings(visit_id,review_id,subscriber_id,installation_id,cycle_id,
   opening_baseline_id,previous_approved_id,previous_value_kwh,current_value_kwh,verified_captured_at)
 VALUES(p_visit,v_review,v.subscriber_id,v.installation_id,v_cycle,
   v_base_id,v_prev_id,v_prev,v_value,COALESCE(v.verified_captured_at,v.captured_at_device))
 RETURNING id INTO v_new;
 UPDATE field_visits SET record_status='approved' WHERE id=p_visit;
 IF v.task_id IS NOT NULL THEN
  UPDATE reading_tasks SET status='completed_reading' WHERE id=v.task_id;
 END IF;
 RETURN v_new;
END $$;

-- Manager chooses next follow-up date after an unreadable event.
CREATE OR REPLACE FUNCTION gms_resolve_unreadable(p_visit uuid,p_followup_due date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; v record; new_review uuid;
BEGIN
 actor:=gms_require_role('manager');
 SELECT * INTO v FROM field_visits WHERE id=p_visit FOR UPDATE;
 IF NOT FOUND OR v.event_kind<>'unreadable' OR v.record_status IN ('unreadable_resolved','approved') THEN
  RAISE EXCEPTION 'No unreadable case to resolve';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM visit_photos WHERE visit_id=p_visit AND state='ready' AND is_primary) THEN
  RAISE EXCEPTION 'Photo is mandatory even when unreadable';
 END IF;
 IF p_followup_due IS NULL THEN RAISE EXCEPTION 'Manager must select follow-up date'; END IF;
 INSERT INTO visit_reviews(visit_id,reviewed_by,decision,rationale)
 VALUES(p_visit,actor,'approve_unreadable','Closed without consumption; follow-up due '||p_followup_due)
 RETURNING id INTO new_review;
 UPDATE field_visits SET record_status='unreadable_resolved' WHERE id=p_visit;
 IF v.task_id IS NOT NULL THEN
  UPDATE reading_tasks SET status='completed_unreadable' WHERE id=v.task_id;
 END IF;
 INSERT INTO subscriber_schedules(subscriber_id,interval_days,next_due_override,changed_by)
 SELECT v.subscriber_id,COALESCE((SELECT interval_days FROM subscriber_schedules WHERE subscriber_id=v.subscriber_id),7),
    p_followup_due,actor
 ON CONFLICT(subscriber_id) DO UPDATE SET next_due_override=EXCLUDED.next_due_override,
  changed_by=EXCLUDED.changed_by,changed_at=now();
 RETURN new_review;
END $$;

-- Finalization uses exact ledger balance; charge exact amount ONCE and leave
-- the sub-shekel remainder in signed ledger balance (never double-carry).
CREATE OR REPLACE FUNCTION gms_finalize_cycle(p_cycle uuid,p_rate numeric)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; c record; s record; new_statement uuid;
  n integer:=0; charge numeric; opening_balance numeric; closing_balance numeric;
  v_revision integer;
BEGIN
 actor:=gms_require_role('manager');
 IF p_rate IS NULL OR p_rate<0 OR scale(p_rate)>6 THEN
  RAISE EXCEPTION 'Final rate must have at most six decimal places';
 END IF;
 -- Enforce global lock order; prevents concurrent close/rate edits.
 PERFORM pg_advisory_xact_lock(6202201);
 SELECT * INTO c FROM reading_cycles WHERE id=p_cycle FOR UPDATE;
 IF NOT FOUND OR c.state<>'open' THEN RAISE EXCEPTION 'Cycle is not open'; END IF;
 IF EXISTS(SELECT 1 FROM reading_tasks WHERE cycle_id=p_cycle AND status NOT IN
    ('completed_reading','completed_unreadable','cancelled')) THEN
  RAISE EXCEPTION 'Unresolved reading tasks block closure';
 END IF;
 IF EXISTS(SELECT 1 FROM field_visits v JOIN reading_tasks t ON t.id=v.task_id
  WHERE t.cycle_id=p_cycle AND v.record_status NOT IN ('approved','rejected','unreadable_resolved')) THEN
  RAISE EXCEPTION 'Pending field review blocks closure';
 END IF;
 IF EXISTS(SELECT 1 FROM statement_versions WHERE cycle_id=p_cycle AND state='final') THEN
  RAISE EXCEPTION 'Cycle already has finalized statements';
 END IF;
 -- Snapshot manager-selected final rate in the same atomic transaction.
 INSERT INTO cycle_price_decisions(cycle_id,provisional_rate_ils_per_kwh,
  final_rate_ils_per_kwh,final_selected_by,finalized_at)
 VALUES(p_cycle,p_rate,p_rate,actor,now())
 ON CONFLICT(cycle_id) DO UPDATE SET
  final_rate_ils_per_kwh=EXCLUDED.final_rate_ils_per_kwh,
  final_selected_by=EXCLUDED.final_selected_by,finalized_at=EXCLUDED.finalized_at;
 FOR s IN SELECT DISTINCT subscriber_id FROM approved_readings
   WHERE cycle_id=p_cycle AND state='active' ORDER BY subscriber_id LOOP
  PERFORM 1 FROM subscribers WHERE id=s.subscriber_id FOR UPDATE;
  INSERT INTO billing_accounts(subscriber_id) VALUES(s.subscriber_id)
  ON CONFLICT(subscriber_id) DO NOTHING;
  PERFORM 1 FROM billing_accounts WHERE subscriber_id=s.subscriber_id FOR UPDATE;
  opening_balance:=gms_ledger_balance(s.subscriber_id);
  SELECT COALESCE(sum(consumption_kwh),0)*p_rate INTO charge FROM approved_readings
    WHERE cycle_id=p_cycle AND subscriber_id=s.subscriber_id AND state='active';
  charge:=round(charge,8);
  closing_balance:=opening_balance+charge;
  SELECT COALESCE(max(revision),0)+1 INTO v_revision FROM statement_versions
    WHERE subscriber_id=s.subscriber_id AND cycle_id=p_cycle;
  INSERT INTO statement_versions(
    subscriber_id,cycle_id,revision,state,provisional,rate_snapshot_ils_per_kwh,
    charge_exact_ils,carry_in_ils,credits_in_ils,adjustments_ils,net_exact_ils,
    requested_whole_ils,carry_out_ils,credits_out_ils,
    opening_ledger_balance_ils,closing_ledger_balance_ils,finalized_at)
  VALUES(s.subscriber_id,p_cycle,v_revision,'final',false,p_rate,charge,
    CASE WHEN opening_balance>0 THEN opening_balance-trunc(opening_balance) ELSE 0 END,
    greatest(0,-opening_balance),0,closing_balance,
    greatest(0,trunc(closing_balance)),
    CASE WHEN closing_balance>0 THEN closing_balance-trunc(closing_balance) ELSE 0 END,
    greatest(0,-closing_balance),opening_balance,closing_balance,now())
  RETURNING id INTO new_statement;
  INSERT INTO statement_reading_lines(statement_id,approved_reading_id,consumption_kwh,
    rate_snapshot,exact_charge_ils)
  SELECT new_statement,id,consumption_kwh,p_rate,round(consumption_kwh*p_rate,8)
  FROM approved_readings WHERE subscriber_id=s.subscriber_id AND cycle_id=p_cycle AND state='active';
  INSERT INTO final_reading_allocations(approved_reading_id,statement_id)
  SELECT approved_reading_id,new_statement FROM statement_reading_lines
   WHERE statement_id=new_statement;
  IF charge<>0 THEN
   INSERT INTO ledger_entries(subscriber_id,source_type,source_id,signed_amount_ils)
   VALUES(s.subscriber_id,'final_statement',new_statement,charge);
  END IF;
  PERFORM gms_reconcile_account(s.subscriber_id);
  UPDATE billing_accounts SET last_finalized_cycle_id=p_cycle WHERE subscriber_id=s.subscriber_id;
  n:=n+1;
 END LOOP;
 UPDATE reading_cycles SET state='closed',closed_by=actor,closed_at=now()
 WHERE id=p_cycle;
 RETURN n;
END $$;



-- Device sync: return value is (accepted/already_received/conflict).
-- p_payload_sha256 is calculated over a canonical payload BY THE TRUSTED API,
-- not merely accepted from an untrusted client header.
CREATE OR REPLACE FUNCTION gms_receive_visit(
 p_operation uuid, p_visit uuid, p_device uuid, p_payload jsonb, p_sha char(64))
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; oldop record; oldvisit record;
 v_sub uuid; v_inst uuid; v_zone uuid; v_task uuid;
 v_kind text; v_reading numeric; v_reason text; v_cap timestamptz;
 v_offset integer; v_status text; v_actor uuid;
BEGIN
 actor:=gms_require_role('employee');
 IF p_operation IS NULL OR p_visit IS NULL OR p_device IS NULL OR p_payload IS NULL OR
   p_sha IS NULL OR p_sha !~ '^[0-9a-fA-F]{64}$' THEN
  RAISE EXCEPTION 'Invalid sync envelope';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM mobile_devices d WHERE d.id=p_device AND d.employee_id=actor AND d.is_active) THEN
  RAISE EXCEPTION 'Device no longer authorized';
 END IF;
 SELECT * INTO oldop FROM sync_operations WHERE operation_id=p_operation FOR UPDATE;
 IF FOUND THEN
  IF oldop.employee_id=actor AND oldop.device_id=p_device AND oldop.payload_sha256=p_sha
    AND oldop.visit_id IS NOT DISTINCT FROM p_visit THEN
   RETURN 'already_received';
  ELSE RETURN 'conflict'; END IF;
 END IF;
 SELECT * INTO oldvisit FROM field_visits WHERE id=p_visit;
 IF FOUND THEN
  IF oldvisit.employee_id=actor AND oldvisit.device_id=p_device AND oldvisit.device_payload_sha256=p_sha
  THEN RETURN 'already_received'; ELSE RETURN 'conflict'; END IF;
 END IF;
 v_sub:=(p_payload->>'subscriber_id')::uuid;
 v_inst:=(p_payload->>'installation_id')::uuid;
 v_zone:=(p_payload->>'zone_id')::uuid;
 v_task:=NULLIF(p_payload->>'task_id','')::uuid;
 v_kind:=p_payload->>'event_kind';
 v_reading:=NULLIF(p_payload->>'reading_value_kwh','')::numeric;
 v_reason:=p_payload->>'reason';
 v_cap:=(p_payload->>'captured_at_device')::timestamptz;
 v_offset:=(p_payload->>'captured_offset_minutes')::integer;
 IF NOT EXISTS(SELECT 1 FROM meter_installations i WHERE i.id=v_inst AND i.subscriber_id=v_sub) THEN
  RAISE EXCEPTION 'Unknown installation for subscriber';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM subscribers s WHERE s.id=v_sub AND s.zone_id=v_zone) THEN
  RAISE EXCEPTION 'Subscriber zone mismatch';
 END IF;
 -- Preserve data captured under a stale offline assignment, but flag it.
 v_status:='awaiting_photo';
 IF NOT EXISTS(SELECT 1 FROM user_zone_grants g WHERE g.employee_id=actor AND g.zone_id=v_zone
  AND g.valid_from <= v_cap AND (g.valid_until IS NULL OR v_cap<g.valid_until)) OR
    (v_task IS NOT NULL AND NOT EXISTS(SELECT 1 FROM reading_tasks t WHERE t.id=v_task
     AND t.subscriber_id=v_sub AND t.installation_id=v_inst AND t.assigned_employee_id=actor))
  THEN v_status:='exception'; END IF;
 -- Base field_visits is immutable on arrival; photo is uploaded separately.
 INSERT INTO field_visits(id,task_id,subscriber_id,installation_id,zone_id,employee_id,
   device_id,event_kind,reading_value_kwh,reason,captured_at_device,
   captured_offset_minutes,record_status,device_payload_sha256)
 VALUES(p_visit,v_task,v_sub,v_inst,v_zone,actor,p_device,v_kind,v_reading,v_reason,
  v_cap,v_offset,v_status,p_sha);
 INSERT INTO sync_operations(operation_id,employee_id,device_id,visit_id,payload_sha256,result_code)
 VALUES(p_operation,actor,p_device,p_visit,p_sha,'accepted');
 RETURN 'accepted';
END $$;

-- Trusted API registers image metadata only after validating object-storage
-- access, MIME signature, content checksum, and durable upload confirmation.
CREATE OR REPLACE FUNCTION gms_register_ready_photo(
 p_visit uuid,p_object_key text,p_sha char(64),p_size bigint,
 p_content_type text,p_primary boolean)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; v record; photo_id uuid;
BEGIN
 actor:=gms_require_role('employee');
 SELECT * INTO v FROM field_visits WHERE id=p_visit;
 IF NOT FOUND OR v.employee_id<>actor THEN RAISE EXCEPTION 'Visit not owned by employee'; END IF;
 IF p_size<=0 OR p_object_key IS NULL OR p_sha !~ '^[0-9a-fA-F]{64}$' THEN
  RAISE EXCEPTION 'Invalid photo metadata'; END IF;
 INSERT INTO visit_photos(visit_id,object_key,sha256_hex,size_bytes,content_type,
   state,is_primary,ready_at)
 VALUES(p_visit,p_object_key,p_sha,p_size,p_content_type,'ready',p_primary,now())
 RETURNING id INTO photo_id;
 RETURN photo_id;
END $$;

-- This is a manager adjudication decision, not proof that device time was true.
CREATE OR REPLACE FUNCTION gms_verify_capture_time(
 p_visit uuid,p_verified_at timestamptz,p_corrected boolean,p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE actor uuid; original record;
BEGIN
 actor:=gms_require_role('manager');
 SELECT * INTO original FROM field_visits WHERE id=p_visit FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Visit not found'; END IF;
 IF p_verified_at IS NULL OR (p_corrected AND nullif(trim(p_reason),'') IS NULL) THEN
  RAISE EXCEPTION 'Verified timestamp and reason for correction required';
 END IF;
 UPDATE field_visits SET verified_captured_at=p_verified_at,
   timestamp_status=CASE WHEN p_corrected THEN 'corrected' ELSE 'consistent' END
 WHERE id=p_visit;
 IF p_corrected THEN
  INSERT INTO visit_reviews(visit_id,reviewed_by,decision,corrected_capture_at,rationale)
   VALUES(p_visit,actor,'correct_timestamp',p_verified_at,p_reason);
 END IF;
END $$;

-- Functions created after the initial hardening pass also lose PUBLIC EXECUTE.
-- DBA must grant narrowly scoped EXECUTE rights to the trusted backend role.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
COMMIT;
