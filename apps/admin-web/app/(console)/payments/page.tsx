"use client";
import Link from "next/link";
import { useState } from "react";
import { api, download, qs, useQuery } from "@/lib/api";
import { dt, money } from "@/lib/format";
import { METHOD } from "@/lib/labels";
import { buildPaymentReceiptWhatsAppText, openWhatsApp } from "@/lib/whatsapp";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, PageHeader, Pager } from "@/components/ui";
import PaymentDialog from "@/components/PaymentDialog";
import { ReasonDialog } from "@/components/ReasonDialog";

export default function Payments() {
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [offset, setOffset] = useState(0);
  const p = useQuery<any>(`payments${qs({ date_from: from, date_to: to, limit: 100, offset })}`);
  const [q, setQ] = useState("");
  const subs = useQuery<any>(q.length >= 2 ? `subscribers${qs({ q, limit: 8 })}` : null);
  const [paying, setPaying] = useState<any>(null);
  const [reversing, setReversing] = useState<any>(null);
  return (
    <div className="stack">
      <PageHeader title="المدفوعات" subtitle="يسجلها المدير فقط عند القبض الفعلي — كاملة أو جزئية. الإلغاء بقيد عكسي موثق ولا يحذف الدفعة الأصلية." />
      <Card title="تسجيل دفعة جديدة">
        <Field label="ابحث عن المشترك (الاسم أو رقم الاشتراك)"><input value={q} onChange={(e) => setQ(e.target.value)} /></Field>
        <div className="row gap" style={{ marginTop: 8 }}>{(subs.data?.items ?? []).map((s: any) => (
          <Button key={s.id} onClick={() => setPaying(s)}>{s.full_name} — {s.subscription_no} — المطلوب {money(s.requested_whole_ils)}</Button>
        ))}</div>
      </Card>
      <Card title="سجل المدفوعات">
        <div className="filters">
          <Field label="من"><input type="date" value={from} onChange={(e) => setFrom(e.target.value)} /></Field>
          <Field label="إلى"><input type="date" value={to} onChange={(e) => setTo(e.target.value)} /></Field>
        </div>
        {p.loading && !p.data ? <Loading /> : p.error ? <ErrorBox error={p.error} /> : !p.data?.items.length ? <Empty>لا توجد مدفوعات.</Empty> : (
          <>
            <div className="table-wrap"><table>
              <thead><tr><th>الإيصال</th><th>التاريخ</th><th>المشترك</th><th className="n">المبلغ</th><th>الطريقة</th><th>المرجع</th><th>سجّلها</th><th>الحالة</th><th></th></tr></thead>
              <tbody>{p.data.items.map((x: any) => (
                <tr key={x.id}><td className="ltr">{x.receipt_no}</td><td>{dt(x.paid_at)}</td><td><Link href={`/subscribers/${x.subscriber_id}`}>{x.subscriber_name}</Link></td>
                  <td className="n">{money(x.amount_ils)}</td><td>{METHOD[x.payment_method]}</td><td>{x.reference_text ?? ""}</td><td>{x.received_by_name}</td>
                  <td>{x.reversal_id ? <Badge tone="muted">ملغاة: {x.reversal_reason}</Badge> : <Badge tone="ok">سارية</Badge>}</td>
                  <td className="row gap">
                    <Button
                      variant="ghost"
                      onClick={() => openWhatsApp(x.subscriber_phone, buildPaymentReceiptWhatsAppText(x), x.subscriber_name)}
                      className="btn-whatsapp-sm"
                      title="إرسال سند القبض عبر واتساب"
                    >
                      💬 واتساب
                    </Button>
                    <Button variant="ghost" onClick={() => download(`payments/${x.id}/receipt`, `${x.receipt_no}.pdf`)}>إيصال PDF</Button>
                    {!x.reversal_id && <Button variant="danger" onClick={() => setReversing(x)}>إلغاء بقيد عكسي</Button>}
                  </td></tr>
              ))}</tbody>
            </table></div>
            <Pager total={p.data.total} limit={100} offset={offset} onChange={setOffset} />
          </>
        )}
      </Card>
      {paying && <PaymentDialog open subscriber={paying} onClose={() => setPaying(null)} onDone={() => { setPaying(null); setQ(""); p.reload(); }} />}
      {reversing && <ReasonDialog open title={`إلغاء الدفعة ${reversing.receipt_no}`} note={`سيُسجل قيد عكسي بقيمة ${money(reversing.amount_ils)} وتبقى الدفعة الأصلية محفوظة.`} onClose={() => setReversing(null)}
        onSubmit={(reason) => api(`payments/${reversing.id}/reverse`, { body: { reason } })} onDone={() => { setReversing(null); p.reload(); }} />}
    </div>
  );
}
