import fs from "node:fs/promises";
import { constants } from "node:fs";
import { createHash } from "node:crypto";
import { AptPolicyError, APT_LOCK_PATH, checkedArtifactPath, checkedBlobURL, validBlobHost } from "../src/lib/apt-policy.mjs";

const TOKEN = /^vercel_blob_rw_([A-Za-z0-9-]+)_(.+)$/;
export function aptPublisherConfiguration(env = process.env) {
  const token = env.APT_BLOB_READ_WRITE_TOKEN?.trim(), host = env.APT_BLOB_HOST?.trim();
  if (!token || !validBlobHost(host)) throw new AptPolicyError("Set dedicated APT_BLOB_READ_WRITE_TOKEN and exact APT_BLOB_HOST before publishing");
  const store = TOKEN.exec(token)?.[1]?.toLowerCase();
  if (!store || host !== `${store}.public.blob.vercel-storage.com`)
    throw new AptPolicyError("APT token store does not match the configured public Blob host");
  const privateToken = env.BLOB_READ_WRITE_TOKEN?.trim();
  if (privateToken && (privateToken === token || TOKEN.exec(privateToken)?.[1]?.toLowerCase() === store))
    throw new AptPolicyError("APT artifacts must use a different Blob store from private authentication and backup data");
  return { token, host };
}
function ownerValue(owner) {
  if (typeof owner !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(owner))
    throw new AptPolicyError("Publisher owner must be a journaled UUID");
  return owner.toLowerCase();
}
function etagValue(etag) {
  if (typeof etag !== "string" || !etag.length || etag.length > 512 || /[\r\n]/.test(etag))
    throw new AptPolicyError("A current publisher lock ETag is required");
  return etag;
}
async function digestStream(stream, maximum) {
  const hash = createHash("sha256"); let size = 0;
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > maximum) throw new AptPolicyError("APT artifact is larger than its declared size");
    hash.update(chunk);
  }
  return { sha256: hash.digest("hex"), size };
}

