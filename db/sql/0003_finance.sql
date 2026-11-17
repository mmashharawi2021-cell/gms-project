-- GMS | 0003 | Financial engine: exact append-only ledger, payments, reversals, adjustments,
-- opening receivables, atomic cycle finalization. All amounts NUMERIC; no float anywhere.
-- Locking order (always): advisory(finalize) -> reading_cycles row -> billing_accounts row.

CREATE FUNCTION gms.ledger_balance(p_subscriber uuid) RETURNS numeric
LANGUAGE sql VOLATILE SET search_path = gms, pg_temp AS $$
 SELECT COALESCE(SUM(signed_amount_ils), 0) FROM gms.ledger_entries WHERE subscriber_id = p_subscriber;
$$;

-- Internal: serialise all money movements of one subscriber.
CREATE FUNCTION gms._lock_account(p_subscriber uuid) RETURNS void
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
BEGIN
 IF NOT EXISTS (SELECT 1 FROM gms.subscribers WHERE id = p_subscriber) THEN
  PERFORM gms.fail('GM404', 'subscriber_not_found', 'المشترك غير موجود');
 END IF;
 INSERT INTO gms.billing_accounts(subscriber_id) VALUES (p_subscriber) ON CONFLICT (subscriber_id) DO NOTHING;
 PERFORM 1 FROM gms.billing_accounts WHERE subscriber_id = p_subscriber FOR UPDATE;
END $$;

-- Internal: refresh the cached projection from the ledger (single source of truth).
CREATE FUNCTION gms._reconcile_account(p_subscriber uuid) RETURNS numeric
LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
DECLARE b numeric;
BEGIN
 b := gms.ledger_balance(p_subscriber);
 UPDATE gms.billing_accounts SET balance_exact_ils = b,
  carry_fraction_ils = CASE WHEN b > 0 THEN b - trunc(b) ELSE 0 END,
  credit_balance_ils = GREATEST(0, -b), updated_at = now()
 WHERE subscriber_id = p_subscriber;
 RETURN b;
END $$;

