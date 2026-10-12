import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { nowIso } from "@/lib/ids";
import {
  parseHealthFields,
  parseProxyInput,
  proxyEndpointKey,
  publicProxy,
} from "@/lib/proxies";
import {
  getStorage,
  type ProxyRecord,
} from "@/lib/storage";

export const runtime = "nodejs";
type RouteContext = { params: { id: string } };

export async function PATCH(req: Request, { params }: RouteContext) {
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  const parsed = parseProxyInput(body, { passwordOptional: true });
  if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });
  const health = parseHealthFields(body);
  if (!health.ok) return NextResponse.json({ error: health.error }, { status: 400 });

  let updated: ProxyRecord | null = null;
  try {
    await getStorage().mutateCollection<ProxyRecord>("proxies", (items) => {
      const current = items.find(
        (proxy) => proxy.id === params.id && proxy.userId === user.id
      );
      if (!current) throw new Error("PROXY_NOT_FOUND");
      const candidate: ProxyRecord = {
        ...current,
        ...parsed.value,
        password:
          parsed.value.password === undefined ? current.password : parsed.value.password,
        ...health.value,
        id: current.id,
        userId: current.userId,
        createdAt: current.createdAt,
        updatedAt: nowIso(),
      };
      if (!candidate.username) candidate.password = null;
      const duplicate = items.some(
        (proxy) =>
          proxy.id !== current.id &&
          proxy.userId === user.id &&
          proxyEndpointKey(proxy) === proxyEndpointKey(candidate)
      );
      if (duplicate) throw new Error("DUPLICATE_PROXY_ENDPOINT");
      updated = candidate;
      return items.map((proxy) => (proxy.id === current.id ? candidate : proxy));
    });
  } catch (error) {
    if (error instanceof Error && error.message === "PROXY_NOT_FOUND") {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }
    if (error instanceof Error && error.message === "DUPLICATE_PROXY_ENDPOINT") {
      return NextResponse.json(
        { error: "That proxy endpoint already exists in your account" },
        { status: 409 }
      );
    }
    throw error;
  }

  return NextResponse.json({ proxy: publicProxy(updated!) });
}

export async function DELETE(req: Request, { params }: RouteContext) {
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  try {
    await getStorage().mutateCollection<ProxyRecord>("proxies", (items) => {
      const proxy = items.find((item) => item.id === params.id && item.userId === user.id);
      if (!proxy) throw new Error("PROXY_NOT_FOUND");
      if (proxy.assignedProfileId) throw new Error("PROXY_ASSIGNED");
      return items.filter((item) => item.id !== proxy.id);
    });
  } catch (error) {
    if (error instanceof Error && error.message === "PROXY_NOT_FOUND") {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }
    if (error instanceof Error && error.message === "PROXY_ASSIGNED") {
      return NextResponse.json(
        { error: "Reset this proxy's profile assignment before deleting it" },
        { status: 409 }
      );
    }
    throw error;
  }
  return NextResponse.json({ ok: true });
}
