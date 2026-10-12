/** Real routes and local commits; synthetic users only, no live service. */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import type { AuthState, LicenseRecord } from "../src/lib/storage";

async function bounded<T>(value: Promise<T>): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([value, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Synthetic transaction gate timed out")), 10_000);
    })]);
  } finally { clearTimeout(timer); }
}

async function main() {
  const previous = process.cwd(), savedEnv = { ...process.env };
  const cloud = path.resolve(path.dirname(process.argv[1]), "..");
  const scratch = await fs.mkdtemp(path.join(path.resolve(cloud, "../.."), "console-license-authority-"));
  process.chdir(scratch); delete process.env.BLOB_READ_WRITE_TOKEN;
  process.env.JWT_SECRET = "synthetic-console-transaction-secret";
  process.env.ADMIN_EMAIL = "owner@fixture.invalid";
  const { getStorage, resetStorageAdapterForTests } = await import("../src/lib/storage");
  const { createSessionToken } = await import("../src/lib/auth");
  const generate = await import("../src/app/api/admin/licenses/route");
  const manage = await import("../src/app/api/admin/licenses/[id]/route");
  const revoke = await import("../src/app/api/admin/licenses/[id]/revoke/route");
  const storage = getStorage(), originalMutation = storage.mutateAuthState.bind(storage);
  const date = "2026-01-01T00:00:00.000Z";
  const owner = { id: "owner", email: "owner@fixture.invalid", role: "admin" as const,
    passwordHash: "synthetic-unused", licensedAt: date, createdAt: date };
  const recipient = { ...owner, id: "recipient", email: "recipient@fixture.invalid", role: "user" as const };
  const license: LicenseRecord = { id: "fixture-license", keyHash: "synthetic-unused", kind: "device",
    ownerUserId: recipient.id, createdAt: date, activatedAt: null, activatedBy: null, revokedAt: null,
    expiresAt: null, label: "Before", note: "Synthetic fixture", maxActivations: 1, activations: [] };
  const token = await createSessionToken({ ...owner, username: "owner", licensed: true });
  const request = (body?: unknown, method = "POST") => new Request("https://console.invalid/api/fixture", {
    method, headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const context = { params: { id: license.id } };
  const operations = [
    { name: "generate", revoked: false, invoke: () => generate.POST(request({ ownerUserId: recipient.id })) },
    { name: "edit", revoked: false, invoke: () => manage.PATCH(request({ label: "After" }, "PATCH"), context) },
    { name: "enable", revoked: true, invoke: () => manage.PATCH(request({ action: "enable" }, "PATCH"), context) },
    { name: "patch-delete", revoked: false, invoke: () => manage.PATCH(request({ action: "delete" }, "PATCH"), context) },
    { name: "delete", revoked: false, invoke: () => manage.DELETE(request(undefined, "DELETE"), context) },
    { name: "revoke", revoked: false, invoke: () => revoke.POST(request(), context) },
    { name: "revoke-retry", revoked: true, invoke: () => revoke.POST(request(), context) },
  ];
  const drifts = [
    { name: "demoted", change: (state: AuthState) => ({ ...state,
      users: state.users.map((user) => user.id === owner.id ? { ...user, role: "user" as const } : user) }) },
    { name: "renamed", change: (state: AuthState) => ({ ...state,
      users: state.users.map((user) => user.id === owner.id ? { ...user, email: "changed@fixture.invalid" } : user) }) },
    { name: "removed", change: (state: AuthState) => ({ ...state, users: state.users.filter((user) => user.id !== owner.id) }) },
    { name: "ambiguous", change: (state: AuthState) => ({ ...state, users: [...state.users, { ...owner }] }) },
  ];
  const authFile = path.join(scratch, ".data/auth-state.json"), auditFile = path.join(scratch, ".data/license-audit.json");
  const snapshot = async () => ({ auth: await fs.readFile(authFile, "utf8"), audit: await fs.readFile(auditFile, "utf8") });
  const reset = async (revoked: boolean) => {
    await originalMutation(() => ({ users: [owner, recipient], licenses: [{ ...license, revokedAt: revoked ? date : null }],
      devices: [], "pairing-codes": [], deviceLicensing: { version: 1, migratedAt: date, adminDevices: [], rates: [], events: [] } }));
    await storage.writeCollection("license-audit", []);
  };
  let passed = 0, failed = 0, executions = 0;
  const check = async (name: string, action: () => Promise<void>) => {
    try { await action(); passed++; console.log(`PASS ${name}`); }
    catch (error) { failed++; console.error(`FAIL ${name}: ${error instanceof Error ? error.message : String(error)}`); }
  };
  const denied = async (response: Response, before: Awaited<ReturnType<typeof snapshot>>) => {
    assert.equal(response.status, 403);
    assert.deepEqual(await response.json(), { error: "Owner access required" });
    assert.deepEqual(await snapshot(), before, "Denied transaction must not rewrite auth or append separate audit");
  };
  try {
    for (const operation of operations) {
      await check(`${operation.name}: current owner retains existing behavior`, async () => {
        await reset(operation.revoked); executions++;
        const response = await operation.invoke(); assert.equal(response.status, 200);
        const value = await response.json(), after = await storage.readAuthState();
        const target = after.licenses.find((entry) => entry.id === license.id)!;
        if (operation.name === "generate") {
          assert.equal(value.licenses.length, 1); assert.equal(after.licenses.length, 2);
          assert(after.licenses.some((entry) => entry.id === value.licenses[0].id && entry.ownerUserId === recipient.id));
          assert(!JSON.stringify(after).includes(value.licenses[0].key));
        } else if (operation.name === "edit") assert.equal(target.label, "After");
        else if (operation.name === "enable") assert.equal(target.revokedAt, null);
        else if (operation.name.includes("delete")) assert(target.deletedAt && target.revokedAt);
        else { assert(target.revokedAt); assert.equal(value.alreadyRevoked, operation.revoked); }
      });
      for (const drift of drifts) {
        await check(`${operation.name}: ${drift.name} actor before commit`, async () => {
          await reset(operation.revoked);
          let entered!: () => void, resume!: () => void;
          const arrived = new Promise<void>((resolve) => { entered = resolve; });
          const gate = new Promise<void>((resolve) => { resume = resolve; });
          let calls = 0;
          storage.mutateAuthState = async (fn) => { calls++; entered(); await bounded(gate); return originalMutation(fn); };
          executions++;
          const pending = operation.invoke(); void pending.catch(() => {});
          try {
            await bounded(arrived);
            await originalMutation(drift.change);
            const before = await snapshot(); resume();
            await denied(await bounded(pending), before); assert.equal(calls, 1);
          } finally { resume(); await Promise.allSettled([pending]); storage.mutateAuthState = originalMutation; }
        });
      }
      await check(`${operation.name}: replayed callback rechecks current actor`, async () => {
        await reset(operation.revoked);
        let attempts = 0, before: Awaited<ReturnType<typeof snapshot>> | undefined;
        storage.mutateAuthState = async (fn) => {
          // Discard an authorized proposal, then run the real local transaction
          // against the newly demoted actor. This models callback replay, not
          // a real Blob ETag conflict or distributed transaction.
          attempts++; fn(structuredClone(await storage.readAuthState()));
          await originalMutation(drifts[0].change); before = await snapshot();
          return originalMutation((state) => { attempts++; return fn(state); });
        };
        try { executions++; const response = await operation.invoke(); assert(before); await denied(response, before); assert.equal(attempts, 2); }
        finally { storage.mutateAuthState = originalMutation; }
      });
    }
  } finally {
    storage.mutateAuthState = originalMutation; resetStorageAdapterForTests(); process.chdir(previous);
    await fs.rm(scratch, { recursive: true, force: true });
    for (const key of Object.keys(process.env)) if (!(key in savedEnv)) delete process.env[key];
    Object.assign(process.env, savedEnv);
  }
  console.log(JSON.stringify({ kind: "console-license-authority", groups: passed + failed, passed, failed, executions,
    realLocalCommitDrift: 28, syntheticCallbackReplay: 7, networkOrDeviceEffects: false }));
  if (failed) process.exitCode = 1;
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
