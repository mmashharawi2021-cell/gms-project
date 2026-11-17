"""Manager review of field visits, photos, corrections and reports (BR-09..16, BR-24/25, BR-30)."""
from __future__ import annotations

import uuid
from datetime import date, datetime

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from app import photo_links
from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.util import Kwh, Text, ok, page

router = APIRouter(prefix="/api/v1", tags=["review"])


class ApproveIn(BaseModel):
    corrected_value_kwh: Kwh | None = None
    rationale: str | None = Field(None, max_length=1000)
    acknowledge_exceptions: bool = False
    accept_late: bool = False
    photo_reviewed: bool = Field(description="the manager confirms the photo was inspected")


class BulkApproveIn(BaseModel):
    visit_ids: list[uuid.UUID] = Field(min_length=1, max_length=500)
    photos_reviewed: bool


class RejectIn(BaseModel):
    decision: str = Field(pattern="^(reject|duplicate)$")
    rationale: Text


class RevisitIn(BaseModel):
    planned_for: date
    employee_id: uuid.UUID | None = None
    rationale: Text


class TimeIn(BaseModel):
    verified_captured_at: datetime
    reason: str | None = Field(None, max_length=1000)


class UnreadableIn(BaseModel):
    followup_due: date
    rationale: str | None = Field(None, max_length=1000)


class NoteIn(BaseModel):
    note: Text


class CorrectIn(BaseModel):
    new_value_kwh: Kwh
    rationale: Text
    idempotency_key: uuid.UUID


VISIT_SQL = """SELECT v.id, v.event_kind, v.reading_value_kwh, v.reason, v.note, v.captured_at_device, v.verified_captured_at,
 v.received_at, v.timestamp_status, v.record_status, v.flags, v.task_id, v.payload_task_id, t.status AS task_status,
 t.cycle_id AS task_cycle_id, v.subscriber_id, s.subscription_no, s.full_name AS subscriber_name, v.zone_id, z.name AS zone_name,
 g.name AS generator_name, v.employee_id, u.full_name AS employee_name, v.installation_id, m.serial_no AS meter_serial,
 head.value AS previous_value_kwh, head.at AS previous_at,
 (SELECT count(*) FROM gms.visit_photos p WHERE p.visit_id=v.id AND p.state='ready') AS ready_photos,
 (SELECT c.id FROM gms.reading_cycles c WHERE gms.local_date(COALESCE(v.verified_captured_at, v.captured_at_device)) BETWEEN c.starts_on AND c.ends_on) AS capture_cycle_id,
 count(*) OVER() AS total
 FROM gms.field_visits v
 JOIN gms.subscribers s ON s.id=v.subscriber_id JOIN gms.zones z ON z.id=v.zone_id JOIN gms.generators g ON g.id=s.generator_id
 JOIN gms.app_users u ON u.id=v.employee_id
 JOIN gms.meter_installations i ON i.id=v.installation_id JOIN gms.meters m ON m.id=i.meter_id
 LEFT JOIN gms.reading_tasks t ON t.id=v.task_id
 LEFT JOIN LATERAL (
   SELECT a.current_value_kwh AS value, a.verified_captured_at AS at FROM gms.approved_readings a
    WHERE a.installation_id=v.installation_id AND a.state='active' AND a.visit_id<>v.id
      AND a.verified_captured_at < COALESCE(v.verified_captured_at, v.captured_at_device)
    ORDER BY a.verified_captured_at DESC LIMIT 1
 ) h ON true
 LEFT JOIN gms.opening_baselines b ON b.installation_id=v.installation_id
 CROSS JOIN LATERAL (SELECT COALESCE(h.value, b.opening_value_kwh) AS value, COALESCE(h.at, b.entered_at) AS at) head"""

OPEN_STATES = ("awaiting_photo", "pending_review", "exception")


