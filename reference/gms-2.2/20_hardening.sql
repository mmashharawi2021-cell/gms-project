-- GMS 2.2 | Integrity & authorization hardening | clean PostgreSQL 16+ DB only.
-- NOT an in-place migration. Install 10_baseline.sql first.
BEGIN;

-- Client readings need exact two decimal places WITHOUT PostgreSQL silently rounding
-- before CHECK evaluation. All raw-reading columns in 10_baseline.sql are `numeric`
-- with no precision/scale typmod: scale() sees the submitted decimal places.
ALTER TABLE opening_baselines ADD CONSTRAINT ck_gms_opening_decimal
 CHECK (scale(opening_value_kwh) <= 2 AND opening_value_kwh < 100000000000000);
ALTER TABLE field_visits ADD CONSTRAINT ck_gms_field_decimal
 CHECK (reading_value_kwh IS NULL OR (scale(reading_value_kwh) <= 2 AND reading_value_kwh < 100000000000000));
ALTER TABLE visit_reviews ADD CONSTRAINT ck_gms_review_decimal
 CHECK (corrected_value_kwh IS NULL OR (corrected_value_kwh >= 0 AND scale(corrected_value_kwh) <= 2));
ALTER TABLE approved_readings ADD CONSTRAINT ck_gms_approved_decimal
 CHECK (scale(previous_value_kwh) <= 2 AND scale(current_value_kwh) <= 2);
ALTER TABLE statement_reading_lines ADD CONSTRAINT ck_gms_line_decimal
 CHECK (scale(consumption_kwh) <= 2);

-- Global weekly price: exactly one open cycle, with audited manager close.
CREATE UNIQUE INDEX ux_gms_one_open_cycle ON reading_cycles ((true)) WHERE state = 'open';
ALTER TABLE reading_cycles ADD CONSTRAINT ck_gms_closed_actor
 CHECK ((state='closed') = (closed_by IS NOT NULL));
ALTER TABLE reading_cycles ADD CONSTRAINT ck_gms_closed_time
 CHECK ((state='closed') = (closed_at IS NOT NULL));
ALTER TABLE reading_tasks ADD COLUMN cancel_reason text;
ALTER TABLE reading_tasks ADD CONSTRAINT ck_gms_cancelled_reason_or_time
 CHECK (status <> 'cancelled' OR (cancelled_at IS NOT NULL AND nullif(trim(cancel_reason),'') IS NOT NULL));

