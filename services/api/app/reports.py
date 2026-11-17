"""Official Arabic reports (FR-29 / AT-18): one data definition rendered to JSON, RTL PDF and RTL Excel.
Every report carries: title, generator scope, cycle/period, issue time, and whether figures are FINAL or PROVISIONAL.
Amounts are exact NUMERIC values from PostgreSQL; nothing is recomputed or rounded here."""
from __future__ import annotations

import io
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path
from zoneinfo import ZoneInfo

from fpdf import FPDF
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side

from app.util import dec_str

FONT_DIR = Path(__file__).parent / "fonts"


@dataclass
class Col:
    key: str
    title: str
    kind: str = "text"     # text | money | kwh | int | date | datetime | rate
    width: float = 1.0
    total: bool = False


@dataclass
class Report:
    title: str
    columns: list[Col]
    rows: list[dict]
    meta: list[tuple[str, str]] = field(default_factory=list)   # (label, value)
    final: bool | None = None                                     # None = not a priced report
    note: str | None = None

    def totals(self) -> dict:
        t = {}
        for c in self.columns:
            if c.total:
                t[c.key] = sum((r[c.key] or Decimal(0) for r in self.rows), Decimal(0))
        return t


def ds(value) -> str:
    """Date text that stays intact inside right-to-left sentences (hyphenated dates get reordered by bidi)."""
    if value is None:
        return "—"
    if isinstance(value, str):
        value = date.fromisoformat(value[:10])
    return value.strftime("%Y/%m/%d")


def fmt(value, kind: str, tz: str = "Asia/Gaza") -> str:
    if value is None:
        return "—"
    if kind in ("money", "kwh", "rate"):
        return dec_str(Decimal(value))
    if kind == "datetime" and isinstance(value, datetime):
        return value.astimezone(ZoneInfo(tz)).strftime("%Y/%m/%d %H:%M")
    if kind == "date" and isinstance(value, (date, datetime)):
        return value.strftime("%Y/%m/%d")
    return str(value)


def status_label(final: bool | None) -> str | None:
    if final is None:
        return None
    return "نهائي" if final else "مبدئي — أرقام تقديرية غير نهائية"


# ------------------------------------------------------------------------------------------- PDF
@dataclass
class Identity:
    """Business identity printed on official documents (manager-editable settings)."""
    name: str = "GMS"
    phone: str = ""
    footer: str = ""


def load_identity(db, actor) -> Identity:
    rows = {r["key"]: r["value"] for r in db.all(actor, "SELECT key, value FROM gms.system_settings WHERE key IN ('business_name','business_phone','statement_footer')")}
    clean = lambda v: "" if v in (None, "-") else v  # noqa: E731
    return Identity(clean(rows.get("business_name")) or "GMS", clean(rows.get("business_phone")), clean(rows.get("statement_footer")))


class _Pdf(FPDF):
    def __init__(self, report: Report, issued: str, identity: Identity | None = None, page_numbers: bool = True):
        super().__init__(orientation="L" if len(report.columns) > 6 else "P", unit="mm", format="A4")
        self.report, self.issued = report, issued
        self.identity, self.page_numbers = identity or Identity(), page_numbers
        self.add_font("Amiri", "", str(FONT_DIR / "Amiri-Regular.ttf"))
        self.add_font("Amiri", "B", str(FONT_DIR / "Amiri-Bold.ttf"))
        self.set_text_shaping(use_shaping_engine=True, direction="rtl", script="arab", language="ara")
        self.set_auto_page_break(True, margin=15)
        self.set_margins(10, 10, 10)
        self.alias_nb_pages()

    # The bundled Arabic font has no U+20AA glyph: spell the currency out instead of silently dropping it.
    def cell(self, w=None, h=None, text="", *args, **kwargs):
        return super().cell(w, h, str(text).replace(" ₪", " شيكل").replace("₪", "شيكل"), *args, **kwargs)

    def multi_cell(self, w, h=None, text="", *args, **kwargs):
        return super().multi_cell(w, h, str(text).replace(" ₪", " شيكل").replace("₪", "شيكل"), *args, **kwargs)

    def footer(self):
        self.set_y(-14)
        self.set_font("Amiri", "", 9)
        if self.identity.footer:
            self.cell(0, 5, self.identity.footer, align="C", new_x="LMARGIN", new_y="NEXT")
        pages = f" — صفحة {self.page_no()} من {{nb}}" if self.page_numbers else ""
        contact = f" — هاتف {self.identity.phone}" if self.identity.phone else ""
        self.cell(0, 5, f"{self.identity.name}{contact}{pages} — تاريخ الإصدار {self.issued}", align="C")


