import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import type { ProfileRecord, ProfileProxyAssignment, ProxyRecord } from "../src/lib/storage";

async function main() {
  const cloud = path.resolve(path.dirname(process.argv[1]), "..");
  const parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "assignment-migration-test-"));
  const previous = process.cwd();
  process.chdir(scratch);
  delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-assignment-migration-test";
  const { getStorage } = await import("../src/lib/storage");
  const { retireProfiles } = await import("../src/lib/profile-inventory");
  const { sha256Hex } = await import("../src/lib/ids");
  const storage = getStorage();
  const data = path.join(scratch, ".data");
  await fs.mkdir(data);
  const now = "2026-01-01T00:00:00.000Z";
  const profile = (profileId: string): ProfileRecord => ({ id: profileId, userId: "owner", deviceId: "phone", profileId, lastSeenAt: now });
  const proxy = (id: string, assignedProfileId: string | null = null): ProxyRecord => ({
    id, userId: "owner", name: id, type: "http", host: "proxy.invalid", port: 8080,
    username: null, password: null, healthStatus: "unknown", lastCheckedAt: null,
    latencyMs: null, healthMessage: null, assignedProfileId, assignedAt: null, createdAt: now, updatedAt: now });
  const assignment = (profileId: string, proxyId: string): ProfileProxyAssignment => ({
    id: `${profileId}-${proxyId}`, userId: "owner", profileId, proxyId, assignedAt: now, updatedAt: now });
  const file = (name: string) => path.join(data, `${name}.json`);
  const write = (name: string, items: unknown[]) => fs.writeFile(file(name), JSON.stringify({ version: 1, items }));
  async function seed(legacy: ProfileProxyAssignment[], proxies = [proxy("p1"), proxy("p2")], existing = false) {
    await fs.unlink(file("inventory-state")).catch((error) => { if (error.code !== "ENOENT") throw error; });
    await write("profiles", [profile("A"), profile("B")]);
    await write("proxies", proxies);
    await write("profile-proxy-assignments", legacy);
    if (existing) await write("inventory-state", [{ id: "inventory-state", formatVersion: 1,
      profiles: [profile("A"), profile("B")], proxies, "profile-tombstones": [] }]);
  }
  let count = 0;
  const check = async (name: string, fn: () => Promise<void>) => { await fn(); count++; console.log(`PASS ${name}`); };
  try {
    await check("first migration is atomic and both real API consumers see the assignment", async () => {
      await seed([assignment("A", "p1")]);
      const legacy = await fs.readFile(file("profile-proxy-assignments"));
      await Promise.all(Array.from({ length: 12 }, () => storage.readInventoryState()));
      assert.deepEqual(await fs.readFile(file("profile-proxy-assignments")), legacy);
      const committed = JSON.parse(await fs.readFile(file("inventory-state"), "utf8")).items[0];
      assert.equal(committed.legacyAssignmentMigration.version, 1);
      assert.equal(committed.proxies[0].assignedProfileId, "A");
      const token = "a".repeat(64);
      await storage.writeCollection("users", [{ id: "owner", email: "fixture@invalid.test", passwordHash: "unused", role: "user", licensedAt: now, createdAt: now }]);
      await storage.writeCollection("devices", [{ id: "phone", userId: "owner", name: "fixture", role: "worker", tokenHash: sha256Hex(token), pairedAt: now, lastSeenAt: now }]);
      const routes = await import("../src/app/api/profile-proxies/route");
      const device = await (await routes.GET(new Request("http://localhost/api/profile-proxies", { headers: { Authorization: `Bearer ${token}` } }))).json();
      assert.equal(device.assignments.find((item: { profileId: string }) => item.profileId === "A").proxy.id, "p1");
      const { createSessionToken } = await import("../src/lib/auth");
      const jwt = await createSessionToken({ id: "owner", email: "fixture@invalid.test", username: "fixture", role: "user", licensed: true });
      const consoleView = await (await routes.GET(new Request("http://localhost/api/profile-proxies", { headers: { Authorization: `Bearer ${jwt}` } }))).json();
      assert.equal(consoleView.profiles.find((item: { profileId: string }) => item.profileId === "A").assignmentId, "p1");
    });
    await check("completed migration never overwrites a subsequent unassignment", async () => {
      await storage.mutateCollection<ProxyRecord>("proxies", (items) => items.map((p) => ({ ...p, assignedProfileId: null })));
      const before = await fs.readFile(file("inventory-state"));
      await write("profile-proxy-assignments", [assignment("A", "p2")]);
      assert((await storage.readInventoryState()).proxies.every((p) => !p.assignedProfileId));
      assert.deepEqual(await fs.readFile(file("inventory-state")), before);
      await assert.rejects(storage.writeCollection("profile-proxy-assignments", []), /read-only/);
    });
    await check("existing H17 document upgrades without re-reading stale profile collections", async () => {
      await seed([assignment("A", "p1")], [proxy("p1"), proxy("p2")], true);
      await write("profiles", [profile("Stale")]);
      const state = await storage.readInventoryState();
      assert.deepEqual(state.profiles.map((p) => p.profileId), ["A", "B"]);
      assert.equal(state.proxies[0].assignedProfileId, "A");
    });
    await check("conflicts leave both authoritative and legacy files unchanged", async () => {
      for (const [legacy, proxies] of [
        [[assignment("A", "p1"), assignment("B", "p1")], [proxy("p1"), proxy("p2")]],
        [[assignment("A", "p1"), assignment("A", "p2")], [proxy("p1"), proxy("p2")]],
        [[assignment("A", "p1")], [proxy("p1", "B"), proxy("p2")]],
        [[assignment("Missing", "p1")], [proxy("p1"), proxy("p2")]],
        [[{ ...assignment("A", "p1"), userId: "other-owner" }], [proxy("p1"), proxy("p2")]],
      ] as [ProfileProxyAssignment[], ProxyRecord[]][]) {
        await seed(legacy, proxies, true);
        const before = await fs.readFile(file("inventory-state"));
        const original = await fs.readFile(file("profile-proxy-assignments"));
        await assert.rejects(storage.readInventoryState(), /migration blocked/);
        assert.deepEqual(await fs.readFile(file("inventory-state")), before);
        assert.deepEqual(await fs.readFile(file("profile-proxy-assignments")), original);
      }
    });
    await check("failed publication preserves state and retry migrates exactly once", async () => {
      await seed([assignment("A", "p1")], [proxy("p1"), proxy("p2")], true);
      const before = await fs.readFile(file("inventory-state"));
      const rename = fs.rename;
      fs.rename = async (source, destination) => {
        if (String(destination) === file("inventory-state")) throw Object.assign(new Error("injected migration commit failure"), { code: "EIO" });
        return rename(source, destination);
      };
      try { await assert.rejects(storage.readInventoryState(), /injected/); }
      finally { fs.rename = rename; }
      assert.deepEqual(await fs.readFile(file("inventory-state")), before);
      assert.equal((await storage.readInventoryState()).proxies[0].assignedProfileId, "A");
    });
    await check("retired profiles cannot be revived by old assignments", async () => {
      await retireProfiles("owner", "phone", ["A"]);
      const doc = JSON.parse(await fs.readFile(file("inventory-state"), "utf8"));
      delete doc.items[0].legacyAssignmentMigration;
      await fs.writeFile(file("inventory-state"), JSON.stringify(doc));
      const state = await storage.readInventoryState();
      assert(!state.profiles.some((p) => p.profileId === "A"));
      assert(!state.proxies.some((p) => p.assignedProfileId === "A"));
      const migrated = JSON.parse(await fs.readFile(file("inventory-state"), "utf8"));
      assert.equal(migrated.items[0].legacyAssignmentMigration.ignoredRetired, 1);
    });
    console.log(`${count} assignment migration checks passed`);
  } finally {
    await storage.mutateCollection("backups", (items) => items).catch(() => {});
    process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("assignment-migration-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
