import { NextResponse } from "next/server";
import { claimPairing } from "@/lib/pairing";
import { claimDeviceLicense, deviceLicenseInput } from "@/lib/device-licenses";
import { reportLicenseServiceError } from "@/lib/license-service-errors";

export const runtime = "nodejs";

// POST /api/devices/claim {pairingCode} -> {deviceId, token}
export async function POST(req: Request) {
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return NextResponse.json({ error: "Expected a JSON object" }, { status: 400 });
  if ("deviceIdentity" in body || "nonce" in body || "key" in body) {
    const input = deviceLicenseInput(body, req);
    if (typeof input === "string") return NextResponse.json({ error: input }, { status: 400 });
    try {
      const result = await claimDeviceLicense(input);
      return NextResponse.json(result.body, { status: result.status,
        headers: { "Cache-Control": "no-store", ...(result.retryAfter ? { "Retry-After": String(result.retryAfter) } : {}) } });
    } catch (error) {
      reportLicenseServiceError("claim", error);
      return NextResponse.json({ error: "Device activation unavailable; check cloud signing configuration and storage" },
        { status: 503, headers: { "Cache-Control": "no-store" } });
    }
  }

  const rawCode = body.pairingCode ?? body.code;
  const pairingCode = typeof rawCode === "string" ? rawCode.trim() : "";
  if (!pairingCode) {
    return NextResponse.json({ error: "pairingCode is required" }, { status: 400 });
  }

  const result = await claimPairing(pairingCode);
  if ("error" in result) {
    return NextResponse.json({ error: result.error }, { status: result.status });
  }
  return NextResponse.json({
    deviceId: result.deviceId,
    token: result.token,
    role: result.role,
    name: result.name,
  });
}
