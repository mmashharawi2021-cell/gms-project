-- GMS | PostgreSQL 16+ | revised physical baseline 2.2 (unverified on live PostgreSQL)
-- 2026-11-14 | DRAFT, NOT TESTED OR SAFE TO RUN IN PRODUCTION.
-- No migrations from v2.0 are supplied; this is a new baseline for review.
-- CRITICAL: server-side atomic business functions, authorization, historical
-- financial reconciliation, complete photo controls, and integration tests
-- must be implemented before any real monetary posting or production launch.
BEGIN;

CREATE TABLE app_users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 username text NOT NULL UNIQUE,
 password_hash text NOT NULL,
 full_name text NOT NULL,
 role text NOT NULL CHECK (role IN ('manager','employee')),
 is_active boolean NOT NULL DEFAULT true,
 must_change_password boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE mobile_devices (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 employee_id uuid NOT NULL REFERENCES app_users(id),
 device_label text NOT NULL,
 public_key text,
 is_active boolean NOT NULL DEFAULT true,
 enrolled_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 UNIQUE (id, employee_id),
 CHECK ((NOT is_active) OR revoked_at IS NULL)
);
CREATE UNIQUE INDEX ux_gms_one_active_device_per_employee
 ON mobile_devices(employee_id) WHERE is_active = true;

CREATE TABLE generators (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL UNIQUE,
 is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE zones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 generator_id uuid NOT NULL REFERENCES generators(id),
 name text NOT NULL,
 UNIQUE(generator_id, name),
 UNIQUE(id, generator_id)
);
CREATE TABLE subscribers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscription_no text NOT NULL UNIQUE,
 full_name text NOT NULL,
 phone text,
 generator_id uuid NOT NULL REFERENCES generators(id),
 zone_id uuid NOT NULL,
 is_active boolean NOT NULL DEFAULT true,
 stopped_at timestamptz,
 stop_reason text,
 FOREIGN KEY(zone_id, generator_id) REFERENCES zones(id, generator_id),
 UNIQUE(id, generator_id),
 UNIQUE(id, zone_id),
 CHECK (is_active OR stopped_at IS NOT NULL)
);
CREATE TABLE user_zone_grants (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 employee_id uuid NOT NULL REFERENCES app_users(id),
 zone_id uuid NOT NULL REFERENCES zones(id),
 valid_from timestamptz NOT NULL,
 valid_until timestamptz,
 granted_by uuid NOT NULL REFERENCES app_users(id),
 CHECK(valid_until IS NULL OR valid_until > valid_from)
);
CREATE INDEX ix_gms_grants_employee ON user_zone_grants(employee_id,zone_id,valid_from);

CREATE TABLE meters (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 serial_no text NOT NULL UNIQUE,
 meter_type text NOT NULL CHECK(meter_type IN ('digital','mechanical')),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE meter_installations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 meter_id uuid NOT NULL REFERENCES meters(id),
 installed_at timestamptz NOT NULL,
 removed_at timestamptz,
 installed_by uuid NOT NULL REFERENCES app_users(id),
 removed_by uuid REFERENCES app_users(id),
 removal_reason text,
 UNIQUE(id,subscriber_id),
 CHECK(removed_at IS NULL OR removed_at>installed_at)
);
CREATE UNIQUE INDEX ux_gms_current_meter_per_subscriber
 ON meter_installations(subscriber_id) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX ux_gms_current_subscriber_per_meter
 ON meter_installations(meter_id) WHERE removed_at IS NULL;

CREATE TABLE opening_baselines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 installation_id uuid NOT NULL UNIQUE REFERENCES meter_installations(id),
 opening_value_kwh numeric NOT NULL CHECK(opening_value_kwh>=0),
 entered_by uuid NOT NULL REFERENCES app_users(id),
 entered_at timestamptz NOT NULL DEFAULT now(),
 note text
);

-- One global weekly pricing period; manager chooses boundaries.
CREATE TABLE reading_cycles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 label text NOT NULL UNIQUE,
 starts_on date NOT NULL,
 ends_on date NOT NULL,
 state text NOT NULL DEFAULT 'draft' CHECK(state IN ('draft','open','closed')),
 opened_by uuid NOT NULL REFERENCES app_users(id),
 closed_by uuid REFERENCES app_users(id),
 closed_at timestamptz,
 CHECK(ends_on>=starts_on),
 CHECK((state='closed') = (closed_at IS NOT NULL))
);
ALTER TABLE reading_cycles ADD CONSTRAINT ex_gms_cycle_date_no_overlap
 EXCLUDE USING gist (daterange(starts_on, ends_on+1,'[)') WITH &&);

