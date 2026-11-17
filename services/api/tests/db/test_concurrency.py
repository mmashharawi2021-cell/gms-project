"""P1/P2 — real concurrent sessions: no double posting, no forked chain, no duplicate visits (AT-12/14/28/29)."""
import threading
import uuid
from decimal import Decimal as D

from tests.world import DbError, World


def race(w: World, n: int, fn):
    """Run fn(i, conn) in n threads, each on its own connection, released together."""
    barrier, out = threading.Barrier(n), [None] * n

    def run(i):
        conn = w.connect()
        try:
            barrier.wait(timeout=20)
            out[i] = ("ok", fn(i, conn))
        except DbError as e:
            out[i] = ("err", e.code)
        except Exception as e:  # deadlocks/serialization failures must not happen
            out[i] = ("crash", repr(e))
        finally:
            conn.close()

    threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    [t.start() for t in threads]
    [t.join(60) for t in threads]
    assert not [o for o in out if o is None or o[0] == "crash"], out
    return out


def billed(w: World):
    c, sub, inst, task = w.week()
    w.read_and_approve(sub, inst, "110.00", w.at(-10), task)
    w.finalize(c, "10")
    return c, sub, inst


def test_same_payment_key_ten_sessions_one_receipt(world: World):
    w = world
    _, sub, _ = billed(w)
    key = uuid.uuid4()
    out = race(w, 10, lambda i, conn: w.pay(sub, "40", key=key, reference="R1", conn=conn))
    assert {o[0] for o in out} == {"ok"} and len({o[1] for o in out}) == 1
    assert w.val("SELECT count(*) FROM gms.payment_receipts") == 1
    assert w.val("SELECT count(*) FROM gms.ledger_entries WHERE source_type='payment'") == 1
    assert w.balance(sub) == D("60")


def test_distinct_concurrent_payments_all_counted_once(world: World):
    w = world
    _, sub, _ = billed(w)
    out = race(w, 12, lambda i, conn: w.pay(sub, "1.25", conn=conn))
    assert all(o[0] == "ok" for o in out) and len({o[1] for o in out}) == 12
    assert w.balance(sub) == D("100") - D("15")
    acc = w.one("SELECT * FROM gms.billing_accounts WHERE subscriber_id=%s", (sub,))
    assert acc["balance_exact_ils"] == D("85")


def test_concurrent_reversal_posts_single_counter_entry(world: World):
    w = world
    _, sub, _ = billed(w)
    pay = w.pay(sub, "30")
    out = race(w, 8, lambda i, conn: w.call(w.manager, "SELECT gms.reverse_payment(%s,'خطأ')", (pay,), conn=conn))
    assert len({o[1] for o in out}) == 1
    assert w.val("SELECT count(*) FROM gms.payment_reversals") == 1 and w.balance(sub) == D("100")


def test_same_visit_uuid_from_ten_sessions_stored_once(world: World):
    w = world
    c, sub, inst, task = w.week()
    p, visit = w.payload(sub, inst, "101.43", w.at(-10), task=task), uuid.uuid4()
    out = race(w, 10, lambda i, conn: w.receive(p, visit=visit, conn=conn)["result"])
    assert sorted(o[1] for o in out) == ["accepted"] + ["already_received"] * 9
    assert w.val("SELECT count(*) FROM gms.field_visits") == 1
    op = uuid.uuid4()
    out = race(w, 6, lambda i, conn: w.receive(dict(p, reading_value_kwh="500"), visit=uuid.uuid4() if False else visit, op=op, conn=conn)["result"])
    assert {o[1] for o in out} == {"conflict"}


def test_same_visit_approved_concurrently_once(world: World):
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101.43", w.at(-10), task=task)
    out = race(w, 8, lambda i, conn: w.approve(v, conn=conn))
    assert sum(1 for o in out if o[0] == "ok") == 1
    assert {o[1] for o in out if o[0] == "err"} == {"visit_resolved"}
    assert w.val("SELECT count(*) FROM gms.approved_readings") == 1


