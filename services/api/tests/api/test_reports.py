"""AT-18 / FR-29: every report renders to PDF and Excel; numbers equal API/DB values; Arabic RTL present."""
import io
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import pymupdf
from openpyxl import load_workbook

from tests.apiclient import expect


def scenario(w):
    a = w.subscriber("QA-R1", "100.00")
    b = w.subscriber("QA-R2", "50.00")
    c = w.cycle("QA-RW1", -6, 0, rate="14")
    for sub, val, d in ((a, "101.20", -5), (a, "101.43", -4), (b, "60.00", -3)):
        t = expect(w.m.post("/api/v1/tasks", {"cycle_id": c, "subscriber_id": sub["id"], "planned_for": w.day(d)}), 201)
        vid = w.field_reading(sub, val, w.at(d), task=t["id"])
        expect(w.m.post(f"/api/v1/visits/{vid}/approve", {"photo_reviewed": True}), 200)
    return a, b, c


def test_reports_pdf_excel_match_data(api, tmp_path):
    w = api.setup()
    a, b, c = scenario(w)
    prov = expect(w.m.get("/api/v1/reports/consumption", params={"cycle_id": c}), 200)
    assert prov["final"] is False and prov["totals"]["cost"] == "160.02"          # 11.43 kWh x 14 (provisional)
    expect(w.m.get("/api/v1/reports/statements", params={"cycle_id": c}), 409, "cycle_not_closed")
    expect(w.m.post(f"/api/v1/cycles/{c}/finalize", {"final_rate_ils_per_kwh": "15", "confirm": True}), 200)
    expect(w.m.post("/api/v1/payments", {"subscriber_id": a["id"], "amount_ils": "21", "paid_at": datetime.now(timezone.utc).isoformat(),
                                         "method": "cash", "idempotency_key": str(uuid.uuid4())}), 201)
    params = {"cycle_id": c, "date_from": w.day(-30), "date_to": w.day(1)}
    for kind in ("consumption", "statements", "generators", "employees", "unread", "arrears", "payments", "adjustments"):
        data = expect(w.m.get(f"/api/v1/reports/{kind}", params=params), 200)
        pdf = w.m.get(f"/api/v1/reports/{kind}", params={**params, "format": "pdf"})
        assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF"), kind
        doc = pymupdf.open(stream=pdf.content, filetype="pdf")
        text = "".join(p.get_text() for p in doc)
        assert "GMS" in text and data["title"].split()[0] in text, kind
        if kind == "statements":
            doc[0].get_pixmap(dpi=110).save(str(tmp_path / "statements-report.png"))
        xl = w.m.get(f"/api/v1/reports/{kind}", params={**params, "format": "xlsx"})
        wb = load_workbook(io.BytesIO(xl.content))
        ws = wb.active
        assert ws.sheet_view.rightToLeft is True and ws["A1"].value == data["title"]
        titles = [col["title"] for col in data["columns"]]
        header_row = next(r for r in range(1, 30) if [ws.cell(r, j).value for j in range(1, len(titles) + 1)] == titles)
        for i, row in enumerate(data["rows"]):
            for j, col in enumerate(data["columns"], start=1):
                cell = ws.cell(header_row + 1 + i, j).value
                if col["kind"] in ("money", "kwh", "rate") and row[col["key"]] is not None:
                    assert cell is not None and not isinstance(cell, str), (kind, col["key"], cell)
                    assert Decimal(str(cell)) == Decimal(row[col["key"]]), (kind, col["key"])
    st = expect(w.m.get("/api/v1/reports/statements", params=params), 200)
    ra = next(r for r in st["rows"] if r["subscription_no"] == "QA-R1")
    assert (ra["charge_exact_ils"], ra["requested_whole_ils"], ra["carry_out_ils"]) == ("21.45", "21", "0.45")
    assert st["totals"]["charge_exact_ils"] == "171.45" and st["final"] is True
    arrears = expect(w.m.get("/api/v1/reports/arrears"), 200)
    assert {r["subscription_no"]: r["requested_whole_ils"] for r in arrears["rows"]} == {"QA-R1": "0", "QA-R2": "150"}
    pr = w.m.get(f"/api/v1/reports/statements/{c}/print")
    assert pr.status_code == 200
    doc = pymupdf.open(stream=pr.content, filetype="pdf")
    assert doc.page_count == 2
    doc[0].get_pixmap(dpi=110).save(str(tmp_path / "statement-page.png"))
    (tmp_path / "statements.pdf").write_bytes(pr.content)
    print("REPORT_IMAGES", tmp_path)
    expect(w.e.get("/api/v1/reports/arrears"), 403)


def test_pdf_has_no_missing_glyphs(api):
    from app.reports import Col, Report, render_pdf
    r = Report("اختبار العملة", [Col("a", "المبلغ ₪", "money")], [{"a": "21.45"}], [("المولد", "QA")], True)
    text = "".join(p.get_text() for p in pymupdf.open(stream=render_pdf(r, "Asia/Gaza"), filetype="pdf"))
    assert "شيكل" in text and "\u20aa" not in text and "21.45" in text
