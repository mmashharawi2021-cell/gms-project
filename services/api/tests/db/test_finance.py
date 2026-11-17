"""P2 — accounting engine against an independent Decimal oracle (AT-07/08/09/10/19/26/27/28/29)."""
import random
import uuid
from decimal import Decimal as D

from tests.db.test_integrity import fails
from tests.oracle import LedgerOracle
from tests.world import World


def check(w: World, sub, oracle: LedgerOracle):
    acc = w.account(sub)
    assert acc["balance_exact_ils"] == oracle.balance
    assert acc["requested_whole_ils"] == oracle.requested
    assert acc["carry_fraction_ils"] == oracle.carried
    assert acc["credit_balance_ils"] == oracle.credit
    # cached projection equals the ledger too (when an account row exists)
    row = w.one("SELECT * FROM gms.billing_accounts WHERE subscriber_id=%s", (sub,))
    if row:
        assert (row["balance_exact_ils"], row["carry_fraction_ils"], row["credit_balance_ils"]) == (oracle.balance, oracle.carried, oracle.credit)


def test_fraction_carry_payment_and_credit_srs_17_3(world: World):
    """SRS 17.3 table, step by step: 21.45 -> pay 21 -> 15.80 -> pay 16 -> adjustment -8."""
    w, o = world, LedgerOracle()
    c1, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "101.43", w.at(-10), t1)
    assert w.balance(sub) == 0  # approval alone posts nothing
    assert w.finalize(c1, "15") == 1
    o.charge("1.43", "15")
    s1 = w.statement(c1, sub)
    assert (s1["charge_exact_ils"], s1["requested_whole_ils"], s1["carry_out_ils"]) == (D("21.45"), 21, D("0.45"))
    check(w, sub, o)
    w.pay(sub, "21"); o.post("-21")
    assert w.balance(sub) == D("0.45")
    check(w, sub, o)
    c2 = w.cycle("QA-C2", -6, 0)
    w.read_and_approve(sub, inst, "102.22", w.at(-3), w.task(c2, sub, -3))
    w.finalize(c2, "20"); o.charge("0.79", "20")
    s2 = w.statement(c2, sub)
    assert (s2["charge_exact_ils"], s2["carry_in_ils"], s2["requested_whole_ils"], s2["carry_out_ils"]) == (D("15.80"), D("0.45"), 16, D("0.25"))
    assert w.balance(sub) == D("16.25")
    w.pay(sub, "16"); o.post("-16")
    assert w.balance(sub) == D("0.25")
    w.adjust(sub, "-8", "تسوية تعويضية"); o.post("-8")
    acc = w.account(sub)
    assert (acc["balance_exact_ils"], acc["requested_whole_ils"], acc["credit_balance_ils"]) == (D("-7.75"), 0, D("7.75"))
    check(w, sub, o)
    # the first statement was never touched by later events
    assert w.statement(c1, sub) == s1
    assert w.val("SELECT count(*) FROM gms.final_reading_allocations") == 2


def test_two_readings_one_week_one_statement(world: World, owner_url):
    """AT-08 / AT-29 / BR-19."""
    w = world
    c1, sub, inst, t1 = w.week()
    r1 = w.read_and_approve(sub, inst, "101.20", w.at(-11), t1)
    r2 = w.read_and_approve(sub, inst, "101.43", w.at(-9), w.task(c1, sub, -9))
    assert w.finalize(c1, "15") == 1
    st = w.statement(c1, sub)
    lines = w.q("SELECT * FROM gms.statement_reading_lines WHERE statement_id=%s ORDER BY current_value_kwh", (st["id"],))
    assert [(l["consumption_kwh"], l["exact_charge_ils"]) for l in lines] == [(D("1.20"), D("18")), (D("0.23"), D("3.45"))]
    assert st["consumption_kwh"] == D("1.43") and st["charge_exact_ils"] == D("21.45")
    assert w.val("SELECT count(*) FROM gms.statement_versions WHERE cycle_id=%s AND subscriber_id=%s", (c1, sub)) == 1
    assert w.val("SELECT count(*) FROM gms.ledger_entries WHERE subscriber_id=%s", (sub,)) == 1
    assert {a["approved_reading_id"] for a in w.q("SELECT approved_reading_id FROM gms.final_reading_allocations")} == {r1, r2}
    # finalizing again is refused; the same reading can never be allocated twice
    with fails("cycle_not_open", "GM409"):
        w.finalize(c1, "15")
    import psycopg
    import pytest
    with psycopg.connect(owner_url, autocommit=True) as oc:
        oc.execute("SELECT set_config('gms.actor_id', %s, false)", (str(w.manager),))
        with pytest.raises(psycopg.Error):
            oc.execute("INSERT INTO gms.final_reading_allocations(approved_reading_id, statement_id) VALUES (%s,%s)", (r1, st["id"]))