/** SDK injection tests the real ownership/hash policy without writing a live store. */
export function createAptPublisher(sdk, configuration, { sleep = ms => new Promise(resolve => setTimeout(resolve, ms)), artifactPolicy = checkedArtifactPath } = {}) {
  const { token, host } = configuration;
  const lockURL = `https://${host}/${APT_LOCK_PATH}`;
  const options = () => ({ token, abortSignal: AbortSignal.timeout(120_000) });
  async function read(pathname) {
    const response = await sdk.get(`https://${host}/${pathname}`, { ...options(), access: "public", useCache: false });
    if (!response) return null;
    if (response.statusCode !== 200 || !response.stream || response.blob.pathname !== pathname)
      throw new AptPolicyError("Blob origin did not return the exact publication object");
    checkedBlobURL(response.blob.url, host, pathname); etagValue(response.blob.etag);
    return response;
  }
  async function readLock(owner, expectedETag = undefined, existing = undefined) {
    const current = existing ?? await read(APT_LOCK_PATH);
    if (!current) throw new AptPolicyError("Publication lock is missing; publication must stop");
    if (!Number.isSafeInteger(current.blob.size) || current.blob.size < 1 || current.blob.size > 4096)
      throw new AptPolicyError("Publication lock is malformed and must be recovered explicitly");
    const chunks = []; let size = 0;
    for await (const chunk of current.stream) {
      size += chunk.length;
      if (size > 4096) throw new AptPolicyError("Publication lock is oversized and was retained");
      chunks.push(Buffer.from(chunk));
    }
    let value;
    try { value = JSON.parse(Buffer.concat(chunks).toString("utf8")); }
    catch { throw new AptPolicyError("Publication lock is corrupt and was retained"); }
    if (value?.formatVersion !== 1 || value.owner !== owner ||
        !Number.isFinite(Date.parse(value.createdAt)) || (expectedETag !== undefined && current.blob.etag !== etagValue(expectedETag)))
      throw new AptPolicyError("Another publisher owns this lock, or its ETag changed; never steal or expire it");
    return { owner, url: lockURL, pathname: APT_LOCK_PATH, etag: current.blob.etag };
  }
  async function awaitCreatedLock(owner, etag = undefined) {
    // Only a create acknowledgement can use this visibility window. Ordinary
    // pre-promotion checks still fail immediately on a missing/replaced lock.
    const delays = [200, 500, 1000, 2000, 4000, 8000, 15000, 30000];
    for (let attempt = 0; attempt <= delays.length; attempt++) {
      const current = await read(APT_LOCK_PATH);
      if (current) return readLock(owner, etag, current);
      if (attempt < delays.length) await sleep(delays[attempt]);
    }
    throw new AptPolicyError("Created publication lock is not visible yet; retain the journal and resume");
  }
  async function verifyArtifact(pathname, expectedHash, expectedSize) {
    const response = await read(pathname);
    if (!response || response.blob.size !== expectedSize) throw new AptPolicyError("Immutable APT artifact is missing or has a different size");
    const actual = await digestStream(response.stream, expectedSize);
    if (actual.sha256 !== expectedHash || actual.size !== expectedSize)
      throw new AptPolicyError("Immutable APT artifact bytes do not match their content-addressed pathname");
    return { url: response.blob.url, pathname, etag: response.blob.etag, ...actual };
  }
  return {
    async check(rawOwner, etag) {
      return readLock(ownerValue(rawOwner), etagValue(etag));
    },
    async lock(rawOwner) {
      const owner = ownerValue(rawOwner);
      // Resume an existing lock by reading it. Repeating PUT for an already
      // owned object is unnecessary and can disturb origin/cache visibility.
      const existing = await read(APT_LOCK_PATH);
      if (existing) return readLock(owner, undefined, existing);
      let created;
      try {
        created = await sdk.put(APT_LOCK_PATH, JSON.stringify({ formatVersion: 1, owner, createdAt: new Date().toISOString() }),
          { ...options(), access: "public", addRandomSuffix: false, allowOverwrite: false, cacheControlMaxAge: 60, contentType: "application/json" });
        checkedBlobURL(created.url, host, APT_LOCK_PATH); etagValue(created.etag);
      } catch (error) {
        // An uncertain create may already have succeeded. Only that same
        // journaled owner can recover it; another publisher is never replaced.
        try { return await awaitCreatedLock(owner); }
        catch (readError) { if (readError instanceof AptPolicyError) throw readError; throw error; }
      }
      return awaitCreatedLock(owner, created.etag);
    },
    async upload({ owner: rawOwner, etag, file, pathname }) {
      const owner = ownerValue(rawOwner), { sha256: expectedHash } = artifactPolicy(pathname);
      await readLock(owner, etagValue(etag));
      const info = await fs.lstat(file);
      if (!info.isFile() || info.isSymbolicLink() || info.size <= 0 || !Number.isSafeInteger(info.size))
        throw new AptPolicyError("APT upload source must be a nonempty regular .deb file");
      const descriptor = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
      try {
        const opened = await descriptor.stat();
        if (!opened.isFile() || opened.dev !== info.dev || opened.ino !== info.ino || opened.size !== info.size)
          throw new AptPolicyError("APT upload source changed before opening");
        const actual = await digestStream(descriptor.createReadStream({ start: 0, autoClose: false }), opened.size);
        if (actual.sha256 !== expectedHash || actual.size !== opened.size)
          throw new AptPolicyError("Local APT artifact does not match the requested SHA256 pathname");
        await readLock(owner, etag);
        let verified;
        const uploadStream = descriptor.createReadStream({ start: 0, autoClose: false });
        try {
          const uploaded = await sdk.put(pathname, uploadStream, {
            ...options(), access: "public", addRandomSuffix: false, allowOverwrite: false, multipart: true,
            cacheControlMaxAge: 31_536_000, contentType: "application/vnd.debian.binary-package",
          });
          checkedBlobURL(uploaded.url, host, pathname); etagValue(uploaded.etag);
        } catch {
          // Reuse an existing immutable path only after origin bytes prove the
          // exact hash and size. Never retry with allowOverwrite:true.
          verified = await verifyArtifact(pathname, expectedHash, opened.size);
        } finally { uploadStream.destroy(); }
        if (!verified) verified = await verifyArtifact(pathname, expectedHash, opened.size);
        await readLock(owner, etag);
        return verified;
      } finally { await descriptor.close(); }
    },
    async unlock(rawOwner, etag) {
      const lock = await readLock(ownerValue(rawOwner), etagValue(etag));
      // A replacement between GET and DELETE must fail its conditional delete.
      await sdk.del(lock.url, { ...options(), ifMatch: lock.etag });
      return { ok: true, released: true };
    },
  };
}
