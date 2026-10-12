/** Actual read handlers and committed local drift; synthetic data only. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { AuthState, CollectionName, LicenseAuditRecord, LicenseRecord } from "../src/lib/storage";

async function bounded<T>(value: Promise<T>): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([value, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Synthetic read gate timed out")), 10_000);
    })]);
  } finally { clearTimeout(timer); }
}

async function main() {
  const previous = process.cwd(), savedEnv = { ...process.env };
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), "socialbox-console-read-"));
  process.chdir(scratch); delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-console-read-secret-only";
  process.env.ADMIN_EMAIL = "owner@fixture.invalid";
  const { getStorage, resetStorageAdapterForTests } = await import("../src/lib/storage");
  const { createSessionToken } = await import("../src/lib/auth");
  const licenses = await import("../src/app/api/admin/licenses/route");
  const users = await import("../src/app/api/admin/users/route");
  const storage = getStorage(), originalRead = storage.readCollection.bind(storage),
    originalState = storage.readAuthState.bind(storage), originalMutation = storage.mutateAuthState.bind(storage);
  const at = "2026-01-01T00:00:00.000Z";
  const owner = { id: "owner", email: "owner@fixture.invalid", role: "admin" as const,
    passwordHash: "synthetic-unused-password-hash", licensedAt: at, createdAt: at };
  const customer = { ...owner, id: "customer", email: "before@fixture.invalid", role: "user" as const };
  const license: LicenseRecord = { id: "synthetic-license", keyHash: "synthetic-private-hash", kind: "device",
    ownerUserId: customer.id, createdAt: at, activatedAt: null, activatedBy: null, revokedAt: null,
    expiresAt: null, label: "Private label", note: "Private note", maxActivations: 1, activations: [] };
  const audit: LicenseAuditRecord = { id: "audit", at, action: "grant", actorUserId: owner.id,
    actorUsername: "owner", licenseId: license.id, keyIdPrefix: license.id.slice(0, 8), expiresAt: null };
  const token = await createSessionToken({ ...owner, username: "owner", licensed: true });
  const request = () => new Request("https://console.invalid/api/synthetic-read", { headers: { authorization: `Bearer ${token}` } });
  const handlers: { name: string; invoke: () => Promise<Response> }[] = [
    { name: "licenses", invoke: () => licenses.GET(request()) }, { name: "users", invoke: () => users.GET(request()) },
  ];
  const drifts = [
    { name: "demoted", change: (s: AuthState) => ({ ...s, users: s.users.map(u => u.id === owner.id ? { ...u, role: "user" as const } : u) }) },
    { name: "renamed", change: (s: AuthState) => ({ ...s, users: s.users.map(u => u.id === owner.id ? { ...u, email: "changed@fixture.invalid" } : u) }) },
    { name: "removed", change: (s: AuthState) => ({ ...s, users: s.users.filter(u => u.id !== owner.id) }) },
    { name: "ambiguous", change: (s: AuthState) => ({ ...s, users: [...s.users, { ...owner }] }) },
  ];
  const reset = async () => {
    await originalMutation(() => ({ users: [owner, customer], licenses: [license], devices: [], "pairing-codes": [],
      deviceLicensing: { version: 1, migratedAt: at, adminDevices: [], rates: [], events: [] } }));
    await storage.writeCollection("license-audit", [audit]);
  };
  const bytes = async () => ({ auth: await fs.readFile(path.join(scratch, ".data/auth-state.json"), "utf8"),
    audit: await fs.readFile(path.join(scratch, ".data/license-audit.json"), "utf8") });
  let passed = 0, failed = 0, executions = 0;
  const check = async (name: string, action: () => Promise<void>) => {
    try { await action(); passed++; console.log(`PASS ${name}`); }
    catch (error) { failed++; console.error(`FAIL ${name}: ${error instanceof Error ? error.message : String(error)}`); }
  };
  const restoreReads = () => { storage.readCollection = originalRead; storage.readAuthState = originalState; };
  try {
    for (const handler of handlers) {
      await check(`${handler.name}: valid owner receives existing sanitized projection without rewrite`, async () => {
        await reset(); const before = await bytes(); executions++;
        const response = await handler.invoke(); assert.equal(response.status, 200); const value = await response.json();
        const text = JSON.stringify(value); assert(!text.includes(owner.passwordHash)); assert(!text.includes(license.keyHash));
        if (handler.name === "licenses") { assert.equal(value.licenses[0].note, license.note); assert.equal(value.audit.length, 1); }
        else { assert.equal(value.users.length, 2); assert.equal(value.users.find((u: { id: string }) => u.id === customer.id).email, customer.email); }
        assert.deepEqual(await bytes(), before);
      });
      await check(`${handler.name}: preexisting duplicate actor cannot use first-match session`, async () => {
        await reset(); await originalMutation(drifts[3].change); const before = await bytes(); executions++;
        const response = await handler.invoke(); assert.equal(response.status, 403);
        assert.deepEqual(await response.json(), { error: "Owner access required" }); assert.deepEqual(await bytes(), before);
      });
      for (const drift of drifts) {
        await check(`${handler.name}: ${drift.name} actor while projection snapshot waits`, async () => {
          await reset(); let entered!: () => void, resume!: () => void, userReads = 0, gates = 0;
          const arrived = new Promise<void>(r => { entered = r; }), gate = new Promise<void>(r => { resume = r; });
          const pause = async () => { gates++; entered(); await bounded(gate); };
          // Session lookup is the first user collection read. The old user
          // handler's second read and both final handlers' full state read are
          // the same semantic projection boundary, using the real local state.
          storage.readCollection = async <T>(name: CollectionName) => {
            if (name === "users" && ++userReads === 2) await pause();
            return originalRead<T>(name);
          };
          storage.readAuthState = async () => { await pause(); return originalState(); };
          executions++; const pending = handler.invoke(); void pending.catch(() => {});
          try {
            await bounded(arrived); await originalMutation(drift.change); const before = await bytes(); resume();
            const response = await bounded(pending); assert.equal(response.status, 403);
            assert.deepEqual(await response.json(), { error: "Owner access required" });
            assert.equal(gates, 1); assert.deepEqual(await bytes(), before);
          } finally { resume(); await Promise.allSettled([pending]); restoreReads(); }
        });
      }
    }
    for (const drift of drifts) {
      await check(`licenses: ${drift.name} actor during separate audit read`, async () => {
        await reset(); let entered!: () => void, resume!: () => void, gates = 0;
        const arrived = new Promise<void>(r => { entered = r; }), gate = new Promise<void>(r => { resume = r; });
        storage.readCollection = async <T>(name: CollectionName) => {
          if (name === "license-audit") { gates++; entered(); await bounded(gate); }
          return originalRead<T>(name);
        };
        executions++; const pending = licenses.GET(request()); void pending.catch(() => {});
        try {
          await bounded(arrived); await originalMutation(drift.change); const before = await bytes(); resume();
          const response = await bounded(pending); assert.equal(response.status, 403);
          assert.deepEqual(await response.json(), { error: "Owner access required" });
          assert.equal(gates, 1); assert.deepEqual(await bytes(), before);
        } finally { resume(); await Promise.allSettled([pending]); restoreReads(); }
      });
    }
    await check("users: users and device counts come from the same final auth snapshot", async () => {
      await reset(); let entered!: () => void, resume!: () => void, gates = 0;
      const arrived = new Promise<void>(r => { entered = r; }), gate = new Promise<void>(r => { resume = r; });
      const pause = async () => { gates++; entered(); await bounded(gate); };
      storage.readCollection = async <T>(name: CollectionName) => { if (name === "devices") await pause(); return originalRead<T>(name); };
      storage.readAuthState = async () => { await pause(); return originalState(); };
      executions++; const pending = users.GET(request()); void pending.catch(() => {});
      try {
        await bounded(arrived); await originalMutation(s => ({ ...s, users: s.users.map(u => u.id === customer.id ? { ...u, email: "after@fixture.invalid" } : u),
          devices: [{ id: "device", userId: customer.id, name: "Synthetic device", role: "worker" as const,
            tokenHash: "synthetic-unused", pairedAt: at, lastSeenAt: at }] }));
        const before = await bytes(); resume(); const response = await bounded(pending); assert.equal(response.status, 200);
        const value = await response.json(), row = value.users.find((u: { id: string }) => u.id === customer.id);
        assert.equal(row.email, "after@fixture.invalid"); assert.equal(row.deviceCount, 1); assert.equal(gates, 1); assert.deepEqual(await bytes(), before);
      } finally { resume(); await Promise.allSettled([pending]); restoreReads(); }
    });
    for (const boundary of ["licenses-audit", "licenses-state", "users-state"]) {
      await check(`${boundary}: non-policy read failure is preserved without rewrite`, async () => {
        await reset(); const before = await bytes(), sentinel = new Error("Synthetic storage failure"); let userReads = 0;
        storage.readCollection = async <T>(name: CollectionName) => {
          if ((boundary === "licenses-audit" && name === "license-audit") ||
              (boundary === "users-state" && name === "users" && ++userReads === 2)) throw sentinel;
          return originalRead<T>(name);
        };
        storage.readAuthState = async () => { if (boundary.endsWith("-state")) throw sentinel; return originalState(); };
        try {
          executions++; await assert.rejects(boundary.startsWith("licenses") ? licenses.GET(request()) : users.GET(request()), e => e === sentinel);
          assert.deepEqual(await bytes(), before);
        } finally { restoreReads(); }
      });
    }
  } finally {
    restoreReads(); resetStorageAdapterForTests(); process.chdir(previous); await fs.rm(scratch, { recursive: true, force: true });
    for (const k of Object.keys(process.env)) if (!(k in savedEnv)) delete process.env[k]; Object.assign(process.env, savedEnv);
  }
  console.log(JSON.stringify({ kind: "console-read-authority", groups: passed + failed, passed, failed, executions,
    normalControls: 2, preexistingAmbiguousReads: 2, committedActorDriftReads: 12, coherentSnapshotReads: 1,
    preservedNonPolicyErrors: 3, networkOrDeviceEffects: false }));
  if (failed) process.exitCode = 1;
}
main().catch(error => { console.error(error); process.exitCode = 1; });
