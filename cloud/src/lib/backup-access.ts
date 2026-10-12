import type { AuthState, BackupRecord } from "./storage";
import type { AuthenticatedDevice } from "./devices";
import { licenseValidity } from "./licenses";

export interface BackupDeviceScope { deviceId: string; userId: string; licenseId: string | null }

/** Recheck the current token, owner, license and immutable activation binding.
 * Legacy paired devices retain access to their own backups only. A license ID
 * is captured at upload; old records never inherit cross-device access later.
 */
export function backupDeviceScope(auth: AuthenticatedDevice, state: AuthState): BackupDeviceScope | null {
  const device = state.devices.find(d => d.id === auth.device.id && d.userId === auth.userId &&
    d.tokenHash && d.tokenHash === auth.device.tokenHash);
  if (!device || !state.users.some(user => user.id === device.userId)) return null;
  if (!device.licenseId) {
    if (device.licenseStatus && device.licenseStatus !== "active") return null;
    return { deviceId: device.id, userId: device.userId, licenseId: null };
  }
  const license = state.licenses.find(l => l.id === device.licenseId);
  if (!license || !licenseValidity(license).valid) return null;
  const owner = license.ownerUserId ?? state.users.find(user =>
    user.email.toLowerCase() === license.activatedBy?.toLowerCase())?.id;
  if (owner !== device.userId || !device.deviceBinding || !license.activations?.some(activation =>
    activation.deviceId === device.id && activation.deviceBinding === device.deviceBinding)) return null;
  return { deviceId: device.id, userId: device.userId, licenseId: license.id };
}

export function deviceMayAccessBackup(scope: BackupDeviceScope | null, backup: BackupRecord): boolean {
  if (!scope || scope.userId !== backup.userId) return false;
  return backup.deviceId === scope.deviceId || (!!scope.licenseId && backup.licenseId === scope.licenseId);
}
