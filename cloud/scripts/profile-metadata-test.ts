/** Real authenticated handlers and atomic storage; all data is synthetic and isolated. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import type { ProfileRecord } from "../src/lib/storage";

async function main() {
  const cloud = path.resolve(path.dirname(process.argv[1]), ".."), parent = path.resolve(cloud, "../..");
  const scratch = await fs.mkdtemp(path.join(parent, "profile-metadata-test-")), previous = process.cwd();
  process.chdir(scratch); delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-profile-metadata-fixture";
  const { getStorage } = await import("../src/lib/storage");
  const { sha256Hex } = await import("../src/lib/ids");
  const { createSessionToken } = await import("../src/lib/auth");
  const { publishProfile, retireProfiles } = await import("../src/lib/profile-inventory");
  const { profileMetadata, profileNoteLength } = await import("../src/lib/profile-metadata");
  const route = await import("../src/app/api/profiles/route");
  const assignments = await import("../src/app/api/profile-proxies/route");
  const storage = getStorage(), now = new Date().toISOString(), deviceToken = "a".repeat(64);
  const req = (token: string, body?: unknown, method = body === undefined ? "GET" : "PATCH") =>
    new Request("http://localhost/api/profiles", { method,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  const records = () => storage.readCollection<ProfileRecord>("profiles");
  let count = 0;
  const check = async (name: string, fn: () => Promise<void>) => { await fn(); count++; console.log(`PASS ${name}`); };
  try {
    await storage.writeCollection("users", ["owner", "other"].map((id) => ({ id, email: `${id}@invalid.test`, passwordHash: "unused", role: "user", licensedAt: now, createdAt: now })));
    await storage.writeCollection("devices", [{ id: "device-a", userId: "owner", name: "a", role: "worker", tokenHash: sha256Hex(deviceToken), pairedAt: now, lastSeenAt: now },
      { id: "device-b", userId: "owner", name: "b", role: "worker", tokenHash: sha256Hex("b".repeat(64)), pairedAt: now, lastSeenAt: now }]);
    const jwt = await createSessionToken({ id: "owner", email: "owner@invalid.test", username: "owner", role: "user", licensed: true });
    const otherJWT = await createSessionToken({ id: "other", email: "other@invalid.test", username: "other", role: "user", licensed: true });
    const legacy: ProfileRecord = { id: "row-a", userId: "owner", deviceId: "device-a", profileId: "Legacy_A", lastSeenAt: now,
      rotationAuthHeader: "Authorization", rotationAuthSecretEnc: "opaque-fixture" };
    await storage.writeCollection("profiles", [legacy]);
    await check("legacy metadata gets presentation defaults without changing IDs or storage", async () => {
      const body = await (await route.GET(req(deviceToken))).json();
      assert.deepEqual(profileMetadata(body.profiles[0]), { role: "default", notes: "", metadataRevision: 0 });
      assert.equal(body.profiles[0].profileId, "Legacy_A");
      assert(!("rotationAuthSecretEnc" in body.profiles[0]));
      assert.deepEqual(await records(), [{ ...legacy, appType: "reddit" }]);
    });
    await check("console edits role and 200 Unicode characters atomically; IDs and secret stay fixed", async () => {
      const notes = "😀".repeat(200); assert.equal(profileNoteLength(notes), 200);
      const response = await route.PATCH(req(jwt, { profileId: "Legacy_A", role: "warmup", notes, metadataRevision: 0 }));
      assert.equal(response.status, 200);
      const body = await response.json(); assert(!("rotationAuthSecretEnc" in body.profile));
      assert.deepEqual((await records())[0], { ...legacy, appType: "reddit", role: "warmup", notes, metadataRevision: 1 });
    });
    await check("invalid metadata and attempted ID or device mutation reject without write", async () => {
      const before = await records();
      const base = { profileId: "Legacy_A", metadataRevision: 1, role: "signup" };
      for (const patch of [{ role: "admin" }, { role: null }, { notes: "😀".repeat(201) }, { notes: 4 }, { metadataRevision: -1 },
        { metadataRevision: 1.5 }, { metadataRevision: null }, { deviceId: "device-b" }, { id: "new-id" }, { userId: "other" }])
        assert.equal((await route.PATCH(req(jwt, { ...base, ...patch }))).status, 400);
      assert.equal((await route.PATCH(req(jwt, { profileId: "Legacy_A", role: "signup" }))).status, 400);
      assert.equal((await route.POST(req(deviceToken, null, "POST"))).status, 400);
      assert.deepEqual(await records(), before);
    });
    await check("metadata edit cannot cross owner, device, or case-sensitive canonical ID", async () => {
      const patch = { profileId: "Legacy_A", notes: "unauthorized", metadataRevision: 1 };
      assert.equal((await route.PATCH(req(otherJWT, patch))).status, 404);
      assert.equal((await route.PATCH(req("b".repeat(64), patch))).status, 404);
      assert.equal((await route.PATCH(req(jwt, { ...patch, profileId: "legacy_a" }))).status, 409);
      assert.equal((await route.PATCH(req("", patch))).status, 401);
      assert.equal((await records())[0].metadataRevision, 1);
    });
    await check("racing launcher and cloud edits allow one CAS winner; stale edits preserve winner", async () => {
      const results = await Promise.all([
        route.PATCH(req(jwt, { profileId: "Legacy_A", role: "signup", metadataRevision: 1 })),
        route.POST(req(deviceToken, { profileId: "Legacy_A", role: "spam", notes: "phone", metadataRevision: 1 }, "POST")),
      ]);
      assert.equal(results.filter((result) => result.status === 409).length, 1);
      assert.equal(results.filter((result) => result.status === 200 || result.status === 201).length, 1);
      const before = await records();
      assert.equal((await route.POST(req(deviceToken, { profileId: "Legacy_A", role: "default", metadataRevision: 1 }, "POST"))).status, 409);
      assert.deepEqual(await records(), before);
      assert.equal(before[0].metadataRevision, 2);
    });
    await check("legacy or clean inventory heartbeat cannot reset console metadata", async () => {
      const before = profileMetadata((await records())[0]);
      for (const body of [{ profileId: "Legacy_A" }, { profileId: "Legacy_A", role: "default", notes: "" }]) {
        assert.equal((await route.POST(req(deviceToken, body, "POST"))).status, 201);
        assert.deepEqual(profileMetadata((await records())[0]), before);
      }
    });
    await check("fresh cloud profile publishes its requested role and notes at revision one", async () => {
      assert.equal((await route.POST(req(jwt, { profileId: "New_B", deviceId: "device-b", role: "spam", metadataRevision: 7 }, "POST"))).status, 409);
      const response = await route.POST(req(jwt, { profileId: "New_B", deviceId: "device-b", nickname: "Same display name", role: "spam", notes: "Fresh", metadataRevision: 0 }, "POST"));
      assert.equal(response.status, 201);
      assert.deepEqual(profileMetadata((await response.json()).profile), { role: "spam", notes: "Fresh", metadataRevision: 1 });
      const body = await (await assignments.GET(req(jwt))).json();
      const profile = body.profiles.find((row: { profileId: string }) => row.profileId === "New_B");
      assert.equal(profile.nickname, "Same display name"); assert.equal(profile.deviceId, "device-b"); assert.equal(profile.role, "spam");
    });
    await check("clearing notes is explicit and does not alter any authorization state", async () => {
      const before = await storage.readInventoryState();
      assert.equal((await route.PATCH(req(jwt, { profileId: "New_B", notes: "", metadataRevision: 1 }))).status, 200);
      const after = await storage.readInventoryState(), oldProfile = before.profiles.find((p) => p.profileId === "New_B")!;
      assert.deepEqual(after, { ...before, profiles: before.profiles.map((p) => p.profileId === "New_B" ? { ...oldProfile, notes: "", metadataRevision: 2 } : p) });
    });
    await check("name-only edits use the same metadata revision and preserve all other profile fields", async () => {
      const before = (await records()).find((p) => p.profileId === "New_B")!;
      const response = await route.POST(req("b".repeat(64), { profileId: "New_B", nickname: "Renamed workspace", metadataRevision: 2 }, "POST"));
      assert.equal(response.status, 201);
      const after = (await records()).find((p) => p.profileId === "New_B")!;
      assert.deepEqual(after, { ...before, nickname: "Renamed workspace", metadataRevision: 3, lastSeenAt: after.lastSeenAt });
      const visible = await (await route.GET(req(jwt))).json();
      assert.equal(visible.profiles.find((p: ProfileRecord) => p.profileId === "New_B").nickname, "Renamed workspace");
    });
    await check("stale rename and revisionless heartbeat cannot overwrite a newer label", async () => {
      const before = (await records()).find((p) => p.profileId === "New_B")!;
      assert.equal((await route.POST(req("b".repeat(64), { profileId: "New_B", nickname: "Stale label", metadataRevision: 2 }, "POST"))).status, 409);
      assert.equal((await route.POST(req("b".repeat(64), { profileId: "New_B", nickname: "Legacy heartbeat" }, "POST"))).status, 201);
      const after = (await records()).find((p) => p.profileId === "New_B")!;
      assert.deepEqual(after, { ...before, lastSeenAt: after.lastSeenAt });
    });
    await check("invalid labels never write; Unicode labels count scalar values", async () => {
      const before = await records();
      for (const nickname of [42, null, "bad\nlabel", "bad\u0000label", "😀".repeat(121)])
        assert.equal((await route.POST(req("b".repeat(64), { profileId: "New_B", nickname, metadataRevision: 3 }, "POST"))).status, 400);
      assert.deepEqual(await records(), before);
      assert.equal((await route.POST(req("b".repeat(64), { profileId: "New_B", nickname: "😀".repeat(120), metadataRevision: 3 }, "POST"))).status, 201);
    });
    await check("first inventory enrollment preserves a local legacy label, then enforces rename revisions and limits", async () => {
      const profileId = "Offline_Legacy", legacyName = "Local legacy label ".repeat(12);
      assert(Array.from(legacyName).length > 120);
      assert(!(await records()).some((record) => record.profileId === profileId));
      const enrolled = await route.POST(req(deviceToken, { profileId, nickname: legacyName,
        country: "US", role: "default", notes: "existing offline container", metadataRevision: 0 }, "POST"));
      assert.equal(enrolled.status, 201);
      const initial = (await enrolled.json()).profile;
      assert.equal(initial.nickname, legacyName); // No truncation or whitespace normalization.
      assert.equal(initial.metadataRevision, 1);
      const beforeInvalid = await records();
      assert.equal((await route.POST(req(deviceToken, { profileId, nickname: "X".repeat(121), metadataRevision: 1 }, "POST"))).status, 400);
      assert.deepEqual(await records(), beforeInvalid);
      const renamed = await route.POST(req(deviceToken, { profileId, nickname: "Reviewed local label", metadataRevision: 1 }, "POST"));
      assert.equal(renamed.status, 201);
      const current = (await renamed.json()).profile;
      assert.equal(current.nickname, "Reviewed local label"); assert.equal(current.metadataRevision, 2);
      assert.equal(current.notes, initial.notes); assert.equal(current.deviceId, initial.deviceId);
      const beforeConflicts = await records();
      assert.equal((await route.POST(req(deviceToken, { profileId, nickname: "Stale rename", metadataRevision: 1 }, "POST"))).status, 409);
      assert.equal((await route.POST(req(deviceToken, { profileId, nickname: legacyName, metadataRevision: 2 }, "POST"))).status, 400);
      assert.deepEqual(await records(), beforeConflicts);
    });
    await check("unchanged legacy long names and 128-character fallback IDs still synchronize", async () => {
      const longName = "Legacy ".repeat(30), longId = "a".repeat(128);
      await storage.mutateCollection<ProfileRecord>("profiles", (items) => [...items,
        { id: "legacy-long-row", userId: "owner", deviceId: "device-a", profileId: "Long_Label", nickname: longName, lastSeenAt: now, metadataRevision: 0 },
        { id: "legacy-id-row", userId: "owner", deviceId: "device-a", profileId: longId, lastSeenAt: now, metadataRevision: 0 }]);
      // A legacy label can even contain trailing whitespace. Direct publication
      // must preserve the exact stored string, never silently normalize it.
      for (const [profileId, nickname] of [["Long_Label", longName], [longId, longId]]) {
        const response = await route.POST(req(deviceToken, { profileId, nickname, country: "US", role: "warmup", notes: "still syncs", metadataRevision: 0 }, "POST"));
        assert.equal(response.status, 201); const record = (await response.json()).profile;
        assert.equal(record.nickname, nickname); assert.equal(record.notes, "still syncs"); assert.equal(record.metadataRevision, 1);
      }
      const freshId = "b".repeat(128);
      const fresh = await publishProfile({ userId: "owner", deviceId: "device-a", profileId: freshId, nickname: freshId, country: "US", metadataRevision: 0 });
      assert.equal(fresh.nickname, freshId);
    });
    await check("retirement blocks metadata revival while a new ID can reuse the display name", async () => {
      await retireProfiles("owner", "device-b", ["New_B"]);
      assert.equal((await route.PATCH(req(jwt, { profileId: "New_B", role: "signup", metadataRevision: 2 }))).status, 410);
      await assert.rejects(publishProfile({ userId: "owner", deviceId: "device-b", profileId: "New_B", nickname: "Same display name", country: "US", role: "signup" }), /retired/);
      const fresh = await publishProfile({ userId: "owner", deviceId: "device-b", profileId: "Fresh_B", nickname: "Same display name", country: "US", role: "signup" });
      assert.equal(fresh.role, "signup"); assert.equal(fresh.metadataRevision, 1);
    });
    console.log(`${count} profile metadata checks passed`);
  } finally {
    await storage.mutateCollection("backups", (items) => items).catch(() => {}); process.chdir(previous);
    const relative = path.relative(parent, scratch);
    assert(!path.isAbsolute(relative) && !relative.includes(path.sep) && relative.startsWith("profile-metadata-test-"));
    await fs.rm(scratch, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
