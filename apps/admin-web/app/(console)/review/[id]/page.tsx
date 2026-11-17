"use client";
import Link from "next/link";
import { use, useState } from "react";
import { api, photoSrc, useQuery } from "@/lib/api";
import { checkDecimal, dt, fromLocalInput, kwh, KWH_RE, money, toLocalInput, todayISO } from "@/lib/format";
import { DECISION, EVENT_KIND, FLAGS, TIME_STATUS, VISIT_STATUS } from "@/lib/labels";
import { Badge, Button, Card, ErrorBox, Field, Loading, Modal, PageHeader, StatusBadge, useAction } from "@/components/ui";

const OPEN = ["awaiting_photo", "pending_review", "exception"];

export default function VisitPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const v = useQuery<any>(`visits/${id}`);
  const users = useQuery<any[]>("users?role=employee");
  const [zoom, setZoom] = useState<string | null>(null);
  const [dialog, setDialog] = useState<string | null>(null);
  const [photoSeen, setPhotoSeen] = useState(false);
  if (v.loading && !v.data) return <Loading />;
  if (v.error) return <ErrorBox error={v.error} />;
  const x = v.data;
  if (!x) return null;
  const isOpen = OPEN.includes(x.record_status);
  const timeOk = ["consistent", "corrected"].includes(x.timestamp_status);
  const done = () => { setDialog(null); v.reload(); };
  return (
    <div className="stack">
      <PageHeader title={`${EVENT_KIND[x.event_kind]} — ${x.subscriber_name}`}
        subtitle={<><Link href={`/subscribers/${x.subscriber_id}`}>{x.subscription_no}</Link> — {x.generator_name} / {x.zone_name} — العداد <span className="ltr">{x.meter_serial}</span></>}
        actions={<StatusBadge map={VISIT_STATUS} value={x.record_status} />} />
      {x.flags?.length > 0 && (
        <div className="alert alert-danger">
          <strong>استثناءات تحتاج قرارًا موثقًا من المدير:</strong>
          <ul>{x.flags.map((f: string) => <li key={f}>{FLAGS[f] ?? f}</li>)}</ul>
        </div>
      )}
      <div className="grid grid-2">
        <Card title="الصور">
          {x.photos.length === 0 ? <div className="alert alert-warn">لم تصل صورة بعد — لا يمكن اعتماد الزيارة دون صورة أساسية سليمة.</div> : (
            <div className="photo-grid">{x.photos.map((p: any) => (
              <figure key={p.id}>
                {p.url ? <img src={photoSrc(p.url)} alt={p.is_primary ? "صورة العداد الأساسية" : "صورة إضافية"} onClick={() => { setZoom(photoSrc(p.url)); setPhotoSeen(true); }} onLoad={() => p.is_primary && setPhotoSeen(true)} />
                  : <div className="empty">الصورة {p.state === "failed" ? "فشل التحقق منها" : "قيد الرفع"}</div>}
                <figcaption>{p.is_primary ? "أساسية" : "إضافية"} — {p.state === "ready" ? "تم التحقق (SHA-256)" : p.state}</figcaption>
              </figure>
            ))}</div>
          )}
        </Card>
        <Card title="البيانات">
          {x.event_kind === "reading" ? (
            <>
              <div className="row gap-lg">
                <div><div className="muted">القراءة المسجلة</div><span className="reading-big">{kwh(x.reading_value_kwh)}</span></div>
                <div><div className="muted">آخر قراءة معتمدة/افتتاحية</div><span className="reading-big" style={{ fontSize: "1.4rem" }}>{kwh(x.previous_value_kwh)}</span></div>
              </div>
              {x.provisional && <p className="provisional">الاستهلاك {kwh(x.provisional.consumption_kwh)} kWh — التكلفة {x.provisional.cost_ils ? money(x.provisional.cost_ils) : "—"} ({x.provisional.label})</p>}
            </>
          ) : <p><b>السبب:</b> {x.reason}</p>}
          <dl className="kv" style={{ marginTop: 12 }}>
            <dt>الموظف</dt><dd>{x.employee_name}</dd>
            <dt>وقت الالتقاط حسب الهاتف</dt><dd>{dt(x.captured_at_device)}</dd>
            <dt>الوقت الموثّق</dt><dd>{x.verified_captured_at ? dt(x.verified_captured_at) : "—"} <StatusBadge map={TIME_STATUS} value={x.timestamp_status} /></dd>
            <dt>وصلت للخادم</dt><dd>{dt(x.received_at)}</dd>
            <dt>المهمة</dt><dd>{x.task_id ? "مرتبطة بمهمة" : "زيارة إضافية"} {x.reason && x.event_kind === "reading" && <span className="muted">— {x.reason}</span>}</dd>
            {x.note && <><dt>ملاحظة</dt><dd>{x.note}</dd></>}
            {x.incident && <><dt>بلاغ العداد</dt><dd>{x.incident.category}: {x.incident.notes}</dd></>}
          </dl>
          {isOpen && (
            <div className="row gap" style={{ marginTop: 16 }}>
              {x.event_kind === "reading" && <Button variant="primary" disabled={!timeOk} onClick={() => setDialog("approve")}>اعتماد / تصحيح</Button>}
              {x.event_kind === "unreadable" && <Button variant="primary" onClick={() => setDialog("unreadable")}>إغلاق دون استهلاك</Button>}
              {x.event_kind === "meter_incident" && <><Button variant="primary" onClick={() => setDialog("incident")}>حسم البلاغ</Button><Link className="btn" href={`/subscribers/${x.subscriber_id}`}>استبدال/تصفير العداد</Link></>}
              <Button onClick={() => setDialog("time")}>توثيق الوقت</Button>
              <Button onClick={() => setDialog("revisit")}>طلب إعادة زيارة</Button>
              <Button variant="danger" onClick={() => setDialog("reject")}>رفض / مكررة</Button>
            </div>
          )}
          {isOpen && !timeOk && x.event_kind === "reading" && <p className="alert alert-warn">يجب توثيق وقت القراءة أولًا (وقت الهاتف غير موثوق تلقائيًا).</p>}
        </Card>
      </div>
      {(x.reviews.length > 0 || x.error_reports.length > 0) && (
        <Card title="سجل القرارات والبلاغات">
          <ul>
            {x.reviews.map((r: any, i: number) => <li key={i}>{dt(r.reviewed_at)} — <b>{DECISION[r.decision] ?? r.decision}</b> بواسطة {r.reviewer}{r.corrected_value_kwh && <> — القيمة <span className="num">{kwh(r.corrected_value_kwh)}</span></>}{r.rationale && <> — {r.rationale}</>}</li>)}
            {x.error_reports.map((e: any) => <li key={e.id}>{dt(e.submitted_at)} — <Badge tone="warn">بلاغ الموظف</Badge> {e.explanation} {e.acknowledged_at && <span className="muted">(عولج: {e.resolution_note})</span>}</li>)}
          </ul>
        </Card>
      )}
      <Modal open={!!zoom} onClose={() => setZoom(null)} title="صورة العداد" wide>{zoom && <img className="zoom" src={zoom} alt="صورة العداد مكبرة" />}</Modal>
      {dialog === "approve" && <ApproveDialog x={x} photoSeen={photoSeen} onClose={() => setDialog(null)} onDone={done} />}
      {dialog === "reject" && <SimpleDialog title="رفض الزيارة" onClose={() => setDialog(null)} onDone={done} extra={(s: any, set: any) => (
        <Field label="القرار"><select value={s.decision ?? "reject"} onChange={(e) => set({ ...s, decision: e.target.value })}><option value="reject">رفض</option><option value="duplicate">مكررة</option></select></Field>
      )} submit={(s: any) => api(`visits/${id}/reject`, { body: { decision: s.decision ?? "reject", rationale: s.reason } })} />}
      {dialog === "revisit" && <SimpleDialog title="طلب إعادة زيارة" onClose={() => setDialog(null)} onDone={done} extra={(s: any, set: any) => (<>
        <Field label="الموعد" required><input type="date" value={s.date ?? todayISO()} onChange={(e) => set({ ...s, date: e.target.value })} /></Field>
        <Field label="الموظف"><select value={s.emp ?? ""} onChange={(e) => set({ ...s, emp: e.target.value })}><option value="">الموظف نفسه</option>{(users.data ?? []).map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</select></Field>
      </>)} submit={(s: any) => api(`visits/${id}/revisit`, { body: { planned_for: s.date ?? todayISO(), employee_id: s.emp || null, rationale: s.reason } })} />}
      {dialog === "unreadable" && <SimpleDialog title="إغلاق التعذر دون استهلاك" note="لا يُحتسب أي مبلغ. حدّد موعد المتابعة؛ إن وقع في أسبوع آخر تتبع المهمة ذلك الأسبوع." optionalReason onClose={() => setDialog(null)} onDone={done} extra={(s: any, set: any) => (
        <Field label="موعد المتابعة" required><input type="date" value={s.date ?? ""} onChange={(e) => set({ ...s, date: e.target.value })} /></Field>
      )} submit={(s: any) => api(`visits/${id}/resolve-unreadable`, { body: { followup_due: s.date, rationale: s.reason || null } })} />}
      {dialog === "incident" && <SimpleDialog title="حسم بلاغ العداد دون استبدال" onClose={() => setDialog(null)} onDone={done} submit={(s: any) => api(`visits/${id}/resolve-incident`, { body: { note: s.reason } })} />}
      {dialog === "time" && <SimpleDialog title="توثيق وقت القراءة" note="الوقت الموثّق يحدد دورة السعر. إن اختلف عن وقت الهاتف يُسجل كتصحيح موثق." optionalReason={x.timestamp_status !== "suspicious"} onClose={() => setDialog(null)} onDone={done} extra={(s: any, set: any) => (
        <Field label="الوقت الموثّق"><input type="datetime-local" value={s.at ?? toLocalInput(x.verified_captured_at ?? x.captured_at_device)} onChange={(e) => set({ ...s, at: e.target.value })} /></Field>
      )} submit={(s: any) => api(`visits/${id}/verify-time`, { body: { verified_captured_at: fromLocalInput(s.at ?? toLocalInput(x.verified_captured_at ?? x.captured_at_device)), reason: s.reason || null } })} />}
    </div>
  );
}

