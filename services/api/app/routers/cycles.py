"""Weekly pricing cycles, provisional/final rate, tasks and scheduling — manager only."""
from __future__ import annotations

import uuid
from datetime import date

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.util import Rate, Text, ok, page

router = APIRouter(prefix="/api/v1", tags=["cycles"])


class CycleIn(BaseModel):
    label: Text
    starts_on: date
    ends_on: date


class RateIn(BaseModel):
    effective_on: date
    rate_ils_per_kwh: Rate
    reason: str | None = Field(None, max_length=500)


class FinalizeIn(BaseModel):
    final_rate_ils_per_kwh: Rate
    confirm: bool = Field(description="must be true: closing is irreversible")


class TaskIn(BaseModel):
    cycle_id: uuid.UUID
    subscriber_id: uuid.UUID
    planned_for: date
    employee_id: uuid.UUID | None = None


class AssignIn(BaseModel):
    employee_id: uuid.UUID | None


class BulkAssignIn(BaseModel):
    task_ids: list[uuid.UUID] = Field(min_length=1, max_length=1000)
    employee_id: uuid.UUID | None


class CancelIn(BaseModel):
    reason: Text


class MoveIn(BaseModel):
    cycle_id: uuid.UUID
    planned_for: date


CYCLE_SQL = """SELECT c.id, c.label, c.starts_on, c.ends_on, c.state, c.opened_at, c.closed_at,
 cp.provisional_rate_ils_per_kwh, cp.final_rate_ils_per_kwh, cp.finalized_at,
 (SELECT count(*) FROM gms.reading_tasks t WHERE t.cycle_id=c.id) AS tasks_total,
 (SELECT count(*) FROM gms.reading_tasks t WHERE t.cycle_id=c.id AND t.status IN ('assigned','in_progress','pending_review')) AS tasks_open,
 (SELECT count(*) FROM gms.approved_readings a WHERE a.cycle_id=c.id AND a.state='active') AS approved_readings,
 (SELECT count(*) FROM gms.statement_versions s WHERE s.cycle_id=c.id AND s.state='final') AS statements,
 (SELECT COALESCE(sum(s.charge_exact_ils),0) FROM gms.statement_versions s WHERE s.cycle_id=c.id AND s.state='final') AS charged_ils
 FROM gms.reading_cycles c LEFT JOIN gms.cycle_price_decisions cp ON cp.cycle_id=c.id"""


@router.get("/cycles")
def list_cycles(db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, CYCLE_SQL + " ORDER BY c.starts_on DESC"))


@router.get("/cycles/{cid}")
def get_cycle(cid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    row = db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,))
    if not row:
        raise AppError(404, "cycle_not_found", "الدورة غير موجودة")
    row["rate_history"] = db.all(m.id, """SELECT e.effective_on, e.proposed_rate_ils_per_kwh, e.reason, e.recorded_at, u.full_name AS recorded_by
        FROM gms.tariff_change_events e JOIN gms.app_users u ON u.id=e.recorded_by WHERE e.cycle_id=%s ORDER BY e.recorded_at""", (cid,))
    if row["state"] != "closed":
        row["blockers"] = db.scalar(m.id, "SELECT gms.cycle_blockers(%s)", (cid,))
    return ok(row)


@router.post("/cycles", status_code=201)
def create_cycle(body: CycleIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    cid = db.scalar(m.id, "SELECT gms.create_cycle(%s,%s,%s)", (body.label, body.starts_on, body.ends_on))
    return ok(db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,)), 201)


@router.put("/cycles/{cid}")
def update_cycle(cid: uuid.UUID, body: CycleIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.update_cycle(%s,%s,%s,%s)", (cid, body.label, body.starts_on, body.ends_on))
    return ok(db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,)))


@router.post("/cycles/{cid}/open")
def open_cycle(cid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.open_cycle(%s)", (cid,))
    return ok(db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,)))


@router.post("/cycles/{cid}/provisional-rate")
def provisional_rate(cid: uuid.UUID, body: RateIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.set_provisional_rate(%s,%s,%s,%s)", (cid, body.effective_on, body.rate_ils_per_kwh, body.reason))
    return ok(db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,)))


@router.get("/cycles/{cid}/estimate")
def estimate(cid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    """Provisional view (BR-18): clearly marked non-final, never posted."""
    c = db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,))
    if not c:
        raise AppError(404, "cycle_not_found", "الدورة غير موجودة")
    final = c["state"] == "closed"
    rate = c["final_rate_ils_per_kwh"] if final else c["provisional_rate_ils_per_kwh"]
    lines = db.all(m.id, """SELECT a.subscriber_id, s.subscription_no, s.full_name, z.name AS zone_name, g.name AS generator_name,
        a.id AS reading_id, a.previous_value_kwh, a.current_value_kwh, a.consumption_kwh, a.verified_captured_at,
        CASE WHEN %(rate)s::numeric IS NULL THEN NULL ELSE round(a.consumption_kwh * %(rate)s::numeric, 8) END AS cost_ils
        FROM gms.approved_readings a JOIN gms.subscribers s ON s.id=a.subscriber_id JOIN gms.zones z ON z.id=s.zone_id
        JOIN gms.generators g ON g.id=s.generator_id
        WHERE a.cycle_id=%(c)s AND (a.state='active' OR (%(final)s AND EXISTS (SELECT 1 FROM gms.final_reading_allocations f WHERE f.approved_reading_id=a.id)))
        ORDER BY s.subscription_no, a.verified_captured_at""", {"rate": rate, "c": cid, "final": final})
    return ok({"cycle": c, "is_final": final, "rate_ils_per_kwh": rate,
               "note": "أرقام نهائية" if final else "تقديرية — غير نهائية حتى تثبيت السعر النهائي وإغلاق الدورة", "lines": lines})


