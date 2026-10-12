import { NextResponse } from "next/server";
import { deviceLicenseInput, validateDeviceLicense } from "@/lib/device-licenses";
import { reportLicenseServiceError } from "@/lib/license-service-errors";
import {
  accessKeyFromRequest,
  findLicenseByKey,
  licenseValidity,
  markLicenseValidated,
} from "@/lib/licenses";

export const runtime = "nodejs";

/**
 * Device heartbeat: POST /api/licenses/validate
 * Access key via Authorization: Bearer <key> or JSON {key}.
 * Returns {valid, revoked, expiresAt} — never echoes the key.
 */
export async function POST(req: Request) {
  let body: Record<string, unknown> | null = null;
  const contentType = req.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    try {
      body = await req.json();
    } catch {
      body = null;
    }
  }

  if (body && typeof body === "object" && ("deviceIdentity" in body || "nonce" in body)) {
    const input = deviceLicenseInput(body, req);
    if (typeof input === "string") return NextResponse.json({ error: input }, { status: 400 });
    try {
      const result = await validateDeviceLicense(input);
      return NextResponse.json(result.body, { status: result.status,
        headers: { "Cache-Control": "no-store", ...(result.retryAfter ? { "Retry-After": String(result.retryAfter) } : {}) } });
    } catch (error) {
      reportLicenseServiceError("validate", error);
      return NextResponse.json({ error: "Signed license validation unavailable; retry within the cached grace period" },
        { status: 503, headers: { "Cache-Control": "no-store" } });
    }
  }

  const key = accessKeyFromRequest(req, { key: typeof body?.key === "string" ? body.key : undefined });
  if (!key) {
    return NextResponse.json({ valid: false, revoked: false, expiresAt: null });
  }

  const lic = await findLicenseByKey(key);
  if (!lic) {
    return NextResponse.json({ valid: false, revoked: false, expiresAt: null });
  }
  if (lic.kind === "device") return NextResponse.json({ valid: false, revoked: Boolean(lic.revokedAt),
    expiresAt: lic.expiresAt ?? null, error: "Device keys require signed installation-bound validation" }, { headers: { "Cache-Control": "no-store" } });

  const status = licenseValidity(lic);
  if (status.valid) {
    await markLicenseValidated(lic.id);
  }
  return NextResponse.json(status);
}
