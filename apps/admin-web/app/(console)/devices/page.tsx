"use client";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { dt } from "@/lib/format";
import { Badge, Button, Card, Empty, ErrorBox, Loading, PageHeader, Stat } from "@/components/ui";
import { ReasonDialog } from "@/components/ReasonDialog";

const REASONS: Record<string, string> = { device_not_enrolled: "هاتف غير مفعّل", device_revoked: "هاتف موقوف", forbidden_zone: "منطقة غير مصرح بها", invalid_precision: "أكثر من منزلتين عشريتين", malformed_payload: "بيانات تالفة", reason_required: "السبب مطلوب", operation_reused: "معرّف عملية مكرر", visit_id_reused: "معرّف زيارة مكرر", unknown_reference: "مرجع غير معروف", invalid_reading: "قراءة غير صالحة" };

export default function Devices() {
  const d = useQuery<any[]>("devices");
  const m = useQuery<any>("sync/monitor");
  const [revoking, setRevoking] = useState<any>(null);
  return (
    <div className="stack">
      <PageHeader title="الأجهزة ومراقبة المزامنة" subtitle="هاتف مفعّل واحد لكل موظف. إيقاف الهاتف يمنع أي مزامنة أو تجديد جلسة فورًا (لا يمكن مسح بياناته عن بُعد أثناء انقطاعه)." />
      {m.data && (
        <div className="stats">
          {m.data.by_result.map((r: any) => <Stat key={r.result_code} label={`عمليات آخر 7 أيام: ${({ accepted: "مقبولة", already_received: "مكررة (تجاهلها الخادم)", conflict: "تعارض", rejected: "مرفوضة" } as any)[r.result_code] ?? r.result_code}`} value={r.n} tone={r.result_code === "rejected" || r.result_code === "conflict" ? "warn" : undefined} />)}
          <Stat label="زيارات بانتظار الصورة" value={m.data.visits_awaiting_photo} />
          <Stat label="صور غير مكتملة" value={m.data.photos_pending} />
        </div>
      )}
      <Card title="الأجهزة">
        {d.loading && !d.data ? <Loading /> : d.error ? <ErrorBox error={d.error} /> : !d.data?.length ? <Empty>لا توجد أجهزة مفعلة. أصدر رمز تفعيل من صفحة الموظفين.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>الموظف</th><th>الجهاز</th><th>الحالة</th><th>التفعيل</th><th>آخر ظهور</th><th>آخر مزامنة</th><th className="n">العمليات</th><th></th></tr></thead>
            <tbody>{d.data.map((x) => (
              <tr key={x.id}><td>{x.employee_name}</td><td>{x.device_label}</td><td>{x.is_active ? <Badge tone="ok">فعّال</Badge> : <Badge>موقوف: {x.revoke_reason}</Badge>}</td>
                <td>{dt(x.enrolled_at)}</td><td>{dt(x.last_seen_at)}</td><td>{dt(x.last_sync_at)}</td><td className="n">{x.operations}</td>
                <td>{x.is_active && <Button variant="danger" onClick={() => setRevoking(x)}>إيقاف</Button>}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      <Card title="عمليات مرفوضة أو متعارضة">
        {!m.data?.rejected_operations.length ? <Empty>لا يوجد.</Empty> : (
          <div className="table-wrap"><table><thead><tr><th>الوقت</th><th>الموظف</th><th>النتيجة</th><th>السبب</th></tr></thead>
            <tbody>{m.data.rejected_operations.map((r: any, i: number) => <tr key={i}><td>{dt(r.accepted_at)}</td><td>{r.employee_name}</td><td>{r.result_code === "conflict" ? "تعارض" : "مرفوضة"}</td><td>{REASONS[r.reason] ?? r.reason}</td></tr>)}</tbody>
          </table></div>
        )}
      </Card>
      <Card title="محاولات دخول/مزامنة مرفوضة">
        {!m.data?.recent_rejections.length ? <Empty>لا يوجد.</Empty> : (
          <div className="table-wrap"><table><thead><tr><th>الوقت</th><th>الموظف</th><th>السبب</th></tr></thead>
            <tbody>{m.data.recent_rejections.map((r: any, i: number) => <tr key={i}><td>{dt(r.occurred_at)}</td><td>{r.employee_name ?? "—"}</td><td>{REASONS[r.reason] ?? r.reason}</td></tr>)}</tbody>
          </table></div>
        )}
      </Card>
      {revoking && <ReasonDialog open title={`إيقاف هاتف ${revoking.employee_name}`} note="بيانات الهاتف غير المرسلة لن تُقبل بعد الإيقاف. لتفعيل هاتف بديل أصدر رمز تفعيل جديد." onClose={() => setRevoking(null)}
        onSubmit={(reason) => api(`devices/${revoking.id}/revoke`, { body: { reason } })} onDone={() => { setRevoking(null); d.reload(); m.reload(); }} />}
    </div>
  );
}
