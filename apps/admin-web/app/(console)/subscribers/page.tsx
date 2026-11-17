"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { api, qs, useQuery } from "@/lib/api";
import { checkDecimal, d, fromLocalInput, KWH_RE, money, toLocalInput } from "@/lib/format";
import { Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, Pager, useAction } from "@/components/ui";

export default function Subscribers() {
  const [q, setQ] = useState("");
  const [zone, setZone] = useState("");
  const [active, setActive] = useState("true");
  const [debtors, setDebtors] = useState(false);
  const [offset, setOffset] = useState(0);
  const [creating, setCreating] = useState(false);
  const gens = useQuery<any[]>("generators");
  const list = useQuery<any>(`subscribers${qs({ q, zone_id: zone, active, debtors, limit: 50, offset })}`);
  const zones = (gens.data ?? []).flatMap((g) => (g.zones ?? []).map((z: any) => ({ ...z, gen: g.name })));
  return (
    <div className="stack">
      <PageHeader title="المشتركون والعدادات" actions={<Button variant="primary" onClick={() => setCreating(true)}>+ مشترك جديد</Button>} />
      <Card>
        <div className="filters">
          <Field label="بحث (الاسم، رقم الاشتراك، العداد، الهاتف)"><input value={q} onChange={(e) => { setQ(e.target.value); setOffset(0); }} /></Field>
          <Field label="المنطقة"><select value={zone} onChange={(e) => { setZone(e.target.value); setOffset(0); }}>
            <option value="">الكل</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.gen} — {z.name}</option>)}
          </select></Field>
          <Field label="الحالة"><select value={active} onChange={(e) => { setActive(e.target.value); setOffset(0); }}>
            <option value="true">فعّال</option><option value="false">موقوف</option><option value="">الكل</option>
          </select></Field>
          <label className="checkbox"><input type="checkbox" checked={debtors} onChange={(e) => setDebtors(e.target.checked)} /> عليهم مستحقات فقط</label>
        </div>
        {list.loading && !list.data ? <Loading /> : list.error ? <ErrorBox error={list.error} /> : !list.data?.items.length ? <Empty>لا يوجد مشتركون مطابقون.</Empty> : (
          <>
            <div className="table-wrap"><table>
              <thead><tr><th>رقم الاشتراك</th><th>الاسم</th><th>المولد / المنطقة</th><th>العداد</th><th>فترة القراءة</th><th>الموعد القادم</th><th className="n">المطلوب</th><th className="n">رصيد دائن</th></tr></thead>
              <tbody>{list.data.items.map((s: any) => (
                <tr key={s.id}>
                  <td><Link href={`/subscribers/${s.id}`}>{s.subscription_no}</Link></td>
                  <td>{s.full_name} {!s.is_active && <span className="badge badge-muted">موقوف</span>}</td>
                  <td>{s.generator_name} / {s.zone_name}</td>
                  <td className="ltr">{s.meter_serial ?? <span className="badge badge-warn">بلا عداد</span>}</td>
                  <td>{s.interval_days ? `${s.interval_days} أيام` : "—"}</td>
                  <td>{d(s.next_due)}</td>
                  <td className="n">{money(s.requested_whole_ils)}</td>
                  <td className="n">{s.credit_balance_ils !== "0" ? money(s.credit_balance_ils) : "—"}</td>
                </tr>
              ))}</tbody>
            </table></div>
            <Pager total={list.data.total} limit={50} offset={offset} onChange={setOffset} />
          </>
        )}
      </Card>
      <CreateSubscriber open={creating} zones={zones} onClose={() => setCreating(false)} onDone={() => { setCreating(false); list.reload(); }} />
    </div>
  );
}

function CreateSubscriber({ open, zones, onClose, onDone }: { open: boolean; zones: any[]; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState<any>({ subscription_no: "", full_name: "", phone: "", address: "", zone_id: "", interval_days: "7", serial_no: "", meter_type: "digital", opening: "", installed_at: toLocalInput(new Date().toISOString()) });
  const { busy, error, setError, run } = useAction();

  useEffect(() => {
    if (open) {
      api<{ next_subscription_no: string }>("subscribers/next-number")
        .then((res) => {
          setF((prev: any) => ({
            ...prev,
            subscription_no: res?.next_subscription_no || "0001",
          }));
        })
        .catch(() => {
          setF((prev: any) => ({
            ...prev,
            subscription_no: prev.subscription_no || "0001",
          }));
        });
    }
  }, [open]);

  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.value });
  const openingErr = f.opening ? checkDecimal(f.opening, KWH_RE, 2) : null;
  async function save() {
    if (f.serial_no && (openingErr || !f.opening)) return setError({ message: openingErr || "القراءة الافتتاحية مطلوبة مع العداد" });
    const body: any = {
      subscription_no: f.subscription_no?.trim() || null,
      full_name: f.full_name,
      phone: f.phone || null,
      address: f.address || null,
      zone_id: f.zone_id,
      interval_days: Number(f.interval_days)
    };
    if (f.serial_no) body.meter = { serial_no: f.serial_no, meter_type: f.meter_type, installed_at: fromLocalInput(f.installed_at), opening_value_kwh: f.opening.trim() };
    const r = await run(() => api("subscribers", { body }), "تم إنشاء المشترك");
    if (r) onDone();
  }
  return (
    <Modal open={open} onClose={onClose} title="مشترك جديد" wide footer={<><Button variant="primary" busy={busy} onClick={save}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="form-grid">
        <Field label="رقم الاشتراك" required hint="تلقائي تسلسلي يبدأ من 0001 (قابل للتعديل)">
          <input value={f.subscription_no} onChange={set("subscription_no")} dir="ltr" placeholder="0001" />
        </Field>
        <Field label="الاسم الكامل" required><input value={f.full_name} onChange={set("full_name")} /></Field>
        <Field label="الهاتف"><input value={f.phone} onChange={set("phone")} dir="ltr" /></Field>
        <Field label="العنوان"><input value={f.address} onChange={set("address")} /></Field>
        <Field label="المولد / المنطقة" required hint="لكل مشترك مولد واحد ثابت"><select value={f.zone_id} onChange={set("zone_id")}>
          <option value="">— اختر —</option>{zones.filter((z) => z.is_active).map((z) => <option key={z.id} value={z.id}>{z.gen} — {z.name}</option>)}
        </select></Field>
        <Field label="فترة القراءة الافتراضية (أيام)" required><input type="number" min={1} max={366} value={f.interval_days} onChange={set("interval_days")} /></Field>
      </div>
      <h3 style={{ margin: "18px 0 8px" }}>العداد والقراءة الافتتاحية</h3>
      <p className="muted">القراءة الافتتاحية يدخلها المدير ولا تُنتج أي مطالبة مالية. يمكن تركيب العداد لاحقًا.</p>
      <div className="form-grid">
        <Field label="رقم العداد"><input value={f.serial_no} onChange={set("serial_no")} dir="ltr" /></Field>
        <Field label="النوع"><select value={f.meter_type} onChange={set("meter_type")}><option value="digital">رقمي</option><option value="mechanical">ميكانيكي</option></select></Field>
        <Field label="القراءة الافتتاحية kWh" error={openingErr} hint="منزلتان عشريتان كحد أقصى"><input inputMode="decimal" value={f.opening} onChange={set("opening")} /></Field>
        <Field label="تاريخ التركيب"><input type="datetime-local" value={f.installed_at} onChange={set("installed_at")} /></Field>
      </div>
      <ErrorBox error={error} />
    </Modal>
  );
}
