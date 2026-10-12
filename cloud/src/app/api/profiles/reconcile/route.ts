import { NextResponse } from "next/server";
import { getDeviceFromRequest } from "@/lib/devices";
import { InventoryConflict, retireProfiles } from "@/lib/profile-inventory";
export const runtime = "nodejs";

export async function POST(req: Request) {
  const device = await getDeviceFromRequest(req);
  if (!device) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  let body: { profileIds?: unknown; appType?: unknown };
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "Invalid JSON" }, { status: 400 }); }
  if (!Array.isArray(body?.profileIds))
    return NextResponse.json({ error: "profileIds array required" }, { status: 400 });
  try {
    const tombstones = await retireProfiles(device.userId, device.device.id, body.profileIds, body.appType);
    return NextResponse.json({ formatVersion: 1, tombstones });
  } catch (error) {
    if (error instanceof InventoryConflict)
      return NextResponse.json({ error: error.message }, { status: error.status });
    throw error;
  }
}
