/** Actual storage and authenticated routes; synthetic state in an isolated directory. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { APP_DESCRIPTORS, appDescriptorForType, profileAppType } from "../src/lib/app-registry";
import type { ProfileRecord, ProxyRecord } from "../src/lib/storage";

async function main() {
  const cloud = path.resolve(path.dirname(process.argv[1]), "..");
  const parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "app-registry-test-"));
  const previous = process.cwd(); process.chdir(scratch);
  delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-app-registry-secret";
  const { getStorage } = await import("../src/lib/storage");
  const { publishProfile, retireProfiles } = await import("../src/lib/profile-inventory");
  const { sha256Hex } = await import("../src/lib/ids");
  const { createSessionToken } = await import("../src/lib/auth");
  const storage = getStorage(), now = "2026-01-01T00:00:00.000Z";
  let count = 0;
  const check = async (name: string, fn: () => Promise<void>) => { await fn(); count++; console.log(`PASS ${name}`); };
  const input = (profileId: string, appType?: unknown, deviceId = "device-a", userId = "owner") =>
    ({ userId, deviceId, profileId, nickname: "", country: "US", ...(appType !== undefined ? { appType } : {}) });
  const token = "d".repeat(64);
  try {
    await check("native and cloud share one canonical registry; unknown values fail closed", async () => {
      const rows = JSON.parse(await fs.readFile(path.join(cloud, "src/config/app-registry.json"), "utf8"));
      assert.deepEqual(APP_DESCRIPTORS, rows);
      for (const descriptor of APP_DESCRIPTORS) {
        for (const key of ["keychainSourceGroups", "keychainGroupSuffixes"] as const) {
          assert.ok(Object.isFrozen(descriptor[key]));
          assert.throws(() => (descriptor[key] as string[]).push("foreign.group"), TypeError);
        }
      }
      assert.equal(appDescriptorForType()?.appType, "reddit");
      assert.equal(profileAppType({}), "reddit");
      for (const invalid of [null, "", "REDDIT", "instagram", 42, [], {}]) {
        assert.equal(appDescriptorForType(invalid), undefined);
        assert.throws(() => profileAppType({ appType: invalid }), /appType/);
      }
      assert.equal(appDescriptorForType("facebook")?.runnable, false);
    });
    await check("legacy rows read as Reddit without rewriting bytes; next mutation persists only additive field", async () => {
      const profile: ProfileRecord = { id: "legacy", userId: "owner", deviceId: "device-a", profileId: "legacy", lastSeenAt: now,
        nickname: "Original", rotationAuthSecretEnc: "preserved-ciphertext" };
      await fs.mkdir(path.join(scratch, ".data"), { recursive: true });
      const file = path.join(scratch, ".data/inventory-state.json");
      const record = { id: "inventory-state", formatVersion: 1, profiles: [profile], proxies: [], "profile-tombstones": [],
        legacyAssignmentMigration: { version: 1, migratedAt: now, ignoredRetired: 0 } };
      const bytes = JSON.stringify({ version: 1, items: [record] });
      await fs.writeFile(file, bytes);
      assert.deepEqual((await storage.readInventoryState()).profiles, [{ ...profile, appType: "reddit" }]);
      assert.equal(await fs.readFile(file, "utf8"), bytes);
      await storage.mutateInventoryState((state) => state);
      const stored = JSON.parse(await fs.readFile(file, "utf8"));
      assert.deepEqual(stored.items[0], { ...record, profiles: [{ ...profile, appType: "reddit" }] });
    });
    await check("new profiles default Reddit; explicit Facebook cannot reuse or retag any existing ID", async () => {
      assert.equal((await publishProfile(input("new-reddit"))).appType, "reddit");
      assert.equal((await publishProfile(input("new-facebook", "facebook"))).appType, "facebook");
      const before = await storage.readInventoryState();
      await assert.rejects(publishProfile(input("legacy", "facebook")), /appType/);
      await assert.rejects(publishProfile(input("new-facebook")), /appType/);
      await assert.rejects(publishProfile(input("NEW-FACEBOOK", "facebook")), /case/);
      await assert.rejects(publishProfile(input("new-facebook", "facebook", "device-b")), /different device/);
      for (const appType of [null, "", 42, "instagram"]) await assert.rejects(publishProfile(input("invalid", appType)), /appType/);
      assert.deepEqual(await storage.readInventoryState(), before);
    });
    await check("generic CAS writers cannot retag profiles or erase explicit Facebook app identity", async () => {
      const before = await storage.readInventoryState();
      await assert.rejects(storage.mutateCollection<ProfileRecord>("profiles", (rows) => rows.map((row) =>
        row.profileId === "legacy" ? { ...row, appType: "facebook" } : row)), /appType cannot/);
      await assert.rejects(storage.mutateCollection<ProfileRecord>("profiles", (rows) => rows.map((row) => {
        if (row.profileId !== "new-facebook") return row;
        const { appType, ...oldWriter } = row; return oldWriter;
      })), /appType cannot/);
      assert.deepEqual(await storage.readInventoryState(), before);
    });
    await check("unknown stored app identity fails closed and preserves inventory bytes", async () => {
      const file = path.join(scratch, ".data/inventory-state.json"), original = await fs.readFile(file);
      try {
        const bad = JSON.parse(original.toString()); bad.items[0].profiles[0].appType = "unregistered";
        const badBytes = JSON.stringify(bad); await fs.writeFile(file, badBytes);
        await assert.rejects(storage.readInventoryState(), /appType/);
        await assert.rejects(storage.mutateInventoryState((state) => state), /appType/);
        assert.equal(await fs.readFile(file, "utf8"), badBytes);
      } finally { await fs.writeFile(file, original); }
    });
    // The migration fixture above intentionally used opaque placeholder
    // ciphertext. Remove that test-only field before exercising decryption.
    await storage.mutateCollection<ProfileRecord>("profiles", (rows) => rows.map((row) =>
      row.profileId === "legacy" ? { ...row, rotationAuthSecretEnc: null } : row));
    await storage.writeCollection("users", [{ id: "owner", email: "apps@invalid.test", passwordHash: "unused", role: "user", licensedAt: now, createdAt: now }]);
    await storage.writeCollection("devices", ["device-a", "device-b"].map((id) => ({ id, userId: "owner", name: id,
      role: "worker", tokenHash: id === "device-a" ? sha256Hex(token) : null, pairedAt: now, lastSeenAt: now })));
    await publishProfile(input("sibling-facebook", "facebook", "device-b"));
    await publishProfile(input("foreign-facebook", "facebook", "foreign-device", "other-owner"));
    const jwt = await createSessionToken({ id: "owner", email: "apps@invalid.test", username: "apps", role: "user", licensed: true });
    const request = (auth: string, body?: object, method = body ? "POST" : "GET", query = "") =>
      new Request(`http://localhost/api/fixture${query}`, { method,
        headers: { Authorization: `Bearer ${auth}`, "Content-Type": "application/json" }, ...(body ? { body: JSON.stringify(body) } : {}) });
    const inventory = await import("../src/app/api/profiles/route");
    const assignments = await import("../src/app/api/profile-proxies/route");
    const assignmentItem = await import("../src/app/api/profile-proxies/[profileId]/route");
    const rotation = await import("../src/app/api/profile-rotation-auth/[profileId]/route");
    const reconcile = await import("../src/app/api/profiles/reconcile/route");
    await check("console app filters preserve user authorization and expose explicit app fields", async () => {
      const all = await (await inventory.GET(request(jwt))).json();
      assert(all.profiles.some((row: ProfileRecord) => row.appType === "reddit"));
      assert(all.profiles.some((row: ProfileRecord) => row.appType === "facebook"));
      assert(!all.profiles.some((row: ProfileRecord) => row.userId !== "owner"));
      assert(!all.profiles.some((row: ProfileRecord) => "rotationAuthSecretEnc" in row));
      for (const route of [inventory, assignments]) {
        const fb = await (await route.GET(request(jwt, undefined, "GET", "?appType=facebook"))).json();
        assert(fb.profiles.length === 2 && fb.profiles.every((row: ProfileRecord) => row.appType === "facebook"));
        assert.equal((await route.GET(request(jwt, undefined, "GET", "?appType=instagram"))).status, 400);
        assert.equal((await route.GET(request(jwt, undefined, "GET", "?appType=reddit&appType=facebook"))).status, 400);
        assert.equal((await route.GET(request("invalid", undefined, "GET", "?appType=facebook"))).status, 401);
      }
    });
    await check("old device clients receive only own Reddit rows; explicit Facebook requests remain device scoped", async () => {
      for (const route of [inventory, assignments]) {
        const legacy = await (await route.GET(request(token))).json();
        const rows: ProfileRecord[] = legacy.profiles ?? legacy.assignments;
        assert(rows.length > 0 && rows.every((row) => row.appType === "reddit"));
        const fb = await (await route.GET(request(token, undefined, "GET", "?appType=facebook"))).json();
        assert.deepEqual((fb.profiles ?? fb.assignments).map((row: ProfileRecord) => row.profileId), ["new-facebook"]);
      }
    });
    await check("legacy metadata, publish, retirement and reconciliation cannot target Facebook implicitly", async () => {
      const record = (await storage.readInventoryState()).profiles.find((row) => row.profileId === "new-facebook")!;
      assert.equal((await inventory.POST(request(token, { profileId: "new-facebook" }))).status, 409);
      const edit = { profileId: "new-facebook", notes: "scoped edit", metadataRevision: record.metadataRevision };
      assert.equal((await inventory.PATCH(request(token, edit, "PATCH"))).status, 409);
      assert.equal((await inventory.PATCH(request(token, { ...edit, appType: "facebook" }, "PATCH"))).status, 200);
      assert.equal((await inventory.DELETE(request(token, { profileId: "new-facebook" }, "DELETE"))).status, 409);
      assert.equal((await reconcile.POST(request(token, { profileIds: ["new-facebook"] }))).status, 409);
      assert.equal((await inventory.PATCH(request(token, { ...edit, profileId: "sibling-facebook", appType: "facebook" }, "PATCH"))).status, 404);
    });
    await check("assignment and credential endpoints require Facebook app assertion; old Reddit payloads still work", async () => {
      const proxy: ProxyRecord = { id: "proxy", userId: "owner", name: "fixture", type: "http", host: "proxy.invalid", port: 8080,
        username: null, password: null, healthStatus: "unknown", lastCheckedAt: null, latencyMs: null, healthMessage: null, createdAt: now, updatedAt: now };
      await storage.writeCollection("proxies", [proxy]);
      assert.equal((await assignments.POST(request(jwt, { profileId: "new-facebook", proxyId: "proxy" }))).status, 409);
      assert.equal((await assignments.POST(request(jwt, { profileId: "new-facebook", appType: "facebook", proxyId: "proxy" }))).status, 201);
      assert.equal((await assignmentItem.DELETE(request(jwt, undefined, "DELETE"), { params: { profileId: "new-facebook" } })).status, 409);
      assert.equal((await assignmentItem.DELETE(request(jwt, undefined, "DELETE", "?appType=facebook"), { params: { profileId: "new-facebook" } })).status, 200);
      assert.equal((await rotation.GET(request(jwt), { params: { profileId: "new-facebook" } })).status, 404);
      assert.equal((await rotation.GET(request(jwt, undefined, "GET", "?appType=facebook"), { params: { profileId: "new-facebook" } })).status, 200);
      assert.equal((await rotation.PUT(request(jwt, { value: null }, "PUT"), { params: { profileId: "new-facebook" } })).status, 409);
      assert.equal((await rotation.PUT(request(jwt, { value: null, appType: "facebook" }, "PUT"), { params: { profileId: "new-facebook" } })).status, 200);
      assert.equal((await assignments.POST(request(jwt, { profileId: "new-reddit", proxyId: "proxy" }))).status, 201);
    });
    await check("retirement remains global across apps and prevents resurrection", async () => {
      await retireProfiles("owner", "device-a", ["new-facebook"], "facebook");
      await assert.rejects(publishProfile(input("new-facebook", "facebook")), /retired/);
      await assert.rejects(publishProfile(input("new-facebook", "reddit")), /retired/);
    });
    console.log(`${count} app registry / migration / authenticated scope groups passed`);
  } finally {
    await storage.mutateCollection("backups", (items) => items).catch(() => {});
    process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("app-registry-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
