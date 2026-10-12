import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { getDeviceFromRequest } from "@/lib/devices";
import { isCanonicalProfileId, InventoryConflict, publishProfile, retireProfiles, updateProfileMetadata } from "@/lib/profile-inventory";
import { getStorage, InventoryMigrationError, type ProfileRecord } from "@/lib/storage";
import { metadataInputError, profileMetadata, type ProfileRole } from "@/lib/profile-metadata";

import { requestedAppFilter, profileAppType } from "@/lib/app-registry";

export const runtime = "nodejs";

function publicProfile({ rotationAuthSecretEnc, ...profile }: ProfileRecord) {
  return { ...profile, ...profileMetadata(profile), hasRotationAuthOverride: Boolean(rotationAuthSecretEnc) };
}

export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  const deviceAuth = user ? null : await getDeviceFromRequest(req);
  if (!user && !deviceAuth) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }
  let appType: string | undefined;
  try { appType = requestedAppFilter(req, Boolean(deviceAuth)); }
  catch { return NextResponse.json({ error: "Unknown or ambiguous appType" }, { status: 400 }); }
  let inventory;
  try { inventory = await getStorage().readInventoryState(); }
  catch (error) {
    if (error instanceof InventoryMigrationError)
      return NextResponse.json({ error: error.message }, { status: 503 });
    throw error;
  }
  const profiles = inventory.profiles;
  return NextResponse.json({
    formatVersion: 1,
    tombstones: inventory["profile-tombstones"].filter((item) =>
      item.userId === (user?.id ?? deviceAuth!.userId) && (!deviceAuth || item.deviceId === deviceAuth.device.id))
      .map(({ profileId, deviceId, deletedAt }) => ({ profileId, deviceId, deletedAt })),
    profiles: profiles
      .filter((profile) =>
        profile.userId === (user?.id ?? deviceAuth!.userId) &&
        (!deviceAuth || profile.deviceId === deviceAuth.device.id) &&
        (!appType || profileAppType(profile) === appType)
      )
      .map(publicProfile),
  });
}

export async function POST(req: Request) {
  const deviceAuth = await getDeviceFromRequest(req);
  const user = deviceAuth ? null : await getUserFromRequest(req);
  if (!deviceAuth && !user) {
    return NextResponse.json({ error: "Authentication required" }, { status: 401 });
  }
  let body: {
    profileId?: string;
    deviceId?: string;
    nickname?: string;
    country?: string;
    role?: ProfileRole;
    notes?: string;
    metadataRevision?: number;
    appType?: unknown;
  };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return NextResponse.json({ error: "Expected a JSON object" }, { status: 400 });
  const metadataError = metadataInputError(body);
  if (metadataError) return NextResponse.json({ error: metadataError }, { status: 400 });
  const profileId = typeof body.profileId === "string" ? body.profileId : "";
  if (!isCanonicalProfileId(profileId)) {
    return NextResponse.json({ error: "Invalid profileId" }, { status: 400 });
  }
  const deviceId = deviceAuth?.device.id ??
    (typeof body.deviceId === "string" ? body.deviceId.trim() : "");
  if (!deviceId) {
    return NextResponse.json({ error: "deviceId is required" }, { status: 400 });
  }
  if (user) {
    const devices = await getStorage().readCollection<{
      id: string;
      userId: string;
    }>("devices");
    if (!devices.some((device) => device.id === deviceId && device.userId === user.id)) {
      return NextResponse.json({ error: "Device not found" }, { status: 404 });
    }
  }
  if (body.nickname !== undefined && typeof body.nickname !== "string")
    return NextResponse.json({ error: "nickname must be text" }, { status: 400 });
  const nickname = body.nickname ?? "";
  const country = typeof body.country === "string" ? body.country.trim().toUpperCase() : "";
  if (country && !/^[A-Z]{2}$/.test(country)) {
    return NextResponse.json({ error: "country must be a two-letter code" }, { status: 400 });
  }
  try {
    const record = await publishProfile({ userId: user?.id ?? deviceAuth!.userId,
      deviceId, profileId, nickname, country, appType: body.appType, role: body.role, notes: body.notes, metadataRevision: body.metadataRevision });
    return NextResponse.json({ profile: publicProfile(record) }, { status: 201 });
  } catch (error) {
    if (error instanceof InventoryConflict)
      return NextResponse.json({ error: error.message }, { status: error.status });
    throw error;
  }
}

/** Metadata-only edits cannot rename, move, create, or retire an identity. */
export async function PATCH(req: Request) {
  const device = await getDeviceFromRequest(req);
  const user = device ? null : await getUserFromRequest(req);
  if (!device && !user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  let body: Record<string, unknown>;
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "Invalid JSON" }, { status: 400 }); }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return NextResponse.json({ error: "Expected a JSON object" }, { status: 400 });
  if (Object.keys(body).some((key) => !["profileId", "role", "notes", "metadataRevision", "appType"].includes(key)))
    return NextResponse.json({ error: "Only role and notes can be edited through this endpoint" }, { status: 400 });
  if (!isCanonicalProfileId(body.profileId) || body.metadataRevision === undefined)
    return NextResponse.json({ error: "Canonical profileId and metadataRevision are required" }, { status: 400 });
  const metadataError = metadataInputError(body);
  if (metadataError) return NextResponse.json({ error: metadataError }, { status: 400 });
  try {
    const profile = await updateProfileMetadata({ userId: user?.id ?? device!.userId,
      deviceId: device?.device.id ?? null, profileId: body.profileId, appType: body.appType,
      role: body.role as ProfileRole | undefined, notes: body.notes as string | undefined,
      metadataRevision: body.metadataRevision as number });
    return NextResponse.json({ profile: publicProfile(profile) });
  } catch (error) {
    if (error instanceof InventoryConflict) return NextResponse.json({ error: error.message }, { status: error.status });
    throw error;
  }
}

export async function DELETE(req: Request) {
  const device = await getDeviceFromRequest(req);
  const user = device ? null : await getUserFromRequest(req);
  if (!device && !user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  let body: { profileId?: unknown; appType?: unknown };
  try { body = await req.json(); }
  catch { return NextResponse.json({ error: "Invalid JSON" }, { status: 400 }); }
  if (!isCanonicalProfileId(body?.profileId))
    return NextResponse.json({ error: "Invalid profileId" }, { status: 400 });
  try {
    const tombstones = await retireProfiles(user?.id ?? device!.userId, device?.device.id ?? null, [body.profileId], body.appType);
    return NextResponse.json({ formatVersion: 1, tombstones });
  } catch (error) {
    if (error instanceof InventoryConflict)
      return NextResponse.json({ error: error.message }, { status: error.status });
    throw error;
  }
}