-- Track initial pre-system receivables/credits separately from real payments.
CREATE TABLE opening_receivables (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL UNIQUE REFERENCES subscribers(id),
 signed_amount_ils numeric(28,8) NOT NULL CHECK (signed_amount_ils<>0),
 as_of date NOT NULL,
 justification text NOT NULL CHECK(length(trim(justification))>0),
 approved_by uuid NOT NULL REFERENCES app_users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE ledger_entries DROP CONSTRAINT ledger_entries_source_type_check;
ALTER TABLE ledger_entries ADD CONSTRAINT ledger_entries_source_type_check
 CHECK(source_type IN ('opening_receivable','final_statement','payment','payment_reversal','adjustment'));

-- A final approved reading may appear on ONE final statement only.
-- Draft preview lines can be regenerated; final allocation is append-only.
CREATE TABLE final_reading_allocations (
 approved_reading_id uuid PRIMARY KEY REFERENCES approved_readings(id),
 statement_id uuid NOT NULL REFERENCES statement_versions(id),
 allocated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_gms_final_allocations_statement ON final_reading_allocations(statement_id);

-- Weekly statements are snapshots of the customer's exact ledger, not payments.
-- The ledger stores FULL exact charges; fractions carry automatically as part
-- of the outstanding signed balance. Avoid separately adding cached carries.
ALTER TABLE statement_versions
 ADD COLUMN opening_ledger_balance_ils numeric(28,8) NOT NULL DEFAULT 0,
 ADD COLUMN closing_ledger_balance_ils numeric(28,8) NOT NULL DEFAULT 0;
ALTER TABLE statement_versions ADD CONSTRAINT ck_gms_final_math CHECK (
 state <> 'final' OR (
  net_exact_ils = closing_ledger_balance_ils
  AND closing_ledger_balance_ils = opening_ledger_balance_ils + charge_exact_ils
  AND requested_whole_ils = GREATEST(0,trunc(closing_ledger_balance_ils))
  AND carry_out_ils = CASE WHEN closing_ledger_balance_ils>0
     THEN closing_ledger_balance_ils-trunc(closing_ledger_balance_ils) ELSE 0 END
  AND credits_out_ils = GREATEST(0,-closing_ledger_balance_ils)
  AND carry_in_ils = CASE WHEN opening_ledger_balance_ils>0
     THEN opening_ledger_balance_ils-trunc(opening_ledger_balance_ils) ELSE 0 END
  AND credits_in_ils = GREATEST(0,-opening_ledger_balance_ils)
  AND provisional=false
  AND finalized_at IS NOT NULL
  AND rate_snapshot_ils_per_kwh >= 0
  ));

CREATE OR REPLACE FUNCTION gms_actor_id() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
 v:=nullif(current_setting('gms.actor_id',true),'');
 IF v IS NULL THEN RAISE EXCEPTION 'Missing authenticated gms.actor_id context'; END IF;
 RETURN v::uuid;
EXCEPTION WHEN invalid_text_representation THEN
 RAISE EXCEPTION 'Malformed gms.actor_id context';
END $$;

CREATE OR REPLACE FUNCTION gms_require_role(p_role text) RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v uuid;
BEGIN
 v:=gms_actor_id();
 IF NOT EXISTS(SELECT 1 FROM app_users WHERE id=v AND role=p_role AND is_active) THEN
  RAISE EXCEPTION 'GMS authorization denied: role % required',p_role;
 END IF;
 RETURN v;
END $$;

CREATE OR REPLACE FUNCTION gms_manager_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM gms_require_role('manager');
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;

-- Enforcement at database trigger boundary IN ADDITION to trusted API auth.
DO $$ DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY[
  'reading_cycles','cycle_price_decisions','tariff_change_events',
  'visit_reviews','approved_readings','statement_versions',
  'statement_reading_lines','final_reading_allocations',
  'financial_adjustments','payment_receipts','payment_reversals',
  'ledger_entries','opening_receivables','mobile_devices',
  'user_zone_grants','meter_installations','opening_baselines','reading_tasks'
 ] LOOP
  EXECUTE format('CREATE TRIGGER %I BEFORE INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION gms_manager_guard()',
      'trg_gms_manager_'||t,t);
 END LOOP;
END $$;

CREATE OR REPLACE FUNCTION gms_guard_immutable_visits() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Cannot delete a captured field visit'; END IF;
 IF (OLD.id,OLD.task_id,OLD.subscriber_id,OLD.installation_id,OLD.zone_id,
     OLD.employee_id,OLD.device_id,OLD.event_kind,OLD.reading_value_kwh,
     OLD.reason,OLD.captured_at_device,OLD.captured_offset_minutes,
     OLD.received_at,OLD.device_payload_sha256)
  IS DISTINCT FROM
    (NEW.id,NEW.task_id,NEW.subscriber_id,NEW.installation_id,NEW.zone_id,
     NEW.employee_id,NEW.device_id,NEW.event_kind,NEW.reading_value_kwh,
     NEW.reason,NEW.captured_at_device,NEW.captured_offset_minutes,
     NEW.received_at,NEW.device_payload_sha256) THEN
  RAISE EXCEPTION 'Captured field visit content is immutable';
 END IF;
 PERFORM gms_require_role('manager');
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_immutable_visits BEFORE UPDATE OR DELETE ON field_visits
 FOR EACH ROW EXECUTE FUNCTION gms_guard_immutable_visits();

CREATE OR REPLACE FUNCTION gms_guard_approved() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Approved readings cannot be deleted'; END IF;
 IF (to_jsonb(NEW)-'state') IS DISTINCT FROM (to_jsonb(OLD)-'state') THEN
  RAISE EXCEPTION 'Approved reading values cannot be changed';
 END IF;
 IF OLD.state<>'active' OR NEW.state NOT IN ('superseded','voided') THEN
  RAISE EXCEPTION 'Invalid approved reading state transition';
 END IF;
 IF EXISTS(SELECT 1 FROM approved_readings r WHERE r.previous_approved_id=OLD.id AND r.state='active') THEN
  RAISE EXCEPTION 'Cannot supersede chain predecessor without full reconciliation';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_approved_append_only BEFORE UPDATE OR DELETE ON approved_readings
 FOR EACH ROW EXECUTE FUNCTION gms_guard_approved();

CREATE OR REPLACE FUNCTION gms_guard_statement() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Statement versions cannot be deleted'; END IF;
 IF OLD.state='final' THEN RAISE EXCEPTION 'Final statement is immutable'; END IF;
 IF NEW.state='final' THEN RAISE EXCEPTION 'Final statements must be created as final through an atomic close'; END IF;
 IF OLD.state='superseded' AND NEW.state <> 'superseded' THEN
  RAISE EXCEPTION 'Superseded statements cannot be reactivated';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_statement_protection BEFORE UPDATE OR DELETE ON statement_versions
 FOR EACH ROW EXECUTE FUNCTION gms_guard_statement();

CREATE OR REPLACE FUNCTION gms_guard_cycle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Cycles cannot be deleted'; END IF;
 IF OLD.state='closed' THEN RAISE EXCEPTION 'Closed cycle is immutable'; END IF;
 IF (OLD.starts_on,OLD.ends_on) IS DISTINCT FROM (NEW.starts_on,NEW.ends_on)
 AND EXISTS(SELECT 1 FROM reading_tasks WHERE cycle_id=OLD.id) THEN
  RAISE EXCEPTION 'Cycle dates locked after task allocation';
 END IF;
 IF NEW.state='closed' THEN
  IF NEW.closed_by IS NULL OR NEW.closed_at IS NULL THEN RAISE EXCEPTION 'Closing manager and time required'; END IF;
  IF NOT EXISTS(SELECT 1 FROM cycle_price_decisions cp WHERE cp.cycle_id=NEW.id
      AND cp.finalized_at IS NOT NULL) THEN
      RAISE EXCEPTION 'Cannot close without final rate';
  END IF;
  IF EXISTS (SELECT 1 FROM reading_tasks WHERE cycle_id=NEW.id AND status NOT IN
      ('completed_reading','completed_unreadable','cancelled')) THEN
      RAISE EXCEPTION 'Cannot close cycle: unresolved tasks';
  END IF;
  IF EXISTS(SELECT 1 FROM field_visits v JOIN reading_tasks t ON t.id=v.task_id
      WHERE t.cycle_id=NEW.id AND v.record_status NOT IN
      ('approved','rejected','unreadable_resolved')) THEN
      RAISE EXCEPTION 'Cannot close cycle: unresolved visits';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_cycle_lock BEFORE UPDATE OR DELETE ON reading_cycles
 FOR EACH ROW EXECUTE FUNCTION gms_guard_cycle();

CREATE OR REPLACE FUNCTION gms_guard_price_decision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='DELETE' THEN RAISE EXCEPTION 'Cycle pricing cannot be deleted'; END IF;
 IF OLD.finalized_at IS NOT NULL THEN RAISE EXCEPTION 'Final rate cannot be changed'; END IF;
 IF EXISTS(SELECT 1 FROM reading_cycles c WHERE c.id=OLD.cycle_id AND c.state='closed') THEN
  RAISE EXCEPTION 'Cannot change pricing on a closed cycle';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_price_lock BEFORE UPDATE OR DELETE ON cycle_price_decisions
 FOR EACH ROW EXECUTE FUNCTION gms_guard_price_decision();

CREATE OR REPLACE FUNCTION gms_price_date_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM reading_cycles c WHERE c.id=NEW.cycle_id
 AND NEW.effective_on BETWEEN c.starts_on AND c.ends_on AND c.state IN ('draft','open')) THEN
  RAISE EXCEPTION 'Price change date must be within an unlocked cycle';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_price_date BEFORE INSERT ON tariff_change_events
 FOR EACH ROW EXECUTE FUNCTION gms_price_date_guard();

CREATE OR REPLACE FUNCTION gms_check_approved_insert() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v record; r record; b record; p record; tz text;
BEGIN
 SELECT * INTO v FROM field_visits WHERE id=NEW.visit_id;
 SELECT * INTO r FROM visit_reviews WHERE id=NEW.review_id;
 IF NOT FOUND OR r.visit_id IS DISTINCT FROM NEW.visit_id
   OR r.decision NOT IN ('approve_reading','correct_reading') THEN
  RAISE EXCEPTION 'Matching manager approval review required';
 END IF;
 IF v.event_kind<>'reading' OR v.installation_id<>NEW.installation_id OR v.subscriber_id<>NEW.subscriber_id THEN
  RAISE EXCEPTION 'Approved reading does not match field visit';
 END IF;
 IF v.timestamp_status NOT IN ('consistent','corrected') THEN
  RAISE EXCEPTION 'Unverified timestamp cannot be approved';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM visit_photos p WHERE p.visit_id=v.id AND p.state='ready' AND p.is_primary) THEN
  RAISE EXCEPTION 'At least one ready primary image is mandatory';
 END IF;
 IF NEW.current_value_kwh IS DISTINCT FROM COALESCE(r.corrected_value_kwh,v.reading_value_kwh) THEN
  RAISE EXCEPTION 'Approved current value must match reviewed value';
 END IF;
 IF NEW.verified_captured_at IS DISTINCT FROM COALESCE(r.corrected_capture_at,v.verified_captured_at,v.captured_at_device) THEN
  RAISE EXCEPTION 'Approved timestamp does not match reviewed timestamp';
 END IF;
 tz:=COALESCE(NULLIF(current_setting('gms.business_timezone',true),''),'Asia/Gaza');
 IF NOT EXISTS(SELECT 1 FROM reading_cycles c WHERE c.id=NEW.cycle_id
  AND c.state='open' AND timezone(tz,NEW.verified_captured_at)::date BETWEEN c.starts_on AND c.ends_on) THEN
  RAISE EXCEPTION 'Reading must belong to the open pricing cycle of its verified capture date';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM meter_installations i WHERE i.id=NEW.installation_id
  AND i.subscriber_id=NEW.subscriber_id AND i.installed_at<=NEW.verified_captured_at
  AND (i.removed_at IS NULL OR i.removed_at>NEW.verified_captured_at)) THEN
  RAISE EXCEPTION 'Installation not active at verified capture time';
 END IF;
 IF EXISTS(SELECT 1 FROM approved_readings a WHERE a.installation_id=NEW.installation_id
  AND a.state='active' AND a.verified_captured_at>=NEW.verified_captured_at) THEN
  RAISE EXCEPTION 'Cannot approve an out-of-order/tied reading';
 END IF;
 IF NEW.opening_baseline_id IS NOT NULL THEN
  SELECT * INTO b FROM opening_baselines WHERE id=NEW.opening_baseline_id;
  IF NOT FOUND OR b.installation_id<>NEW.installation_id
   OR b.opening_value_kwh<>NEW.previous_value_kwh
   OR EXISTS(SELECT 1 FROM approved_readings a WHERE a.installation_id=NEW.installation_id AND a.state='active') THEN
   RAISE EXCEPTION 'Invalid opening reading reference';
  END IF;
 ELSE
  SELECT * INTO p FROM approved_readings WHERE id=NEW.previous_approved_id AND state='active';
  IF NOT FOUND OR p.installation_id<>NEW.installation_id OR p.subscriber_id<>NEW.subscriber_id
     OR p.current_value_kwh<>NEW.previous_value_kwh
     OR p.verified_captured_at>=NEW.verified_captured_at THEN
   RAISE EXCEPTION 'Previous approved reading chain mismatch';
  END IF;
  IF EXISTS (SELECT 1 FROM approved_readings a WHERE a.installation_id=NEW.installation_id
   AND a.state='active' AND a.verified_captured_at>p.verified_captured_at) THEN
   RAISE EXCEPTION 'Previous reading is not the current chain head';
  END IF;
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_approved_validate BEFORE INSERT ON approved_readings
 FOR EACH ROW EXECUTE FUNCTION gms_check_approved_insert();

