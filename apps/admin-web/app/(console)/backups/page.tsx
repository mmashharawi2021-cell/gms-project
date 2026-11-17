"use client";
import { useState } from "react";
import { api, useQuery } from "@/lib/api";
import { dt, num } from "@/lib/format";
import { Badge, Button, Card, Empty, ErrorBox, Field, Loading, Modal, PageHeader, useAction } from "@/components/ui";

export default function Backups() {
  const b = useQuery<any[]>("backups");
  const [dl, setDl] = useState<any>(null);
  return (
    <div className="stack">
      <PageHeader title="النسخ الاحتياطية" subtitle="نسخة يومية تلقائية لقاعدة البيانات وصور العدادات مع بصمات SHA-256. التنزيل اليدوي يتطلب إعادة إدخال كلمة المرور ويُسجَّل في التدقيق." />
      <Card>
        {b.loading && !b.data ? <Loading /> : b.error ? <ErrorBox error={b.error} /> : !b.data?.length ? <Empty>لم تُنفذ نسخ احتياطية بعد. تأكد من تشغيل خدمة backup.</Empty> : (
          <div className="table-wrap"><table>
            <thead><tr><th>البدء</th><th>الانتهاء</th><th>النوع</th><th>النتيجة</th><th className="n">الحجم (بايت)</th><th>ملاحظات</th><th></th></tr></thead>
            <tbody>{b.data.map((x) => (
              <tr key={x.id}><td>{dt(x.started_at)}</td><td>{dt(x.ended_at)}</td><td>{({ scheduled: "مجدولة", manual: "يدوية", restore_test: "اختبار استعادة" } as any)[x.kind]}</td>
                <td>{x.succeeded ? <Badge tone="ok">ناجحة</Badge> : x.succeeded === false ? <Badge tone="danger">فاشلة</Badge> : <Badge tone="warn">جارية</Badge>}</td>
                <td className="n">{x.size_bytes ? num(x.size_bytes) : "—"}</td><td>{x.notes}</td>
                <td>{x.succeeded && <Button onClick={() => setDl(x)}>تنزيل</Button>}</td></tr>
            ))}</tbody>
          </table></div>
        )}
      </Card>
      {dl && <DownloadDialog backup={dl} onClose={() => setDl(null)} />}
    </div>
  );
}

function DownloadDialog({ backup, onClose }: any) {
  const [pw, setPw] = useState("");
  const { busy, error, run } = useAction();
  async function go() {
    const res = await run(async () => {
      const r = await fetch(`/bff/backups/${backup.id}/download`, { method: "POST", headers: { "content-type": "application/json", "x-gms-csrf": "1" }, body: JSON.stringify({ password: pw }) });
      if (!r.ok) { const e = await r.json().catch(() => ({})); throw Object.assign(new Error(e?.error?.message ?? "فشل التنزيل"), { code: e?.error?.code }); }
      return r.blob();
    });
    if (res) {
      const a = document.createElement("a");
      a.href = URL.createObjectURL(res);
      a.download = `${backup.artifact_name}.tar`;
      a.click();
      onClose();
    }
  }
  return (
    <Modal open onClose={onClose} title="تنزيل النسخة الاحتياطية" footer={<><Button variant="primary" busy={busy} disabled={!pw} onClick={go}>تنزيل</Button><Button onClick={onClose}>إلغاء</Button></>}>
      <div className="stack">
        <div className="alert alert-warn">الملف يحتوي جميع بيانات المشتركين والمالية والصور. احفظه في مكان آمن ومشفّر.</div>
        <Field label="أعد إدخال كلمة المرور" required><input type="password" dir="ltr" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="current-password" /></Field>
        <ErrorBox error={error} />
      </div>
    </Modal>
  );
}
