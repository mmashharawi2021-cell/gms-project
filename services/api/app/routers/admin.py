"""Manager administration: accounts, phones, zone grants, generators, zones, settings, audit trail."""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.security import hash_password, human_code, sha256_hex, temporary_password
from app.util import Text, ok, page

router = APIRouter(prefix="/api/v1", tags=["admin"])

USER_COLS = "id, username, full_name, role, is_active, must_change_password, created_at, password_changed_at, locked_until"


class UserIn(BaseModel):
    username: str = Field(pattern=r"^[A-Za-z0-9._-]{3,40}$")
    full_name: Text
    role: Literal["manager", "employee"]


class UserPatch(BaseModel):
    full_name: Text | None = None
    is_active: bool | None = None


class ReasonIn(BaseModel):
    reason: Text


class GrantIn(BaseModel):
    employee_id: uuid.UUID
    zone_id: uuid.UUID
    valid_from: datetime | None = None   # may be back-dated (existing assignments); never in the future


class GeneratorIn(BaseModel):
    name: Text
    location_note: str | None = Field(None, max_length=500)
    is_active: bool = True


class ZoneIn(BaseModel):
    generator_id: uuid.UUID
    name: Text
    reading_weekday: int | None = Field(None, ge=0, le=6)
    is_active: bool = True


class ZonePatch(BaseModel):
    name: Text | None = None
    reading_weekday: int | None = Field(None, ge=0, le=6)
    clear_weekday: bool = False
    is_active: bool | None = None


class SettingIn(BaseModel):
    value: str = Field(min_length=1, max_length=100)


EDITABLE_SETTINGS = {"business_timezone", "clock_skew_tolerance_minutes", "late_sync_hours", "default_interval_days",
                     "business_name", "business_phone", "statement_footer"}
TEXT_SETTINGS = {"business_name": 80, "business_phone": 40, "statement_footer": 160}


