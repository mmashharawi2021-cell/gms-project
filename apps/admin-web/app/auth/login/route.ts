import { NextRequest, NextResponse } from "next/server";
import { API_URL, csrfOk, jsonError, setSession } from "@/lib/server";

export async function POST(req: NextRequest) {
  if (!csrfOk(req)) return jsonError(403, "csrf", "طلب غير مسموح");
  const { username, password } = await req.json().catch(() => ({}));
  const r = await fetch(`${API_URL}/api/v1/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-forwarded-for": req.headers.get("x-forwarded-for") ?? "" },
    body: JSON.stringify({ username, password, client: "web" }),
    cache: "no-store",
  });
  const data = await r.json().catch(() => ({ error: { code: "server_error", message: "تعذر الاتصال بالخادم" } }));
  if (!r.ok) return NextResponse.json(data, { status: r.status });
  const res = NextResponse.json({ user: data.user });
  setSession(res, req, data);
  return res;
}
