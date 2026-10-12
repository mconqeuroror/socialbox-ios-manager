/** Release policy for the retained rootless package; independent of the RedditBox APT lanes. */
export const SOCIALBOX_PACKAGE = "com.socialbox"; // Installed identity: upgrades must not create another app.
export const RELEASE_CHECKS = ["backup_restore", "upgrade_data", "launch_switch", "proxy_failure", "license_activation"] as const;
export type ReleaseCheck = typeof RELEASE_CHECKS[number];
export type Candidate = {
  id: string; sequence: number; packageVersion: string; sha256: string; size: number;
  architecture: "iphoneos-arm64"; minimumIOS: "16.0"; supportedFrom: string[];
  notes: string; commit: string; blockers: string[];
  artifactURL: string | null;
  /** Signed, immutable flat APT snapshot produced by the Mac preparation tool. */
  files: Record<string, { base64: string; sha256: string }>;
};
export type TestReceipt = { candidateID: string; sha256: string; checks: Record<ReleaseCheck, string>; actor: string; at: string };
export type ReleaseState = {
  id: "stable"; revision: number; current: string | null; receipts: TestReceipt[];
  history: { candidateID: string; sha256: string; actor: string; at: string }[];
};
const hash = /^[a-f0-9]{64}$/;
export function versionSequence(value: unknown): number | null {
  if (typeof value !== "string" || !/^3\.1\.0-1\+socialbox\.[1-9][0-9]{0,5}$/.test(value)) return null;
  return Number(value.split(".").at(-1));
}
export function validateCandidate(value: Candidate): void {
  if (!value || value.id !== `socialbox-${value.sequence}` || versionSequence(value.packageVersion) !== value.sequence
      || !hash.test(value.sha256) || !Number.isInteger(value.size) || value.size <= 0 || value.size > 512 * 1024 * 1024
      || value.architecture !== "iphoneos-arm64" || value.minimumIOS !== "16.0"
      || !Array.isArray(value.supportedFrom) || value.supportedFrom.length !== 1
      || versionSequence(value.supportedFrom[0]) !== value.sequence - 1
      || typeof value.notes !== "string" || value.notes.length < 1 || value.notes.length > 2000
      || !/^[a-f0-9]{40}$/.test(value.commit) || !Array.isArray(value.blockers)
      || value.blockers.some(v => typeof v !== "string" || v.length < 1 || v.length > 500)
      || !value.files || typeof value.files !== "object") throw new Error("Invalid release candidate");
  if (value.artifactURL !== null) {
    const url = new URL(value.artifactURL);
    if (url.protocol !== "https:" || !/^[a-z0-9][a-z0-9-]*\.public\.blob\.vercel-storage\.com$/.test(url.hostname)
        || url.username || url.password || url.port || url.search || url.hash
        || url.pathname !== `/apt/socialbox/artifacts/${value.sha256}/socialbox_${value.sequence}_iphoneos-arm64.deb`)
      throw new Error("Invalid immutable package URL");
  }
}
export function emptyReleaseState(): ReleaseState {
  return { id: "stable", revision: 0, current: null, receipts: [], history: [] };
}
export function releaseBlockers(candidate: Candidate, state: ReleaseState): string[] {
  const failures = [...candidate.blockers];
  if (!candidate.artifactURL || !["Release", "InRelease", "Release.gpg", "Packages", "Packages.gz", "key.asc"].every(k => candidate.files[k]))
    failures.push("The immutable package and signed repository have not been prepared.");
  const receipt = state.receipts.find(r => r.candidateID === candidate.id && r.sha256 === candidate.sha256);
  if (!receipt || RELEASE_CHECKS.some(k => !receipt.checks[k])) failures.push("Complete every device acceptance check for this exact package.");
  return failures;
}
export function attestRelease(state: ReleaseState, candidate: Candidate, checks: Record<ReleaseCheck, string>, actor: string, at: string): ReleaseState {
  validateCandidate(candidate);
  if (!checks || RELEASE_CHECKS.some(k => typeof checks[k] !== "string" || checks[k].trim().length < 12 || checks[k].length > 1000))
    throw new Error("Describe the observed result for each of the five device checks (12–1000 characters).");
  return { ...state, revision: state.revision + 1, receipts: [...state.receipts.filter(r => r.candidateID !== candidate.id),
    { candidateID: candidate.id, sha256: candidate.sha256,
      checks: Object.fromEntries(RELEASE_CHECKS.map(k => [k, checks[k].trim()])) as Record<ReleaseCheck, string>, actor, at }] };
}
export function promoteRelease(state: ReleaseState, candidate: Candidate, candidates: Candidate[], expectedRevision: number, actor: string, at: string): ReleaseState {
  validateCandidate(candidate);
  if (state.current === candidate.id) return state; // Retry after a lost response never republishes another artifact.
  if (state.revision !== expectedRevision) throw new Error("Release state changed. Refresh and review it again.");
  const blockers = releaseBlockers(candidate, state);
  if (blockers.length) throw new Error(blockers.join(" "));
  if (state.current) {
    const previous = candidates.find(c => c.id === state.current);
    if (!previous || candidate.sequence <= previous.sequence || !candidate.supportedFrom.includes(previous.packageVersion))
      throw new Error("This candidate has no tested upgrade path from the current public release.");
  }
  return { ...state, revision: state.revision + 1, current: candidate.id,
    history: [...state.history, { candidateID: candidate.id, sha256: candidate.sha256, actor, at }] };
}
export function publicRelease(candidate: Candidate | undefined, state: ReleaseState) {
  const event = state.history.find(e => e.candidateID === candidate?.id && e.sha256 === candidate?.sha256);
  if (!candidate || !event || releaseBlockers(candidate, state).length) return { schemaVersion: 1, channel: "stable", available: false };
  return { schemaVersion: 1, channel: "stable", available: true, package: SOCIALBOX_PACKAGE,
    packageVersion: candidate.packageVersion, sequence: candidate.sequence, supportedFrom: candidate.supportedFrom,
    architecture: candidate.architecture, minimumIOS: candidate.minimumIOS, publishedAt: event.at,
    notes: candidate.notes, sha256: candidate.sha256, updateURL: "https://redditspoof.vercel.app/updates" };
}
