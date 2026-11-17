import { NextRequest, NextResponse } from "next/server";
import { API_URL, AT, RT, clearSession, csrfOk, jsonError, refreshOnce } from "@/lib/server";

export async function POST(req: NextRequest) {
  if (!csrfOk(req)) return jsonError(403, "csrf", "طلب غير مسموح");
  const rt = req.cookies.get(RT)?.value;
  let at = req.cookies.get(AT)?.value;
  let refresh = rt;
  if (!at && rt) {
    const t = await refreshOnce(rt);
    at = t?.access_token;
    refresh = t?.refresh_token ?? rt;
  }
  if (at && refresh) {
    await fetch(`${API_URL}/api/v1/auth/logout`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${at}` },
      body: JSON.stringify({ refresh_token: refresh }),
      cache: "no-store",
    }).catch(() => undefined);
  }
  const res = NextResponse.json({ ok: true });
  clearSession(res);
  return res;
}
