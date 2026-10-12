import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash, randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { spawnSync } from "node:child_process";
import { aptPublisherConfiguration, createAptPublisher } from "./apt-publisher.mjs";
import { APT_LOCK_PATH, checkedRepository, resolveAptDownload } from "../src/lib/apt-policy.mjs";
import nextConfig from "../next.config.mjs";

const host = "aptfixture.public.blob.vercel-storage.com", token = "vercel_blob_rw_aptfixture_synthetic-token";
const configuration = aptPublisherConfiguration({ APT_BLOB_HOST: host, APT_BLOB_READ_WRITE_TOKEN: token,
  BLOB_READ_WRITE_TOKEN: "vercel_blob_rw_privatefixture_synthetic-other-token" });
const hash = (value) => createHash("sha256").update(value).digest("hex");
const artifact = Buffer.from("synthetic deb bytes: publisher does not replace package archive validation");
const filename = "com.redditbox_1.2.3_iphoneos-arm64.deb", pathname = `apt/redditbox/debs/${hash(artifact)}/${filename}`;
const entry = { version: "1.2.3", filename: `debs/${filename}`, sha256: hash(artifact), size: artifact.length,
  blobURL: `https://${host}/${pathname}`, control: { Package: "com.redditbox", Version: "1.2.3", Architecture: "iphoneos-arm64" } };
const manifest = { formatVersion: 1, package: "com.redditbox", architecture: "iphoneos-arm64", version: "1.2.3", blobHost: host,
  versions: [entry], requiresMDMReadoption: false, signingContractHash: "synthetic" };
class MockBlob {
  hiddenReads = 0;
  objects = new Map(); calls = []; serial = 0; throwAfterPut = false; afterPut = null; beforeDelete = null; alterUpload = false;
  store(name, bytes) {
    const value = { bytes: Buffer.from(bytes), etag: `etag-${++this.serial}`, pathname: name, url: `https://${host}/${name}` };
    this.objects.set(name, value); return value;
  }
  async put(name, body, options) {
    this.calls.push({ method: "put", name, options });
    assert.equal(options.token, token); assert.equal(options.access, "public"); assert.equal(options.allowOverwrite, false); assert.equal(options.addRandomSuffix, false);
    if (this.objects.has(name)) throw new Error("BlobPreconditionFailed");
    const chunks = [];
    if (typeof body === "string" || Buffer.isBuffer(body)) chunks.push(Buffer.from(body));
    else for await (const chunk of body) chunks.push(Buffer.from(chunk));
    if (this.objects.has(name)) throw new Error("BlobPreconditionFailed");
    const bytes = this.alterUpload && name !== APT_LOCK_PATH ? Buffer.from("corrupt") : Buffer.concat(chunks);
    const value = this.store(name, bytes);
    if (this.afterPut) await this.afterPut(name);
    if (this.throwAfterPut) { this.throwAfterPut = false; throw new Error("uncertain transport outcome"); }
    return { url: value.url, pathname: name, etag: value.etag };
  }
  async get(url, options) {
    this.calls.push({ method: "get", url, options });
    assert.equal(options.token, token); assert.equal(options.access, "public"); assert.equal(options.useCache, false);
    assert.equal(new URL(url).host, host);
    const name = new URL(url).pathname.slice(1), value = this.objects.get(name);
    if (!value || (name === APT_LOCK_PATH && this.hiddenReads-- > 0)) return null;
    return { statusCode: 200, stream: Readable.toWeb(Readable.from([value.bytes])),
      blob: { url: value.url, pathname: name, etag: value.etag, size: value.bytes.length } };
  }
  async del(url, options) {
    this.calls.push({ method: "del", url, options });
    assert.equal(options.token, token); assert(options.ifMatch);
    const name = new URL(url).pathname.slice(1);
    if (this.beforeDelete) await this.beforeDelete(name);
    const value = this.objects.get(name);
    if (!value || value.etag !== options.ifMatch) throw new Error("BlobPreconditionFailed");
    this.objects.delete(name);
  }
}