# --- accounts ------------------------------------------------------------------------------
@router.get("/users")
def list_users(role: str | None = None, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    rows = db.all(m.id, f"""SELECT {USER_COLS},
        (SELECT json_agg(json_build_object('zone_id', g.zone_id, 'zone_name', z.name, 'grant_id', g.id) ORDER BY z.name)
           FROM gms.user_zone_grants g JOIN gms.zones z ON z.id=g.zone_id
          WHERE g.employee_id=u.id AND g.valid_until IS NULL) AS zones,
        (SELECT json_build_object('id', d.id, 'label', d.device_label, 'enrolled_at', d.enrolled_at, 'last_seen_at', d.last_seen_at)
           FROM gms.mobile_devices d WHERE d.employee_id=u.id AND d.is_active) AS active_device
        FROM gms.app_users u WHERE (%s::text IS NULL OR role=%s) ORDER BY role, full_name""", (role, role))
    return ok(rows)


@router.post("/users", status_code=201)
def create_user(body: UserIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    temp = temporary_password()
    row = db.one(m.id, f"""INSERT INTO gms.app_users(username,password_hash,full_name,role,must_change_password)
                         VALUES (%s,%s,%s,%s,true) RETURNING {USER_COLS}""",
                 (body.username.lower(), hash_password(temp), body.full_name.strip(), body.role))
    return ok({**row, "temporary_password": temp}, 201)


@router.patch("/users/{user_id}")
def update_user(user_id: uuid.UUID, body: UserPatch, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    if user_id == m.id and body.is_active is False:
        raise AppError(409, "cannot_disable_self", "لا يمكنك إيقاف حسابك الحالي")
    with db.tx(m.id) as c:
        row = c.execute(f"""UPDATE gms.app_users SET full_name=COALESCE(%s, full_name), is_active=COALESCE(%s, is_active),
                 token_version = token_version + CASE WHEN %s IS FALSE THEN 1 ELSE 0 END
                 WHERE id=%s RETURNING {USER_COLS}""", (body.full_name, body.is_active, body.is_active, user_id)).fetchone()
        if not row:
            raise AppError(404, "user_not_found", "المستخدم غير موجود")
        if body.is_active is False:
            c.execute("UPDATE gms.auth_refresh_tokens SET revoked_at=now() WHERE user_id=%s AND revoked_at IS NULL", (user_id,))
    return ok(row)


@router.post("/users/{user_id}/reset-password")
def reset_password(user_id: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    temp = temporary_password()
    with db.tx(m.id) as c:
        row = c.execute(f"""UPDATE gms.app_users SET password_hash=%s, must_change_password=true, failed_logins=0,
                 locked_until=NULL, token_version=token_version+1 WHERE id=%s RETURNING {USER_COLS}""",
                        (hash_password(temp), user_id)).fetchone()
        if not row:
            raise AppError(404, "user_not_found", "المستخدم غير موجود")
        c.execute("UPDATE gms.auth_refresh_tokens SET revoked_at=now() WHERE user_id=%s AND revoked_at IS NULL", (user_id,))
    return ok({**row, "temporary_password": temp})


# --- phones --------------------------------------------------------------------------------
@router.post("/users/{user_id}/enrollment-codes", status_code=201)
def issue_enrollment_code(user_id: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    u = db.one(m.id, "SELECT role, is_active FROM gms.app_users WHERE id=%s", (user_id,))
    if not u or u["role"] != "employee" or not u["is_active"]:
        raise AppError(422, "invalid_employee", "رمز التفعيل يصدر لموظف ميداني فعال فقط")
    code = human_code(10)
    expires = datetime.now(timezone.utc) + timedelta(hours=24)
    db.one(m.id, """INSERT INTO gms.device_enrollment_codes(employee_id,code_sha256,created_by,expires_at)
                    VALUES (%s,%s,%s,%s) RETURNING id""", (user_id, sha256_hex(code), m.id, expires))
    return ok({"code": f"{code[:5]}-{code[5:]}", "expires_at": expires}, 201)


@router.get("/devices")
def list_devices(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, """SELECT d.id, d.employee_id, u.full_name AS employee_name, d.device_label, d.is_active,
        d.enrolled_at, d.revoked_at, d.revoke_reason, d.last_seen_at,
        (SELECT count(*) FROM gms.sync_operations s WHERE s.device_id=d.id) AS operations,
        (SELECT max(accepted_at) FROM gms.sync_operations s WHERE s.device_id=d.id) AS last_sync_at
        FROM gms.mobile_devices d JOIN gms.app_users u ON u.id=d.employee_id ORDER BY d.is_active DESC, d.enrolled_at DESC"""))


@router.post("/devices/{device_id}/revoke")
def revoke_device(device_id: uuid.UUID, body: ReasonIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.revoke_device(%s,%s)", (device_id, body.reason))
    return ok()


@router.get("/sync/monitor")
def sync_monitor(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok({
        "by_result": db.all(m.id, """SELECT result_code, count(*) AS n FROM gms.sync_operations
                                     WHERE accepted_at > now() - interval '7 days' GROUP BY 1 ORDER BY 1"""),
        "recent_rejections": db.all(m.id, """SELECT r.occurred_at, r.reason, u.full_name AS employee_name, r.device_id
            FROM gms.sync_rejections r LEFT JOIN gms.app_users u ON u.id=r.user_id ORDER BY r.occurred_at DESC LIMIT 50"""),
        "rejected_operations": db.all(m.id, """SELECT s.accepted_at, s.result_code, s.result_data->>'reason' AS reason,
            u.full_name AS employee_name, s.entity_id FROM gms.sync_operations s JOIN gms.app_users u ON u.id=s.employee_id
            WHERE s.result_code IN ('rejected','conflict') ORDER BY s.accepted_at DESC LIMIT 50"""),
        "photos_pending": db.scalar(m.id, "SELECT count(*) FROM gms.visit_photos WHERE state <> 'ready'"),
        "visits_awaiting_photo": db.scalar(m.id, "SELECT count(*) FROM gms.field_visits WHERE record_status='awaiting_photo'"),
        "devices": db.all(m.id, """SELECT d.id, u.full_name AS employee_name, d.device_label, d.last_seen_at,
            (SELECT max(accepted_at) FROM gms.sync_operations s WHERE s.device_id=d.id) AS last_sync_at
            FROM gms.mobile_devices d JOIN gms.app_users u ON u.id=d.employee_id WHERE d.is_active ORDER BY u.full_name"""),
    })


# --- zone grants ---------------------------------------------------------------------------
@router.post("/zone-grants", status_code=201)
def grant_zone(body: GrantIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    u = db.one(m.id, "SELECT role FROM gms.app_users WHERE id=%s AND is_active", (body.employee_id,))
    if not u or u["role"] != "employee":
        raise AppError(422, "invalid_employee", "الموظف غير موجود أو غير فعال")
    vf = body.valid_from or datetime.now(timezone.utc)
    if vf > datetime.now(timezone.utc) + timedelta(minutes=5):
        raise AppError(422, "future_date", "بداية الصلاحية لا تكون في المستقبل")
    row = db.one(m.id, """INSERT INTO gms.user_zone_grants(employee_id,zone_id,valid_from,granted_by) VALUES (%s,%s,%s,%s)
                          RETURNING id, employee_id, zone_id, valid_from""", (body.employee_id, body.zone_id, vf, m.id))
    return ok(row, 201)


@router.post("/zone-grants/{grant_id}/end")
def end_grant(grant_id: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    row = db.one(m.id, "UPDATE gms.user_zone_grants SET valid_until=now() WHERE id=%s AND valid_until IS NULL RETURNING id", (grant_id,))
    if not row:
        raise AppError(404, "grant_not_found", "الصلاحية غير موجودة أو منتهية")
    return ok()


# --- generators & zones --------------------------------------------------------------------
@router.get("/generators")
def list_generators(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, """SELECT g.*, (SELECT count(*) FROM gms.subscribers s WHERE s.generator_id=g.id AND s.is_active) AS active_subscribers,
        (SELECT json_agg(json_build_object('id', z.id, 'name', z.name, 'reading_weekday', z.reading_weekday, 'is_active', z.is_active,
                 'subscribers', (SELECT count(*) FROM gms.subscribers s WHERE s.zone_id=z.id AND s.is_active),
                 'employees', (SELECT json_agg(json_build_object('id', u.id, 'full_name', u.full_name)) FROM gms.user_zone_grants gr
                               JOIN gms.app_users u ON u.id=gr.employee_id WHERE gr.zone_id=z.id AND gr.valid_until IS NULL))
                 ORDER BY z.name) FROM gms.zones z WHERE z.generator_id=g.id) AS zones
        FROM gms.generators g ORDER BY g.name"""))


@router.get("/generators/{gid}/power-loss")
def generator_power_loss(gid: uuid.UUID, cycle_id: uuid.UUID | None = None, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    c = db.one(m.id, "SELECT id, label, starts_on, ends_on, state FROM gms.reading_cycles WHERE (%s::uuid IS NULL OR id=%s) ORDER BY starts_on DESC LIMIT 1", (cycle_id, cycle_id))
    if not c:
        return ok({"cycle": None, "generator": None, "subscribers": [], "total_consumed_kwh": "0", "rate_ils_per_kwh": "0"})

    rate = db.scalar(m.id, """SELECT COALESCE(
        (SELECT rate_snapshot_ils_per_kwh FROM gms.statement_versions WHERE cycle_id=%s LIMIT 1),
        (SELECT provisional_rate_ils_per_kwh FROM gms.cycle_price_decisions WHERE cycle_id=%s),
        0
    )""", (c["id"], c["id"]))

    gen = db.one(m.id, "SELECT id, name, location_note FROM gms.generators WHERE id=%s", (gid,))
    if not gen:
        raise AppError(404, "generator_not_found", "المولد غير موجود")

    subscribers = db.all(m.id, """
        SELECT s.id, s.subscription_no, s.full_name, z.name AS zone_name,
               COALESCE(a.consumption_kwh, 0) AS consumption_kwh,
               a.previous_value_kwh, a.current_value_kwh
        FROM gms.subscribers s
        JOIN gms.zones z ON z.id=s.zone_id
        LEFT JOIN gms.approved_readings a ON a.subscriber_id=s.id AND a.cycle_id=%s AND a.state='active'
        WHERE s.generator_id=%s AND s.is_active
        ORDER BY consumption_kwh DESC, s.subscription_no
    """, (c["id"], gid))

    total_kwh = sum(s["consumption_kwh"] for s in subscribers)
    return ok({
        "cycle": c,
        "generator": gen,
        "rate_ils_per_kwh": str(rate or 0),
        "total_consumed_kwh": str(total_kwh),
        "subscribers_count": len(subscribers),
        "subscribers": subscribers
    })


@router.post("/generators", status_code=201)
def create_generator(body: GeneratorIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.one(m.id, "INSERT INTO gms.generators(name,location_note,is_active) VALUES (%s,%s,%s) RETURNING *",
                     (body.name.strip(), body.location_note, body.is_active)), 201)


@router.put("/generators/{gid}")
def update_generator(gid: uuid.UUID, body: GeneratorIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    row = db.one(m.id, "UPDATE gms.generators SET name=%s, location_note=%s, is_active=%s WHERE id=%s RETURNING *",
                 (body.name.strip(), body.location_note, body.is_active, gid))
    if not row:
        raise AppError(404, "not_found", "المولد غير موجود")
    return ok(row)


@router.post("/zones", status_code=201)
def create_zone(body: ZoneIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.one(m.id, "INSERT INTO gms.zones(generator_id,name,reading_weekday,is_active) VALUES (%s,%s,%s,%s) RETURNING *",
                     (body.generator_id, body.name.strip(), body.reading_weekday, body.is_active)), 201)


@router.patch("/zones/{zid}")
def update_zone(zid: uuid.UUID, body: ZonePatch, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    row = db.one(m.id, """UPDATE gms.zones SET name=COALESCE(%s,name),
           reading_weekday=CASE WHEN %s THEN NULL ELSE COALESCE(%s, reading_weekday) END, is_active=COALESCE(%s,is_active)
           WHERE id=%s RETURNING *""", (body.name, body.clear_weekday, body.reading_weekday, body.is_active, zid))
    if not row:
        raise AppError(404, "not_found", "المنطقة غير موجودة")
    return ok(row)


# --- settings & audit ----------------------------------------------------------------------
@router.get("/settings")
def get_settings(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, "SELECT key, value, updated_at FROM gms.system_settings ORDER BY key"))


@router.put("/settings/{key}")
def put_setting(key: str, body: SettingIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    if key not in EDITABLE_SETTINGS:
        raise AppError(404, "not_found", "إعداد غير معروف")
    v = body.value.strip()
    if key == "business_timezone":
        if not db.scalar(m.id, "SELECT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name=%s)", (v,)):
            raise AppError(422, "invalid_timezone", "منطقة زمنية غير معروفة")
        if db.scalar(m.id, "SELECT EXISTS (SELECT 1 FROM gms.approved_readings)"):
            raise AppError(409, "timezone_locked", "لا يمكن تغيير المنطقة الزمنية بعد اعتماد قراءات")
    elif key in TEXT_SETTINGS:
        if len(v) > TEXT_SETTINGS[key] or any(ord(ch) < 32 for ch in v):
            raise AppError(422, "invalid_value", f"النص طويل جدًا (الحد {TEXT_SETTINGS[key]} حرفًا) أو يحتوي رموزًا غير مسموحة")
    elif not v.isdigit() or not (1 <= int(v) <= 10000):
        raise AppError(422, "invalid_value", "قيمة رقمية غير صالحة")
    return ok(db.one(m.id, "UPDATE gms.system_settings SET value=%s, updated_by=%s, updated_at=now() WHERE key=%s RETURNING key, value, updated_at",
                     (v, m.id, key)))


@router.get("/audit")
def audit(entity_type: str | None = None, entity_id: uuid.UUID | None = None, actor_id: uuid.UUID | None = None,
          limit: int = 100, offset: int = 0, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    limit, offset = page(limit, offset)
    return ok(db.all(m.id, """SELECT a.id, a.occurred_at, a.actor_id, u.full_name AS actor_name, a.action_code, a.entity_type,
        a.entity_id, a.before_data, a.after_data FROM gms.audit_logs a LEFT JOIN gms.app_users u ON u.id=a.actor_id
        WHERE (%(t)s::text IS NULL OR a.entity_type=%(t)s) AND (%(e)s::uuid IS NULL OR a.entity_id=%(e)s)
          AND (%(a)s::uuid IS NULL OR a.actor_id=%(a)s)
        ORDER BY a.id DESC LIMIT %(l)s OFFSET %(o)s""", {"t": entity_type, "e": entity_id, "a": actor_id, "l": limit, "o": offset}))
