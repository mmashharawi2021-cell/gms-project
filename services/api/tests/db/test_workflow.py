"""P1/P4/P5 database level — scheduling, review workflow, sync intake (AT-01/04/05/06/11/12/13/14/17/20/30)."""
import hashlib
import json
import uuid
from datetime import timedelta
from decimal import Decimal as D

import psycopg
import pytest

from tests.db.test_integrity import fails
from tests.world import World


def day(w: World, n: int):
    return w.today + timedelta(days=n)


def status(w: World, visit):
    return w.val("SELECT record_status FROM gms.field_visits WHERE id=%s", (visit,))


def task_status(w: World, task):
    return w.val("SELECT status FROM gms.reading_tasks WHERE id=%s", (task,))


def test_flexible_intervals_generate_tasks_and_close_without_not_due(world: World):
    """AT-01 / BR-03/04/05."""
    w = world.bootstrap()
    a, inst_a = w.add_subscriber(interval_days=4)
    b, _ = w.add_subscriber(interval_days=7)
    c = w.cycle("QA-C1", 0, 6)
    assert w.val("SELECT gms.next_due_date(%s)", (a,)) == day(w, 4)
    assert w.val("SELECT gms.next_due_date(%s)", (b,)) == day(w, 7)
    assert w.call(w.manager, "SELECT gms.generate_due_tasks(%s)", (c,)) == 1          # only the 4-day subscriber
    assert w.call(w.manager, "SELECT gms.generate_due_tasks(%s)", (c,)) == 0          # idempotent
    t = w.one("SELECT * FROM gms.reading_tasks")
    assert (t["subscriber_id"], t["planned_for"], t["source"], t["assigned_employee_id"]) == (a, day(w, 4), "scheduled", w.employee)
    # manager override of the next date (BR-03)
    with w.tx(w.manager) as cx:
        cx.execute("UPDATE gms.subscriber_schedules SET next_due_override=%s, changed_by=%s WHERE subscriber_id=%s", (day(w, 2), w.manager, b))
    assert w.call(w.manager, "SELECT gms.generate_due_tasks(%s)", (c,)) == 1
    tb = w.val("SELECT id FROM gms.reading_tasks WHERE subscriber_id=%s", (b,))
    # exceptional extra task + date outside the cycle refused
    with fails("planned_out_of_cycle", "GM422"):
        w.call(w.manager, "SELECT gms.create_task(%s,%s,%s,'manager_extra',NULL,NULL)", (c, a, day(w, 9)))
    # reading today -> next due = approved reading date + interval; override consumed
    w.approve(w.visit(a, inst_a, "101.00", w.now(), task=t["id"]))
    assert w.val("SELECT gms.next_due_date(%s)", (a,)) == day(w, 4)
    with fails("unresolved_tasks", "GM409"):
        w.finalize(c, "10")
    w.call(w.manager, "SELECT gms.cancel_task(%s,'تأجيل بقرار المدير')", (tb,))
    with fails("reason_required"):
        w.call(w.manager, "SELECT gms.cancel_task(%s,'')", (tb,))
    assert w.finalize(c, "10") == 1                                                    # not-due subscribers never block
    # non-overlapping weeks (FR-07)
    with fails("cycle_overlap", "GM409"):
        w.call(w.manager, "SELECT gms.create_cycle('QA-OVERLAP',%s,%s)", (day(w, 6), day(w, 12)))


