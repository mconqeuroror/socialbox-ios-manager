import { getStorage, type LicenseAuditRecord } from "./storage";
import { nowIso, randomId } from "./ids";

const AUDIT_CAP = 500;

export function keyIdPrefix(licenseId: string): string {
  return licenseId.slice(0, 8);
}

function toAuditRecord(entry: Omit<LicenseAuditRecord, "id" | "at">): LicenseAuditRecord {
  return {
    id: randomId(8),
    at: nowIso(),
    ...entry,
    keyIdPrefix: entry.keyIdPrefix || keyIdPrefix(entry.licenseId),
  };
}

export async function appendLicenseAudit(
  entry: Omit<LicenseAuditRecord, "id" | "at">
): Promise<LicenseAuditRecord> {
  const rec = toAuditRecord(entry);
  const storage = getStorage();
  await storage.mutateCollection<LicenseAuditRecord>("license-audit", (items) =>
    [rec, ...items].slice(0, AUDIT_CAP)
  );
  return rec;
}

export async function appendLicenseAuditMany(
  entries: Omit<LicenseAuditRecord, "id" | "at">[]
): Promise<void> {
  if (entries.length === 0) return;
  const recs = entries.map(toAuditRecord);
  const storage = getStorage();
  await storage.mutateCollection<LicenseAuditRecord>("license-audit", (items) =>
    [...recs.reverse(), ...items].slice(0, AUDIT_CAP)
  );
}

export async function listLicenseAudit(limit = 100): Promise<LicenseAuditRecord[]> {
  const storage = getStorage();
  const items = await storage.readCollection<LicenseAuditRecord>("license-audit");
  return [...items].sort((a, b) => b.at.localeCompare(a.at)).slice(0, limit);
}

export function publicAuditRow(row: LicenseAuditRecord) {
  return {
    id: row.id,
    at: row.at,
    action: row.action,
    actorUsername: row.actorUsername,
    keyIdPrefix: row.keyIdPrefix,
    expiresAt: row.expiresAt ?? null,
  };
}
