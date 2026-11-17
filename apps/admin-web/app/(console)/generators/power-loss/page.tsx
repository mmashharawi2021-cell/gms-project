"use client";
import Link from "next/link";
import { Suspense, useEffect, useState } from "react";
import { useSearchParams } from "next/navigation";
import { useQuery } from "@/lib/api";
import { d, kwh, money, num } from "@/lib/format";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, PageHeader } from "@/components/ui";

function PowerLossPageContent() {
  const sp = useSearchParams();
  const gens = useQuery<any[]>("generators");
  const cycles = useQuery<any[]>("cycles");

  const [genId, setGenId] = useState(sp.get("generator_id") ?? "");
  const [cycleId, setCycleId] = useState(sp.get("cycle_id") ?? "");
  const [generatedInput, setGeneratedInput] = useState("");

  // Select defaults if not chosen
  useEffect(() => {
    if (!genId && gens.data?.length) {
      setGenId(gens.data[0].id);
    }
  }, [gens.data, genId]);

  useEffect(() => {
    if (!cycleId && cycles.data?.length) {
      setCycleId(cycles.data[0].id);
    }
  }, [cycles.data, cycleId]);

  // Query power loss data for chosen generator and cycle
  const lossData = useQuery<any>(
    genId ? `generators/${genId}/power-loss${cycleId ? `?cycle_id=${cycleId}` : ""}` : null
  );

  const dta = lossData.data;
  const consumedKwh = dta ? parseFloat(dta.total_consumed_kwh || "0") : 0;
  const rate = dta ? parseFloat(dta.rate_ils_per_kwh || "0") : 0;

  // Use entered generated kWh, or fallback to an initial estimate (consumed * 1.05) if blank
  const enteredGenerated = parseFloat(generatedInput);
  const generatedKwh = !isNaN(enteredGenerated) && enteredGenerated > 0 ? enteredGenerated : 0;

  const lossKwh = generatedKwh > 0 ? Math.max(0, generatedKwh - consumedKwh) : 0;
  const lossPct = generatedKwh > 0 ? (lossKwh / generatedKwh) * 100 : 0;
  const lossCostIls = lossKwh * (rate > 0 ? rate : 1);

  // Diagnostic Status
  const getDiagnostic = () => {
    if (generatedKwh === 0) {
      return {
        tone: "info",
        title: "يرجى إدخال قراءة العداد الرئيسي للمولد",
        desc: "أدخل كمية الطاقة الإجمالية المنتجة من المولد (ك.و.س) لحساب الفاقد وكشف السرقات فوراً.",
      };
    }
    if (generatedKwh < consumedKwh) {
      return {
        tone: "warn",
        title: "تنبيه: الطاقة المفوترة أكبر من الطاقة المنتجة المدخلة!",
        desc: "يرجى مراجعة رقم قراءة العداد الرئيسي المدخل والتأكد من صحة وحدات القياس.",
      };
    }
    if (lossPct <= 5) {
      return {
        tone: "ok",
        title: `✅ نسبة الفاقد طبيعية وممتازة (${lossPct.toFixed(1)}%)`,
        desc: "الفاقد يقع ضمن الحد الفني المقبول لهدر الكابلات والمحولات الكهربائية (أقل من 5%).",
      };
    }
    if (lossPct <= 10) {
      return {
        tone: "warn",
        title: `⚠️ تحذير: نسبة الفاقد مرتفعة نسبياً (${lossPct.toFixed(1)}%)`,
        desc: "نسبة الفاقد تتجاوز الهدر الفني المعتاد. يُوصى بفحص خطوط التوزيع ومراجعة أي عدادات يشتبه في بطئها.",
      };
    }
    return {
      tone: "danger",
      title: `🚨 إنذار حرج: فاقد كهربائي مرتفع جداً (${lossPct.toFixed(1)}%) — اشتباه سرقة أو عطل عداد!`,
      desc: "هناك هدر غير طبيعي في هذه الدورة! يُوصى فوراً بتكليف الموظف الميداني بعمل جولة تفتيشية لمطابقة التوصيلات وفحص العدادات الصفرية.",
    };
  };

  const diag = getDiagnostic();

  return (
    <div className="stack">
      <PageHeader
        title="🔍 كاشف الفاقد الكهربائي وسرقات التيار"
        subtitle="مقارنة الطاقة المنتجة على العداد الرئيسي للمولد بإجمالي استهلاك المشتركين لكشف الهدر والتلاعب."
        actions={
          <Link href="/generators" className="btn btn-secondary">
            ⚡ إدارة المولدات
          </Link>
        }
      />

      {/* Selectors and Main Input */}
      <Card>
        <div className="filters">
          <Field label="المولد الكهربائي" required>
            <select value={genId} onChange={(e) => setGenId(e.target.value)}>
              {(gens.data ?? []).map((g) => (
                <option key={g.id} value={g.id}>
                  {g.name} ({g.active_subscribers} مشترك)
                </option>
              ))}
            </select>
          </Field>

          <Field label="دورة الفوترة">
            <select value={cycleId} onChange={(e) => setCycleId(e.target.value)}>
              {(cycles.data ?? []).map((c) => (
                <option key={c.id} value={c.id}>
                  {c.label} ({d(c.starts_on)} — {d(c.ends_on)})
                </option>
              ))}
            </select>
          </Field>

          <Field
            label="قراءة العداد الرئيسي للمولد (الطاقة المنتجة kWh)"
            hint="اكتب إجمالي الطاقة المسجلة على لوحة المولد في هذه الدورة"
          >
            <input
              type="number"
              step="any"
              placeholder="مثال: 12500"
              value={generatedInput}
              onChange={(e) => setGeneratedInput(e.target.value)}
              className="num-input font-bold"
            />
          </Field>
        </div>
      </Card>

      {lossData.loading && !lossData.data ? (
        <Loading label="جارٍ استخراج وتحليل بيانات الطاقة والمشتركين…" />
      ) : lossData.error ? (
        <ErrorBox error={lossData.error} />
      ) : !dta ? (
        <Empty>يرجى اختيار مولد ودورة لعرض التحليل.</Empty>
      ) : (
        <>
          {/* Smart Diagnostic Banner */}
          <div className={`alert alert-${diag.tone}`}>
            <strong>{diag.title}</strong>
            <p style={{ margin: "4px 0 0 0" }}>{diag.desc}</p>
          </div>

          {/* Analysis KPI Cards */}
          <div className="stats">
            <div className="stat">
              <span className="stat-label">الطاقة المنتجة (المولد)</span>
              <span className="stat-value">{generatedKwh > 0 ? `${num(generatedKwh)} kWh` : "—"}</span>
            </div>

            <div className="stat stat-ok">
              <span className="stat-label">الطاقة المفوترة (المشتركون)</span>
              <span className="stat-value">{num(consumedKwh)} kWh</span>
            </div>

            <div className={`stat ${lossPct > 10 ? "stat-danger" : lossPct > 5 ? "stat-warn" : ""}`}>
              <span className="stat-label">كمية الفاقد (الهدر)</span>
              <span className="stat-value">{generatedKwh > 0 ? `${num(lossKwh)} kWh` : "—"}</span>
            </div>

            <div className={`stat ${lossPct > 10 ? "stat-danger" : lossPct > 5 ? "stat-warn" : ""}`}>
              <span className="stat-label">نسبة الفاقد المئوية</span>
              <span className="stat-value">{generatedKwh > 0 ? `${lossPct.toFixed(1)} %` : "—"}</span>
            </div>

            <div className={`stat ${lossCostIls > 0 ? "stat-danger" : ""}`}>
              <span className="stat-label">الخسارة المالية التقديرية</span>
              <span className="stat-value">{generatedKwh > 0 ? `${money(lossCostIls)}` : "—"}</span>
            </div>
          </div>

          {/* Subscribers Breakdown on this Generator */}
          <Card
            title={`👥 استهلاك المشتركين المرتبطين بهذا المولد (${dta.subscribers_count} مشترك)`}
            actions={<span className="muted">مرتبون من الأعلى استهلاكاً إلى الأقل</span>}
          >
            {!dta.subscribers?.length ? (
              <Empty>لا يوجد مشتركون فعالون مسجلون على هذا المولد.</Empty>
            ) : (
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>رقم الاشتراك</th>
                      <th>اسم المشترك</th>
                      <th>المنطقة</th>
                      <th className="n">السابقة</th>
                      <th className="n">الحالية</th>
                      <th className="n">الاستهلاك (kWh)</th>
                      <th className="n">نسبة السحب من المولد</th>
                      <th>الحالة</th>
                    </tr>
                  </thead>
                  <tbody>
                    {dta.subscribers.map((s: any) => {
                      const sKwh = parseFloat(s.consumption_kwh || "0");
                      const sharePct = consumedKwh > 0 ? (sKwh / consumedKwh) * 100 : 0;
                      return (
                        <tr key={s.id}>
                          <td className="ltr">
                            <Link href={`/subscribers/${s.id}`}>{s.subscription_no}</Link>
                          </td>
                          <td>
                            <Link href={`/subscribers/${s.id}`}>{s.full_name}</Link>
                          </td>
                          <td>{s.zone_name}</td>
                          <td className="n">{kwh(s.previous_value_kwh)}</td>
                          <td className="n">{kwh(s.current_value_kwh)}</td>
                          <td className="n font-bold">{kwh(s.consumption_kwh)}</td>
                          <td className="n">{sharePct > 0 ? `${sharePct.toFixed(1)}%` : "0%"}</td>
                          <td>
                            {sKwh === 0 ? (
                              <Badge tone="warn">استهلاك صفري</Badge>
                            ) : sharePct > 15 ? (
                              <Badge tone="info">استهلاك عالي</Badge>
                            ) : (
                              <Badge tone="ok">اعتيادي</Badge>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                  <tfoot>
                    <tr>
                      <td colSpan={5}>الإجمالي المفوتر للمشتركين</td>
                      <td className="n">{num(consumedKwh)} kWh</td>
                      <td className="n">100%</td>
                      <td></td>
                    </tr>
                  </tfoot>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </div>
  );
}

export default function PowerLossPage() {
  return (
    <Suspense>
      <PowerLossPageContent />
    </Suspense>
  );
}
