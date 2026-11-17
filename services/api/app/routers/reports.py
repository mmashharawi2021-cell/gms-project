"""FR-29 report endpoints: /api/v1/reports/{kind}?format=json|pdf|xlsx and printable weekly statements."""
from __future__ import annotations

import uuid
from datetime import date

from fastapi import APIRouter, Depends, Query
from fastapi.responses import Response

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.reports import Col, Report, ds, load_identity, render_pdf, render_statements_pdf_parallel, render_xlsx
from app.util import dec_str, ok

router = APIRouter(prefix="/api/v1/reports", tags=["reports"])

KINDS = {
    "consumption": "تقرير الاستهلاك التفصيلي",
    "statements": "تقرير الكشوف الأسبوعية",
    "generators": "تقرير الاستهلاك حسب المولد",
    "employees": "تقرير أداء الموظفين الميدانيين",
    "unread": "تقرير المشتركين غير المقروءين",
    "arrears": "تقرير المستحقات والديون والأرصدة الدائنة",
    "payments": "تقرير المدفوعات",
    "adjustments": "تقرير التسويات والتصحيحات",
}


def _cycle(db, actor, cycle_id):
    if not cycle_id:
        raise AppError(422, "cycle_required", "اختر الدورة")
    c = db.one(actor, """SELECT c.*, cp.final_rate_ils_per_kwh, cp.provisional_rate_ils_per_kwh FROM gms.reading_cycles c
                         LEFT JOIN gms.cycle_price_decisions cp ON cp.cycle_id=c.id WHERE c.id=%s""", (cycle_id,))
    if not c:
        raise AppError(404, "cycle_not_found", "الدورة غير موجودة")
    return c


def _gen_label(db, actor, generator_id):
    if not generator_id:
        return "جميع المولدات"
    name = db.scalar(actor, "SELECT name FROM gms.generators WHERE id=%s", (generator_id,))
    if not name:
        raise AppError(404, "not_found", "المولد غير موجود")
    return name


