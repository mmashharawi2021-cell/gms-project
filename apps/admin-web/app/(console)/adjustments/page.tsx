"use client";
import Link from "next/link";
import { useQuery } from "@/lib/api";
import { dt, money } from "@/lib/format";
import { Card, Empty, ErrorBox, Loading, PageHeader } from "@/components/ui";

const KIND: Record<string, string> = { manual: "تسوية يدوية", reading_correction: "تصحيح قراءة في دورة مغلقة", late_reading: "قراءة متأخرة لدورة مغلقة" };

export default function Adjustments() {
  const a = useQuery<any[]>("adjustments");
  return (
    <div className="stack">
      <PageHeader title="التسويات والأرصدة الدائنة" subtitle="التسويات قيود مستقلة لا تعدّل الكشوف المغلقة. لإضافة تسوية افتح صفحة المشترك ← دفتر الحساب." />
      <Card>
        {a.loading && !a.data ? <Loading /> : a.error ? <ErrorBox error={a.error} /> : !a.data?.length ? <Empty>لا توجد تسويات.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>التاريخ</th><th>المشترك</th><th>النوع</th><th>الدورة المصدر</th><th className="n">المبلغ</th><th>السبب</th><th>سجّلها</th></tr></thead>
            <tbody>{a.data.map((x) => (
              <tr key={x.id}><td>{dt(x.recorded_at)}</td><td><Link href={`/subscribers/${x.subscriber_id}`}>{x.subscriber_name}</Link></td><td>{KIND[x.kind]}</td>
                <td>{x.source_cycle_label ?? "—"}</td><td className="n">{money(x.adjustment_ils)}</td><td>{x.description}</td><td>{x.recorded_by_name}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
    </div>
  );
}
