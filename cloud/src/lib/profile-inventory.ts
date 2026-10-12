import { getStorage, type ProfileRecord, type ProfileTombstone } from "./storage";
import { randomId } from "./ids";
import { appDescriptorForType, profileAppType } from "./app-registry";
import { metadataInputError, profileMetadata, type ProfileRole } from "./profile-metadata";

export const isCanonicalProfileId = (value: unknown): value is string =>
  typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);

export class InventoryConflict extends Error {
  constructor(message: string, public readonly status = 409) { super(message); }
}

export async function publishProfile(input: {
  userId: string; deviceId: string; profileId: string; nickname: string; country: string;
  role?: ProfileRole; notes?: string; metadataRevision?: number; appType?: unknown;
}): Promise<ProfileRecord> {
  if (!isCanonicalProfileId(input.profileId)) throw new InventoryConflict("Invalid canonical profile ID", 400);
  const descriptor = appDescriptorForType(input.appType);
  if (!descriptor) throw new InventoryConflict("Unknown or malformed appType", 400);
  if (typeof input.nickname !== "string") throw new InventoryConflict("Container name must be text", 400);
  const metadataError = metadataInputError(input);
  if (metadataError) throw new InventoryConflict(metadataError, 400);
  const now = new Date().toISOString(), id = randomId(8);
  const state = await getStorage().mutateInventoryState((state) => {
    const same = (item: { userId: string; profileId: string }) =>
      item.userId === input.userId && item.profileId.toLowerCase() === input.profileId.toLowerCase();
    if (state["profile-tombstones"].some(same)) throw new InventoryConflict("Profile ID is permanently retired", 410);
    const existing = state.profiles.find(same);
    // First enrollment may be an old, previously offline container whose local
    // installation label was unbounded. The server cannot distinguish that
    // upload from fresh creation, so preserve its exact cosmetic label without
    // a client-supplied "legacy" flag or silent truncation. New native creation
    // validates names; server rename bounds apply to changes to existing rows.
    // Repeating a stored legacy label (or 128-character fallback ID) is not a
    // rename and must not block unrelated role/notes synchronization.
    const unchangedName = input.nickname === (existing?.nickname || input.profileId);
    if (existing && input.nickname && !unchangedName && (input.nickname !== input.nickname.trim() ||
        Array.from(input.nickname).length > 120 || /[\p{Cc}\p{Cf}\p{Cs}]/u.test(input.nickname)))
      throw new InventoryConflict("Container name must be 1–120 characters without control characters", 400);
    if (existing && existing.profileId !== input.profileId)
      throw new InventoryConflict("Profile ID differs only by case from an existing profile");
    if (existing && profileAppType(existing) !== descriptor.appType)
      throw new InventoryConflict("Profile appType cannot be changed");
    if (existing && existing.deviceId !== input.deviceId)
      throw new InventoryConflict("Profile belongs to a different device; explicit transfer is required");
    if (!existing && input.metadataRevision !== undefined && input.metadataRevision !== 0)
      throw new InventoryConflict("A new profile must start at metadataRevision zero");
    const hasMetadata = input.role !== undefined || input.notes !== undefined || Boolean(input.nickname);
    const previousMetadata = profileMetadata(existing ?? {});
    // Legacy inventory heartbeats omit a revision and must not overwrite console edits.
    const editMetadata = existing && hasMetadata && input.metadataRevision !== undefined;
    if (editMetadata && input.metadataRevision !== previousMetadata.metadataRevision)
      throw new InventoryConflict("Profile metadata changed elsewhere; refresh before retrying");
    if (editMetadata && previousMetadata.metadataRevision === Number.MAX_SAFE_INTEGER)
      throw new InventoryConflict("Profile metadata revision limit reached; explicit recovery required");
    const metadata = !existing || editMetadata ? {
      role: input.role ?? previousMetadata.role, notes: input.notes ?? previousMetadata.notes,
      metadataRevision: previousMetadata.metadataRevision + 1,
    } : previousMetadata;
    const record: ProfileRecord = existing ? { ...existing, appType: descriptor.appType, lastSeenAt: now,
      ...metadata, ...(editMetadata && input.nickname ? { nickname: input.nickname } : {}), ...(input.country ? { country: input.country } : {}) } : {
        id, ...input, appType: descriptor.appType, ...metadata, lastSeenAt: now, createdAt: now,
        nickname: input.nickname || input.profileId, country: input.country || "US" };
    return { ...state, profiles: [...state.profiles.filter((item) => !same(item)), record] };
  });
  return state.profiles.find((item) => item.userId === input.userId && item.profileId === input.profileId)!;
}

