/** Presentation metadata only: never an input to identity or network authorization. */
export const PROFILE_ROLES = ["signup", "warmup", "spam", "default"] as const;
export type ProfileRole = typeof PROFILE_ROLES[number];
export const MAX_PROFILE_NOTE_LENGTH = 200;

export function isProfileRole(value: unknown): value is ProfileRole {
  return typeof value === "string" && (PROFILE_ROLES as readonly string[]).includes(value);
}

/** Count Unicode scalar values, including an emoji as one character. */
export function profileNoteLength(value: string): number { return Array.from(value).length; }

export function profileMetadata(record: { role?: unknown; notes?: unknown; metadataRevision?: unknown }) {
  return {
    role: isProfileRole(record.role) ? record.role : "default" as ProfileRole,
    notes: typeof record.notes === "string" ? record.notes : "",
    metadataRevision: Number.isSafeInteger(record.metadataRevision) && Number(record.metadataRevision) >= 0
      ? Number(record.metadataRevision) : 0,
  };
}

export function metadataInputError(input: { role?: unknown; notes?: unknown; metadataRevision?: unknown }): string | null {
  if (input.role !== undefined && !isProfileRole(input.role)) return "role must be signup, warmup, spam, or default";
  if (input.notes !== undefined && (typeof input.notes !== "string" || profileNoteLength(input.notes) > MAX_PROFILE_NOTE_LENGTH))
    return "notes must be a string of at most 200 Unicode characters";
  if (input.metadataRevision !== undefined && (!Number.isSafeInteger(input.metadataRevision) || Number(input.metadataRevision) < 0))
    return "metadataRevision must be a non-negative safe integer";
  return null;
}
