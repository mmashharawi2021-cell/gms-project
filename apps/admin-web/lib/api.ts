"use client";
// Browser-side API access. Always goes through the same-origin BFF (/bff/*); never holds tokens.
import { useCallback, useEffect, useRef, useState } from "react";

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string, public fields?: { field: string; message: string }[]) {
    super(message);
  }
}

type Opts = { method?: string; body?: unknown; form?: FormData; raw?: boolean };

export async function api<T = any>(path: string, opts: Opts = {}): Promise<T> {
  const method = opts.method ?? (opts.body !== undefined || opts.form ? "POST" : "GET");
  const headers: Record<string, string> = { "x-gms-csrf": "1" };
  let body: BodyInit | undefined;
  if (opts.form) body = opts.form;
  else if (opts.body !== undefined) {
    headers["content-type"] = "application/json";
    body = JSON.stringify(opts.body);
  }
  const url = path.startsWith("/auth/") ? path : `/bff/${path.replace(/^\//, "")}`;
  const res = await fetch(url, { method, headers, body, cache: "no-store", credentials: "same-origin" });
  if (opts.raw && res.ok) return res as unknown as T;
  const ct = res.headers.get("content-type") || "";
  const data = ct.includes("application/json") ? await res.json() : null;
  if (!res.ok) {
    const e = data?.error ?? { code: "http_" + res.status, message: "تعذر تنفيذ الطلب" };
    if (res.status === 401 && typeof window !== "undefined" && !path.startsWith("/auth/")) {
      window.location.href = "/login?next=" + encodeURIComponent(window.location.pathname + window.location.search);
    }
    if (e.code === "password_change_required" && typeof window !== "undefined") window.location.href = "/change-password";
    throw new ApiError(res.status, e.code, e.message, e.fields);
  }
  return data as T;
}

export function qs(params: Record<string, string | number | boolean | null | undefined>) {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null && v !== "") p.set(k, String(v));
  const s = p.toString();
  return s ? `?${s}` : "";
}

export function useQuery<T = any>(path: string | null) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [loading, setLoading] = useState(!!path);
  const seq = useRef(0);
  const load = useCallback(async () => {
    if (!path) return;
    const n = ++seq.current;
    setLoading(true);
    try {
      const d = await api<T>(path);
      if (n === seq.current) {
        setData(d);
        setError(null);
      }
    } catch (e) {
      if (n === seq.current) setError(e as ApiError);
    } finally {
      if (n === seq.current) setLoading(false);
    }
  }, [path]);
  useEffect(() => {
    load();
  }, [load]);
  return { data, error, loading, reload: load, setData };
}

export function photoSrc(url: string) {
  return url.replace(/^\/api\/v1\//, "/bff/");
}

export async function download(path: string, fallbackName: string) {
  const res = await api<Response>(path, { raw: true });
  const blob = await res.blob();
  const cd = res.headers.get("content-disposition") || "";
  const m = /filename="?([^";]+)"?/.exec(cd);
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = m?.[1] || fallbackName;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
}

export function newKey(): string {
  return crypto.randomUUID();
}
