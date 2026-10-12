import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { isValidLicenseKeyFormat } from "@/lib/ids";
import { activateLicenseForUser } from "@/lib/licenses";

export const runtime = "nodejs";

export async function POST(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: { key?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }

  const key = body.key?.toUpperCase().trim();
  if (!key || !isValidLicenseKeyFormat(key)) {
    return NextResponse.json({ error: "Invalid license key format" }, { status: 400 });
  }

  const result = await activateLicenseForUser(key, user.id);
  if ("error" in result) return NextResponse.json({ error: result.error }, { status: result.status });
  return NextResponse.json(result);
}
