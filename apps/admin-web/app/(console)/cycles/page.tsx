"use client";
import Link from "next/link";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { d, money, num } from "@/lib/format";
import { CYCLE_STATE } from "@/lib/labels";
import { Button, Card, Empty, ErrorBox, Loading, PageHeader, StatusBadge } from "@/components/ui";
import { CycleDialog } from "@/components/CycleDialog";

export default function Cycles() {
  const c = useQuery<any[]>("cycles");
  const [creating, setCreating] = useState(false);
  return (
    <div className="stack">
      <PageHeader title="دورات التسعير الأسبوعية" subtitle="دورة عامة لكل المولدات؛ دورة مفتوحة واحدة في كل وقت؛ لا تداخل في التواريخ." actions={<Button variant="primary" onClick={() => setCreating(true)}>+ دورة جديدة</Button>} />
      <Card>
        {c.loading && !c.data ? <Loading /> : c.error ? <ErrorBox error={c.error} /> : !c.data?.length ? <Empty>لا توجد دورات.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>الدورة</th><th>الفترة</th><th>الحالة</th><th className="n">السعر المبدئي</th><th className="n">السعر النهائي</th><th className="n">مهام مفتوحة/الكل</th><th className="n">قراءات معتمدة</th><th className="n">الكشوف</th><th className="n">إجمالي التكلفة</th></tr></thead>
            <tbody>{c.data.map((x) => (
              <tr key={x.id}>
                <td><Link href={`/cycles/${x.id}`}>{x.label}</Link></td><td>{d(x.starts_on)} — {d(x.ends_on)}</td><td><StatusBadge map={CYCLE_STATE} value={x.state} /></td>
                <td className="n">{x.provisional_rate_ils_per_kwh ?? "—"}</td><td className="n">{x.final_rate_ils_per_kwh ?? "—"}</td>
                <td className="n">{x.tasks_open} / {x.tasks_total}</td><td className="n">{num(x.approved_readings)}</td><td className="n">{num(x.statements)}</td><td className="n">{x.state === "closed" ? money(x.charged_ils) : "—"}</td>
              </tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      {creating && <CycleDialog onClose={() => setCreating(false)} onDone={() => { setCreating(false); c.reload(); }} />}
    </div>
  );
}

