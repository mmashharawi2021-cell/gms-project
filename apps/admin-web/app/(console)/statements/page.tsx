"use client";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import { download, qs, useQuery } from "@/lib/api";
import { kwh, money } from "@/lib/format";
import { buildStatementWhatsAppText, openWhatsApp } from "@/lib/whatsapp";
import { Button, Card, Empty, ErrorBox, Field, Loading, PageHeader } from "@/components/ui";

function Statements() {
  const sp = useSearchParams();
  const cycles = useQuery<any[]>("cycles");
  const [cycle, setCycle] = useState(sp.get("cycle_id") ?? "");
  const [zone, setZone] = useState("");
  const gens = useQuery<any[]>("generators");
  const zones = (gens.data ?? []).flatMap((g) => (g.zones ?? []).map((z: any) => ({ ...z, gen: g.name })));
  useEffect(() => {
    const closed = (cycles.data ?? []).filter((c) => c.state === "closed");
    if (!cycle && closed.length) setCycle(closed[0].id);
  }, [cycles.data, cycle]);
  const s = useQuery<any>(cycle ? `statements${qs({ cycle_id: cycle, limit: 500 })}` : null);
  const closed = (cycles.data ?? []).filter((c) => c.state === "closed");
  return (
    <div className="stack">
      <PageHeader title="الكشوف الأسبوعية النهائية" subtitle="كشف واحد لكل مشترك في الدورة، بتفاصيل كل قراءة. الكشف النهائي غير قابل للتعديل."
        actions={cycle && <><Button onClick={() => download(`reports/statements/${cycle}/print${zone ? `?zone_id=${zone}` : ""}`, "statements.pdf")}>{zone ? "طباعة كشوف المنطقة PDF" : "طباعة الكشوف PDF"}</Button><Button onClick={() => download(`reports/statements?format=xlsx&cycle_id=${cycle}`, "statements.xlsx")}>Excel</Button></>} />
      <Card>
        <div className="filters"><Field label="الدورة المغلقة"><select value={cycle} onChange={(e) => setCycle(e.target.value)}>{closed.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select></Field>
          <Field label="طباعة حسب المنطقة" hint="الطباعة الكاملة لآلاف الكشوف تستغرق دقائق"><select value={zone} onChange={(e) => setZone(e.target.value)}><option value="">كل المناطق</option>{zones.map((z) => <option key={z.id} value={z.id}>{z.gen} — {z.name}</option>)}</select></Field></div>
        {!closed.length ? <Empty>لا توجد دورات مغلقة بعد.</Empty> : s.loading && !s.data ? <Loading /> : s.error ? <ErrorBox error={s.error} /> : !s.data?.items.length ? <Empty>لا توجد كشوف.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>رقم الكشف</th><th>المشترك</th><th>المنطقة</th><th className="n">kWh</th><th className="n">تكلفة الأسبوع</th><th className="n">الرصيد السابق</th><th className="n">المطلوب</th><th className="n">كسر مرحّل</th><th className="n">رصيد دائن</th><th>إرسال</th></tr></thead>
            <tbody>{s.data.items.map((x: any) => (
              <tr key={x.id}><td><Link href={`/statements/${x.id}`} className="ltr">{x.statement_no}</Link></td><td>{x.subscriber_name} <span className="muted ltr">{x.subscription_no}</span></td><td>{x.zone_name}</td>
                <td className="n">{kwh(x.consumption_kwh)}</td><td className="n">{money(x.charge_exact_ils)}</td><td className="n">{money(x.opening_ledger_balance_ils)}</td>
                <td className="n"><b>{money(x.requested_whole_ils)}</b></td><td className="n">{money(x.carry_out_ils)}</td><td className="n">{money(x.credits_out_ils)}</td>
                <td>
                  <Button
                    variant="ghost"
                    onClick={() => openWhatsApp(x.subscriber_phone, buildStatementWhatsAppText(x), x.subscriber_name)}
                    className="btn-whatsapp-sm"
                    title="إرسال الفاتورة عبر واتساب"
                  >
                    💬 واتساب
                  </Button>
                </td></tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
    </div>
  );
}
export default function Page() { return <Suspense><Statements /></Suspense>; }
