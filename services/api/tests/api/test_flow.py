"""P3–P5/P8/P9 end-to-end over HTTP: master data -> schedule -> phone sync + photo -> review -> close -> pay."""
import hashlib
import uuid
from datetime import datetime, timedelta, timezone

from tests.apiclient import expect, jpeg


def test_full_week_over_http(api):
    w = api.setup()
    a = w.subscriber("QA-1001", "100.00", interval=4)
    b = w.subscriber("QA-1002", "50.00", interval=7)
    assert a["meter_serial"] == "M-QA-1001" and a["next_due"]
    c1 = w.cycle("QA-W1", -13, -7, rate="14")
    # a brand-new opening baseline is not due in a past week: the manager overrides the next date (BR-03)
    for sub, d in ((a, -11), (b, -10)):
        expect(w.m.put(f"/api/v1/subscribers/{sub['id']}/schedule", {"interval_days": 7 if sub is b else 4, "next_due_override": w.day(d)}), 200)
    created = expect(w.m.post(f"/api/v1/cycles/{c1}/generate-tasks"), 200)["created"]
    assert created == 2
    tasks = {t["subscriber_id"]: t for t in expect(w.m.get("/api/v1/tasks", params={"cycle_id": c1}), 200)["items"]}
    assert all(t["assigned_employee_id"] == w.emp_id for t in tasks.values())   # single employee on the zone
    # the phone downloads its day
    boot = expect(w.e.get("/api/v1/mobile/bootstrap"), 200)
    assert {s["id"] for s in boot["subscribers"]} == {a["id"], b["id"]} and len(boot["tasks"]) == 2
    assert "balance_exact_ils" not in boot["subscribers"][0]
    assert boot["subscribers"][0]["last_approved_value_kwh"] in ("100", "50")
    # two readings for A in the same week (second one is an extra visit), one for B
    v1 = w.field_reading(a, "101.20", w.at(-11), task=tasks[a["id"]]["id"])
    v2 = w.field_reading(a, "101.43", w.at(-9), reason="طلب المشترك قراءة إضافية")
    v3 = w.field_reading(b, "60.00", w.at(-10), task=tasks[b["id"]]["id"])
    q = expect(w.m.get("/api/v1/visits", params={"open_only": "true"}), 200)
    assert q["total"] == 3
    d1 = expect(w.m.get(f"/api/v1/visits/{v1}"), 200)
    assert d1["previous_value_kwh"] == "100" and d1["provisional"]["cost_ils"] == "16.8" and d1["provisional"]["label"].startswith("تقديري")
    assert d1["photos"][0]["url"]
    img = api.client.get(d1["photos"][0]["url"])
    assert img.status_code == 200 and img.content.startswith(b"\xff\xd8")
    expect(api.client.get(d1["photos"][0]["url"].replace("sig=", "sig=0")), 403, "invalid_link")
    # approval needs explicit photo review; bulk approval skips exceptions
    expect(w.m.post(f"/api/v1/visits/{v1}/approve", {"photo_reviewed": False}), 422, "photo_review_required")
    bulk = expect(w.m.post("/api/v1/visits/approve-bulk", {"visit_ids": [v1, v2, v3], "photos_reviewed": True}), 200)
    by = {r["visit_id"]: r for r in bulk["results"]}
    assert by[v1]["result"] == by[v3]["result"] == "approved", bulk
    assert by[v2]["code"] == "exceptions_need_ack"
    expect(w.m.post(f"/api/v1/visits/{v2}/approve", {"photo_reviewed": True, "acknowledge_exceptions": True,
                                                     "rationale": "قراءة إضافية موثقة"}), 200)
    est = expect(w.m.get(f"/api/v1/cycles/{c1}/estimate"), 200)
    assert est["is_final"] is False and len(est["lines"]) == 3
    # closing needs explicit confirmation; then statements exist and are immutable through the API
    expect(w.m.post(f"/api/v1/cycles/{c1}/finalize", {"final_rate_ils_per_kwh": "15", "confirm": False}), 422, "confirmation_required")
    assert expect(w.m.post(f"/api/v1/cycles/{c1}/finalize", {"final_rate_ils_per_kwh": "15", "confirm": True}), 200)["statements"] == 2
    expect(w.m.post(f"/api/v1/cycles/{c1}/finalize", {"final_rate_ils_per_kwh": "15", "confirm": True}), 409, "cycle_not_open")
    sts = {s["subscriber_id"]: s for s in expect(w.m.get("/api/v1/statements", params={"cycle_id": c1}), 200)["items"]}
    sa = expect(w.m.get(f"/api/v1/statements/{sts[a['id']]['id']}"), 200)
    assert (sa["charge_exact_ils"], sa["requested_whole_ils"], sa["carry_out_ils"], len(sa["lines"])) == ("21.45", "21", "0.45", 2)
    assert sts[b["id"]]["charge_exact_ils"] == "150"
    # partial payment, idempotent retry, wrong-payload reuse, reversal
    key = str(uuid.uuid4())
    pay = {"subscriber_id": a["id"], "amount_ils": "21.00", "paid_at": datetime.now(timezone.utc).isoformat(), "method": "cash",
           "reference": "إيصال ورقي 17", "idempotency_key": key}
    r1 = expect(w.m.post("/api/v1/payments", pay), 201)
    r2 = expect(w.m.post("/api/v1/payments", pay), 201)
    assert r1["payment"]["id"] == r2["payment"]["id"] and r1["account"]["balance_exact_ils"] == "0.45"
    expect(w.m.post("/api/v1/payments", {**pay, "amount_ils": "20"}), 409, "idempotency_conflict")
    expect(w.m.post("/api/v1/payments", {**pay, "amount_ils": 21.0, "idempotency_key": str(uuid.uuid4())}), 422, "validation_error")
    expect(w.m.post("/api/v1/payments", {**pay, "amount_ils": "21.001", "idempotency_key": str(uuid.uuid4())}), 422, "validation_error")
    pb = expect(w.m.post("/api/v1/payments", {**pay, "subscriber_id": b["id"], "amount_ils": "100", "idempotency_key": str(uuid.uuid4())}), 201)
    assert pb["account"]["requested_whole_ils"] == "50"
    expect(w.m.post(f"/api/v1/payments/{pb['payment']['id']}/reverse", {"reason": "أدخلت لمشترك خطأ"}), 200)
    led = expect(w.m.get(f"/api/v1/subscribers/{b['id']}/ledger"), 200)
    assert [e["source_type"] for e in led["entries"]] == ["final_statement", "payment", "payment_reversal"]
    assert led["entries"][-1]["running_balance_ils"] == "150" and led["account"]["total_paid_ils"] == "0"
    # week 2: 0.79 kWh @ 20 -> 15.80 + carried 0.45 -> request 16, carry 0.25
    c2 = w.cycle("QA-W2", -6, 0, rate="20")
    t = expect(w.m.post("/api/v1/tasks", {"cycle_id": c2, "subscriber_id": a["id"], "planned_for": w.day(-3)}), 201)
    v4 = w.field_reading(a, "102.22", w.at(-3), task=t["id"])
    expect(w.m.post(f"/api/v1/visits/{v4}/approve", {"photo_reviewed": True}), 200)
    t_b = expect(w.m.post("/api/v1/tasks", {"cycle_id": c2, "subscriber_id": b["id"], "planned_for": w.day(-2)}), 201)
    expect(w.m.post(f"/api/v1/tasks/{t_b['id']}/cancel", {"reason": "المشترك مسافر"}), 200)
    expect(w.m.post(f"/api/v1/cycles/{c2}/finalize", {"final_rate_ils_per_kwh": "20", "confirm": True}), 200)
    acc = expect(w.m.get(f"/api/v1/subscribers/{a['id']}"), 200)["account"]
    assert (acc["balance_exact_ils"], acc["requested_whole_ils"], acc["carry_fraction_ils"]) == ("16.25", "16", "0.25")
    # closed-week correction -> single adjustment, statements untouched
    r_a = [r for r in expect(w.m.get(f"/api/v1/subscribers/{a['id']}"), 200)["readings"] if r["current_value_kwh"] == "101.43"][0]
    ck = str(uuid.uuid4())
    corr = expect(w.m.post(f"/api/v1/readings/{r_a['id']}/correct", {"new_value_kwh": "101.33", "rationale": "الصورة تُظهر 101.33", "idempotency_key": ck}), 200)
    assert sorted(x["adjustment_ils"] for x in corr["adjustments"]) == ["-1.5", "2"]
    assert expect(w.m.get(f"/api/v1/statements/{sts[a['id']]['id']}"), 200) == sa
    assert expect(w.m.get(f"/api/v1/subscribers/{a['id']}"), 200)["account"]["balance_exact_ils"] == "16.75"
    # the phone sees review outcomes
    st = expect(w.e.post("/api/v1/mobile/status", {"visit_ids": [v1, v2, v4]}), 200)
    assert {s["record_status"] for s in st} == {"approved"}
    # audit trail recorded who did what
    audit = expect(w.m.get("/api/v1/audit", params={"entity_type": "payment_receipts"}), 200)
    assert audit and audit[0]["actor_id"] == w.m.user["id"]


