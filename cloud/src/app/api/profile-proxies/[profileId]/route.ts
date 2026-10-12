import { isCanonicalProfileId } from "@/lib/profile-inventory";
import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { getStorage } from "@/lib/storage";
import { requestedAppFilter, profileAppType } from "@/lib/app-registry";

export const runtime = "nodejs";
type RouteContext = { params: { profileId: string } };

/** Explicitly reset a profile. Assignments are never rotated automatically. */
export async function DELETE(req: Request, { params }: RouteContext) {
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  const profileId = params.profileId;
  if (!isCanonicalProfileId(profileId)) return NextResponse.json({ error: "Invalid profileId" }, { status: 400 });
  let appType: string | undefined;
  try { appType = requestedAppFilter(req, true); }
  catch { return NextResponse.json({ error: "Unknown or ambiguous appType" }, { status: 400 }); }
  let removed = false;
  let mismatch = false;
  await getStorage().mutateInventoryState((state) => {
    const profile = state.profiles.find((item) => item.userId === user.id && item.profileId === profileId);
    if (profile && profileAppType(profile) !== appType) { mismatch = true; return state; }
    return { ...state, proxies: state.proxies.map((item) => {
      const matches = item.userId === user.id && item.assignedProfileId === profileId;
      if (!matches) return item;
      removed = true;
      return { ...item, assignedProfileId: null, assignedAt: null, updatedAt: new Date().toISOString() };
    }) };
  });
  if (mismatch) return NextResponse.json({ error: "Profile appType does not match" }, { status: 409 });
  if (!removed) return NextResponse.json({ error: "Not found" }, { status: 404 });
  return NextResponse.json({ ok: true });
}
