"""Business identity settings, payment receipt PDF, Excel formula-injection guard, parallel statement printing."""
import io
import uuid
from datetime import datetime, timezone

import pymupdf
from openpyxl import load_workbook

from tests.apiclient import expect


def test_identity_settings_receipt_and_formula_guard(api):
    w = api.setup()
    keys = {s["key"] for s in expect(w.m.get("/api/v1/settings"), 200)}
    assert {"business_name", "business_phone", "statement_footer"} <= keys          # migration 0002 applied
    expect(w.m.put("/api/v1/settings/business_name", {"value": "مولدات النور"}), 200)
    expect(w.m.put("/api/v1/settings/business_phone", {"value": "0599-123456"}), 200)
    expect(w.m.put("/api/v1/settings/statement_footer", {"value": "الدفع في مكتب المولد يوميًا"}), 200)
    expect(w.m.put("/api/v1/settings/business_name", {"value": "x" * 81}), 422, "invalid_value")
    expect(w.e.put("/api/v1/settings/business_name", {"value": "hacked"}), 403)
    # a hostile name coming from data entry / Excel import
    evil = '=HYPERLINK("http://evil.example","اضغط")'
    sub = expect(w.m.post("/api/v1/subscribers", {"subscription_no": "QA-EVIL", "full_name": evil, "zone_id": w.zone, "interval_days": 7}), 201)
    pay = expect(w.m.post("/api/v1/payments", {"subscriber_id": sub["id"], "amount_ils": "25.50", "paid_at": datetime.now(timezone.utc).isoformat(),
                                               "method": "cash", "reference": "دفتر 7", "idempotency_key": str(uuid.uuid4())}), 201)["payment"]
    # receipt PDF
    r = w.m.get(f"/api/v1/payments/{pay['id']}/receipt")
    assert r.status_code == 200 and r.content.startswith(b"%PDF")
    text = "".join(p.get_text() for p in pymupdf.open(stream=r.content, filetype="pdf"))
    assert pay["receipt_no"] in text and "25.5" in text and "النور" in text and "الدفع في مكتب المولد" in text
    expect(w.e.get(f"/api/v1/payments/{pay['id']}/receipt"), 403)
    expect(w.m.post(f"/api/v1/payments/{pay['id']}/reverse", {"reason": "خطأ إدخال"}), 200)
    text = "".join(p.get_text() for p in pymupdf.open(stream=w.m.get(f"/api/v1/payments/{pay['id']}/receipt").content, filetype="pdf"))
    assert "ملغى" in text
    # Excel: the hostile name is stored as plain text, never as a formula
    xl = w.m.get("/api/v1/reports/payments", params={"format": "xlsx"})
    ws = load_workbook(io.BytesIO(xl.content)).active
    cells = [c for row in ws.iter_rows() for c in row if isinstance(c.value, str) and "HYPERLINK" in c.value]
    assert cells and all(c.data_type == "s" for c in cells)
    assert ws["B2"].value == "مولدات النور"
    # audit of the receipt print
    assert any(a["action_code"] == "PRINT_RECEIPT" for a in expect(w.m.get("/api/v1/audit", params={"entity_type": "payment_receipts"}), 200))


def test_parallel_statement_printing_keeps_order():
    import datetime as dt
    from decimal import Decimal

    from app.reports import Identity, render_statements_pdf_parallel

    def st(i):
        return {"statement_no": f"ST-{i:05d}", "generator_name": "G", "zone_name": "Z", "subscriber_name": f"QA {i}", "subscription_no": f"QA-{i}",
                "cycle_label": "W", "starts_on": dt.date(2026, 11, 9), "ends_on": dt.date(2026, 11, 15), "rate_snapshot_ils_per_kwh": Decimal(15),
                "consumption_kwh": Decimal("1.43"), "charge_exact_ils": Decimal("21.45"), "opening_ledger_balance_ils": Decimal(0),
                "closing_ledger_balance_ils": Decimal("21.45"), "requested_whole_ils": Decimal(21), "carry_out_ils": Decimal("0.45"),
                "credits_out_ils": Decimal(0), "payments_in_period": Decimal(0), "lines": []}

    pdf = render_statements_pdf_parallel([st(i) for i in range(7)], "Asia/Gaza", Identity("QA"), chunk=2, workers=2)
    doc = pymupdf.open(stream=pdf, filetype="pdf")
    assert doc.page_count == 7
    assert [f"ST-{i:05d}" in doc[i].get_text() for i in range(7)] == [True] * 7
