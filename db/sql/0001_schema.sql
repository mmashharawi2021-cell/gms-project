-- GMS | 0001 | Tables (schema gms). Derived from reference 2.2 baseline, corrected after
-- real PostgreSQL execution (see docs/phase-00-audit.md). Applied by Alembic revision 0001.
-- Readings: numeric WITHOUT typmod + scale CHECK (no silent rounding). Money: numeric(28,8).

CREATE TABLE gms.system_settings (
 key text PRIMARY KEY,
 value text NOT NULL,
 updated_by uuid,
 updated_at timestamptz NOT NULL DEFAULT now()
);
-- Operational configuration (not business/customer data). Asia/Gaza is an assumption
-- that must be confirmed by the client (docs/assumptions-and-decisions.md, D-01).
INSERT INTO gms.system_settings(key,value) VALUES
 ('business_timezone','Asia/Gaza'),
 ('clock_skew_tolerance_minutes','5'),
 ('late_sync_hours','36'),
 ('default_interval_days','7');

CREATE TABLE gms.app_users (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 username text NOT NULL UNIQUE CHECK (username = lower(username) AND username ~ '^[a-z0-9._-]{3,40}$'),
 password_hash text NOT NULL,
 full_name text NOT NULL CHECK (length(trim(full_name)) > 0),
 role text NOT NULL CHECK (role IN ('manager','employee')),
 is_active boolean NOT NULL DEFAULT true,
 must_change_password boolean NOT NULL DEFAULT false,
 token_version integer NOT NULL DEFAULT 0,
 failed_logins integer NOT NULL DEFAULT 0,
 locked_until timestamptz,
 password_changed_at timestamptz,
 created_by uuid REFERENCES gms.app_users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE gms.mobile_devices (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 employee_id uuid NOT NULL REFERENCES gms.app_users(id),
 install_id text NOT NULL CHECK (length(install_id) BETWEEN 16 AND 128),
 device_label text NOT NULL,
 is_active boolean NOT NULL DEFAULT true,
 enrolled_at timestamptz NOT NULL DEFAULT now(),
 revoked_at timestamptz,
 revoked_by uuid REFERENCES gms.app_users(id),
 revoke_reason text,
 last_seen_at timestamptz,
 UNIQUE (id, employee_id),
 CHECK (is_active = (revoked_at IS NULL))
);
CREATE UNIQUE INDEX ux_one_active_device_per_employee ON gms.mobile_devices(employee_id) WHERE is_active;
CREATE UNIQUE INDEX ux_active_install ON gms.mobile_devices(install_id) WHERE is_active;

-- Manager-issued one-time code authorising enrolment/replacement of an employee phone.
CREATE TABLE gms.device_enrollment_codes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 employee_id uuid NOT NULL REFERENCES gms.app_users(id),
 code_sha256 char(64) NOT NULL UNIQUE,
 created_by uuid NOT NULL REFERENCES gms.app_users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 used_at timestamptz,
 used_device_id uuid REFERENCES gms.mobile_devices(id)
);

CREATE TABLE gms.auth_refresh_tokens (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 user_id uuid NOT NULL REFERENCES gms.app_users(id),
 device_id uuid REFERENCES gms.mobile_devices(id),
 family_id uuid NOT NULL,
 token_sha256 char(64) NOT NULL UNIQUE,
 client_kind text NOT NULL CHECK (client_kind IN ('web','mobile')),
 issued_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL,
 used_at timestamptz,
 revoked_at timestamptz
);
CREATE INDEX ix_refresh_user ON gms.auth_refresh_tokens(user_id, family_id);