-- Historical daily price edits; only final cycle price is financial truth.
CREATE TABLE tariff_change_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 cycle_id uuid NOT NULL REFERENCES reading_cycles(id),
 effective_on date NOT NULL,
 proposed_rate_ils_per_kwh numeric(16,6) NOT NULL CHECK(proposed_rate_ils_per_kwh>=0),
 recorded_by uuid NOT NULL REFERENCES app_users(id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 reason text
);
CREATE INDEX ix_gms_tariff_cycle ON tariff_change_events(cycle_id,effective_on,recorded_at);
CREATE TABLE cycle_price_decisions (
 cycle_id uuid PRIMARY KEY REFERENCES reading_cycles(id),
 provisional_rate_ils_per_kwh numeric(16,6) NOT NULL CHECK(provisional_rate_ils_per_kwh>=0),
 final_rate_ils_per_kwh numeric(16,6) CHECK(final_rate_ils_per_kwh>=0),
 final_selected_by uuid REFERENCES app_users(id),
 finalized_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK((final_rate_ils_per_kwh IS NULL) = (finalized_at IS NULL)),
 CHECK((final_selected_by IS NULL) = (finalized_at IS NULL))
);

CREATE TABLE subscriber_schedules (
 subscriber_id uuid PRIMARY KEY REFERENCES subscribers(id),
 interval_days integer NOT NULL CHECK(interval_days BETWEEN 1 AND 366),
 next_due_override date,
 changed_by uuid NOT NULL REFERENCES app_users(id),
 changed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE reading_tasks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 cycle_id uuid NOT NULL REFERENCES reading_cycles(id),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 installation_id uuid NOT NULL,
 zone_id uuid NOT NULL REFERENCES zones(id),
 assigned_employee_id uuid REFERENCES app_users(id),
 planned_for date NOT NULL,
 source text NOT NULL CHECK(source IN ('scheduled','manager_extra','revisit','unreadable_followup','closing')),
 parent_task_id uuid REFERENCES reading_tasks(id),
 status text NOT NULL DEFAULT 'assigned' CHECK(status IN
   ('assigned','in_progress','pending_review','completed_reading','completed_unreadable','revisit_required','cancelled')),
 created_by uuid REFERENCES app_users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 cancelled_at timestamptz,
 FOREIGN KEY(installation_id,subscriber_id) REFERENCES meter_installations(id,subscriber_id),
 FOREIGN KEY(subscriber_id,zone_id) REFERENCES subscribers(id,zone_id),
 UNIQUE(id,cycle_id,installation_id)
);
CREATE INDEX ix_gms_tasks_cycle_state ON reading_tasks(cycle_id,status);
CREATE INDEX ix_gms_tasks_employee_date ON reading_tasks(assigned_employee_id,planned_for);
-- No UNIQUE(cycle_id,subscriber_id)! multiple visits per cycle are valid.

-- Immutable-on-arrival raw field events. Do not alter captured payload;
-- review outcomes are managed separately.
CREATE TABLE field_visits (
 id uuid PRIMARY KEY, -- stable UUID produced on device
 task_id uuid REFERENCES reading_tasks(id), -- NULL allowed for permitted unscheduled visits
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 installation_id uuid NOT NULL,
 zone_id uuid NOT NULL REFERENCES zones(id),
 employee_id uuid NOT NULL REFERENCES app_users(id),
 device_id uuid NOT NULL,
 event_kind text NOT NULL CHECK(event_kind IN ('reading','unreadable','meter_incident')),
 reading_value_kwh numeric,
 reason text,
 captured_at_device timestamptz NOT NULL,
 verified_captured_at timestamptz,
 captured_offset_minutes integer,
 received_at timestamptz NOT NULL DEFAULT now(),
 timestamp_status text NOT NULL DEFAULT 'pending' CHECK(timestamp_status IN ('pending','consistent','suspicious','corrected')),
 record_status text NOT NULL DEFAULT 'awaiting_photo' CHECK(record_status IN
  ('awaiting_photo','pending_review','exception','approved','rejected','needs_revisit','unreadable_resolved')),
 device_payload_sha256 char(64) NOT NULL,
 FOREIGN KEY(installation_id,subscriber_id) REFERENCES meter_installations(id,subscriber_id),
 FOREIGN KEY(subscriber_id,zone_id) REFERENCES subscribers(id,zone_id),
 FOREIGN KEY(device_id,employee_id) REFERENCES mobile_devices(id,employee_id),
 CHECK((event_kind='reading' AND reading_value_kwh IS NOT NULL AND reading_value_kwh>=0)
    OR (event_kind<>'reading' AND reading_value_kwh IS NULL AND NULLIF(trim(reason),'') IS NOT NULL))
);
CREATE INDEX ix_gms_visits_subscriber_date ON field_visits(subscriber_id,captured_at_device);
CREATE INDEX ix_gms_visits_status ON field_visits(record_status,received_at);

