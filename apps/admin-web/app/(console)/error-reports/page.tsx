"use client";
import Link from "next/link";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { dt } from "@/lib/format";
import { Button, Card, Empty, ErrorBox, Loading, PageHeader } from "@/components/ui";
import { ReasonDialog } from "@/components/ReasonDialog";

export default function ErrorReports() {
  const [all, setAll] = useState(false);
  const r = useQuery<any[]>(`error-reports?open_only=${!all}`);
  const [ack, setAck] = useState<any>(null);
  return (
    <div className="stack">
      <PageHeader title="بلاغات الموظفين عن أخطاء القراءة" subtitle="البلاغ لا يعدّل الزيارة الخام؛ يصحح المدير من الصورة أو يطلب إعادة زيارة." actions={<label className="checkbox"><input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /> عرض المعالجة أيضًا</label>} />
      <Card>
        {r.loading && !r.data ? <Loading /> : r.error ? <ErrorBox error={r.error} /> : !r.data?.length ? <Empty>لا توجد بلاغات.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>التاريخ</th><th>الموظف</th><th>المشترك</th><th>البلاغ</th><th>المعالجة</th><th></th></tr></thead>
            <tbody>{r.data.map((e) => (
              <tr key={e.id}><td>{dt(e.submitted_at)}</td><td>{e.employee_name}</td><td>{e.subscriber_name} <span className="muted ltr">{e.subscription_no}</span></td><td>{e.explanation}</td>
                <td>{e.acknowledged_at ? `${dt(e.acknowledged_at)} — ${e.resolution_note}` : <span className="badge badge-warn">مفتوح</span>}</td>
                <td className="row gap"><Link href={`/review/${e.visit_id}`}>الزيارة</Link>{!e.acknowledged_at && <Button variant="ghost" onClick={() => setAck(e)}>معالجة</Button>}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      {ack && <ReasonDialog open title="معالجة البلاغ" note="وثّق ما تم: تصحيح، إعادة زيارة، أو أن القيمة صحيحة." onClose={() => setAck(null)} onSubmit={(note) => api(`error-reports/${ack.id}/acknowledge`, { body: { note } })} onDone={() => { setAck(null); r.reload(); }} />}
    </div>
  );
}
