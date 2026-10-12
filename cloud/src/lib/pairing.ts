import { getStorage, type DeviceRecord, type DeviceRole, type PairingCodeRecord } from "./storage";
import { generateDeviceToken, generatePairingCode, nowIso, randomId, sha256Hex } from "./ids";

const CODE_TTL_MS = 15 * 60 * 1000;

class PairingFailure extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

export function isDeviceRole(value: unknown): value is DeviceRole {
  return value === "factory" || value === "worker";
}

export async function createPairing(
  userId: string,
  name: string,
  role: DeviceRole
): Promise<{ deviceId: string; pairingCode: string; expiresAt: string }> {
  const storage = getStorage();
  const now = nowIso();
  const deviceId = randomId(8);
  const pairingCode = generatePairingCode();
  const expiresAt = new Date(Date.now() + CODE_TTL_MS).toISOString();

  const device: DeviceRecord = {
      id: deviceId,
      userId,
      name,
      role,
      tokenHash: null,
      pairedAt: now,
      lastSeenAt: now,
  };
  const pairing: PairingCodeRecord = {
      id: randomId(8),
      code: pairingCode,
      userId,
      deviceId,
      createdAt: now,
      expiresAt,
      consumedAt: null,
      consumedByDeviceId: null,
  };
  await storage.mutateAuthState((state) => {
    if (!state.users.some((user) => user.id === userId)) {
      throw new PairingFailure("Pairing owner no longer exists", 404);
    }
    if (state.devices.some((entry) => entry.id === deviceId) ||
        state["pairing-codes"].some((entry) => entry.code === pairingCode)) {
      throw new PairingFailure("Pairing code collision; try again", 409);
    }
    return { ...state, devices: [...state.devices, device],
      "pairing-codes": [...state["pairing-codes"], pairing] };
  });

  return { deviceId, pairingCode, expiresAt };
}

export async function claimPairing(
  pairingCode: string
): Promise<
  { deviceId: string; token: string; role: DeviceRole; name: string } | { error: string; status: number }
> {
  const storage = getStorage();
  const code = pairingCode.toUpperCase().trim();
  const token = generateDeviceToken();
  const tokenHash = sha256Hex(token);
  try {
    const committed = await storage.mutateAuthState((state) => {
      // Validate current records on EVERY CAS attempt, including elapsed TTL.
      const now = Date.now();
      const matches = state["pairing-codes"].filter((entry) => entry.code === code);
      const record = matches.length === 1 ? matches[0] : undefined;
      if (!record || !(Date.parse(record.expiresAt) > now)) {
        throw new PairingFailure("Invalid or expired pairing code", 404);
      }
      if (record.consumedAt || record.consumedByDeviceId) {
        throw new PairingFailure("Pairing code already claimed", 409);
      }
      const device = state.devices.find((entry) => entry.id === record.deviceId);
      if (!device || device.userId !== record.userId ||
          !state.users.some((user) => user.id === record.userId)) {
        throw new PairingFailure("Pairing device or owner no longer exists", 404);
      }
      if (device.tokenHash) throw new PairingFailure("Pairing code already claimed", 409);
      const at = new Date(now).toISOString();
      return {
        ...state,
        "pairing-codes": state["pairing-codes"].map((entry) => entry.id === record.id
          ? { ...entry, consumedAt: at, consumedByDeviceId: device.id } : entry),
        devices: state.devices.map((entry) => entry.id === device.id
          ? { ...entry, tokenHash, lastSeenAt: at } : entry),
      };
    });
    const device = committed.devices.find((entry) => entry.tokenHash === tokenHash);
    if (!device) throw new Error("Committed pairing token is unavailable");
    return { deviceId: device.id, token, role: device.role, name: device.name };
  } catch (error) {
    if (error instanceof PairingFailure) return { error: error.message, status: error.status };
    throw error;
  }
}

export async function activeCodesForUser(userId: string): Promise<{ code: string; expiresAt: string }[]> {
  const storage = getStorage();
  const all = await storage.readCollection<PairingCodeRecord>("pairing-codes");
  return all
    .filter((c) => c.userId === userId && !c.consumedAt && new Date(c.expiresAt) > new Date())
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
    .map((c) => ({ code: c.code, expiresAt: c.expiresAt }));
}
