import { NextResponse } from "next/server";
import { getUserFromRequest } from "@/lib/auth";
import { getDeviceFromRequest } from "@/lib/devices";
import { isCanonicalProfileId } from "@/lib/profile-inventory";
import { profileMetadata } from "@/lib/profile-metadata";
import { nowIso } from "@/lib/ids";
import { requestedAppFilter, appDescriptorForType, profileAppType } from "@/lib/app-registry";
import { AssignmentConflict, deviceProxyUrl, publicProxy } from "@/lib/proxies";
import { decryptProxySecret } from "@/lib/proxy-secrets";
import {
  getStorage,
  InventoryMigrationError,
} from "@/lib/storage";

export const runtime = "nodejs";

export async function GET(req: Request) {
  const user = await getUserFromRequest(req);
  const deviceAuth = user ? null : await getDeviceFromRequest(req);
  const userId = user?.id ?? deviceAuth?.userId;
  if (!userId) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  let appType: string | undefined;
  try { appType = requestedAppFilter(req, Boolean(deviceAuth)); }
  catch { return NextResponse.json({ error: "Unknown or ambiguous appType" }, { status: 400 }); }
  const storage = getStorage();
  let inventory;
  try { inventory = await storage.readInventoryState(); }
  catch (error) {
    if (error instanceof InventoryMigrationError)
      return NextResponse.json({ error: error.message }, { status: 503 });
    throw error;
  }
  const { proxies } = inventory;
  const profiles = inventory.profiles.filter((profile) => !appType || profileAppType(profile) === appType);
  const ownedProxies = new Map(
    proxies
      .filter((proxy) => proxy.userId === userId)
      .map((proxy) => [proxy.id, proxy] as const)
  );
  const assignedProxies = [...ownedProxies.values()].filter(
    (proxy) => Boolean(proxy.assignedProfileId)
  );
  if (deviceAuth) {
    try {
      return NextResponse.json({
        assignments: profiles
          .filter((profile) => profile.userId === userId && profile.deviceId === deviceAuth.device.id)
          .map((profile) => {
            const proxy = assignedProxies.find(
              (item) => item.assignedProfileId === profile.profileId
            );
            return {
              profileId: profile.profileId,
              appType: profileAppType(profile),
              proxy: proxy
                ? {
                    id: proxy.id,
                    url: deviceProxyUrl(proxy),
                    healthStatus: proxy.healthStatus,
                    lastCheckedAt: proxy.lastCheckedAt,
                  }
                : null,
              rotationAuth: profile.rotationAuthSecretEnc
                ? {
                    header: profile.rotationAuthHeader || "Authorization",
                    value: decryptProxySecret(profile.rotationAuthSecretEnc),
                  }
                : null,
            };
          }),
      });
    } catch {
      return NextResponse.json(
        { error: "Rotation credential decryption failed" },
        { status: 503 }
      );
    }
  }
  const profileIds = profiles.filter((profile) => profile.userId === userId)
    .map((profile) => profile.profileId).sort();

  return NextResponse.json({
    profiles: profileIds.map((profileId) => {
      const proxy = assignedProxies.find((item) => item.assignedProfileId === profileId);
      const profile = profiles.find((item) => item.userId === userId && item.profileId === profileId)!;
      return {
        profileId,
        appType: profileAppType(profile),
        nickname: profile.nickname || profileId,
        deviceId: profile.deviceId,
        ...profileMetadata(profile),
        assignmentId: proxy?.id ?? null,
        proxy: proxy ? publicProxy(proxy) : null,
        rotationAuthHeader: profiles.find(
          (profile) => profile.userId === userId && profile.profileId === profileId
        )?.rotationAuthHeader ?? "Authorization",
        hasRotationAuthOverride: Boolean(profiles.find(
          (profile) => profile.userId === userId && profile.profileId === profileId
        )?.rotationAuthSecretEnc),
        warning: proxy ? null : "No proxy assigned",
      };
    }),
  });
}

