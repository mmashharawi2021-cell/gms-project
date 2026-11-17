"use client";
import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import { api } from "@/lib/api";
import { Button, Card, ErrorBox, Field } from "@/components/ui";

export default function ChangePassword() {
  const router = useRouter();
  const [cur, setCur] = useState("");
  const [pw, setPw] = useState("");
  const [pw2, setPw2] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  async function submit(e: FormEvent) {
    e.preventDefault();
    if (pw !== pw2) return setError({ message: "كلمتا المرور غير متطابقتين" });
    setBusy(true);
    setError(null);
    try {
      await api("/auth/change-password", { body: { current_password: cur, new_password: pw } });
      router.replace("/");
    } catch (err) {
      setError(err);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="login-wrap">
      <Card className="login-card" title="تغيير كلمة المرور">
        <p className="muted">يجب تغيير كلمة المرور المؤقتة قبل استخدام النظام. 8 أحرف على الأقل وتجمع بين أحرف وأرقام.</p>
        <form onSubmit={submit} className="stack">
          <Field label="كلمة المرور الحالية/المؤقتة" required><input type="password" value={cur} onChange={(e) => setCur(e.target.value)} required dir="ltr" autoComplete="current-password" /></Field>
          <Field label="كلمة المرور الجديدة" required><input type="password" value={pw} onChange={(e) => setPw(e.target.value)} required dir="ltr" autoComplete="new-password" /></Field>
          <Field label="تأكيد كلمة المرور" required><input type="password" value={pw2} onChange={(e) => setPw2(e.target.value)} required dir="ltr" autoComplete="new-password" /></Field>
          <ErrorBox error={error} />
          <Button variant="primary" busy={busy} type="submit">حفظ</Button>
        </form>
      </Card>
    </div>
  );
}
