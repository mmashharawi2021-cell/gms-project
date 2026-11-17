"""Subscribers, schedules, meters (install / replace / reset) — manager only."""
from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.util import Kwh, Text, ok, page

router = APIRouter(prefix="/api/v1/subscribers", tags=["subscribers"])


class MeterIn(BaseModel):
    serial_no: Text
    meter_type: Literal["digital", "mechanical"]
    installed_at: datetime
    opening_value_kwh: Kwh
    note: str | None = Field(None, max_length=500)


class SubscriberIn(BaseModel):
    subscription_no: str | None = Field(None, max_length=40)
    full_name: Text
    phone: str | None = Field(None, max_length=40)
    address: str | None = Field(None, max_length=500)
    notes: str | None = Field(None, max_length=2000)
    zone_id: uuid.UUID
    interval_days: int = Field(ge=1, le=366)
    meter: MeterIn | None = None


class SubscriberPatch(BaseModel):
    full_name: Text | None = None
    phone: str | None = Field(None, max_length=40)
    address: str | None = Field(None, max_length=500)
    notes: str | None = Field(None, max_length=2000)
    zone_id: uuid.UUID | None = None


class ScheduleIn(BaseModel):
    interval_days: int = Field(ge=1, le=366)
    next_due_override: date | None = None


class ReplaceMeterIn(BaseModel):
    kind: Literal["replacement", "reset"]
    effective_at: datetime
    reason: Text
    new_serial_no: str | None = Field(None, max_length=100)
    new_meter_type: Literal["digital", "mechanical"] | None = None
    new_opening_value_kwh: Kwh
    incident_visit_id: uuid.UUID | None = None


class StopIn(BaseModel):
    reason: Text


LIST_SQL = """
SELECT s.id, s.subscription_no, s.full_name, s.phone, s.address, s.is_active, s.stopped_at, s.stop_reason,
 s.generator_id, g.name AS generator_name, s.zone_id, z.name AS zone_name,
 i.id AS installation_id, m.serial_no AS meter_serial, m.meter_type, i.installed_at,
 sc.interval_days, sc.next_due_override, gms.next_due_date(s.id) AS next_due,
 a.balance_exact_ils, a.requested_whole_ils, a.carry_fraction_ils, a.credit_balance_ils,
 count(*) OVER() AS total
FROM gms.subscribers s
JOIN gms.generators g ON g.id = s.generator_id
JOIN gms.zones z ON z.id = s.zone_id
LEFT JOIN gms.meter_installations i ON i.subscriber_id = s.id AND i.removed_at IS NULL
LEFT JOIN gms.meters m ON m.id = i.meter_id
LEFT JOIN gms.subscriber_schedules sc ON sc.subscriber_id = s.id
LEFT JOIN gms.v_subscriber_account a ON a.subscriber_id = s.id
WHERE (%(q)s::text IS NULL OR s.full_name ILIKE %(like)s OR s.subscription_no ILIKE %(like)s OR m.serial_no ILIKE %(like)s OR s.phone ILIKE %(like)s)
  AND (%(zone)s::uuid IS NULL OR s.zone_id = %(zone)s)
  AND (%(gen)s::uuid IS NULL OR s.generator_id = %(gen)s)
  AND (%(active)s::boolean IS NULL OR s.is_active = %(active)s)
  AND (NOT %(debtors)s OR a.requested_whole_ils > 0)
ORDER BY s.subscription_no
LIMIT %(limit)s OFFSET %(offset)s
"""


@router.get("")
def list_subscribers(q: str | None = None, zone_id: uuid.UUID | None = None, generator_id: uuid.UUID | None = None,
                     active: bool | None = None, debtors: bool = False, limit: int = 50, offset: int = 0,
                     db: Database = Depends(get_db), m: Principal = Depends(manager)):
    limit, offset = page(limit, offset)
    q = (q or "").strip() or None
    like = f"%{q.replace('%', '').replace('_', '')}%" if q else None
    rows = db.all(m.id, LIST_SQL, {"q": q, "like": like, "zone": zone_id, "gen": generator_id, "active": active,
                                   "debtors": debtors, "limit": limit, "offset": offset})
    total = rows[0]["total"] if rows else 0
    for r in rows:
        r.pop("total")
    return ok({"items": rows, "total": total, "limit": limit, "offset": offset})


def _detail(db: Database, actor, sid) -> dict:
    rows = db.all(actor, LIST_SQL.replace("WHERE (%(q)s", "WHERE s.id = %(id)s AND (%(q)s"),
                  {"id": sid, "q": None, "like": None, "zone": None, "gen": None, "active": None, "debtors": False, "limit": 1, "offset": 0})
    if not rows:
        raise AppError(404, "subscriber_not_found", "المشترك غير موجود")
    d = rows[0]
    d.pop("total")
    d["account"] = db.one(actor, "SELECT * FROM gms.v_subscriber_account WHERE subscriber_id=%s", (sid,))
    d["installations"] = db.all(actor, """SELECT i.id, m.serial_no, m.meter_type, i.kind, i.installed_at, i.removed_at, i.removal_reason,
        b.opening_value_kwh, b.entered_at AS opening_entered_at FROM gms.meter_installations i JOIN gms.meters m ON m.id=i.meter_id
        LEFT JOIN gms.opening_baselines b ON b.installation_id=i.id WHERE i.subscriber_id=%s ORDER BY i.installed_at DESC""", (sid,))
    d["readings"] = db.all(actor, """SELECT a.id, a.visit_id, a.cycle_id, c.label AS cycle_label, a.previous_value_kwh, a.current_value_kwh,
        a.consumption_kwh, a.verified_captured_at, a.state, a.approved_at, (f.statement_id IS NOT NULL) AS billed
        FROM gms.approved_readings a JOIN gms.reading_cycles c ON c.id=a.cycle_id
        LEFT JOIN gms.final_reading_allocations f ON f.approved_reading_id=a.id
        WHERE a.subscriber_id=%s ORDER BY a.verified_captured_at DESC, a.approved_at DESC LIMIT 200""", (sid,))
    d["visits"] = db.all(actor, """SELECT v.id, v.event_kind, v.reading_value_kwh, v.reason, v.captured_at_device, v.verified_captured_at,
        v.record_status, v.timestamp_status, v.flags, u.full_name AS employee_name FROM gms.field_visits v
        JOIN gms.app_users u ON u.id=v.employee_id WHERE v.subscriber_id=%s ORDER BY v.captured_at_device DESC LIMIT 100""", (sid,))
    return d