@router.get("/visits")
def list_visits(status: str | None = None, open_only: bool = False, kind: str | None = None, employee_id: uuid.UUID | None = None,
                zone_id: uuid.UUID | None = None, subscriber_id: uuid.UUID | None = None, cycle_id: uuid.UUID | None = None,
                flagged: bool | None = None, limit: int = 100, offset: int = 0,
                db: Database = Depends(get_db), m: Principal = Depends(manager)):
    limit, offset = page(limit, offset)
    rows = db.all(m.id, f"""SELECT * FROM ({VISIT_SQL}
        WHERE (%(st)s::text IS NULL OR v.record_status=%(st)s) AND (NOT %(open)s OR v.record_status IN {OPEN_STATES})
          AND (%(k)s::text IS NULL OR v.event_kind=%(k)s) AND (%(e)s::uuid IS NULL OR v.employee_id=%(e)s)
          AND (%(z)s::uuid IS NULL OR v.zone_id=%(z)s) AND (%(s)s::uuid IS NULL OR v.subscriber_id=%(s)s)
          AND (%(f)s::boolean IS NULL OR (cardinality(v.flags) > 0 OR v.timestamp_status='suspicious') = %(f)s)
        ORDER BY v.captured_at_device) x
        WHERE (%(c)s::uuid IS NULL OR x.capture_cycle_id=%(c)s OR x.task_cycle_id=%(c)s)
        LIMIT %(l)s OFFSET %(o)s""",
                  {"st": status, "open": open_only, "k": kind, "e": employee_id, "z": zone_id, "s": subscriber_id,
                   "f": flagged, "c": cycle_id, "l": limit, "o": offset})
    total = rows[0]["total"] if rows else 0
    for r in rows:
        r.pop("total")
    return ok({"items": rows, "total": total})


