"""Phase B — payments, reversals, adjustments, opening balances, ledger, statements (manager only)."""
from __future__ import annotations

import uuid
from datetime import date, datetime
from typing import Literal

from fastapi import APIRouter, Depends
from fastapi.responses import Response
from pydantic import BaseModel, Field

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.reports import load_identity, render_receipt_pdf
from app.util import Money, PositiveMoney, Text, ok, page

router = APIRouter(prefix="/api/v1", tags=["finance"])


class PaymentIn(BaseModel):
    subscriber_id: uuid.UUID
    amount_ils: PositiveMoney
    paid_at: datetime
    method: Literal["cash", "bank_transfer", "other"]
    reference: str | None = Field(None, max_length=200)
    idempotency_key: uuid.UUID


class ReverseIn(BaseModel):
    reason: Text


class AdjustmentIn(BaseModel):
    subscriber_id: uuid.UUID
    amount_ils: Money
    reason: Text
    source_cycle_id: uuid.UUID | None = None
    idempotency_key: uuid.UUID


class OpeningIn(BaseModel):
    subscriber_id: uuid.UUID
    amount_ils: Money
    as_of: date
    justification: Text


PAYMENT_SQL = """SELECT p.id, p.receipt_no, p.subscriber_id, s.subscription_no, s.full_name AS subscriber_name, s.phone AS subscriber_phone, p.amount_ils, p.paid_at,
 p.payment_method, p.reference_text, p.created_at, u.full_name AS received_by_name,
 r.id AS reversal_id, r.reversed_at, r.reason AS reversal_reason, count(*) OVER() AS total
 FROM gms.payment_receipts p JOIN gms.subscribers s ON s.id=p.subscriber_id JOIN gms.app_users u ON u.id=p.received_by
 LEFT JOIN gms.payment_reversals r ON r.payment_id=p.id"""


def _strip_total(rows):
    total = rows[0]["total"] if rows else 0
    for r in rows:
        r.pop("total")
    return {"items": rows, "total": total}