def test_close_blocked_until_everything_is_decided(world: World):
    """AT-30 / FR-28: tasks, any raw visit (even unscheduled) and error reports block the close."""
    w = world
    c, sub, inst, task = w.week()
    sub2, inst2 = w.add_subscriber()
    with fails("unresolved_tasks", "GM409"):
        w.finalize(c, "10")
    v = w.visit(sub, inst, "101", w.at(-10), task=task)
    assert task_status(w, task) == "pending_review"
    with fails("unresolved_tasks"):
        w.finalize(c, "10")
    w.approve(v)
    assert task_status(w, task) == "completed_reading"
    v2 = w.visit(sub2, inst2, "100.5", w.at(-9), photo=False)          # unscheduled, still awaiting its photo
    with fails("unresolved_visits", "GM409"):
        w.finalize(c, "10")
    w.call(w.manager, "SELECT gms.reject_visit(%s,'reject','بدون صورة')", (v2,))
    rep, body = uuid.uuid4(), "أدخلت الرقم خطأ"
    res = w.call(w.employee, "SELECT gms.receive_error_report(%s,%s,%s,%s,%s,%s)", (uuid.uuid4(), rep, w.device, v, body, hashlib.sha256(body.encode()).hexdigest()))
    assert res["result"] == "accepted"
    with fails("open_error_reports", "GM409"):
        w.finalize(c, "10")
    assert w.call(w.manager, "SELECT gms.cycle_blockers(%s)", (c,)) == {"unresolved_tasks": 0, "unresolved_visits": 0, "open_error_reports": 1}
    w.call(w.manager, "SELECT gms.acknowledge_error_report(%s,'روجعت الصورة والقيمة صحيحة')", (rep,))
    assert w.finalize(c, "10") == 1
    assert w.val("SELECT state FROM gms.reading_cycles WHERE id=%s", (c,)) == "closed"


def test_unreadable_closes_without_charge_and_follow_up_uses_new_week(world: World):
    """AT-05 / BR-15/16."""
    w = world
    c1, sub, inst, t1 = w.week()
    u = w.visit(sub, inst, None, w.at(-10), task=t1, kind="unreadable", reason="المشترك غير موجود")
    with fails("not_a_reading"):
        w.approve(u)
    with fails("followup_required", "GM422"):
        w.call(w.manager, "SELECT gms.resolve_unreadable(%s,NULL,NULL)", (u,))
    w.call(w.manager, "SELECT gms.resolve_unreadable(%s,%s,'إغلاق إداري')", (u, day(w, -4)))
    assert (status(w, u), task_status(w, t1)) == ("unreadable_resolved", "completed_unreadable")
    assert w.finalize(c1, "10") == 0
    assert w.val("SELECT count(*) FROM gms.ledger_entries") == 0 and w.val("SELECT count(*) FROM gms.statement_versions") == 0
    c2 = w.cycle("QA-C2", -6, 0)
    assert w.call(w.manager, "SELECT gms.generate_due_tasks(%s)", (c2,)) == 1
    t2 = w.one("SELECT * FROM gms.reading_tasks WHERE cycle_id=%s", (c2,))
    assert t2["planned_for"] == day(w, -4)
    w.approve(w.visit(sub, inst, "103.00", w.at(-4), task=t2["id"]))
    assert w.val("SELECT next_due_override FROM gms.subscriber_schedules WHERE subscriber_id=%s", (sub,)) is None
    w.finalize(c2, "20")
    assert w.balance(sub) == D("60")        # whole difference at the week of the successful reading


