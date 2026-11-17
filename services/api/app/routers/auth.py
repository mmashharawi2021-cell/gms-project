from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from app.db import Database
from app.deps import Principal, any_user, get_db
from app.errors import AppError
from app.security import (hash_password, make_access_token, new_secret, sha256_hex, validate_new_password,
                          verify_password)
from app.util import ok

router = APIRouter(prefix="/api/v1/auth", tags=["auth"])


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=1, max_length=256)
    client: Literal["web", "mobile"]
    install_id: str | None = Field(None, min_length=16, max_length=128)
    enrollment_code: str | None = Field(None, max_length=64)
    device_label: str | None = Field(None, max_length=100)


class RefreshIn(BaseModel):
    refresh_token: str = Field(min_length=10, max_length=300)
    install_id: str | None = Field(None, max_length=128)


class ChangePasswordIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=256)
    new_password: str = Field(min_length=1, max_length=256)


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _audit(db: Database, actor, action: str, user_id, data: dict):
    with db.tx(actor) as c:
        c.execute("SELECT gms.audit(%s,'app_users',%s,%s::jsonb)", (action, user_id, _json(data)))


def _json(d: dict) -> str:
    from app.util import dumps
    return dumps(d).decode()


def issue_tokens(request: Request, user: dict, device_id, client: str, family: uuid.UUID | None = None, conn=None) -> dict:
    s = request.app.state.settings
    access, ttl = make_access_token(s, user, device_id)
    rid, secret = uuid.uuid4(), new_secret()
    raw = f"{rid}.{secret}"
    ttl_refresh = timedelta(days=s.refresh_ttl_days_mobile) if client == "mobile" else timedelta(hours=s.refresh_ttl_hours_web)
    expires = datetime.now(timezone.utc) + ttl_refresh
    sql = """INSERT INTO gms.auth_refresh_tokens(id,user_id,device_id,family_id,token_sha256,client_kind,expires_at)
             VALUES (%s,%s,%s,%s,%s,%s,%s)"""
    params = (rid, user["id"], device_id, family or uuid.uuid4(), sha256_hex(raw), client, expires)
    if conn is not None:
        conn.execute(sql, params)
    else:
        with request.app.state.db.tx() as c:
            c.execute(sql, params)
    return {"access_token": access, "token_type": "bearer", "expires_in": ttl, "refresh_token": raw,
            "refresh_expires_at": expires}


def _user_view(u: dict, device_id=None) -> dict:
    return {"id": u["id"], "username": u["username"], "full_name": u["full_name"], "role": u["role"],
            "must_change_password": u["must_change_password"], "device_id": device_id}


@router.post("/login")
def login(body: LoginIn, request: Request, db: Database = Depends(get_db)):
    s = request.app.state.settings
    uname = body.username.strip().lower()
    if not request.app.state.login_limiter.allow(f"{_client_ip(request)}|{uname}"):
        raise AppError(429, "too_many_attempts", "محاولات كثيرة؛ حاول بعد دقائق")
    u = db.one(None, "SELECT * FROM gms.app_users WHERE username=%s", (uname,))
    if u and u["locked_until"] and u["locked_until"] > datetime.now(timezone.utc):
        _audit(db, None, "LOGIN_LOCKED", u["id"], {"ip": _client_ip(request)})
        raise AppError(423, "account_locked", "الحساب مقفل مؤقتًا بسبب محاولات خاطئة متكررة")
    if not verify_password(u["password_hash"] if u else None, body.password):
        if u:
            db.one(None, """UPDATE gms.app_users SET failed_logins = failed_logins + 1,
                    locked_until = CASE WHEN failed_logins + 1 >= %s THEN now() + make_interval(mins => %s) END
                    WHERE id = %s RETURNING id""", (s.login_max_failures, s.login_lock_minutes, u["id"]))
            _audit(db, None, "LOGIN_FAILED", u["id"], {"ip": _client_ip(request), "client": body.client})
        raise AppError(401, "invalid_credentials", "اسم المستخدم أو كلمة المرور غير صحيحة")
    if not u["is_active"]:
        _audit(db, None, "LOGIN_DISABLED", u["id"], {"ip": _client_ip(request)})
        raise AppError(403, "account_disabled", "الحساب موقوف؛ راجع المدير")
    if u["failed_logins"] or u["locked_until"]:
        db.one(None, "UPDATE gms.app_users SET failed_logins=0, locked_until=NULL WHERE id=%s RETURNING id", (u["id"],))
    device_id = None
    if body.client == "web":
        if u["role"] != "manager":
            raise AppError(403, "web_managers_only", "لوحة الويب مخصصة للمدير؛ استخدم تطبيق الموظف")
    else:
        if u["role"] != "employee":
            raise AppError(403, "mobile_employees_only", "تطبيق الهاتف مخصص للموظفين الميدانيين")
        if not body.install_id:
            raise AppError(422, "install_id_required", "معرّف تثبيت التطبيق مطلوب")
        if body.enrollment_code:
            code = body.enrollment_code.strip().upper().replace("-", "").replace(" ", "")
            device_id = db.scalar(u["id"], "SELECT gms.enroll_device(%s,%s,%s)",
                                  (sha256_hex(code), body.install_id, (body.device_label or "Android").strip()[:100]))
        else:
            row = db.one(None, "SELECT id FROM gms.mobile_devices WHERE employee_id=%s AND install_id=%s AND is_active",
                         (u["id"], body.install_id))
            if not row:
                with db.tx() as c:
                    c.execute("""UPDATE gms.mobile_devices SET is_active = false, revoked_at = now(), revoke_reason = 'تسجيل دخول جديد'
                                 WHERE is_active AND (employee_id = %s OR install_id = %s)""", (u["id"], body.install_id))
                    c.execute("UPDATE gms.auth_refresh_tokens SET revoked_at = now() WHERE user_id = %s AND client_kind = 'mobile' AND revoked_at IS NULL", (u["id"],))
                    device_id = c.execute("""INSERT INTO gms.mobile_devices(employee_id, install_id, device_label)
                                             VALUES (%s, %s, %s) RETURNING id""",
                                          (u["id"], body.install_id, (body.device_label or "Android").strip()[:100])).fetchone()["id"]
            else:
                device_id = row["id"]
    tokens = issue_tokens(request, u, device_id, body.client)
    _audit(db, u["id"], "LOGIN_OK", u["id"], {"ip": _client_ip(request), "client": body.client, "device_id": device_id})
    return ok({**tokens, "user": _user_view(u, device_id)})


