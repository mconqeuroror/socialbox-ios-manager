import { NextResponse } from "next/server";
import { getDeviceFromRequest } from "@/lib/devices";
import { nowIso } from "@/lib/ids";
import { getStorage } from "@/lib/storage";

export const runtime = "nodejs";

export async function POST(
  req: Request,
  { params }: { params: { id: string } }
) {
  const deviceAuth = await getDeviceFromRequest(req);
  if (!deviceAuth) {
    return NextResponse.json({ error: "Device authentication required" }, { status: 401 });
  }
  let body: { healthy?: boolean; latencyMs?: number; message?: string; exitIP?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (typeof body.healthy !== "boolean") {
    return NextResponse.json({ error: "healthy boolean is required" }, { status: 400 });
  }

  let found = false;
  await getStorage().mutateInventoryState((state) => {
    found = false;
    const authorized = new Set(state.profiles.filter((profile) => profile.userId === deviceAuth.userId &&
      profile.deviceId === deviceAuth.device.id).map((profile) => profile.profileId));
    return { ...state, proxies: state.proxies.map((proxy) => {
      if (proxy.id !== params.id || proxy.userId !== deviceAuth.userId ||
          !proxy.assignedProfileId || !authorized.has(proxy.assignedProfileId)) return proxy;
      found = true;
      return {
        ...proxy,
        healthStatus: body.healthy ? "healthy" : "unhealthy",
        lastCheckedAt: nowIso(),
        latencyMs:
          typeof body.latencyMs === "number" && Number.isFinite(body.latencyMs)
            ? Math.max(0, body.latencyMs)
            : null,
        healthMessage:
          typeof body.message === "string" ? body.message.slice(0, 500) : null,
        updatedAt: nowIso(),
      };
    }) };
  });
  if (!found) return NextResponse.json({ error: "Proxy not found" }, { status: 404 });
  return NextResponse.json({ ok: true });
}
