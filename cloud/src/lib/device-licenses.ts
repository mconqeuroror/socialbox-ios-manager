import { getStorage, type AuthState, type DeviceRecord, type LicenseRecord, type DeviceLicenseEvent } from "./storage";
import { findLicenseByKey, licenseValidity, normalizeAccessKey } from "./licenses";
import { isValidLicenseKeyFormat, randomId, sha256Hex } from "./ids";
import { loadLicenseSigner, type DeviceLicenseStatus } from "./license-signing";
import { ConsoleOwnerRequiredError, requireCurrentConsoleOwner } from "./console-owner";

export interface DeviceLicenseResult { status: number; body: Record<string, unknown>; retryAfter?: number }
type Input = { identity: string; binding: string; nonce: string; key: string | null; bearer: string | null; name: string };
export function deviceLicenseInput(body: Record<string, unknown>, req: Request): Input | string {
  if (typeof body.deviceIdentity !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.deviceIdentity))
    return "deviceIdentity must be a stable installation UUID";
  if (typeof body.nonce !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(body.nonce))
    return "nonce must contain 16–128 URL-safe random characters";
  if (body.key !== undefined && typeof body.key !== "string") return "key must be a string";
  const identity = body.deviceIdentity.toLowerCase();
  const token = req.headers.get("authorization")?.replace(/^Bearer /, "") ?? "";
  return { identity, binding: sha256Hex(identity), nonce: body.nonce,
    key: normalizeAccessKey(body.key as string | undefined), bearer: /^[0-9a-f]{64}$/.test(token) ? token : null,
    name: typeof body.name === "string" && body.name.trim() ? body.name.trim().slice(0, 64) : "RedditBox iPhone" };
}

export function deviceLicenseStatus(license: LicenseRecord | undefined, now = Date.now()): DeviceLicenseStatus {
  if (!license || license.deletedAt) return "invalid";
  if (license.revokedAt) return "revoked";
  if (license.expiresAt && (!Number.isFinite(Date.parse(license.expiresAt)) || Date.parse(license.expiresAt) <= now)) return "expired";
  return "active";
}
function ownerOf(license: LicenseRecord | undefined, state: AuthState): string | undefined {
  return license?.ownerUserId ?? state.users.find((user) => user.email.toLowerCase() === license?.activatedBy?.toLowerCase())?.id;
}
function adminDevice(device: DeviceRecord, state: AuthState): boolean {
  return !!state.deviceLicensing!.adminDevices.some((entry) => entry.deviceId === device.id && entry.userId === device.userId);
}
function event(state: AuthState, entry: Omit<DeviceLicenseEvent, "id" | "at">, now: number) {
  state.deviceLicensing!.events.push({ id: randomId(12), at: new Date(now).toISOString(), ...entry });
}
function rate(state: AuthState, binding: string, kind: "claim" | "validate", now: number): number | null {
  const windowMs = kind === "claim" ? 15 * 60_000 : 60_000, limit = kind === "claim" ? 5 : 120;
  const licensing = state.deviceLicensing!;
  licensing.rates = licensing.rates.filter((entry) => now - entry.windowStart < (entry.kind === "claim" ? 15 * 60_000 : 60_000));
  const current = licensing.rates.find((entry) => entry.binding === binding && entry.kind === kind);
  if (current) {
    if (current.count >= limit) return Math.max(1, Math.ceil((current.windowStart + windowMs - now) / 1000));
    current.count++;
  } else {
    if (licensing.rates.length >= 4096) return 60;
    licensing.rates.push({ binding, kind, windowStart: now, count: 1 });
  }
  return null;
}
function authenticatedDevice(input: Input, state: AuthState): DeviceRecord | undefined {
  if (!input.bearer) return undefined;
  const hash = sha256Hex(input.bearer);
  return state.devices.find((device) => device.tokenHash === hash && state.users.some((user) => user.id === device.userId));
}

