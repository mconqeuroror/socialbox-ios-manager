import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { activeCodesForUser, createPairing } from "@/lib/pairing";

export const runtime = "nodejs";

// Convenience wrapper used by the web console. Creates a factory pairing
// named "Device" via the shared pair helper, then returns the live code list.
export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const { pairingCode, expiresAt, deviceId } = await createPairing(user.id, "Device", "factory");
  const activeCodes = await activeCodesForUser(user.id);

  return NextResponse.json({
    code: pairingCode,
    pairingCode,
    deviceId,
    expiresAt,
    activeCodes,
  });
}