CREATE TABLE visit_photos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL REFERENCES field_visits(id),
 object_key text NOT NULL UNIQUE,
 sha256_hex char(64) NOT NULL,
 size_bytes bigint NOT NULL CHECK(size_bytes>0),
 content_type text NOT NULL CHECK(content_type IN ('image/jpeg','image/png','image/webp')),
 state text NOT NULL DEFAULT 'uploading' CHECK(state IN ('uploading','ready','failed')),
 is_primary boolean NOT NULL DEFAULT false,
 ready_at timestamptz,
 CHECK((state='ready') = (ready_at IS NOT NULL))
);
CREATE UNIQUE INDEX ux_gms_one_primary_photo ON visit_photos(visit_id) WHERE is_primary;
CREATE INDEX ix_gms_photos_visit ON visit_photos(visit_id,state);

CREATE TABLE visit_error_reports (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL REFERENCES field_visits(id),
 employee_id uuid NOT NULL REFERENCES app_users(id),
 explanation text NOT NULL,
 submitted_at timestamptz NOT NULL DEFAULT now(),
 acknowledged_by uuid REFERENCES app_users(id)
);
CREATE TABLE meter_incident_reports (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL UNIQUE REFERENCES field_visits(id),
 category text NOT NULL CHECK(category IN ('reset','replacement','fault','other')),
 notes text NOT NULL,
 resolved_by uuid REFERENCES app_users(id),
 resolved_at timestamptz,
 resulting_installation_id uuid REFERENCES meter_installations(id)
);
CREATE TABLE visit_reviews (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL REFERENCES field_visits(id),
 reviewed_by uuid NOT NULL REFERENCES app_users(id),
 decision text NOT NULL CHECK(decision IN
   ('approve_reading','correct_reading','duplicate','reject','request_revisit','approve_unreadable','correct_timestamp','accept_late')),
 corrected_value_kwh numeric,
 corrected_capture_at timestamptz,
 rationale text,
 evidence_note text,
 reviewed_at timestamptz NOT NULL DEFAULT now(),
 CHECK(decision<>'correct_reading' OR corrected_value_kwh IS NOT NULL),
 CHECK(decision<>'correct_timestamp' OR corrected_capture_at IS NOT NULL)
);

-- A single active successor per source, whether opening baseline or prior
-- approved reading. Both server-side locking and reference validation are
-- additionally REQUIRED; a self-FK/UNIQUE alone is NOT enough.
CREATE TABLE approved_readings (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL REFERENCES field_visits(id),
 review_id uuid NOT NULL UNIQUE REFERENCES visit_reviews(id),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 installation_id uuid NOT NULL REFERENCES meter_installations(id),
 cycle_id uuid NOT NULL REFERENCES reading_cycles(id),
 opening_baseline_id uuid REFERENCES opening_baselines(id),
 previous_approved_id uuid REFERENCES approved_readings(id),
 previous_value_kwh numeric NOT NULL CHECK(previous_value_kwh>=0),
 current_value_kwh numeric NOT NULL CHECK(current_value_kwh>=0),
 consumption_kwh numeric GENERATED ALWAYS AS (current_value_kwh-previous_value_kwh) STORED,
 verified_captured_at timestamptz NOT NULL,
 state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','superseded','voided')),
 approved_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(installation_id,subscriber_id) REFERENCES meter_installations(id,subscriber_id),
 CHECK(current_value_kwh>=previous_value_kwh),
 CHECK((opening_baseline_id IS NOT NULL) <> (previous_approved_id IS NOT NULL))
);
CREATE UNIQUE INDEX ux_gms_active_visit_reading ON approved_readings(visit_id) WHERE state='active';
CREATE UNIQUE INDEX ux_gms_active_opening_successor ON approved_readings(opening_baseline_id)
 WHERE state='active' AND opening_baseline_id IS NOT NULL;
