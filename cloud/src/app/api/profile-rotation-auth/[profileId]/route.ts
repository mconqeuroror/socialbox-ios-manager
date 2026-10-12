import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { encryptProxySecret } from "@/lib/proxy-secrets";
import { isCanonicalProfileId, InventoryConflict } from "@/lib/profile-inventory";
import { getStorage, type ProfileRecord } from "@/lib/storage";
import { requestedAppFilter, appDescriptorForType, profileAppType } from "@/lib/app-registry";

export const runtime = "nodejs";
type RouteContext = { params: { profileId: string } };
const HEADER_RE = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]{1,128}$/;

export async function GET(req: Request, { params }: RouteContext) {
  if (!isCanonicalProfileId(params.profileId)) return NextResponse.json({ error: "Invalid profileId" }, { status: 400 });
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  let appType: string | undefined;
  try { appType = requestedAppFilter(req, true); }
  catch { return NextResponse.json({ error: "Unknown or ambiguous appType" }, { status: 400 }); }
  const profiles = await getStorage().readCollection<ProfileRecord>("profiles");
  const profile = profiles.find(
    (item) => item.userId === user.id && item.profileId === params.profileId && profileAppType(item) === appType
  );
  if (!profile) return NextResponse.json({ error: "Profile not found" }, { status: 404 });
  return NextResponse.json({
    profileId: profile.profileId,
    header: profile.rotationAuthHeader ?? "Authorization",
    hasOverride: Boolean(profile.rotationAuthSecretEnc),
  });
}

export async function PUT(req: Request, { params }: RouteContext) {
  if (!isCanonicalProfileId(params.profileId)) return NextResponse.json({ error: "Invalid profileId" }, { status: 400 });
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  let body: { header?: unknown; value?: unknown; appType?: unknown };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return NextResponse.json({ error: "Expected a JSON object" }, { status: 400 });
  const descriptor = appDescriptorForType(body.appType);
  if (!descriptor) return NextResponse.json({ error: "Unknown or malformed appType" }, { status: 400 });
  const clear = body.value === null || body.value === "";
  const header = typeof body.header === "string" ? body.header.trim() : "Authorization";
  const value = typeof body.value === "string" ? body.value : "";
  if (!clear && (!HEADER_RE.test(header) || !value || value.length > 4096)) {
    return NextResponse.json(
      { error: "A valid header and secret value (max 4096 chars) are required" },
      { status: 400 }
    );
  }
  let encrypted: string | null = null;
  try {
    encrypted = clear ? null : encryptProxySecret(value);
  } catch (error) {
    return NextResponse.json(
      { error: error instanceof Error ? error.message : "Secret encryption unavailable" },
      { status: 503 }
    );
  }
  let found = false;
  const storage = getStorage();
  try {
  await storage.mutateInventoryState((state) => {
    found = false;
    if (state["profile-tombstones"].some((item) => item.userId === user.id && item.profileId.toLowerCase() === params.profileId.toLowerCase()))
      throw new InventoryConflict("Profile ID is permanently retired", 410);
    const items = state.profiles;
    const updated = items.map((item) => {
      if (item.userId !== user.id || item.profileId !== params.profileId) return item;
      if (profileAppType(item) !== descriptor.appType) throw new InventoryConflict("Profile appType does not match", 409);
      found = true;
      return {
        ...item,
        rotationAuthHeader: clear ? null : header,
        rotationAuthSecretEnc: encrypted,
      };
    });
    return { ...state, profiles: updated };
  });
  } catch (error) {
    if (error instanceof InventoryConflict)
      return NextResponse.json({ error: error.message }, { status: error.status });
    throw error;
  }
  if (!found) return NextResponse.json({ error: "Profile not found" }, { status: 404 });
  return NextResponse.json({
    profileId: params.profileId,
    header: clear ? "Authorization" : header,
    hasOverride: !clear,
  });
}