@router.post("/refresh")
def refresh(body: RefreshIn, request: Request, db: Database = Depends(get_db)):
    digest = sha256_hex(body.refresh_token)
    with db.tx() as c:
        t = c.execute("SELECT * FROM gms.auth_refresh_tokens WHERE token_sha256=%s FOR UPDATE", (digest,)).fetchone()
        if not t or t["revoked_at"] or t["expires_at"] <= datetime.now(timezone.utc):
            raise AppError(401, "invalid_refresh", "انتهت الجلسة؛ سجّل الدخول مجددًا")
        if t["used_at"]:
            # Reuse of a rotated token = theft signal: kill the whole family.
            c.execute("UPDATE gms.auth_refresh_tokens SET revoked_at=now() WHERE family_id=%s AND revoked_at IS NULL", (t["family_id"],))
            c.execute("SELECT gms.audit('REFRESH_REUSE','app_users',%s,'{}'::jsonb)", (t["user_id"],))
            reuse = True
        else:
            reuse = False
            u = c.execute("SELECT * FROM gms.app_users WHERE id=%s", (t["user_id"],)).fetchone()
            if not u["is_active"]:
                raise AppError(401, "invalid_refresh", "انتهت الجلسة؛ سجّل الدخول مجددًا")
            if t["device_id"]:
                d = c.execute("SELECT install_id, is_active FROM gms.mobile_devices WHERE id=%s", (t["device_id"],)).fetchone()
                if not d["is_active"] or (body.install_id and body.install_id != d["install_id"]):
                    c.execute("INSERT INTO gms.sync_rejections(user_id, device_id, reason) VALUES (%s,%s,'device_revoked')", (u["id"], t["device_id"]))
                    raise AppError(403, "device_revoked", "تم إيقاف هذا الجهاز من قبل المدير")
            c.execute("UPDATE gms.auth_refresh_tokens SET used_at=now() WHERE id=%s", (t["id"],))
            tokens = issue_tokens(request, u, t["device_id"], t["client_kind"], t["family_id"], conn=c)
    if reuse:
        raise AppError(401, "invalid_refresh", "انتهت الجلسة؛ سجّل الدخول مجددًا")
    return ok({**tokens, "user": _user_view(u, t["device_id"])})


@router.post("/logout")
def logout(body: RefreshIn, db: Database = Depends(get_db), p: Principal = Depends(any_user)):
    with db.tx(p.id) as c:
        c.execute("""UPDATE gms.auth_refresh_tokens SET revoked_at=now()
                     WHERE family_id IN (SELECT family_id FROM gms.auth_refresh_tokens WHERE token_sha256=%s AND user_id=%s)
                       AND revoked_at IS NULL""", (sha256_hex(body.refresh_token), p.id))
    return ok()


@router.get("/me")
def me(p: Principal = Depends(any_user)):
    return ok({"id": p.id, "username": p.username, "full_name": p.full_name, "role": p.role,
               "device_id": p.device_id, "must_change_password": p.must_change_password})


@router.post("/change-password")
def change_password(body: ChangePasswordIn, request: Request, db: Database = Depends(get_db), p: Principal = Depends(any_user)):
    u = db.one(None, "SELECT * FROM gms.app_users WHERE id=%s", (p.id,))
    if not verify_password(u["password_hash"], body.current_password):
        raise AppError(401, "invalid_credentials", "كلمة المرور الحالية غير صحيحة")
    problem = validate_new_password(body.new_password, u["username"])
    if problem or body.new_password == body.current_password:
        raise AppError(422, "weak_password", problem or "اختر كلمة مرور مختلفة عن الحالية")
    with db.tx(p.id) as c:
        u = c.execute("""UPDATE gms.app_users SET password_hash=%s, must_change_password=false, password_changed_at=now(),
                         token_version=token_version+1 WHERE id=%s RETURNING *""", (hash_password(body.new_password), p.id)).fetchone()
        c.execute("UPDATE gms.auth_refresh_tokens SET revoked_at=now() WHERE user_id=%s AND revoked_at IS NULL", (p.id,))
        tokens = issue_tokens(request, u, p.device_id, "mobile" if p.device_id else "web", conn=c)
    return ok({**tokens, "user": _user_view(u, p.device_id)})
