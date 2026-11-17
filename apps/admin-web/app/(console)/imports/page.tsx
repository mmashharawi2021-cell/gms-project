"use client";
import { useState } from "react";
import { api, download } from "@/lib/api";
import { Badge, Button, Card, Empty, ErrorBox, Field, PageHeader, useAction } from "@/components/ui";

const STATUS: Record<string, [string, string]> = { new: ["جديد — سيُستورد", "ok"], exists: ["موجود مسبقًا — يُتخطى", "muted"], duplicate_in_file: ["مكرر في الملف", "warn"], error: ["خطأ", "danger"] };

type Map = Record<string, { column?: string; value?: string } | null>;

export default function Imports() {
  const [file, setFile] = useState<File | null>(null);
  const [inspect, setInspect] = useState<any>(null);
  const [mapping, setMapping] = useState<Map>({});
  const [batch, setBatch] = useState<any>(null);
  const [done, setDone] = useState<any>(null);
  const { busy, error, run } = useAction();

  async function readHeaders(f: File) {
    setFile(f);
    setBatch(null);
    setDone(null);
    const form = new FormData();
    form.append("file", f);
    const r: any = await run(() => api("imports/subscribers/inspect", { form }));
    if (r) {
      setInspect(r);
      setMapping(r.suggested);
    }
  }

  async function preview() {
    if (!file) return;
    const form = new FormData();
    form.append("file", file);
    form.append("mapping", JSON.stringify(mapping));
    const r = await run(() => api("imports/subscribers", { form }));
    if (r) setBatch(r);
  }

  const setField = (key: string, v: string) => {
    if (v === "") return setMapping({ ...mapping, [key]: null });
    if (v === "__const") return setMapping({ ...mapping, [key]: { value: "" } });
    setMapping({ ...mapping, [key]: { column: v } });
  };

  return (
    <div className="stack">
      <PageHeader title="استيراد المشتركين من Excel" subtitle="1) اختيار الملف ← 2) ربط الأعمدة بحقول النظام ← 3) معاينة وفحص ← 4) تأكيد. لا يُكتب شيء قبل التأكيد، والاستيراد كامل أو لا شيء."
        actions={<Button onClick={() => download("imports/subscribers/template", "gms-subscribers-template.xlsx")}>تنزيل قالب مقترح</Button>} />
      <Card>
        <div className="alert alert-info">يمكن استخدام ملفك كما هو: يقترح النظام ربط أعمدته تلقائيًا وتؤكد أنت. الحقل غير الموجود في الملف (مثل المولد عند وجود ملف لكل مولد) يمكن إعطاؤه قيمة ثابتة. القراءة الافتتاحية بمنزلتين عشريتين كحد أقصى — القيم الأدق تُرفض ولا تُقرّب.</div>
        <div className="filters">
          <Field label="ملف Excel (xlsx)"><input type="file" accept=".xlsx" onChange={(e) => e.target.files?.[0] && readHeaders(e.target.files[0])} /></Field>
        </div>
        <ErrorBox error={error} />
      </Card>
      {inspect && !batch && (
        <Card title="ربط الأعمدة" actions={<Button variant="primary" busy={busy} onClick={preview}>معاينة وفحص</Button>}>
          <div className="table-wrap"><table>
            <thead><tr><th>حقل النظام</th><th>المصدر في ملفك</th><th>قيمة ثابتة</th><th>مثال من الصف الأول</th></tr></thead>
            <tbody>{inspect.fields.map((f: any) => {
              const m = mapping[f.key];
              const col = m?.column;
              const isConst = m && m.column === undefined;
              const idx = col ? inspect.headers.indexOf(col) : -1;
              return (
                <tr key={f.key}>
                  <td>{f.title}{f.required && <b className="req"> *</b>}</td>
                  <td><select value={isConst ? "__const" : col ?? ""} onChange={(e) => setField(f.key, e.target.value)}>
                    <option value="">— غير مربوط —</option>
                    {inspect.headers.filter((h: string) => h).map((h: string) => <option key={h} value={h}>{h}</option>)}
                    <option value="__const">قيمة ثابتة لكل الصفوف…</option>
                  </select></td>
                  <td>{isConst && <input value={m?.value ?? ""} onChange={(e) => setMapping({ ...mapping, [f.key]: { value: e.target.value } })}
                    placeholder={f.key === "meter_type" ? "رقمي أو ميكانيكي" : f.key === "installed_on" ? "2026-11-01" : ""} />}</td>
                  <td className="muted">{idx >= 0 ? inspect.sample?.[0]?.[idx] ?? "" : ""}</td>
                </tr>
              );
            })}</tbody>
          </table></div>
        </Card>
      )}
      {batch && (
        <Card title={`معاينة: ${batch.filename}`} actions={!done && <>
          {batch.summary.new > 0 && <Button variant="primary" busy={busy} onClick={async () => { const r = await run(() => api(`imports/${batch.id}/commit`, { method: "POST" }), "تم الاستيراد"); if (r) setDone(r); }}>تأكيد استيراد {batch.summary.new} مشترك</Button>}
          <Button onClick={() => setBatch(null)}>تعديل الربط</Button>
          <Button onClick={async () => { await run(() => api(`imports/${batch.id}/discard`, { method: "POST" })); setBatch(null); setInspect(null); }}>إلغاء الدفعة</Button></>}>
          <div className="row gap" style={{ marginBottom: 12 }}>{Object.entries(batch.summary).map(([k, v]) => <Badge key={k} tone={STATUS[k]?.[1] ?? "info"}>{(STATUS[k]?.[0] ?? (k === "total" ? "إجمالي الصفوف" : k === "created" ? "أُنشئ" : k))}: {String(v)}</Badge>)}</div>
          {done && <div className="alert alert-ok">أُنشئ {done.summary.created} مشترك مع عداداتهم وقراءاتهم الافتتاحية.</div>}
          {!batch.rows.length ? <Empty>الملف فارغ.</Empty> : (
            <div className="table-wrap"><table>
              <thead><tr><th>الصف</th><th>الحالة</th><th>رقم الاشتراك</th><th>الاسم</th><th>العداد</th><th className="n">الافتتاحية</th><th>الملاحظات</th></tr></thead>
              <tbody>{batch.rows.map((r: any) => (
                <tr key={r.row}><td>{r.row}</td><td><Badge tone={STATUS[r.status][1]}>{STATUS[r.status][0]}</Badge></td><td>{r.values.subscription_no}</td><td>{r.values.full_name}</td>
                  <td className="ltr">{r.values.meter_serial}</td><td className="n">{r.values.opening_value_kwh}</td><td>{r.errors.join("؛ ")}</td></tr>
              ))}</tbody>
            </table></div>
          )}
        </Card>
      )}
    </div>
  );
}