def build(kind: str, db: Database, actor, cycle_id=None, generator_id=None, zone_id=None, date_from=None, date_to=None) -> Report:
    if kind not in KINDS:
        raise AppError(404, "unknown_report", "نوع تقرير غير معروف")
    gen = _gen_label(db, actor, generator_id)
    p = {"c": cycle_id, "g": generator_id, "z": zone_id, "f": date_from, "t": date_to}
    meta = [("المولد", gen)]
    if kind in ("consumption", "statements", "generators", "unread"):
        c = _cycle(db, actor, cycle_id)
        meta.append(("الدورة", f"{c['label']} ({ds(c['starts_on'])} إلى {ds(c['ends_on'])})"))
        final = c["state"] == "closed"
        rate = c["final_rate_ils_per_kwh"] if final else c["provisional_rate_ils_per_kwh"]
        p["rate"] = rate
        meta.append(("السعر", f"{dec_str(rate)} شيكل لكل كيلوواط ساعة" if rate is not None else "لم يحدد بعد"))
    else:
        if kind != "arrears":
            meta.append(("الفترة", f"{ds(date_from) if date_from else 'البداية'} إلى {ds(date_to) if date_to else 'اليوم'}"))
        final = None
    scope = "AND (%(g)s::uuid IS NULL OR s.generator_id=%(g)s) AND (%(z)s::uuid IS NULL OR s.zone_id=%(z)s)"

    if kind == "consumption":
        rows = db.all(actor, f"""SELECT s.subscription_no, s.full_name, g.name AS generator, z.name AS zone, a.verified_captured_at,
            a.previous_value_kwh, a.current_value_kwh, a.consumption_kwh,
            COALESCE(l.rate_snapshot, %(rate)s::numeric) AS rate,
            COALESCE(l.exact_charge_ils, round(a.consumption_kwh * %(rate)s::numeric, 8)) AS cost
            FROM gms.approved_readings a JOIN gms.subscribers s ON s.id=a.subscriber_id JOIN gms.generators g ON g.id=s.generator_id
            JOIN gms.zones z ON z.id=s.zone_id
            LEFT JOIN gms.final_reading_allocations f ON f.approved_reading_id=a.id
            LEFT JOIN gms.statement_reading_lines l ON l.approved_reading_id=a.id AND l.statement_id=f.statement_id
            WHERE a.cycle_id=%(c)s AND (CASE WHEN f.statement_id IS NOT NULL THEN true ELSE a.state='active' END) {scope}
            ORDER BY g.name, z.name, s.subscription_no, a.verified_captured_at""", p)
        cols = [Col("subscription_no", "رقم الاشتراك"), Col("full_name", "المشترك", width=1.8), Col("zone", "المنطقة"),
                Col("verified_captured_at", "تاريخ القراءة", "datetime", 1.3), Col("previous_value_kwh", "السابقة", "kwh"),
                Col("current_value_kwh", "الحالية", "kwh"), Col("consumption_kwh", "الاستهلاك kWh", "kwh", total=True),
                Col("rate", "السعر", "rate"), Col("cost", "التكلفة ₪", "money", total=True)]
        note = None if final else "تنبيه: الأرقام مبدئية بالسعر المبدئي الحالي، ولا تمثل مطالبة مالية حتى تثبيت السعر النهائي وإغلاق الدورة."
        return Report(KINDS[kind], cols, rows, meta, final, note)

    if kind == "statements":
        if not final:
            raise AppError(409, "cycle_not_closed", "الكشوف النهائية تصدر بعد إغلاق الدورة؛ استخدم تقرير الاستهلاك للأرقام التقديرية")
        rows = db.all(actor, f"""SELECT sv.statement_no, s.subscription_no, s.full_name, z.name AS zone, sv.consumption_kwh, sv.charge_exact_ils,
            sv.opening_ledger_balance_ils, sv.closing_ledger_balance_ils, sv.requested_whole_ils, sv.carry_out_ils, sv.credits_out_ils
            FROM gms.statement_versions sv JOIN gms.subscribers s ON s.id=sv.subscriber_id JOIN gms.zones z ON z.id=s.zone_id
            WHERE sv.cycle_id=%(c)s AND sv.state='final' {scope} ORDER BY z.name, s.subscription_no""", p)
        cols = [Col("statement_no", "رقم الكشف"), Col("subscription_no", "رقم الاشتراك"), Col("full_name", "المشترك", width=1.8),
                Col("consumption_kwh", "الاستهلاك kWh", "kwh", total=True), Col("charge_exact_ils", "تكلفة الأسبوع ₪", "money", total=True),
                Col("opening_ledger_balance_ils", "الرصيد السابق ₪", "money"), Col("closing_ledger_balance_ils", "الرصيد بعد الكشف ₪", "money"),
                Col("requested_whole_ils", "المطلوب ₪", "int", total=True), Col("carry_out_ils", "الكسر المرحّل ₪", "money"),
                Col("credits_out_ils", "رصيد دائن ₪", "money")]
        return Report(KINDS[kind], cols, rows, meta, True, "المبلغ المطلوب هو الجزء الصحيح من الرصيد؛ الكسر يرحّل. إصدار الكشف لا يعني الدفع.")

    if kind == "generators":
        rows = db.all(actor, f"""SELECT g.name AS generator, count(DISTINCT a.subscriber_id) AS subscribers, count(a.id) AS readings,
            COALESCE(sum(a.consumption_kwh),0) AS kwh,
            COALESCE(sum(COALESCE(l.exact_charge_ils, round(a.consumption_kwh * %(rate)s::numeric, 8))),0) AS cost
            FROM gms.approved_readings a JOIN gms.subscribers s ON s.id=a.subscriber_id JOIN gms.generators g ON g.id=s.generator_id
            LEFT JOIN gms.final_reading_allocations f ON f.approved_reading_id=a.id
            LEFT JOIN gms.statement_reading_lines l ON l.approved_reading_id=a.id AND l.statement_id=f.statement_id
            WHERE a.cycle_id=%(c)s AND (CASE WHEN f.statement_id IS NOT NULL THEN true ELSE a.state='active' END) {scope}
            GROUP BY g.name ORDER BY g.name""", p)
        cols = [Col("generator", "المولد", width=1.6), Col("subscribers", "عدد المشتركين", "int", total=True),
                Col("readings", "عدد القراءات", "int", total=True), Col("kwh", "الاستهلاك kWh", "kwh", total=True),
                Col("cost", "التكلفة ₪", "money", total=True)]
        return Report(KINDS[kind], cols, rows, meta, final)

    if kind == "unread":
        rows = db.all(actor, f"""SELECT s.subscription_no, s.full_name, z.name AS zone, t.planned_for, t.status, u.full_name AS employee,
            (SELECT v.reason FROM gms.field_visits v WHERE v.task_id=t.id ORDER BY v.received_at DESC LIMIT 1) AS last_reason
            FROM gms.reading_tasks t JOIN gms.subscribers s ON s.id=t.subscriber_id JOIN gms.zones z ON z.id=s.zone_id
            LEFT JOIN gms.app_users u ON u.id=t.assigned_employee_id
            WHERE t.cycle_id=%(c)s AND t.status <> 'completed_reading' {scope} ORDER BY z.name, t.planned_for, s.subscription_no""", p)
        labels = {"assigned": "مكلّفة", "in_progress": "قيد التنفيذ", "pending_review": "بانتظار المراجعة", "completed_unreadable": "متعذرة/مغلقة",
                  "revisit_required": "إعادة زيارة", "cancelled": "ملغاة"}
        for r in rows:
            r["status"] = labels.get(r["status"], r["status"])
        cols = [Col("subscription_no", "رقم الاشتراك"), Col("full_name", "المشترك", width=1.8), Col("zone", "المنطقة"),
                Col("planned_for", "الموعد", "date"), Col("status", "الحالة"), Col("employee", "الموظف", width=1.3),
                Col("last_reason", "سبب التعذر", width=1.8)]
        return Report(KINDS[kind], cols, rows, meta, None)

    if kind == "employees":
        rows = db.all(actor, """SELECT u.full_name AS employee, count(v.id) AS visits,
            count(*) FILTER (WHERE v.event_kind='reading') AS readings, count(*) FILTER (WHERE v.event_kind='unreadable') AS unreadable,
            count(*) FILTER (WHERE v.event_kind='meter_incident') AS incidents,
            count(*) FILTER (WHERE v.record_status='approved') AS approved, count(*) FILTER (WHERE v.record_status='rejected') AS rejected,
            count(*) FILTER (WHERE v.record_status IN ('awaiting_photo','pending_review','exception')) AS pending,
            count(*) FILTER (WHERE cardinality(v.flags) > 0) AS flagged
            FROM gms.app_users u LEFT JOIN gms.field_visits v ON v.employee_id=u.id
              AND (%(f)s::date IS NULL OR gms.local_date(v.captured_at_device) >= %(f)s)
              AND (%(t)s::date IS NULL OR gms.local_date(v.captured_at_device) <= %(t)s)
            WHERE u.role='employee' GROUP BY u.id, u.full_name ORDER BY u.full_name""", p)
        cols = [Col("employee", "الموظف", width=1.8), Col("visits", "الزيارات", "int", total=True), Col("readings", "قراءات", "int", total=True),
                Col("unreadable", "تعذر", "int", total=True), Col("incidents", "بلاغات عداد", "int", total=True),
                Col("approved", "معتمدة", "int", total=True), Col("rejected", "مرفوضة", "int", total=True),
                Col("pending", "بانتظار المراجعة", "int", total=True), Col("flagged", "باستثناءات", "int", total=True)]
        return Report(KINDS[kind], cols, rows, meta, None)

    if kind == "arrears":
        rows = db.all(actor, f"""SELECT s.subscription_no, s.full_name, g.name AS generator, z.name AS zone,
            a.balance_exact_ils, a.requested_whole_ils, a.carry_fraction_ils, a.credit_balance_ils, a.total_paid_ils,
            (SELECT max(p.paid_at) FROM gms.payment_receipts p WHERE p.subscriber_id=s.id
               AND NOT EXISTS (SELECT 1 FROM gms.payment_reversals r WHERE r.payment_id=p.id)) AS last_payment
            FROM gms.v_subscriber_account a JOIN gms.subscribers s ON s.id=a.subscriber_id JOIN gms.generators g ON g.id=s.generator_id
            JOIN gms.zones z ON z.id=s.zone_id WHERE a.balance_exact_ils <> 0 {scope}
            ORDER BY a.balance_exact_ils DESC, s.subscription_no""", p)
        cols = [Col("subscription_no", "رقم الاشتراك"), Col("full_name", "المشترك", width=1.8), Col("zone", "المنطقة"),
                Col("balance_exact_ils", "الرصيد الدقيق ₪", "money", total=True), Col("requested_whole_ils", "المطلوب ₪", "int", total=True),
                Col("carry_fraction_ils", "كسر مرحّل ₪", "money", total=True), Col("credit_balance_ils", "رصيد دائن ₪", "money", total=True),
                Col("total_paid_ils", "إجمالي المدفوع ₪", "money", total=True), Col("last_payment", "آخر دفعة", "datetime", 1.3)]
        return Report(KINDS[kind], cols, rows, meta + [("ملاحظة", "المستحق منفصل عن المدفوع وعن الكسور والأرصدة الدائنة")], None)

    if kind == "payments":
        rows = db.all(actor, f"""SELECT p.receipt_no, p.paid_at, s.subscription_no, s.full_name, p.amount_ils,
            CASE p.payment_method WHEN 'cash' THEN 'نقدًا' WHEN 'bank_transfer' THEN 'تحويل بنكي' ELSE 'أخرى' END AS method,
            p.reference_text, u.full_name AS recorded_by,
            CASE WHEN r.id IS NULL THEN 'سارية' ELSE 'ملغاة: ' || r.reason END AS status,
            CASE WHEN r.id IS NULL THEN p.amount_ils ELSE 0 END AS effective
            FROM gms.payment_receipts p JOIN gms.subscribers s ON s.id=p.subscriber_id JOIN gms.app_users u ON u.id=p.received_by
            LEFT JOIN gms.payment_reversals r ON r.payment_id=p.id
            WHERE (%(f)s::date IS NULL OR gms.local_date(p.paid_at) >= %(f)s) AND (%(t)s::date IS NULL OR gms.local_date(p.paid_at) <= %(t)s) {scope}
            ORDER BY p.paid_at, p.receipt_no""", p)
        cols = [Col("receipt_no", "رقم الإيصال"), Col("paid_at", "تاريخ الدفع", "datetime", 1.3), Col("subscription_no", "رقم الاشتراك"),
                Col("full_name", "المشترك", width=1.7), Col("amount_ils", "المبلغ ₪", "money", total=True), Col("method", "الطريقة"),
                Col("reference_text", "المرجع"), Col("recorded_by", "سجّلها"), Col("status", "الحالة", width=1.4),
                Col("effective", "الصافي ₪", "money", total=True)]
        return Report(KINDS[kind], cols, rows, meta, None)

    rows = db.all(actor, f"""SELECT f.recorded_at, s.subscription_no, s.full_name,
        CASE f.kind WHEN 'manual' THEN 'تسوية يدوية' WHEN 'reading_correction' THEN 'تصحيح قراءة' ELSE 'قراءة متأخرة' END AS kind,
        c.label AS cycle, f.adjustment_ils, f.description, u.full_name AS recorded_by
        FROM gms.financial_adjustments f JOIN gms.subscribers s ON s.id=f.subscriber_id JOIN gms.app_users u ON u.id=f.recorded_by
        LEFT JOIN gms.reading_cycles c ON c.id=f.source_cycle_id
        WHERE (%(f)s::date IS NULL OR gms.local_date(f.recorded_at) >= %(f)s) AND (%(t)s::date IS NULL OR gms.local_date(f.recorded_at) <= %(t)s) {scope}
        ORDER BY f.recorded_at""", p)
    cols = [Col("recorded_at", "التاريخ", "datetime", 1.3), Col("subscription_no", "رقم الاشتراك"), Col("full_name", "المشترك", width=1.6),
            Col("kind", "النوع"), Col("cycle", "الدورة المصدر"), Col("adjustment_ils", "المبلغ ₪ (+مدين/-دائن)", "money", 1.3, total=True),
            Col("description", "السبب", width=2.4), Col("recorded_by", "سجّلها")]
    return Report(KINDS[kind], cols, rows, meta, None)


