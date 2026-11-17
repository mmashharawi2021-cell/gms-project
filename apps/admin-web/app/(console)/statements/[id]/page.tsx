"use client";
import Link from "next/link";
import { use } from "react";
import { download, useQuery } from "@/lib/api";
import { d, dt, kwh, money } from "@/lib/format";
import { buildStatementWhatsAppText, openWhatsApp } from "@/lib/whatsapp";
import { Button, Card, ErrorBox, Loading, PageHeader, Stat } from "@/components/ui";

export default function StatementPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);
  const s = useQuery<any>(`statements/${id}`);
  if (s.loading && !s.data) return <Loading />;
  if (s.error) return <ErrorBox error={s.error} />;
  const x = s.data;
  if (!x) return null;
  return (
    <div className="stack">
      <PageHeader title={`كشف ${x.statement_no}`} subtitle={<><Link href={`/subscribers/${x.subscriber_id}`}>{x.subscriber_name}</Link> — {x.generator_name} / {x.zone_name} — {x.cycle_label} ({d(x.starts_on)} — {d(x.ends_on)})</>}
        actions={<>
          <Button onClick={() => openWhatsApp(x.subscriber_phone, buildStatementWhatsAppText(x), x.subscriber_name)} className="btn-whatsapp">
            💬 إرسال عبر واتساب
          </Button>
          <Button onClick={() => download(`reports/statements/${x.cycle_id}/print?subscriber_id=${x.subscriber_id}`, `${x.statement_no}.pdf`)}>طباعة PDF</Button>
        </>} />
      <div className="stats">
        <Stat label="السعر النهائي" value={`${x.rate_snapshot_ils_per_kwh} ₪/kWh`} />
        <Stat label="الاستهلاك" value={`${kwh(x.consumption_kwh)} kWh`} />
        <Stat label="تكلفة الأسبوع الدقيقة" value={money(x.charge_exact_ils)} />
        <Stat label="الرصيد قبل الكشف" value={money(x.opening_ledger_balance_ils)} />
        <Stat label="المبلغ المطلوب" value={money(x.requested_whole_ils)} tone="warn" />
        <Stat label="كسر مرحّل" value={money(x.carry_out_ils)} />
        <Stat label="رصيد دائن" value={money(x.credits_out_ils)} />
      </div>
      <Card title="سطور القراءات">
        <div className="table-wrap"><table>
          <thead><tr><th>تاريخ القراءة</th><th className="n">السابقة</th><th className="n">الحالية</th><th className="n">kWh</th><th className="n">التكلفة الدقيقة</th></tr></thead>
          <tbody>{x.lines.map((l: any) => <tr key={l.approved_reading_id}><td>{dt(l.verified_captured_at)}</td><td className="n">{kwh(l.previous_value_kwh)}</td><td className="n">{kwh(l.current_value_kwh)}</td><td className="n">{kwh(l.consumption_kwh)}</td><td className="n">{money(l.exact_charge_ils)}</td></tr>)}</tbody>
          <tfoot><tr><td>الإجمالي</td><td></td><td></td><td className="n">{kwh(x.consumption_kwh)}</td><td className="n">{money(x.charge_exact_ils)}</td></tr></tfoot>
        </table></div>
        <p className="muted">إصدار الكشف لا يعني الدفع. المطلوب هو الجزء الصحيح من الرصيد بعد الكشف ({money(x.closing_ledger_balance_ils)})، والكسر يُرحّل دون ازدواج.</p>
      </Card>
    </div>
  );
}
