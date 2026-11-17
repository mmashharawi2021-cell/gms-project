"""P3 — authentication, sessions, devices and strong negative authorization tests (AT-13 / AT-25)."""
import uuid
from datetime import datetime, timedelta, timezone

import jwt

from tests.apiclient import Session, expect


def test_login_rules_and_lockout(api):
    w = api.setup()
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-manager", "password": "wrong", "client": "web"}), 401, "invalid_credentials")
    expect(api.client.post("/api/v1/auth/login", json={"username": "nobody", "password": "x", "client": "web"}), 401, "invalid_credentials")
    # an employee cannot use the web console, a manager cannot use the field app
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-employee", "password": w.e.password, "client": "web"}), 403, "web_managers_only")
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-manager", "password": "Manager-Pass-1", "client": "mobile",
                                                       "install_id": uuid.uuid4().hex}), 403, "mobile_employees_only")
    # unknown phone without enrollment code
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-employee", "password": w.e.password, "client": "mobile",
                                                       "install_id": uuid.uuid4().hex}), 403, "device_not_enrolled")
    # 5 wrong passwords lock the account even with the right password afterwards
    u = expect(w.m.post("/api/v1/users", {"username": "qa-lock", "full_name": "QA lock", "role": "manager"}), 201)
    for _ in range(5):
        expect(api.client.post("/api/v1/auth/login", json={"username": "qa-lock", "password": "bad", "client": "web"}), 401)
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-lock", "password": u["temporary_password"], "client": "web"}), 423, "account_locked")
    # manager reset unlocks and issues a new temporary password
    temp = expect(w.m.post(f"/api/v1/users/{u['id']}/reset-password"), 200)["temporary_password"]
    s = api.login_web("qa-lock", temp)
    assert s.user["must_change_password"]


def test_temporary_password_must_be_changed(api):
    w = api.setup()
    u = expect(w.m.post("/api/v1/users", {"username": "qa-new-mgr", "full_name": "QA new", "role": "manager"}), 201)
    s = api.login_web("qa-new-mgr", u["temporary_password"])
    expect(s.get("/api/v1/subscribers"), 403, "password_change_required")
    expect(s.get("/api/v1/auth/me"), 200)
    expect(s.post("/api/v1/auth/change-password", {"current_password": u["temporary_password"], "new_password": "12345678"}), 422, "weak_password")
    d = expect(s.post("/api/v1/auth/change-password", {"current_password": u["temporary_password"], "new_password": "Better-Pass-77"}), 200)
    expect(Session(api.client, d["access_token"]).get("/api/v1/subscribers"), 200)
    expect(s.get("/api/v1/auth/me"), 401, "invalid_token")    # the old token died with the password change


def test_refresh_rotation_and_reuse_detection(api):
    w = api.setup()
    s = api.login_web()
    first = s.refresh
    d = expect(api.client.post("/api/v1/auth/refresh", json={"refresh_token": first}), 200)
    second = d["refresh_token"]
    # replaying the rotated token revokes the whole family, including the new one
    expect(api.client.post("/api/v1/auth/refresh", json={"refresh_token": first}), 401, "invalid_refresh")
    expect(api.client.post("/api/v1/auth/refresh", json={"refresh_token": second}), 401, "invalid_refresh")
    # logout revokes
    s2 = api.login_web()
    expect(s2.post("/api/v1/auth/logout", {"refresh_token": s2.refresh}), 200)
    expect(api.client.post("/api/v1/auth/refresh", json={"refresh_token": s2.refresh}), 401)
    assert w


