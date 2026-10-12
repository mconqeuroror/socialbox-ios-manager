/** Bounded encrypted transport; no plaintext or public blob URLs. */
export const BACKUP_PART_BYTES = 1024 * 1024;
export const BACKUP_MAX_BYTES = 200 * BACKUP_PART_BYTES;
export interface BackupPart { key: string; size: number; checksum: string }
export interface BackupUpload { expiresAt: number; tokenHash: string; received: number[] }
export function backupPartSize(size: number, index: number): number {
  return Math.min(BACKUP_PART_BYTES, size - index * BACKUP_PART_BYTES);
}

/** Bound independent private-object deletions so large backups fit a function run. */
export async function deleteBackupParts(parts: readonly BackupPart[], storage: { deleteBlob(key: string): Promise<void> }): Promise<void> {
  for (let offset=0; offset<parts.length; offset+=8) {
    const results=await Promise.allSettled(parts.slice(offset,offset+8).map(part=>storage.deleteBlob(part.key)));
    const failed=results.find(result=>result.status==="rejected");
    if(failed?.status==="rejected") throw failed.reason;
  }
}
