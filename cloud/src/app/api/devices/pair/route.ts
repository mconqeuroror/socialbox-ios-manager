import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { createPairing, isDeviceRole } from "@/lib/pairing";

export const runtime = "nodejs";

// POST /api/devices/pair {name, role: "factory"|"worker"}
// Authorization: Bearer <user JWT> (cookie also accepted for the web console)
export async function POST(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: { name?: string; role?: string; deviceName?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const name = (body.name ?? body.deviceName ?? "").trim();
  const role = body.role;
  if (!name || name.length > 64) {
    return NextResponse.json({ error: "name must be 1-64 characters" }, { status: 400 });
  }
  if (!isDeviceRole(role)) {
    return NextResponse.json({ error: 'role must be "factory" or "worker"' }, { status: 400 });
  }

  const { deviceId, pairingCode } = await createPairing(user.id, name, role);
  return NextResponse.json({ deviceId, pairingCode });
}