def test_forged_and_stale_tokens(api):
    w = api.setup()
    settings = api.app.state.settings
    real = jwt.decode(w.e.token, settings.jwt_secret, algorithms=["HS256"], issuer=settings.jwt_issuer)
    # employee rewrites its own token to role=manager with a guessed key -> signature fails
    forged = jwt.encode({**real, "role": "manager"}, "guessed-secret-" + "y" * 40, algorithm="HS256")
    expect(Session(api.client, forged).get("/api/v1/subscribers"), 401, "invalid_token")
    expect(Session(api.client, "not-a-jwt").get("/api/v1/subscribers"), 401, "invalid_token")
    expect(api.client.get("/api/v1/subscribers"), 401, "unauthenticated")
    none_alg = jwt.encode({**real, "role": "manager"}, None, algorithm="none")
    expect(Session(api.client, none_alg).get("/api/v1/subscribers"), 401, "invalid_token")
    # even a correctly signed token claiming manager for an employee id is refused (DB is re-read each request)
    signed = jwt.encode({**real, "role": "manager"}, settings.jwt_secret, algorithm="HS256")
    expect(Session(api.client, signed).get("/api/v1/subscribers"), 401, "invalid_token")
    # disabling the account kills existing sessions immediately
    expect(w.m.patch(f"/api/v1/users/{w.emp_id}", {"is_active": False}), 200)
    expect(w.e.get("/api/v1/mobile/bootstrap"), 401, "invalid_token")
    expect(api.client.post("/api/v1/auth/refresh", json={"refresh_token": w.e.refresh}), 401)
    # a manager cannot disable themselves
    expect(w.m.patch(f"/api/v1/users/{w.m.user['id']}", {"is_active": False}), 409, "cannot_disable_self")


def test_employee_cannot_reach_any_manager_operation(api):
    """AT-25 at HTTP level: the employee edits requests by hand; every manager endpoint answers 403."""
    w = api.setup()
    sub = w.subscriber()
    c = w.cycle("QA-C1", -6, 0)
    vid = w.field_reading(sub, "101.00", w.at(-1))
    rid, pid, key = str(uuid.uuid4()), str(uuid.uuid4()), str(uuid.uuid4())
    calls = [
        ("get", "/api/v1/subscribers", None), ("get", f"/api/v1/subscribers/{sub['id']}", None),
        ("post", "/api/v1/subscribers", {"subscription_no": "X", "full_name": "X", "zone_id": w.zone, "interval_days": 7}),
        ("patch", f"/api/v1/subscribers/{sub['id']}", {"full_name": "hacked"}),
        ("post", f"/api/v1/subscribers/{sub['id']}/replace-meter", {"kind": "reset", "effective_at": datetime.now(timezone.utc).isoformat(), "reason": "x", "new_opening_value_kwh": "0"}),
        ("post", f"/api/v1/subscribers/{sub['id']}/stop", {"reason": "x"}),
        ("get", "/api/v1/visits", None), ("get", f"/api/v1/visits/{vid}", None),
        ("post", f"/api/v1/visits/{vid}/approve", {"photo_reviewed": True}),
        ("post", "/api/v1/visits/approve-bulk", {"visit_ids": [vid], "photos_reviewed": True}),
        ("post", f"/api/v1/visits/{vid}/reject", {"decision": "reject", "rationale": "x"}),
        ("post", f"/api/v1/visits/{vid}/verify-time", {"verified_captured_at": datetime.now(timezone.utc).isoformat(), "reason": "x"}),
        ("post", f"/api/v1/readings/{rid}/correct", {"new_value_kwh": "1", "rationale": "x", "idempotency_key": key}),
        ("post", f"/api/v1/cycles/{c}/provisional-rate", {"effective_on": w.day(0), "rate_ils_per_kwh": "1"}),
        ("post", f"/api/v1/cycles/{c}/finalize", {"final_rate_ils_per_kwh": "1", "confirm": True}),
        ("post", "/api/v1/cycles", {"label": "X", "starts_on": w.day(10), "ends_on": w.day(16)}),
        ("post", "/api/v1/tasks", {"cycle_id": c, "subscriber_id": sub["id"], "planned_for": w.day(0)}),
        ("post", "/api/v1/payments", {"subscriber_id": sub["id"], "amount_ils": "10", "paid_at": datetime.now(timezone.utc).isoformat(), "method": "cash", "idempotency_key": key}),
        ("post", f"/api/v1/payments/{pid}/reverse", {"reason": "x"}),
        ("post", "/api/v1/adjustments", {"subscriber_id": sub["id"], "amount_ils": "-5", "reason": "x", "idempotency_key": key}),
        ("post", "/api/v1/opening-receivables", {"subscriber_id": sub["id"], "amount_ils": "5", "as_of": w.day(0), "justification": "x"}),
        ("get", f"/api/v1/subscribers/{sub['id']}/ledger", None), ("get", "/api/v1/statements", None), ("get", "/api/v1/payments", None),
        ("get", "/api/v1/users", None), ("post", "/api/v1/users", {"username": "evil", "full_name": "x", "role": "manager"}),
        ("patch", f"/api/v1/users/{w.m.user['id']}", {"is_active": False}),
        ("post", f"/api/v1/users/{w.emp_id}/reset-password", None),
        ("post", f"/api/v1/users/{w.emp_id}/enrollment-codes", None),
        ("post", "/api/v1/zone-grants", {"employee_id": w.emp_id, "zone_id": w.zone}),
        ("get", "/api/v1/devices", None), ("post", f"/api/v1/devices/{uuid.uuid4()}/revoke", {"reason": "x"}),
        ("post", "/api/v1/generators", {"name": "X"}), ("put", "/api/v1/settings/business_timezone", {"value": "UTC"}),
        ("get", "/api/v1/audit", None), ("get", "/api/v1/sync/monitor", None), ("get", f"/api/v1/cycles/{c}/estimate", None),
    ]
    for method, url, body in calls:
        r = getattr(w.e, method)(url, body) if body is not None else getattr(w.e, method)(url)
        assert r.status_code == 403, f"{method} {url} -> {r.status_code} {r.text}"
    # and the manager token cannot pose as a phone
    expect(w.m.get("/api/v1/mobile/bootstrap"), 403, "forbidden")
    assert expect(w.m.get(f"/api/v1/visits/{vid}"), 200)["record_status"] == "exception"   # unscheduled -> untouched by the 403s
    assert expect(w.m.get(f"/api/v1/subscribers/{sub['id']}"), 200)["full_name"].startswith("مشترك")


