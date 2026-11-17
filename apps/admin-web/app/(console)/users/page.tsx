"use client";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { dt } from "@/lib/format";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, useAction } from "@/components/ui";

export default function Users() {
  const u = useQuery<any[]>("users");
  const gens = useQuery<any[]>("generators");
  const [dialog, setDialog] = useState<any>(null);
  const [secret, setSecret] = useState<any>(null);
  const act = useAction();
  const zones = (gens.data ?? []).flatMap((g) => (g.zones ?? []).map((z: any) => ({ ...z, gen: g.name })));
  const reload = () => u.reload();
  return (
    <div className="stack">
      <PageHeader title="الموظفون والحسابات" subtitle="المدير وحده ينشئ الحسابات ويصدر كلمات مرور مؤقتة يلزم تغييرها ورموز تفعيل الهواتف." actions={<Button variant="primary" onClick={() => setDialog({ kind: "new" })}>+ حساب جديد</Button>} />
      <ErrorBox error={act.error} />
      <Card>
        {u.loading && !u.data ? <Loading /> : u.error ? <ErrorBox error={u.error} /> : !u.data?.length ? <Empty>لا يوجد مستخدمون.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>الاسم</th><th>اسم المستخدم</th><th>الدور</th><th>الحالة</th><th>المناطق</th><th>الهاتف المفعّل</th><th></th></tr></thead>
            <tbody>{u.data.map((x) => (
              <tr key={x.id}>
                <td>{x.full_name}</td><td className="ltr">{x.username}</td><td>{x.role === "manager" ? "مدير" : "موظف ميداني"}</td>
                <td>{x.is_active ? <Badge tone="ok">فعّال</Badge> : <Badge>موقوف</Badge>} {x.must_change_password && <Badge tone="warn">كلمة مرور مؤقتة</Badge>} {x.locked_until && new Date(x.locked_until) > new Date() && <Badge tone="danger">مقفل مؤقتًا</Badge>}</td>
                <td>{x.role === "employee" ? <>{(x.zones ?? []).map((z: any) => <span key={z.grant_id} className="badge badge-info" style={{ marginInlineEnd: 4 }}>{z.zone_name} <button className="icon-btn" style={{ fontSize: 11, padding: "0 2px" }} title="إنهاء الصلاحية" onClick={() => act.run(() => api(`zone-grants/${z.grant_id}/end`, { method: "POST" }), "أُنهيت صلاحية المنطقة").then(reload)}>✕</button></span>)}
                  <Button variant="ghost" onClick={() => setDialog({ kind: "grant", user: x })}>+ منطقة</Button></> : "—"}</td>
                <td>{x.active_device ? <>{x.active_device.label}<div className="muted">آخر ظهور {dt(x.active_device.last_seen_at)}</div></> : x.role === "employee" ? <Badge tone="warn">لا يوجد</Badge> : "—"}</td>
                <td className="row gap">
                  {x.role === "employee" && x.is_active && <Button variant="ghost" onClick={() => act.run(() => api(`users/${x.id}/enrollment-codes`, { method: "POST" })).then((r: any) => r && setSecret({ title: `رمز تفعيل هاتف ${x.full_name}`, value: r.code, note: `صالح لمرة واحدة حتى ${dt(r.expires_at)}. تفعيل هاتف جديد يوقف الهاتف السابق.` }))}>رمز تفعيل هاتف</Button>}
                  <Button variant="ghost" onClick={() => act.run(() => api(`users/${x.id}/reset-password`, { method: "POST" })).then((r: any) => { if (r) { setSecret({ title: `كلمة مرور مؤقتة — ${x.full_name}`, value: r.temporary_password, note: "سلّمها للمستخدم شخصيًا؛ يجب تغييرها عند أول دخول. أُنهيت جلساته الحالية." }); reload(); } })}>كلمة مرور مؤقتة</Button>
                  <Button variant="ghost" onClick={() => setDialog({ kind: "edit", user: x })}>تعديل</Button>
                </td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      {dialog?.kind === "new" && <NewUser onClose={() => setDialog(null)} onDone={(r: any) => { setDialog(null); reload(); setSecret({ title: `تم إنشاء حساب ${r.full_name}`, value: r.temporary_password, note: "كلمة المرور المؤقتة تظهر مرة واحدة فقط." }); }} />}
      {dialog?.kind === "edit" && <EditUser user={dialog.user} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
      {dialog?.kind === "grant" && <GrantDialog user={dialog.user} zones={zones} onClose={() => setDialog(null)} onDone={() => { setDialog(null); reload(); }} />}
      <Modal open={!!secret} onClose={() => setSecret(null)} title={secret?.title ?? ""} footer={<Button onClick={() => setSecret(null)}>تم</Button>}>
        <p className="reading-big" style={{ letterSpacing: 2 }}>{secret?.value}</p>
        <p className="muted">{secret?.note}</p>
      </Modal>
    </div>
  );
}

function NewUser({ onClose, onDone }: any) {
  const [f, setF] = useState({ username: "", full_name: "", role: "employee" });
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title="حساب جديد" footer={<><Button variant="primary" busy={busy} onClick={async () => { const r = await run(() => api("users", { body: f })); if (r) onDone(r); }}>إنشاء</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="الاسم الكامل" required><input value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>
        <Field label="اسم المستخدم" required hint="أحرف لاتينية وأرقام و . _ -"><input dir="ltr" value={f.username} onChange={(e) => setF({ ...f, username: e.target.value })} /></Field>
        <Field label="الدور"><select value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })}><option value="employee">موظف ميداني (تطبيق Android)</option><option value="manager">مدير (لوحة الويب)</option></select></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function EditUser({ user, onClose, onDone }: any) {
  const [f, setF] = useState({ full_name: user.full_name, is_active: user.is_active });
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title={`تعديل ${user.full_name}`} footer={<><Button variant="primary" busy={busy} onClick={async () => (await run(() => api(`users/${user.id}`, { method: "PATCH", body: f }), "تم الحفظ")) && onDone()}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="الاسم الكامل"><input value={f.full_name} onChange={(e) => setF({ ...f, full_name: e.target.value })} /></Field>
        <label className="checkbox"><input type="checkbox" checked={f.is_active} onChange={(e) => setF({ ...f, is_active: e.target.checked })} /> الحساب فعّال (الإيقاف ينهي الجلسات فورًا)</label>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function GrantDialog({ user, zones, onClose, onDone }: any) {
  const have = new Set((user.zones ?? []).map((z: any) => z.zone_id));
  const [zone, setZone] = useState("");
  const { busy, error, run } = useAction();
  return (
    <Modal open onClose={onClose} title={`منح ${user.full_name} صلاحية منطقة`} footer={<><Button variant="primary" busy={busy} disabled={!zone} onClick={async () => (await run(() => api("zone-grants", { body: { employee_id: user.id, zone_id: zone } }), "تم منح الصلاحية")) && onDone()}>منح</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <Field label="المنطقة"><select value={zone} onChange={(e) => setZone(e.target.value)}><option value="">— اختر —</option>{zones.filter((z: any) => !have.has(z.id)).map((z: any) => <option key={z.id} value={z.id}>{z.gen} — {z.name}</option>)}</select></Field>
      <p className="muted">يرى الموظف مشتركي مناطقه فقط، ويُسمح له بقراءات إضافية داخلها مع السبب والصورة.</p>
      <ErrorBox error={error} />
    </Modal>
  );
}
