"""FR-06 / AT-16: Excel import of subscribers + meters + opening readings: upload -> preview (validation,
duplicates in file and in DB) -> explicit commit of the SAME stored rows, atomically. The client's real
column layout is still unknown (SRS Q05) — this template is a proposal (docs/assumptions-and-decisions.md D-14)."""
from __future__ import annotations

import hashlib
import io
import json
import uuid
from datetime import date, datetime, time, timezone
from decimal import Decimal, InvalidOperation

from fastapi import APIRouter, Depends, Form, UploadFile
from fastapi.responses import Response
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill

from app.db import Database
from app.deps import Principal, get_db, manager
from app.errors import AppError
from app.util import dumps, ok

router = APIRouter(prefix="/api/v1/imports", tags=["imports"])

COLUMNS = [  # (key, Arabic header, required)
    ("subscription_no", "رقم الاشتراك", True),
    ("full_name", "اسم المشترك", True),
    ("phone", "الهاتف", False),
    ("address", "العنوان", False),
    ("generator", "المولد", True),
    ("zone", "المنطقة", True),
    ("meter_serial", "رقم العداد", True),
    ("meter_type", "نوع العداد", True),
    ("opening_value_kwh", "القراءة الافتتاحية", True),
    ("installed_on", "تاريخ التركيب", True),
    ("interval_days", "فترة القراءة بالأيام", True),
    ("notes", "ملاحظات", False),
]
SYNONYMS = {  # used to SUGGEST a mapping for an unknown client file; the manager confirms it on screen
    "subscription_no": ["رقم الاشتراك", "رقم المشترك", "رقم الحساب", "الرقم", "subscription", "account", "id"],
    "full_name": ["اسم المشترك", "الاسم", "المشترك", "الاسم الكامل", "name", "full name"],
    "phone": ["الهاتف", "الجوال", "رقم الهاتف", "رقم الجوال", "موبايل", "phone", "mobile"],
    "address": ["العنوان", "السكن", "address"],
    "generator": ["المولد", "اسم المولد", "generator"],
    "zone": ["المنطقة", "الحي", "المربع", "zone", "area"],
    "meter_serial": ["رقم العداد", "العداد", "meter", "serial"],
    "meter_type": ["نوع العداد", "النوع", "type"],
    "opening_value_kwh": ["القراءة الافتتاحية", "القراءة", "آخر قراءة", "القراءة الحالية", "reading", "opening"],
    "installed_on": ["تاريخ التركيب", "تاريخ الاشتراك", "التاريخ", "date"],
    "interval_days": ["فترة القراءة بالأيام", "فترة القراءة", "الفترة", "interval"],
    "notes": ["ملاحظات", "ملاحظة", "notes"],
}


def _norm(h: str) -> str:
    h = (h or "").strip().lower().replace("ـ", "")
    for a, b in (("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ة", "ه"), ("ى", "ي")):
        h = h.replace(a, b)
    return " ".join(h.split())


def suggest(headers: list[str]) -> dict:
    taken, out = set(), {}
    for key, names in SYNONYMS.items():
        cands = [_norm(n) for n in names]
        hit = next((h for h in headers if h and _norm(h) in cands and h not in taken), None)
        if hit is None:
            hit = next((h for h in headers if h and h not in taken and any(c and c in _norm(h) for c in cands[:2])), None)
        if hit:
            taken.add(hit)
        out[key] = {"column": hit} if hit else None
    return out


METER_TYPES = {"رقمي": "digital", "digital": "digital", "ميكانيكي": "mechanical", "mechanical": "mechanical"}
MAX_ROWS = 20000


@router.get("/subscribers/template")
def template(m: Principal = Depends(manager)):
    wb = Workbook()
    ws = wb.active
    ws.title = "المشتركون"
    ws.sheet_view.rightToLeft = True
    ws.append([h for _, h, _ in COLUMNS])
    for i, (_, _, req) in enumerate(COLUMNS, start=1):
        cell = ws.cell(row=1, column=i)
        cell.font = Font(bold=True)
        cell.fill = PatternFill("solid", fgColor="FFE9D8" if req else "FFF2F2F2")
        ws.column_dimensions[cell.column_letter].width = 20
    buf = io.BytesIO()
    wb.save(buf)
    return Response(buf.getvalue(), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                    headers={"Content-Disposition": "attachment; filename=gms-subscribers-template.xlsx"})