export async function claimDeviceLicense(input: Input): Promise<DeviceLicenseResult> {
  const signer = loadLicenseSigner(); // Configuration failure must not consume an activation.
  const match = input.key && isValidLicenseKeyFormat(input.key) ? await findLicenseByKey(input.key) : null;
  const proposedId = randomId(16);
  let result: DeviceLicenseResult = { status: 503, body: { error: "Activation did not commit" } };
  await getStorage().mutateAuthState((state) => {
    const now = Date.now(), at = new Date(now).toISOString();
    const retryAfter = rate(state, input.binding, "claim", now);
    if (retryAfter) { result = { status: 429, body: { error: "Too many activation attempts; retry later", retryAfter }, retryAfter }; return state; }
    const bearerDevice = authenticatedDevice(input, state);
    const boundDevices = state.devices.filter((device) => device.deviceBinding === input.binding);
    if (boundDevices.length > 1) { result = { status: 409, body: { error: "Ambiguous installation binding; explicit recovery required" } }; return state; }
    let device = bearerDevice ?? boundDevices[0];
    const fail = (message: string, status = 403) => { result = { status, body: { error: message } }; return state; };
    if (bearerDevice?.deviceBinding && bearerDevice.deviceBinding !== input.binding) return fail("Device is bound to a different installation");
    if (bearerDevice && boundDevices[0] && boundDevices[0].id !== bearerDevice.id) return fail("Installation is already bound to another device");
    // A saved pre-upgrade account key must not shadow the frozen entitlement.
    // The exemption still requires this exact previously paired device bearer;
    // a supplied key or matching installation UUID cannot grant it alone.
    if (bearerDevice && adminDevice(bearerDevice, state)) {
      device = { ...bearerDevice, deviceBinding: input.binding, licenseStatus: "active", lastSeenAt: at };
      state.devices = state.devices.map((entry) => entry.id === device!.id ? device! : entry);
      if (!bearerDevice.deviceBinding) event(state, { action: "admin-bind", licenseId: null, deviceId: device.id }, now);
      result = { status: 200, body: { deviceId: device.id, token: input.bearer!, name: device.name, role: device.role,
        licenseToken: signer.issue({ deviceId: device.id, deviceBinding: input.binding,
          keyFingerprint: sha256Hex(input.key ?? `admin:${device.id}`), status: "active", nonce: input.nonce }, now) } };
      return state;
    }
    if (!input.key) return fail("Enter a device license key; this device has no migrated admin entitlement");
    const license = match ? state.licenses.find((entry) => entry.id === match.id && entry.keyHash === match.keyHash &&
      (!entry.keyFingerprint || entry.keyFingerprint === sha256Hex(input.key!))) : undefined;
    if (!license) return fail("Invalid device license key", 404);
    const status = deviceLicenseStatus(license, now);
    if (status !== "active") return fail(`Device license is ${status}`);
    const owner = ownerOf(license, state);
    if (!owner || !state.users.some((user) => user.id === owner)) return fail("License needs an existing owner assigned by an administrator");
    if (device && device.userId !== owner) return fail("License and device belong to different owners");
    // A caller-selected UUID identifies a record; it never authenticates it.
    // Do not reissue or replace an existing bearer using only UUID + license.
    // A lost first response needs explicit recovery, not credential disclosure.
    if (device && !bearerDevice) {
      result = { status: 409, body: { code: "device_credential_required",
        error: "This installation is already activated. Its saved device credential is required; contact support for recovery" } };
      return state;
    }
    const activations = license.activations ?? [];
    const existing = activations.find((entry) => entry.deviceBinding === input.binding);
    const maximum = license.maxActivations ?? 1;
    if (!Number.isInteger(maximum) || maximum < 1 || maximum > 100) return fail("Invalid activation limit; explicit recovery required");
    if (!existing && activations.length >= maximum) return fail("License activation limit reached; existing device bindings are locked", 409);
    if (existing && (!device || existing.deviceId !== device.id)) return fail("Bound device record is unavailable; explicit recovery required", 409);
    if (!device && state.devices.some((entry) => entry.id === proposedId)) return fail("Device ID collision; retry activation", 409);
    const id = device?.id ?? proposedId;
    const token = bearerDevice ? input.bearer! : signer.deviceToken(license.id, id, input.binding);
    const activated: DeviceRecord = { ...(device ?? { id, userId: owner, name: input.name, role: "worker", pairedAt: at }),
      tokenHash: sha256Hex(token), deviceBinding: input.binding, licenseId: license.id, licenseStatus: "active", lastSeenAt: at };
    state.devices = device ? state.devices.map((entry) => entry.id === id ? activated : entry) : [...state.devices, activated];
    state.licenses = state.licenses.map((entry) => entry.id === license.id ? { ...entry, ownerUserId: owner,
      keyFingerprint: sha256Hex(input.key!), lastValidatedAt: at,
      activations: existing ? activations.map((entry) => entry.deviceId === id ? { ...entry, lastCheckedAt: at } : entry)
        : [...activations, { deviceId: id, deviceBinding: input.binding, activatedAt: at, lastCheckedAt: at }] } : entry);
    if (!existing) event(state, { action: "activate-device", licenseId: license.id, deviceId: id }, now);
    result = { status: 200, body: { deviceId: id, token, name: activated.name, role: activated.role,
      licenseToken: signer.issue({ deviceId: id, deviceBinding: input.binding, keyFingerprint: sha256Hex(input.key),
        status: "active", nonce: input.nonce, expiresAt: license.expiresAt }, now) } };
    return state;
  });
  return result;
}

