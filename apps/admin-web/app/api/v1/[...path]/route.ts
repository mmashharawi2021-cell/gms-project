import { NextRequest, NextResponse } from "next/server";
import { API_URL } from "@/lib/server";

export const dynamic = "force-dynamic";

async function proxyToFastApi(req: NextRequest, ctx: { params: Promise<{ path: string[] }> }) {
  const { path } = await ctx.params;
  const targetUrl = `${API_URL}/api/v1/${path.map(encodeURIComponent).join("/")}${req.nextUrl.search}`;

  const forwardHeaders = new Headers();
  req.headers.forEach((value, key) => {
    // Don't forward host or connection headers
    if (!["host", "connection", "transfer-encoding"].includes(key.toLowerCase())) {
      forwardHeaders.set(key, value);
    }
  });

  const clientIp = req.headers.get("x-forwarded-for") || req.headers.get("x-real-ip");
  if (clientIp) {
    forwardHeaders.set("x-forwarded-for", clientIp);
  }

  const body = ["GET", "HEAD"].includes(req.method) ? undefined : await req.arrayBuffer();

  try {
    const res = await fetch(targetUrl, {
      method: req.method,
      headers: forwardHeaders,
      body,
      cache: "no-store",
      redirect: "manual",
    });

    const responseHeaders = new Headers();
    res.headers.forEach((value, key) => {
      if (!["content-encoding", "transfer-encoding"].includes(key.toLowerCase())) {
        responseHeaders.set(key, value);
      }
    });

    return new NextResponse(res.body, {
      status: res.status,
      headers: responseHeaders,
    });
  } catch (err: any) {
    return NextResponse.json(
      { error: { code: "api_gateway_error", message: "تعذر الاتصال بخادم الـ API الداخلي", detail: String(err) } },
      { status: 502 }
    );
  }
}

export {
  proxyToFastApi as GET,
  proxyToFastApi as POST,
  proxyToFastApi as PUT,
  proxyToFastApi as PATCH,
  proxyToFastApi as DELETE,
  proxyToFastApi as OPTIONS,
  proxyToFastApi as HEAD,
};