def test_reading_spanning_weeks_uses_current_week_rate(world: World):
    """BR-17: the whole difference since the previous approved reading is priced at the week of the current reading."""
    w = world
    c1, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "105.00", w.at(-12), t1)   # 5 kWh in week 1
    w.finalize(c1, "10")
    c2 = w.cycle("QA-C2", -6, 0)
    # next reading 6 days later: consumption happened across both weeks, priced entirely at week-2 rate
    w.read_and_approve(sub, inst, "115.00", w.at(-2), w.task(c2, sub, -2))
    w.finalize(c2, "25")
    assert w.statement(c1, sub)["charge_exact_ils"] == D("50")
    assert w.statement(c2, sub)["charge_exact_ils"] == D("250")
    assert w.balance(sub) == D("300")


def test_provisional_rate_changes_never_post_and_final_rate_recomputes(world: World):
    """AT-07 / BR-18."""
    w = world
    c1, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "110.00", w.at(-12), t1)
    w.finalize(c1, "10")
    before = w.statement(c1, sub)
    c2 = w.cycle("QA-C2", -6, 0)
    for day, rate in ((-6, "30"), (-5, "31.5"), (-4, "29.25")):
        w.call(w.manager, "SELECT gms.set_provisional_rate(%s,%s,%s,'تغيير يومي')", (c2, w.today.fromordinal(w.today.toordinal() + day), D(rate)))
    assert w.val("SELECT count(*) FROM gms.tariff_change_events WHERE cycle_id=%s", (c2,)) == 3
    assert w.val("SELECT provisional_rate_ils_per_kwh FROM gms.cycle_price_decisions WHERE cycle_id=%s", (c2,)) == D("29.25")
    w.read_and_approve(sub, inst, "112.00", w.at(-5), w.task(c2, sub, -5))
    w.read_and_approve(sub, inst, "113.50", w.at(-2), w.task(c2, sub, -2))
    assert w.balance(sub) == D("100")  # provisional figures are not posted
    with fails("tariff_date_out_of_cycle"):
        w.call(w.manager, "SELECT gms.set_provisional_rate(%s,%s,5,'x')", (c2, w.today.fromordinal(w.today.toordinal() + 30)))
    w.finalize(c2, "28")
    st = w.statement(c2, sub)
    lines = w.q("SELECT exact_charge_ils, rate_snapshot FROM gms.statement_reading_lines WHERE statement_id=%s ORDER BY 1", (st["id"],))
    assert [(l["exact_charge_ils"], l["rate_snapshot"]) for l in lines] == [(D("42"), D("28")), (D("56"), D("28"))]
    assert st["charge_exact_ils"] == D("98")
    assert w.statement(c1, sub) == before  # previous week untouched
    with fails("cycle_closed"):
        w.call(w.manager, "SELECT gms.set_provisional_rate(%s,%s,5,'x')", (c2, w.today))


def test_partial_payments_reversal_and_idempotency(world: World):
    """AT-10 / AT-28 / BR-29."""
    w, o = world, LedgerOracle()
    c1, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "110.00", w.at(-10), t1)
    w.finalize(c1, "15.025"); o.charge("10", "15.025")   # 150.25
    key = uuid.uuid4()
    p1 = w.pay(sub, "100", key=key, reference="إيصال 1"); o.post("-100")
    assert w.pay(sub, "100", key=key, reference="إيصال 1") == p1            # retry -> same receipt
    assert w.val("SELECT count(*) FROM gms.payment_receipts WHERE subscriber_id=%s", (sub,)) == 1
    with fails("idempotency_conflict", "GM409"):
        w.pay(sub, "90", key=key, reference="إيصال 1")                       # same key, other amount
    acc = w.account(sub)
    assert (acc["requested_whole_ils"], acc["carry_fraction_ils"], acc["total_paid_ils"], acc["total_charged_ils"]) == (50, D("0.25"), D("100"), D("150.25"))
    p2 = w.pay(sub, "30"); o.post("-30")
    check(w, sub, o)
    assert w.account(sub)["requested_whole_ils"] == 20
    # reversal = counter entry; original rows stay
    rev = w.call(w.manager, "SELECT gms.reverse_payment(%s,'أُدخلت بالخطأ')", (p2,)); o.post("30")
    assert w.call(w.manager, "SELECT gms.reverse_payment(%s,'again')", (p2,)) == rev    # idempotent
    assert w.val("SELECT count(*) FROM gms.payment_receipts WHERE id=%s", (p2,)) == 1
    assert w.val("SELECT count(*) FROM gms.ledger_entries WHERE source_type='payment' AND source_id=%s", (p2,)) == 1
    assert w.val("SELECT count(*) FROM gms.ledger_entries WHERE source_type='payment_reversal'") == 1
    check(w, sub, o)
    assert w.account(sub)["total_paid_ils"] == D("100")
    for bad in ("0", "-5", "10.555"):
        with fails("invalid_payment", "GM422"):
            w.pay(sub, bad)
    with fails("invalid_payment"):
        w.pay(sub, "10", method="crypto")
    with fails("reason_required"):
        w.call(w.manager, "SELECT gms.reverse_payment(%s,'  ')", (p1,))
    # FR-27: issuing a statement never means it was paid
    sub2, inst2 = w.add_subscriber()
    assert w.account(sub2)["total_paid_ils"] == 0


