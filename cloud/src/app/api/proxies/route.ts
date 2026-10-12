import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { nowIso, randomId } from "@/lib/ids";
import { parseProxyInput, proxyEndpointKey, publicProxy } from "@/lib/proxies";
import { getStorage, type ProxyRecord } from "@/lib/storage";

export const runtime = "nodejs";

export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const proxies = await getStorage().readCollection<ProxyRecord>("proxies");
  return NextResponse.json({
    proxies: proxies
      .filter((proxy) => proxy.userId === user.id)
      .sort((a, b) => a.name.localeCompare(b.name))
      .map(publicProxy),
  });
}

export async function POST(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  const parsed = parseProxyInput(body);
  if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

  const now = nowIso();
  const record: ProxyRecord = {
    id: randomId(8),
    userId: user.id,
    ...parsed.value,
    password: parsed.value.password ?? null,
    healthStatus: "unknown",
    lastCheckedAt: null,
    latencyMs: null,
    healthMessage: null,
    assignedProfileId: null,
    assignedAt: null,
    createdAt: now,
    updatedAt: now,
  };

  try {
    await getStorage().mutateCollection<ProxyRecord>("proxies", (items) => {
      const duplicate = items.some(
        (proxy) =>
          proxy.userId === user.id && proxyEndpointKey(proxy) === proxyEndpointKey(record)
      );
      if (duplicate) throw new Error("DUPLICATE_PROXY_ENDPOINT");
      return [...items, record];
    });
  } catch (error) {
    if (error instanceof Error && error.message === "DUPLICATE_PROXY_ENDPOINT") {
      return NextResponse.json(
        { error: "That proxy endpoint already exists in your account" },
        { status: 409 }
      );
    }
    throw error;
  }

  return NextResponse.json({ proxy: publicProxy(record) }, { status: 201 });
}