CREATE UNIQUE INDEX ux_gms_active_previous_successor ON approved_readings(previous_approved_id)
 WHERE state='active' AND previous_approved_id IS NOT NULL;
CREATE INDEX ix_gms_active_reading_chain ON approved_readings(installation_id,verified_captured_at)
 WHERE state='active';
-- CAUTION: active->superseded transition MUST occur through an audited,
-- serializable approval/correction transaction; never a normal API UPDATE.

-- One statement per subscriber & pricing week, multiple readings per week.
-- Recomputations of OPEN weeks create a new revision, superseding the draft.
-- Closed statement remains immutable: later corrections are adjustments.
CREATE TABLE statement_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 cycle_id uuid NOT NULL REFERENCES reading_cycles(id),
 revision integer NOT NULL CHECK(revision>=1),
 state text NOT NULL CHECK(state IN ('draft','superseded','final')),
 provisional boolean NOT NULL DEFAULT true,
 rate_snapshot_ils_per_kwh numeric(16,6) NOT NULL CHECK(rate_snapshot_ils_per_kwh>=0),
 charge_exact_ils numeric(28,8) NOT NULL DEFAULT 0,
 carry_in_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK(carry_in_ils>=0 AND carry_in_ils<1),
 credits_in_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK(credits_in_ils>=0),
 adjustments_ils numeric(28,8) NOT NULL DEFAULT 0,
 net_exact_ils numeric(28,8) NOT NULL DEFAULT 0,
 requested_whole_ils numeric(24,0) NOT NULL DEFAULT 0 CHECK(requested_whole_ils>=0),
 carry_out_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK(carry_out_ils>=0 AND carry_out_ils<1),
 credits_out_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK(credits_out_ils>=0),
 created_at timestamptz NOT NULL DEFAULT now(),
 finalized_at timestamptz,
 UNIQUE(subscriber_id,cycle_id,revision),
 CHECK((state='final')=(finalized_at IS NOT NULL)),
 CHECK(state<>'final' OR provisional=false)
);
CREATE UNIQUE INDEX ux_gms_one_final_statement ON statement_versions(subscriber_id,cycle_id)
 WHERE state='final';
CREATE TABLE statement_reading_lines (
 statement_id uuid NOT NULL REFERENCES statement_versions(id),
 approved_reading_id uuid NOT NULL REFERENCES approved_readings(id),
 consumption_kwh numeric NOT NULL CHECK(consumption_kwh>=0),
 rate_snapshot numeric(16,6) NOT NULL CHECK(rate_snapshot>=0),
 exact_charge_ils numeric(28,8) NOT NULL CHECK(exact_charge_ils>=0),
 PRIMARY KEY(statement_id,approved_reading_id),
 CHECK(exact_charge_ils=consumption_kwh*rate_snapshot)
);

CREATE TABLE billing_accounts (
 subscriber_id uuid PRIMARY KEY REFERENCES subscribers(id),
 carry_fraction_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK(carry_fraction_ils>=0 AND carry_fraction_ils<1),
 credit_balance_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK(credit_balance_ils>=0),
 last_finalized_cycle_id uuid REFERENCES reading_cycles(id),
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE financial_adjustments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 source_cycle_id uuid REFERENCES reading_cycles(id),
 target_cycle_id uuid REFERENCES reading_cycles(id),
 adjustment_ils numeric(28,8) NOT NULL CHECK(adjustment_ils<>0),
 description text NOT NULL,
 recorded_by uuid NOT NULL REFERENCES app_users(id),
 idempotency_key uuid NOT NULL UNIQUE,
 recorded_at timestamptz NOT NULL DEFAULT now()
);

-- Actual payments are manager-only. Partial payments are supported.
CREATE TABLE payment_receipts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 receipt_no text NOT NULL UNIQUE,
 amount_ils numeric(20,2) NOT NULL CHECK(amount_ils>0),
 paid_at timestamptz NOT NULL,
 received_by uuid NOT NULL REFERENCES app_users(id),
 payment_method text NOT NULL CHECK(payment_method IN ('cash','bank_transfer','other')),
 reference_text text,
 idempotency_key uuid NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payment_reversals (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 payment_id uuid NOT NULL UNIQUE REFERENCES payment_receipts(id),
 reversed_by uuid NOT NULL REFERENCES app_users(id),
 reversed_at timestamptz NOT NULL DEFAULT now(),
 reason text NOT NULL
);
-- Debit > 0, credit < 0; cash receipt is a credit. No deletion allowed.
CREATE TABLE ledger_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES subscribers(id),
 source_type text NOT NULL CHECK(source_type IN ('final_statement','payment','payment_reversal','adjustment')),
 source_id uuid NOT NULL,
 signed_amount_ils numeric(28,8) NOT NULL CHECK(signed_amount_ils<>0),
 posted_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(source_type,source_id)
);
CREATE INDEX ix_gms_ledger_subscriber ON ledger_entries(subscriber_id,posted_at);
-- Ledger balance (unpaid receivable) = SUM(signed_amount_ils) per subscriber.
-- The fractional carry / credits are separate accounting state, NOT receipts.
-- Posting final statements/adjustments/payments must update ledger and
-- subscriber account atomically with SELECT ... FOR UPDATE.