const parent = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const scratch = await fs.mkdtemp(path.join(parent, "apt-publication-test-"));
const file = path.join(scratch, filename); await fs.writeFile(file, artifact);
let count = 0;
const check = async (name, fn) => { await fn(); count++; console.log(`PASS ${name}`); };
try {
  await check("rootful artifacts use their own architecture/path under the shared publisher lock", async () => {
    const rootful = JSON.parse(JSON.stringify(manifest).replaceAll("iphoneos-arm64", "iphoneos-arm").replaceAll("/apt/redditbox/", "/apt/redditbox-rootful/"));
    const rootfulName = filename.replace("iphoneos-arm64", "iphoneos-arm");
    assert.equal(checkedRepository(rootful, host, "iphoneos-arm"), rootful);
    assert.throws(() => checkedRepository(rootful, host));
    assert.equal(resolveAptDownload(rootful, rootfulName, host, "iphoneos-arm").url, rootful.versions[0].blobURL);
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID();
    const lock = await publisher.lock(owner);
    const rootfulPath = `apt/redditbox-rootful/debs/${hash(artifact)}/${rootfulName}`;
    assert.equal((await publisher.upload({ owner, etag: lock.etag, file, pathname: rootfulPath })).pathname, rootfulPath);
    await assert.rejects(publisher.upload({ owner, etag: lock.etag, file, pathname: rootfulPath.replace("redditbox-rootful", "redditbox") }));
    await assert.rejects(createAptPublisher(sdk, configuration).lock(randomUUID()));
  });
  await check("actual Next config disables caching for each mutable signed repository index only", async () => {
    const rules = await nextConfig.headers();
    const expected = ["Packages", "Packages.gz", "Release", "InRelease", "Release.gpg", "repository.json"];
    assert.equal(rules.length, expected.length * 2);
    assert.deepEqual(rules.map((rule) => rule.source).sort(), ["redditbox", "redditbox-rootful"].flatMap((repo) => expected.map((name) => `/apt/${repo}/${name}`)).sort());
    for (const rule of rules) assert.deepEqual(rule.headers, [{ key: "Cache-Control", value: "no-store" }]);
  });
  await check("plain Node CLI rejects incomplete, duplicate and unknown arguments without leaking credentials", async () => {
    const cli = path.join(parent, "cloud/scripts/apt-publish.mjs");
    const secret = "synthetic-secret-that-must-not-appear";
    for (const args of [[], ["invalid"], ["lock"], ["lock", "--owner"], ["lock", "--owner", randomUUID(), "--owner", randomUUID()],
      ["lock", "--owner", randomUUID(), "--token", secret], ["unlock", "--owner", randomUUID()], ["check", "--owner", randomUUID()],
      ["upload", "--owner", randomUUID(), "--etag", "fixture", "--file", file], ["lock", "--owner", randomUUID()]]) {
      const response = spawnSync(process.execPath, [cli, ...args], { encoding: "utf8", timeout: 10_000,
        env: { ...process.env, APT_BLOB_READ_WRITE_TOKEN: secret, APT_BLOB_HOST: host, BLOB_READ_WRITE_TOKEN: secret } });
      assert.equal(response.error, undefined); assert.equal(response.status, 1); assert.equal(response.stdout, "");
      assert(response.stderr.length > 0); assert(!response.stderr.includes(secret));
    }
  });
  await check("publisher configuration refuses private-store reuse, missing credentials and host mismatch before SDK access", async () => {
    for (const env of [{}, { APT_BLOB_HOST: host }, { APT_BLOB_HOST: host, APT_BLOB_READ_WRITE_TOKEN: "vercel_blob_rw_other_secret" },
      { APT_BLOB_HOST: host, APT_BLOB_READ_WRITE_TOKEN: token, BLOB_READ_WRITE_TOKEN: token },
      { APT_BLOB_HOST: host, APT_BLOB_READ_WRITE_TOKEN: token, BLOB_READ_WRITE_TOKEN: "vercel_blob_rw_aptfixture_other-secret" }])
      assert.throws(() => aptPublisherConfiguration(env));
  });
  await check("bundled manifest allows only exact listed package and rejects redirect/path/host tricks", async () => {
    assert.equal(checkedRepository(manifest, host), manifest);
    assert.equal(resolveAptDownload(manifest, filename, host).url, entry.blobURL);
    assert.equal(resolveAptDownload(manifest, "com.redditbox_0.0.1_iphoneos-arm64.deb", host), null);
    for (const name of ["../repository.json", "%2e%2e", "com.redditbox_1.2.3_iphoneos-arm.deb", filename + "?redirect=https://evil.invalid"])
      assert.equal(resolveAptDownload(manifest, name, host), null);
    for (const url of [entry.blobURL + "?download=1", entry.blobURL + "#fragment", entry.blobURL.replace(host, "evil.invalid"),
      entry.blobURL.replace("https:", "http:"), entry.blobURL.replace(host, `${host}:443`), entry.blobURL.replace("https://", "https://user@"),
      entry.blobURL.replace("/apt/", "/%61pt/"), entry.blobURL.replace(hash(artifact), "0".repeat(64))])
      assert.throws(() => checkedRepository({ ...manifest, versions: [{ ...entry, blobURL: url }] }, host));
    assert.throws(() => checkedRepository({ ...manifest, versions: [entry, entry] }));
    assert.throws(() => checkedRepository({ ...manifest, formatVersion: 2 }));
    assert.throws(() => checkedRepository({ ...manifest, versions: [{ ...entry, control: { ...entry.control, Package: "other" } }] }));
    const older = (version) => ({ ...entry, version, filename: `debs/com.redditbox_${version}_iphoneos-arm64.deb`,
      blobURL: entry.blobURL.replace("1.2.3", version), control: { ...entry.control, Version: version } });
    const retained = [entry, older("1.2.2"), older("1.1.9")];
    assert.equal(checkedRepository({ ...manifest, versions: retained }).versions.length, 3);
    assert.throws(() => checkedRepository({ ...manifest, versions: [...retained, older("1.0.0")] }));
    assert.throws(() => checkedRepository({ ...manifest, versions: [entry, older("1.2.4")] }));
    assert.throws(() => checkedRepository({ ...manifest, version: "1.2.2" }));
  });
  await check("two publishers race for one exclusive lock and only one owner wins", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owners = [randomUUID(), randomUUID()];
    const results = await Promise.allSettled(owners.map((owner) => publisher.lock(owner)));
    assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
    assert.equal(sdk.objects.size, 1);
    const current = JSON.parse(sdk.objects.get(APT_LOCK_PATH).bytes);
    assert(owners.includes(current.owner));
  });
  await check("same journal owner recovers an uncertain create but a different owner never steals even an old lock", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(); sdk.throwAfterPut = true;
    const first = await publisher.lock(owner), second = await publisher.lock(owner);
    assert.deepEqual(second, first);
    assert.equal(sdk.calls.filter((call) => call.method === "put").length, 1, "Resume must read the existing owner, without repeating PUT");
    sdk.store(APT_LOCK_PATH, JSON.stringify({ formatVersion: 1, owner, createdAt: "2000-01-01T00:00:00.000Z" }));
    await assert.rejects(publisher.lock(randomUUID()), /never steal/);
    assert.equal(JSON.parse(sdk.objects.get(APT_LOCK_PATH).bytes).owner, owner);
  });
  await check("newly created lock waits only for bounded visibility and verifies its owner", async () => {
    const sdk=new MockBlob(),delays=[];
    sdk.afterPut=async()=>{sdk.hiddenReads=3;};
    const publisher=createAptPublisher(sdk,configuration,{sleep:async ms=>delays.push(ms)}),owner=randomUUID();
    const lock=await publisher.lock(owner);assert.equal(lock.owner,owner);assert.equal(delays.length,3);
    assert.equal(sdk.calls.filter(c=>c.method==="put").length,1);
  });
  await check("create visibility retries are bounded and never overwrite or accept a replacement", async () => {
    const sdk=new MockBlob(),delays=[];sdk.afterPut=async()=>{sdk.hiddenReads=99;};
    const publisher=createAptPublisher(sdk,configuration,{sleep:async ms=>delays.push(ms)});
    await assert.rejects(publisher.lock(randomUUID()),/not visible/);
    assert.equal(delays.length,8);assert.equal(sdk.calls.filter(c=>c.method==="put").length,1);
    const changed=new MockBlob();changed.afterPut=async()=>{changed.hiddenReads=1;};
    const owner=randomUUID(),replacement=randomUUID();
    await assert.rejects(createAptPublisher(changed,configuration,{sleep:async()=>{
      changed.store(APT_LOCK_PATH,JSON.stringify({formatVersion:1,owner:replacement,createdAt:new Date().toISOString()}));
    }}).lock(owner),/never steal/);
    assert.equal(JSON.parse(changed.objects.get(APT_LOCK_PATH).bytes).owner,replacement);
  });
  await check("wrong owner and stale ETag cannot unlock a live publisher", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(), lock = await publisher.lock(owner);
    await assert.rejects(publisher.unlock(randomUUID(), lock.etag), /Another publisher/);
    await assert.rejects(publisher.unlock(owner, "old-etag"), /ETag changed/);
    assert.equal(sdk.calls.filter((call) => call.method === "del").length, 0);
  });
  await check("pre-promotion ownership check cannot recreate a missing or changed lock", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(), lock = await publisher.lock(owner);
    const writes = sdk.calls.filter((call) => call.method === "put").length;
    assert.deepEqual(await publisher.check(owner, lock.etag), lock);
    await assert.rejects(publisher.check(randomUUID(), lock.etag), /Another publisher/);
    await assert.rejects(publisher.check(owner, "stale-etag"), /ETag changed/);
    sdk.objects.delete(APT_LOCK_PATH);
    await assert.rejects(publisher.check(owner, lock.etag), /lock is missing/);
    assert.equal(sdk.objects.size, 0); assert.equal(sdk.calls.filter((call) => call.method === "put").length, writes);
  });
  await check("corrupt, oversized and malformed locks remain in place for explicit recovery", async () => {
    const owner = randomUUID();
    for (const contents of ["invalid JSON", "x".repeat(4097), JSON.stringify({ formatVersion: 2, owner, createdAt: new Date().toISOString() }),
      JSON.stringify({ formatVersion: 1, owner, createdAt: "invalid date" })]) {
      const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), before = sdk.store(APT_LOCK_PATH, contents);
      await assert.rejects(publisher.lock(owner)); await assert.rejects(publisher.unlock(owner, before.etag));
      assert.equal(sdk.objects.get(APT_LOCK_PATH), before); assert.equal(sdk.calls.filter((call) => call.method === "del").length, 0);
    }
  });
  await check("GET/DELETE race uses conditional deletion and preserves a replacement owner's lock", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(), replacement = randomUUID(), lock = await publisher.lock(owner);
    sdk.beforeDelete = async () => { sdk.store(APT_LOCK_PATH, JSON.stringify({ formatVersion: 1, owner: replacement, createdAt: new Date().toISOString() })); };
    await assert.rejects(publisher.unlock(owner, lock.etag), /Precondition/);
    assert.equal(JSON.parse(sdk.objects.get(APT_LOCK_PATH).bytes).owner, replacement);
    assert.equal(sdk.calls.find((call) => call.method === "del").options.ifMatch, lock.etag);
  });
  await check("upload proves local and origin hash/size, uses immutable paths and is safely replayable", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(), lock = await publisher.lock(owner);
    const first = await publisher.upload({ owner, etag: lock.etag, file, pathname });
    const second = await publisher.upload({ owner, etag: lock.etag, file, pathname });
    assert.deepEqual(second, first); assert.equal(first.sha256, hash(artifact)); assert.equal(first.size, artifact.length);
    assert(sdk.calls.filter((call) => call.method === "put").every((call) => call.options.allowOverwrite === false));
    assert.deepEqual(await publisher.unlock(owner, lock.etag), { ok: true, released: true });
    assert(!sdk.objects.has(APT_LOCK_PATH)); assert(sdk.objects.has(pathname));
  });
  await check("mismatched local hash and existing corrupted artifacts never overwrite the immutable path", async () => {
    const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(), lock = await publisher.lock(owner);
    await assert.rejects(publisher.upload({ owner, etag: lock.etag, file, pathname: pathname.replace(hash(artifact), "0".repeat(64)) }), /Local APT artifact/);
    assert.equal(sdk.calls.filter((call) => call.method === "put" && call.name !== APT_LOCK_PATH).length, 0);
    sdk.store(pathname, Buffer.from("bad"));
    await assert.rejects(publisher.upload({ owner, etag: lock.etag, file, pathname }), /different size/);
    assert.equal(sdk.objects.get(pathname).bytes.toString(), "bad"); assert(sdk.objects.has(APT_LOCK_PATH));
  });
  await check("lost lock or corrupted uploaded bytes never return a publishable artifact", async () => {
    for (const mode of ["lost-lock", "corrupt-bytes"]) {
      const sdk = new MockBlob(), publisher = createAptPublisher(sdk, configuration), owner = randomUUID(), lock = await publisher.lock(owner);
      if (mode === "lost-lock") sdk.afterPut = async (name) => { if (name !== APT_LOCK_PATH) sdk.store(APT_LOCK_PATH,
        JSON.stringify({ formatVersion: 1, owner: randomUUID(), createdAt: new Date().toISOString() })); };
      else sdk.alterUpload = true;
      await assert.rejects(publisher.upload({ owner, etag: lock.etag, file, pathname }));
      assert(sdk.objects.has(APT_LOCK_PATH)); assert.equal(sdk.calls.filter((call) => call.method === "del").length, 0);
    }
  });
  await check("SocialBox candidate reuses the same lock and immutable byte verification without weakening the default package policy", async () => {
    const sdk = new MockBlob(), owner = randomUUID(), socialPath = `apt/socialbox/artifacts/${hash(artifact)}/socialbox_16_iphoneos-arm64.deb`;
    const original = createAptPublisher(sdk, configuration), lock = await original.lock(owner);
    await assert.rejects(original.upload({owner,etag:lock.etag,file,pathname:socialPath}));
    const candidate = createAptPublisher(sdk, configuration, {artifactPolicy: value => {
      assert.equal(value,socialPath);return {sha256:hash(artifact),filename:"socialbox_16_iphoneos-arm64.deb"};
    }});
    assert.equal((await candidate.upload({owner,etag:lock.etag,file,pathname:socialPath})).sha256,hash(artifact));
    await assert.rejects(createAptPublisher(sdk,configuration).lock(randomUUID()));
    await candidate.unlock(owner,lock.etag);assert(sdk.objects.has(socialPath));
  });
  console.log(`${count} APT publication checks passed (mock Blob SDK; no live network writes)`);
} finally {
  const relative = path.relative(parent, scratch);
  assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("apt-publication-test-"));
  await fs.rm(scratch, { recursive: true, force: true });
}