CREATE OR REPLACE FUNCTION gms_check_statement_line() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s record; a record;
BEGIN
 SELECT * INTO s FROM statement_versions WHERE id=NEW.statement_id;
 SELECT * INTO a FROM approved_readings WHERE id=NEW.approved_reading_id;
 IF NOT FOUND OR s.id IS NULL OR a.state<>'active' OR a.subscriber_id<>s.subscriber_id
   OR a.cycle_id<>s.cycle_id OR a.consumption_kwh<>NEW.consumption_kwh
   OR NEW.rate_snapshot<>s.rate_snapshot_ils_per_kwh OR
   NOT EXISTS(SELECT 1 FROM reading_cycles c WHERE c.id=s.cycle_id AND c.state='open') THEN
  RAISE EXCEPTION 'Statement line has invalid subscriber, cycle, reading, or price';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_statement_line_validate BEFORE INSERT ON statement_reading_lines
 FOR EACH ROW EXECUTE FUNCTION gms_check_statement_line();

CREATE OR REPLACE FUNCTION gms_check_final_allocation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM statement_versions s JOIN approved_readings a
  ON a.subscriber_id=s.subscriber_id AND a.cycle_id=s.cycle_id
  WHERE s.id=NEW.statement_id AND s.state='final' AND a.id=NEW.approved_reading_id AND a.state='active') THEN
  RAISE EXCEPTION 'Final allocation must reference a valid final statement and active reading';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM statement_reading_lines l
  WHERE l.statement_id=NEW.statement_id AND l.approved_reading_id=NEW.approved_reading_id) THEN
  RAISE EXCEPTION 'Missing detailed line for final allocation';
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_allocation_guard BEFORE INSERT ON final_reading_allocations
 FOR EACH ROW EXECUTE FUNCTION gms_check_final_allocation();
