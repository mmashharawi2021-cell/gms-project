"""HTTP-level helper: drives the real FastAPI app (TestClient) against the disposable PostgreSQL."""
from __future__ import annotations

import hashlib
import uuid
from datetime import datetime, timedelta, timezone

from fastapi.testclient import TestClient


def jpeg(seed: str = "x", size: int = 2048) -> bytes:
    body = hashlib.sha256(seed.encode()).digest() * (size // 32)
    return b"\xff\xd8\xff\xe0" + body + b"\xff\xd9"


class Session:
    def __init__(self, client: TestClient, token: str, refresh: str | None = None, user: dict | None = None):
        self.client, self.token, self.refresh, self.user = client, token, refresh, user or {}

    @property
    def h(self):
        return {"Authorization": f"Bearer {self.token}"}

    def get(self, url, **kw):
        return self.client.get(url, headers=self.h, **kw)

    def post(self, url, json=None, **kw):
        return self.client.post(url, json=json, headers=self.h, **kw)

    def put(self, url, json=None, **kw):
        return self.client.put(url, json=json, headers={**self.h, **kw.pop("headers", {})}, **kw)

    def patch(self, url, json=None, **kw):
        return self.client.patch(url, json=json, headers=self.h, **kw)


def expect(resp, status: int, code: str | None = None):
    assert resp.status_code == status, f"{resp.request.method} {resp.request.url} -> {resp.status_code} {resp.text}"
    if code:
        assert resp.json()["error"]["code"] == code, resp.text
    return resp.json() if resp.content and resp.headers.get("content-type", "").startswith("application/json") else resp


class ApiWorld:
    def __init__(self, client: TestClient, app, db_url: str):
        self.client, self.app, self.db_url = client, app, db_url
        self.today = datetime.now(timezone.utc).date()

    def login_web(self, username="qa-manager", password="Manager-Pass-1") -> Session:
        d = expect(self.client.post("/api/v1/auth/login", json={"username": username, "password": password, "client": "web"}), 200)
        return Session(self.client, d["access_token"], d["refresh_token"], d["user"])

    def login_mobile(self, username, password, install_id, code=None) -> Session:
        body = {"username": username, "password": password, "client": "mobile", "install_id": install_id}
        if code:
            body["enrollment_code"] = code
        d = expect(self.client.post("/api/v1/auth/login", json=body), 200)
        return Session(self.client, d["access_token"], d["refresh_token"], d["user"])

    # --- scenario builders -------------------------------------------------------------
    def setup(self):
        """Manager + generator + zone + enrolled employee phone. Synthetic QA data only."""
        self.m = self.login_web()
        # scenarios replay past weeks: readings "captured" days ago are synced now -> raise the late-sync threshold
        expect(self.m.put("/api/v1/settings/late_sync_hours", {"value": "10000"}), 200)
        self.gen = expect(self.m.post("/api/v1/generators", {"name": "QA-GEN"}), 201)["id"]
        self.zone = expect(self.m.post("/api/v1/zones", {"generator_id": self.gen, "name": "QA-ZONE"}), 201)["id"]
        self.e, self.emp_id, self.install = self.new_employee("qa-employee", self.zone)
        return self

    def new_employee(self, username, zone=None):
        u = expect(self.m.post("/api/v1/users", {"username": username, "full_name": "QA " + username, "role": "employee"}), 201)
        if zone:
            expect(self.m.post("/api/v1/zone-grants", {"employee_id": u["id"], "zone_id": zone, "valid_from": self.at(-60).isoformat()}), 201)
        code = expect(self.m.post(f"/api/v1/users/{u['id']}/enrollment-codes"), 201)["code"]
        install = uuid.uuid4().hex
        s = self.login_mobile(username, u["temporary_password"], install, code)
        assert s.user["must_change_password"]
        new_pw = "Field-Pass-" + uuid.uuid4().hex[:6] + "9"
        d = expect(s.post("/api/v1/auth/change-password", {"current_password": u["temporary_password"], "new_password": new_pw}), 200)
        s = Session(self.client, d["access_token"], d["refresh_token"], d["user"])
        s.password = new_pw
        return s, u["id"], install

    def subscriber(self, no="QA-1001", opening="100.00", interval=7, zone=None, installed_days=-40):
        body = {"subscription_no": no, "full_name": "مشترك اختبار " + no, "zone_id": zone or self.zone, "interval_days": interval,
                "meter": {"serial_no": "M-" + no, "meter_type": "digital", "opening_value_kwh": opening,
                          "installed_at": self.at(installed_days).isoformat()}}
        return expect(self.m.post("/api/v1/subscribers", body), 201)

    def at(self, days: int, hour: int = 10) -> datetime:
        d = self.today + timedelta(days=days)
        return datetime(d.year, d.month, d.day, hour, tzinfo=timezone.utc)

    def day(self, n: int) -> str:
        return (self.today + timedelta(days=n)).isoformat()

    def cycle(self, label, start, end, rate="10"):
        c = expect(self.m.post("/api/v1/cycles", {"label": label, "starts_on": self.day(start), "ends_on": self.day(end)}), 201)
        expect(self.m.post(f"/api/v1/cycles/{c['id']}/open"), 200)
        expect(self.m.post(f"/api/v1/cycles/{c['id']}/provisional-rate", {"effective_on": self.day(start), "rate_ils_per_kwh": rate}), 200)
        return c["id"]

    def visit_op(self, sub: dict, value: str | None, at: datetime, task=None, kind="reading", reason=None, zone=None):
        payload = {"subscriber_id": sub["id"], "installation_id": sub["installation_id"], "zone_id": zone or sub["zone_id"],
                   "event_kind": kind, "captured_at_device": at.isoformat()}
        if value is not None:
            payload["reading_value_kwh"] = value
        if task:
            payload["task_id"] = task
        if reason:
            payload["reason"] = reason
        return {"kind": "visit", "operation_id": str(uuid.uuid4()), "visit_id": str(uuid.uuid4()), "payload": payload}

    def sync(self, session: Session, ops: list, device_now: datetime | None = None):
        return session.post("/api/v1/mobile/sync", {"device_now": (device_now or datetime.now(timezone.utc)).isoformat(), "operations": ops})

    def upload(self, session: Session, visit_id, data: bytes | None = None, primary=True, photo_id=None, sha=None):
        data = data if data is not None else jpeg(str(visit_id))
        photo_id = photo_id or uuid.uuid4()
        sha = sha or hashlib.sha256(data).hexdigest()
        return session.put(f"/api/v1/mobile/photos/{photo_id}", content=data,
                           params={"visit_id": str(visit_id), "is_primary": str(primary).lower(), "sha256": sha},
                           headers={"Content-Type": "application/octet-stream"})

    def field_reading(self, sub, value, at, task=None, reason=None):
        """Employee syncs a reading + photo; returns visit id."""
        op = self.visit_op(sub, value, at, task=task, reason=reason or (None if task else "قراءة إضافية"))
        r = expect(self.sync(self.e, [op]), 200)["results"][0]
        assert r["result"] == "accepted", r
        expect(self.upload(self.e, op["visit_id"]), 200)
        return op["visit_id"]