def test_credit_larger_than_next_charge_survives(world: World):
    """AT-19 / AT-27 / BR-22: closed-cycle credit of 8, later charge 5 -> request 0, credit 3; then 2 -> credit 1."""
    w, o = world, LedgerOracle()
    c1, sub, inst, t1 = w.week("QA-C1", -20, -14)
    w.read_and_approve(sub, inst, "104.00", w.at(-17), t1)
    w.finalize(c1, "10"); o.charge("4", "10")
    w.pay(sub, "40"); o.post("-40")
    w.adjust(sub, "-8"); o.post("-8")
    c2 = w.cycle("QA-C2", -13, -7)
    w.read_and_approve(sub, inst, "104.50", w.at(-10), w.task(c2, sub, -10))
    w.finalize(c2, "10"); o.charge("0.5", "10")
    s2 = w.statement(c2, sub)
    assert (s2["credits_in_ils"], s2["charge_exact_ils"], s2["requested_whole_ils"], s2["credits_out_ils"]) == (D("8"), D("5"), 0, D("3"))
    c3 = w.cycle("QA-C3", -6, 0)
    w.read_and_approve(sub, inst, "104.70", w.at(-3), w.task(c3, sub, -3))
    w.finalize(c3, "10"); o.charge("0.2", "10")
    assert w.statement(c3, sub)["credits_out_ils"] == D("1")
    check(w, sub, o)
    assert o.credit == D("1")


def test_zero_consumption_keeps_fraction_and_posts_nothing(world: World):
    """AT-19: zero consumption -> statement with zero charge, no zero ledger row, carry preserved."""
    w = world
    c1, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "101.43", w.at(-10), t1)
    w.finalize(c1, "15")
    w.pay(sub, "21")
    c2 = w.cycle("QA-C2", -6, 0)
    w.read_and_approve(sub, inst, "101.43", w.at(-3), w.task(c2, sub, -3))
    w.finalize(c2, "20")
    s2 = w.statement(c2, sub)
    assert (s2["charge_exact_ils"], s2["requested_whole_ils"], s2["carry_in_ils"], s2["carry_out_ils"]) == (0, 0, D("0.45"), D("0.45"))
    assert w.val("SELECT count(*) FROM gms.ledger_entries WHERE source_type='final_statement' AND subscriber_id=%s", (sub,)) == 1
    assert w.balance(sub) == D("0.45")


def test_opening_receivable_needs_real_source(world: World):
    w = world.bootstrap()
    sub, _ = w.add_subscriber()
    with fails("invalid_opening_receivable", "GM422"):
        w.call(w.manager, "SELECT gms.record_opening_receivable(%s,120.50,%s,'')", (sub, w.today))
    w.call(w.manager, "SELECT gms.record_opening_receivable(%s,120.50,%s,'كشف Excel المعتمد صف 12')", (sub, w.today))
    assert w.balance(sub) == D("120.50")
    with fails("opening_receivable_exists", "GM409"):
        w.call(w.manager, "SELECT gms.record_opening_receivable(%s,10,%s,'again')", (sub, w.today))
    acc = w.account(sub)
    assert (acc["opening_receivable_ils"], acc["requested_whole_ils"], acc["carry_fraction_ils"]) == (D("120.50"), 120, D("0.50"))