def test_raw_readings_wait_for_sequential_manager_approval(world: World, owner_url):
    """AT-04 / AT-14 / BR-11/12: raw data is always kept; the approved chain never forks or double counts."""
    w = world
    c, sub, inst, t1 = w.week()
    v1 = w.visit(sub, inst, "101.00", w.at(-10, 8), task=t1)
    v2 = w.visit(sub, inst, "102.00", w.at(-10, 12))                   # same day, before v1 is approved
    v3 = w.visit(sub, inst, "102.00", w.at(-10, 13))
    assert w.val("SELECT count(*) FROM gms.field_visits") == 3
    assert w.val("SELECT count(*) FROM gms.approved_readings") == 0 and w.val("SELECT count(*) FROM gms.ledger_entries") == 0
    assert status(w, v2) == "exception"                                # unscheduled -> needs explicit manager decision
    with fails("earlier_visit_pending", "GM409"):
        w.approve(v2, rationale="x", ack=True)
    r1 = w.approve(v1)
    with fails("exceptions_need_ack", "GM409"):
        w.approve(v2)
    w.approve(v2, rationale="قراءة إضافية موثقة", ack=True)
    w.call(w.manager, "SELECT gms.reject_visit(%s,'duplicate','مكررة لنفس اليوم')", (v3,))
    with fails("visit_resolved"):
        w.approve(v1)
    # an older raw reading arriving later cannot be inserted behind the chain head
    v0 = w.visit(sub, inst, "100.50", w.at(-11))
    with fails("out_of_order", "GM409"):
        w.approve(v0, rationale="x", ack=True)
    chain = w.q("SELECT previous_value_kwh, current_value_kwh FROM gms.approved_readings WHERE state='active' ORDER BY verified_captured_at")
    assert [(r["previous_value_kwh"], r["current_value_kwh"]) for r in chain] == [(D("100.00"), D("101.00")), (D("101.00"), D("102.00"))]
    # forging a second successor of the same predecessor is impossible even for the table owner
    with psycopg.connect(owner_url, autocommit=True) as oc:
        oc.execute("SELECT set_config('gms.actor_id', %s, false)", (str(w.manager),))
        rv = oc.execute("INSERT INTO gms.visit_reviews(visit_id,reviewed_by,decision) VALUES (%s,%s,'approve_reading') RETURNING id", (v0, w.manager)).fetchone()[0]
        oc.execute("UPDATE gms.field_visits SET record_status='pending_review' WHERE id=%s", (v0,))
        for prev_col, prev in (("opening_baseline_id", w.val("SELECT id FROM gms.opening_baselines WHERE installation_id=%s", (inst,))), ("previous_approved_id", r1)):
            with pytest.raises(psycopg.Error):
                oc.execute(f"INSERT INTO gms.approved_readings(visit_id,review_id,subscriber_id,installation_id,cycle_id,{prev_col},previous_value_kwh,current_value_kwh,verified_captured_at,approved_by) "
                           "SELECT id,%s,subscriber_id,installation_id,%s,%s,100.00,100.50,verified_captured_at,%s FROM gms.field_visits WHERE id=%s", (rv, c, prev, w.manager, v0))
    assert w.val("SELECT count(*) FROM gms.approved_readings WHERE state='active'") == 2
    w.call(w.manager, "SELECT gms.reject_visit(%s,'reject','خارج التسلسل')", (v0,))
    w.finalize(c, "10")
    assert w.balance(sub) == D("20")       # 2 kWh once


def test_lower_reading_is_an_exception_without_money(world: World):
    """BR-09 / BR-10."""
    w = world
    c, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "105.00", w.at(-11), t1)
    t2 = w.task(c, sub, -9)
    v = w.visit(sub, inst, "104.00", w.at(-9), task=t2)
    with fails("lower_than_previous", "GM409"):
        w.approve(v)
    assert w.val("SELECT count(*) FROM gms.approved_readings") == 1
    with fails("reason_required", "GM422"):
        w.approve(v, corrected=D("106.00"))
    w.approve(v, corrected=D("106.00"), rationale="الصورة تظهر 106")
    rev = w.one("SELECT decision, corrected_value_kwh FROM gms.visit_reviews WHERE visit_id=%s", (v,))
    assert (rev["decision"], rev["corrected_value_kwh"]) == ("correct_reading", D("106.00"))
    assert w.val("SELECT reading_value_kwh FROM gms.field_visits WHERE id=%s", (v,)) == D("104.00")     # raw kept