@router.get("/next-number")
def get_next_subscription_no(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    val = db.scalar(
        m.id,
        """SELECT COALESCE(MAX(CASE WHEN subscription_no ~ '^[0-9]+$' THEN subscription_no::bigint ELSE 0 END), 0) + 1
           FROM gms.subscribers"""
    ) or 1
    return ok({"next_subscription_no": f"{val:04d}"})


@router.get("/{sid}")
def get_subscriber(sid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(_detail(db, m.id, sid))


@router.post("", status_code=201)
def create_subscriber(body: SubscriberIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    with db.tx(m.id) as c:
        z = c.execute("SELECT generator_id, is_active FROM gms.zones WHERE id=%s", (body.zone_id,)).fetchone()
        if not z or not z["is_active"]:
            raise AppError(422, "invalid_zone", "المنطقة غير موجودة أو غير فعالة")
        
        sub_no = body.subscription_no.strip() if body.subscription_no and body.subscription_no.strip() else None
        if not sub_no:
            c.execute("LOCK TABLE gms.subscribers IN SHARE ROW EXCLUSIVE MODE")
            val = c.execute(
                """SELECT COALESCE(MAX(CASE WHEN subscription_no ~ '^[0-9]+$' THEN subscription_no::bigint ELSE 0 END), 0) + 1 AS next_val
                   FROM gms.subscribers"""
            ).fetchone()["next_val"]
            sub_no = f"{val:04d}"

        sid = c.execute("""INSERT INTO gms.subscribers(subscription_no,full_name,phone,address,notes,generator_id,zone_id)
                           VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id""",
                        (sub_no, body.full_name.strip(), body.phone, body.address, body.notes,
                         z["generator_id"], body.zone_id)).fetchone()["id"]
        c.execute("INSERT INTO gms.subscriber_schedules(subscriber_id,interval_days,changed_by) VALUES (%s,%s,%s)",
                  (sid, body.interval_days, m.id))
        if body.meter:
            mt = body.meter
            c.execute("SELECT gms.install_meter(%s,%s,%s,%s,%s,%s)",
                      (sid, mt.serial_no, mt.meter_type, mt.installed_at, mt.opening_value_kwh, mt.note))
    return ok(_detail(db, m.id, sid), 201)


@router.patch("/{sid}")
def update_subscriber(sid: uuid.UUID, body: SubscriberPatch, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    with db.tx(m.id) as c:
        row = c.execute("""UPDATE gms.subscribers SET full_name=COALESCE(%s,full_name), phone=COALESCE(%s,phone),
               address=COALESCE(%s,address), notes=COALESCE(%s,notes), zone_id=COALESCE(%s,zone_id) WHERE id=%s RETURNING id""",
                        (body.full_name, body.phone, body.address, body.notes, body.zone_id, sid)).fetchone()
        if not row:
            raise AppError(404, "subscriber_not_found", "المشترك غير موجود")
    return ok(_detail(db, m.id, sid))


@router.put("/{sid}/schedule")
def set_schedule(sid: uuid.UUID, body: ScheduleIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.one(m.id, """INSERT INTO gms.subscriber_schedules(subscriber_id,interval_days,next_due_override,changed_by)
        VALUES (%s,%s,%s,%s) ON CONFLICT (subscriber_id) DO UPDATE SET interval_days=EXCLUDED.interval_days,
        next_due_override=EXCLUDED.next_due_override, changed_by=EXCLUDED.changed_by, changed_at=now() RETURNING subscriber_id""",
           (sid, body.interval_days, body.next_due_override, m.id))
    return ok(_detail(db, m.id, sid))


@router.post("/{sid}/meter", status_code=201)
def install_meter(sid: uuid.UUID, body: MeterIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.install_meter(%s,%s,%s,%s,%s,%s)",
              (sid, body.serial_no, body.meter_type, body.installed_at, body.opening_value_kwh, body.note))
    return ok(_detail(db, m.id, sid), 201)


@router.post("/{sid}/replace-meter")
def replace_meter(sid: uuid.UUID, body: ReplaceMeterIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.replace_meter(%s,%s,%s,%s,%s,%s,%s,%s)",
              (sid, body.kind, body.effective_at, body.reason, body.new_serial_no, body.new_meter_type,
               body.new_opening_value_kwh, body.incident_visit_id))
    return ok(_detail(db, m.id, sid))


@router.post("/{sid}/stop")
def stop(sid: uuid.UUID, body: StopIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.stop_subscriber(%s,%s)", (sid, body.reason))
    return ok(_detail(db, m.id, sid))


@router.post("/{sid}/reactivate")
def reactivate(sid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.reactivate_subscriber(%s)", (sid,))
    return ok(_detail(db, m.id, sid))