@router.get("/visits/{vid}")
def get_visit(vid: uuid.UUID, request: Request, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    v = db.one(m.id, VISIT_SQL + " WHERE v.id=%s", (vid,))
    if not v:
        raise AppError(404, "visit_not_found", "الزيارة غير موجودة")
    v.pop("total")
    secret = request.app.state.settings.jwt_secret
    photos = db.all(m.id, """SELECT id, is_primary, state, content_type, size_bytes, sha256_hex, created_at, ready_at, failure_reason
                             FROM gms.visit_photos WHERE visit_id=%s ORDER BY is_primary DESC, created_at""", (vid,))
    for p in photos:
        p["url"] = photo_links.sign(secret, p["id"]) if p["state"] == "ready" else None
    v["photos"] = photos
    v["reviews"] = db.all(m.id, """SELECT r.decision, r.corrected_value_kwh, r.corrected_capture_at, r.rationale, r.reviewed_at,
        u.full_name AS reviewer FROM gms.visit_reviews r JOIN gms.app_users u ON u.id=r.reviewed_by WHERE r.visit_id=%s ORDER BY r.reviewed_at""", (vid,))
    v["error_reports"] = db.all(m.id, """SELECT id, explanation, submitted_at, acknowledged_at, resolution_note
        FROM gms.visit_error_reports WHERE visit_id=%s ORDER BY submitted_at""", (vid,))
    v["incident"] = db.one(m.id, "SELECT category, notes, resolved_at, resolution_note FROM gms.meter_incident_reports WHERE visit_id=%s", (vid,))
    v["approved_reading"] = db.one(m.id, """SELECT id, previous_value_kwh, current_value_kwh, consumption_kwh, cycle_id, state
        FROM gms.approved_readings WHERE visit_id=%s AND state='active'""", (vid,))
    v["provisional"] = None
    if v["event_kind"] == "reading" and v["capture_cycle_id"] and v["previous_value_kwh"] is not None:
        rate = db.scalar(m.id, "SELECT provisional_rate_ils_per_kwh FROM gms.cycle_price_decisions WHERE cycle_id=%s", (v["capture_cycle_id"],))
        kwh = v["reading_value_kwh"] - v["previous_value_kwh"]
        v["provisional"] = {"consumption_kwh": kwh, "rate_ils_per_kwh": rate,
                            "cost_ils": (kwh * rate) if rate is not None and kwh >= 0 else None, "label": "تقديري — غير نهائي"}
    return ok(v)


@router.get("/photos/{pid}/content")
def photo_content(pid: uuid.UUID, exp: int, sig: str, request: Request, db: Database = Depends(get_db)):
    if not photo_links.verify(request.app.state.settings.jwt_secret, pid, exp, sig):
        raise AppError(403, "invalid_link", "رابط الصورة منتهي أو غير صالح")
    p = db.one(None, "SELECT object_key, content_type, sha256_hex FROM gms.visit_photos WHERE id=%s AND state='ready'", (pid,))
    data = request.app.state.storage.get(p["object_key"]) if p else None
    if data is None:
        raise AppError(404, "photo_missing", "ملف الصورة غير موجود في التخزين")
    return Response(data, media_type=p["content_type"], headers={"Cache-Control": "private, max-age=600", "ETag": p["sha256_hex"],
                                                                  "X-Content-Type-Options": "nosniff"})


@router.post("/visits/{vid}/approve")
def approve(vid: uuid.UUID, body: ApproveIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    if not body.photo_reviewed:
        raise AppError(422, "photo_review_required", "يجب مراجعة صورة العداد قبل الاعتماد")
    rid = db.scalar(m.id, "SELECT gms.approve_visit(%s,%s,%s,%s,%s)",
                    (vid, body.corrected_value_kwh, body.rationale, body.acknowledge_exceptions, body.accept_late))
    return ok({"approved_reading_id": rid})


@router.post("/visits/approve-bulk")
def approve_bulk(body: BulkApproveIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    """BR-30: each visit is approved in its OWN transaction with its own review record. Visits with
    exceptions are never approved in bulk (they need an individual, documented decision)."""
    if not body.photos_reviewed:
        raise AppError(422, "photo_review_required", "يجب مراجعة صور جميع البنود قبل الاعتماد الجماعي")
    order = db.all(m.id, "SELECT id FROM gms.field_visits WHERE id = ANY(%s) ORDER BY COALESCE(verified_captured_at, captured_at_device)",
                   (list(body.visit_ids),))
    results = []
    for row in order:
        try:
            rid = db.scalar(m.id, "SELECT gms.approve_visit(%s,NULL,NULL,false,false)", (row["id"],))
            results.append({"visit_id": row["id"], "result": "approved", "approved_reading_id": rid})
        except AppError as e:
            results.append({"visit_id": row["id"], "result": "skipped", "code": e.code, "message": e.message})
    found = {r["id"] for r in order}
    results += [{"visit_id": v, "result": "skipped", "code": "visit_not_found", "message": "الزيارة غير موجودة"}
                for v in body.visit_ids if v not in found]
    return ok({"approved": sum(r["result"] == "approved" for r in results), "results": results})


@router.post("/visits/{vid}/reject")
def reject(vid: uuid.UUID, body: RejectIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.reject_visit(%s,%s,%s)", (vid, body.decision, body.rationale))
    return ok()


@router.post("/visits/{vid}/revisit")
def revisit(vid: uuid.UUID, body: RevisitIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok({"task_id": db.scalar(m.id, "SELECT gms.request_revisit(%s,%s,%s,%s)", (vid, body.planned_for, body.employee_id, body.rationale))})


@router.post("/visits/{vid}/verify-time")
def verify_time(vid: uuid.UUID, body: TimeIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.verify_capture_time(%s,%s,%s)", (vid, body.verified_captured_at, body.reason))
    return ok()


@router.post("/visits/{vid}/resolve-unreadable")
def resolve_unreadable(vid: uuid.UUID, body: UnreadableIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.resolve_unreadable(%s,%s,%s)", (vid, body.followup_due, body.rationale))
    return ok()


@router.post("/visits/{vid}/resolve-incident")
def resolve_incident(vid: uuid.UUID, body: NoteIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.resolve_incident(%s,%s)", (vid, body.note))
    return ok()


@router.post("/error-reports/{rid}/acknowledge")
def acknowledge(rid: uuid.UUID, body: NoteIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.acknowledge_error_report(%s,%s)", (rid, body.note))
    return ok()


@router.get("/error-reports")
def error_reports(open_only: bool = True, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, """SELECT e.id, e.visit_id, e.explanation, e.submitted_at, e.acknowledged_at, e.resolution_note,
        u.full_name AS employee_name, s.full_name AS subscriber_name, s.subscription_no
        FROM gms.visit_error_reports e JOIN gms.app_users u ON u.id=e.employee_id JOIN gms.field_visits v ON v.id=e.visit_id
        JOIN gms.subscribers s ON s.id=v.subscriber_id WHERE (NOT %s OR e.acknowledged_at IS NULL) ORDER BY e.submitted_at DESC""", (open_only,)))


@router.post("/readings/{rid}/correct")
def correct(rid: uuid.UUID, body: CorrectIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    new_id = db.scalar(m.id, "SELECT gms.correct_approved_reading(%s,%s,%s,%s)", (rid, body.new_value_kwh, body.rationale, body.idempotency_key))
    adjustments = db.all(m.id, """SELECT f.id, f.adjustment_ils, f.source_cycle_id, f.description FROM gms.financial_adjustments f
        JOIN gms.reading_corrections c ON c.id=f.correction_id WHERE c.idempotency_key=%s""", (body.idempotency_key,))
    return ok({"new_reading_id": new_id, "adjustments": adjustments})
