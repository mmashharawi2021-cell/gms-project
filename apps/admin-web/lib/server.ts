// Server-only helpers for the Backend-For-Frontend. Tokens never reach browser JavaScript:
// they live in httpOnly, SameSite=Strict cookies and are attached here when proxying to the API.
import type { NextRequest } from "next/server";
import { NextResponse } from "next/server";

export const API_URL = (process.env.GMS_API_INTERNAL_URL || "http://127.0.0.1:8000").replace(/\/$/, "");
export const AT = "gms_at";
export const RT = "gms_rt";

export type Tokens = { access_token: string; expires_in: number; refresh_token: string; refresh_expires_at: string };

function secure(req: NextRequest) {
  return req.nextUrl.protocol === "https:" || req.headers.get("x-forwarded-proto") === "https";
}

export function setSession(res: NextResponse, req: NextRequest, t: Tokens) {
  const base = { httpOnly: true, sameSite: "strict" as const, secure: secure(req), path: "/" };
  res.cookies.set(AT, t.access_token, { ...base, maxAge: Math.max(30, t.expires_in - 30) });
  res.cookies.set(RT, t.refresh_token, { ...base, expires: new Date(t.refresh_expires_at) });
}

export function clearSession(res: NextResponse) {
  res.cookies.set(AT, "", { path: "/", maxAge: 0 });
  res.cookies.set(RT, "", { path: "/", maxAge: 0 });
}

// Single-flight refresh: parallel requests with the same expired session share ONE rotation,
// otherwise the API's refresh-token reuse detection would (correctly) revoke the whole session.
const inflight = new Map<string, { at: number; p: Promise<Tokens | null> }>();

export function refreshOnce(rt: string): Promise<Tokens | null> {
  const now = Date.now();
  for (const [k, v] of inflight) if (now - v.at > 30_000) inflight.delete(k);
  const hit = inflight.get(rt);
  if (hit) return hit.p;
  const p = fetch(`${API_URL}/api/v1/auth/refresh`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ refresh_token: rt }),
    cache: "no-store",
  }).then(async (r) => (r.ok ? ((await r.json()) as Tokens) : null)).catch(() => null);
  inflight.set(rt, { at: now, p });
  return p;
}

export function csrfOk(req: NextRequest) {
  if (["GET", "HEAD", "OPTIONS"].includes(req.method)) return true;
  // A custom header cannot be sent cross-site without a CORS pre-flight (which we never allow).
  return req.headers.get("x-gms-csrf") === "1";
}

export function jsonError(status: number, code: string, message: string) {
  return NextResponse.json({ error: { code, message } }, { status });
}