def test_sync_protocol_photos_and_scope(api):
    """AT-02/03/06/11/12 over HTTP."""
    w = api.setup()
    a = w.subscriber("QA-2001")
    zone2 = expect(w.m.post("/api/v1/zones", {"generator_id": w.gen, "name": "QA-ZONE-2"}), 201)["id"]
    other = w.subscriber("QA-2002", zone=zone2)
    w.cycle("QA-W1", -6, 0)
    boot = expect(w.e.get("/api/v1/mobile/bootstrap"), 200)
    assert [s["id"] for s in boot["subscribers"]] == [a["id"]]            # never sees another zone
    op = w.visit_op(a, "121.98", w.at(-1), reason="إضافية")
    ops = [op, op, w.visit_op(a, "121.987", w.at(-1), reason="x"), w.visit_op(other, "5", w.at(-1), reason="x"),
           {"kind": "visit", "operation_id": str(uuid.uuid4()), "visit_id": str(uuid.uuid4()), "payload": {"event_kind": "reading"}},
           w.visit_op(a, None, w.at(-1), kind="unreadable"), w.visit_op(a, "130", datetime.now(timezone.utc) + timedelta(hours=5), reason="x")]
    res = expect(w.sync(w.e, ops), 200)["results"]
    assert [r["result"] for r in res] == ["accepted", "already_received", "rejected", "rejected", "rejected", "rejected", "accepted"]
    assert [r.get("reason") for r in res[2:6]] == ["invalid_precision", "forbidden_zone", "malformed_payload", "reason_required"]
    assert "clock_future" in res[6]["flags"]
    # same ids, other content -> conflict; resend of all 10 times -> still one visit
    changed = {**op, "payload": {**op["payload"], "reading_value_kwh": "500"}}
    assert expect(w.sync(w.e, [changed]), 200)["results"][0]["result"] == "conflict"
    for _ in range(10):
        assert expect(w.sync(w.e, [op]), 200)["results"][0]["result"] == "already_received"
    visits = expect(w.m.get("/api/v1/visits", params={"subscriber_id": a["id"]}), 200)
    assert visits["total"] == 2
    vid = op["visit_id"]
    assert expect(w.m.get(f"/api/v1/visits/{vid}"), 200)["reading_value_kwh"] == "121.98"
    # photos: wrong checksum, not an image, then the real photo (idempotent)
    data = jpeg("p1")
    expect(w.upload(w.e, vid, data, sha="0" * 64), 422, "checksum_mismatch")
    expect(w.upload(w.e, vid, b"%PDF-1.4 not an image"), 415, "not_an_image")
    pid = uuid.uuid4()
    r = expect(w.upload(w.e, vid, data, photo_id=pid), 200)
    assert r["state"] == "ready" and r["record_status"] == "exception"
    assert expect(w.upload(w.e, vid, data, photo_id=pid), 200)["state"] == "ready"
    expect(w.upload(w.e, vid, jpeg("other"), photo_id=pid), 409, "photo_conflict")
    expect(w.upload(w.e, vid, jpeg("second")), 409, "primary_exists")
    assert expect(w.upload(w.e, vid, jpeg("extra"), primary=False), 200)["state"] == "ready"
    # another employee cannot attach photos to this visit
    e2, _, _ = w.new_employee("qa-employee-2", w.zone)
    expect(w.upload(e2, vid, jpeg("intruder"), primary=False), 404, "visit_not_found")
    # stored object == uploaded bytes
    stored = api.app.state.storage.get(f"visits/{vid}/{pid}.jpg")
    assert hashlib.sha256(stored).hexdigest() == hashlib.sha256(data).hexdigest()
    # manager sees it, approves with documented acknowledgement
    expect(w.m.post(f"/api/v1/visits/{vid}/approve", {"photo_reviewed": True}), 409, "exceptions_need_ack")
    expect(w.m.post(f"/api/v1/visits/{vid}/approve", {"photo_reviewed": True, "acknowledge_exceptions": True,
                                                      "rationale": "x", "corrected_value_kwh": "121.987"}), 422, "validation_error")
    expect(w.m.post(f"/api/v1/visits/{vid}/approve", {"photo_reviewed": True, "acknowledge_exceptions": True, "rationale": "موثقة"}), 200)


def test_clock_evidence_same_boot(api):
    """BR-24: monotonic elapsed time of the same boot lets the server confirm or doubt the device clock."""
    w = api.setup()
    a = w.subscriber("QA-3001")
    w.cycle("QA-W1", -6, 0)
    now = datetime.now(timezone.utc)
    good = w.visit_op(a, "101", now - timedelta(hours=2), reason="x")
    good.update(capture_boot_id="boot-1", capture_elapsed_ms=1_000_000)
    lying = w.visit_op(a, "102", now - timedelta(days=3), reason="x")       # claims 3 days ago, really 1 hour ago
    lying.update(capture_boot_id="boot-1", capture_elapsed_ms=4_600_000)
    body = {"device_now": now.isoformat(), "boot_id": "boot-1", "elapsed_ms": 8_200_000, "operations": [good, lying]}
    res = expect(w.e.post("/api/v1/mobile/sync", body), 200)["results"]
    assert res[0]["flags"] == ["unscheduled"] and "clock_suspicious" in res[1]["flags"]
    v = expect(w.m.get(f"/api/v1/visits/{lying['visit_id']}"), 200)
    assert v["timestamp_status"] == "suspicious" and v["verified_captured_at"] is None