def test_open_cycle_correction_recomputes_without_ledger(world: World):
    """AT-09 (open week): corrected value replaces the active reading; history kept; nothing posted."""
    w = world
    c1, sub, inst, t1 = w.week()
    r1 = w.read_and_approve(sub, inst, "105.00", w.at(-11), t1)
    r2 = w.read_and_approve(sub, inst, "108.00", w.at(-9), w.task(c1, sub, -9))
    key = uuid.uuid4()
    n1 = w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'قراءة الصورة 104',%s)", (r1, D("104.00"), key))
    assert w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'قراءة الصورة 104',%s)", (r1, D("104.00"), key)) == n1
    with fails("idempotency_conflict"):
        w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'x',%s)", (r1, D("103.00"), key))
    rows = w.q("SELECT state, previous_value_kwh, current_value_kwh, supersedes_id FROM gms.approved_readings WHERE installation_id=%s ORDER BY approved_at, current_value_kwh", (inst,))
    active = [(r["previous_value_kwh"], r["current_value_kwh"]) for r in rows if r["state"] == "active"]
    assert sorted(active) == [(D("100.00"), D("104.00")), (D("104.00"), D("108.00"))]     # chain re-linked
    assert sum(1 for r in rows if r["state"] == "superseded") == 2                        # originals preserved
    assert w.val("SELECT count(*) FROM gms.ledger_entries") == 0
    with fails("reading_not_active"):
        w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'x',%s)", (r1, D("103.00"), uuid.uuid4()))
    with fails("chain_would_break"):
        w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'x',%s)", (n1, D("109.00"), uuid.uuid4()))
    w.finalize(c1, "10")
    assert w.statement(c1, sub)["charge_exact_ils"] == D("80")    # 8 kWh total, never double counted
    assert w.val("SELECT count(*) FROM gms.statement_reading_lines") == 2
    assert r2 is not None


def test_closed_cycle_correction_posts_single_adjustment(world: World):
    """AT-09 (closed week) / BR-21: statement untouched, exact difference posted once as an adjustment."""
    w, o = world, LedgerOracle()
    c1, sub, inst, t1 = w.week("QA-C1", -20, -14)
    r1 = w.read_and_approve(sub, inst, "110.00", w.at(-17), t1)
    w.finalize(c1, "10"); o.charge("10", "10")
    c2 = w.cycle("QA-C2", -13, -7)
    w.read_and_approve(sub, inst, "115.00", w.at(-10), w.task(c2, sub, -10))
    w.finalize(c2, "20"); o.charge("5", "20")
    c3 = w.cycle("QA-C3", -6, 0)
    w.read_and_approve(sub, inst, "118.00", w.at(-3), w.task(c3, sub, -3))    # open week
    st1, st2 = w.statement(c1, sub), w.statement(c2, sub)
    ledger_before = w.q("SELECT id, signed_amount_ils FROM gms.ledger_entries ORDER BY seq")
    # manager finds the week-1 reading was really 108 (not 110): week1 -2 kWh @10, week2 +2 kWh @20
    key = uuid.uuid4()
    w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'خطأ قراءة مثبت بالصورة',%s)", (r1, D("108.00"), key))
    o.post("-20"); o.post("40")
    w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'خطأ قراءة مثبت بالصورة',%s)", (r1, D("108.00"), key))   # retry: no double post
    adj = w.q("SELECT adjustment_ils, kind, source_cycle_id FROM gms.financial_adjustments ORDER BY adjustment_ils")
    assert [(a["adjustment_ils"], a["kind"], a["source_cycle_id"]) for a in adj] == [(D("-20"), "reading_correction", c1), (D("40"), "reading_correction", c2)]
    assert (w.statement(c1, sub), w.statement(c2, sub)) == (st1, st2)          # history untouched
    assert w.q("SELECT id, signed_amount_ils FROM gms.ledger_entries ORDER BY seq")[: len(ledger_before)] == ledger_before
    check(w, sub, o)
    # open week is recomputed from the re-linked chain: 118 - 115 = 3 kWh, unchanged, billed once at close
    w.finalize(c3, "30"); o.charge("3", "30")
    assert w.statement(c3, sub)["charge_exact_ils"] == D("90")
    check(w, sub, o)
    assert w.val("SELECT count(*) FROM gms.approved_readings WHERE installation_id=%s AND state='active'", (inst,)) == 3


