from __future__ import annotations

import logging
from contextlib import asynccontextmanager

import psycopg
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware

from app.config import Settings, get_settings
from app.db import Database
from app.errors import AppError, app_error_handler, db_error_handler, validation_handler
from app.ratelimit import RateLimiter
from app.storage import make_storage
from app.util import ok


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    logging.getLogger("fontTools").setLevel(logging.WARNING)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.db.open()
        yield
        app.state.db.close()

    app = FastAPI(title="GMS API", version="0.1.0", lifespan=lifespan,
                  description="نظام إدارة مولدات الكهرباء — واجهة برمجية. كل الصلاحيات تُفرض على الخادم وقاعدة البيانات.")
    app.state.settings = settings
    app.state.db = Database(settings.database_url, settings.pool_max)
    app.state.storage = make_storage(settings)
    app.state.login_limiter = RateLimiter(limit=10, window_seconds=300)

    if settings.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_credentials=False,
                           allow_methods=["GET", "POST", "PUT", "PATCH"], allow_headers=["Authorization", "Content-Type"])

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("X-Frame-Options", "DENY")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        if request.url.path.startswith("/api/") and "/content" not in request.url.path:
            response.headers.setdefault("Cache-Control", "no-store")
        return response

    app.add_exception_handler(AppError, app_error_handler)
    app.add_exception_handler(RequestValidationError, validation_handler)
    app.add_exception_handler(psycopg.Error, db_error_handler)

    from app.routers import admin, auth, cycles, finance, imports, mobile, reports, review, subscribers, system
    for r in (auth, admin, subscribers, cycles, review, finance, mobile, imports, reports, system):
        app.include_router(r.router)

    @app.get("/health", tags=["system"])
    def health():
        app.state.db.scalar(None, "SELECT 1")
        return ok({"status": "ok"})

    return app
