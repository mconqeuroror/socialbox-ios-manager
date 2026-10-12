import { createHash } from "node:crypto";
import catalog from "../data/socialbox-releases.json";
import { getStorage } from "./storage";
import { emptyReleaseState, validateCandidate, type Candidate, type ReleaseState } from "./socialbox-release-policy";

/** Build-owned catalog: no browser-supplied binary URLs, signatures, version numbers or blockers. */
export function validateRepositorySnapshot(c: Candidate): void {
  validateCandidate(c);
  if (Object.keys(c.files).length > 12) throw new Error("Oversized repository snapshot");
  for (const [name, file] of Object.entries(c.files)) {
    if (!/^(Release|InRelease|Release\.gpg|Packages|Packages\.gz|key\.asc|by-hash\/SHA256\/[a-f0-9]{64})$/.test(name)) throw new Error("Unsafe repository file");
    if (!file || typeof file.base64 !== "string" || file.base64.length > 700000) throw new Error("Oversized repository file");
    const bytes = Buffer.from(file.base64, "base64");
    if (bytes.length > 512 * 1024 || bytes.toString("base64") !== file.base64
        || createHash("sha256").update(bytes).digest("hex") !== file.sha256) throw new Error("Repository snapshot changed");
    if (name.startsWith("by-hash/") && !name.endsWith(file.sha256)) throw new Error("Invalid repository hash path");
  }
}
export function releaseCandidates(): Candidate[] {
  if (catalog.schemaVersion !== 1) throw new Error("Unsupported release catalog");
  const candidates = catalog.candidates as Candidate[];
  const ids = new Set<string>();
  for (const c of candidates) {
    validateRepositorySnapshot(c);
    if (c.artifactURL && process.env.APT_BLOB_HOST && new URL(c.artifactURL).hostname !== process.env.APT_BLOB_HOST.trim()) throw new Error("Repository store mismatch");
    if (ids.has(c.id)) throw new Error("Duplicate release candidate");
    ids.add(c.id);
  }
  return candidates;
}
export async function releaseState(): Promise<ReleaseState> {
  const rows = await getStorage().readCollection<ReleaseState>("socialbox-releases");
  if (rows.length > 1 || (rows.length && rows[0].id !== "stable")) throw new Error("Invalid release state");
  return rows[0] || emptyReleaseState();
}
export async function mutateRelease(change: (state: ReleaseState) => ReleaseState): Promise<ReleaseState> {
  let result = emptyReleaseState();
  await getStorage().mutateCollection<ReleaseState>("socialbox-releases", rows => {
    if (rows.length > 1 || (rows.length && rows[0].id !== "stable")) throw new Error("Invalid release state");
    result = change(rows[0] || emptyReleaseState());
    return [result];
  });
  return result;
}
