import bcrypt from "bcryptjs";
import { getStorage, type AuthState, type LicenseRecord } from "./storage";
import { isValidLicenseKeyFormat, nowIso, sha256Hex } from "./ids";
import { ConsoleOwnerRequiredError, requireCurrentConsoleOwner } from "./console-owner";

export interface LicenseValidity {
  valid: boolean;
  revoked: boolean;
  expiresAt: string | null;
}

export function normalizeAccessKey(raw: string | undefined | null): string | null {
  if (!raw) return null;
  const key = raw.trim().toUpperCase();
  return key.length ? key : null;
}

export function accessKeyFromRequest(
  req: Request,
  body: { key?: string } | null
): string | null {
  const auth = req.headers.get("authorization");
  if (auth?.startsWith("Bearer ")) {
    const token = auth.slice("Bearer ".length).trim();
    // User JWTs are three base64 segments; access keys are XXXX-XXXX-XXXX-XXXX.
    if (token && !token.includes(".")) {
      return normalizeAccessKey(token);
    }
  }
  return normalizeAccessKey(body?.key);
}

export function licenseValidity(lic: LicenseRecord, now = Date.now()): LicenseValidity {
  const revoked = !!lic.revokedAt;
  const expiresAt = lic.expiresAt ?? null;
  const expired = expiresAt ? !Number.isFinite(Date.parse(expiresAt)) || Date.parse(expiresAt) <= now : false;
  return {
    valid: !revoked && !expired && !lic.deletedAt,
    revoked,
    expiresAt,
  };
}

export async function findLicenseByKey(key: string): Promise<LicenseRecord | null> {
  if (!isValidLicenseKeyFormat(key)) return null;
  const storage = getStorage();
  const licenses = await storage.readCollection<LicenseRecord>("licenses");
  const fingerprint = sha256Hex(key);
  const byFp = licenses.find((l) => l.keyFingerprint === fingerprint);
  if (byFp) return byFp;
  for (const lic of licenses) {
    if (lic.keyFingerprint) continue;
    if (await bcrypt.compare(key, lic.keyHash)) return lic;
  }
  return null;
}

export async function markLicenseValidated(id: string): Promise<void> {
  const storage = getStorage();
  const at = nowIso();
  await storage.mutateCollection<LicenseRecord>("licenses", (items) =>
    items.map((l) => (l.id === id ? { ...l, lastValidatedAt: at } : l))
  );
}

class LicenseFailure extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

export async function activateLicenseForUser(
  rawKey: string, userId: string
): Promise<{ licensed: true } | { error: string; status: number }> {
  const key = normalizeAccessKey(rawKey);
  if (!key || !isValidLicenseKeyFormat(key)) {
    return { error: "Invalid license key format", status: 400 };
  }
  // bcrypt lookup may run outside the transaction, but no eligibility decision
  // does. Recheck this exact key record after every CAS retry.
  const match = await findLicenseByKey(key);
  if (!match) return { error: "Invalid or already used license key", status: 404 };
  try {
    await getStorage().mutateAuthState((state) => {
      const matches = state.licenses.filter((license) => license.id === match.id);
      const license = matches.length === 1 ? matches[0] : undefined;
      const users = state.users.filter((user) => user.id === userId);
      const user = users.length === 1 ? users[0] : undefined;
      if (!user) throw new LicenseFailure("Account no longer exists", 404);
      if (!license || license.keyHash !== match.keyHash ||
          (license.keyFingerprint && license.keyFingerprint !== sha256Hex(key))) {
        throw new LicenseFailure("Invalid or changed license key", 404);
      }
      if (license.kind === "device") throw new LicenseFailure("This is a device key; activate it in the RedditBox launcher", 400);
      const validity = licenseValidity(license);
      if (validity.revoked) throw new LicenseFailure("This access key has been revoked", 403);
      if (!validity.valid || (license.expiresAt && !Number.isFinite(Date.parse(license.expiresAt)))) {
        throw new LicenseFailure("This access key is no longer valid", 403);
      }
      if (license.activatedAt || license.activatedBy) {
        throw new LicenseFailure("Invalid or already used license key", 404);
      }
      if (user.licensedAt !== null) {
        throw new LicenseFailure("This account already has an active license", 400);
      }
      const activatedAt = nowIso();
      return { ...state,
        licenses: state.licenses.map((entry) => entry.id === license.id
          ? { ...entry, activatedBy: user.email, activatedAt } : entry),
        users: state.users.map((entry) => entry.id === user.id
          ? { ...entry, licensedAt: activatedAt } : entry),
      };
    });
    return { licensed: true };
  } catch (error) {
    if (error instanceof LicenseFailure) return { error: error.message, status: error.status };
    throw error;
  }
}

type RevokeResult = { license: LicenseRecord; alreadyRevoked: boolean } | { error: string; status: number };

/** Trusted server-internal utility; request handlers use the required-actor API. */
export function revokeLicense(id: string): Promise<RevokeResult> {
  return revokeLicenseTransaction(id, () => {});
}

export function revokeLicenseForConsoleOwner(id: string, actorUserId: string): Promise<RevokeResult> {
  return revokeLicenseTransaction(id, (state) => requireCurrentConsoleOwner(state.users, actorUserId));
}

async function revokeLicenseTransaction(id: string, authorize: (state: AuthState) => void): Promise<RevokeResult> {
  let alreadyRevoked = false;
  try {
    const committed = await getStorage().mutateAuthState((state) => {
      authorize(state);
      const matches = state.licenses.filter((entry) => entry.id === id);
      const license = matches.length === 1 ? matches[0] : undefined;
      if (!license) throw new LicenseFailure("License not found", 404);
      alreadyRevoked = !!license.revokedAt; // reset on every CAS attempt
      const revoked = { ...license, revokedAt: license.revokedAt || nowIso() };
      const licenses = state.licenses.map((entry) => entry.id === id ? revoked : entry);
      const email = license.activatedBy?.toLowerCase();
      const users = state.users.map((user) => {
        if (!email || user.email.toLowerCase() !== email ||
            !license.activatedAt || user.licensedAt !== license.activatedAt) return user;
        // A retry for an old revoked key must not revoke a newer grant, even
        // when two activations happened to share a millisecond timestamp.
        const replacement = licenses.find((entry) => entry.id !== id &&
          entry.activatedBy?.toLowerCase() === email && entry.activatedAt &&
          licenseValidity(entry).valid &&
          (!entry.expiresAt || Number.isFinite(Date.parse(entry.expiresAt))));
        return { ...user, licensedAt: replacement?.activatedAt ?? null };
      });
      if (!alreadyRevoked && state.deviceLicensing) state.deviceLicensing.events.push({
        id: `revoke-${license.id}-${Date.now()}`, at: nowIso(), action: "revoke", licenseId: license.id,
      });
      return { ...state, licenses, users };
    });
    return { license: committed.licenses.find((entry) => entry.id === id)!, alreadyRevoked };
  } catch (error) {
    if (error instanceof ConsoleOwnerRequiredError) return { error: error.message, status: 403 };
    if (error instanceof LicenseFailure) return { error: error.message, status: error.status };
    throw error;
  }
}
