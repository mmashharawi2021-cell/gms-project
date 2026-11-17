"""AT-16 / FR-06: Excel preview, validation, duplicate detection, atomic commit, no double import."""
import io

from openpyxl import Workbook, load_workbook

from app.routers.imports import COLUMNS
from tests.apiclient import expect

H = [h for _, h, _ in COLUMNS]


def xlsx(rows) -> bytes:
    wb = Workbook()
    ws = wb.active
    ws.append(H)
    for r in rows:
        ws.append(r)
    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def test_excel_import_preview_and_commit(api):
    w = api.setup()
    w.subscriber("QA-EXIST")
    tpl = w.m.get("/api/v1/imports/subscribers/template")
    assert tpl.status_code == 200
    assert [c.value for c in load_workbook(io.BytesIO(tpl.content)).active[1]] == H
    rows = [
        ["S-1", "مشترك أول", "0599", "حي 1", "QA-GEN", "QA-ZONE", "MX-1", "رقمي", 1234.5, "2026-01-01", 7, None],
        ["S-2", "مشترك ثان", None, None, "QA-GEN", "QA-ZONE", "MX-2", "ميكانيكي", "88.25", "2026-01-01", 4, "ملاحظة"],
        ["S-3", "دقة زائدة", None, None, "QA-GEN", "QA-ZONE", "MX-3", "رقمي", 121.987, "2026-01-01", 7, None],
        ["S-1", "مكرر", None, None, "QA-GEN", "QA-ZONE", "MX-4", "رقمي", 1, "2026-01-01", 7, None],
        ["QA-EXIST", "موجود", None, None, "QA-GEN", "QA-ZONE", "MX-5", "رقمي", 1, "2026-01-01", 7, None],
        ["S-6", "منطقة غير معروفة", None, None, "QA-GEN", "لا توجد", "MX-6", "رقمي", 1, "2026-01-01", 7, None],
        ["S-7", None, None, None, "QA-GEN", "QA-ZONE", "MX-7", "شمسي", -3, "غدًا", 0, None],
        [None, None, None, None, None, None, None, None, None, None, None, None],
    ]
    content = xlsx(rows)
    b = expect(w.m.client.post("/api/v1/imports/subscribers", headers=w.m.h,
                               files={"file": ("subs.xlsx", content, "application/octet-stream")}), 201)
    st = {r["row"]: r for r in b["rows"]}
    assert [st[i]["status"] for i in range(2, 9)] == ["new", "new", "error", "duplicate_in_file", "exists", "error", "error"]
    assert st[2]["values"]["opening_value_kwh"] == "1234.5"
    assert "121.987" in st[4]["errors"][0]
    assert len(st[8]["errors"]) >= 5
    assert b["summary"] == {"total": 7, "new": 2, "error": 3, "duplicate_in_file": 1, "exists": 1}
    assert expect(w.m.get("/api/v1/subscribers"), 200)["total"] == 1      # preview writes nothing
    done = expect(w.m.post(f"/api/v1/imports/{b['id']}/commit"), 200)
    assert done["summary"]["created"] == 2
    expect(w.m.post(f"/api/v1/imports/{b['id']}/commit"), 409, "batch_not_preview")
    subs = {s["subscription_no"]: s for s in expect(w.m.get("/api/v1/subscribers"), 200)["items"]}
    assert set(subs) == {"QA-EXIST", "S-1", "S-2"} and subs["S-2"]["interval_days"] == 4
    d = expect(w.m.get(f"/api/v1/subscribers/{subs['S-1']['id']}"), 200)
    assert d["installations"][0]["opening_value_kwh"] == "1234.5"
    # the same file cannot be imported twice
    expect(w.m.client.post("/api/v1/imports/subscribers", headers=w.m.h,
                           files={"file": ("subs.xlsx", content, "application/octet-stream")}), 409, "file_already_imported")
    expect(w.m.client.post("/api/v1/imports/subscribers", headers=w.m.h,
                           files={"file": ("x.xlsx", b"not excel", "application/octet-stream")}), 422, "invalid_file")
    expect(w.e.client.post("/api/v1/imports/subscribers", headers=w.e.h,
                           files={"file": ("subs2.xlsx", xlsx(rows[:1]), "application/octet-stream")}), 403)


def test_unknown_client_layout_is_mapped_on_screen(api):
    """A file with the client's own headers (no template): inspect suggests a mapping; constants fill missing columns."""
    import json

    w = api.setup()
    wb = Workbook()
    ws = wb.active
    ws.append(["الرقم", "اسم المشترك", "الجوال", "الحي", "رقم العداد", "آخر قراءة", "تاريخ الاشتراك", "عمود لا يهم"])
    ws.append(["A-1", "أول", "0599", "QA-ZONE", "MM-1", 120.5, "15/10/2026", "x"])
    ws.append(["A-2", "ثانٍ", None, "QA-ZONE", "MM-2", "77", "2026/10/16", "y"])
    buf = io.BytesIO()
    wb.save(buf)
    content = buf.getvalue()
    files = {"file": ("client.xlsx", content, "application/octet-stream")}
    expect(w.m.client.post("/api/v1/imports/subscribers", headers=w.m.h, files=files), 422, "missing_column")
    ins = expect(w.m.client.post("/api/v1/imports/subscribers/inspect", headers=w.m.h, files=files), 200)
    sug = ins["suggested"]
    assert sug["subscription_no"] == {"column": "الرقم"} and sug["full_name"] == {"column": "اسم المشترك"}
    assert sug["zone"] == {"column": "الحي"} and sug["opening_value_kwh"] == {"column": "آخر قراءة"} and sug["generator"] is None
    assert ins["sample"][0][0] == "A-1"
    mapping = {**{k: v for k, v in sug.items() if v}, "generator": {"value": "QA-GEN"}, "meter_type": {"value": "رقمي"}, "interval_days": {"value": "7"}}
    b = expect(w.m.client.post("/api/v1/imports/subscribers", headers=w.m.h, files=files, data={"mapping": json.dumps(mapping)}), 201)
    assert [r["status"] for r in b["rows"]] == ["new", "new"], b["rows"]
    assert b["rows"][0]["values"]["installed_on"] == "2026-10-15"
    expect(w.m.post(f"/api/v1/imports/{b['id']}/commit"), 200)
    subs = {s["subscription_no"]: s for s in expect(w.m.get("/api/v1/subscribers"), 200)["items"]}
    assert set(subs) == {"A-1", "A-2"} and subs["A-1"]["meter_serial"] == "MM-1"
    expect(w.m.client.post("/api/v1/imports/subscribers", headers=w.m.h, files=files, data={"mapping": "not-json"}), 422, "invalid_mapping")
