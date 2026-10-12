import { NextResponse } from "next/server";
import { getConsoleOwnerFromRequest } from "@/lib/console-auth";
import { revokeLicenseForConsoleOwner } from "@/lib/licenses";
import { appendLicenseAudit, keyIdPrefix } from "@/lib/audit";

export const runtime = "nodejs";

export async function POST(req: Request, { params }: { params: { id: string } }) {
  const user = await getConsoleOwnerFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Owner access required" }, { status: 403 });
  }

  const id = params.id?.trim();
  if (!id) {
    return NextResponse.json({ error: "License id is required" }, { status: 400 });
  }

  const result = await revokeLicenseForConsoleOwner(id, user.id);
  if ("error" in result) return NextResponse.json({ error: result.error }, { status: result.status });
  const match = result.license;
  if (result.alreadyRevoked) {
    return NextResponse.json({
      id: match.id,
      revokedAt: match.revokedAt,
      alreadyRevoked: true,
    });
  }

  await appendLicenseAudit({
    action: "revoke",
    actorUserId: user.id,
    actorUsername: user.username || user.email,
    licenseId: match.id,
    keyIdPrefix: keyIdPrefix(match.id),
    expiresAt: match.expiresAt ?? null,
  });

  return NextResponse.json({ id, revokedAt: match.revokedAt, alreadyRevoked: false });
}
