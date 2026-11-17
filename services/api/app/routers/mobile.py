"""Field app API (employee + enrolled active phone only). The phone never talks to PostgreSQL."""
from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field, ValidationError

from app.db import Database
from app.deps import Principal, employee, get_db
from app.errors import AppError
from app.storage import sniff_image
from app.util import ok

router = APIRouter(prefix="/api/v1/mobile", tags=["mobile"])

PAYLOAD_KEYS = ("subscriber_id", "installation_id", "zone_id", "task_id", "event_kind", "reading_value_kwh", "reason", "note",
                "captured_at_device", "captured_offset_minutes", "incident_category")


class VisitPayload(BaseModel):
    subscriber_id: uuid.UUID
    installation_id: uuid.UUID
    zone_id: uuid.UUID
    task_id: uuid.UUID | None = None
    event_kind: Literal["reading", "unreadable", "meter_incident"]
    reading_value_kwh: str | None = Field(None, max_length=32, pattern=r"^\d{1,14}(\.\d+)?$")
    reason: str | None = Field(None, max_length=1000)
    note: str | None = Field(None, max_length=2000)
    captured_at_device: datetime
    captured_offset_minutes: int | None = Field(None, ge=-900, le=900)
    incident_category: Literal["reset", "replacement", "fault", "other"] | None = None


class SyncOp(BaseModel):
    kind: Literal["visit", "error_report"]
    operation_id: uuid.UUID
    visit_id: uuid.UUID
    payload: dict | None = None               # visit
    capture_boot_id: str | None = Field(None, max_length=64)
    capture_elapsed_ms: int | None = Field(None, ge=0)
    report_id: uuid.UUID | None = None         # error report
    explanation: str | None = Field(None, max_length=2000)


class SyncIn(BaseModel):
    device_now: datetime
    boot_id: str | None = Field(None, max_length=64)
    elapsed_ms: int | None = Field(None, ge=0)
    operations: list[SyncOp] = Field(max_length=200)


class StatusIn(BaseModel):
    visit_ids: list[uuid.UUID] = Field(max_length=1000)