export async function updateProfileMetadata(input: {
  userId: string; deviceId: string | null; profileId: string;
  role?: ProfileRole; notes?: string; metadataRevision: number; appType?: unknown;
}): Promise<ProfileRecord> {
  if (!isCanonicalProfileId(input.profileId)) throw new InventoryConflict("Invalid canonical profile ID", 400);
  const metadataError = metadataInputError(input);
  if (metadataError) throw new InventoryConflict(metadataError, 400);
  if (input.role === undefined && input.notes === undefined)
    throw new InventoryConflict("Provide role or notes to update", 400);
  const descriptor = appDescriptorForType(input.appType);
  if (!descriptor) throw new InventoryConflict("Unknown or malformed appType", 400);
  const state = await getStorage().mutateInventoryState((state) => {
    const matches = (item: { userId: string; profileId: string }) =>
      item.userId === input.userId && item.profileId.toLowerCase() === input.profileId.toLowerCase();
    if (state["profile-tombstones"].some(matches)) throw new InventoryConflict("Profile ID is permanently retired", 410);
    const record = state.profiles.find(matches);
    if (!record || (input.deviceId && record.deviceId !== input.deviceId)) throw new InventoryConflict("Profile not found", 404);
    if (profileAppType(record) !== descriptor.appType) throw new InventoryConflict("Profile appType does not match", 409);
    if (record.profileId !== input.profileId) throw new InventoryConflict("Profile ID differs only by case from an existing profile");
    const metadata = profileMetadata(record);
    if (input.metadataRevision !== metadata.metadataRevision)
      throw new InventoryConflict("Profile metadata changed elsewhere; refresh before retrying");
    if (metadata.metadataRevision === Number.MAX_SAFE_INTEGER)
      throw new InventoryConflict("Profile metadata revision limit reached; explicit recovery required");
    return { ...state, profiles: state.profiles.map((item) => item === record ? { ...item,
      role: input.role ?? metadata.role, notes: input.notes ?? metadata.notes,
      metadataRevision: metadata.metadataRevision + 1 } : item) };
  });
  return state.profiles.find((item) => item.userId === input.userId && item.profileId === input.profileId)!;
}

export async function retireProfiles(userId: string, deviceId: string | null,
  profileIds: string[], appType?: unknown): Promise<ProfileTombstone[]> {
  const descriptor = appDescriptorForType(appType);
  if (!descriptor) throw new InventoryConflict("Unknown or malformed appType", 400);
  if (!profileIds.length || profileIds.length > 256 || !profileIds.every(isCanonicalProfileId))
    throw new InventoryConflict("Expected 1–256 canonical profile IDs", 400);
  const now = new Date().toISOString();
  const ids = [...new Set(profileIds)];
  const records = new Map(ids.map((profileId) => [profileId, randomId(8)]));
  const state = await getStorage().mutateInventoryState((state) => {
    for (const profileId of ids) {
      const profile = state.profiles.find((item) => item.userId === userId && item.profileId.toLowerCase() === profileId.toLowerCase());
      if (profile && profileAppType(profile) !== descriptor.appType)
        throw new InventoryConflict("Profile appType does not match", 409);
      const retired = state["profile-tombstones"].find((item) => item.userId === userId && item.profileId.toLowerCase() === profileId.toLowerCase());
      if ((profile && profile.profileId !== profileId) || (retired && retired.profileId !== profileId))
        throw new InventoryConflict("Profile ID differs only by case from an existing profile");
      if ((profile && deviceId && profile.deviceId !== deviceId) ||
          (retired && deviceId && retired.deviceId !== deviceId))
        throw new InventoryConflict("Profile belongs to a different device", 403);
      if (!profile && !retired && !deviceId)
        throw new InventoryConflict("Profile not found", 404);
      // A device can retire its own not-yet-published ID; this handles an
      // uncertain POST followed by offline local deletion without resurrection.
      if (!retired) state["profile-tombstones"].push({ id: records.get(profileId)!, userId,
        deviceId: deviceId ?? profile!.deviceId, profileId, deletedAt: now });
    }
    const removed = new Set(ids.map((id) => id.toLowerCase()));
    state.profiles = state.profiles.filter((item) => item.userId !== userId || !removed.has(item.profileId.toLowerCase()));
    state.proxies = state.proxies.map((item) => item.userId === userId && item.assignedProfileId &&
      removed.has(item.assignedProfileId.toLowerCase()) ? { ...item, assignedProfileId: null,
        assignedAt: null, updatedAt: now } : item);
    return state;
  });
  return state["profile-tombstones"].filter((item) => item.userId === userId && ids.includes(item.profileId));
}