export async function POST(req: Request) {
  const user = await getUserFromRequest(req);
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 });

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ error: "Invalid JSON body" }, { status: 400 });
  }
  if (!body || typeof body !== "object" || Array.isArray(body))
    return NextResponse.json({ error: "Expected a JSON object" }, { status: 400 });
  const descriptor = appDescriptorForType(body.appType);
  if (!descriptor) return NextResponse.json({ error: "Unknown or malformed appType" }, { status: 400 });
  const profileId = typeof body.profileId === "string" ? body.profileId : "";
  const proxyId = typeof body.proxyId === "string" ? body.proxyId.trim() : "";
  const reassign = body.reassign === true;
  if (!isCanonicalProfileId(profileId) || !proxyId) {
    return NextResponse.json(
      { error: "profileId and proxyId are required" },
      { status: 400 }
    );
  }

  const storage = getStorage();
  const now = nowIso();
  let assignment: { id: string; userId: string; profileId: string; proxyId: string; assignedAt: string; updatedAt: string } | null = null;
  try {
    await storage.mutateInventoryState((state) => {
      if (state["profile-tombstones"].some((item) => item.userId === user.id && item.profileId.toLowerCase() === profileId.toLowerCase()))
        throw new Error("PROFILE_RETIRED");
      if (!state.profiles.some((item) => item.userId === user.id && item.profileId === profileId))
        throw new Error("PROFILE_NOT_FOUND");
      if (!state.profiles.some((item) => item.userId === user.id && item.profileId === profileId &&
          profileAppType(item) === descriptor.appType)) throw new Error("PROFILE_APP_MISMATCH");
      const items = state.proxies;
      const target = items.find((proxy) => proxy.userId === user.id && proxy.id === proxyId);
      if (!target) throw new Error("PROXY_NOT_FOUND");
      const conflict = Boolean(target.assignedProfileId && target.assignedProfileId !== profileId) ||
        items.some((proxy) =>
          proxy.userId === user.id &&
          proxy.id !== proxyId &&
          proxy.assignedProfileId === profileId
        );
      if (conflict && !reassign) {
        throw new AssignmentConflict(
          "Profile or proxy is already assigned; retry with reassign=true to replace it explicitly"
        );
      }
      assignment = {
        id: target.id,
        userId: user.id,
        profileId,
        proxyId: target.id,
        assignedAt: target.assignedAt ?? now,
        updatedAt: now,
      };
      return { ...state, proxies: items.map((proxy) => {
        if (proxy.userId !== user.id) return proxy;
        if (proxy.id === proxyId) {
          return { ...proxy, assignedProfileId: profileId, assignedAt: assignment!.assignedAt, updatedAt: now };
        }
        if (reassign && proxy.assignedProfileId === profileId) {
          return { ...proxy, assignedProfileId: null, assignedAt: null, updatedAt: now };
        }
        return proxy;
      }) };
    });
  } catch (error) {
    if (error instanceof InventoryMigrationError)
      return NextResponse.json({ error: error.message }, { status: 503 });
    if (error instanceof Error && error.message === "PROFILE_APP_MISMATCH")
      return NextResponse.json({ error: "Profile appType does not match" }, { status: 409 });
    if (error instanceof Error && error.message === "PROFILE_NOT_FOUND")
      return NextResponse.json({ error: "Register or restore the profile on its device before assigning a proxy" }, { status: 404 });
    if (error instanceof Error && error.message === "PROFILE_RETIRED")
      return NextResponse.json({ error: "Profile ID is permanently retired" }, { status: 410 });
    if (error instanceof AssignmentConflict) {
      return NextResponse.json({ error: error.message }, { status: 409 });
    }
    if (error instanceof Error && error.message === "PROXY_NOT_FOUND") {
      return NextResponse.json({ error: "Proxy not found" }, { status: 404 });
    }
    throw error;
  }

  return NextResponse.json({ assignment }, { status: 201 });
}