def _text(v) -> str | None:
    if v is None:
        return None
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    s = str(v).strip()
    return s or None


def _decimal(v) -> Decimal:
    if isinstance(v, bool):
        raise InvalidOperation
    if isinstance(v, float):
        v = repr(v)          # exact text Excel stored (shortest round-trip), never re-rounded
    return Decimal(str(v).strip().replace(",", ""))


def _date(v) -> date:
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    s = str(v).strip().replace("/", "-").replace(".", "-")
    parts = s.split("-")
    if len(parts) == 3 and len(parts[2]) == 4:          # dd-mm-yyyy (common in Arabic spreadsheets)
        return date(int(parts[2]), int(parts[1]), int(parts[0]))
    return date.fromisoformat("-".join(p.zfill(2) for p in parts) if len(parts) == 3 else s)


def _sheet(content: bytes):
    try:
        wb = load_workbook(io.BytesIO(content), read_only=True, data_only=True)
    except Exception as err:
        raise AppError(422, "invalid_file", "الملف ليس ملف Excel صالحًا (xlsx)") from err
    rows = wb.worksheets[0].iter_rows(values_only=True)
    return [(_text(h) or "") for h in next(rows, [])], rows


def parse_rows(content: bytes, mapping: dict | None = None) -> list[dict]:
    """mapping: {field: {"column": header} | {"value": constant}}; without it the standard template headers are used."""
    header, rows = _sheet(content)
    index, const = {}, {}
    for key, ar, req in COLUMNS:
        m = (mapping or {}).get(key)
        if m and m.get("column") is not None:
            if m["column"] not in header:
                raise AppError(422, "missing_column", f"العمود «{m['column']}» غير موجود في الملف")
            index[key] = header.index(m["column"])
        elif m and str(m.get("value", "")).strip():
            const[key] = str(m["value"]).strip()
        elif mapping is None and ar in header:
            index[key] = header.index(ar)
        elif mapping is None and key in header:
            index[key] = header.index(key)
        elif req:
            raise AppError(422, "missing_column", f"الحقل المطلوب «{ar}» غير مربوط بعمود أو قيمة ثابتة")
    out = []
    for n, raw in enumerate(rows, start=2):
        if raw is None or all(c is None or str(c).strip() == "" for c in raw):
            continue
        if len(out) >= MAX_ROWS:
            raise AppError(422, "too_many_rows", f"الحد الأقصى {MAX_ROWS} صف في الملف الواحد")
        out.append({"row": n, "raw": {**const, **{k: (raw[i] if i < len(raw) else None) for k, i in index.items()}}})
    return out