def test_offline_assignment_change_and_zone_authorization(world: World):
    """AT-06 / BR-13/14: raw records under a stale assignment are kept and flagged; foreign zones are refused."""
    w = world.bootstrap()
    c = w.cycle("QA-C1", -13, -7)
    zone2, zone3 = w.add_zone("QA-ZONE-2"), w.add_zone("QA-ZONE-3")
    w.grant(w.employee, zone2, valid_from=w.at(-60), valid_until=w.at(-12))          # grant withdrawn while offline
    s1, i1 = w.add_subscriber()
    s2, i2 = w.add_subscriber(zone=zone2)
    s3, i3 = w.add_subscriber(zone=zone3)
    res = w.receive(w.payload(s2, i2, "101", w.at(-10), reason="كنت في المنطقة", zone=zone2))
    assert res["result"] == "accepted" and "no_zone_grant" in res["flags"]
    w.photo(res["visit_id"])
    assert status(w, res["visit_id"]) == "exception"
    with fails("exceptions_need_ack", "GM409"):
        w.approve(res["visit_id"])
    w.approve(res["visit_id"], rationale="التكليف تغير أثناء عدم الاتصال؛ القراءة سليمة", ack=True)
    # task reassigned to somebody else while the phone was offline
    other = w.add_employee("qa-other")
    t = w.task(c, s1, -10)
    w.call(w.manager, "SELECT gms.assign_task(%s,%s)", (t, other))
    res = w.receive(w.payload(s1, i1, "101", w.at(-10), task=t))
    assert res["result"] == "accepted" and res["flags"] == ["task_mismatch"]
    assert task_status(w, t) == "assigned"                                           # the new assignee's task is untouched
    # in-zone extra visit needs a reason (BR-13)
    res = w.receive(w.payload(s1, i1, "101.5", w.at(-9)))
    assert res == {"result": "rejected", "reason": "reason_required", "visit_id": res["visit_id"]}
    # zone never granted: refused by the server, trace kept, nothing stored as a visit
    res = w.receive(w.payload(s3, i3, "101", w.at(-10), reason="x", zone=zone3))
    assert res["result"] == "rejected" and res["reason"] == "forbidden_zone"
    assert w.val("SELECT count(*) FROM gms.field_visits WHERE subscriber_id=%s", (s3,)) == 0
    assert w.val("SELECT count(*) FROM gms.sync_operations WHERE result_code='rejected' AND result_data->>'reason'='forbidden_zone'") == 1


def test_revoked_device_is_refused_and_replacement_works(world: World):
    """AT-13 / BR-27."""
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101", w.at(-10), task=task, photo=False)
    old = w.device
    with fails("invalid_enrollment_code", "GM403"):
        w.call(w.employee, "SELECT gms.enroll_device(%s,%s,'x')", ("f" * 64, uuid.uuid4().hex))
    w.call(w.manager, "SELECT gms.revoke_device(%s,'فقدان الهاتف')", (old,))
    with fails("device_revoked", "GM403"):
        w.receive(w.payload(sub, inst, "102", w.at(-9), reason="x"))
    with fails("device_revoked", "GM403"):
        w.photo(v)
    assert w.val("SELECT count(*) FROM gms.field_visits") == 1
    new = w.add_device(w.employee)
    assert w.receive(w.payload(sub, inst, "102", w.at(-9), reason="x"), device=new)["result"] == "accepted"
    with fails("device_revoked"):
        w.receive(w.payload(sub, inst, "103", w.at(-8), reason="x"), device=old)
    # enrolling a third phone revokes the second automatically (one active phone per employee)
    third = w.add_device(w.employee)
    assert w.q("SELECT id FROM gms.mobile_devices WHERE is_active") == [{"id": third}]