function ApproveDialog({ x, photoSeen, onClose, onDone }: any) {
  const [corrected, setCorrected] = useState("");
  const [rationale, setRationale] = useState("");
  const [ack, setAck] = useState(false);
  const [late, setLate] = useState(false);
  const [seen, setSeen] = useState(photoSeen);
  const { busy, error, setError, run } = useAction();
  const err = corrected ? checkDecimal(corrected, KWH_RE, 2) : null;
  const flagged = x.flags?.length > 0;
  const closedCycle = x.flags?.includes("cycle_closed");
  async function go() {
    if (err) return setError({ message: err });
    const r = await run(() => api(`visits/${x.id}/approve`, { body: { corrected_value_kwh: corrected.trim() || null, rationale: rationale || null, acknowledge_exceptions: ack, accept_late: late, photo_reviewed: seen } }), "اعتُمدت القراءة");
    if (r) onDone();
  }
  return (
    <Modal open onClose={onClose} title="اعتماد القراءة" footer={<><Button variant="primary" busy={busy} disabled={!seen} onClick={go}>اعتماد</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <p>القيمة المسجلة من الهاتف: <b className="num">{kwh(x.reading_value_kwh)}</b></p>
        <Field label="تصحيح القيمة من الصورة (اختياري)" error={err} hint="القيمة الخام الأصلية تبقى محفوظة"><input inputMode="decimal" value={corrected} onChange={(e) => setCorrected(e.target.value)} /></Field>
        <Field label={corrected || flagged || closedCycle ? "السبب (إلزامي)" : "ملاحظة"}><textarea rows={2} value={rationale} onChange={(e) => setRationale(e.target.value)} /></Field>
        {flagged && <label className="checkbox"><input type="checkbox" checked={ack} onChange={(e) => setAck(e.target.checked)} /> راجعت الاستثناءات وأقرّ بقبول القراءة</label>}
        {closedCycle && <label className="checkbox"><input type="checkbox" checked={late} onChange={(e) => setLate(e.target.checked)} /> قبول كقراءة متأخرة: تُسجل تكلفتها كتسوية مستقلة دون فتح الدورة المغلقة</label>}
        <label className="checkbox"><input type="checkbox" checked={seen} onChange={(e) => setSeen(e.target.checked)} /> راجعت صورة العداد</label>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function SimpleDialog({ title, note, optionalReason, extra, submit, onClose, onDone }: any) {
  const [s, set] = useState<any>({ reason: "" });
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title={title} footer={<><Button variant="primary" busy={busy} disabled={!optionalReason && !s.reason.trim()} onClick={async () => (await run(() => submit(s), "تم حفظ القرار")) && onDone()}>تأكيد</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        {note && <p className="muted">{note}</p>}
        {extra && extra(s, set)}
        <Field label={optionalReason ? "ملاحظة" : "السبب"} required={!optionalReason}><textarea rows={3} value={s.reason} onChange={(e) => set({ ...s, reason: e.target.value })} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