export async function validateDeviceLicense(input: Input): Promise<DeviceLicenseResult> {
  const signer = loadLicenseSigner();
  let result: DeviceLicenseResult = { status: 503, body: { error: "Validation did not commit" } };
  await getStorage().mutateAuthState((state) => {
    const now = Date.now(), at = new Date(now).toISOString();
    const retryAfter = rate(state, input.binding, "validate", now);
    if (retryAfter) { result = { status: 429, body: { error: "Too many license checks; retry later", retryAfter }, retryAfter }; return state; }
    const device = authenticatedDevice(input, state);
    if (!device) { result = { status: 401, body: { error: "Device authentication required" } }; return state; }
    // Keep this endpoint available after key revocation so the phone can verify a signed denial.
    const license = state.licenses.find((entry) => entry.id === device.licenseId);
    const admin = adminDevice(device, state);
    let status: DeviceLicenseStatus = admin ? "active" : deviceLicenseStatus(license, now);
    let reason = status === "active" ? "Validated" : `License ${status}`;
    const storedFingerprint = license?.keyFingerprint ?? "0".repeat(64);
    const fingerprint = input.key ? sha256Hex(input.key) : admin ? sha256Hex(`admin:${device.id}`) : storedFingerprint;
    if (device.deviceBinding !== input.binding || (!admin && (ownerOf(license, state) !== device.userId ||
        !license?.activations?.some((entry) => entry.deviceId === device.id && entry.deviceBinding === input.binding)))) {
      status = "invalid"; reason = "Device binding or license activation does not match";
    } else if (!admin && input.key && sha256Hex(input.key) !== storedFingerprint) {
      status = "invalid"; reason = "License key does not match the bound activation";
    }
    const licenseToken = signer.issue({ deviceId: device.id, deviceBinding: input.binding,
      keyFingerprint: fingerprint, status, nonce: input.nonce, expiresAt: status === "active" && !admin ? license?.expiresAt : null, reason }, now);
    if (status !== device.licenseStatus) event(state, { action: `status-${status}`, licenseId: license?.id ?? null, deviceId: device.id, detail: reason }, now);
    state.devices = state.devices.map((entry) => entry.id === device.id ? { ...entry, lastSeenAt: at, licenseStatus: status } : entry);
    if (status === "active" && license && !admin) state.licenses = state.licenses.map((entry) => entry.id === license.id ? {
      ...entry, lastValidatedAt: at, activations: entry.activations?.map((activation) => activation.deviceId === device.id ? { ...activation, lastCheckedAt: at } : activation),
    } : entry);
    result = { status: 200, body: { licenseToken, valid: status === "active", revoked: status === "revoked",
      expiresAt: admin ? null : license?.expiresAt ?? null } };
    return state;
  });
  return result;
}

export async function manageDeviceLicense(id: string, actorUserId: string, patch: {
  action?: "enable" | "delete"; label?: string; note?: string; ownerUserId?: string;
}): Promise<DeviceLicenseResult> {
  let result: DeviceLicenseResult = { status: 404, body: { error: "License not found" } };
  try {
    await getStorage().mutateAuthState((state) => {
      requireCurrentConsoleOwner(state.users, actorUserId);
      const license = state.licenses.find((entry) => entry.id === id), now = Date.now();
      if (!license) return state;
      if (license.deletedAt) { result = { status: 410, body: { error: "Deleted key cannot be restored; bindings and history retained" } }; return state; }
      if (patch.ownerUserId && (!state.users.some((user) => user.id === patch.ownerUserId) ||
          ((license.activations?.length ?? 0) > 0 && ownerOf(license, state) !== patch.ownerUserId))) {
        result = { status: 409, body: { error: "Owner must exist and cannot change after device activation" } }; return state;
      }
      const next = { ...license, ...(patch.label !== undefined ? { label: patch.label } : {}),
        ...(patch.note !== undefined ? { note: patch.note } : {}), ...(patch.ownerUserId ? { ownerUserId: patch.ownerUserId } : {}),
        ...(patch.action === "enable" ? { revokedAt: null } : {}),
        ...(patch.action === "delete" ? { deletedAt: new Date(now).toISOString(), revokedAt: license.revokedAt ?? new Date(now).toISOString() } : {}) };
      state.licenses = state.licenses.map((entry) => entry.id === id ? next : entry);
      if (!license.kind && license.activatedBy && license.activatedAt) state.users = state.users.map((user) => {
        if (user.email.toLowerCase() !== license.activatedBy!.toLowerCase()) return user;
        if (patch.action === "enable" && user.licensedAt === null && licenseValidity(next).valid)
          return { ...user, licensedAt: license.activatedAt };
        if (patch.action === "delete" && user.licensedAt === license.activatedAt) {
          const replacement = state.licenses.find((entry) => entry.id !== id && !entry.kind &&
            entry.activatedBy?.toLowerCase() === user.email.toLowerCase() && entry.activatedAt && licenseValidity(entry).valid);
          return { ...user, licensedAt: replacement?.activatedAt ?? null };
        }
        return user;
      });
      event(state, { action: patch.action ?? "edit", licenseId: id, actorUserId }, now);
      result = { status: 200, body: { id, action: patch.action ?? "edit" } };
      return state;
    });
  } catch (error) {
    if (error instanceof ConsoleOwnerRequiredError) return { status: 403, body: { error: error.message } };
    throw error;
  }
  return result;
}
