from __future__ import annotations

import uuid
from dataclasses import dataclass

import jwt
from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import Settings
from app.db import Database
from app.errors import AppError
from app.security import decode_access_token

bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class Principal:
    id: uuid.UUID
    role: str
    username: str
    full_name: str
    device_id: uuid.UUID | None
    must_change_password: bool


def get_db(request: Request) -> Database:
    return request.app.state.db


def get_settings_dep(request: Request) -> Settings:
    return request.app.state.settings


def _principal(request: Request, creds: HTTPAuthorizationCredentials | None) -> Principal:
    if creds is None or creds.scheme.lower() != "bearer":
        raise AppError(401, "unauthenticated", "يلزم تسجيل الدخول")
    s: Settings = request.app.state.settings
    try:
        claims = decode_access_token(s, creds.credentials)
        uid = uuid.UUID(claims["sub"])
        did = uuid.UUID(claims["did"]) if claims.get("did") else None
    except (jwt.PyJWTError, ValueError, KeyError) as err:
        raise AppError(401, "invalid_token", "جلسة غير صالحة أو منتهية") from err
    db: Database = request.app.state.db
    # Identity, role and device status are re-read from the database on EVERY request: a disabled
    # account, a role change, a password reset or a revoked phone take effect immediately.
    u = db.one(None, """SELECT u.id, u.role, u.username, u.full_name, u.is_active, u.token_version, u.must_change_password,
                        (%s::uuid IS NULL OR EXISTS (SELECT 1 FROM gms.mobile_devices d WHERE d.id=%s::uuid AND d.employee_id=u.id AND d.is_active)) AS device_ok
                        FROM gms.app_users u WHERE u.id=%s""", (did, did, uid))
    if not u or not u["is_active"] or u["token_version"] != claims.get("tv") or u["role"] != claims.get("role"):
        raise AppError(401, "invalid_token", "جلسة غير صالحة أو منتهية")
    if not u["device_ok"]:
        raise AppError(403, "device_revoked", "تم إيقاف هذا الجهاز من قبل المدير")
    if u["role"] == "employee" and did is None:
        raise AppError(401, "invalid_token", "جلسة غير صالحة")
    return Principal(u["id"], u["role"], u["username"], u["full_name"], did, u["must_change_password"])


def any_user(request: Request, creds: HTTPAuthorizationCredentials | None = Depends(bearer)) -> Principal:
    """Authenticated, but allowed to act even when a password change is pending (me/change-password/logout)."""
    return _principal(request, creds)


def active_user(p: Principal = Depends(any_user)) -> Principal:
    if p.must_change_password:
        raise AppError(403, "password_change_required", "يجب تغيير كلمة المرور المؤقتة أولًا")
    return p


def manager(p: Principal = Depends(active_user)) -> Principal:
    if p.role != "manager":
        raise AppError(403, "forbidden", "هذه العملية للمدير فقط")
    return p


def employee(p: Principal = Depends(active_user)) -> Principal:
    if p.role != "employee" or p.device_id is None:
        raise AppError(403, "forbidden", "هذه العملية لتطبيق الموظف الميداني فقط")
    return p
