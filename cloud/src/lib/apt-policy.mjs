/** Shared by the public download route and the offline release publisher. */
export const APT_PACKAGE = "com.redditbox";
export const APT_ARCHITECTURE = "iphoneos-arm64";
// Both variants share a deployment, so publication uses one global lock.
export const APT_LOCK_PATH = "apt/redditbox/.publish-lock.json";
const VERSION = /^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$/;
const SHA256 = /^[0-9a-f]{64}$/;
const DEPENDENCIES = { "ai.akemi.appinst": /^2\.1\.1(?:-redditbox[1-9][0-9]{0,3})?$/, "ai.akemi.appsyncunified": /^116\.0$/ };

export class AptPolicyError extends Error {}
function requireValue(condition, message) { if (!condition) throw new AptPolicyError(message); }
export function validBlobHost(host) {
  return typeof host === "string" && /^[a-z0-9][a-z0-9-]*\.public\.blob\.vercel-storage\.com$/.test(host);
}
export function repositoryName(architecture = APT_ARCHITECTURE) {
  requireValue(architecture === "iphoneos-arm64" || architecture === "iphoneos-arm", "Unsupported APT architecture");
  return architecture === "iphoneos-arm" ? "redditbox-rootful" : "redditbox";
}
export function packageFilename(version, architecture = APT_ARCHITECTURE) {
  repositoryName(architecture);
  requireValue(typeof version === "string" && VERSION.test(version), "APT version must use numeric X.Y.Z format");
  return `${APT_PACKAGE}_${version}_${architecture}.deb`;
}
export function validPackageFilename(filename, architecture = APT_ARCHITECTURE) {
  if (typeof filename !== "string") return false;
  const dependency = /^(ai\.akemi\.(?:appinst|appsyncunified))_([^/]+)_(iphoneos-arm64|iphoneos-arm)\.deb$/.exec(filename);
  if (dependency) return dependency[3] === architecture && DEPENDENCIES[dependency[1]].test(dependency[2]);
  const match = /^com\.redditbox_([^/]+)_(iphoneos-arm64|iphoneos-arm)\.deb$/.exec(filename);
  return !!match && match[2] === architecture && VERSION.test(match[1]) && packageFilename(match[1], architecture) === filename;
}
export function checkedBlobURL(value, host, pathname) {
  requireValue(validBlobHost(host), "APT Blob host must name one exact public Vercel Blob store");
  let url;
  try { url = new URL(value); } catch { throw new AptPolicyError("Invalid APT Blob URL"); }
  requireValue(url.protocol === "https:" && url.hostname === host && !url.port && !url.username && !url.password &&
    !url.search && !url.hash && url.pathname === `/${pathname}` && value === `https://${host}/${pathname}`,
  "APT Blob URL does not match the allowlisted store and immutable artifact path");
  return url.href;
}
export function checkedArtifactPath(pathname) {
  requireValue(typeof pathname === "string", "APT artifact pathname is required");
  const match = /^apt\/(redditbox|redditbox-rootful)\/debs\/([0-9a-f]{64})\/([^/]+)$/.exec(pathname);
  requireValue(!!match && validPackageFilename(match[3], match[1] === "redditbox" ? "iphoneos-arm64" : "iphoneos-arm"), "APT artifact must use its SHA256 directory and canonical package filename");
  return { sha256: match[2], filename: match[3] };
}
/** @param {any} value @param {string | undefined} [expectedHost] */
export function checkedRepository(value, expectedHost = undefined, architecture = APT_ARCHITECTURE) {
  const repository = repositoryName(architecture);
  requireValue(value && typeof value === "object" && !Array.isArray(value) && value.formatVersion === 1,
    "Unsupported or invalid APT repository manifest");
  requireValue(value.package === APT_PACKAGE && value.architecture === architecture && validBlobHost(value.blobHost),
    "APT repository identity or public store is invalid");
  if (expectedHost !== undefined) requireValue(value.blobHost === expectedHost, "APT manifest store does not match this deployment");
  requireValue(Array.isArray(value.versions) && value.versions.length >= 1 && value.versions.length <= 3,
    "APT manifest must retain one to three versions");
  const seen = new Set();
  let previous = null;
  for (const entry of value.versions) {
    requireValue(entry && typeof entry === "object" && !Array.isArray(entry), "Invalid APT version entry");
    const filename = packageFilename(entry.version, architecture);
    requireValue(entry.filename === `debs/${filename}` && SHA256.test(entry.sha256) &&
      Number.isSafeInteger(entry.size) && entry.size > 0, "Invalid APT artifact filename, SHA256 or size");
    requireValue(!seen.has(entry.version), "APT manifest contains a duplicate version"); seen.add(entry.version);
    const parts = entry.version.split(".").map(Number);
    if (previous) {
      const changed = parts.findIndex((part, index) => part !== previous[index]);
      requireValue(changed >= 0 && parts[changed] < previous[changed], "APT versions must be ordered newest first");
    }
    previous = parts;
    requireValue(entry.control && typeof entry.control === "object" && !Array.isArray(entry.control) &&
      entry.control.Package === APT_PACKAGE && entry.control.Version === entry.version && entry.control.Architecture === architecture,
    "APT control identity does not match the artifact");
    checkedBlobURL(entry.blobURL, value.blobHost, `apt/${repository}/debs/${entry.sha256}/${filename}`);
  }
  requireValue(value.version === value.versions[0].version, "APT current version must match the first retained artifact");
  const dependencies = value.dependencies ?? [];
  requireValue(Array.isArray(dependencies) && dependencies.length <= 2, "Invalid dependency inventory");
  const packages = new Set();
  for (const entry of dependencies) {
    const packageID = entry?.control?.Package;
    requireValue(Object.hasOwn(DEPENDENCIES, packageID) && !packages.has(packageID) && typeof entry.version === "string" && DEPENDENCIES[packageID].test(entry.version), "Unsupported or duplicate dependency");
    packages.add(packageID);
    const filename = `${packageID}_${entry.version}_${architecture}.deb`;
    requireValue(entry.filename === `debs/${filename}` && entry.control.Architecture === architecture && entry.control.Version === entry.version && SHA256.test(entry.sha256) && Number.isSafeInteger(entry.size) && entry.size > 0 && entry.size <= 512 * 1024 * 1024, "Invalid dependency metadata");
    checkedBlobURL(entry.blobURL, value.blobHost, `apt/${repository}/debs/${entry.sha256}/${filename}`);
  }
  return value;
}
/** @param {any} repository @param {string} filename @param {string | undefined} [expectedHost] */
export function resolveAptDownload(repository, filename, expectedHost = undefined, architecture = APT_ARCHITECTURE) {
  if (!validPackageFilename(filename, architecture)) return null;
  const checked = checkedRepository(repository, expectedHost, architecture);
  const entry = [...checked.versions, ...(checked.dependencies ?? [])].find((version) => version.filename === `debs/${filename}`);
  return entry ? { url: entry.blobURL, sha256: entry.sha256, size: entry.size } : null;
}
