"use client";
import Link from "next/link";
import { use, useState } from "react";
import { api, download, useQuery } from "@/lib/api";
import { checkDecimal, d, dt, kwh, money, RATE_RE, todayISO } from "@/lib/format";
import { CYCLE_STATE } from "@/lib/labels";
import { Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, Stat, StatusBadge, useAction, useToast } from "@/components/ui";
import { CycleDialog } from "@/components/CycleDialog";

export default function CyclePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const c = useQuery<any>(`cycles/${id}`);
  const est = useQuery<any>(`cycles/${id}/estimate`);
  const toast = useToast();
  const [dialog, setDialog] = useState<string | null>(null);
  const act = useAction();
  if (c.loading && !c.data) return <Loading />;
  if (c.error) return <ErrorBox error={c.error} />;
  const x = c.data;
  if (!x) return null;
  const reload = () => { c.reload(); est.reload(); };
  const b = x.blockers;
  const blocked = b && b.unresolved_tasks + b.unresolved_visits + b.open_error_reports > 0;
  return (
    <div className="stack">
      <PageHeader title={x.label} subtitle={<>{d(x.starts_on)} — {d(x.ends_on)} <StatusBadge map={CYCLE_STATE} value={x.state} /></>}
        actions={<>
          {x.state === "draft" && <><Button onClick={() => setDialog("edit")}>تعديل</Button><Button variant="primary" busy={act.busy} onClick={() => act.run(() => api(`cycles/${id}/open`, { method: "POST" }), "فُتحت الدورة").then(reload)}>فتح الدورة</Button></>}
          {x.state !== "closed" && <><Button onClick={() => setDialog("rate")}>سعر مبدئي</Button>
            <Button busy={act.busy} onClick={() => act.run(() => api<any>(`cycles/${id}/generate-tasks`, { method: "POST" })).then((r: any) => { if (r) toast(`أُنشئت ${r.created} مهمة تلقائية`); reload(); })}>توليد المهام المستحقة</Button></>}
          {x.state === "open" && <Button variant="primary" onClick={() => setDialog("finalize")}>تثبيت السعر النهائي وإغلاق</Button>}
          {x.state === "closed" && <><Link className="btn" href={`/statements?cycle_id=${id}`}>الكشوف</Link>
            <Button onClick={() => download(`reports/statements/${id}/print`, "statements.pdf")}>طباعة جميع الكشوف PDF</Button></>}
        </>} />
      <ErrorBox error={act.error} />
      <div className="stats">
        <Stat label="السعر المبدئي (تقديري)" value={x.provisional_rate_ils_per_kwh ?? "—"} />
        <Stat label="السعر النهائي" value={x.final_rate_ils_per_kwh ?? "لم يُثبت"} tone={x.final_rate_ils_per_kwh ? "ok" : undefined} />
        <Stat label="المهام (مفتوحة / الكل)" value={`${x.tasks_open} / ${x.tasks_total}`} tone={x.tasks_open ? "warn" : undefined} />
        <Stat label="قراءات معتمدة" value={x.approved_readings} />
        <Stat label="كشوف نهائية" value={x.statements} />
      </div>
      {x.state !== "closed" && b && (
        <Card title="عوائق الإغلاق">
          {blocked ? <ul>
            {b.unresolved_tasks > 0 && <li>مهام غير محسومة: <b>{b.unresolved_tasks}</b> — <Link href={`/tasks?cycle_id=${id}`}>عرض</Link></li>}
            {b.unresolved_visits > 0 && <li>زيارات بانتظار قرار المدير: <b>{b.unresolved_visits}</b> — <Link href={`/review?cycle_id=${id}`}>مراجعة</Link></li>}
            {b.open_error_reports > 0 && <li>بلاغات خطأ مفتوحة: <b>{b.open_error_reports}</b> — <Link href="/error-reports">عرض</Link></li>}
          </ul> : <div className="alert alert-ok">لا توجد عوائق للإغلاق.</div>}
        </Card>
      )}
      <Card title={est.data?.is_final ? "استهلاك الدورة — أرقام نهائية" : "استهلاك الدورة — تقديري"}
            actions={<><Button variant="ghost" onClick={() => download(`reports/consumption?format=xlsx&cycle_id=${id}`, "consumption.xlsx")}>Excel</Button><Button variant="ghost" onClick={() => download(`reports/consumption?format=pdf&cycle_id=${id}`, "consumption.pdf")}>PDF</Button></>}>
        {!est.data?.is_final && <p className="provisional">تقديري — غير نهائي. لا يُنتج مطالبة مالية أو ترحيل كسور حتى تثبيت السعر النهائي وإغلاق الدورة.</p>}
        {est.loading && !est.data ? <Loading /> : !est.data?.lines.length ? <Empty>لا توجد قراءات معتمدة في هذه الدورة.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>المشترك</th><th>المنطقة</th><th>تاريخ القراءة</th><th className="n">السابقة</th><th className="n">الحالية</th><th className="n">kWh</th><th className="n">التكلفة</th></tr></thead>
            <tbody>{est.data.lines.map((l: any) => (
              <tr key={l.reading_id}><td><Link href={`/subscribers/${l.subscriber_id}`}>{l.full_name}</Link> <span className="muted ltr">{l.subscription_no}</span></td><td>{l.zone_name}</td>
                <td>{dt(l.verified_captured_at)}</td><td className="n">{kwh(l.previous_value_kwh)}</td><td className="n">{kwh(l.current_value_kwh)}</td>
                <td className="n">{kwh(l.consumption_kwh)}</td><td className="n">{money(l.cost_ils)}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      {x.rate_history?.length > 0 && (
        <Card title="سجل الأسعار المبدئية اليومية">
          <div className="table-wrap"><table><thead><tr><th>ساري من</th><th className="n">السعر</th><th>السبب</th><th>بواسطة</th><th>وقت التسجيل</th></tr></thead>
            <tbody>{x.rate_history.map((r: any, i: number) => <tr key={i}><td>{d(r.effective_on)}</td><td className="n">{r.proposed_rate_ils_per_kwh}</td><td>{r.reason ?? ""}</td><td>{r.recorded_by}</td><td>{dt(r.recorded_at)}</td></tr>)}</tbody>
          </table></div>
        </Card>
      )}
      {dialog === "edit" && <CycleDialog cycle={x} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
      {dialog === "rate" && <RateDialog cycle={x} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
      {dialog === "finalize" && <FinalizeDialog cycle={x} blocked={blocked} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
    </div>
  );
}

function RateDialog({ cycle, onClose, onDone }: any) {
  const today = todayISO();
  const [rate, setRate] = useState("");
  const [on, setOn] = useState(today >= cycle.starts_on && today <= cycle.ends_on ? today : cycle.starts_on);
  const [reason, setReason] = useState("");
  const { busy, error, setError, run } = useAction();
  const err = rate ? checkDecimal(rate, RATE_RE, 6) : null;
  return (
    <Modal open onClose={onClose} title="سعر مبدئي (يومي)" footer={<><Button variant="primary" busy={busy} onClick={async () => {
      if (!rate || err) return setError({ message: err ?? "السعر مطلوب" });
      if (await run(() => api(`cycles/${cycle.id}/provisional-rate`, { body: { effective_on: on, rate_ils_per_kwh: rate.trim(), reason: reason || null } }), "سُجل السعر المبدئي")) onDone();
    }}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <p className="muted">السعر المبدئي للعرض التقديري فقط ويمكن تغييره يوميًا. لا يُنشئ أي حركة مالية.</p>
        <Field label="السعر ₪ لكل kWh" required error={err} hint="حتى 6 منازل عشرية"><input inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} /></Field>
        <Field label="ساري من تاريخ"><input type="date" min={cycle.starts_on} max={cycle.ends_on} value={on} onChange={(e) => setOn(e.target.value)} /></Field>
        <Field label="ملاحظة"><input value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function FinalizeDialog({ cycle, blocked, onClose, onDone }: any) {
  const [rate, setRate] = useState(cycle.provisional_rate_ils_per_kwh ?? "");
  const [confirm, setConfirm] = useState(false);
  const { busy, error, setError, run } = useAction();
  const err = rate ? checkDecimal(String(rate), RATE_RE, 6) : null;
  return (
    <Modal open onClose={onClose} title={`إغلاق ${cycle.label}`} footer={<><Button variant="primary" busy={busy} disabled={!confirm} onClick={async () => {
      if (!rate || err) return setError({ message: err ?? "السعر النهائي مطلوب" });
      if (await run(() => api(`cycles/${cycle.id}/finalize`, { body: { final_rate_ils_per_kwh: String(rate).trim(), confirm } }), "أُغلقت الدورة وصدرت الكشوف النهائية")) onDone();
    }}>تثبيت وإغلاق</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        {blocked && <div className="alert alert-warn">توجد عوائق إغلاق؛ سيرفض الخادم الإغلاق حتى حسمها.</div>}
        <div className="alert alert-info">سيُعاد احتساب جميع قراءات الدورة بالسعر النهائي، ويُصدر كشف واحد لكل مشترك، وتُقيَّد التكلفة الدقيقة في دفتر الحساب. <b>لا يمكن التراجع</b>؛ أي تصحيح لاحق يصبح تسوية مستقلة.</div>
        <Field label="السعر النهائي الموحّد ₪/kWh" required error={err}><input inputMode="decimal" value={rate} onChange={(e) => setRate(e.target.value)} /></Field>
        <label className="checkbox"><input type="checkbox" checked={confirm} onChange={(e) => setConfirm(e.target.checked)} /> راجعت القراءات وأؤكد الإغلاق النهائي</label>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
