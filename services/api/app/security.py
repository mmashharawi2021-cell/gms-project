from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from app.config import Settings

_ph = PasswordHasher()  # argon2id, library defaults
_DUMMY = _ph.hash("timing-equaliser-not-a-password")


def hash_password(password: str) -> str:
    return _ph.hash(password)


def verify_password(stored: str | None, password: str) -> bool:
    try:
        return _ph.verify(stored or _DUMMY, password) and stored is not None
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def new_secret(nbytes: int = 32) -> str:
    return secrets.token_urlsafe(nbytes)


_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I


def human_code(length: int = 10) -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(length))


def temporary_password() -> str:
    return human_code(4) + "-" + human_code(4) + "-" + human_code(4)


def validate_new_password(password: str, username: str) -> str | None:
    if len(password) < 8:
        return "كلمة المرور يجب ألا تقل عن 8 أحرف"
    if len(password) > 128:
        return "كلمة المرور طويلة جدًا"
    if username.lower() in password.lower():
        return "كلمة المرور يجب ألا تحتوي اسم المستخدم"
    if password.isdigit() or password.isalpha():
        return "كلمة المرور يجب أن تجمع بين أحرف وأرقام"
    return None


def make_access_token(settings: Settings, user: dict, device_id: uuid.UUID | None) -> tuple[str, int]:
    now = datetime.now(timezone.utc)
    ttl = settings.access_ttl_minutes * 60
    claims = {
        "iss": settings.jwt_issuer, "sub": str(user["id"]), "role": user["role"], "tv": user["token_version"],
        "did": str(device_id) if device_id else None, "typ": "access", "iat": int(now.timestamp()),
        "exp": int((now + timedelta(seconds=ttl)).timestamp()), "jti": uuid.uuid4().hex,
    }
    return jwt.encode(claims, settings.jwt_secret, algorithm="HS256"), ttl


def decode_access_token(settings: Settings, token: str) -> dict:
    claims = jwt.decode(token, settings.jwt_secret, algorithms=["HS256"], issuer=settings.jwt_issuer,
                        options={"require": ["exp", "iat", "sub", "typ"]})
    if claims.get("typ") != "access":
        raise jwt.InvalidTokenError("wrong token type")
    return claims
