"use client";
import { useState } from "react";
import { api, download, qs, useQuery } from "@/lib/api";
import { d, dt, kwh, money } from "@/lib/format";
import { Button, Card, Empty, ErrorBox, Field, Loading, PageHeader, useAction } from "@/components/ui";

const NEEDS_CYCLE = ["consumption", "statements", "generators", "unread"];
const NEEDS_DATES = ["employees", "payments", "adjustments"];

function cell(v: any, kind: string) {
  if (v === null || v === undefined) return "—";
  if (kind === "money") return money(v);
  if (kind === "kwh" || kind === "rate") return kwh(v);
  if (kind === "datetime") return dt(v);
  if (kind === "date") return d(v);
  return String(v);
}

export default function Reports() {
  const kinds = useQuery<any[]>("reports");
  const cycles = useQuery<any[]>("cycles");
  const gens = useQuery<any[]>("generators");
  const [kind, setKind] = useState("consumption");
  const [f, setF] = useState<any>({ cycle_id: "", generator_id: "", date_from: "", date_to: "" });
  const [data, setData] = useState<any>(null);
  const { busy, error, run } = useAction();
  const params = { cycle_id: NEEDS_CYCLE.includes(kind) ? f.cycle_id || (cycles.data?.[0]?.id ?? "") : "", generator_id: f.generator_id,
    date_from: NEEDS_DATES.includes(kind) ? f.date_from : "", date_to: NEEDS_DATES.includes(kind) ? f.date_to : "" };
  const show = () => run(() => api(`reports/${kind}${qs(params)}`)).then((r) => r && setData(r));
  return (
    <div className="stack">
      <PageHeader title="التقارير الرسمية" subtitle="كل تقرير يتضمن المولد والدورة/الفترة وتاريخ الإصدار، ويوضح إن كانت الأرقام مبدئية أو نهائية." />
      <Card>
        <div className="filters">
          <Field label="نوع التقرير"><select value={kind} onChange={(e) => { setKind(e.target.value); setData(null); }}>{(kinds.data ?? []).map((k) => <option key={k.kind} value={k.kind}>{k.title}</option>)}</select></Field>
          {NEEDS_CYCLE.includes(kind) && <Field label="الدورة"><select value={params.cycle_id} onChange={(e) => setF({ ...f, cycle_id: e.target.value })}>{(cycles.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}</select></Field>}
          <Field label="المولد"><select value={f.generator_id} onChange={(e) => setF({ ...f, generator_id: e.target.value })}><option value="">جميع المولدات</option>{(gens.data ?? []).map((g) => <option key={g.id} value={g.id}>{g.name}</option>)}</select></Field>
          {NEEDS_DATES.includes(kind) && <><Field label="من"><input type="date" value={f.date_from} onChange={(e) => setF({ ...f, date_from: e.target.value })} /></Field>
            <Field label="إلى"><input type="date" value={f.date_to} onChange={(e) => setF({ ...f, date_to: e.target.value })} /></Field></>}
          <Button variant="primary" busy={busy} onClick={show}>عرض</Button>
          <Button onClick={() => download(`reports/${kind}${qs({ ...params, format: "pdf" })}`, `gms-${kind}.pdf`)}>PDF</Button>
          <Button onClick={() => download(`reports/${kind}${qs({ ...params, format: "xlsx" })}`, `gms-${kind}.xlsx`)}>Excel</Button>
        </div>
        <ErrorBox error={error} />
        {busy && <Loading />}
        {data && (
          <div className="stack">
            <div><h2>{data.title}</h2><p className="muted">{data.meta.map((m: any) => `${m[0]}: ${m[1]}`).join(" — ")}{data.final === false && " — "}{data.final === false && <b className="badge badge-warn">مبدئي/تقديري</b>}{data.final && <b className="badge badge-ok">نهائي</b>}</p>
              {data.note && <p className={data.final === false ? "provisional" : "muted"}>{data.note}</p>}</div>
            {!data.rows.length ? <Empty>لا توجد بيانات.</Empty> : (
              <div className="table-wrap"><table>
                <thead><tr>{data.columns.map((c: any) => <th key={c.key} className={c.kind === "text" ? "" : "n"}>{c.title}</th>)}</tr></thead>
                <tbody>{data.rows.map((r: any, i: number) => <tr key={i}>{data.columns.map((c: any) => <td key={c.key} className={c.kind === "text" ? "" : "n"}>{cell(r[c.key], c.kind)}</td>)}</tr>)}</tbody>
                {Object.keys(data.totals).length > 0 && <tfoot><tr>{data.columns.map((c: any, i: number) => <td key={c.key} className={c.kind === "text" ? "" : "n"}>{c.key in data.totals ? cell(data.totals[c.key], c.kind) : i === 0 ? "الإجمالي" : ""}</td>)}</tr></tfoot>}
              </table></div>
            )}
          </div>
        )}
      </Card>
    </div>
  );
}