def test_concurrent_approvals_on_one_meter_keep_linear_chain(world: World):
    w = world
    c, sub, inst, task = w.week()
    visits = [w.visit(sub, inst, f"{101 + i}.00", w.at(-12 + i, 8), task=w.task(c, sub, -12 + i) if i else task) for i in range(5)]
    for _ in range(6):   # hammer until all are in: later ones are refused while an earlier one is pending
        pending = [v for v in visits if w.val("SELECT record_status FROM gms.field_visits WHERE id=%s", (v,)) == "pending_review"]
        if not pending:
            break
        out = race(w, len(pending), lambda i, conn: w.approve(pending[i], conn=conn))
        assert {o[1] for o in out if o[0] == "err"} <= {"earlier_visit_pending"}
    chain = w.q("SELECT id, previous_approved_id, opening_baseline_id, previous_value_kwh, current_value_kwh FROM gms.approved_readings WHERE state='active' ORDER BY verified_captured_at")
    assert len(chain) == 5
    assert chain[0]["opening_baseline_id"] is not None
    for prev, cur in zip(chain, chain[1:]):
        assert cur["previous_approved_id"] == prev["id"] and cur["previous_value_kwh"] == prev["current_value_kwh"]
    assert w.val("SELECT sum(consumption_kwh) FROM gms.approved_readings WHERE state='active'") == D("5.00")


def test_concurrent_finalize_creates_statements_once(world: World):
    w = world
    c, sub, inst, task = w.week()
    subs = [(sub, inst, task)] + [(*w.add_subscriber(), None) for _ in range(5)]
    for s, i, t in subs:
        w.read_and_approve(s, i, "103.33", w.at(-10), t or w.task(c, s, -10))
    out = race(w, 5, lambda i, conn: w.finalize(c, "7.123456", conn=conn))
    assert sorted(o[0] for o in out) == ["err"] * 4 + ["ok"] and [o[1] for o in out if o[0] == "ok"] == [6]
    assert {o[1] for o in out if o[0] == "err"} == {"cycle_not_open"}
    assert w.val("SELECT count(*) FROM gms.statement_versions") == 6
    assert w.val("SELECT count(*) FROM gms.ledger_entries") == 6
    assert w.val("SELECT sum(signed_amount_ils) FROM gms.ledger_entries") == D("3.33") * D("7.123456") * 6


def test_approval_racing_with_close_never_leaves_unbilled_reading(world: World):
    w = world
    c, sub, inst, task = w.week()
    others = [w.add_subscriber() for _ in range(6)]
    w.read_and_approve(sub, inst, "101", w.at(-10), task)
    pend = [w.visit(s, i, "105", w.at(-9), task=w.task(c, s, -9)) for s, i in others]

    def fn(i, conn):
        return w.finalize(c, "10", conn=conn) if i == len(pend) else w.approve(pend[i], conn=conn)

    out = race(w, len(pend) + 1, fn)
    if w.val("SELECT state FROM gms.reading_cycles WHERE id=%s", (c,)) != "closed":
        assert out[-1] == ("err", "unresolved_tasks") or out[-1] == ("err", "unresolved_visits")
        for v in pend:
            if w.val("SELECT record_status FROM gms.field_visits WHERE id=%s", (v,)) == "pending_review":
                w.approve(v)
        w.finalize(c, "10")
    assert w.val("SELECT count(*) FROM gms.approved_readings a WHERE a.cycle_id=%s AND a.state='active' AND NOT EXISTS (SELECT 1 FROM gms.final_reading_allocations f WHERE f.approved_reading_id=a.id)", (c,)) == 0
    assert w.val("SELECT count(*) FROM gms.statement_versions") == 7
    assert w.val("SELECT sum(signed_amount_ils) FROM gms.ledger_entries") == D("10") + 6 * D("50")


def test_concurrent_closed_cycle_correction_posts_once(world: World):
    w = world
    c, sub, inst, task = w.week()
    r = w.read_and_approve(sub, inst, "110.00", w.at(-10), task)
    w.finalize(c, "10")
    key = uuid.uuid4()
    out = race(w, 6, lambda i, conn: w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'تصحيح',%s)", (r, D("108.00"), key), conn=conn))
    assert {o[0] for o in out} == {"ok"} and len({o[1] for o in out}) == 1
    assert w.val("SELECT count(*) FROM gms.financial_adjustments") == 1
    assert w.balance(sub) == D("80")
    # two DIFFERENT corrections racing: exactly one wins, the other sees a non-active reading
    out = race(w, 2, lambda i, conn: w.call(w.manager, "SELECT gms.correct_approved_reading(%s,%s,'تصحيح',%s)", (out[0][1], D(f"10{6 + i}.00"), uuid.uuid4()), conn=conn))
    assert sorted(o[0] for o in out) == ["err", "ok"]
    assert w.val("SELECT count(*) FROM gms.approved_readings WHERE state='active'") == 1
