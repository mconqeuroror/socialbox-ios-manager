/** Actual HTTP handlers, RSA signatures and auth CAS; no live service or real keys. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { createHash, generateKeyPairSync, randomUUID } from "node:crypto";
import { jwtVerify } from "jose";
import type { AuthState, LicenseRecord } from "../src/lib/storage";

async function main() {
  process.env.ADMIN_EMAIL = "admin@invalid.test";
  const cloud = path.resolve(path.dirname(process.argv[1]), ".."), parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "device-license-test-")), previous = process.cwd();
  process.chdir(scratch); delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-device-licensing-test-secret"; process.env.APP_URL = "https://license.invalid";
  const keypair = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const pem = keypair.privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  process.env.LICENSE_SIGNING_PRIVATE_KEY = pem;
  const sha = (value: string | Buffer) => createHash("sha256").update(value).digest("hex");
  const now = new Date().toISOString(), adminToken = "a".repeat(64), workerToken = "b".repeat(64), staleAdminToken = "c".repeat(64);
  const seed: AuthState = {
    users: ["admin", "tester"].map((id) => ({ id, email: `${id}@invalid.test`, passwordHash: "unused", role: id === "admin" ? "admin" : "user", licensedAt: now, createdAt: now })),
    licenses: [], "pairing-codes": [], devices: [
      { id: "pre-admin", userId: "admin", name: "Already paired admin", role: "factory", tokenHash: sha(adminToken), pairedAt: now, lastSeenAt: now },
      { id: "pre-admin-stale-key", userId: "admin", name: "Admin with old account key", role: "factory", tokenHash: sha(staleAdminToken), pairedAt: now, lastSeenAt: now },
      { id: "pending-admin", userId: "admin", name: "Unclaimed admin", role: "worker", tokenHash: null, pairedAt: now, lastSeenAt: now },
      { id: "pre-worker", userId: "tester", name: "Already paired tester", role: "worker", tokenHash: sha(workerToken), pairedAt: now, lastSeenAt: now },
    ],
  };
  await fs.mkdir(path.join(scratch, ".data"));
  await fs.writeFile(path.join(scratch, ".data/auth-state.json"), JSON.stringify({ version: 1, items: [{ ...seed, id: "auth-state", formatVersion: 1 }] }));
  const { getStorage, resetStorageAdapterForTests } = await import("../src/lib/storage");
  const { createSessionToken } = await import("../src/lib/auth");
  const { createPairing, claimPairing } = await import("../src/lib/pairing");
  const { activateLicenseForUser } = await import("../src/lib/licenses");
  const claim = await import("../src/app/api/devices/claim/route");
  const readiness = await import("../src/app/api/licenses/status/route");
  const validate = await import("../src/app/api/licenses/validate/route");
  const admin = await import("../src/app/api/admin/licenses/route");
  const manage = await import("../src/app/api/admin/licenses/[id]/route");
  const revoke = await import("../src/app/api/admin/licenses/[id]/revoke/route");
  const storage = getStorage();
  const request = (body?: unknown, token = "", method = "POST") => new Request("https://license.invalid/api/fixture", {
    method, headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const input = (identity: string, key?: string) => ({ deviceIdentity: identity, nonce: randomUUID(), ...(key ? { key } : {}) });
  const adminJWT = await createSessionToken({ id: "admin", email: "admin@invalid.test", username: "admin", role: "admin", licensed: true });
  const testerJWT = await createSessionToken({ id: "tester", email: "tester@invalid.test", username: "tester", role: "user", licensed: true });
  const verify = async (token: string, expected: { deviceId: string; identity: string; keyFingerprint: string; nonce: string; status: string }) => {
    const result = await jwtVerify(token, keypair.publicKey, { algorithms: ["RS256"], issuer: "https://license.invalid", audience: "redditbox-device" });
    assert.equal(result.protectedHeader.typ, "JWT");
    assert.equal(result.protectedHeader.kid, sha(keypair.publicKey.export({ format: "der", type: "pkcs1" })));
    const payload = result.payload;
    assert.equal(payload.v, 1); assert.equal(payload.sub, expected.deviceId); assert.equal(payload.deviceBinding, sha(expected.identity.toLowerCase()));
    assert.equal(payload.keyFingerprint, expected.keyFingerprint); assert.equal(payload.nonce, expected.nonce); assert.equal(payload.status, expected.status);
    assert(payload.exp! > payload.iat! && payload.exp! - payload.iat! <= 72 * 60 * 60);
    return payload;
  };
  const generate = async (body: object = {}) => {
    const response = await admin.POST(request(body, adminJWT)); assert.equal(response.status, 200, JSON.stringify(await response.clone().json()));
    return (await response.json()).licenses as { key: string; id: string; expiresAt: string | null }[];
  };
  let count = 0;
  const check = async (name: string, fn: () => Promise<void>) => { await fn(); count++; console.log(`PASS ${name}`); };
  let first: { key: string; id: string }, activation: { deviceId: string; token: string; licenseToken: string }, identity = randomUUID();
  try {
    await check("atomic migration freezes only already-claimed admin devices before later pairing", async () => {
      const state = await storage.readAuthState();
      assert.deepEqual(state.deviceLicensing!.adminDevices, [{ deviceId: "pre-admin", userId: "admin" }, { deviceId: "pre-admin-stale-key", userId: "admin" }]);
      const pairing = await createPairing("admin", "Paired after migration", "worker"), claimed = await claimPairing(pairing.pairingCode);
      assert(!("error" in claimed));
      assert.equal((await claim.POST(request(input(randomUUID()), claimed.token))).status, 403);
      assert.equal((await claim.POST(request(input(randomUUID()), workerToken))).status, 403);
      resetStorageAdapterForTests();
      assert.deepEqual((await getStorage().readAuthState()).deviceLicensing!.adminDevices, state.deviceLicensing!.adminDevices);
    });
    await check("readiness verifies signing identity and storage without consuming an activation or leaking secrets", async () => {
      const before = await getStorage().readAuthState();
      const response = await readiness.GET();
      assert.equal(response.status, 200);
      assert.equal(response.headers.get("cache-control"), "no-store");
      assert.deepEqual(await response.json(), { ready: true, issuer: "https://license.invalid",
        keyId: sha(keypair.publicKey.export({ format: "der", type: "pkcs1" })) });
      assert.deepEqual(await getStorage().readAuthState(), before);
      const logs: unknown[][] = [], original = console.error;
      console.error = (...args) => { logs.push(args); };
      try {
        process.env.LICENSE_SIGNING_PRIVATE_KEY = "synthetic-secret-that-must-not-be-logged";
        const failed = await readiness.GET();
        assert.equal(failed.status, 503);
        assert.deepEqual(await failed.json(), { ready: false, unavailable: "signing" });
        assert(!JSON.stringify(logs).includes(process.env.LICENSE_SIGNING_PRIVATE_KEY));
        process.env.LICENSE_SIGNING_PRIVATE_KEY = pem;
        const currentStorage = getStorage(), read = currentStorage.readAuthState;
        currentStorage.readAuthState = async () => { throw new Error("synthetic-private-record-that-must-not-be-logged"); };
        try {
          const failedStorage = await readiness.GET();
          assert.equal(failedStorage.status, 503);
          assert.deepEqual(await failedStorage.json(), { ready: false, unavailable: "storage" });
          assert(!JSON.stringify(logs).includes("synthetic-private-record"));
        } finally { currentStorage.readAuthState = read; }
      } finally { process.env.LICENSE_SIGNING_PRIVATE_KEY = pem; console.error = original; }
      assert.equal(logs.length, 2);
    });
    await check("migrated admin claims keyless with existing bearer and receives verifiable permanent entitlement", async () => {
      const adminIdentity = randomUUID(), body = input(adminIdentity);
      const response = await claim.POST(request(body, adminToken)); assert.equal(response.status, 200);
      const value = await response.json(); assert.equal(value.deviceId, "pre-admin"); assert.equal(value.token, adminToken);
      await verify(value.licenseToken, { deviceId: "pre-admin", identity: adminIdentity, keyFingerprint: sha("admin:pre-admin"), nonce: body.nonce, status: "active" });
      const second = input(adminIdentity), validation = await (await validate.POST(request(second, adminToken))).json();
      await verify(validation.licenseToken, { deviceId: "pre-admin", identity: adminIdentity, keyFingerprint: sha("admin:pre-admin"), nonce: second.nonce, status: "active" });
      assert.equal((await claim.POST(request(input(randomUUID()), adminToken))).status, 403, "admin binding remains immutable");
    });
    await check("frozen admin entitlement survives a saved revoked account key without consuming its activation slots", async () => {
      const oldKey = "ZZZZ-YYYY-XXXX-WWWW", uuid = randomUUID();
      const oldLicense: LicenseRecord = { id: "legacy-admin-key", keyHash: "unused-fingerprint-fixture", keyFingerprint: sha(oldKey),
        createdAt: "2020-01-01T00:00:00.000Z", activatedBy: "admin@invalid.test", activatedAt: "2020-01-01T00:00:00.000Z",
        revokedAt: "2020-02-01T00:00:00.000Z", expiresAt: "2020-03-01T00:00:00.000Z", activations: [], maxActivations: 1 };
      await storage.mutateCollection<LicenseRecord>("licenses", (items) => [...items, oldLicense]);
      const body = input(uuid, ` ${oldKey.toLowerCase()} `), response = await claim.POST(request(body, staleAdminToken));
      assert.equal(response.status, 200); const value = await response.json();
      assert.equal(value.deviceId, "pre-admin-stale-key"); assert.equal(value.token, staleAdminToken);
      const claims = await verify(value.licenseToken, { deviceId: value.deviceId, identity: uuid, keyFingerprint: sha(oldKey), nonce: body.nonce, status: "active" });
      assert.equal(claims.exp! - claims.iat!, 72 * 60 * 60, "Old account expiry must not shorten the frozen entitlement lease");
      const followup = input(uuid, oldKey), checked = await (await validate.POST(request(followup, staleAdminToken))).json();
      assert.equal(checked.valid, true); assert.equal(checked.expiresAt, null);
      await verify(checked.licenseToken, { deviceId: value.deviceId, identity: uuid, keyFingerprint: sha(oldKey), nonce: followup.nonce, status: "active" });
      const after = await storage.readAuthState();
      assert.deepEqual(after.licenses.find((entry) => entry.id === oldLicense.id), oldLicense);
      assert.equal(after.devices.find((entry) => entry.id === value.deviceId)!.licenseId, undefined);
      assert.equal(after.deviceLicensing!.events.filter((event) => event.action === "admin-bind" && event.deviceId === value.deviceId).length, 1);
      const later = await createPairing("admin", "Admin paired after frozen migration", "worker"), paired = await claimPairing(later.pairingCode);
      assert(!("error" in paired));
      assert.equal((await claim.POST(request(input(randomUUID(), oldKey), paired.token))).status, 403, "Later admin pairing must not gain the exemption");
      assert.equal((await claim.POST(request(input(uuid, oldKey)))).status, 403, "Known installation UUID without the existing bearer must not inherit admin access");
      assert.equal((await claim.POST(request(input(randomUUID(), oldKey), workerToken))).status, 403, "Ordinary paired device remains subject to key revocation");
      assert.equal((await claim.POST(request(input(randomUUID(), oldKey), staleAdminToken))).status, 403, "Admin installation binding remains immutable");
      const wrongBinding = input(randomUUID(), oldKey), denied = await (await validate.POST(request(wrongBinding, staleAdminToken))).json();
      await verify(denied.licenseToken, { deviceId: value.deviceId, identity: wrongBinding.deviceIdentity, keyFingerprint: sha(oldKey), nonce: wrongBinding.nonce, status: "invalid" });
    });
    await check("single generation defaults to one activation and creator ownership without exposing stored secrets", async () => {
      [first] = await generate();
      const state = await storage.readAuthState(), license = state.licenses.find((entry) => entry.id === first.id)!;
      assert.equal(license.kind, "device"); assert.equal(license.ownerUserId, "admin"); assert.equal(license.maxActivations, 1);
      assert.equal(license.expiresAt, null);
      assert(!JSON.stringify(state).includes(first.key));
      const listed = await (await admin.GET(request(undefined, adminJWT, "GET"))).json();
      assert(!JSON.stringify(listed).includes(first.key)); assert(!JSON.stringify(listed).includes("keyHash"));
      assert.equal(listed.licenses[0].history[0].action, "generate");
      assert.equal((await admin.POST(request({}, testerJWT))).status, 403);
      const oldActivation = await activateLicenseForUser(first.key, "tester");
      assert("error" in oldActivation && oldActivation.status === 400, "device keys never become web-account grants");
      assert.equal((await (await validate.POST(request({ key: first.key }))).json()).valid, false, "new device key cannot bypass binding through old unsigned validation");
    });
    await check("bulk permanent generation supports explicit owner, label and note; invalid inputs or owner reject", async () => {
      const keys = await generate({ count: 2, ownerUserId: "tester", label: "Acceptance", note: "Synthetic batch" });
      assert.equal(keys.length, 2); assert.notEqual(keys[0].key, keys[1].key);
      const stored = (await storage.readAuthState()).licenses.filter((entry) => keys.some((key) => key.id === entry.id));
      assert(stored.every((entry) => entry.ownerUserId === "tester" && entry.maxActivations === 1 && entry.expiresAt === null && entry.label === "Acceptance" && entry.note === "Synthetic batch"));
      for (const body of [{ maxActivations: 0 }, { maxActivations: 101 }, { count: 0 }, { label: "x".repeat(81) }, { note: "😀".repeat(201) }])
        assert.equal((await admin.POST(request(body, adminJWT))).status, 400);
      const before = (await storage.readAuthState()).licenses.length;
      assert.equal((await admin.POST(request({ ownerUserId: "missing" }, adminJWT))).status, 404);
      assert.equal((await storage.readAuthState()).licenses.length, before);
    });
    await check("activation signs exact UUID/key/nonce/issuer claims and atomically binds a new device", async () => {
      const body = input(identity.toUpperCase(), `  ${first.key.toLowerCase()}  `);
      const response = await claim.POST(request(body)); assert.equal(response.status, 200); activation = await response.json();
      assert(/^[0-9a-f]{64}$/.test(activation.token));
      const signed = await verify(activation.licenseToken, { deviceId: activation.deviceId, identity, keyFingerprint: sha(first.key), nonce: body.nonce, status: "active" });
      assert.equal(signed.exp! - signed.iat!, 72 * 60 * 60, "Permanent customer term still has bounded signed freshness");
      const state = await storage.readAuthState(), device = state.devices.find((entry) => entry.id === activation.deviceId)!;
      assert.equal(device.userId, "admin"); assert.equal(device.tokenHash, sha(activation.token));
      assert.equal(state.licenses.find((entry) => entry.id === first.id)!.activations!.length, 1);
      const tokenParts = activation.licenseToken.split("."); tokenParts[1] = Buffer.from(JSON.stringify({ status: "active" })).toString("base64url");
      await assert.rejects(jwtVerify(tokenParts.join("."), keypair.publicKey, { algorithms: ["RS256"] }));
      const followup = input(identity), validation = await validate.POST(request(followup, activation.token));
      assert.equal(validation.status, 200);
      const checked = await validation.json(); assert.equal(checked.expiresAt, null);
      await verify(checked.licenseToken, { deviceId: activation.deviceId, identity, keyFingerprint: sha(first.key), nonce: followup.nonce, status: "active" });
    });
    await check("copied installation UUID and key cannot recover an existing device credential", async () => {
      const [key] = await generate(), uuid = randomUUID();
      const original = await (await claim.POST(request(input(uuid, key.key)))).json();
      const before = await storage.readAuthState();
      const response = await claim.POST(request(input(uuid, key.key)));
      assert.equal(response.status, 409, "A client-selected UUID is not proof of possession of the paired device");
      const denied = await response.json();
      assert(!("token" in denied) && !("licenseToken" in denied));
      assert(!JSON.stringify(denied).includes(original.token));
      const after = await storage.readAuthState();
      assert.deepEqual(after.devices, before.devices);
      assert.deepEqual(after.licenses, before.licenses);
      assert.deepEqual(after.deviceLicensing!.events, before.deviceLicensing!.events);
    });
    await check("unknown or foreign bearers and a second same-owner key cannot take over an installation", async () => {
      const [key, otherKey] = await generate({ count: 2 }), uuid = randomUUID();
      const original = await (await claim.POST(request(input(uuid, key.key)))).json();
      const before = await storage.readAuthState();
      for (const [suppliedKey, bearer] of [[key.key, "d".repeat(64)], [key.key, workerToken], [otherKey.key, ""]]) {
        const response = await claim.POST(request(input(uuid, suppliedKey), bearer));
        assert([403, 409].includes(response.status));
        const denied = await response.json();
        assert(!("token" in denied) && !("licenseToken" in denied));
      }
      const after = await storage.readAuthState();
      assert.deepEqual(after.devices, before.devices);
      assert.deepEqual(after.licenses, before.licenses);
      assert.deepEqual(after.deviceLicensing!.events, before.deviceLicensing!.events);
      const verified = await (await validate.POST(request(input(uuid, key.key), original.token))).json();
      assert.equal(verified.valid, true, "Failed takeover preserves the original pairing");
    });
    await check("concurrent first claims for a copied UUID return credentials only to the committed activation", async () => {
      const [key] = await generate(), uuid = randomUUID();
      const responses = await Promise.all([claim.POST(request(input(uuid, key.key))), claim.POST(request(input(uuid, key.key)))]);
      assert.deepEqual(responses.map((response) => response.status).sort(), [200, 409]);
      for (const response of responses) {
        const body = await response.json();
        if (response.status === 409) assert(!("token" in body) && !("licenseToken" in body));
      }
      const state = await storage.readAuthState();
      assert.equal(state.devices.filter((entry) => entry.deviceBinding === sha(uuid)).length, 1);
      assert.equal(state.licenses.find((entry) => entry.id === key.id)!.activations!.length, 1);
    });
    await check("authenticated same-installation retries retain one token without consuming another activation", async () => {
      const responses = await Promise.all([claim.POST(request(input(identity, first.key), activation.token)), claim.POST(request(input(identity, first.key), activation.token))]);
      for (const response of responses) { assert.equal(response.status, 200); const body = await response.json();
        assert.equal(body.deviceId, activation.deviceId); assert.equal(body.token, activation.token); }
      const license = (await storage.readAuthState()).licenses.find((entry) => entry.id === first.id)!;
      assert.equal(license.activations!.length, 1);
      assert.equal((await claim.POST(request(input(randomUUID(), first.key)))).status, 409);
    });
    await check("established max-two activation race admits two installations and permanently rejects a third", async () => {
      const [key] = await generate();
      // Seed a synthetic pre-policy record; new issuance cannot request this limit.
      await storage.mutateCollection<LicenseRecord>("licenses", (items) => items.map((entry) =>
        entry.id === key.id ? { ...entry, createdAt: "2020-01-01T00:00:00.000Z", maxActivations: 2 } : entry));
      const results = await Promise.all([randomUUID(), randomUUID(), randomUUID()].map((uuid) => claim.POST(request(input(uuid, key.key)))));
      assert.equal(results.filter((result) => result.status === 200).length, 2);
      assert.equal(results.filter((result) => result.status === 409).length, 1);
      const license = (await storage.readAuthState()).licenses.find((entry) => entry.id === key.id)!;
      assert.equal(new Set(license.activations!.map((entry) => entry.deviceBinding)).size, 2);
    });
    await check("existing paired device retains IDs and token; cross-owner key cannot capture it", async () => {
      const [owned] = await generate({ ownerUserId: "tester" }), body = input(randomUUID(), owned.key);
      assert.equal((await claim.POST(request(input(body.deviceIdentity, first.key), workerToken))).status, 403);
      const response = await claim.POST(request(body, workerToken)); assert.equal(response.status, 200);
      const claimed = await response.json(); assert.equal(claimed.deviceId, "pre-worker"); assert.equal(claimed.token, workerToken);
    });
    await check("revocation is immediate in cloud and authenticated validation returns a verifiable signed denial", async () => {
      assert.equal((await revoke.POST(request(undefined, adminJWT), { params: { id: first.id } })).status, 200);
      const body = input(identity, first.key), response = await validate.POST(request(body, activation.token)); assert.equal(response.status, 200);
      const value = await response.json(); assert.equal(value.valid, false); assert.equal(value.revoked, true);
      await verify(value.licenseToken, { deviceId: activation.deviceId, identity, keyFingerprint: sha(first.key), nonce: body.nonce, status: "revoked" });
      assert.equal((await storage.readAuthState()).devices.find((entry) => entry.id === activation.deviceId)!.tokenHash, sha(activation.token));
    });
    await check("re-enable keeps binding and history; a wrong requested key receives matching-fingerprint signed invalid", async () => {
      assert.equal((await manage.PATCH(request({ action: "enable" }, adminJWT, "PATCH"), { params: { id: first.id } })).status, 200);
      const body = input(identity, first.key), good = await (await validate.POST(request(body, activation.token))).json();
      await verify(good.licenseToken, { deviceId: activation.deviceId, identity, keyFingerprint: sha(first.key), nonce: body.nonce, status: "active" });
      const badKey = "AAAA-AAAA-AAAA-AAAA", badBody = input(identity, badKey), bad = await (await validate.POST(request(badBody, activation.token))).json();
      await verify(bad.licenseToken, { deviceId: activation.deviceId, identity, keyFingerprint: sha(badKey), nonce: badBody.nonce, status: "invalid" });
      assert.equal((await manage.PATCH(request({ ownerUserId: "tester" }, adminJWT, "PATCH"), { params: { id: first.id } })).status, 409);
    });
    await check("established expiry bounds signed grace and expired validation cannot issue a fresh active lease", async () => {
      const [key] = await generate(), uuid = randomUUID(), body = input(uuid, key.key);
      const establishedExpiry = new Date(Date.now() + 60_000).toISOString();
      // Seed an existing expiring term without widening new issuance policy.
      await storage.mutateCollection<LicenseRecord>("licenses", (items) => items.map((entry) =>
        entry.id === key.id ? { ...entry, createdAt: "2020-01-01T00:00:00.000Z", expiresAt: establishedExpiry } : entry));
      const value = await (await claim.POST(request(body))).json();
      const payload = await verify(value.licenseToken, { deviceId: value.deviceId, identity: uuid, keyFingerprint: sha(key.key), nonce: body.nonce, status: "active" });
      assert(payload.exp! <= Math.floor(Date.parse(establishedExpiry) / 1000));
      await storage.mutateCollection<LicenseRecord>("licenses", (items) => items.map((entry) => entry.id === key.id ? { ...entry, expiresAt: "2020-01-01T00:00:00.000Z" } : entry));
      const checkBody = input(uuid, key.key), expired = await (await validate.POST(request(checkBody, value.token))).json();
      await verify(expired.licenseToken, { deviceId: value.deviceId, identity: uuid, keyFingerprint: sha(key.key), nonce: checkBody.nonce, status: "expired" });
    });
    await check("delete retains activation/history and device data while subsequent checks are signed invalid", async () => {
      const before = await storage.readAuthState(), previousDevice = before.devices.find((entry) => entry.id === activation.deviceId)!;
      assert.equal((await manage.DELETE(request(undefined, adminJWT, "DELETE"), { params: { id: first.id } })).status, 200);
      const after = await storage.readAuthState(), license = after.licenses.find((entry) => entry.id === first.id)!;
      assert(license.deletedAt); assert.equal(license.activations!.length, 1);
      assert.deepEqual(after.devices.find((entry) => entry.id === activation.deviceId), previousDevice);
      assert(after.deviceLicensing!.events.some((entry) => entry.licenseId === first.id && entry.action === "delete"));
      const body = input(identity, first.key), denied = await (await validate.POST(request(body, activation.token))).json();
      await verify(denied.licenseToken, { deviceId: activation.deviceId, identity, keyFingerprint: sha(first.key), nonce: body.nonce, status: "invalid" });
      assert.equal((await manage.PATCH(request({ action: "enable" }, adminJWT, "PATCH"), { params: { id: first.id } })).status, 410);
    });
    await check("activation rate limits persist across adapter restart and include invalid-key attempts", async () => {
      const uuid = randomUUID();
      for (let i = 0; i < 5; i++) assert.equal((await claim.POST(request(input(uuid, "AAAA-AAAA-AAAA-AAAA")))).status, 404);
      resetStorageAdapterForTests();
      const response = await claim.POST(request(input(uuid, "AAAA-AAAA-AAAA-AAAA"))); assert.equal(response.status, 429);
      assert(Number(response.headers.get("Retry-After")) > 0);
      assert.equal((await getStorage().readAuthState()).deviceLicensing!.rates.find((entry) => entry.binding === sha(uuid))!.count, 5);
    });
    await check("missing signer and failed atomic commit consume no activation and never return unsigned success", async () => {
      const [key] = await generate(), uuid = randomUUID(), before = await getStorage().readAuthState();
      delete process.env.LICENSE_SIGNING_PRIVATE_KEY;
      assert.equal((await claim.POST(request(input(uuid, key.key)))).status, 503);
      assert.deepEqual(await getStorage().readAuthState(), before);
      process.env.LICENSE_SIGNING_PRIVATE_KEY = pem;
      const rename = fs.rename;
      fs.rename = async (source, target) => {
        if (String(target).endsWith("auth-state.json")) throw Object.assign(new Error("injected auth commit failure"), { code: "EIO" });
        return rename(source, target);
      };
      try { assert.equal((await claim.POST(request(input(uuid, key.key)))).status, 503); }
      finally { fs.rename = rename; }
      assert.deepEqual(await getStorage().readAuthState(), before);
      assert.equal((await claim.POST(request(input(uuid, key.key)))).status, 200);
    });
    await check("concurrent revoke and activation converge to revoked and next check proves denial", async () => {
      const [key] = await generate(), uuid = randomUUID();
      const results = await Promise.all([claim.POST(request(input(uuid, key.key))), revoke.POST(request(undefined, adminJWT), { params: { id: key.id } })]);
      assert.equal(results[1].status, 200);
      const license = (await getStorage().readAuthState()).licenses.find((entry) => entry.id === key.id)!; assert(license.revokedAt);
      if (results[0].status === 200) {
        const value = await results[0].json(), body = input(uuid, key.key), denial = await (await validate.POST(request(body, value.token))).json();
        await verify(denial.licenseToken, { deviceId: value.deviceId, identity: uuid, keyFingerprint: sha(key.key), nonce: body.nonce, status: "revoked" });
      } else assert.equal(results[0].status, 403);
    });
    await check("validation throttles persist and refuse unsigned success; unknown authentication never grants", async () => {
      await getStorage().mutateAuthState((state) => {
        state.deviceLicensing!.rates = state.deviceLicensing!.rates.filter((entry) => entry.binding !== sha(identity) || entry.kind !== "validate");
        state.deviceLicensing!.rates.push({ binding: sha(identity), kind: "validate", windowStart: Date.now(), count: 120 });
        return state;
      });
      resetStorageAdapterForTests();
      const response = await validate.POST(request(input(identity, first.key), activation.token));
      assert.equal(response.status, 429); assert(Number(response.headers.get("Retry-After")) > 0);
      assert(!("licenseToken" in await response.json()));
      assert.equal((await validate.POST(request(input(randomUUID(), first.key), "f".repeat(64)))).status, 401);
    });
    await check("future licensing migration is rejected without destructive fallback", async () => {
      const file = path.join(scratch, ".data/auth-state.json"), before = await fs.readFile(file);
      try {
        const document = JSON.parse(before.toString()); document.items[0].deviceLicensing.version = 99;
        await fs.writeFile(file, JSON.stringify(document));
        await assert.rejects(getStorage().readAuthState(), /Unsupported or corrupt/);
        assert.equal(JSON.parse(await fs.readFile(file, "utf8")).items[0].deviceLicensing.version, 99);
      } finally { await fs.writeFile(file, before); }
    });
    await check("malformed persisted rate limits produce 503 and remain unchanged for recovery", async () => {
      const file = path.join(scratch, ".data/auth-state.json"), before = await fs.readFile(file);
      try {
        const document = JSON.parse(before.toString()); document.items[0].deviceLicensing.rates = [{ binding: sha(identity), kind: "claim", windowStart: "bad", count: 1 }];
        const corrupt = JSON.stringify(document); await fs.writeFile(file, corrupt);
        await assert.rejects(getStorage().readAuthState(), /Corrupt device licensing/);
        assert.equal((await validate.POST(request(input(identity, first.key), activation.token))).status, 503);
        assert.equal(await fs.readFile(file, "utf8"), corrupt);
      } finally { await fs.writeFile(file, before); }
    });
    console.log(`${count} device licensing checks passed`);
  } finally {
    process.env.LICENSE_SIGNING_PRIVATE_KEY = pem;
    await getStorage().mutateCollection("backups", (items) => items).catch(() => {}); process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("device-license-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
