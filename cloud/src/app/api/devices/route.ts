import { NextResponse } from "next/server";
import { getStorage, type DeviceRecord } from "@/lib/storage";
import { getUserFromRequest } from "@/lib/auth";
import { getDeviceFromRequest } from "@/lib/devices";

export const runtime = "nodejs";

// GET /api/devices — user auth OR Bearer deviceToken
export async function GET(req: Request) {
  const user = await getUserFromRequest(req);

  if (user) {
    const storage = getStorage();
    const devices = await storage.readCollection<DeviceRecord>("devices");
    const owned = devices
      .filter((d) => d.userId === user.id)
      .map((d) => ({
        id: d.id,
        name: d.name,
        role: d.role ?? "worker",
        claimed: !!d.tokenHash,
        pairedAt: d.pairedAt,
        lastSeenAt: d.lastSeenAt,
      }));
    return NextResponse.json({ devices: owned });
  }

  const deviceAuth = await getDeviceFromRequest(req);
  if (deviceAuth) {
    const storage = getStorage();
    const devices = await storage.readCollection<DeviceRecord>("devices");
    const owned = devices
      .filter((d) => d.userId === deviceAuth.userId && d.id === deviceAuth.device.id)
      .map((d) => ({
        id: d.id,
        name: d.name,
        role: d.role ?? "worker",
        claimed: !!d.tokenHash,
        pairedAt: d.pairedAt,
        lastSeenAt: d.lastSeenAt,
      }));
    return NextResponse.json({ devices: owned });
  }

  return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
}
