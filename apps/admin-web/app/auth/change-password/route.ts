import { NextRequest, NextResponse } from "next/server";
import { API_URL, AT, RT, csrfOk, jsonError, refreshOnce, setSession } from "@/lib/server";

export async function POST(req: NextRequest) {
  if (!csrfOk(req)) return jsonError(403, "csrf", "طلب غير مسموح");
  let token = req.cookies.get(AT)?.value;
  const rt = req.cookies.get(RT)?.value;
  if (!token && rt) token = (await refreshOnce(rt))?.access_token;
  if (!token) return jsonError(401, "unauthenticated", "يلزم تسجيل الدخول");
  const r = await fetch(`${API_URL}/api/v1/auth/change-password`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: await req.text(),
    cache: "no-store",
  });
  const data = await r.json();
  if (!r.ok) return NextResponse.json(data, { status: r.status });
  const res = NextResponse.json({ user: data.user });
  setSession(res, req, data);
  return res;
}
