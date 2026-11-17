"use client";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, useAction } from "@/components/ui";

const DAYS = ["الأحد", "الإثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];

export default function Generators() {
  const g = useQuery<any[]>("generators");
  const [edit, setEdit] = useState<any>(null);
  const [zone, setZone] = useState<any>(null);
  return (
    <div className="stack">
      <PageHeader title="المولدات والمناطق" subtitle="لكل مشترك مولد واحد ثابت. يمكن تحديد يوم قراءة لكل منطقة." actions={<Button variant="primary" onClick={() => setEdit({})}>+ مولد</Button>} />
      {g.loading && !g.data ? <Loading /> : g.error ? <ErrorBox error={g.error} /> : !g.data?.length ? <Empty>لم تُسجل مولدات بعد.</Empty> : g.data.map((gen) => (
        <Card key={gen.id} title={<>{gen.name} {!gen.is_active && <Badge>غير فعال</Badge>}</>}
              actions={<><span className="muted">{gen.active_subscribers} مشترك</span><Button onClick={() => setEdit(gen)}>تعديل</Button><Button onClick={() => setZone({ generator_id: gen.id })}>+ منطقة</Button></>}>
          {gen.location_note && <p className="muted">{gen.location_note}</p>}
          {!gen.zones?.length ? <Empty>لا توجد مناطق.</Empty> : (
            <div className="table-wrap"><table>
              <thead><tr><th>المنطقة</th><th>يوم القراءة</th><th>المشتركون</th><th>الموظفون المخوّلون</th><th></th></tr></thead>
              <tbody>{gen.zones.map((z: any) => (
                <tr key={z.id}><td>{z.name} {!z.is_active && <Badge>غير فعالة</Badge>}</td><td>{z.reading_weekday === null ? "—" : DAYS[z.reading_weekday]}</td>
                  <td>{z.subscribers}</td><td>{(z.employees ?? []).map((e: any) => e.full_name).join("، ") || <Badge tone="warn">لا يوجد</Badge>}</td>
                  <td><Button variant="ghost" onClick={() => setZone({ ...z, generator_id: gen.id })}>تعديل</Button></td></tr>
              ))}</tbody>
            </table></div>
          )}
        </Card>
      ))}
      {edit && <GeneratorDialog g={edit} onClose={() => setEdit(null)} onDone={() => { setEdit(null); g.reload(); }} />}
      {zone && <ZoneDialog z={zone} onClose={() => setZone(null)} onDone={() => { setZone(null); g.reload(); }} />}
    </div>
  );
}

function GeneratorDialog({ g, onClose, onDone }: any) {
  const [f, setF] = useState({ name: g.name ?? "", location_note: g.location_note ?? "", is_active: g.is_active ?? true });
  const { busy, error, run } = useAction();
  const save = () => run(() => g.id ? api(`generators/${g.id}`, { method: "PUT", body: f }) : api("generators", { body: f }), "تم الحفظ").then((r) => r && onDone());
  return (
    <Modal open onClose={onClose} title={g.id ? "تعديل مولد" : "مولد جديد"} footer={<><Button variant="primary" busy={busy} onClick={save}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="اسم المولد" required><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
        <Field label="الموقع/ملاحظة"><input value={f.location_note} onChange={(e) => setF({ ...f, location_note: e.target.value })} /></Field>
        <label className="checkbox"><input type="checkbox" checked={f.is_active} onChange={(e) => setF({ ...f, is_active: e.target.checked })} /> فعّال</label>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}

function ZoneDialog({ z, onClose, onDone }: any) {
  const [f, setF] = useState({ name: z.name ?? "", reading_weekday: z.reading_weekday ?? "", is_active: z.is_active ?? true });
  const { busy, error, run } = useAction();
  const wd = f.reading_weekday === "" ? null : Number(f.reading_weekday);
  const save = () => run(() => z.id
    ? api(`zones/${z.id}`, { method: "PATCH", body: { name: f.name, reading_weekday: wd, clear_weekday: wd === null, is_active: f.is_active } })
    : api("zones", { body: { generator_id: z.generator_id, name: f.name, reading_weekday: wd, is_active: f.is_active } }), "تم الحفظ").then((r) => r && onDone());
  return (
    <Modal open onClose={onClose} title={z.id ? "تعديل منطقة" : "منطقة جديدة"} footer={<><Button variant="primary" busy={busy} onClick={save}>حفظ</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <Field label="اسم المنطقة" required><input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} /></Field>
        <Field label="يوم القراءة المعتاد" hint="تُجدول المهام التلقائية في أقرب يوم مطابق داخل الدورة"><select value={String(f.reading_weekday)} onChange={(e) => setF({ ...f, reading_weekday: e.target.value })}>
          <option value="">بدون يوم محدد</option>{DAYS.map((d, i) => <option key={i} value={i}>{d}</option>)}
        </select></Field>
        <label className="checkbox"><input type="checkbox" checked={f.is_active} onChange={(e) => setF({ ...f, is_active: e.target.checked })} /> فعّالة</label>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
