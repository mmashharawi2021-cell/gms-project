"use client";
import { useRouter, useSearchParams } from "next/navigation";
import { FormEvent, Suspense, useState } from "react";
import { api } from "@/lib/api";
import { Button, Card, ErrorBox, Field } from "@/components/ui";

function LoginForm() {
  const router = useRouter();
  const sp = useSearchParams();
  const [username, setU] = useState("");
  const [password, setP] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>(null);
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const r = await api<{ user: { must_change_password: boolean } }>("/auth/login", { body: { username, password } });
      const next = sp.get("next");
      router.replace(r.user.must_change_password ? "/change-password" : next && next.startsWith("/") && !next.startsWith("//") ? next : "/");
    } catch (err) {
      setError(err);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="login-wrap">
      <Card className="login-card">
        <div className="brand"><span className="brand-mark">⚡</span><div><strong>GMS</strong><small>لوحة المدير</small></div></div>
        <form onSubmit={submit} className="stack">
          <Field label="اسم المستخدم" required><input autoComplete="username" value={username} onChange={(e) => setU(e.target.value)} required dir="ltr" /></Field>
          <Field label="كلمة المرور" required><input type="password" autoComplete="current-password" value={password} onChange={(e) => setP(e.target.value)} required dir="ltr" /></Field>
          <ErrorBox error={error} />
          <Button variant="primary" busy={busy} type="submit" style={{ width: "100%", justifyContent: "center" }}>تسجيل الدخول</Button>
          <p className="muted" style={{ fontSize: 13 }}>الموظفون الميدانيون يستخدمون تطبيق Android.</p>
        </form>
      </Card>
    </div>
  );
}

export default function LoginPage() {
  return <Suspense><LoginForm /></Suspense>;
}
