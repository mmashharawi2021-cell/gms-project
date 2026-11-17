from __future__ import annotations

import logging

import psycopg
from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

log = logging.getLogger("gms")

_SQLSTATE_HTTP = {"GM403": 403, "GM404": 404, "GM409": 409, "GM422": 422}


class AppError(Exception):
    def __init__(self, status: int, code: str, message: str, extra: dict | None = None):
        super().__init__(message)
        self.status, self.code, self.message, self.extra = status, code, message, extra or {}


def from_db(exc: psycopg.Error) -> AppError | None:
    state = exc.sqlstate or ""
    diag = exc.diag
    if state in _SQLSTATE_HTTP:
        return AppError(_SQLSTATE_HTTP[state], diag.message_detail or "error", diag.message_primary or "خطأ")
    if state == "42501":
        return AppError(403, "forbidden", "العملية غير مصرح بها")
    if state == "23505":
        return AppError(409, "duplicate", "القيمة مستخدمة مسبقًا", {"constraint": diag.constraint_name})
    if state == "23503":
        return AppError(422, "invalid_reference", "مرجع غير موجود", {"constraint": diag.constraint_name})
    if state == "23514":
        return AppError(422, "constraint_violation", "القيمة تخالف قيود البيانات", {"constraint": diag.constraint_name})
    if state == "23P01":
        return AppError(409, "overlap", "تداخل مع سجل آخر")
    if state in ("22P02", "22007", "22008", "22003"):
        return AppError(422, "invalid_value", "قيمة غير صالحة")
    return None


def body(code: str, message: str, extra: dict | None = None) -> dict:
    return {"error": {"code": code, "message": message, **(extra or {})}}


async def app_error_handler(_: Request, exc: AppError):
    return JSONResponse(status_code=exc.status, content=body(exc.code, exc.message, exc.extra))


async def validation_handler(_: Request, exc: RequestValidationError):
    fields = []
    for e in exc.errors():
        fields.append({"field": ".".join(str(p) for p in e.get("loc", ())[1:]), "message": e.get("msg", "")})
    return JSONResponse(status_code=422, content=body("validation_error", "بيانات الطلب غير صالحة", {"fields": fields}))


async def db_error_handler(_: Request, exc: psycopg.Error):
    mapped = from_db(exc)
    if mapped:
        return JSONResponse(status_code=mapped.status, content=body(mapped.code, mapped.message, mapped.extra))
    log.error("database error sqlstate=%s", exc.sqlstate)  # never log parameters (may contain personal data)
    return JSONResponse(status_code=500, content=body("server_error", "خطأ داخلي في الخادم"))