def render_pdf(report: Report, tz: str, identity: Identity | None = None) -> bytes:
    issued = datetime.now(timezone.utc).astimezone(ZoneInfo(tz)).strftime("%Y/%m/%d %H:%M")
    pdf = _Pdf(report, issued, identity)
    pdf.add_page()
    pdf.set_font("Amiri", "B", 12)
    pdf.cell(0, 7, pdf.identity.name, align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Amiri", "B", 16)
    pdf.cell(0, 10, report.title, align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Amiri", "", 11)
    meta = list(report.meta) + [("تاريخ الإصدار", issued)]
    if report.final is not None:
        meta.append(("حالة الأرقام", status_label(report.final)))
    for label, value in meta:
        pdf.cell(0, 6.5, f"{label}: {value}", align="R", new_x="LMARGIN", new_y="NEXT")
    if report.note:
        pdf.set_font("Amiri", "B", 10)
        pdf.multi_cell(0, 6, report.note, align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(2)
    usable = pdf.w - pdf.l_margin - pdf.r_margin
    total_w = sum(c.width for c in report.columns)
    widths = [usable * c.width / total_w for c in report.columns]
    line_h = 7

    def header():
        pdf.set_font("Amiri", "B", 10)
        pdf.set_fill_color(233, 216, 196)
        x = pdf.w - pdf.r_margin
        y = pdf.get_y()
        for c, wd in zip(report.columns, widths, strict=True):      # first column on the RIGHT
            x -= wd
            pdf.set_xy(x, y)
            pdf.cell(wd, line_h + 1, c.title, border=1, align="C", fill=True)
        pdf.set_xy(pdf.l_margin, y + line_h + 1)

    header()
    pdf.set_font("Amiri", "", 9.5)
    for i, row in enumerate(report.rows):
        if pdf.get_y() + line_h > pdf.h - 15:
            pdf.add_page()
            header()
            pdf.set_font("Amiri", "", 9.5)
        x = pdf.w - pdf.r_margin
        y = pdf.get_y()
        fill = i % 2 == 1
        pdf.set_fill_color(247, 244, 240)
        for c, wd in zip(report.columns, widths, strict=True):
            x -= wd
            pdf.set_xy(x, y)
            text = fmt(row.get(c.key), c.kind, tz)
            pdf.cell(wd, line_h, text, border=1, align="R" if c.kind == "text" else "C", fill=fill)
        pdf.set_xy(pdf.l_margin, y + line_h)
    totals = report.totals()
    if totals:
        pdf.set_font("Amiri", "B", 10)
        x = pdf.w - pdf.r_margin
        y = pdf.get_y()
        for idx, (c, wd) in enumerate(zip(report.columns, widths, strict=True)):
            x -= wd
            pdf.set_xy(x, y)
            text = fmt(totals[c.key], c.kind) if c.key in totals else ("الإجمالي" if idx == 0 else "")
            pdf.cell(wd, line_h, text, border=1, align="C")
        pdf.set_xy(pdf.l_margin, y + line_h)
    pdf.ln(3)
    pdf.set_font("Amiri", "", 9)
    pdf.cell(0, 6, f"عدد السجلات: {len(report.rows)}", align="R")
    return bytes(pdf.output())


# ------------------------------------------------------------------------------------------ XLSX
def _no_formula(cell) -> None:
    """Formula injection guard: text from users (names, notes, imported Excel) must never become a live formula."""
    if isinstance(cell.value, str) and cell.value[:1] in ("=", "+", "-", "@") and cell.data_type == "f":
        cell.data_type = "s"


_NUMFMT = {"money": "#,##0.00######", "kwh": "#,##0.00", "rate": "0.00####", "int": "0"}


def render_xlsx(report: Report, tz: str, identity: Identity | None = None) -> bytes:
    issued = datetime.now(timezone.utc).astimezone(ZoneInfo(tz)).strftime("%Y/%m/%d %H:%M")
    wb = Workbook()
    ws = wb.active
    ws.title = "التقرير"
    ws.sheet_view.rightToLeft = True
    bold, thin = Font(bold=True, name="Arial"), Side(style="thin", color="FF999999")
    ws.append([report.title])
    ws["A1"].font = Font(bold=True, size=14, name="Arial")
    ws.append(["الجهة", (identity or Identity()).name])
    meta = list(report.meta) + [("تاريخ الإصدار", issued)]
    if report.final is not None:
        meta.append(("حالة الأرقام", status_label(report.final)))
    for label, value in meta:
        ws.append([label, value])
        for cell in ws[ws.max_row]:
            _no_formula(cell)
    if report.note:
        ws.append([report.note])
    ws.append([])
    ws.append([c.title for c in report.columns])
    hdr = ws.max_row
    for i, _ in enumerate(report.columns, start=1):
        cell = ws.cell(row=hdr, column=i)
        cell.font, cell.fill = bold, PatternFill("solid", fgColor="FFE9D8C4")
        cell.border = Border(top=thin, bottom=thin, left=thin, right=thin)
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    for row in report.rows:
        values = []
        for c in report.columns:
            v = row.get(c.key)
            if c.kind in ("money", "kwh", "rate") and v is not None:
                v = Decimal(v)                   # written as an exact decimal literal
            elif c.kind == "datetime" and isinstance(v, datetime):
                v = v.astimezone(ZoneInfo(tz)).replace(tzinfo=None)
            elif c.kind not in ("int", "date") and v is not None and not isinstance(v, (int, Decimal)):
                v = str(v)
            values.append(v)
        ws.append(values)
        r = ws.max_row
        for i, c in enumerate(report.columns, start=1):
            cell = ws.cell(row=r, column=i)
            _no_formula(cell)
            if c.kind in _NUMFMT:
                cell.number_format = _NUMFMT[c.kind]
            elif c.kind == "datetime":
                cell.number_format = "yyyy-mm-dd hh:mm"
            elif c.kind == "date":
                cell.number_format = "yyyy-mm-dd"
    totals = report.totals()
    if totals:
        ws.append([totals.get(c.key, "الإجمالي" if i == 0 else None) for i, c in enumerate(report.columns)])
        r = ws.max_row
        for i, c in enumerate(report.columns, start=1):
            ws.cell(row=r, column=i).font = bold
            if c.kind in _NUMFMT:
                ws.cell(row=r, column=i).number_format = _NUMFMT[c.kind]
    for i, c in enumerate(report.columns, start=1):
        ws.column_dimensions[ws.cell(row=hdr, column=i).column_letter].width = max(12, 14 * c.width)
    ws.freeze_panes = ws.cell(row=hdr + 1, column=1)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


# ------------------------------------------------------------------------------ weekly statements
_DISCLAIMER = ("إصدار هذا الكشف لا يعني أنه مدفوع. المبالغ الدقيقة محفوظة في دفتر الحساب.",
               "يُطلب الجزء الصحيح من الشيكل ويُرحّل الكسر إلى الحساب التالي دون ازدواج.")


def render_statements_pdf(statements: list[dict], tz: str, identity: Identity | None = None, issued: str | None = None) -> bytes:
    """Printable weekly statement, one page per subscriber (BR-19/20, FR-24/27)."""
    issued = issued or datetime.now(timezone.utc).astimezone(ZoneInfo(tz)).strftime("%Y/%m/%d %H:%M")
    pdf = _Pdf(Report("كشف أسبوعي", [], []), issued, identity, page_numbers=False)
    for st in statements:
        pdf.add_page()
        pdf.set_font("Amiri", "B", 13)
        pdf.cell(0, 7, pdf.identity.name + (f" — {pdf.identity.phone}" if pdf.identity.phone else ""), align="C", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Amiri", "B", 17)
        pdf.cell(0, 10, "كشف الاستهلاك الأسبوعي — نهائي", align="C", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Amiri", "", 11.5)
        for label, value in (("رقم الكشف", st["statement_no"]), ("المولد", st["generator_name"]), ("المنطقة", st["zone_name"]),
                             ("المشترك", f"{st['subscriber_name']} — رقم الاشتراك {st['subscription_no']}"),
                             ("الدورة", f"{st['cycle_label']} ({ds(st['starts_on'])} إلى {ds(st['ends_on'])})"),
                             ("السعر النهائي للدورة", f"{dec_str(st['rate_snapshot_ils_per_kwh'])} شيكل / كيلوواط ساعة"),
                             ("تاريخ الإصدار", issued)):
            pdf.cell(0, 7, f"{label}: {value}", align="R", new_x="LMARGIN", new_y="NEXT")
        pdf.ln(2)
        cols = [("تاريخ القراءة", 1.4), ("القراءة السابقة", 1.2), ("القراءة الحالية", 1.2), ("الاستهلاك kWh", 1.1), ("التكلفة الدقيقة ₪", 1.3)]
        usable = pdf.w - pdf.l_margin - pdf.r_margin
        tw = sum(c[1] for c in cols)
        widths = [usable * c[1] / tw for c in cols]

        def row(values, bold=False, fill=False, widths=widths):
            pdf.set_font("Amiri", "B" if bold else "", 10.5)
            x, y = pdf.w - pdf.r_margin, pdf.get_y()
            for v, wd in zip(values, widths, strict=True):
                x -= wd
                pdf.set_xy(x, y)
                pdf.cell(wd, 8, v, border=1, align="C", fill=fill)
            pdf.set_xy(pdf.l_margin, y + 8)

        pdf.set_fill_color(233, 216, 196)
        row([c[0] for c in cols], bold=True, fill=True)
        for ln in st["lines"]:
            row([fmt(ln["verified_captured_at"], "datetime", tz), dec_str(ln["previous_value_kwh"]), dec_str(ln["current_value_kwh"]),
                 dec_str(ln["consumption_kwh"]), dec_str(ln["exact_charge_ils"])])
        row(["الإجمالي", "", "", dec_str(st["consumption_kwh"]), dec_str(st["charge_exact_ils"])], bold=True)
        pdf.ln(4)
        summary = [
            ("الرصيد قبل هذا الكشف", st["opening_ledger_balance_ils"]),
            ("تكلفة استهلاك الأسبوع", st["charge_exact_ils"]),
            ("الرصيد بعد الكشف", st["closing_ledger_balance_ils"]),
        ]
        pdf.set_font("Amiri", "", 11.5)
        for label, v in summary:
            pdf.cell(0, 7, f"{label}: {dec_str(v)} ₪", align="R", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Amiri", "B", 14)
        pdf.cell(0, 9, f"المبلغ المطلوب: {dec_str(st['requested_whole_ils'])} ₪", align="R", new_x="LMARGIN", new_y="NEXT")
        pdf.set_font("Amiri", "", 11.5)
        pdf.cell(0, 7, f"كسر شيكل مرحّل للحساب التالي: {dec_str(st['carry_out_ils'])} ₪", align="R", new_x="LMARGIN", new_y="NEXT")
        pdf.cell(0, 7, f"رصيد دائن للمشترك: {dec_str(st['credits_out_ils'])} ₪", align="R", new_x="LMARGIN", new_y="NEXT")
        if st.get("payments_in_period"):
            pdf.cell(0, 7, f"دفعات مسجلة خلال فترة الدورة (محسوبة ضمن الرصيد): {dec_str(st['payments_in_period'])} ₪", align="R",
                     new_x="LMARGIN", new_y="NEXT")
        pdf.ln(3)
        pdf.set_font("Amiri", "", 9.5)
        # fixed short lines: automatic line breaking would re-shape the paragraph glyph by glyph (slow on large batches)
        for line in _DISCLAIMER:
            pdf.cell(0, 5.5, line, align="R", new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())


def _render_chunk(args):
    statements, tz, identity, issued = args
    return render_statements_pdf(statements, tz, identity, issued)


def render_statements_pdf_parallel(statements: list[dict], tz: str, identity: Identity | None = None,
                                   chunk: int = 250, workers: int | None = None) -> bytes:
    """Large batches: Arabic shaping is CPU-bound, so pages are rendered in several processes and merged in order."""
    import os
    from concurrent.futures import ProcessPoolExecutor

    from pypdf import PdfWriter

    issued = datetime.now(timezone.utc).astimezone(ZoneInfo(tz)).strftime("%Y/%m/%d %H:%M")
    if len(statements) <= chunk:
        return render_statements_pdf(statements, tz, identity, issued)
    parts = [statements[i:i + chunk] for i in range(0, len(statements), chunk)]
    workers = workers or max(1, min(len(parts), (os.cpu_count() or 2) - 1))
    with ProcessPoolExecutor(max_workers=workers) as pool:
        pdfs = list(pool.map(_render_chunk, [(p, tz, identity, issued) for p in parts]))
    writer = PdfWriter()
    for blob in pdfs:
        writer.append(io.BytesIO(blob))
    out = io.BytesIO()
    writer.write(out)
    return out.getvalue()


_METHOD = {"cash": "نقدًا", "bank_transfer": "تحويل بنكي", "other": "أخرى"}


def render_receipt_pdf(pay: dict, account: dict, identity: Identity, tz: str) -> bytes:
    """Official payment receipt (FR-26). A reversed payment is printed clearly as cancelled."""
    issued = datetime.now(timezone.utc).astimezone(ZoneInfo(tz)).strftime("%Y/%m/%d %H:%M")
    pdf = _Pdf(Report("إيصال", [], []), issued, identity, page_numbers=False)
    pdf.add_page()
    pdf.set_font("Amiri", "B", 15)
    pdf.cell(0, 9, identity.name + (f" — {identity.phone}" if identity.phone else ""), align="C", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Amiri", "B", 19)
    pdf.cell(0, 12, "إيصال قبض", align="C", new_x="LMARGIN", new_y="NEXT")
    if pay.get("reversal_id"):
        pdf.set_text_color(180, 35, 24)
        pdf.cell(0, 9, f"ملغى بتاريخ {fmt(pay['reversed_at'], 'datetime', tz)}: {pay['reversal_reason']}", align="C", new_x="LMARGIN", new_y="NEXT")
        pdf.set_text_color(0, 0, 0)
    pdf.ln(3)
    pdf.set_font("Amiri", "", 12.5)
    rows = [("رقم الإيصال", pay["receipt_no"]), ("تاريخ القبض", fmt(pay["paid_at"], "datetime", tz)),
            ("المشترك", f"{pay['subscriber_name']} — رقم الاشتراك {pay['subscription_no']}"),
            ("طريقة الدفع", _METHOD.get(pay["payment_method"], pay["payment_method"])), ("المرجع", pay.get("reference_text") or "—"),
            ("استلمها", pay["received_by_name"])]
    for label, value in rows:
        pdf.cell(0, 8, f"{label}: {value}", align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(2)
    pdf.set_font("Amiri", "B", 17)
    pdf.cell(0, 11, f"المبلغ المقبوض: {dec_str(Decimal(pay['amount_ils']))} شيكل", align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.set_font("Amiri", "", 12)
    pdf.cell(0, 8, f"الرصيد المطلوب بعد هذه العملية: {dec_str(Decimal(account['requested_whole_ils']))} شيكل", align="R", new_x="LMARGIN", new_y="NEXT")
    if Decimal(account["carry_fraction_ils"]):
        pdf.cell(0, 8, f"كسر مرحّل: {dec_str(Decimal(account['carry_fraction_ils']))} شيكل", align="R", new_x="LMARGIN", new_y="NEXT")
    if Decimal(account["credit_balance_ils"]):
        pdf.cell(0, 8, f"رصيد دائن للمشترك: {dec_str(Decimal(account['credit_balance_ils']))} شيكل", align="R", new_x="LMARGIN", new_y="NEXT")
    pdf.ln(12)
    pdf.cell(0, 8, "توقيع المستلم: ____________________", align="R", new_x="LMARGIN", new_y="NEXT")
    return bytes(pdf.output())
