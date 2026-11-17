"use client";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { api, qs, useQuery } from "@/lib/api";
import { d } from "@/lib/format";
import { TASK_SOURCE, TASK_STATUS } from "@/lib/labels";
import { Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, StatusBadge, useAction } from "@/components/ui";
import { ReasonDialog } from "@/components/ReasonDialog";

function Tasks() {
  const sp = useSearchParams();
  const cycles = useQuery<any[]>("cycles");
  const users = useQuery<any[]>("users?role=employee");
  const gens = useQuery<any[]>("generators");
  const [cycle, setCycle] = useState(sp.get("cycle_id") ?? "");
  const [status, setStatus] = useState("");
  const [emp, setEmp] = useState("");
  const [zone, setZone] = useState("");
  const [unassigned, setUn] = useState(false);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [dialog, setDialog] = useState<any>(null);
  useEffect(() => {
    if (!cycle && cycles.data?.length) setCycle((cycles.data.find((c) => c.state === "open") ?? cycles.data[0]).id);
  }, [cycles.data, cycle]);
  const t = useQuery<any>(cycle ? `tasks${qs({ cycle_id: cycle, status, employee_id: emp, zone_id: zone, unassigned, limit: 500 })}` : null);
  const zones = (gens.data ?? []).flatMap((g) => (g.zones ?? []).map((z: any) => ({ ...z, gen: g.name })));
  const open = (x: any) => ["assigned", "in_progress"].includes(x.status);
  const toggle = (id: string) => setSel((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const reload = () => { setSel(new Set()); t.reload(); };
  return (
    <div className="stack">
      <PageHeader title="المهام والتكليفات" actions={<Button variant="primary" disabled={!cycle} onClick={() => setDialog({ kind: "new" })}>+ مهمة استثنائية</Button>} />
      <Card>
        <div className="filters">
          <Field label="الدورة"><select value={cycle} onChange={(e) => setCycle(e.target.value)}>{(cycles.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.label} ({c.state === "open" ? "مفتوحة" : c.state === "draft" ? "مسودة" : "مغلقة"})</option>)}</select></Field>
          <Field label="الحالة"><select value={status} onChange={(e) => setStatus(e.target.value)}><option value="">الكل</option>{Object.entries(TASK_STATUS).map(([k, [l]]) => <option key={k} value={k}>{l}</option>)}</select></Field>
          <Field label="الموظف"><select value={emp} onChange={(e) => setEmp(e.target.value)}><option value="">الكل</option>{(users.data ?? []).map((u) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</select></Field>
          <Field label="المنطقة"><select value={zone} onChange={(e) => setZone(e.target.value)}><option value="">الكل</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.gen} — {z.name}</option>)}</select></Field>
          <label className="checkbox"><input type="checkbox" checked={unassigned} onChange={(e) => setUn(e.target.checked)} /> غير مكلّفة فقط</label>
        </div>
        {sel.size > 0 && <div className="row gap" style={{ marginBottom: 10 }}><b>{sel.size} محددة</b><Button variant="primary" onClick={() => setDialog({ kind: "assign", ids: [...sel] })}>تكليف موظف</Button></div>}
        {t.loading && !t.data ? <Loading /> : t.error ? <ErrorBox error={t.error} /> : !t.data?.items.length ? <Empty>لا توجد مهام مطابقة.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th><input type="checkbox" aria-label="تحديد الكل" onChange={(e) => setSel(e.target.checked ? new Set(t.data.items.filter(open).map((x: any) => x.id)) : new Set())} /></th>
              <th>الموعد</th><th>المشترك</th><th>المنطقة</th><th>المصدر</th><th>الموظف</th><th>الحالة</th><th></th></tr></thead>
            <tbody>{t.data.items.map((x: any) => (
              <tr key={x.id}>
                <td>{open(x) && <input type="checkbox" checked={sel.has(x.id)} onChange={() => toggle(x.id)} />}</td>
                <td>{d(x.planned_for)}</td><td><Link href={`/subscribers/${x.subscriber_id}`}>{x.subscriber_name}</Link> <span className="muted ltr">{x.subscription_no}</span></td>
                <td>{x.zone_name}</td><td>{TASK_SOURCE[x.source]}{x.parent_task_id && <span className="muted"> (متابعة)</span>}</td>
                <td>{x.employee_name ?? <span className="badge badge-warn">غير مكلّفة</span>}</td><td><StatusBadge map={TASK_STATUS} value={x.status} />{x.cancel_reason && <div className="muted">{x.cancel_reason}</div>}</td>
                <td className="row gap">{open(x) && <><Button variant="ghost" onClick={() => setDialog({ kind: "assign", ids: [x.id] })}>تكليف</Button><Button variant="ghost" onClick={() => setDialog({ kind: "move", task: x })}>ترحيل</Button><Button variant="ghost" onClick={() => setDialog({ kind: "cancel", task: x })}>إلغاء</Button></>}
                  {x.status === "pending_review" && <Link href={`/review?subscriber_id=${x.subscriber_id}`}>مراجعة</Link>}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      {dialog?.kind === "assign" && <AssignDialog ids={dialog.ids} users={users.data ?? []} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
      {dialog?.kind === "cancel" && <ReasonDialog open title="إلغاء المهمة" note="الإلغاء موثق بالسبب ولا يحذف المهمة." onClose={() => setDialog(null)} onSubmit={(reason) => api(`tasks/${dialog.task.id}/cancel`, { body: { reason } })} onDone={() => { setDialog(null); reload(); }} />}
      {dialog?.kind === "move" && <MoveDialog task={dialog.task} cycles={cycles.data ?? []} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
      {dialog?.kind === "new" && <NewTaskDialog cycle={(cycles.data ?? []).find((c) => c.id === cycle)} users={users.data ?? []} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
    </div>
  );
}

function AssignDialog({ ids, users, onClose, onDone }: any) {
  const [emp, setEmp] = useState("");
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title={`تكليف ${ids.length} مهمة`} footer={<><Button variant="primary" busy={busy} onClick={async () => (await run(() => api("tasks/assign-bulk", { body: { task_ids: ids, employee_id: emp || null } }), "تم التكليف")) && onDone()}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <Field label="الموظف"><select value={emp} onChange={(e) => setEmp(e.target.value)}><option value="">بدون تكليف</option>{users.filter((u: any) => u.is_active).map((u: any) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</select></Field>
      <p className="muted">إن تغيّر التكليف بينما الهاتف دون اتصال، تُحفظ قراءات الموظف السابق كاستثناء يراجعه المدير — لا تُحذف.</p>
      <ErrorBox error={error} />
    </Modal>
  );
}

function MoveDialog({ task, cycles, onClose, onDone }: any) {
  const options = cycles.filter((c: any) => c.state !== "closed");
  const [cycle, setCycle] = useState(options[0]?.id ?? "");
  const [date, setDate] = useState("");
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title="ترحيل المهمة إلى دورة أخرى" footer={<><Button variant="primary" busy={busy} onClick={async () => (await run(() => api(`tasks/${task.id}/move`, { body: { cycle_id: cycle, planned_for: date } }), "تم الترحيل")) && onDone()}>ترحيل</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="الدورة"><select value={cycle} onChange={(e) => setCycle(e.target.value)}>{options.map((c: any) => <option key={c.id} value={c.id}>{c.label}</option>)}</select></Field>
        <Field label="الموعد الجديد"><input type="date" value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function NewTaskDialog({ cycle, users, onClose, onDone }: any) {
  const [q, setQ] = useState("");
  const subs = useQuery<any>(q.length >= 2 ? `subscribers${qs({ q, active: true, limit: 10 })}` : null);
  const [sub, setSub] = useState<any>(null);
  const [date, setDate] = useState(cycle?.starts_on ?? "");
  const [emp, setEmp] = useState("");
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title={`مهمة استثنائية — ${cycle?.label ?? ""}`} footer={<><Button variant="primary" busy={busy} disabled={!sub} onClick={async () => (await run(() => api("tasks", { body: { cycle_id: cycle.id, subscriber_id: sub.id, planned_for: date, employee_id: emp || null } }), "أُنشئت المهمة")) && onDone()}>إنشاء</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="ابحث عن المشترك"><input value={q} onChange={(e) => { setQ(e.target.value); setSub(null); }} /></Field>
        {sub ? <p>المشترك: <b>{sub.full_name}</b> ({sub.subscription_no})</p> : (subs.data?.items ?? []).map((s: any) => <Button key={s.id} variant="ghost" onClick={() => setSub(s)}>{s.full_name} — {s.subscription_no} — {s.zone_name}</Button>)}
        <Field label="الموعد"><input type="date" min={cycle?.starts_on} max={cycle?.ends_on} value={date} onChange={(e) => setDate(e.target.value)} /></Field>
        <Field label="الموظف" hint="فارغ = الموظف المخوّل الوحيد للمنطقة إن وجد"><select value={emp} onChange={(e) => setEmp(e.target.value)}><option value="">تلقائي</option>{users.filter((u: any) => u.is_active).map((u: any) => <option key={u.id} value={u.id}>{u.full_name}</option>)}</select></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

export default function TasksPage() {
  return <Suspense><Tasks /></Suspense>;
}
