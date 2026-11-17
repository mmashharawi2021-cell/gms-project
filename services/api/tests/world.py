"""Test helper driving the database exactly like the API does: restricted login + gms.actor_id.

Synthetic fixtures only (clearly marked QA-*); never shipped to production.
"""
from __future__ import annotations

import hashlib
import json
import uuid
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row


class DbError(Exception):
    def __init__(self, sqlstate: str, code: str, message: str):
        super().__init__(f"{sqlstate} {code}: {message}")
        self.sqlstate, self.code, self.message = sqlstate, code, message


def _wrap(exc: psycopg.Error) -> DbError:
    return DbError(exc.sqlstate or "", (exc.diag.message_detail or "") if exc.diag else "", str(exc))


class World:
    def __init__(self, url: str):
        self.url = url
        self.conn = psycopg.connect(url, row_factory=dict_row)
        self.manager: uuid.UUID | None = None
        self.employee: uuid.UUID | None = None
        self.device: uuid.UUID | None = None
        self.generator: uuid.UUID | None = None
        self.zone: uuid.UUID | None = None
        self.today = self.conn.execute("SELECT gms.local_date(now()) AS d").fetchone()["d"]
        self.conn.commit()
        self._n = 0

    def close(self):
        self.conn.close()

    def connect(self):
        return psycopg.connect(self.url, row_factory=dict_row)

    # --- execution -----------------------------------------------------------------
    @contextmanager
    def tx(self, actor: uuid.UUID | None, conn=None):
        conn = conn or self.conn
        try:
            with conn.transaction():
                if actor is not None:
                    conn.execute("SELECT set_config('gms.actor_id', %s, true)", (str(actor),))
                yield conn
        except psycopg.Error as exc:
            if exc.sqlstate and (exc.sqlstate.startswith("GM") or exc.sqlstate in ("42501", "23514", "23505", "23503", "23P01")):
                raise _wrap(exc) from exc
            raise

    def call(self, actor, sql: str, params=(), conn=None):
        with self.tx(actor, conn) as c:
            row = c.execute(sql, params).fetchone()
            return next(iter(row.values())) if row else None

    def q(self, sql: str, params=()):
        with self.conn.transaction():
            return self.conn.execute(sql, params).fetchall()

    def one(self, sql: str, params=()):
        rows = self.q(sql, params)
        return rows[0] if rows else None

    def val(self, sql: str, params=()):
        row = self.one(sql, params)
        return next(iter(row.values())) if row else None

    # --- base data -----------------------------------------------------------------
    def bootstrap(self, late_sync_hours: int = 1000000):
        self.manager = self.call(None, "INSERT INTO gms.app_users(username,password_hash,full_name,role) VALUES ('qa-manager','TEST-NOT-A-REAL-HASH','QA Manager','manager') RETURNING id")
        self.employee = self.add_employee("qa-employee")
        self.generator = self.call(self.manager, "INSERT INTO gms.generators(name) VALUES ('QA-GEN') RETURNING id")
        self.zone = self.add_zone("QA-ZONE")
        self.grant(self.employee, self.zone)
        self.device = self.add_device(self.employee)
        with self.tx(self.manager) as c:
            c.execute("UPDATE gms.system_settings SET value = %s WHERE key = 'late_sync_hours'", (str(late_sync_hours),))
        return self

    def add_employee(self, username: str) -> uuid.UUID:
        return self.call(self.manager, "INSERT INTO gms.app_users(username,password_hash,full_name,role) VALUES (%s,'TEST-NOT-A-REAL-HASH',%s,'employee') RETURNING id", (username, "QA " + username))

    def add_zone(self, name: str, generator=None) -> uuid.UUID:
        return self.call(self.manager, "INSERT INTO gms.zones(generator_id,name) VALUES (%s,%s) RETURNING id", (generator or self.generator, name))

    def grant(self, employee, zone, valid_from: datetime | None = None, valid_until: datetime | None = None):
        return self.call(self.manager, "INSERT INTO gms.user_zone_grants(employee_id,zone_id,valid_from,valid_until,granted_by) VALUES (%s,%s,%s,%s,%s) RETURNING id",
                         (employee, zone, valid_from or self.at(-60), valid_until, self.manager))

    def add_device(self, employee) -> uuid.UUID:
        code = uuid.uuid4().hex
        sha = hashlib.sha256(code.encode()).hexdigest()
        self.call(self.manager, "INSERT INTO gms.device_enrollment_codes(employee_id,code_sha256,created_by,expires_at) VALUES (%s,%s,%s,now()+interval '1 hour') RETURNING id", (employee, sha, self.manager))
        return self.call(employee, "SELECT gms.enroll_device(%s,%s,%s)", (sha, uuid.uuid4().hex, "QA Android"))

    def at(self, days: int, hour: int = 10) -> datetime:
        """A UTC instant `days` from today at the given UTC hour (same local date in Asia/Gaza)."""
        d = self.today + timedelta(days=days)
        return datetime(d.year, d.month, d.day, hour, 0, tzinfo=timezone.utc)

    def add_subscriber(self, opening: str = "100.00", interval_days: int = 7, zone=None, installed_days: int = -40):
        self._n += 1
        sid = self.call(self.manager, "INSERT INTO gms.subscribers(subscription_no,full_name,generator_id,zone_id) VALUES (%s,%s,%s,%s) RETURNING id",
                        (f"QA-{self._n:04d}", f"QA Subscriber {self._n}", self.generator, zone or self.zone))
        with self.tx(self.manager) as c:
            c.execute("INSERT INTO gms.subscriber_schedules(subscriber_id,interval_days,changed_by) VALUES (%s,%s,%s)", (sid, interval_days, self.manager))
        inst = self.call(self.manager, "SELECT gms.install_meter(%s,%s,'digital',%s,%s,NULL)", (sid, f"QA-M-{self._n:04d}", self.at(installed_days), Decimal(opening)))
        return sid, inst

    def cycle(self, label: str, start_days: int, end_days: int, open_: bool = True, rate: str | None = None) -> uuid.UUID:
        cid = self.call(self.manager, "SELECT gms.create_cycle(%s,%s,%s)", (label, self.today + timedelta(days=start_days), self.today + timedelta(days=end_days)))
        if open_:
            self.call(self.manager, "SELECT gms.open_cycle(%s)", (cid,))
        if rate is not None:
            self.call(self.manager, "SELECT gms.set_provisional_rate(%s,%s,%s,'QA')", (cid, self.today + timedelta(days=start_days), Decimal(rate)))
        return cid

    def task(self, cycle, sub, planned_days: int, source: str = "manager_extra", employee=None) -> uuid.UUID:
        return self.call(self.manager, "SELECT gms.create_task(%s,%s,%s,%s,%s,NULL)", (cycle, sub, self.today + timedelta(days=planned_days), source, employee or self.employee))

    # --- field ---------------------------------------------------------------------
    @staticmethod
    def sha(payload: dict) -> str:
        return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def payload(self, sub, inst, value, at: datetime, task=None, kind="reading", reason=None, zone=None) -> dict:
        p = {"subscriber_id": str(sub), "installation_id": str(inst), "zone_id": str(zone or self.zone), "event_kind": kind,
             "captured_at_device": at.isoformat()}
        if task:
            p["task_id"] = str(task)
        if value is not None:
            p["reading_value_kwh"] = str(value)
        if reason:
            p["reason"] = reason
        return p

    def receive(self, payload: dict, visit=None, op=None, employee=None, device=None, trust="consistent", conn=None) -> dict:
        visit = visit or uuid.uuid4()
        res = self.call(employee or self.employee, "SELECT gms.receive_visit(%s,%s,%s,%s::jsonb,%s,%s,NULL)",
                        (op or uuid.uuid4(), visit, device or self.device, json.dumps(payload), self.sha(payload), trust), conn=conn)
        res["visit_id"] = visit
        return res

    def photo(self, visit, primary=True, employee=None, ready=True) -> uuid.UUID:
        pid = uuid.uuid4()
        sha = hashlib.sha256(pid.bytes).hexdigest()
        self.call(employee or self.employee, "SELECT gms.begin_photo(%s,%s,%s,%s,'image/jpeg',%s)", (pid, visit, sha, 1234, primary))
        if ready:
            self.call(employee or self.employee, "SELECT gms.complete_photo(%s,%s,%s)", (pid, sha, 1234))
        return pid

    def visit(self, sub, inst, value, at: datetime, task=None, kind="reading", reason=None, photo=True, trust="consistent") -> uuid.UUID:
        if task is None and reason is None:
            reason = "QA extra visit"
        res = self.receive(self.payload(sub, inst, value, at, task, kind, reason), trust=trust)
        assert res["result"] == "accepted", res
        if photo:
            self.photo(res["visit_id"])
        return res["visit_id"]

    def approve(self, visit, corrected=None, rationale=None, ack=False, late=False, conn=None) -> uuid.UUID:
        return self.call(self.manager, "SELECT gms.approve_visit(%s,%s,%s,%s,%s)", (visit, corrected, rationale, ack, late), conn=conn)

    def read_and_approve(self, sub, inst, value, at: datetime, task) -> uuid.UUID:
        return self.approve(self.visit(sub, inst, value, at, task=task))

    def finalize(self, cycle, rate: str, conn=None) -> int:
        return self.call(self.manager, "SELECT gms.finalize_cycle(%s,%s)", (cycle, Decimal(rate)), conn=conn)

    def pay(self, sub, amount: str, key=None, paid_at=None, method="cash", reference=None, actor=None, conn=None) -> uuid.UUID:
        return self.call(actor or self.manager, "SELECT gms.record_payment(%s,%s,%s,%s,%s,%s)",
                         (sub, Decimal(amount), paid_at or self.at(0, 6), method, reference, key or uuid.uuid4()), conn=conn)

    def adjust(self, sub, amount: str, reason="QA adjustment", key=None) -> uuid.UUID:
        return self.call(self.manager, "SELECT gms.record_adjustment(%s,%s,%s,%s,NULL)", (sub, Decimal(amount), reason, key or uuid.uuid4()))

    def balance(self, sub) -> Decimal:
        return self.val("SELECT gms.ledger_balance(%s)", (sub,))

    def account(self, sub) -> dict:
        return self.one("SELECT * FROM gms.v_subscriber_account WHERE subscriber_id = %s", (sub,))

    def statement(self, cycle, sub) -> dict:
        return self.one("SELECT * FROM gms.statement_versions WHERE cycle_id = %s AND subscriber_id = %s AND state = 'final'", (cycle, sub))

    def now(self, minutes: int = -5) -> datetime:
        return datetime.now(timezone.utc) + timedelta(minutes=minutes)

    def week(self, label="QA-C1", start=-13, end=-7, rate=None):
        """bootstrap + one open past cycle + one subscriber with a task; returns (cycle, sub, inst, task)."""
        if self.manager is None:
            self.bootstrap()
        c = self.cycle(label, start, end, rate=rate)
        sub, inst = self.add_subscriber()
        return c, sub, inst, self.task(c, sub, start + 3)