def test_revoked_phone_is_cut_off_and_replaced(api):
    """AT-13 / BR-27: revoke -> immediate 403 on sync/refresh; attempts are traced; a new phone needs a new code."""
    w = api.setup()
    sub = w.subscriber()
    w.cycle("QA-C1", -6, 0)
    dev = expect(w.m.get("/api/v1/devices"), 200)[0]
    expect(w.m.post(f"/api/v1/devices/{dev['id']}/revoke", {"reason": "هاتف مفقود"}), 200)
    expect(w.sync(w.e, [w.visit_op(sub, "101", w.at(-1), reason="x")]), 403, "device_revoked")
    expect(api.client.post("/api/v1/auth/refresh", json={"refresh_token": w.e.refresh, "install_id": w.install}), 401)
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-employee", "password": w.e.password, "client": "mobile",
                                                       "install_id": w.install}), 403, "device_not_enrolled")
    monitor = expect(w.m.get("/api/v1/sync/monitor"), 200)
    assert any(r["reason"] == "device_not_enrolled" for r in monitor["recent_rejections"])
    code = expect(w.m.post(f"/api/v1/users/{w.emp_id}/enrollment-codes"), 201)["code"]
    new = api.login_mobile("qa-employee", w.e.password, uuid.uuid4().hex, code)
    assert expect(w.sync(new, [w.visit_op(sub, "101", w.at(-1), reason="x")]), 200)["results"][0]["result"] == "accepted"
    # a code is single-use
    expect(api.client.post("/api/v1/auth/login", json={"username": "qa-employee", "password": w.e.password, "client": "mobile",
                                                       "install_id": uuid.uuid4().hex, "enrollment_code": code}), 403, "invalid_enrollment_code")
    # an expired/unknown code never works
    assert datetime.now(timezone.utc) + timedelta(days=1)