CREATE TABLE sync_operations (
 operation_id uuid PRIMARY KEY,
 employee_id uuid NOT NULL REFERENCES app_users(id),
 device_id uuid NOT NULL REFERENCES mobile_devices(id),
 visit_id uuid REFERENCES field_visits(id),
 payload_sha256 char(64) NOT NULL,
 result_code text NOT NULL CHECK(result_code IN
  ('accepted','already_received','conflict','retry_required','rejected')),
 result_data jsonb NOT NULL DEFAULT '{}'::jsonb,
 accepted_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE audit_logs (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor_id uuid REFERENCES app_users(id),
 action_code text NOT NULL,
 entity_type text NOT NULL,
 entity_id uuid,
 before_data jsonb,
 after_data jsonb,
 occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE backup_job_log (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 initiated_by uuid REFERENCES app_users(id),
 kind text NOT NULL CHECK(kind IN ('scheduled','manual','restore_test')),
 started_at timestamptz NOT NULL DEFAULT now(),
 ended_at timestamptz,
 succeeded boolean,
 notes text
);

-- Basic append-only protections (still requires DB role grants, audit triggers,
-- restricted service functions and backup-level validation in production).
CREATE OR REPLACE FUNCTION gms_prevent_immutable_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 RAISE EXCEPTION 'Historical record is append-only: use reversal or correction flow';
END;
$$;
CREATE TRIGGER trg_gms_protect_opening BEFORE UPDATE OR DELETE ON opening_baselines
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_protect_price_events BEFORE UPDATE OR DELETE ON tariff_change_events
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_protect_payments BEFORE UPDATE OR DELETE ON payment_receipts
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_protect_payment_reversals BEFORE UPDATE OR DELETE ON payment_reversals
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_protect_fin_adjustments BEFORE UPDATE OR DELETE ON financial_adjustments
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_protect_ledger BEFORE UPDATE OR DELETE ON ledger_entries
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();
CREATE TRIGGER trg_gms_protect_audit BEFORE UPDATE OR DELETE ON audit_logs
 FOR EACH ROW EXECUTE FUNCTION gms_prevent_immutable_change();

COMMIT;

-- GMS 2.2 overlays server-side guarantees in the separately installed 20_hardening.sql and 30_finance_engine.sql.
-- Historical 2.1 checklist retained below for migration audit:
-- A. App user role=manager for reviews, final pricing, payments, corrections,
--    manual downloads, device revocations; user role=employee for field events.
-- B. Atomic visit approval: primary READY photo exists; original time reviewed;
--    original task/area grant and historical assignment policy checked;
--    relevant installation active at capture; reading chain head locked;
--    previous_value matches actual referenced approved reading or baseline;
--    order of captured events and pending earlier events validated.
-- C. Cycle close: every scheduled and extra task resolved, no unresolved
--    mandatory review; final rate selected; all statement versions computed;
--    no dangling provisional carry; no open accounting transactions.
-- D. Transactional financial postings (SELECT account FOR UPDATE), decimal
--    floor & carry, negative-credit handling, payment idempotency and refunds.
-- E. Untrusted client-device clocks require evidence & manager correction.
-- F. Historical price effective_on within cycle, and final rate immutability
--    after close, audited exceptional adjustment, not silent edit.
-- G. No double-posting of same approved reading across FINAL statements.
-- H. Image object storage ACL, checksums, virus/file type checking, retention;
--    transactional receipt acknowledgement and safe upload retries.
-- I. Offline app wipe/revocation limitations; privileged API grants and
--    immutable audit for state changes. DB superuser can bypass triggers.
-- J. Backups, restore tests, monitored indexes, reconciliations, QA loads,
--    timezone selection, and schema/migration tests before production.
