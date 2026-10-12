/** Actual issuance handler and local commits; synthetic users and keys only. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import type { AuthState, LicenseRecord } from "../src/lib/storage";

async function bounded<T>(value: Promise<T>): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([value, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Synthetic issuance gate timed out")), 10_000);
    })]);
  } finally { clearTimeout(timer); }
}

async function main() {
  const previous = process.cwd(), savedEnv = { ...process.env };
  const cloud = path.resolve(path.dirname(process.argv[1]), "..");
  const scratch = await fs.mkdtemp(path.join(path.resolve(cloud, "../.."), "permanent-device-license-"));
  process.chdir(scratch); delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-permanent-device-license-secret";
  process.env.ADMIN_EMAIL = "owner@fixture.invalid";
  const { getStorage, resetStorageAdapterForTests } = await import("../src/lib/storage");
  const { createSessionToken } = await import("../src/lib/auth");
  const route = await import("../src/app/api/admin/licenses/route");
  const storage = getStorage(), originalMutation = storage.mutateAuthState.bind(storage);
  const at = "2026-01-01T00:00:00.000Z";
  const owner = { id: "owner", email: "owner@fixture.invalid", role: "admin" as const,
    passwordHash: "synthetic-unused", licensedAt: at, createdAt: at };
  const otherAdmin = { ...owner, id: "other-admin", email: "other-admin@fixture.invalid" };
  const customer = { ...owner, id: "customer", email: "customer@fixture.invalid", role: "user" as const };
  const historical: LicenseRecord[] = [
    { id: "historical-device", keyHash: "synthetic-old-hash", keyFingerprint: "a".repeat(64), kind: "device",
      ownerUserId: customer.id, createdAt: at, activatedBy: null, activatedAt: null, revokedAt: null,
      expiresAt: "2099-01-01T00:00:00.000Z", maxActivations: 3, label: "Established term",
      note: "Synthetic prior policy", activations: [{ deviceId: "old-device", deviceBinding: "b".repeat(64),
        activatedAt: at, lastCheckedAt: at }] },
    { id: "historical-account", keyHash: "synthetic-legacy-hash", createdAt: at,
      activatedBy: customer.email, activatedAt: at, revokedAt: "2026-02-01T00:00:00.000Z",
      expiresAt: "2026-03-01T00:00:00.000Z" },
  ];
  const seed: AuthState = { users: [owner, otherAdmin, customer], licenses: historical,
    devices: [{ id: "old-device", userId: customer.id, name: "Established synthetic device", role: "worker",
      tokenHash: "c".repeat(64), deviceBinding: "b".repeat(64), licenseId: "historical-device",
      licenseStatus: "active", pairedAt: at, lastSeenAt: at }], "pairing-codes": [],
    deviceLicensing: { version: 1, migratedAt: at, adminDevices: [], rates: [], events: [
      { id: "old-event", at, action: "activate-device", licenseId: "historical-device", deviceId: "old-device" },
    ] } };
  const tokens = Object.fromEntries(await Promise.all(seed.users.map(async (user) =>
    [user.id, await createSessionToken({ ...user, username: user.id, licensed: true })])));
  const request = (body: unknown, token = tokens.owner) => new Request("https://console.invalid/api/admin/licenses", {
    method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const authFile = path.join(scratch, ".data/auth-state.json"), auditFile = path.join(scratch, ".data/license-audit.json");
  const snapshot = async () => ({ auth: await fs.readFile(authFile, "utf8"), audit: await fs.readFile(auditFile, "utf8") });
  const reset = async () => {
    await originalMutation(() => structuredClone(seed));
    await storage.writeCollection("license-audit", []);
  };
  let passed = 0, failed = 0, executions = 0;
  const check = async (name: string, action: () => Promise<void>) => {
    try { await action(); passed++; console.log(`PASS ${name}`); }
    catch (error) { failed++; console.error(`FAIL ${name}: ${error instanceof Error ? error.message : String(error)}`); }
  };
  const invoke = async (body: unknown, token?: string) => { executions++; return route.POST(request(body, token)); };
  const rejected = async (body: unknown, status: number, token?: string) => {
    await reset(); const before = await snapshot();
    const response = await invoke(body, token); assert.equal(response.status, status);
    const result = await response.json(); assert(typeof result.error === "string");
    assert(!("licenses" in result)); assert.deepEqual(await snapshot(), before, "Refusal preserves exact auth/audit bytes");
  };
  try {
    for (const [name, body] of [
      ["omitted policy", {}],
      ["explicit permanent one-device policy", { expiresAt: null, maxActivations: 1 }],
      ["bulk with assigned owner", { count: 2, ownerUserId: customer.id, label: "Synthetic phone", note: "Synthetic note" }],
    ] as const) await check(name, async () => {
      await reset(); const before = await storage.readAuthState(), audit = await fs.readFile(auditFile, "utf8");
      const response = await invoke(body); assert.equal(response.status, 200); const result = await response.json();
      const after = await storage.readAuthState();
      assert.equal(result.licenses.length, "count" in body ? body.count : 1);
      for (const issued of result.licenses) {
        assert.equal(issued.expiresAt, null);
        const record = after.licenses.find((entry) => entry.id === issued.id)!;
        assert.equal(record.kind, "device"); assert.equal(record.expiresAt, null); assert.equal(record.maxActivations, 1);
        assert.equal(record.ownerUserId, "ownerUserId" in body ? body.ownerUserId : owner.id);
        assert.equal(record.label, "label" in body ? body.label : "");
        assert.equal(record.note, "note" in body ? body.note : "");
        assert.deepEqual(record.activations, []); assert(record.keyHash); assert(record.keyFingerprint);
        assert(!JSON.stringify(after).includes(issued.key), "Only the successful response contains the plaintext key");
      }
      assert.equal(after.licenses.length, before.licenses.length + result.licenses.length);
      assert.deepEqual(after.licenses.filter((entry) => historical.some((old) => old.id === entry.id)), before.licenses);
      assert.deepEqual(after.users, before.users); assert.deepEqual(after.devices, before.devices);
      assert.deepEqual(after["pairing-codes"], before["pairing-codes"]);
      assert.deepEqual(after.deviceLicensing!.adminDevices, before.deviceLicensing!.adminDevices);
      assert.deepEqual(after.deviceLicensing!.rates, before.deviceLicensing!.rates);
      assert.deepEqual(after.deviceLicensing!.events.slice(0, before.deviceLicensing!.events.length), before.deviceLicensing!.events);
      assert.equal(after.deviceLicensing!.events.length, before.deviceLicensing!.events.length + result.licenses.length);
      assert.equal(await fs.readFile(auditFile, "utf8"), audit);
    });
    const hostile: [string, unknown][] = [
      ["future expiry", { expiresAt: "2099-01-01T00:00:00.000Z" }],
      ["past expiry", { expiresAt: "2020-01-01T00:00:00.000Z" }],
      ["empty expiry", { expiresAt: "" }], ["malformed expiry", { expiresAt: "invalid" }],
      ["numeric expiry", { expiresAt: 0 }], ["Boolean expiry", { expiresAt: false }],
      ["object expiry", { expiresAt: {} }], ["array expiry", { expiresAt: [] }],
      ["day term", { expiresInDays: 4 }], ["zero day term", { expiresInDays: 0 }],
      ["string day term", { expiresInDays: "4" }], ["empty day term", { expiresInDays: "" }],
      ["null day term", { expiresInDays: null }], ["Boolean day term", { expiresInDays: false }],
      ["object day term", { expiresInDays: {} }], ["array day term", { expiresInDays: [] }],
      ["null expiry cannot mask day term", { expiresAt: null, expiresInDays: 4 }],
      ["two devices", { maxActivations: 2 }], ["hundred devices", { maxActivations: 100 }],
      ["zero devices", { maxActivations: 0 }], ["negative devices", { maxActivations: -1 }],
      ["fractional devices", { maxActivations: 1.5 }], ["string devices", { maxActivations: "1" }],
      ["null devices", { maxActivations: null }], ["Boolean devices", { maxActivations: true }],
      ["array devices", { maxActivations: [1] }], ["object devices", { maxActivations: {} }],
    ];
    for (const [name, body] of hostile) await check(`refuse ${name}`, () => rejected(body, 400));
    for (const [name, token] of [["anonymous", ""], ["other administrator", tokens[otherAdmin.id]],
      ["customer", tokens[customer.id]]] as const)
      await check(`refuse ${name}`, () => rejected({}, 403, token));
    const drifts = [
      { name: "demoted", change: (state: AuthState) => ({ ...state, users: state.users.map((user) =>
        user.id === owner.id ? { ...user, role: "user" as const } : user) }) },
      { name: "renamed", change: (state: AuthState) => ({ ...state, users: state.users.map((user) =>
        user.id === owner.id ? { ...user, email: "changed@fixture.invalid" } : user) }) },
      { name: "removed", change: (state: AuthState) => ({ ...state, users: state.users.filter((user) => user.id !== owner.id) }) },
      { name: "duplicate actor", change: (state: AuthState) => ({ ...state, users: [...state.users, { ...owner }] }) },
    ];
    for (const drift of drifts) await check(`current transaction refuses ${drift.name}`, async () => {
      await reset(); let entered!: () => void, resume!: () => void;
      const arrived = new Promise<void>((resolve) => { entered = resolve; });
      const gate = new Promise<void>((resolve) => { resume = resolve; });
      let calls = 0;
      storage.mutateAuthState = async (fn) => { calls++; entered(); await bounded(gate); return originalMutation(fn); };
      const pending = invoke({ ownerUserId: customer.id }); void pending.catch(() => {});
      try {
        await bounded(arrived); await originalMutation(drift.change); const before = await snapshot(); resume();
        const response = await bounded(pending); assert.equal(response.status, 403);
        assert.deepEqual(await response.json(), { error: "Owner access required" });
        assert.deepEqual(await snapshot(), before); assert.equal(calls, 1);
      } finally { resume(); await Promise.allSettled([pending]); storage.mutateAuthState = originalMutation; }
    });
  } finally {
    storage.mutateAuthState = originalMutation; resetStorageAdapterForTests(); process.chdir(previous);
    await fs.rm(scratch, { recursive: true, force: true });
    for (const key of Object.keys(process.env)) if (!(key in savedEnv)) delete process.env[key];
    Object.assign(process.env, savedEnv);
  }
  console.log(JSON.stringify({ kind: "permanent-device-license", groups: passed + failed, passed, failed, executions,
    realLocalOwnerDrifts: 4, networkOrDeviceEffects: false }));
  if (failed) process.exitCode = 1;
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