def test_sync_is_idempotent_per_uuid(world: World):
    """AT-12 / BR-26."""
    w = world
    c, sub, inst, task = w.week()
    p = w.payload(sub, inst, "101.43", w.at(-10), task=task)
    visit, op = uuid.uuid4(), uuid.uuid4()
    results = [w.receive(p, visit=visit, op=op)["result"] for _ in range(10)]
    assert results == ["accepted"] + ["already_received"] * 9
    assert w.receive(p, visit=visit)["result"] == "already_received"                 # new operation id, same visit+payload
    p2 = dict(p, reading_value_kwh="999.00")
    assert w.receive(p2, visit=visit, op=op)["result"] == "conflict"                 # same key, other fingerprint
    assert w.receive(p2, visit=visit)["result"] == "conflict"
    assert w.val("SELECT count(*) FROM gms.field_visits") == 1
    assert w.val("SELECT reading_value_kwh FROM gms.field_visits WHERE id=%s", (visit,)) == D("101.43")
    pid = uuid.uuid4(); sha = "ab" * 32
    for _ in range(3):
        assert w.call(w.employee, "SELECT gms.begin_photo(%s,%s,%s,10,'image/jpeg',true)", (pid, visit, sha))["state"] == "uploading"
    with fails("photo_conflict", "GM409"):
        w.call(w.employee, "SELECT gms.begin_photo(%s,%s,%s,10,'image/jpeg',true)", (pid, visit, "cd" * 32))
    for _ in range(3):
        assert w.call(w.employee, "SELECT gms.complete_photo(%s,%s,10)", (pid, sha))["state"] == "ready"
    w.approve(visit)
    again = w.receive(p, visit=visit, op=op)
    assert (again["result"], again["record_status"]) == ("already_received", "approved")
    assert w.val("SELECT count(*) FROM gms.approved_readings") == 1
    bad = w.call(w.employee, "SELECT gms.receive_visit(%s,%s,%s,%s::jsonb,%s,'consistent',NULL)", (uuid.uuid4(), uuid.uuid4(), w.device, json.dumps({"x": 1}), "aa" * 32))
    assert bad == {"result": "rejected", "reason": "malformed_payload"}


def test_untrusted_device_clock_needs_manager_decision(world: World):
    """AT-11 / BR-24: no silent re-pricing; the manager documents the verified time."""
    w = world
    c, sub, inst, task = w.week()
    v = w.visit(sub, inst, "101", w.at(-3), task=task, trust="suspicious")           # device claims a date outside week 1
    row = w.one("SELECT timestamp_status, verified_captured_at, record_status, flags FROM gms.field_visits WHERE id=%s", (v,))
    assert (row["timestamp_status"], row["verified_captured_at"], row["record_status"], row["flags"]) == ("suspicious", None, "exception", ["clock_suspicious"])
    with fails("timestamp_unverified", "GM409"):
        w.approve(v, rationale="x", ack=True)
    with fails("reason_required", "GM422"):
        w.call(w.manager, "SELECT gms.verify_capture_time(%s,%s,NULL)", (v, w.at(-10)))
    w.call(w.manager, "SELECT gms.verify_capture_time(%s,%s,'ساعة الهاتف متقدمة أسبوعًا؛ التاريخ من الصورة')", (v, w.at(-10)))
    r = w.approve(v, rationale="وقت مصحح وموثق", ack=True)
    row = w.one("SELECT cycle_id, verified_captured_at FROM gms.approved_readings WHERE id=%s", (r,))
    assert (row["cycle_id"], row["verified_captured_at"]) == (c, w.at(-10))
    assert w.val("SELECT captured_at_device FROM gms.field_visits WHERE id=%s", (v,)) == w.at(-3)       # raw evidence kept
    res = w.receive(w.payload(sub, inst, "102", w.now(180), reason="x"))                                 # 3h in the future
    assert "clock_future" in res["flags"]
    assert w.val("SELECT timestamp_status FROM gms.field_visits WHERE id=%s", (res["visit_id"],)) == "suspicious"