CREATE FUNCTION gms.record_opening_receivable(p_subscriber uuid, p_amount numeric, p_as_of date, p_justification text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_id uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_amount IS NULL OR p_amount = 0 OR scale(p_amount) > 2 OR p_as_of IS NULL OR nullif(trim(p_justification), '') IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_opening_receivable', 'يلزم مبلغ افتتاحي غير صفري بمنزلتين عشريتين كحد أقصى مع التاريخ والمستند المبرر');
 END IF;
 PERFORM gms._lock_account(p_subscriber);
 IF EXISTS (SELECT 1 FROM gms.opening_receivables WHERE subscriber_id = p_subscriber) THEN
  PERFORM gms.fail('GM409', 'opening_receivable_exists', 'سُجّل رصيد افتتاحي لهذا المشترك مسبقًا؛ استخدم تسوية موثقة للتعديل');
 END IF;
 INSERT INTO gms.opening_receivables(subscriber_id, signed_amount_ils, as_of, justification, approved_by)
 VALUES (p_subscriber, p_amount, p_as_of, trim(p_justification), v_actor) RETURNING id INTO v_id;
 INSERT INTO gms.ledger_entries(subscriber_id, source_type, source_id, signed_amount_ils, posted_by)
 VALUES (p_subscriber, 'opening_receivable', v_id, p_amount, v_actor);
 PERFORM gms._reconcile_account(p_subscriber);
 RETURN v_id;
END $$;

-- BR-29: manager-only actual receipt. Idempotent on p_idempotency; same key + different data = conflict.
CREATE FUNCTION gms.record_payment(p_subscriber uuid, p_amount numeric, p_paid_at timestamptz,
 p_method text, p_reference text, p_idempotency uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_prev gms.payment_receipts; v_id uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_amount IS NULL OR p_amount <= 0 OR scale(p_amount) > 2 OR p_amount >= 1000000000 OR p_paid_at IS NULL
    OR p_method IS NULL OR p_method NOT IN ('cash','bank_transfer','other') OR p_idempotency IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_payment', 'بيانات الدفعة غير صالحة: مبلغ موجب بمنزلتين كحد أقصى وتاريخ وطريقة دفع ومفتاح عدم تكرار');
 END IF;
 IF p_paid_at > now() + interval '1 day' THEN
  PERFORM gms.fail('GM422', 'payment_in_future', 'تاريخ الدفعة في المستقبل');
 END IF;
 PERFORM gms._lock_account(p_subscriber);
 SELECT * INTO v_prev FROM gms.payment_receipts WHERE idempotency_key = p_idempotency;
 IF FOUND THEN
  IF v_prev.subscriber_id <> p_subscriber OR v_prev.amount_ils <> p_amount OR v_prev.paid_at <> p_paid_at
     OR v_prev.payment_method <> p_method OR v_prev.reference_text IS DISTINCT FROM nullif(trim(p_reference), '') THEN
   PERFORM gms.fail('GM409', 'idempotency_conflict', 'أُعيد استخدام مفتاح عدم التكرار مع بيانات دفعة مختلفة');
  END IF;
  RETURN v_prev.id;
 END IF;
 INSERT INTO gms.payment_receipts(subscriber_id, receipt_no, amount_ils, paid_at, received_by, payment_method, reference_text, idempotency_key)
 VALUES (p_subscriber, 'RC-' || to_char(nextval('gms.receipt_no_seq'), 'FM00000000'), p_amount, p_paid_at, v_actor,
  p_method, nullif(trim(p_reference), ''), p_idempotency)
 RETURNING id INTO v_id;
 INSERT INTO gms.ledger_entries(subscriber_id, source_type, source_id, signed_amount_ils, posted_by)
 VALUES (p_subscriber, 'payment', v_id, -p_amount, v_actor);
 PERFORM gms._reconcile_account(p_subscriber);
 RETURN v_id;
END $$;

-- Cancelling a payment = one counter-entry; the original receipt and ledger row stay untouched.
CREATE FUNCTION gms.reverse_payment(p_payment uuid, p_reason text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_pay gms.payment_receipts; v_id uuid;
BEGIN
 v_actor := gms.require_role('manager');
 IF nullif(trim(p_reason), '') IS NULL THEN PERFORM gms.fail('GM422', 'reason_required', 'سبب إلغاء الدفعة إلزامي'); END IF;
 SELECT * INTO v_pay FROM gms.payment_receipts WHERE id = p_payment;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'payment_not_found', 'الدفعة غير موجودة'); END IF;
 PERFORM gms._lock_account(v_pay.subscriber_id);
 SELECT id INTO v_id FROM gms.payment_reversals WHERE payment_id = p_payment;
 IF FOUND THEN RETURN v_id; END IF;
 INSERT INTO gms.payment_reversals(payment_id, reversed_by, reason) VALUES (p_payment, v_actor, trim(p_reason)) RETURNING id INTO v_id;
 INSERT INTO gms.ledger_entries(subscriber_id, source_type, source_id, signed_amount_ils, posted_by)
 VALUES (v_pay.subscriber_id, 'payment_reversal', v_id, v_pay.amount_ils, v_actor);
 PERFORM gms._reconcile_account(v_pay.subscriber_id);
 RETURN v_id;
END $$;

-- Internal: post one adjustment (caller already authorised and holds the account lock).
CREATE FUNCTION gms._post_adjustment(p_actor uuid, p_subscriber uuid, p_amount numeric, p_reason text, p_idempotency uuid,
 p_kind text, p_source_cycle uuid, p_correction uuid, p_reading uuid)
RETURNS uuid LANGUAGE plpgsql SET search_path = gms, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
 INSERT INTO gms.financial_adjustments(subscriber_id, kind, source_cycle_id, correction_id, approved_reading_id,
  adjustment_ils, description, recorded_by, idempotency_key)
 VALUES (p_subscriber, p_kind, p_source_cycle, p_correction, p_reading, p_amount, p_reason, p_actor, p_idempotency)
 RETURNING id INTO v_id;
 INSERT INTO gms.ledger_entries(subscriber_id, source_type, source_id, signed_amount_ils, posted_by)
 VALUES (p_subscriber, 'adjustment', v_id, p_amount, p_actor);
 PERFORM gms._reconcile_account(p_subscriber);
 RETURN v_id;
END $$;

-- Manual signed adjustment (credit < 0, debit > 0) with mandatory reason. Idempotent.
CREATE FUNCTION gms.record_adjustment(p_subscriber uuid, p_amount numeric, p_reason text, p_idempotency uuid,
 p_source_cycle uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; v_prev gms.financial_adjustments;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_amount IS NULL OR p_amount = 0 OR scale(p_amount) > 2 OR abs(p_amount) >= 1000000000
    OR nullif(trim(p_reason), '') IS NULL OR p_idempotency IS NULL THEN
  PERFORM gms.fail('GM422', 'invalid_adjustment', 'تسوية غير صالحة: مبلغ غير صفري بمنزلتين كحد أقصى وسبب ومفتاح عدم تكرار');
 END IF;
 PERFORM gms._lock_account(p_subscriber);
 SELECT * INTO v_prev FROM gms.financial_adjustments WHERE idempotency_key = p_idempotency;
 IF FOUND THEN
  IF v_prev.subscriber_id <> p_subscriber OR v_prev.adjustment_ils <> p_amount OR v_prev.description <> trim(p_reason)
     OR v_prev.source_cycle_id IS DISTINCT FROM p_source_cycle OR v_prev.kind <> 'manual' THEN
   PERFORM gms.fail('GM409', 'idempotency_conflict', 'أُعيد استخدام مفتاح عدم التكرار مع بيانات تسوية مختلفة');
  END IF;
  RETURN v_prev.id;
 END IF;
 RETURN gms._post_adjustment(v_actor, p_subscriber, p_amount, trim(p_reason), p_idempotency, 'manual', p_source_cycle, NULL, NULL);
END $$;

-- Everything that still needs a manager decision before a cycle may close (BR-05, FR-28).
CREATE FUNCTION gms.cycle_blockers(p_cycle uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE c gms.reading_cycles; v_tasks integer; v_visits integer; v_reports integer;
BEGIN
 PERFORM gms.require_role('manager');
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 SELECT count(*) INTO v_tasks FROM gms.reading_tasks
  WHERE cycle_id = p_cycle AND status IN ('assigned','in_progress','pending_review');
 SELECT count(*) INTO v_visits FROM gms.field_visits v
  WHERE v.record_status IN ('awaiting_photo','pending_review','exception')
    AND (EXISTS (SELECT 1 FROM gms.reading_tasks t WHERE t.id = v.task_id AND t.cycle_id = p_cycle)
      OR gms.local_date(COALESCE(v.verified_captured_at, v.captured_at_device)) BETWEEN c.starts_on AND c.ends_on);
 SELECT count(*) INTO v_reports FROM gms.visit_error_reports e JOIN gms.field_visits v ON v.id = e.visit_id
  WHERE e.acknowledged_at IS NULL
    AND (EXISTS (SELECT 1 FROM gms.reading_tasks t WHERE t.id = v.task_id AND t.cycle_id = p_cycle)
      OR gms.local_date(COALESCE(v.verified_captured_at, v.captured_at_device)) BETWEEN c.starts_on AND c.ends_on);
 RETURN jsonb_build_object('unresolved_tasks', v_tasks, 'unresolved_visits', v_visits, 'open_error_reports', v_reports);
END $$;

-- Atomic close: one final rate, one final statement per subscriber (many reading lines),
-- the EXACT charge posted once; sub-shekel remainder stays in the signed ledger balance.
CREATE FUNCTION gms.finalize_cycle(p_cycle uuid, p_rate numeric)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = gms, pg_temp AS $$
DECLARE v_actor uuid; c gms.reading_cycles; s record; v_statement uuid; n integer := 0;
 v_charge numeric; v_kwh numeric; v_open numeric; v_close numeric; v_block jsonb;
BEGIN
 v_actor := gms.require_role('manager');
 IF p_rate IS NULL OR p_rate < 0 OR scale(p_rate) > 6 OR p_rate >= 10000000000 THEN
  PERFORM gms.fail('GM422', 'invalid_rate', 'السعر النهائي يجب أن يكون غير سالب وبست منازل عشرية كحد أقصى');
 END IF;
 PERFORM pg_advisory_xact_lock(6202201);
 SELECT * INTO c FROM gms.reading_cycles WHERE id = p_cycle FOR UPDATE;
 IF NOT FOUND THEN PERFORM gms.fail('GM404', 'cycle_not_found', 'الدورة غير موجودة'); END IF;
 IF c.state <> 'open' THEN PERFORM gms.fail('GM409', 'cycle_not_open', 'الدورة ليست مفتوحة'); END IF;
 v_block := gms.cycle_blockers(p_cycle);
 IF (v_block->>'unresolved_tasks')::int > 0 THEN
  PERFORM gms.fail('GM409', 'unresolved_tasks', format('لا يمكن إغلاق الدورة: %s مهمة لم تُحسم', v_block->>'unresolved_tasks'));
 END IF;
 IF (v_block->>'unresolved_visits')::int > 0 THEN
  PERFORM gms.fail('GM409', 'unresolved_visits', format('لا يمكن إغلاق الدورة: %s زيارة بانتظار قرار المدير', v_block->>'unresolved_visits'));
 END IF;
 IF (v_block->>'open_error_reports')::int > 0 THEN
  PERFORM gms.fail('GM409', 'open_error_reports', format('لا يمكن إغلاق الدورة: %s بلاغ خطأ لم يُعالج', v_block->>'open_error_reports'));
 END IF;
 IF EXISTS (SELECT 1 FROM gms.statement_versions WHERE cycle_id = p_cycle AND state = 'final') THEN
  PERFORM gms.fail('GM409', 'already_finalized', 'للدورة كشوف نهائية بالفعل');
 END IF;
 PERFORM set_config('gms.finalizing', p_cycle::text, true);
 INSERT INTO gms.cycle_price_decisions(cycle_id, provisional_rate_ils_per_kwh, final_rate_ils_per_kwh, final_selected_by, finalized_at)
 VALUES (p_cycle, p_rate, p_rate, v_actor, now())
 ON CONFLICT (cycle_id) DO UPDATE SET final_rate_ils_per_kwh = EXCLUDED.final_rate_ils_per_kwh,
  final_selected_by = EXCLUDED.final_selected_by, finalized_at = EXCLUDED.finalized_at;
 FOR s IN SELECT DISTINCT subscriber_id FROM gms.approved_readings
   WHERE cycle_id = p_cycle AND state = 'active' ORDER BY subscriber_id LOOP
  PERFORM gms._lock_account(s.subscriber_id);
  v_open := gms.ledger_balance(s.subscriber_id);
  SELECT COALESCE(sum(consumption_kwh), 0), COALESCE(sum(round(consumption_kwh * p_rate, 8)), 0)
    INTO v_kwh, v_charge FROM gms.approved_readings
   WHERE cycle_id = p_cycle AND subscriber_id = s.subscriber_id AND state = 'active';
  v_close := v_open + v_charge;
  INSERT INTO gms.statement_versions(statement_no, subscriber_id, cycle_id, revision, state, provisional,
    rate_snapshot_ils_per_kwh, consumption_kwh, charge_exact_ils, opening_ledger_balance_ils, closing_ledger_balance_ils,
    carry_in_ils, credits_in_ils, requested_whole_ils, carry_out_ils, credits_out_ils, finalized_at)
  VALUES ('ST-' || to_char(nextval('gms.statement_no_seq'), 'FM00000000'), s.subscriber_id, p_cycle, 1, 'final', false,
    p_rate, v_kwh, v_charge, v_open, v_close,
    CASE WHEN v_open > 0 THEN v_open - trunc(v_open) ELSE 0 END, GREATEST(0, -v_open),
    GREATEST(0, trunc(v_close)),
    CASE WHEN v_close > 0 THEN v_close - trunc(v_close) ELSE 0 END, GREATEST(0, -v_close), now())
  RETURNING id INTO v_statement;
  INSERT INTO gms.statement_reading_lines(statement_id, approved_reading_id, previous_value_kwh, current_value_kwh,
    consumption_kwh, rate_snapshot, exact_charge_ils)
  SELECT v_statement, id, previous_value_kwh, current_value_kwh, consumption_kwh, p_rate, round(consumption_kwh * p_rate, 8)
   FROM gms.approved_readings WHERE subscriber_id = s.subscriber_id AND cycle_id = p_cycle AND state = 'active';
  INSERT INTO gms.final_reading_allocations(approved_reading_id, statement_id)
  SELECT approved_reading_id, v_statement FROM gms.statement_reading_lines WHERE statement_id = v_statement;
  IF v_charge <> 0 THEN
   INSERT INTO gms.ledger_entries(subscriber_id, source_type, source_id, signed_amount_ils, posted_by)
   VALUES (s.subscriber_id, 'final_statement', v_statement, v_charge, v_actor);
  END IF;
  PERFORM gms._reconcile_account(s.subscriber_id);
  UPDATE gms.billing_accounts SET last_finalized_cycle_id = p_cycle WHERE subscriber_id = s.subscriber_id;
  n := n + 1;
 END LOOP;
 UPDATE gms.reading_cycles SET state = 'closed', closed_by = v_actor, closed_at = now() WHERE id = p_cycle;
 PERFORM set_config('gms.finalizing', '', true);
 RETURN n;
END $$;

-- Read model: one row per subscriber derived from the single ledger (FR-27).
CREATE VIEW gms.v_subscriber_account AS
SELECT s.id AS subscriber_id,
 COALESCE(l.balance, 0) AS balance_exact_ils,
 GREATEST(0, trunc(COALESCE(l.balance, 0))) AS requested_whole_ils,
 CASE WHEN COALESCE(l.balance, 0) > 0 THEN COALESCE(l.balance, 0) - trunc(COALESCE(l.balance, 0)) ELSE 0 END AS carry_fraction_ils,
 GREATEST(0, -COALESCE(l.balance, 0)) AS credit_balance_ils,
 COALESCE(l.charged, 0) AS total_charged_ils,
 COALESCE(l.paid, 0) AS total_paid_ils,
 COALESCE(l.adjusted, 0) AS total_adjusted_ils,
 COALESCE(l.opening, 0) AS opening_receivable_ils
FROM gms.subscribers s
LEFT JOIN (
 SELECT subscriber_id, SUM(signed_amount_ils) AS balance,
  SUM(signed_amount_ils) FILTER (WHERE source_type = 'final_statement') AS charged,
  -SUM(signed_amount_ils) FILTER (WHERE source_type IN ('payment','payment_reversal')) AS paid,
  SUM(signed_amount_ils) FILTER (WHERE source_type = 'adjustment') AS adjusted,
  SUM(signed_amount_ils) FILTER (WHERE source_type = 'opening_receivable') AS opening
 FROM gms.ledger_entries GROUP BY subscriber_id
) l ON l.subscriber_id = s.id;