@router.post("/cycles/{cid}/finalize")
def finalize(cid: uuid.UUID, body: FinalizeIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    if not body.confirm:
        raise AppError(422, "confirmation_required", "إغلاق الدورة نهائي؛ يلزم التأكيد الصريح")
    n = db.scalar(m.id, "SELECT gms.finalize_cycle(%s,%s)", (cid, body.final_rate_ils_per_kwh))
    return ok({"statements": n, "cycle": db.one(m.id, CYCLE_SQL + " WHERE c.id=%s", (cid,))})


@router.post("/cycles/{cid}/generate-tasks")
def generate_tasks(cid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok({"created": db.scalar(m.id, "SELECT gms.generate_due_tasks(%s)", (cid,))})


# --- tasks ---------------------------------------------------------------------------------
TASK_SQL = """SELECT t.id, t.cycle_id, c.label AS cycle_label, t.subscriber_id, s.subscription_no, s.full_name AS subscriber_name,
 t.zone_id, z.name AS zone_name, t.assigned_employee_id, u.full_name AS employee_name, t.planned_for, t.source, t.status,
 t.parent_task_id, t.cancel_reason, t.created_at, t.updated_at, count(*) OVER() AS total
 FROM gms.reading_tasks t JOIN gms.reading_cycles c ON c.id=t.cycle_id JOIN gms.subscribers s ON s.id=t.subscriber_id
 JOIN gms.zones z ON z.id=t.zone_id LEFT JOIN gms.app_users u ON u.id=t.assigned_employee_id"""


@router.get("/tasks")
def list_tasks(cycle_id: uuid.UUID | None = None, status: str | None = None, employee_id: uuid.UUID | None = None,
               zone_id: uuid.UUID | None = None, unassigned: bool = False, planned_for: date | None = None,
               limit: int = 200, offset: int = 0, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    limit, offset = page(limit, offset)
    rows = db.all(m.id, TASK_SQL + """ WHERE (%(c)s::uuid IS NULL OR t.cycle_id=%(c)s) AND (%(st)s::text IS NULL OR t.status=%(st)s)
        AND (%(e)s::uuid IS NULL OR t.assigned_employee_id=%(e)s) AND (%(z)s::uuid IS NULL OR t.zone_id=%(z)s)
        AND (NOT %(un)s OR t.assigned_employee_id IS NULL) AND (%(d)s::date IS NULL OR t.planned_for=%(d)s)
        ORDER BY t.planned_for, z.name, s.subscription_no LIMIT %(l)s OFFSET %(o)s""",
                  {"c": cycle_id, "st": status, "e": employee_id, "z": zone_id, "un": unassigned, "d": planned_for, "l": limit, "o": offset})
    total = rows[0]["total"] if rows else 0
    for r in rows:
        r.pop("total")
    return ok({"items": rows, "total": total})


@router.post("/tasks", status_code=201)
def create_task(body: TaskIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    tid = db.scalar(m.id, "SELECT gms.create_task(%s,%s,%s,'manager_extra',%s,NULL)",
                    (body.cycle_id, body.subscriber_id, body.planned_for, body.employee_id))
    return ok(db.one(m.id, TASK_SQL + " WHERE t.id=%s", (tid,)), 201)


@router.post("/tasks/{tid}/assign")
def assign(tid: uuid.UUID, body: AssignIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.assign_task(%s,%s)", (tid, body.employee_id))
    return ok(db.one(m.id, TASK_SQL + " WHERE t.id=%s", (tid,)))


@router.post("/tasks/assign-bulk")
def assign_bulk(body: BulkAssignIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    with db.tx(m.id) as c:   # all or nothing
        for tid in body.task_ids:
            c.execute("SELECT gms.assign_task(%s,%s)", (tid, body.employee_id))
    return ok({"assigned": len(body.task_ids)})


@router.post("/tasks/{tid}/cancel")
def cancel(tid: uuid.UUID, body: CancelIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.cancel_task(%s,%s)", (tid, body.reason))
    return ok(db.one(m.id, TASK_SQL + " WHERE t.id=%s", (tid,)))


@router.post("/tasks/{tid}/move")
def move(tid: uuid.UUID, body: MoveIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.move_task(%s,%s,%s)", (tid, body.cycle_id, body.planned_for))
    return ok(db.one(m.id, TASK_SQL + " WHERE t.id=%s", (tid,)))
