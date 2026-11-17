"""Manager dashboard and backup download (BR-31: manual download after re-authentication)."""
from __future__ import annotations

import tarfile
import tempfile
import uuid
from pathlib import Path

from fastapi import APIRouter, BackgroundTasks, Depends, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.security import verify_password
from app.util import ok

router = APIRouter(prefix="/api/v1", tags=["system"])


class ReauthIn(BaseModel):
    password: str = Field(min_length=1, max_length=256)


@router.get("/dashboard")
def dashboard(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    cycle = db.one(m.id, """SELECT c.id, c.label, c.starts_on, c.ends_on, c.state, cp.provisional_rate_ils_per_kwh
        FROM gms.reading_cycles c LEFT JOIN gms.cycle_price_decisions cp ON cp.cycle_id=c.id
        WHERE c.state='open' LIMIT 1""")
    data = {"open_cycle": cycle}
    if cycle:
        data["blockers"] = db.scalar(m.id, "SELECT gms.cycle_blockers(%s)", (cycle["id"],))
        data["tasks"] = db.all(m.id, "SELECT status, count(*) AS n FROM gms.reading_tasks WHERE cycle_id=%s GROUP BY 1", (cycle["id"],))
    data["visits"] = db.all(m.id, """SELECT record_status, count(*) AS n FROM gms.field_visits
        WHERE record_status IN ('awaiting_photo','pending_review','exception') GROUP BY 1""")
    data["counts"] = db.one(m.id, """SELECT (SELECT count(*) FROM gms.subscribers WHERE is_active) AS active_subscribers,
        (SELECT count(*) FROM gms.generators WHERE is_active) AS generators,
        (SELECT count(*) FROM gms.app_users WHERE role='employee' AND is_active) AS employees,
        (SELECT count(*) FROM gms.mobile_devices WHERE is_active) AS active_devices,
        (SELECT count(*) FROM gms.visit_error_reports WHERE acknowledged_at IS NULL) AS open_error_reports""")
    data["money"] = db.one(m.id, """SELECT COALESCE(sum(requested_whole_ils),0) AS requested_total_ils,
        COALESCE(sum(credit_balance_ils),0) AS credit_total_ils, count(*) FILTER (WHERE requested_whole_ils > 0) AS debtors
        FROM gms.v_subscriber_account""")
    data["last_backup"] = db.one(m.id, "SELECT started_at, ended_at, succeeded, kind, size_bytes FROM gms.backup_job_log ORDER BY started_at DESC LIMIT 1")
    return ok(data)


@router.get("/backups")
def list_backups(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, """SELECT id, kind, started_at, ended_at, succeeded, artifact_name, size_bytes, notes
                             FROM gms.backup_job_log ORDER BY started_at DESC LIMIT 100"""))


@router.post("/backups/{bid}/download")
def download_backup(bid: uuid.UUID, body: ReauthIn, request: Request, background: BackgroundTasks,
                    db: Database = Depends(get_db), m: Principal = Depends(manager)):
    pw = db.scalar(m.id, "SELECT password_hash FROM gms.app_users WHERE id=%s", (m.id,))
    if not verify_password(pw, body.password):
        db.scalar(m.id, "SELECT gms.audit('BACKUP_DOWNLOAD_DENIED','backup_job_log',%s,'{}'::jsonb)", (bid,))
        raise AppError(401, "reauth_failed", "كلمة المرور غير صحيحة")
    job = db.one(m.id, "SELECT artifact_name, succeeded FROM gms.backup_job_log WHERE id=%s", (bid,))
    if not job or not job["succeeded"] or not job["artifact_name"]:
        raise AppError(404, "backup_not_available", "النسخة غير متاحة للتنزيل")
    root = Path(request.app.state.settings.backup_dir).resolve()
    folder = (root / job["artifact_name"]).resolve()
    if root not in folder.parents or not (folder / "manifest.json").is_file():
        raise AppError(404, "backup_not_available", "ملفات النسخة غير موجودة على الخادم")
    tmp = tempfile.NamedTemporaryFile(suffix=".tar", delete=False)
    tmp.close()
    with tarfile.open(tmp.name, "w") as tar:
        tar.add(folder, arcname=folder.name)
    background.add_task(lambda p=tmp.name: Path(p).unlink(missing_ok=True))
    db.scalar(m.id, "SELECT gms.audit('BACKUP_DOWNLOAD','backup_job_log',%s,'{}'::jsonb)", (bid,))
    return FileResponse(tmp.name, media_type="application/x-tar", filename=f"{folder.name}.tar")
