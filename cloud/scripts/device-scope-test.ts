/** Exercise actual authenticated routes with two devices of one synthetic owner. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { createHash } from "node:crypto";
import type { ProfileRecord, ProxyRecord, BackupRecord } from "../src/lib/storage";
async function main() {
  const cloud = path.resolve(path.dirname(process.argv[1]), "..");
  const parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "device-scope-test-"));
  const previous = process.cwd(); process.chdir(scratch);
  delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-device-scope-secret";
  process.env.PROXY_SECRETS_KEY = "12".repeat(32);
  const { getStorage } = await import("../src/lib/storage");
  const { sha256Hex } = await import("../src/lib/ids");
  const { encryptProxySecret } = await import("../src/lib/proxy-secrets");
  const { createSessionToken } = await import("../src/lib/auth");
  const storage = getStorage(), now = "2026-01-01T00:00:00.000Z";
  const tokens = { a: "a".repeat(64), b: "b".repeat(64) };
  const request = (token: string, body?: object, method = body ? "POST" : "GET") =>
    new Request("http://localhost/api/fixture", { method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      ...(body ? { body: JSON.stringify(body) } : {}) });
  let count = 0;
  const check = async (name: string, fn: () => Promise<void>) => { await fn(); count++; console.log(`PASS ${name}`); };
  try {
    await storage.writeCollection("users", [{ id: "owner", email: "scope@invalid.test", passwordHash: "unused", role: "user", licensedAt: now, createdAt: now }]);
    await storage.writeCollection("devices", Object.entries(tokens).map(([id, token]) => ({ id, userId: "owner", name: id,
      role: "worker", tokenHash: sha256Hex(token), pairedAt: now, lastSeenAt: now })));
    const profiles: ProfileRecord[] = ["a", "b"].map((deviceId) => ({ id: deviceId, userId: "owner", deviceId,
      profileId: `profile-${deviceId}`, lastSeenAt: now, rotationAuthHeader: "Authorization",
      rotationAuthSecretEnc: encryptProxySecret(`rotation-${deviceId}`) }));
    await storage.writeCollection("profiles", profiles);
    await storage.writeCollection<ProxyRecord>("proxies", ["a", "b"].map((id) => ({ id, userId: "owner", name: id,
      type: "http", host: `${id}.invalid`, port: 8080, username: id, password: `password-${id}`, healthStatus: "unknown",
      lastCheckedAt: null, latencyMs: null, healthMessage: null, assignedProfileId: `profile-${id}`, createdAt: now, updatedAt: now })));
    const assignments = await import("../src/app/api/profile-proxies/route");
    const inventory = await import("../src/app/api/profiles/route");
    const reconcile = await import("../src/app/api/profiles/reconcile/route");
    const health = await import("../src/app/api/proxies/[id]/health/route");
    const backupList = await import("../src/app/api/backups/route");
    const backupItem = await import("../src/app/api/backups/[id]/route");
    const rotation = await import("../src/app/api/rotation-settings/route");
    await check("each device receives only its registered profile credentials", async () => {
      for (const id of ["a", "b"] as const) {
        const response = await assignments.GET(request(tokens[id])); assert.equal(response.status, 200);
        const body = await response.json(); assert.equal(body.assignments.length, 1);
        assert.equal(body.assignments[0].profileId, `profile-${id}`);
        assert.equal(body.assignments[0].rotationAuth.value, `rotation-${id}`);
        assert(body.assignments[0].proxy.url.includes(`password-${id}`));
        const rows = await (await inventory.GET(request(tokens[id]))).json();
        assert.deepEqual(rows.profiles.map((p: { profileId: string }) => p.profileId), [`profile-${id}`]);
      }
      await storage.mutateCollection<ProfileRecord>("profiles", (items) => items.map((p) => p.deviceId === "b" ? { ...p, rotationAuthSecretEnc: "corrupt-other-device" } : p));
      assert.equal((await assignments.GET(request(tokens.a))).status, 200, "must not even decrypt another device's secret");
      await storage.writeCollection("profiles", profiles);
    });
    await check("device token cannot transfer or retire another device profile", async () => {
      assert.equal((await inventory.POST(request(tokens.a, { profileId: "profile-b" }))).status, 409);
      assert.equal((await inventory.DELETE(request(tokens.a, { profileId: "profile-b" }, "DELETE"))).status, 403);
      assert.equal((await reconcile.POST(request(tokens.a, { profileIds: ["profile-b"] }))).status, 403);
      assert.deepEqual((await storage.readInventoryState()).profiles, profiles.map((profile) => ({ ...profile, appType: "reddit" })));
    });
    await check("health mutation checks the assigned device within the inventory transaction", async () => {
      assert.equal((await health.POST(request(tokens.a, { healthy: true }), { params: { id: "b" } })).status, 404);
      assert.equal((await health.POST(request(tokens.a, { healthy: true }), { params: { id: "a" } })).status, 200);
      assert.equal((await storage.readInventoryState()).proxies.find((p) => p.id === "b")!.healthStatus, "unknown");
    });
    await check("backup list/download/delete do not expose another device's encrypted profile", async () => {
      const backups: BackupRecord[] = [];
      for (const id of ["a", "b"]) {
        const blobPath = await storage.putBlob(`backup-${id}`, Buffer.from(`encrypted-${id}`));
        backups.push({ id, userId: "owner", deviceId: id, containerId: `profile-${id}`, size: 11,
          createdAt: now, iv: "fixture", salt: "fixture", checksum: "fixture", blobPath });
      }
      await storage.writeCollection("backups", backups);
      const own = await (await backupList.GET(request(tokens.a))).json();
      assert.deepEqual(own.backups.map((b: { id: string }) => b.id), ["a"]);
      assert.equal((await backupItem.GET(request(tokens.a), { params: { id: "b" } })).status, 401);
      assert.equal((await backupItem.DELETE(request(tokens.a, undefined, "DELETE"), { params: { id: "b" } })).status, 401);
      assert.equal((await backupItem.GET(request(tokens.b), { params: { id: "b" } })).status, 200);
      assert.equal((await storage.getBlob("backup-b"))!.byteLength, 11);
    });
    await check("backup upload requires a live profile registered to the uploading device", async () => {
      const bytes = Buffer.from("synthetic ciphertext");
      const body = { containerId: "profile-b", ciphertext: bytes.toString("base64"),
        iv: Buffer.alloc(12).toString("base64"), salt: Buffer.alloc(16).toString("base64"), checksum: createHash("sha256").update(bytes).digest("hex") };
      assert.equal((await backupList.POST(request(tokens.a, body))).status, 403);
      assert.equal((await backupList.POST(request(tokens.a, { ...body, containerId: "profile-a" }))).status, 200);
    });
    await check("global sharing requires an explicit owner action and then covers both paired devices", async () => {
      await storage.writeCollection("rotation-settings", [{ id: "legacy", userId: "owner", proxyURLSecretEnc: encryptProxySecret("http://global.invalid:8080"),
        rotationURL: "https://control.invalid/rotate", authHeader: "Authorization", authorizationSecretEnc: encryptProxySecret("global-secret"), method: "POST", updatedAt: now }]);
      assert.equal((await rotation.GET(request(tokens.a))).status, 403);
      const jwt = await createSessionToken({ id: "owner", email: "scope@invalid.test", username: "scope", role: "user", licensed: true });
      const values = { proxyURL: "http://global.invalid:8080", rotationURL: "https://control.invalid/rotate", authHeader: "Authorization", authorization: "global-secret", method: "POST" };
      assert.equal((await rotation.PUT(request(jwt, values, "PUT"))).status, 400);
      assert.equal((await rotation.PUT(request(tokens.a, { ...values, deviceAccess: "all-paired" }, "PUT"))).status, 401);
      assert.equal((await rotation.PUT(request(jwt, { ...values, deviceAccess: "all-paired" }, "PUT"))).status, 200);
      for (const token of Object.values(tokens)) {
        const response = await rotation.GET(request(token)); assert.equal(response.status, 200);
        assert.equal((await response.json()).settings.authorization, "global-secret");
      }
    });
    await check("token revocation between read and auth commit rejects the stale token", async () => {
      const mutate = storage.mutateAuthState.bind(storage);
      storage.mutateAuthState = async (fn) => {
        await mutate((state) => ({ ...state, devices: state.devices.map((d) => d.id === "a" ? { ...d, tokenHash: null } : d) }));
        return mutate(fn);
      };
      try {
        assert.equal((await assignments.GET(request(tokens.a))).status, 401);
      } finally { storage.mutateAuthState = mutate; }
    });
    console.log(`${count} two-device authorization groups passed`);
  } finally {
    await storage.mutateCollection("backups", (items) => items).catch(() => {});
    process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("device-scope-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
