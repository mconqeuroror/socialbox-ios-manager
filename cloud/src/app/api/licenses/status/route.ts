import { NextResponse } from "next/server";
import { loadLicenseSigner } from "@/lib/license-signing";
import { getStorage } from "@/lib/storage";
import { reportLicenseServiceError } from "@/lib/license-service-errors";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/** Deployment readiness. Exposes only the public signing identity, never license records. */
export async function GET() {
  let stage = "signing";
  try {
    const signer = loadLicenseSigner();
    stage = "storage";
    await getStorage().readAuthState();
    return NextResponse.json({ ready: true, issuer: signer.issuer, keyId: signer.kid },
      { headers: { "Cache-Control": "no-store" } });
  } catch (error) {
    reportLicenseServiceError(stage, error);
    return NextResponse.json({ ready: false, unavailable: stage },
      { status: 503, headers: { "Cache-Control": "no-store" } });
  }
}