CREATE TRIGGER trg_gms_allocations_append_only BEFORE UPDATE OR DELETE ON final_reading_allocations
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_opening_receivables_append_only BEFORE UPDATE OR DELETE ON opening_receivables
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();

CREATE OR REPLACE FUNCTION gms_check_ledger_source() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE valid_source boolean := false;
BEGIN
 CASE NEW.source_type
 WHEN 'final_statement' THEN
  SELECT EXISTS(SELECT 1 FROM statement_versions s WHERE s.id=NEW.source_id
   AND s.subscriber_id=NEW.subscriber_id AND s.state='final'
   AND s.charge_exact_ils=NEW.signed_amount_ils) INTO valid_source;
 WHEN 'payment' THEN
  SELECT EXISTS(SELECT 1 FROM payment_receipts p WHERE p.id=NEW.source_id
   AND p.subscriber_id=NEW.subscriber_id AND NEW.signed_amount_ils=-p.amount_ils) INTO valid_source;
 WHEN 'payment_reversal' THEN
  SELECT EXISTS(SELECT 1 FROM payment_reversals r JOIN payment_receipts p ON p.id=r.payment_id
   WHERE r.id=NEW.source_id AND p.subscriber_id=NEW.subscriber_id
     AND NEW.signed_amount_ils=p.amount_ils) INTO valid_source;
 WHEN 'adjustment' THEN
  SELECT EXISTS(SELECT 1 FROM financial_adjustments a WHERE a.id=NEW.source_id
   AND a.subscriber_id=NEW.subscriber_id AND a.adjustment_ils=NEW.signed_amount_ils) INTO valid_source;
 WHEN 'opening_receivable' THEN
  SELECT EXISTS(SELECT 1 FROM opening_receivables o WHERE o.id=NEW.source_id
   AND o.subscriber_id=NEW.subscriber_id AND o.signed_amount_ils=NEW.signed_amount_ils) INTO valid_source;
 END CASE;
 IF NOT valid_source THEN RAISE EXCEPTION 'Invalid ledger source or amount'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER trg_gms_ledger_valid_source BEFORE INSERT ON ledger_entries
 FOR EACH ROW EXECUTE FUNCTION gms_check_ledger_source();

