"use client";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { dt } from "@/lib/format";
import { Button, Card, ErrorBox, Field, Loading, PageHeader, useAction } from "@/components/ui";

const LABELS: Record<string, [string, string]> = {
  business_name: ["اسم الجهة على الكشوف والإيصالات والتقارير", "مثال: مولدات النور — يظهر أعلى كل كشف وإيصال"],
  business_phone: ["هاتف الجهة", "يظهر في رأس وتذييل المستندات؛ اتركه - لإخفائه"],
  statement_footer: ["نص تذييل المستندات", "مثال: الدفع في مكتب المولد يوميًا من 9 حتى 5؛ اتركه - لإخفائه"],
  business_timezone: ["المنطقة الزمنية للأعمال", "تحدد تاريخ القراءة ودورتها. لا يمكن تغييرها بعد اعتماد قراءات. (افتراض يحتاج تأكيد العميل)"],
  clock_skew_tolerance_minutes: ["سماحية فرق ساعة الهاتف (دقائق)", "أكبر من ذلك تصبح الزيارة «وقت مشكوك فيه» تحتاج قرار المدير"],
  late_sync_hours: ["حد المزامنة المتأخرة (ساعات)", "الزيارات التي تصل بعد هذه المدة تُعلَّم كاستثناء"],
  default_interval_days: ["فترة القراءة الافتراضية (أيام)", "تُستخدم عند عدم وجود جدولة للمشترك"],
};

export default function Settings() {
  const s = useQuery<any[]>("settings");
  return (
    <div className="stack">
      <PageHeader title="الإعدادات" />
      {s.loading && !s.data ? <Loading /> : s.error ? <ErrorBox error={s.error} /> : (s.data ?? []).filter((x) => LABELS[x.key]).map((x) => <SettingRow key={x.key} item={x} onSaved={s.reload} />)}
    </div>
  );
}

function SettingRow({ item, onSaved }: any) {
  const [v, setV] = useState(item.value);
  const { busy, error, run } = useAction();
  const [label, hint] = LABELS[item.key];
  return (
    <Card>
      <div className="filters">
        <Field label={label} hint={hint}><input dir={item.key.startsWith("business_name") || item.key === "statement_footer" ? "rtl" : "ltr"} value={v} onChange={(e) => setV(e.target.value)} /></Field>
        <Button variant="primary" busy={busy} disabled={v === item.value} onClick={() => run(() => api(`settings/${item.key}`, { method: "PUT", body: { value: v } }), "تم الحفظ").then((r) => r && onSaved())}>حفظ</Button>
        <span className="muted">آخر تعديل {dt(item.updated_at)}</span>
      </div>
      <ErrorBox error={error} />
    </Card>
  );
}
