"use client";
import Link from "next/link";
import { use, useState } from "react";
import { api, newKey, useQuery } from "@/lib/api";
import { checkDecimal, d, dt, fromLocalInput, kwh, KWH_RE, money, MONEY_RE, toLocalInput, todayISO } from "@/lib/format";
import { EVENT_KIND, LEDGER_SOURCE, VISIT_STATUS } from "@/lib/labels";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, Stat, StatusBadge, useAction } from "@/components/ui";
import PaymentDialog from "@/components/PaymentDialog";
import { ReasonDialog } from "@/components/ReasonDialog";

export default function SubscriberPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const s = useQuery<any>(`subscribers/${id}`);
  const ledger = useQuery<any>(`subscribers/${id}/ledger`);
  const [tab, setTab] = useState("readings");
  const [dialog, setDialog] = useState<string | null>(null);
  const [correcting, setCorrecting] = useState<any>(null);
  if (s.loading && !s.data) return <Loading />;
  if (s.error) return <ErrorBox error={s.error} />;
  const x = s.data;
  if (!x) return null;
  const reload = () => { s.reload(); ledger.reload(); };
  const close = () => setDialog(null);
  const done = () => { setDialog(null); reload(); };
  return (
    <div className="stack">
      <PageHeader
        title={`${x.full_name}`}
        subtitle={<>رقم الاشتراك <b>{x.subscription_no}</b> — {x.generator_name} / {x.zone_name} {!x.is_active && <Badge tone="muted">موقوف: {x.stop_reason}</Badge>}</>}
        actions={<>
          <Button onClick={() => setDialog("edit")}>تعديل البيانات</Button>
          <Button onClick={() => setDialog("schedule")}>الجدولة</Button>
          {x.installation_id ? <Button onClick={() => setDialog("replace")}>استبدال/تصفير العداد</Button> : <Button variant="primary" onClick={() => setDialog("install")}>تركيب عداد</Button>}
          <Button variant="primary" onClick={() => setDialog("pay")}>تسجيل دفعة</Button>
          {x.is_active ? <Button variant="danger" onClick={() => setDialog("stop")}>إيقاف الاشتراك</Button> : <Button onClick={() => setDialog("reactivate")}>إعادة التفعيل</Button>}
        </>}
      />
      <div className="stats">
        <Stat label="المطلوب (شيكل صحيح)" value={money(x.account.requested_whole_ils)} tone={x.account.requested_whole_ils !== "0" ? "warn" : undefined} />
        <Stat label="الرصيد الدقيق" value={money(x.account.balance_exact_ils)} />
        <Stat label="كسر مرحّل" value={money(x.account.carry_fraction_ils)} />
        <Stat label="رصيد دائن" value={money(x.account.credit_balance_ils)} tone={x.account.credit_balance_ils !== "0" ? "ok" : undefined} />
        <Stat label="إجمالي المدفوع" value={money(x.account.total_paid_ils)} />
        <Stat label="الموعد القادم" value={d(x.next_due)} />
      </div>
      <Card>
        <dl className="kv">
          <dt>الهاتف</dt><dd className="ltr">{x.phone || "—"}</dd>
          <dt>العنوان</dt><dd>{x.address || "—"}</dd>
          <dt>العداد الحالي</dt><dd><span className="ltr">{x.meter_serial ?? "—"}</span> {x.meter_type && <span className="muted">({x.meter_type === "digital" ? "رقمي" : "ميكانيكي"})</span>}</dd>
          <dt>فترة القراءة</dt><dd>{x.interval_days ?? "—"} أيام {x.next_due_override && <Badge tone="info">موعد معدّل يدويًا: {d(x.next_due_override)}</Badge>}</dd>
        </dl>
      </Card>
      <div className="tabs">
        {[["readings", "القراءات المعتمدة"], ["visits", "الزيارات الخام"], ["ledger", "دفتر الحساب"], ["meters", "سجل العدادات"]].map(([k, l]) => (
          <button key={k} className={tab === k ? "on" : ""} onClick={() => setTab(k)}>{l}</button>
        ))}
      </div>
      {tab === "readings" && (
        <Card>
          {!x.readings.length ? <Empty>لا توجد قراءات معتمدة بعد.</Empty> : (
            <div className="table-wrap"><table>
              <thead><tr><th>تاريخ القراءة</th><th>الدورة</th><th className="n">السابقة</th><th className="n">الحالية</th><th className="n">الاستهلاك</th><th>الحالة</th><th></th></tr></thead>
              <tbody>{x.readings.map((r: any) => (
                <tr key={r.id} style={r.state !== "active" ? { opacity: 0.55 } : undefined}>
                  <td>{dt(r.verified_captured_at)}</td><td>{r.cycle_label}</td>
                  <td className="n">{kwh(r.previous_value_kwh)}</td><td className="n">{kwh(r.current_value_kwh)}</td><td className="n">{kwh(r.consumption_kwh)}</td>
                  <td>{r.state === "active" ? (r.billed ? <Badge tone="info">مفوترة</Badge> : <Badge tone="ok">فعالة</Badge>) : <Badge tone="muted">{r.state === "superseded" ? "مستبدلة بتصحيح" : "ملغاة"}</Badge>}</td>
                  <td>{r.state === "active" && <Button variant="ghost" onClick={() => setCorrecting(r)}>تصحيح</Button>}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
        </Card>
      )}
      {tab === "visits" && (
        <Card>
          {!x.visits.length ? <Empty>لا توجد زيارات.</Empty> : (
            <div className="table-wrap"><table>
              <thead><tr><th>وقت الالتقاط (الجهاز)</th><th>النوع</th><th className="n">القيمة</th><th>الموظف</th><th>الحالة</th><th></th></tr></thead>
              <tbody>{x.visits.map((v: any) => (
                <tr key={v.id}><td>{dt(v.captured_at_device)}</td><td>{EVENT_KIND[v.event_kind]}</td><td className="n">{kwh(v.reading_value_kwh)}</td>
                  <td>{v.employee_name}</td><td><StatusBadge map={VISIT_STATUS} value={v.record_status} /></td><td><Link href={`/review/${v.id}`}>فتح</Link></td></tr>
              ))}</tbody>
            </table></div>
          )}
        </Card>
      )}
      {tab === "ledger" && (
        <Card actions={<><Button onClick={() => setDialog("adjust")}>تسوية يدوية</Button>{x.account.opening_receivable_ils === "0" && <Button onClick={() => setDialog("opening")}>رصيد افتتاحي</Button>}</>}
              title="دفتر الحساب (append-only)">
          {ledger.loading ? <Loading /> : !ledger.data?.entries.length ? <Empty>لا توجد حركات مالية.</Empty> : (
            <div className="table-wrap"><table>
              <thead><tr><th>#</th><th>التاريخ</th><th>النوع</th><th>البيان</th><th className="n">المبلغ</th><th className="n">الرصيد</th></tr></thead>
              <tbody>{ledger.data.entries.map((e: any) => (
                <tr key={e.seq}><td>{e.seq}</td><td>{dt(e.posted_at)}</td><td>{LEDGER_SOURCE[e.source_type]}</td><td>{e.description}</td>
                  <td className="n">{money(e.signed_amount_ils)}</td><td className="n">{money(e.running_balance_ils)}</td></tr>
              ))}</tbody>
            </table></div>
          )}
          <p className="muted">الموجب = مستحق على المشترك، السالب = دفعة أو رصيد لصالحه. المطلوب = الجزء الصحيح من الرصيد الموجب، والكسر يرحّل تلقائيًا.</p>
        </Card>
      )}
      {tab === "meters" && (
        <Card>
          <div className="table-wrap"><table>
            <thead><tr><th>العداد</th><th>النوع</th><th>التركيب</th><th>الإزالة</th><th className="n">الافتتاحية</th><th>السبب</th></tr></thead>
            <tbody>{x.installations.map((i: any) => (
              <tr key={i.id}><td className="ltr">{i.serial_no}</td><td>{{ initial: "أول تركيب", replacement: "استبدال", reset: "تصفير" }[i.kind as string]}</td>
                <td>{dt(i.installed_at)}</td><td>{i.removed_at ? dt(i.removed_at) : <Badge tone="ok">حالي</Badge>}</td>
                <td className="n">{kwh(i.opening_value_kwh)}</td><td>{i.removal_reason ?? ""}</td></tr>
            ))}</tbody>
          </table></div>
        </Card>
      )}

      {dialog === "edit" && <EditDialog open s={x} onClose={close} onDone={done} />}
      {dialog === "schedule" && <ScheduleDialog open s={x} onClose={close} onDone={done} />}
      {(dialog === "install" || dialog === "replace") && <MeterDialog open mode={dialog} s={x} onClose={close} onDone={done} />}
      <ReasonDialog open={dialog === "stop"} title="إيقاف الاشتراك" note="تُلغى المهام المفتوحة، وتبقى المديونية والتاريخ محفوظين. الزيارات المعلقة يجب حسمها أولًا."
        onClose={close} onSubmit={(reason) => api(`subscribers/${id}/stop`, { body: { reason } })} onDone={done} />
      <ReasonDialog open={dialog === "reactivate"} title="إعادة تفعيل الاشتراك" noReason onClose={close} onSubmit={() => api(`subscribers/${id}/reactivate`, { method: "POST" })} onDone={done} />
      {dialog === "pay" && <PaymentDialog open subscriber={x} onClose={close} onDone={done} />}
      {dialog === "adjust" && <AdjustDialog open s={x} onClose={close} onDone={done} />}
      {dialog === "opening" && <OpeningDialog open s={x} onClose={close} onDone={done} />}
      <CorrectDialog reading={correcting} onClose={() => setCorrecting(null)} onDone={() => { setCorrecting(null); reload(); }} />
    </div>
  );
}

function EditDialog({ open, s, onClose, onDone }: any) {
  const gens = useQuery<any[]>(open ? "generators" : null);
  const [f, setF] = useState({ full_name: s.full_name, phone: s.phone ?? "", address: s.address ?? "", notes: "", zone_id: s.zone_id });
  const { busy, error, run } = useAction();
  const zones = (gens.data ?? []).filter((g) => g.id === s.generator_id).flatMap((g) => g.zones ?? []);
  return (
    <Modal open={open} onClose={onClose} title="تعديل بيانات المشترك" footer={<><Button variant="primary" busy={busy} onClick={async () => (await run(() => api(`subscribers/${s.id}`, { method: "PATCH", body: f }), "تم الحفظ")) && onDone()}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="الاسم"><input value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>
        <Field label="الهاتف"><input dir="ltr" value={f.phone} onChange={(e) => setF({ ...f, phone: e.target.value })} /></Field>
        <Field label="العنوان"><input value={f.address} onChange={(e) => setF({ ...f, address: e.target.value })} /></Field>
        <Field label="المنطقة" hint="ضمن المولد نفسه فقط"><select value={f.zone_id} onChange={(e) => setF({ ...f, zone_id: e.target.value })}>{zones.map((z: any) => <option key={z.id} value={z.id}>{z.name}</option>)}</select></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function ScheduleDialog({ open, s, onClose, onDone }: any) {
  const [interval, setInterval] = useState(String(s.interval_days ?? 7));
  const [override, setOverride] = useState(s.next_due_override ?? "");
  const { busy, error, run } = useAction();
  return (
    <Modal open={open} onClose={onClose} title="جدولة القراءة" footer={<><Button variant="primary" busy={busy} onClick={async () => (await run(() => api(`subscribers/${s.id}/schedule`, { method: "PUT", body: { interval_days: Number(interval), next_due_override: override || null } }), "تم الحفظ")) && onDone()}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <p className="muted">الموعد القادم = تاريخ آخر قراءة معتمدة + الفترة، ما لم يحدد المدير موعدًا آخر.</p>
        <Field label="الفترة (أيام)"><input type="number" min={1} max={366} value={interval} onChange={(e) => setInterval(e.target.value)} /></Field>
        <Field label="تعديل الموعد القادم (اختياري)"><input type="date" value={override} onChange={(e) => setOverride(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function MeterDialog({ open, mode, s, onClose, onDone }: any) {
  const [f, setF] = useState<any>({ kind: "replacement", serial: "", type: "digital", at: toLocalInput(new Date().toISOString()), opening: "", reason: "", incident: "" });
  const { busy, error, setError, run } = useAction();
  const oe = f.opening ? checkDecimal(f.opening, KWH_RE, 2) : null;
  async function save() {
    if (!f.opening || oe) return setError({ message: oe ?? "القراءة الافتتاحية مطلوبة" });
    const r = mode === "install"
      ? await run(() => api(`subscribers/${s.id}/meter`, { body: { serial_no: f.serial, meter_type: f.type, installed_at: fromLocalInput(f.at), opening_value_kwh: f.opening.trim() } }), "تم تركيب العداد")
      : await run(() => api(`subscribers/${s.id}/replace-meter`, { body: { kind: f.kind, effective_at: fromLocalInput(f.at), reason: f.reason, new_serial_no: f.kind === "replacement" ? f.serial : null, new_meter_type: f.kind === "replacement" ? f.type : null, new_opening_value_kwh: f.opening.trim(), incident_visit_id: f.incident || null } }), "تم تسجيل العداد الجديد");
    if (r) onDone();
  }
  return (
    <Modal open={open} onClose={onClose} title={mode === "install" ? "تركيب عداد" : "استبدال أو تصفير العداد"} footer={<><Button variant="primary" busy={busy} onClick={save}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        {mode === "replace" && <>
          <div className="alert alert-info">يُغلق التركيب الحالي ويبدأ تسلسل قراءات جديد بقراءة افتتاحية. لا يُحتسب استهلاك غير مقروء على العداد القديم — اعتمد قراءة ختامية قبل الاستبدال إن لزم.</div>
          <Field label="الإجراء"><select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}><option value="replacement">استبدال بعداد جديد</option><option value="reset">تصفير العداد نفسه</option></select></Field>
          <Field label="السبب" required><input value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} /></Field>
        </>}
        {(mode === "install" || f.kind === "replacement") && <div className="grid grid-2">
          <Field label="رقم العداد" required><input dir="ltr" value={f.serial} onChange={(e) => setF({ ...f, serial: e.target.value })} /></Field>
          <Field label="النوع"><select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="digital">رقمي</option><option value="mechanical">ميكانيكي</option></select></Field>
        </div>}
        <div className="grid grid-2">
          <Field label="القراءة الافتتاحية للعداد kWh" required error={oe}><input inputMode="decimal" value={f.opening} onChange={(e) => setF({ ...f, opening: e.target.value })} /></Field>
          <Field label="التاريخ والوقت"><input type="datetime-local" value={f.at} onChange={(e) => setF({ ...f, at: e.target.value })} /></Field>
        </div>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function AdjustDialog({ open, s, onClose, onDone }: any) {
  const [amount, setAmount] = useState("");
  const [reason, setReason] = useState("");
  const [key] = useState(newKey);
  const { busy, error, setError, run } = useAction();
  const err = amount ? checkDecimal(amount, MONEY_RE, 2) : null;
  return (
    <Modal open={open} onClose={onClose} title="تسوية يدوية موثقة" footer={<><Button variant="primary" busy={busy} onClick={async () => {
      if (!amount || err || amount.trim() === "0") return setError({ message: err ?? "المبلغ مطلوب وغير صفري" });
      if (await run(() => api("adjustments", { body: { subscriber_id: s.id, amount_ils: amount.trim(), reason, idempotency_key: key } }), "سُجلت التسوية")) onDone();
    }}>تسجيل</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <p className="muted">موجب = مبلغ إضافي على المشترك. سالب (مثل ‎-8) = لصالح المشترك ويتحول لرصيد دائن يُستهلك تلقائيًا. لا يُعدّل أي كشف سابق.</p>
        <Field label="المبلغ ₪" required error={err}><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
        <Field label="السبب" required><textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function OpeningDialog({ open, s, onClose, onDone }: any) {
  const [amount, setAmount] = useState("");
  const [asOf, setAsOf] = useState(todayISO());
  const [just, setJust] = useState("");
  const { busy, error, setError, run } = useAction();
  const err = amount ? checkDecimal(amount, MONEY_RE, 2) : null;
  return (
    <Modal open={open} onClose={onClose} title="رصيد افتتاحي من مستند معتمد" footer={<><Button variant="primary" busy={busy} onClick={async () => {
      if (!amount || err) return setError({ message: err ?? "المبلغ مطلوب" });
      if (await run(() => api("opening-receivables", { body: { subscriber_id: s.id, amount_ils: amount.trim(), as_of: asOf, justification: just } }), "سُجل الرصيد الافتتاحي")) onDone();
    }}>تسجيل</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <div className="alert alert-warn">يُسجل مرة واحدة لكل مشترك، ومن مستند أو ملف Excel معتمد فقط. لا تُدخل أرصدة تقديرية.</div>
        <Field label="المبلغ ₪ (موجب = دين، سالب = رصيد دائن)" required error={err}><input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} /></Field>
        <Field label="بتاريخ"><input type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></Field>
        <Field label="المستند/المبرر" required><textarea rows={2} value={just} onChange={(e) => setJust(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function CorrectDialog({ reading, onClose, onDone }: any) {
  const [value, setValue] = useState("");
  const [reason, setReason] = useState("");
  const [key, setKey] = useState(newKey);
  const { busy, error, setError, run } = useAction();
  const err = value ? checkDecimal(value, KWH_RE, 2) : null;
  if (!reading) return null;
  return (
    <Modal open onClose={onClose} title="تصحيح قراءة معتمدة" footer={<><Button variant="primary" busy={busy} onClick={async () => {
      if (!value || err) return setError({ message: err ?? "القيمة مطلوبة" });
      const r: any = await run(() => api(`readings/${reading.id}/correct`, { body: { new_value_kwh: value.trim(), rationale: reason, idempotency_key: key } }), "تم التصحيح");
      if (r) { setKey(newKey()); onDone(); }
    }}>تأكيد التصحيح</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <p>القيمة الحالية: <b className="num">{kwh(reading.current_value_kwh)}</b> — {reading.billed ? <Badge tone="info">مفوترة في دورة مغلقة</Badge> : <Badge tone="ok">دورة مفتوحة</Badge>}</p>
        <div className="alert alert-info">لا يُحذف شيء: تُستبدل القراءة وما بعدها بنسخ جديدة. إن كانت في دورة مغلقة يُسجل الفرق كتسوية مستقلة مرة واحدة دون تعديل الكشف.</div>
        <Field label="القيمة الصحيحة kWh" required error={err}><input inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} /></Field>
        <Field label="السبب (من الصورة)" required><textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