-- Document sensitive state changes automatically; base audit_logs is append-only.
CREATE OR REPLACE FUNCTION gms_audit_transition() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE actor uuid;
BEGIN
 actor:=NULLIF(current_setting('gms.actor_id',true),'')::uuid;
 INSERT INTO audit_logs(actor_id,action_code,entity_type,entity_id,before_data,after_data)
 VALUES(actor,'DB_'||TG_OP,TG_TABLE_NAME,COALESCE(NEW.id,OLD.id),
  CASE WHEN TG_OP='INSERT' THEN NULL ELSE to_jsonb(OLD) END,
  CASE WHEN TG_OP='DELETE' THEN NULL ELSE to_jsonb(NEW) END);
 RETURN COALESCE(NEW,OLD);
END $$;
-- Avoid tables whose PK is not `id`; audit them explicitly in business functions.
DO $$ DECLARE t text;
BEGIN
 FOREACH t IN ARRAY ARRAY['reading_cycles','approved_readings','statement_versions',
   'field_visits','reading_tasks','payment_receipts','payment_reversals',
   'financial_adjustments','mobile_devices','subscriber_schedules','subscribers'] LOOP
   IF t <> 'subscriber_schedules' THEN
    EXECUTE format('CREATE TRIGGER %I AFTER INSERT OR UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION gms_audit_transition()',
     'trg_gms_audit_'||t,t);
   END IF;
 END LOOP;
END $$;

-- Keep historically approved statement lines immutable even when someone obtains
-- an elevated connection; append them only while the cycle is open.
CREATE TRIGGER trg_gms_statement_line_lock BEFORE UPDATE OR DELETE ON statement_reading_lines
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();

-- No application database login may write to tables directly. Backend must
-- authenticate the actual human and set gms.actor_id in a transaction on a
-- trusted connection BEFORE invoking restricted stored functions.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
COMMIT;
