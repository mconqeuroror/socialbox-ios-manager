/** Actual storage/route tests; only synthetic data in a bounded scratch directory. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import type { ProxyRecord } from "../src/lib/storage";

async function main() {
  const cloud = path.resolve(path.dirname(process.argv[1]), "..");
  const parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "inventory-test-"));
  const previous = process.cwd();
  process.chdir(scratch);
  delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-inventory-fixture-secret";
  const { getStorage } = await import("../src/lib/storage");
  const { publishProfile, retireProfiles, isCanonicalProfileId } = await import("../src/lib/profile-inventory");
  const storage = getStorage();
  const now = "2026-01-01T00:00:00.000Z";
  const input = (profileId: string, deviceId = "device-a", userId = "owner") =>
    ({ userId, deviceId, profileId, nickname: "", country: "US" });
  const proxy = (id: string, assignedProfileId: string | null): ProxyRecord => ({
    id, userId: "owner", name: id, type: "http", host: "proxy.invalid", port: 8080,
    username: null, password: null, healthStatus: "unknown", lastCheckedAt: null,
    latencyMs: null, healthMessage: null, assignedProfileId, assignedAt: now,
    createdAt: now, updatedAt: now,
  });
  let count = 0;
  const check = async (name: string, fn: () => Promise<void>) => { await fn(); count++; console.log(`PASS ${name}`); };
  try {
    await check("one wire ID contract rejects aliases without writing", async () => {
      const fixture = JSON.parse(await fs.readFile(path.resolve(cloud, "../tools/fixtures/profile-identifiers.json"), "utf8"));
      for (const id of [...fixture.accepted, "a".repeat(128)]) assert(isCanonicalProfileId(id));
      for (const id of [...fixture.rejected, "a".repeat(129), null, 42]) {
        assert(!isCanonicalProfileId(id));
        await assert.rejects(publishProfile(input(id)), /canonical/);
      }
      assert.equal((await storage.readInventoryState()).profiles.length, 0);
    });
    await check("case collision and device reassignment preserve existing record", async () => {
      const original = await publishProfile(input("Alpha_One"));
      await assert.rejects(publishProfile(input("alpha_one")), /case/);
      await assert.rejects(publishProfile(input("Alpha_One", "device-b")), /different device/);
      assert.deepEqual((await storage.readInventoryState()).profiles, [original]);
    });
    await check("failed atomic deletion preserves profile and assigned proxy", async () => {
      await storage.writeCollection("proxies", [proxy("proxy-a", "Alpha_One")]);
      const before = await storage.readInventoryState();
      const rename = fs.rename;
      fs.rename = async (source, target) => {
        if (String(target).endsWith("inventory-state.json")) throw Object.assign(new Error("injected commit failure"), { code: "EIO" });
        return rename(source, target);
      };
      try { await assert.rejects(retireProfiles("owner", "device-a", ["Alpha_One"]), /injected/); }
      finally { fs.rename = rename; }
      assert.deepEqual(await storage.readInventoryState(), before);
    });
    await check("deletion releases assignment atomically and replay is idempotent", async () => {
      const first = await retireProfiles("owner", "device-a", ["Alpha_One"]);
      const second = await retireProfiles("owner", "device-a", ["Alpha_One"]);
      assert.deepEqual(first, second);
      const state = await storage.readInventoryState();
      assert.equal(state.profiles.length, 0);
      assert.equal(state.proxies[0].assignedProfileId, null);
      assert.equal(state["profile-tombstones"].length, 1);
      await assert.rejects(publishProfile(input("Alpha_One")), /retired/);
      await assert.rejects(publishProfile(input("ALPHA_ONE")), /retired/);
    });
    await check("stale generic writers cannot resurrect or retarget tombstones", async () => {
      await assert.rejects(storage.writeCollection("proxies", [proxy("proxy-a", "Alpha_One")]), /PROFILE_RETIRED/);
      await assert.rejects(storage.writeCollection("profile-tombstones", []), /cannot be undone/);
      await assert.rejects(storage.mutateInventoryState((state) => ({ ...state,
        "profile-tombstones": state["profile-tombstones"].map((t) => ({ ...t, deviceId: "device-b" })) })), /cannot be undone/);
    });
    await check("uncertain unpublished local IDs can retire without crossing devices", async () => {
      await retireProfiles("owner", "device-a", ["Offline"]);
      await assert.rejects(retireProfiles("owner", "device-b", ["Offline"]), /different device/);
      await assert.rejects(retireProfiles("owner", null, ["NeverPublished"]), /not found/);
      await publishProfile(input("OtherDevice", "device-b"));
      await assert.rejects(retireProfiles("owner", "device-a", ["OtherDevice"]), /different device/);
      await publishProfile(input("Offline", "device-a", "other-owner"));
    });
    await check("racing publish and deletion converge to permanently retired", async () => {
      await publishProfile(input("Race"));
      await storage.mutateCollection<ProxyRecord>("proxies", (items) => [...items, proxy("proxy-race", "Race")]);
      await Promise.allSettled(Array.from({ length: 16 }, (_, i) => i % 2 ?
        publishProfile(input("Race")) : retireProfiles("owner", "device-a", ["Race"])));
      const state = await storage.readInventoryState();
      assert(!state.profiles.some((item) => item.profileId === "Race"));
      assert.equal(state["profile-tombstones"].filter((item) => item.profileId === "Race").length, 1);
      assert(!state.proxies.some((item) => item.assignedProfileId === "Race"));
    });
    await check("real console routes cannot assign or revive retired backup-only IDs", async () => {
      const { createSessionToken } = await import("../src/lib/auth");
      await storage.writeCollection("users", [{ id: "owner", email: "fixture@invalid.test", passwordHash: "unused",
        role: "user", licensedAt: now, createdAt: now }]);
      const token = await createSessionToken({ id: "owner", email: "fixture@invalid.test", username: "fixture", role: "user", licensed: true });
      const request = (body: object, method = "POST") => new Request("http://localhost/api/fixture", {
        method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(body) });
      const assignment = await import("../src/app/api/profile-proxies/route");
      assert.equal((await assignment.POST(request({ profileId: "Alpha_One", proxyId: "proxy-a" }))).status, 410);
      assert.equal((await assignment.POST(request({ profileId: "BackupOnly", proxyId: "proxy-a" }))).status, 404);
      assert.equal((await assignment.POST(request({ profileId: " OtherDevice", proxyId: "proxy-a" }))).status, 400);
      const rotation = await import("../src/app/api/profile-rotation-auth/[profileId]/route");
      assert.equal((await rotation.PUT(request({ value: null }, "PUT"), { params: { profileId: "Alpha_One" } })).status, 410);
      assert.equal((await rotation.PUT(request({ value: null }, "PUT"), { params: { profileId: "BackupOnly" } })).status, 404);
    });
    await check("cloud corruption never reactivates legacy inventory", async () => {
      const file = path.join(scratch, ".data", "inventory-state.json");
      const bytes = await fs.readFile(file);
      try {
        await fs.writeFile(file, '{"version":1,"items":[]}');
        await assert.rejects(storage.readInventoryState(), /Corrupt inventory/);
      } finally { await fs.writeFile(file, bytes); }
    });
    console.log(`${count} profile inventory checks passed`);
  } finally {
    // Await the serialized store tail before removing only this test's root.
    await storage.mutateCollection("backups", (items) => items).catch(() => {});
    process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("inventory-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