@router.get("")
def list_kinds(m: Principal = Depends(manager)):
    return ok([{"kind": k, "title": v} for k, v in KINDS.items()])


@router.get("/statements/{cycle_id}/print")
def print_statements(cycle_id: uuid.UUID, subscriber_id: uuid.UUID | None = None, generator_id: uuid.UUID | None = None,
                     zone_id: uuid.UUID | None = None, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    p = {"c": cycle_id, "s": subscriber_id, "g": generator_id, "z": zone_id}
    where = """sv.cycle_id=%(c)s AND sv.state='final' AND (%(s)s::uuid IS NULL OR sv.subscriber_id=%(s)s)
        AND (%(g)s::uuid IS NULL OR s.generator_id=%(g)s) AND (%(z)s::uuid IS NULL OR s.zone_id=%(z)s)"""
    sts = db.all(m.id, f"""SELECT sv.*, s.subscription_no, s.full_name AS subscriber_name, g.name AS generator_name, z.name AS zone_name,
        c.label AS cycle_label, c.starts_on, c.ends_on, COALESCE(pay.total, 0) AS payments_in_period
        FROM gms.statement_versions sv JOIN gms.subscribers s ON s.id=sv.subscriber_id JOIN gms.generators g ON g.id=s.generator_id
        JOIN gms.zones z ON z.id=s.zone_id JOIN gms.reading_cycles c ON c.id=sv.cycle_id
        LEFT JOIN LATERAL (SELECT sum(pr.amount_ils) AS total FROM gms.payment_receipts pr WHERE pr.subscriber_id=sv.subscriber_id
           AND gms.local_date(pr.paid_at) BETWEEN c.starts_on AND c.ends_on) pay ON true
        WHERE {where} ORDER BY g.name, z.name, s.subscription_no""", p)
    if not sts:
        raise AppError(404, "no_statements", "لا توجد كشوف نهائية لهذه الدورة")
    lines: dict = {}
    for ln in db.all(m.id, f"""SELECT l.statement_id, a.verified_captured_at, l.previous_value_kwh, l.current_value_kwh, l.consumption_kwh,
            l.exact_charge_ils FROM gms.statement_reading_lines l JOIN gms.approved_readings a ON a.id=l.approved_reading_id
            JOIN gms.statement_versions sv ON sv.id=l.statement_id JOIN gms.subscribers s ON s.id=sv.subscriber_id
            WHERE {where} ORDER BY a.verified_captured_at""", p):
        lines.setdefault(ln.pop("statement_id"), []).append(ln)
    for st in sts:
        st["lines"] = lines.get(st["id"], [])
    tz = db.scalar(m.id, "SELECT gms.business_tz()")
    db.scalar(m.id, "SELECT gms.audit('EXPORT_STATEMENTS','reading_cycles',%s,'{}'::jsonb)", (cycle_id,))
    return Response(render_statements_pdf_parallel(sts, tz, load_identity(db, m.id)), media_type="application/pdf",
                    headers={"Content-Disposition": f"attachment; filename=statements-{sts[0]['cycle_label']}.pdf".encode("ascii", "ignore").decode()})


@router.get("/{kind}")
def report(kind: str, format: str = Query("json", pattern="^(json|pdf|xlsx)$"), cycle_id: uuid.UUID | None = None,
           generator_id: uuid.UUID | None = None, zone_id: uuid.UUID | None = None, date_from: date | None = None,
           date_to: date | None = None, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    r = build(kind, db, m.id, cycle_id, generator_id, zone_id, date_from, date_to)
    if format == "json":
        return ok({"title": r.title, "meta": r.meta, "final": r.final, "note": r.note,
                   "columns": [{"key": c.key, "title": c.title, "kind": c.kind} for c in r.columns], "rows": r.rows, "totals": r.totals()})
    tz = db.scalar(m.id, "SELECT gms.business_tz()")
    db.scalar(m.id, "SELECT gms.audit('EXPORT_REPORT','reports',NULL,%s::jsonb)", (f'{{"kind":"{kind}","format":"{format}"}}',))
    if format == "pdf":
        return Response(render_pdf(r, tz, load_identity(db, m.id)), media_type="application/pdf", headers={"Content-Disposition": f"attachment; filename=gms-{kind}.pdf"})
    return Response(render_xlsx(r, tz, load_identity(db, m.id)), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    headers={"Content-Disposition": f"attachment; filename=gms-{kind}.xlsx"})
