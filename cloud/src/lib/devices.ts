import { getStorage, type DeviceRecord } from "./storage";
import { sha256Hex } from "./ids";

export interface AuthenticatedDevice {
  device: DeviceRecord;
  userId: string;
}

/**
 * Authenticate a request via `Authorization: Bearer <deviceToken>`.
 * Returns the device record and owning user id, or null.
 * Rechecks token ownership while committing lastSeenAt, before returning the
 * authenticated device. A concurrent token change cannot authenticate a stale record.
 */
export async function getDeviceFromRequest(req: Request): Promise<AuthenticatedDevice | null> {
  const auth = req.headers.get("authorization");
  if (!auth?.startsWith("Bearer ")) return null;
  const token = auth.slice("Bearer ".length).trim();
  if (!token || token.length !== 64 || !/^[0-9a-f]+$/.test(token)) return null;

  const storage = getStorage();
  const devices = await storage.readCollection<DeviceRecord>("devices");
  const tokenHash = sha256Hex(token);
  const device = devices.find((d) => d.tokenHash === tokenHash);
  if (!device) return null;

  const now = new Date().toISOString();
  const changed = new Error("Device authentication changed before commit");
  try {
    const state = await storage.mutateAuthState((state) => {
      const current = state.devices.find((d) => d.id === device.id &&
        d.userId === device.userId && d.tokenHash === tokenHash);
      if (!current || !state.users.some((user) => user.id === current.userId)) throw changed;
      return { ...state, devices: state.devices.map((d) => d.id === current.id ? { ...d, lastSeenAt: now } : d) };
    });
    const verified = state.devices.find((d) => d.id === device.id)!;
    return { device: verified, userId: verified.userId };
  } catch (error) {
    if (error === changed) return null;
    throw error;
  }
}