def validate(db: Database, actor, parsed: list[dict]) -> list[dict]:
    gens = {r["name"]: r["id"] for r in db.all(actor, "SELECT id, name FROM gms.generators")}
    zones = {(r["generator_id"], r["name"]): r["id"] for r in db.all(actor, "SELECT id, generator_id, name FROM gms.zones WHERE is_active")}
    existing_subs = {r["subscription_no"] for r in db.all(actor, "SELECT subscription_no FROM gms.subscribers")}
    existing_meters = {r["serial_no"] for r in db.all(actor, "SELECT serial_no FROM gms.meters")}
    seen_subs, seen_meters, result = {}, {}, []
    for item in parsed:
        raw, errors, v = item["raw"], [], {}
        for key, ar, req in COLUMNS:
            if req and _text(raw.get(key)) is None:
                errors.append(f"«{ar}» مطلوب")
        for key in ("subscription_no", "full_name", "phone", "address", "meter_serial", "notes"):
            v[key] = _text(raw.get(key))
        gid = gens.get(_text(raw.get("generator")) or "")
        if _text(raw.get("generator")) and not gid:
            errors.append(f"المولد «{_text(raw.get('generator'))}» غير معرّف في النظام")
        zid = zones.get((gid, _text(raw.get("zone")) or "")) if gid else None
        if gid and _text(raw.get("zone")) and not zid:
            errors.append(f"المنطقة «{_text(raw.get('zone'))}» غير موجودة ضمن هذا المولد")
        v["zone_id"] = str(zid) if zid else None
        mt = _text(raw.get("meter_type"))
        v["meter_type"] = METER_TYPES.get((mt or "").lower())
        if mt and not v["meter_type"]:
            errors.append("نوع العداد يجب أن يكون «رقمي» أو «ميكانيكي»")
        if raw.get("opening_value_kwh") is not None:
            try:
                d = _decimal(raw["opening_value_kwh"])
                if d < 0 or d.as_tuple().exponent < -2:
                    errors.append(f"القراءة الافتتاحية {d} يجب أن تكون غير سالبة وبمنزلتين عشريتين كحد أقصى (لا تقريب)")
                v["opening_value_kwh"] = str(d)
            except (InvalidOperation, ValueError):
                errors.append("القراءة الافتتاحية ليست رقمًا")
        if raw.get("installed_on") is not None:
            try:
                d = _date(raw["installed_on"])
                if d > date.today():
                    errors.append("تاريخ التركيب في المستقبل")
                v["installed_on"] = d.isoformat()
            except ValueError:
                errors.append("تاريخ التركيب غير صالح (YYYY-MM-DD)")
        if raw.get("interval_days") is not None:
            try:
                iv = int(_decimal(raw["interval_days"]))
                if not 1 <= iv <= 366 or _decimal(raw["interval_days"]) != iv:
                    raise ValueError
                v["interval_days"] = iv
            except (InvalidOperation, ValueError):
                errors.append("فترة القراءة يجب أن تكون عددًا صحيحًا بين 1 و366")
        status = "error" if errors else "new"
        no, serial = v["subscription_no"], v["meter_serial"]
        if no and no in seen_subs:
            errors.append(f"رقم الاشتراك مكرر في الملف (الصف {seen_subs[no]})")
            status = "duplicate_in_file"
        if serial and serial in seen_meters:
            errors.append(f"رقم العداد مكرر في الملف (الصف {seen_meters[serial]})")
            status = "duplicate_in_file"
        if status == "new" and no in existing_subs:
            status, errors = "exists", ["المشترك موجود مسبقًا في النظام — لن يُستورد مرة ثانية"]
        elif status == "new" and serial in existing_meters:
            status, errors = "error", ["رقم العداد مسجل مسبقًا لمشترك آخر"]
        if no:
            seen_subs.setdefault(no, item["row"])
        if serial:
            seen_meters.setdefault(serial, item["row"])
        result.append({"row": item["row"], "status": status, "errors": errors, "values": v})
    return result


def _summary(rows: list[dict]) -> dict:
    s = {"total": len(rows)}
    for r in rows:
        s[r["status"]] = s.get(r["status"], 0) + 1
    return s


@router.post("/subscribers/inspect")
async def inspect(file: UploadFile, m: Principal = Depends(manager)):
    """Step 1 for an unknown file: headers, a few sample rows and a suggested column mapping."""
    content = await file.read()
    if len(content) > 15 * 1024 * 1024:
        raise AppError(413, "file_too_large", "حجم الملف كبير جدًا")
    header, rows = _sheet(content)
    sample = []
    for raw in rows:
        if raw and any(c not in (None, "") for c in raw):
            sample.append([_text(c) for c in raw[: len(header)]])
        if len(sample) == 3:
            break
    return ok({"headers": header, "sample": sample, "suggested": suggest(header),
               "fields": [{"key": k, "title": t, "required": r} for k, t, r in COLUMNS]})