@router.post("/payments", status_code=201)
def record_payment(body: PaymentIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    pid = db.scalar(m.id, "SELECT gms.record_payment(%s,%s,%s,%s,%s,%s)",
                    (body.subscriber_id, body.amount_ils, body.paid_at, body.method, body.reference, body.idempotency_key))
    pay = db.one(m.id, PAYMENT_SQL + " WHERE p.id=%s", (pid,))
    pay.pop("total")
    return ok({"payment": pay, "account": db.one(m.id, "SELECT * FROM gms.v_subscriber_account WHERE subscriber_id=%s", (body.subscriber_id,))}, 201)


@router.post("/payments/{pid}/reverse")
def reverse(pid: uuid.UUID, body: ReverseIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    db.scalar(m.id, "SELECT gms.reverse_payment(%s,%s)", (pid, body.reason))
    pay = db.one(m.id, PAYMENT_SQL + " WHERE p.id=%s", (pid,))
    pay.pop("total")
    return ok(pay)


@router.get("/payments")
def list_payments(subscriber_id: uuid.UUID | None = None, date_from: date | None = None, date_to: date | None = None,
                  limit: int = 100, offset: int = 0, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    limit, offset = page(limit, offset)
    return ok(_strip_total(db.all(m.id, PAYMENT_SQL + """ WHERE (%(s)s::uuid IS NULL OR p.subscriber_id=%(s)s)
        AND (%(f)s::date IS NULL OR gms.local_date(p.paid_at) >= %(f)s) AND (%(t)s::date IS NULL OR gms.local_date(p.paid_at) <= %(t)s)
        ORDER BY p.paid_at DESC, p.created_at DESC LIMIT %(l)s OFFSET %(o)s""",
                                  {"s": subscriber_id, "f": date_from, "t": date_to, "l": limit, "o": offset})))


@router.post("/adjustments", status_code=201)
def adjustment(body: AdjustmentIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    aid = db.scalar(m.id, "SELECT gms.record_adjustment(%s,%s,%s,%s,%s)",
                    (body.subscriber_id, body.amount_ils, body.reason, body.idempotency_key, body.source_cycle_id))
    return ok({"id": aid, "account": db.one(m.id, "SELECT * FROM gms.v_subscriber_account WHERE subscriber_id=%s", (body.subscriber_id,))}, 201)


@router.get("/adjustments")
def list_adjustments(subscriber_id: uuid.UUID | None = None, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    return ok(db.all(m.id, """SELECT f.id, f.subscriber_id, s.full_name AS subscriber_name, s.subscription_no, f.kind, f.adjustment_ils,
        f.description, f.source_cycle_id, c.label AS source_cycle_label, f.recorded_at, u.full_name AS recorded_by_name
        FROM gms.financial_adjustments f JOIN gms.subscribers s ON s.id=f.subscriber_id JOIN gms.app_users u ON u.id=f.recorded_by
        LEFT JOIN gms.reading_cycles c ON c.id=f.source_cycle_id
        WHERE (%s::uuid IS NULL OR f.subscriber_id=%s) ORDER BY f.recorded_at DESC LIMIT 500""", (subscriber_id, subscriber_id)))


@router.post("/opening-receivables", status_code=201)
def opening(body: OpeningIn, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    oid = db.scalar(m.id, "SELECT gms.record_opening_receivable(%s,%s,%s,%s)", (body.subscriber_id, body.amount_ils, body.as_of, body.justification))
    return ok({"id": oid}, 201)


@router.get("/subscribers/{sid}/ledger")
def ledger(sid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    entries = db.all(m.id, """SELECT l.seq, l.posted_at, l.source_type, l.source_id, l.signed_amount_ils,
        sum(l.signed_amount_ils) OVER (ORDER BY l.seq) AS running_balance_ils,
        CASE l.source_type
          WHEN 'final_statement' THEN (SELECT 'كشف ' || sv.statement_no || ' — ' || c.label FROM gms.statement_versions sv JOIN gms.reading_cycles c ON c.id=sv.cycle_id WHERE sv.id=l.source_id)
          WHEN 'payment' THEN (SELECT 'دفعة ' || p.receipt_no FROM gms.payment_receipts p WHERE p.id=l.source_id)
          WHEN 'payment_reversal' THEN (SELECT 'إلغاء دفعة ' || p.receipt_no || ': ' || r.reason FROM gms.payment_reversals r JOIN gms.payment_receipts p ON p.id=r.payment_id WHERE r.id=l.source_id)
          WHEN 'adjustment' THEN (SELECT 'تسوية: ' || f.description FROM gms.financial_adjustments f WHERE f.id=l.source_id)
          WHEN 'opening_receivable' THEN (SELECT 'رصيد افتتاحي: ' || o.justification FROM gms.opening_receivables o WHERE o.id=l.source_id)
        END AS description
        FROM gms.ledger_entries l WHERE l.subscriber_id=%s ORDER BY l.seq""", (sid,))
    return ok({"account": db.one(m.id, "SELECT * FROM gms.v_subscriber_account WHERE subscriber_id=%s", (sid,)), "entries": entries})


STATEMENT_SQL = """SELECT sv.id, sv.statement_no, sv.subscriber_id, s.subscription_no, s.full_name AS subscriber_name, s.phone AS subscriber_phone,
 g.name AS generator_name, z.name AS zone_name, sv.cycle_id, c.label AS cycle_label, c.starts_on, c.ends_on,
 sv.rate_snapshot_ils_per_kwh, sv.consumption_kwh, sv.charge_exact_ils, sv.opening_ledger_balance_ils,
 sv.closing_ledger_balance_ils, sv.carry_in_ils, sv.credits_in_ils, sv.requested_whole_ils, sv.carry_out_ils, sv.credits_out_ils,
 sv.finalized_at, count(*) OVER() AS total
 FROM gms.statement_versions sv JOIN gms.subscribers s ON s.id=sv.subscriber_id JOIN gms.reading_cycles c ON c.id=sv.cycle_id
 JOIN gms.generators g ON g.id=s.generator_id JOIN gms.zones z ON z.id=s.zone_id"""


@router.get("/statements")
def list_statements(cycle_id: uuid.UUID | None = None, subscriber_id: uuid.UUID | None = None, generator_id: uuid.UUID | None = None,
                    limit: int = 200, offset: int = 0, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    limit, offset = page(limit, offset)
    return ok(_strip_total(db.all(m.id, STATEMENT_SQL + """ WHERE sv.state='final' AND (%(c)s::uuid IS NULL OR sv.cycle_id=%(c)s)
        AND (%(s)s::uuid IS NULL OR sv.subscriber_id=%(s)s) AND (%(g)s::uuid IS NULL OR s.generator_id=%(g)s)
        ORDER BY c.starts_on DESC, s.subscription_no LIMIT %(l)s OFFSET %(o)s""",
                                  {"c": cycle_id, "s": subscriber_id, "g": generator_id, "l": limit, "o": offset})))


@router.get("/statements/{sid}")
def get_statement(sid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    st = db.one(m.id, STATEMENT_SQL + " WHERE sv.id=%s", (sid,))
    if not st:
        raise AppError(404, "statement_not_found", "الكشف غير موجود")
    st.pop("total")
    st["lines"] = db.all(m.id, """SELECT l.approved_reading_id, a.verified_captured_at, l.previous_value_kwh, l.current_value_kwh,
        l.consumption_kwh, l.rate_snapshot, l.exact_charge_ils FROM gms.statement_reading_lines l
        JOIN gms.approved_readings a ON a.id=l.approved_reading_id WHERE l.statement_id=%s ORDER BY a.verified_captured_at""", (sid,))
    return ok(st)


@router.get("/payments/{pid}/receipt")
def receipt(pid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    pay = db.one(m.id, PAYMENT_SQL + " WHERE p.id=%s", (pid,))
    if not pay:
        raise AppError(404, "payment_not_found", "الدفعة غير موجودة")
    account = db.one(m.id, "SELECT * FROM gms.v_subscriber_account WHERE subscriber_id=%s", (pay["subscriber_id"],))
    pdf = render_receipt_pdf(pay, account, load_identity(db, m.id), db.scalar(m.id, "SELECT gms.business_tz()"))
    db.scalar(m.id, "SELECT gms.audit('PRINT_RECEIPT','payment_receipts',%s,'{}'::jsonb)", (pid,))
    return Response(pdf, media_type="application/pdf", headers={"Content-Disposition": f"attachment; filename={pay['receipt_no']}.pdf"})