def canonical(payload: dict) -> tuple[dict, str]:
    """Only known content fields, in a stable form. Retries with the same content -> same fingerprint;
    clock evidence (which changes on every retry) is deliberately not part of it."""
    clean = {k: payload[k] for k in PAYLOAD_KEYS if payload.get(k) not in (None, "")}
    text = json.dumps(clean, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return clean, hashlib.sha256(text.encode()).hexdigest()


def judge_time(body: SyncIn, op: SyncOp, captured: datetime, tolerance: timedelta) -> tuple[str, datetime | None]:
    """BR-24: device time is evidence. Same boot -> monotonic elapsed time gives a server-side estimate of the
    capture instant; otherwise only a currently-correct clock is accepted as consistent."""
    server_now = datetime.now(timezone.utc)
    skew = abs(body.device_now - server_now)
    if captured.tzinfo is None:
        return "suspicious", None
    if (op.capture_boot_id and body.boot_id and op.capture_boot_id == body.boot_id
            and op.capture_elapsed_ms is not None and body.elapsed_ms is not None and body.elapsed_ms >= op.capture_elapsed_ms):
        estimated = server_now - timedelta(milliseconds=body.elapsed_ms - op.capture_elapsed_ms)
        return ("consistent" if abs(estimated - captured) <= tolerance else "suspicious"), estimated
    return ("consistent" if skew <= tolerance and captured <= server_now + tolerance else "suspicious"), None


@router.get("/bootstrap")
def bootstrap(db: Database = Depends(get_db), p: Principal = Depends(employee)):
    """Everything the phone needs for a full offline day — ONLY the employee's zones and tasks (no money)."""
    with db.tx(p.id) as c:
        c.execute("SELECT gms.touch_device(%s)", (p.device_id,))
        zones = c.execute("""SELECT z.id, z.name, g.name AS generator_name FROM gms.user_zone_grants gr JOIN gms.zones z ON z.id=gr.zone_id
            JOIN gms.generators g ON g.id=z.generator_id WHERE gr.employee_id=%s AND gr.valid_from<=now()
            AND (gr.valid_until IS NULL OR gr.valid_until>now()) ORDER BY z.name""", (p.id,)).fetchall()
        zone_ids = [z["id"] for z in zones]
        tasks = c.execute("""SELECT t.id, t.cycle_id, t.subscriber_id, t.installation_id, t.zone_id, t.planned_for, t.source, t.status
            FROM gms.reading_tasks t JOIN gms.reading_cycles cy ON cy.id=t.cycle_id
            WHERE t.assigned_employee_id=%s AND t.status IN ('assigned','in_progress') AND cy.state<>'closed'
            ORDER BY t.planned_for""", (p.id,)).fetchall()
        task_subs = list({t["subscriber_id"] for t in tasks})
        subs = c.execute("""SELECT s.id, s.subscription_no, s.full_name, s.address, s.phone, s.zone_id, z.name AS zone_name,
            i.id AS installation_id, m.serial_no AS meter_serial, m.meter_type,
            last.value AS last_approved_value_kwh, last.at AS last_approved_at
            FROM gms.subscribers s JOIN gms.zones z ON z.id=s.zone_id
            JOIN gms.meter_installations i ON i.subscriber_id=s.id AND i.removed_at IS NULL JOIN gms.meters m ON m.id=i.meter_id
            LEFT JOIN gms.opening_baselines b ON b.installation_id=i.id
            LEFT JOIN LATERAL (SELECT a.current_value_kwh AS value, a.verified_captured_at AS at FROM gms.approved_readings a
                WHERE a.installation_id=i.id AND a.state='active' ORDER BY a.verified_captured_at DESC LIMIT 1) l ON true
            CROSS JOIN LATERAL (SELECT COALESCE(l.value, b.opening_value_kwh) AS value, l.at) last
            WHERE s.is_active AND (s.zone_id = ANY(%s) OR s.id = ANY(%s)) ORDER BY z.name, s.subscription_no""",
                         (zone_ids, task_subs)).fetchall()
        tz = c.execute("SELECT gms.business_tz() AS tz").fetchone()["tz"]
    return ok({"server_time": datetime.now(timezone.utc), "business_timezone": tz, "employee": {"id": p.id, "full_name": p.full_name},
               "zones": zones, "tasks": tasks, "subscribers": subs})


@router.post("/sync")
def sync(body: SyncIn, request: Request, db: Database = Depends(get_db), p: Principal = Depends(employee)):
    """Per-item acknowledgements; each item is its own transaction (partial success is normal)."""
    tolerance = timedelta(minutes=int(db.scalar(p.id, "SELECT gms.setting('clock_skew_tolerance_minutes')") or 5))
    results = []
    for op in body.operations:
        try:
            if op.kind == "visit":
                try:
                    parsed = VisitPayload.model_validate(op.payload or {})
                except ValidationError:
                    results.append({"operation_id": op.operation_id, "visit_id": op.visit_id, "result": "rejected", "reason": "malformed_payload"})
                    continue
                clean, sha = canonical(op.payload or {})
                trust, estimated = judge_time(body, op, parsed.captured_at_device, tolerance)
                res = db.scalar(p.id, "SELECT gms.receive_visit(%s,%s,%s,%s::jsonb,%s,%s,%s)",
                                (op.operation_id, op.visit_id, p.device_id, json.dumps(clean, ensure_ascii=False), sha, trust, estimated))
                results.append({"operation_id": op.operation_id, "visit_id": op.visit_id, **res})
            else:
                if not op.report_id or not op.explanation:
                    results.append({"operation_id": op.operation_id, "result": "rejected", "reason": "malformed_payload"})
                    continue
                sha = hashlib.sha256(f"{op.visit_id}|{op.explanation}".encode()).hexdigest()
                res = db.scalar(p.id, "SELECT gms.receive_error_report(%s,%s,%s,%s,%s,%s)",
                                (op.operation_id, op.report_id, p.device_id, op.visit_id, op.explanation, sha))
                results.append({"operation_id": op.operation_id, "report_id": op.report_id, **res})
        except AppError as e:
            if e.status == 403:
                raise   # revoked phone / disabled account: stop the whole batch
            results.append({"operation_id": op.operation_id, "result": "retry_required" if e.status >= 500 else "rejected", "reason": e.code})
    db.scalar(p.id, "SELECT gms.touch_device(%s)", (p.device_id,))
    return ok({"server_time": datetime.now(timezone.utc), "results": results})


@router.put("/photos/{photo_id}")
async def upload_photo(photo_id: uuid.UUID, request: Request, visit_id: uuid.UUID = Query(...), is_primary: bool = Query(...),
                       sha256: str = Query(..., pattern="^[0-9a-fA-F]{64}$"), db: Database = Depends(get_db), p: Principal = Depends(employee)):
    """Idempotent upload. The bytes are hashed, type-sniffed, stored atomically, READ BACK from storage and
    re-hashed before the photo is marked ready (SRS 18.2: a DB row alone proves nothing)."""
    settings = request.app.state.settings
    data = bytearray()
    async for chunk in request.stream():
        data.extend(chunk)
        if len(data) > settings.max_photo_bytes:
            raise AppError(413, "photo_too_large", "حجم الصورة أكبر من المسموح")
    data = bytes(data)
    if not data:
        raise AppError(422, "empty_photo", "ملف الصورة فارغ")
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256.lower():
        raise AppError(422, "checksum_mismatch", "بصمة الصورة لا تطابق المحتوى المستلم؛ أعد الإرسال")
    ctype = sniff_image(data)
    if not ctype:
        raise AppError(415, "not_an_image", "الملف ليس صورة JPEG/PNG/WEBP صالحة")
    begun = db.scalar(p.id, "SELECT gms.begin_photo(%s,%s,%s,%s,%s,%s)", (photo_id, visit_id, digest, len(data), ctype, is_primary))
    if begun["state"] == "ready":
        status = db.scalar(p.id, "SELECT record_status FROM gms.field_visits WHERE id=%s", (visit_id,))
        return ok({"photo_id": photo_id, "state": "ready", "record_status": status})
    storage = request.app.state.storage
    storage.put(begun["object_key"], data, ctype)
    stored = storage.get(begun["object_key"]) or b""
    res = db.scalar(p.id, "SELECT gms.complete_photo(%s,%s,%s)", (photo_id, hashlib.sha256(stored).hexdigest(), len(stored)))
    return ok({"photo_id": photo_id, **res})


@router.post("/status")
def status(body: StatusIn, db: Database = Depends(get_db), p: Principal = Depends(employee)):
    rows = db.all(p.id, """SELECT v.id AS visit_id, v.record_status, v.timestamp_status, v.flags,
        (SELECT count(*) FROM gms.visit_photos ph WHERE ph.visit_id=v.id AND ph.state='ready') AS ready_photos,
        (SELECT r.decision FROM gms.visit_reviews r WHERE r.visit_id=v.id ORDER BY r.reviewed_at DESC LIMIT 1) AS last_decision
        FROM gms.field_visits v WHERE v.employee_id=%s AND v.id = ANY(%s)""", (p.id, list(body.visit_ids)))
    return ok(rows)
