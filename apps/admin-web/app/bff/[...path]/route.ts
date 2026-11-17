import { NextRequest, NextResponse } from "next/server";
import { API_URL, AT, RT, clearSession, csrfOk, jsonError, refreshOnce, setSession, type Tokens } from "@/lib/server";

export const dynamic = "force-dynamic";

const PASS_HEADERS = ["content-type", "content-disposition", "cache-control", "etag"];

async function forward(req: NextRequest, path: string[], body: ArrayBuffer | undefined, token: string | undefined) {
  const url = `${API_URL}/api/v1/${path.map(encodeURIComponent).join("/")}${req.nextUrl.search}`;
  const headers: Record<string, string> = {};
  const ct = req.headers.get("content-type");
  if (ct) headers["content-type"] = ct;
  if (token) headers.authorization = `Bearer ${token}`;
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) headers["x-forwarded-for"] = fwd;
  return fetch(url, { method: req.method, headers, body, cache: "no-store", redirect: "manual" });
}

async function handle(req: NextRequest, ctx: { params: Promise<{ path: string[] }> }) {
  if (!csrfOk(req)) return jsonError(403, "csrf", "طلب غير مسموح");
  const { path } = await ctx.params;
  if (path[0] === "auth" && path[1] !== "me") return jsonError(404, "not_found", "غير موجود");
  const body = ["GET", "HEAD"].includes(req.method) ? undefined : await req.arrayBuffer();
  let token = req.cookies.get(AT)?.value;
  const rt = req.cookies.get(RT)?.value;
  let renewed: Tokens | null = null;
  if (!token && rt) {
    renewed = await refreshOnce(rt);
    token = renewed?.access_token;
  }
  let res = await forward(req, path, body, token);
  if (res.status === 401 && rt && !renewed) {
    const err = await res.clone().json().catch(() => null);
    if (err?.error?.code === "invalid_token" || err?.error?.code === "unauthenticated") {
      renewed = await refreshOnce(rt);
      if (renewed) res = await forward(req, path, body, renewed.access_token);
    }
  }
  const out = new NextResponse(res.body, { status: res.status });
  for (const h of PASS_HEADERS) {
    const v = res.headers.get(h);
    if (v) out.headers.set(h, v);
  }
  if (renewed) setSession(out, req, renewed);
  else if (res.status === 401 && rt) clearSession(out);
  return out;
}

export { handle as GET, handle as POST, handle as PUT, handle as PATCH, handle as DELETE };