@router.post("/subscribers", status_code=201)
async def upload(file: UploadFile, mapping: str | None = Form(None), db: Database = Depends(get_db), m: Principal = Depends(manager)):
    try:
        mapping_obj = json.loads(mapping) if mapping else None
        if mapping_obj is not None and not isinstance(mapping_obj, dict):
            raise ValueError
    except ValueError as err:
        raise AppError(422, "invalid_mapping", "ربط الأعمدة غير صالح") from err
    content = await file.read()
    if len(content) > 15 * 1024 * 1024:
        raise AppError(413, "file_too_large", "حجم الملف كبير جدًا")
    sha = hashlib.sha256(content).hexdigest()
    if db.scalar(m.id, "SELECT EXISTS (SELECT 1 FROM gms.import_batches WHERE file_sha256=%s AND status='committed')", (sha,)):
        raise AppError(409, "file_already_imported", "هذا الملف نفسه استُورد مسبقًا")
    rows = validate(db, m.id, parse_rows(content, mapping_obj))
    batch = db.one(m.id, """INSERT INTO gms.import_batches(filename,file_sha256,uploaded_by,summary,rows)
        VALUES (%s,%s,%s,%s::jsonb,%s::jsonb) RETURNING id, filename, status, summary, created_at""",
                   ((file.filename or "import.xlsx")[:200], sha, m.id, json.dumps(_summary(rows)), dumps(rows).decode()))
    return ok({**batch, "rows": rows}, 201)


@router.get("/{bid}")
def get_batch(bid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    b = db.one(m.id, "SELECT id, filename, status, summary, rows, created_at, committed_at FROM gms.import_batches WHERE id=%s", (bid,))
    if not b:
        raise AppError(404, "not_found", "دفعة الاستيراد غير موجودة")
    return ok(b)


@router.post("/{bid}/commit")
def commit(bid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    """All importable rows in ONE transaction: either every new subscriber is created or none."""
    with db.tx(m.id) as c:
        b = c.execute("SELECT * FROM gms.import_batches WHERE id=%s FOR UPDATE", (bid,)).fetchone()
        if not b:
            raise AppError(404, "not_found", "دفعة الاستيراد غير موجودة")
        if b["status"] != "preview":
            raise AppError(409, "batch_not_preview", "الدفعة مستوردة أو ملغاة مسبقًا")
        created = 0
        for r in b["rows"]:
            if r["status"] != "new":
                continue
            v = r["values"]
            # re-check at commit time (data may have changed since the preview)
            if c.execute("SELECT 1 FROM gms.subscribers WHERE subscription_no=%s", (v["subscription_no"],)).fetchone():
                continue
            z = c.execute("SELECT generator_id FROM gms.zones WHERE id=%s", (v["zone_id"],)).fetchone()
            sid = c.execute("""INSERT INTO gms.subscribers(subscription_no,full_name,phone,address,notes,generator_id,zone_id)
                VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id""", (v["subscription_no"], v["full_name"], v["phone"], v["address"],
                                                               v["notes"], z["generator_id"], v["zone_id"])).fetchone()["id"]
            c.execute("INSERT INTO gms.subscriber_schedules(subscriber_id,interval_days,changed_by) VALUES (%s,%s,%s)", (sid, v["interval_days"], m.id))
            installed = datetime.combine(date.fromisoformat(v["installed_on"]), time(12), tzinfo=timezone.utc)
            c.execute("SELECT gms.install_meter(%s,%s,%s,%s,%s,%s)", (sid, v["meter_serial"], v["meter_type"], installed,
                                                                     Decimal(v["opening_value_kwh"]), f"استيراد Excel: {b['filename']} صف {r['row']}"))
            created += 1
        summary = {**b["summary"], "created": created}
        c.execute("UPDATE gms.import_batches SET status='committed', committed_at=now(), summary=%s::jsonb WHERE id=%s", (json.dumps(summary), bid))
    return ok({"id": bid, "status": "committed", "summary": summary})


@router.post("/{bid}/discard")
def discard(bid: uuid.UUID, db: Database = Depends(get_db), m: Principal = Depends(manager)):
    row = db.one(m.id, "UPDATE gms.import_batches SET status='discarded' WHERE id=%s AND status='preview' RETURNING id", (bid,))
    if not row:
        raise AppError(409, "batch_not_preview", "الدفعة ليست في وضع المعاينة")
    return ok()
