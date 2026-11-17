"use client";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Suspense, useState } from "react";
import { api, qs, useQuery } from "@/lib/api";
import { dt, kwh } from "@/lib/format";
import { EVENT_KIND, FLAGS, TIME_STATUS, VISIT_STATUS } from "@/lib/labels";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, Pager, StatusBadge, useAction } from "@/components/ui";

function Queue() {
  const sp = useSearchParams();
  const [status, setStatus] = useState("open");
  const [kind, setKind] = useState("");
  const [flagged, setFlagged] = useState("");
  const [offset, setOffset] = useState(0);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [bulk, setBulk] = useState(false);
  const path = `visits${qs({ open_only: status === "open", status: status === "open" ? "" : status, kind, flagged, cycle_id: sp.get("cycle_id"), subscriber_id: sp.get("subscriber_id"), limit: 100, offset })}`;
  const v = useQuery<any>(path);
  const approvable = (x: any) => x.event_kind === "reading" && x.record_status === "pending_review";
  return (
    <div className="stack">
      <PageHeader title="مراجعة القراءات والصور" subtitle="كل اعتماد يتطلب مراجعة صورة العداد. الحالات الاستثنائية تُحسم فرديًا مع توثيق السبب." />
      <Card>
        <div className="filters">
          <Field label="الحالة"><select value={status} onChange={(e) => { setStatus(e.target.value); setOffset(0); }}>
            <option value="open">بحاجة لقرار</option>{Object.entries(VISIT_STATUS).map(([k, [l]]) => <option key={k} value={k}>{l}</option>)}</select></Field>
          <Field label="النوع"><select value={kind} onChange={(e) => setKind(e.target.value)}><option value="">الكل</option>{Object.entries(EVENT_KIND).map(([k, l]) => <option key={k} value={k}>{l}</option>)}</select></Field>
          <Field label="الاستثناءات"><select value={flagged} onChange={(e) => setFlagged(e.target.value)}><option value="">الكل</option><option value="true">عليها استثناءات</option><option value="false">بدون استثناءات</option></select></Field>
        </div>
        {sel.size > 0 && <div className="row gap" style={{ marginBottom: 10 }}><b>{sel.size} محددة</b><Button variant="primary" onClick={() => setBulk(true)}>اعتماد جماعي</Button></div>}
        {v.loading && !v.data ? <Loading /> : v.error ? <ErrorBox error={v.error} /> : !v.data?.items.length ? <Empty>لا توجد زيارات مطابقة.</Empty> : (
          <>
            <div className="table-wrap"><table>
              <thead><tr><th></th><th>وقت الالتقاط</th><th>المشترك</th><th>الموظف</th><th>النوع</th><th className="n">السابقة</th><th className="n">القراءة</th><th className="n">الفرق</th><th>صور</th><th>الوقت</th><th>الحالة</th><th></th></tr></thead>
              <tbody>{v.data.items.map((x: any) => {
                const diff = x.reading_value_kwh && x.previous_value_kwh ? subtract(x.reading_value_kwh, x.previous_value_kwh) : null;
                return (
                  <tr key={x.id}>
                    <td>{approvable(x) && <input type="checkbox" checked={sel.has(x.id)} onChange={() => setSel((s) => { const n = new Set(s); n.has(x.id) ? n.delete(x.id) : n.add(x.id); return n; })} />}</td>
                    <td>{dt(x.verified_captured_at ?? x.captured_at_device)}</td>
                    <td>{x.subscriber_name} <span className="muted ltr">{x.subscription_no}</span><div className="muted">{x.zone_name}</div></td>
                    <td>{x.employee_name}</td><td>{EVENT_KIND[x.event_kind]}</td>
                    <td className="n">{kwh(x.previous_value_kwh)}</td><td className="n"><b>{kwh(x.reading_value_kwh)}</b></td>
                    <td className="n">{diff === null ? "—" : diff.startsWith("-") ? <Badge tone="danger">{diff}</Badge> : diff}</td>
                    <td>{x.ready_photos > 0 ? x.ready_photos : <Badge tone="warn">لا يوجد</Badge>}</td>
                    <td><StatusBadge map={TIME_STATUS} value={x.timestamp_status} /></td>
                    <td><StatusBadge map={VISIT_STATUS} value={x.record_status} />{x.flags?.map((f: string) => <div key={f}><Badge tone="danger">{FLAGS[f] ?? f}</Badge></div>)}</td>
                    <td><Link className="btn" href={`/review/${x.id}`}>مراجعة</Link></td>
                  </tr>
                );
              })}</tbody>
            </table></div>
            <Pager total={v.data.total} limit={100} offset={offset} onChange={setOffset} />
          </>
        )}
      </Card>
      {bulk && <BulkDialog ids={[...sel]} rows={v.data?.items ?? []} onClose={() => setBulk(false)} onDone={() => { setBulk(false); setSel(new Set()); v.reload(); }} />}
    </div>
  );
}

/** exact decimal subtraction on strings with ≤2 decimals (no floating point) */
function subtract(a: string, b: string): string {
  const cents = (s: string) => { const [i, f = ""] = s.split("."); return BigInt(i) * 100n + BigInt((f + "00").slice(0, 2)) * (s.startsWith("-") ? -1n : 1n); };
  const c = cents(a) - cents(b);
  const neg = c < 0n; const abs = neg ? -c : c;
  return `${neg ? "-" : ""}${abs / 100n}.${String(abs % 100n).padStart(2, "0")}`;
}

function BulkDialog({ ids, rows, onClose, onDone }: any) {
  const [ok, setOk] = useState(false);
  const [result, setResult] = useState<any>(null);
  const { busy, error, run } = useAction();
  const chosen = rows.filter((r: any) => ids.includes(r.id));
  if (result) return (
    <Modal open onClose={onDone} title="نتيجة الاعتماد الجماعي" footer={<Button onClick={onDone}>إغلاق</Button>}>
      <p>اعتُمد <b>{result.approved}</b> من {result.results.length}.</p>
      <ul>{result.results.filter((r: any) => r.result !== "approved").map((r: any) => <li key={r.visit_id}>{rows.find((x: any) => x.id === r.visit_id)?.subscriber_name}: {r.message}</li>)}</ul>
    </Modal>
  );
  return (
    <Modal open onClose={onClose} title={`اعتماد ${ids.length} قراءة`} wide footer={<><Button variant="primary" busy={busy} disabled={!ok} onClick={async () => { const r = await run(() => api("visits/approve-bulk", { body: { visit_ids: ids, photos_reviewed: ok } })); if (r) setResult(r); }}>اعتماد</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <p className="muted">يُعتمد كل بند في معاملة مستقلة وبسجل قرار خاص. البنود ذات الاستثناءات تُتخطى ويجب حسمها فرديًا.</p>
      <ul>{chosen.map((r: any) => <li key={r.id}>{r.subscriber_name}: <span className="num">{kwh(r.previous_value_kwh)} → {kwh(r.reading_value_kwh)}</span></li>)}</ul>
      <label className="checkbox"><input type="checkbox" checked={ok} onChange={(e) => setOk(e.target.checked)} /> راجعت صورة العداد لكل بند</label>
      <ErrorBox error={error} />
    </Modal>
  );
}

export default function ReviewPage() {
  return <Suspense><Queue /></Suspense>;
}