def test_meter_replacement_starts_a_new_chain(world: World):
    """AT-17 / FR-04/13: the employee only reports; the manager records old/new meter and the new opening value."""
    w = world
    c, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "105.00", w.at(-12), t1)
    t2 = w.task(c, sub, -10)
    p = w.payload(sub, inst, None, w.at(-10), task=t2, kind="meter_incident", reason="العداد محترق واستُبدل")
    p["incident_category"] = "replacement"
    inc = w.receive(p)["visit_id"]
    w.photo(inc)
    new_inst = w.call(w.manager, "SELECT gms.replace_meter(%s,'replacement',%s,'استبدال عداد محترق','QA-NEW-1','digital',0,%s)", (sub, w.at(-10, 12), inc))
    old = w.one("SELECT removed_at, removal_reason FROM gms.meter_installations WHERE id=%s", (inst,))
    assert old["removed_at"] == w.at(-10, 12)
    assert (status(w, inc), task_status(w, t2)) == ("incident_resolved", "completed_unreadable")
    assert w.val("SELECT resulting_installation_id FROM gms.meter_incident_reports WHERE visit_id=%s", (inc,)) == new_inst
    w.read_and_approve(sub, new_inst, "4.00", w.at(-8), w.task(c, sub, -8))
    last = w.one("SELECT previous_value_kwh, consumption_kwh, opening_baseline_id IS NOT NULL AS from_opening FROM gms.approved_readings WHERE installation_id=%s", (new_inst,))
    assert (last["previous_value_kwh"], last["consumption_kwh"], last["from_opening"]) == (0, D("4.00"), True)
    # a reading claimed on the removed meter after its removal cannot be approved
    late = w.visit(sub, inst, "106.00", w.at(-9))
    with fails("installation_inactive", "GM409"):
        w.approve(late, rationale="x", ack=True)
    w.call(w.manager, "SELECT gms.reject_visit(%s,'reject','عداد مُزال')", (late,))
    w.finalize(c, "10")
    assert w.balance(sub) == D("90")


def test_stop_subscription_keeps_history_and_debt(world: World):
    """AT-20 / BR-23."""
    w = world
    c1, sub, inst, t1 = w.week()
    w.read_and_approve(sub, inst, "110.00", w.at(-10), t1)
    w.finalize(c1, "10")
    c2 = w.cycle("QA-C2", -6, 0)
    t2 = w.task(c2, sub, -3)
    w.call(w.manager, "SELECT gms.stop_subscriber(%s,'طلب المشترك')", (sub,))
    assert task_status(w, t2) == "cancelled"
    assert w.balance(sub) == D("100") and w.val("SELECT count(*) FROM gms.approved_readings WHERE subscriber_id=%s", (sub,)) == 1
    assert w.call(w.manager, "SELECT gms.generate_due_tasks(%s)", (c2,)) == 0
    with fails("subscriber_inactive", "GM409"):
        w.task(c2, sub, -2)
    w.task(c2, sub, -2, source="closing")                # optional closing reading is still possible
    w.pay(sub, "100")
    assert w.balance(sub) == 0
    with fails("permission denied", "42501"):       # the API login has no DELETE privilege at all
        w.call(w.manager, "DELETE FROM gms.subscribers WHERE id=%s RETURNING id", (sub,))


def test_revisit_creates_linked_task_and_blocks_its_own_week(world: World):
    """BR-10/15/16."""
    w = world
    c1, sub, inst, t1 = w.week()
    v = w.visit(sub, inst, "101", w.at(-10), task=t1)
    child = w.call(w.manager, "SELECT gms.request_revisit(%s,%s,NULL,'الصورة غير واضحة')", (v, day(w, -8)))
    assert (status(w, v), task_status(w, t1)) == ("needs_revisit", "revisit_required")
    row = w.one("SELECT parent_task_id, source, cycle_id, assigned_employee_id FROM gms.reading_tasks WHERE id=%s", (child,))
    assert (row["parent_task_id"], row["source"], row["cycle_id"], row["assigned_employee_id"]) == (t1, "revisit", c1, w.employee)
    with fails("unresolved_tasks"):
        w.finalize(c1, "10")
    c2 = w.cycle("QA-C2", -6, 0, open_=False)
    w.call(w.manager, "SELECT gms.move_task(%s,%s,%s)", (child, c2, day(w, -5)))       # follow-up belongs to the new week
    assert w.finalize(c1, "10") == 0
    w.call(w.manager, "SELECT gms.open_cycle(%s)", (c2,))
    w.approve(w.visit(sub, inst, "103", w.at(-5), task=child))
    w.finalize(c2, "20")
    assert w.balance(sub) == D("60")