def test_late_reading_for_closed_week_becomes_adjustment(world: World):
    """BR-25 / FR-21: arrival after close never reopens the week."""
    w = world
    c1, sub, inst, t1 = w.week("QA-C1", -13, -7)
    sub2, inst2 = w.add_subscriber()
    w.read_and_approve(sub, inst, "101.00", w.at(-10), t1)
    w.finalize(c1, "10")
    c2 = w.cycle("QA-C2", -6, 0)
    res = w.receive(w.payload(sub2, inst2, "107.50", w.at(-9), reason="وصلت متأخرة"))
    assert "cycle_closed" in res["flags"]
    w.photo(res["visit_id"])
    assert w.val("SELECT record_status FROM gms.field_visits WHERE id=%s", (res["visit_id"],)) == "exception"
    with fails("exceptions_need_ack"):
        w.approve(res["visit_id"])
    with fails("cycle_closed"):
        w.approve(res["visit_id"], rationale="x", ack=True)
    w.approve(res["visit_id"], rationale="قراءة موثقة بالصورة", ack=True, late=True)
    assert w.val("SELECT state FROM gms.reading_cycles WHERE id=%s", (c1,)) == "closed"
    assert w.statement(c1, sub2) is None
    adj = w.one("SELECT * FROM gms.financial_adjustments WHERE subscriber_id=%s", (sub2,))
    assert (adj["adjustment_ils"], adj["kind"], adj["source_cycle_id"]) == (D("75"), "late_reading", c1)
    assert w.balance(sub2) == D("75")
    # the next reading in the open week continues from the late one: no double billing
    w.read_and_approve(sub2, inst2, "108.50", w.at(-2), w.task(c2, sub2, -2))
    w.finalize(c2, "20")
    assert w.balance(sub2) == D("95")


def test_random_scenarios_match_oracle(world: World):
    """G3: many subscribers, several weeks, random readings/payments/adjustments/reversals vs the Decimal oracle."""
    rng = random.Random(22022)
    w = world.bootstrap()
    subs = [w.add_subscriber(opening=f"{rng.randint(0, 5000)}.{rng.randint(0, 99):02d}") for _ in range(12)]
    oracles = {s: LedgerOracle() for s, _ in subs}
    last = {s: w.val("SELECT opening_value_kwh FROM gms.opening_baselines WHERE installation_id=%s", (i,)) for s, i in subs}
    payments: dict = {s: [] for s, _ in subs}
    for week in range(4):
        start = -27 + week * 7
        c = w.cycle(f"QA-W{week}", start, start + 6)
        rate = f"{rng.randint(1, 40)}.{rng.randint(0, 999999):06d}"
        for s, inst in subs:
            kwh_week = D(0)
            for k in range(rng.choice([0, 1, 1, 2, 3])):
                new = last[s] + D(rng.randint(0, 3000)) / 100
                w.read_and_approve(s, inst, new, w.at(start + 1 + k * 2, hour=8 + k), w.task(c, s, start + 1 + k * 2))
                kwh_week += new - last[s]
                last[s] = new
            if kwh_week or True:
                oracles[s].charge(kwh_week, rate) if w.val("SELECT count(*) FROM gms.approved_readings WHERE cycle_id=%s AND subscriber_id=%s AND state='active'", (c, s)) else None
        w.finalize(c, rate)
        for s, _ in subs:
            action = rng.choice(["none", "pay_part", "pay_all", "adjust", "reverse", "pay_part"])
            o = oracles[s]
            if action == "pay_part" and o.requested > 0:
                amt = D(rng.randint(1, int(o.requested)))
                payments[s].append((w.pay(s, amt), amt)); o.post(-amt)
            elif action == "pay_all" and o.requested > 0:
                payments[s].append((w.pay(s, o.requested), o.requested)); o.post(-o.requested)
            elif action == "adjust":
                amt = D(rng.randint(-2000, 2000)) / 100
                if amt:
                    w.adjust(s, amt); o.post(amt)
            elif action == "reverse" and payments[s]:
                pid, amt = payments[s].pop()
                w.call(w.manager, "SELECT gms.reverse_payment(%s,'QA')", (pid,)); o.post(amt)
            check(w, s, o)
            st = w.statement(c, s)
            if st:
                assert st["closing_ledger_balance_ils"] == st["opening_ledger_balance_ils"] + st["charge_exact_ils"]
    # global invariants
    assert w.val("SELECT count(*) FROM (SELECT approved_reading_id FROM gms.final_reading_allocations GROUP BY 1 HAVING count(*)>1) x") == 0
    assert w.val("SELECT count(*) FROM gms.approved_readings a WHERE state='active' AND NOT EXISTS (SELECT 1 FROM gms.final_reading_allocations f WHERE f.approved_reading_id=a.id)") == 0
    assert w.val("SELECT sum(signed_amount_ils) FROM gms.ledger_entries") == sum((o.balance for o in oracles.values()), D(0))
    assert w.val("SELECT count(*) FROM gms.statement_versions s WHERE charge_exact_ils <> (SELECT COALESCE(sum(exact_charge_ils),0) FROM gms.statement_reading_lines l WHERE l.statement_id=s.id)") == 0