CREATE TABLE gms.generators (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 name text NOT NULL UNIQUE CHECK (length(trim(name)) > 0),
 location_note text,
 is_active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE gms.zones (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 generator_id uuid NOT NULL REFERENCES gms.generators(id),
 name text NOT NULL CHECK (length(trim(name)) > 0),
 reading_weekday smallint CHECK (reading_weekday BETWEEN 0 AND 6), -- 0=Sunday (extract dow)
 is_active boolean NOT NULL DEFAULT true,
 UNIQUE (generator_id, name),
 UNIQUE (id, generator_id)
);
-- BR-01: one fixed generator per subscriber (generator_id immutable, see guards).
CREATE TABLE gms.subscribers (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscription_no text NOT NULL UNIQUE CHECK (length(trim(subscription_no)) > 0),
 full_name text NOT NULL CHECK (length(trim(full_name)) > 0),
 phone text,
 address text,
 notes text,
 generator_id uuid NOT NULL REFERENCES gms.generators(id),
 zone_id uuid NOT NULL,
 is_active boolean NOT NULL DEFAULT true,
 stopped_at timestamptz,
 stop_reason text,
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (zone_id, generator_id) REFERENCES gms.zones(id, generator_id),
 CHECK (is_active OR stopped_at IS NOT NULL)
);
CREATE INDEX ix_subscribers_zone ON gms.subscribers(zone_id) WHERE is_active;
CREATE INDEX ix_subscribers_name ON gms.subscribers(full_name);

CREATE TABLE gms.user_zone_grants (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 employee_id uuid NOT NULL REFERENCES gms.app_users(id),
 zone_id uuid NOT NULL REFERENCES gms.zones(id),
 valid_from timestamptz NOT NULL DEFAULT now(),
 valid_until timestamptz,
 granted_by uuid NOT NULL REFERENCES gms.app_users(id),
 CHECK (valid_until IS NULL OR valid_until > valid_from)
);
CREATE INDEX ix_grants_employee ON gms.user_zone_grants(employee_id, zone_id, valid_from);
CREATE UNIQUE INDEX ux_one_open_grant ON gms.user_zone_grants(employee_id, zone_id) WHERE valid_until IS NULL;

CREATE TABLE gms.meters (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 serial_no text NOT NULL UNIQUE CHECK (length(trim(serial_no)) > 0),
 meter_type text NOT NULL CHECK (meter_type IN ('digital','mechanical')),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE gms.meter_installations (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 meter_id uuid NOT NULL REFERENCES gms.meters(id),
 kind text NOT NULL DEFAULT 'initial' CHECK (kind IN ('initial','replacement','reset')),
 installed_at timestamptz NOT NULL,
 removed_at timestamptz,
 installed_by uuid NOT NULL REFERENCES gms.app_users(id),
 removed_by uuid REFERENCES gms.app_users(id),
 removal_reason text,
 UNIQUE (id, subscriber_id),
 CHECK (removed_at IS NULL OR removed_at > installed_at),
 CHECK ((removed_at IS NULL) = (removed_by IS NULL))
);
CREATE UNIQUE INDEX ux_current_meter_per_subscriber ON gms.meter_installations(subscriber_id) WHERE removed_at IS NULL;
CREATE UNIQUE INDEX ux_current_subscriber_per_meter ON gms.meter_installations(meter_id) WHERE removed_at IS NULL;

-- BR-06: manager-entered opening reading; never billed.
CREATE TABLE gms.opening_baselines (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 installation_id uuid NOT NULL UNIQUE REFERENCES gms.meter_installations(id),
 opening_value_kwh numeric NOT NULL CHECK (opening_value_kwh >= 0 AND scale(opening_value_kwh) <= 2 AND opening_value_kwh < 100000000000000),
 entered_by uuid NOT NULL REFERENCES gms.app_users(id),
 entered_at timestamptz NOT NULL DEFAULT now(),
 note text
);

CREATE TABLE gms.reading_cycles (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 label text NOT NULL UNIQUE CHECK (length(trim(label)) > 0),
 starts_on date NOT NULL,
 ends_on date NOT NULL,
 state text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft','open','closed')),
 opened_by uuid NOT NULL REFERENCES gms.app_users(id),
 opened_at timestamptz,
 closed_by uuid REFERENCES gms.app_users(id),
 closed_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK (ends_on >= starts_on),
 CHECK ((state = 'closed') = (closed_at IS NOT NULL)),
 CHECK ((state = 'closed') = (closed_by IS NOT NULL)),
 CONSTRAINT ex_cycle_no_overlap EXCLUDE USING gist (daterange(starts_on, ends_on + 1, '[)') WITH &&)
);
CREATE UNIQUE INDEX ux_one_open_cycle ON gms.reading_cycles ((true)) WHERE state = 'open';

CREATE TABLE gms.tariff_change_events (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 cycle_id uuid NOT NULL REFERENCES gms.reading_cycles(id),
 effective_on date NOT NULL,
 proposed_rate_ils_per_kwh numeric(16,6) NOT NULL CHECK (proposed_rate_ils_per_kwh >= 0),
 recorded_by uuid NOT NULL REFERENCES gms.app_users(id),
 recorded_at timestamptz NOT NULL DEFAULT now(),
 reason text
);
CREATE INDEX ix_tariff_cycle ON gms.tariff_change_events(cycle_id, effective_on, recorded_at);
CREATE TABLE gms.cycle_price_decisions (
 cycle_id uuid PRIMARY KEY REFERENCES gms.reading_cycles(id),
 provisional_rate_ils_per_kwh numeric(16,6) NOT NULL CHECK (provisional_rate_ils_per_kwh >= 0),
 final_rate_ils_per_kwh numeric(16,6) CHECK (final_rate_ils_per_kwh >= 0),
 final_selected_by uuid REFERENCES gms.app_users(id),
 finalized_at timestamptz,
 updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK ((final_rate_ils_per_kwh IS NULL) = (finalized_at IS NULL)),
 CHECK ((final_selected_by IS NULL) = (finalized_at IS NULL))
);

CREATE TABLE gms.subscriber_schedules (
 subscriber_id uuid PRIMARY KEY REFERENCES gms.subscribers(id),
 interval_days integer NOT NULL CHECK (interval_days BETWEEN 1 AND 366),
 next_due_override date,
 changed_by uuid NOT NULL REFERENCES gms.app_users(id),
 changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE gms.reading_tasks (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 cycle_id uuid NOT NULL REFERENCES gms.reading_cycles(id),
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 installation_id uuid NOT NULL,
 zone_id uuid NOT NULL REFERENCES gms.zones(id), -- snapshot of the subscriber zone at creation
 assigned_employee_id uuid REFERENCES gms.app_users(id),
 planned_for date NOT NULL,
 source text NOT NULL CHECK (source IN ('scheduled','manager_extra','revisit','unreadable_followup','closing')),
 parent_task_id uuid REFERENCES gms.reading_tasks(id),
 status text NOT NULL DEFAULT 'assigned' CHECK (status IN
  ('assigned','in_progress','pending_review','completed_reading','completed_unreadable','revisit_required','cancelled')),
 created_by uuid REFERENCES gms.app_users(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 updated_at timestamptz NOT NULL DEFAULT now(),
 cancelled_at timestamptz,
 cancel_reason text,
 FOREIGN KEY (installation_id, subscriber_id) REFERENCES gms.meter_installations(id, subscriber_id),
 CHECK (status <> 'cancelled' OR (cancelled_at IS NOT NULL AND nullif(trim(cancel_reason), '') IS NOT NULL))
);
CREATE INDEX ix_tasks_cycle_state ON gms.reading_tasks(cycle_id, status);
CREATE INDEX ix_tasks_employee_date ON gms.reading_tasks(assigned_employee_id, planned_for);
CREATE INDEX ix_tasks_subscriber ON gms.reading_tasks(subscriber_id, status);

-- Raw field events: content immutable on arrival; review state lives in a few status columns.
CREATE TABLE gms.field_visits (
 id uuid PRIMARY KEY, -- stable UUID generated on the device
 task_id uuid REFERENCES gms.reading_tasks(id),
 payload_task_id uuid, -- what the device sent (kept even when the task link is not usable)
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 installation_id uuid NOT NULL,
 zone_id uuid NOT NULL REFERENCES gms.zones(id),
 employee_id uuid NOT NULL REFERENCES gms.app_users(id),
 device_id uuid NOT NULL,
 event_kind text NOT NULL CHECK (event_kind IN ('reading','unreadable','meter_incident')),
 reading_value_kwh numeric,
 reason text,
 note text,
 captured_at_device timestamptz NOT NULL,
 captured_offset_minutes integer,
 server_estimated_captured_at timestamptz,
 received_at timestamptz NOT NULL DEFAULT now(),
 flags text[] NOT NULL DEFAULT '{}',
 device_payload_sha256 char(64) NOT NULL,
 -- review-side (mutable through manager functions only)
 verified_captured_at timestamptz,
 timestamp_status text NOT NULL DEFAULT 'pending' CHECK (timestamp_status IN ('pending','consistent','suspicious','corrected')),
 record_status text NOT NULL DEFAULT 'awaiting_photo' CHECK (record_status IN
  ('awaiting_photo','pending_review','exception','approved','rejected','needs_revisit','unreadable_resolved','incident_resolved')),
 FOREIGN KEY (installation_id, subscriber_id) REFERENCES gms.meter_installations(id, subscriber_id),
 FOREIGN KEY (device_id, employee_id) REFERENCES gms.mobile_devices(id, employee_id),
 CHECK ((event_kind = 'reading' AND reading_value_kwh IS NOT NULL AND reading_value_kwh >= 0)
     OR (event_kind <> 'reading' AND reading_value_kwh IS NULL AND nullif(trim(reason), '') IS NOT NULL)),
 CONSTRAINT ck_field_decimal CHECK (reading_value_kwh IS NULL OR (scale(reading_value_kwh) <= 2 AND reading_value_kwh < 100000000000000))
);
CREATE INDEX ix_visits_subscriber_date ON gms.field_visits(subscriber_id, captured_at_device);
CREATE INDEX ix_visits_status ON gms.field_visits(record_status, received_at);
CREATE INDEX ix_visits_installation ON gms.field_visits(installation_id, captured_at_device);
CREATE INDEX ix_visits_task ON gms.field_visits(task_id);
CREATE INDEX ix_visits_employee ON gms.field_visits(employee_id, received_at);

CREATE TABLE gms.visit_photos (
 id uuid PRIMARY KEY, -- generated on the device
 visit_id uuid NOT NULL REFERENCES gms.field_visits(id),
 object_key text NOT NULL UNIQUE,
 sha256_hex char(64) NOT NULL CHECK (sha256_hex ~ '^[0-9a-f]{64}$'),
 size_bytes bigint NOT NULL CHECK (size_bytes > 0),
 content_type text NOT NULL CHECK (content_type IN ('image/jpeg','image/png','image/webp')),
 state text NOT NULL DEFAULT 'uploading' CHECK (state IN ('uploading','ready','failed')),
 is_primary boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),
 ready_at timestamptz,
 failure_reason text,
 CHECK ((state = 'ready') = (ready_at IS NOT NULL))
);
CREATE UNIQUE INDEX ux_one_primary_photo ON gms.visit_photos(visit_id) WHERE is_primary;
CREATE INDEX ix_photos_visit ON gms.visit_photos(visit_id, state);

CREATE TABLE gms.visit_error_reports (
 id uuid PRIMARY KEY, -- generated on the device
 visit_id uuid NOT NULL REFERENCES gms.field_visits(id),
 employee_id uuid NOT NULL REFERENCES gms.app_users(id),
 explanation text NOT NULL CHECK (length(trim(explanation)) > 0),
 submitted_at timestamptz NOT NULL DEFAULT now(),
 acknowledged_by uuid REFERENCES gms.app_users(id),
 acknowledged_at timestamptz,
 resolution_note text,
 CHECK ((acknowledged_by IS NULL) = (acknowledged_at IS NULL))
);
CREATE TABLE gms.meter_incident_reports (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL UNIQUE REFERENCES gms.field_visits(id),
 category text NOT NULL CHECK (category IN ('reset','replacement','fault','other')),
 notes text NOT NULL,
 resolved_by uuid REFERENCES gms.app_users(id),
 resolved_at timestamptz,
 resolution_note text,
 resulting_installation_id uuid REFERENCES gms.meter_installations(id)
);

CREATE TABLE gms.visit_reviews (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL REFERENCES gms.field_visits(id),
 reviewed_by uuid NOT NULL REFERENCES gms.app_users(id),
 decision text NOT NULL CHECK (decision IN
  ('approve_reading','correct_reading','duplicate','reject','request_revisit','approve_unreadable',
   'correct_timestamp','accept_late','rechain','resolve_incident')),
 corrected_value_kwh numeric CHECK (corrected_value_kwh IS NULL OR (corrected_value_kwh >= 0 AND scale(corrected_value_kwh) <= 2)),
 corrected_capture_at timestamptz,
 rationale text,
 reviewed_at timestamptz NOT NULL DEFAULT now(),
 CHECK (decision <> 'correct_reading' OR (corrected_value_kwh IS NOT NULL AND nullif(trim(rationale), '') IS NOT NULL)),
 CHECK (decision <> 'correct_timestamp' OR corrected_capture_at IS NOT NULL)
);
CREATE INDEX ix_reviews_visit ON gms.visit_reviews(visit_id, reviewed_at);

-- Linear approved chain per installation: one active successor per opening baseline / previous reading.
CREATE TABLE gms.approved_readings (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 visit_id uuid NOT NULL REFERENCES gms.field_visits(id),
 review_id uuid NOT NULL UNIQUE REFERENCES gms.visit_reviews(id),
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 installation_id uuid NOT NULL REFERENCES gms.meter_installations(id),
 cycle_id uuid NOT NULL REFERENCES gms.reading_cycles(id),
 opening_baseline_id uuid REFERENCES gms.opening_baselines(id),
 previous_approved_id uuid REFERENCES gms.approved_readings(id),
 supersedes_id uuid REFERENCES gms.approved_readings(id),
 previous_value_kwh numeric NOT NULL CHECK (previous_value_kwh >= 0),
 current_value_kwh numeric NOT NULL CHECK (current_value_kwh >= 0),
 consumption_kwh numeric GENERATED ALWAYS AS (current_value_kwh - previous_value_kwh) STORED,
 verified_captured_at timestamptz NOT NULL,
 state text NOT NULL DEFAULT 'active' CHECK (state IN ('active','superseded','voided')),
 approved_by uuid NOT NULL REFERENCES gms.app_users(id),
 approved_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY (installation_id, subscriber_id) REFERENCES gms.meter_installations(id, subscriber_id),
 CHECK (current_value_kwh >= previous_value_kwh),
 CHECK ((opening_baseline_id IS NOT NULL) <> (previous_approved_id IS NOT NULL)),
 CONSTRAINT ck_approved_decimal CHECK (scale(previous_value_kwh) <= 2 AND scale(current_value_kwh) <= 2)
);
CREATE UNIQUE INDEX ux_active_visit_reading ON gms.approved_readings(visit_id) WHERE state = 'active';
CREATE UNIQUE INDEX ux_active_opening_successor ON gms.approved_readings(opening_baseline_id)
 WHERE state = 'active' AND opening_baseline_id IS NOT NULL;
CREATE UNIQUE INDEX ux_active_previous_successor ON gms.approved_readings(previous_approved_id)
 WHERE state = 'active' AND previous_approved_id IS NOT NULL;
CREATE INDEX ix_active_reading_chain ON gms.approved_readings(installation_id, verified_captured_at) WHERE state = 'active';
CREATE INDEX ix_approved_cycle ON gms.approved_readings(cycle_id, subscriber_id) WHERE state = 'active';

CREATE TABLE gms.reading_corrections (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 idempotency_key uuid NOT NULL UNIQUE,
 original_reading_id uuid NOT NULL REFERENCES gms.approved_readings(id),
 new_reading_id uuid REFERENCES gms.approved_readings(id),
 old_value_kwh numeric NOT NULL,
 new_value_kwh numeric NOT NULL CHECK (new_value_kwh >= 0 AND scale(new_value_kwh) <= 2),
 rationale text NOT NULL CHECK (length(trim(rationale)) > 0),
 corrected_by uuid NOT NULL REFERENCES gms.app_users(id),
 corrected_at timestamptz NOT NULL DEFAULT now()
);

CREATE SEQUENCE gms.statement_no_seq;
CREATE SEQUENCE gms.receipt_no_seq;

-- One FINAL weekly statement per subscriber and cycle (multiple reading lines allowed).
-- Provisional figures are computed on the fly and never stored or posted.
CREATE TABLE gms.statement_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 statement_no text NOT NULL UNIQUE,
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 cycle_id uuid NOT NULL REFERENCES gms.reading_cycles(id),
 revision integer NOT NULL DEFAULT 1 CHECK (revision >= 1),
 state text NOT NULL CHECK (state IN ('draft','superseded','final')),
 provisional boolean NOT NULL DEFAULT true,
 rate_snapshot_ils_per_kwh numeric(16,6) NOT NULL CHECK (rate_snapshot_ils_per_kwh >= 0),
 consumption_kwh numeric NOT NULL DEFAULT 0 CHECK (consumption_kwh >= 0),
 charge_exact_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (charge_exact_ils >= 0),
 opening_ledger_balance_ils numeric(28,8) NOT NULL DEFAULT 0,
 closing_ledger_balance_ils numeric(28,8) NOT NULL DEFAULT 0,
 carry_in_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (carry_in_ils >= 0 AND carry_in_ils < 1),
 credits_in_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (credits_in_ils >= 0),
 requested_whole_ils numeric(24,0) NOT NULL DEFAULT 0 CHECK (requested_whole_ils >= 0),
 carry_out_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (carry_out_ils >= 0 AND carry_out_ils < 1),
 credits_out_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (credits_out_ils >= 0),
 created_at timestamptz NOT NULL DEFAULT now(),
 finalized_at timestamptz,
 UNIQUE (subscriber_id, cycle_id, revision),
 CHECK ((state = 'final') = (finalized_at IS NOT NULL)),
 CONSTRAINT ck_final_math CHECK (state <> 'final' OR (
   provisional = false
   AND closing_ledger_balance_ils = opening_ledger_balance_ils + charge_exact_ils
   AND requested_whole_ils = GREATEST(0, trunc(closing_ledger_balance_ils))
   AND carry_out_ils = CASE WHEN closing_ledger_balance_ils > 0 THEN closing_ledger_balance_ils - trunc(closing_ledger_balance_ils) ELSE 0 END
   AND credits_out_ils = GREATEST(0, -closing_ledger_balance_ils)
   AND carry_in_ils = CASE WHEN opening_ledger_balance_ils > 0 THEN opening_ledger_balance_ils - trunc(opening_ledger_balance_ils) ELSE 0 END
   AND credits_in_ils = GREATEST(0, -opening_ledger_balance_ils)))
);
CREATE UNIQUE INDEX ux_one_final_statement ON gms.statement_versions(subscriber_id, cycle_id) WHERE state = 'final';
CREATE INDEX ix_statement_cycle ON gms.statement_versions(cycle_id);

CREATE TABLE gms.statement_reading_lines (
 statement_id uuid NOT NULL REFERENCES gms.statement_versions(id),
 approved_reading_id uuid NOT NULL REFERENCES gms.approved_readings(id),
 previous_value_kwh numeric NOT NULL,
 current_value_kwh numeric NOT NULL,
 consumption_kwh numeric NOT NULL CHECK (consumption_kwh >= 0 AND scale(consumption_kwh) <= 2),
 rate_snapshot numeric(16,6) NOT NULL CHECK (rate_snapshot >= 0),
 exact_charge_ils numeric(28,8) NOT NULL CHECK (exact_charge_ils >= 0),
 PRIMARY KEY (statement_id, approved_reading_id),
 CHECK (consumption_kwh = current_value_kwh - previous_value_kwh),
 CHECK (exact_charge_ils = consumption_kwh * rate_snapshot)
);
-- FIX-04: an approved reading can be allocated to ONE final statement only.
CREATE TABLE gms.final_reading_allocations (
 approved_reading_id uuid PRIMARY KEY REFERENCES gms.approved_readings(id),
 statement_id uuid NOT NULL REFERENCES gms.statement_versions(id),
 allocated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_final_allocations_statement ON gms.final_reading_allocations(statement_id);

-- Lock target + cached projection of the exact ledger balance (never a source of truth).
CREATE TABLE gms.billing_accounts (
 subscriber_id uuid PRIMARY KEY REFERENCES gms.subscribers(id),
 balance_exact_ils numeric(28,8) NOT NULL DEFAULT 0,
 carry_fraction_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (carry_fraction_ils >= 0 AND carry_fraction_ils < 1),
 credit_balance_ils numeric(28,8) NOT NULL DEFAULT 0 CHECK (credit_balance_ils >= 0),
 last_finalized_cycle_id uuid REFERENCES gms.reading_cycles(id),
 updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE gms.opening_receivables (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL UNIQUE REFERENCES gms.subscribers(id),
 signed_amount_ils numeric(28,8) NOT NULL CHECK (signed_amount_ils <> 0),
 as_of date NOT NULL,
 justification text NOT NULL CHECK (length(trim(justification)) > 0),
 approved_by uuid NOT NULL REFERENCES gms.app_users(id),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE gms.financial_adjustments (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 kind text NOT NULL DEFAULT 'manual' CHECK (kind IN ('manual','reading_correction','late_reading')),
 source_cycle_id uuid REFERENCES gms.reading_cycles(id),
 correction_id uuid REFERENCES gms.reading_corrections(id),
 approved_reading_id uuid REFERENCES gms.approved_readings(id),
 adjustment_ils numeric(28,8) NOT NULL CHECK (adjustment_ils <> 0),
 description text NOT NULL CHECK (length(trim(description)) > 0),
 recorded_by uuid NOT NULL REFERENCES gms.app_users(id),
 idempotency_key uuid NOT NULL UNIQUE,
 recorded_at timestamptz NOT NULL DEFAULT now()
);
-- BR-29: actual receipts, manager only, full or partial.
CREATE TABLE gms.payment_receipts (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 receipt_no text NOT NULL UNIQUE,
 amount_ils numeric(20,2) NOT NULL CHECK (amount_ils > 0),
 paid_at timestamptz NOT NULL,
 received_by uuid NOT NULL REFERENCES gms.app_users(id),
 payment_method text NOT NULL CHECK (payment_method IN ('cash','bank_transfer','other')),
 reference_text text,
 idempotency_key uuid NOT NULL UNIQUE,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_payments_subscriber ON gms.payment_receipts(subscriber_id, paid_at);
CREATE TABLE gms.payment_reversals (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 payment_id uuid NOT NULL UNIQUE REFERENCES gms.payment_receipts(id),
 reversed_by uuid NOT NULL REFERENCES gms.app_users(id),
 reversed_at timestamptz NOT NULL DEFAULT now(),
 reason text NOT NULL CHECK (length(trim(reason)) > 0)
);
-- Append-only exact ledger. Debit > 0, credit < 0. Balance = SUM(signed_amount_ils).
CREATE TABLE gms.ledger_entries (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 seq bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
 subscriber_id uuid NOT NULL REFERENCES gms.subscribers(id),
 source_type text NOT NULL CHECK (source_type IN ('opening_receivable','final_statement','payment','payment_reversal','adjustment')),
 source_id uuid NOT NULL,
 signed_amount_ils numeric(28,8) NOT NULL CHECK (signed_amount_ils <> 0),
 posted_by uuid NOT NULL REFERENCES gms.app_users(id),
 posted_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE (source_type, source_id)
);
CREATE INDEX ix_ledger_subscriber ON gms.ledger_entries(subscriber_id, seq);

CREATE TABLE gms.sync_operations (
 operation_id uuid PRIMARY KEY,
 op_kind text NOT NULL DEFAULT 'visit' CHECK (op_kind IN ('visit','error_report')),
 employee_id uuid NOT NULL REFERENCES gms.app_users(id),
 device_id uuid NOT NULL REFERENCES gms.mobile_devices(id),
 entity_id uuid NOT NULL, -- visit id or error-report id as sent by the device
 payload_sha256 char(64) NOT NULL,
 result_code text NOT NULL CHECK (result_code IN ('accepted','already_received','conflict','rejected')),
 result_data jsonb NOT NULL DEFAULT '{}'::jsonb,
 accepted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_syncops_entity ON gms.sync_operations(entity_id);
-- Trace of refused sync/login attempts (revoked device, disabled account, ...).
CREATE TABLE gms.sync_rejections (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 user_id uuid,
 device_id uuid,
 reason text NOT NULL,
 detail jsonb NOT NULL DEFAULT '{}'::jsonb,
 occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE gms.audit_logs (
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
 actor_id uuid,
 action_code text NOT NULL,
 entity_type text NOT NULL,
 entity_id uuid,
 before_data jsonb,
 after_data jsonb,
 occurred_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_audit_entity ON gms.audit_logs(entity_type, entity_id, occurred_at);
CREATE INDEX ix_audit_time ON gms.audit_logs(occurred_at);

CREATE TABLE gms.backup_job_log (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 initiated_by uuid REFERENCES gms.app_users(id),
 kind text NOT NULL CHECK (kind IN ('scheduled','manual','restore_test')),
 started_at timestamptz NOT NULL DEFAULT now(),
 ended_at timestamptz,
 succeeded boolean,
 artifact_name text,
 size_bytes bigint,
 sha256_hex char(64),
 notes text
);

CREATE TABLE gms.import_batches (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 filename text NOT NULL,
 file_sha256 char(64) NOT NULL,
 uploaded_by uuid NOT NULL REFERENCES gms.app_users(id),
 status text NOT NULL DEFAULT 'preview' CHECK (status IN ('preview','committed','discarded')),
 summary jsonb NOT NULL DEFAULT '{}'::jsonb,
 rows jsonb NOT NULL DEFAULT '[]'::jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),
 committed_at timestamptz
);
CREATE UNIQUE INDEX ux_import_committed_file ON gms.import_batches(file_sha256) WHERE status = 'committed';
