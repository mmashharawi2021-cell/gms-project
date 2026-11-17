"use client";
import { useState } from "react";
import { qs, useQuery } from "@/lib/api";
import { dt } from "@/lib/format";
import { Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, Pager } from "@/components/ui";

export default function Audit() {
  const [type, setType] = useState("");
  const [offset, setOffset] = useState(0);
  const a = useQuery<any[]>(`audit${qs({ entity_type: type, limit: 100, offset })}`);
  const [open, setOpen] = useState<any>(null);
  return (
    <div className="stack">
      <PageHeader title="سجل التدقيق" subtitle="سجل غير قابل للتعديل أو الحذف لكل تغيير على البيانات والعمليات المالية والدخول والتصدير." />
      <Card>
        <div className="filters"><Field label="الكيان"><select value={type} onChange={(e) => { setType(e.target.value); setOffset(0); }}>
          <option value="">الكل</option>{["app_users", "subscribers", "field_visits", "visit_reviews", "approved_readings", "reading_cycles", "cycle_price_decisions", "statement_versions", "payment_receipts", "payment_reversals", "financial_adjustments", "mobile_devices", "reading_tasks", "backup_job_log", "reports"].map((t) => <option key={t} value={t}>{t}</option>)}
        </select></Field></div>
        {a.loading && !a.data ? <Loading /> : a.error ? <ErrorBox error={a.error} /> : !a.data?.length ? <Empty>لا توجد سجلات.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>الوقت</th><th>المستخدم</th><th>الإجراء</th><th>الكيان</th><th></th></tr></thead>
            <tbody>{a.data.map((x) => (
              <tr key={x.id}><td>{dt(x.occurred_at)}</td><td>{x.actor_name ?? "النظام"}</td><td className="ltr">{x.action_code}</td><td className="ltr">{x.entity_type}</td>
                <td><Button variant="ghost" onClick={() => setOpen(x)}>التفاصيل</Button></td></tr>
            ))}</tbody>
          </table></div>
        )}
        <Pager total={(a.data?.length ?? 0) === 100 ? offset + 200 : offset + (a.data?.length ?? 0)} limit={100} offset={offset} onChange={setOffset} />
      </Card>
      <Modal open={!!open} onClose={() => setOpen(null)} title="تفاصيل السجل" wide>
        {open && <div className="grid grid-2">
          <div><h3>قبل</h3><pre dir="ltr" style={{ whiteSpace: "pre-wrap", fontSize: 12 }}>{JSON.stringify(open.before_data, null, 1)}</pre></div>
          <div><h3>بعد</h3><pre dir="ltr" style={{ whiteSpace: "pre-wrap", fontSize: 12 }}>{JSON.stringify(open.after_data, null, 1)}</pre></div>
        </div>}
      </Modal>
    </div>
  );
}
