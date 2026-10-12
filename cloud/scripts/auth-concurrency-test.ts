/**
 * Real local-storage authentication transactions, including competing processes.
 * Every record is synthetic. Change cwd BEFORE importing storage (it captures cwd).
 * Run with tsx scripts/auth-concurrency-test.ts; no server or credentials required.
 */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import type { AuthState, LicenseRecord, UserRecord } from "../src/lib/storage";

const scriptPath = path.resolve(process.argv[1]);
const cloudRoot = path.dirname(path.dirname(scriptPath));
const scratchParent = path.resolve(cloudRoot, "../..");
const tsxCLI = path.join(cloudRoot, "node_modules/tsx/dist/cli.mjs");
const fixtureDate = "2026-01-01T00:00:00.000Z";
const keyA = "ABCD-EFGH-JKMN-PQRS";
const keyB = "ZZZZ-YYYY-XXXX-WWWW";

function user(id: string): UserRecord {
  return { id, email: `${id}@concurrency.invalid`, passwordHash: "synthetic-unused",
    role: "user", licensedAt: null, createdAt: fixtureDate };
}

function assertScratch(directory: string): void {
  const relative = path.relative(scratchParent, directory);
  assert(!path.isAbsolute(relative) && !relative.startsWith(`..${path.sep}`));
  assert(relative.split(path.sep)[0].startsWith("auth-concurrency-"), "only synthetic test directories are allowed");
}

async function bounded<T>(promise: Promise<T>, label: string, ms = 10_000): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} timed out`)), ms);
    })]);
  } finally {
    clearTimeout(timer);
  }
}

// Only built-ins and erased type imports precede this function.
async function loadAPI() {
  delete process.env.BLOB_READ_WRITE_TOKEN;
  const storageModule = await import("../src/lib/storage");
  const pairing = await import("../src/lib/pairing");
  const licenses = await import("../src/lib/licenses");
  const { sha256Hex } = await import("../src/lib/ids");
  return { storage: storageModule.getStorage(), ...pairing, ...licenses, sha256Hex };
}

type Claim = Awaited<ReturnType<Awaited<ReturnType<typeof loadAPI>>["claimPairing"]>>;

// Child processes start together after all have loaded the real modules.
function startWorker(directory: string, action: string, value: string) {
  assertScratch(directory);
  const child = spawn(process.execPath, [tsxCLI, scriptPath, "--worker", action, value], {
    cwd: directory, env: { ...process.env, BLOB_READ_WRITE_TOKEN: "" },
    stdio: ["pipe", "pipe", "pipe"], windowsHide: true,
  });
  let stdout = "";
  let stderr = "";
  let readyResolve!: () => void;
  let readyReject!: (error: Error) => void;
  const ready = new Promise<void>((resolve, reject) => { readyResolve = resolve; readyReject = reject; });
  const result = new Promise<unknown>((resolve, reject) => {
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString();
      if (stdout.startsWith("READY\n")) readyResolve();
    });
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.once("error", (error) => { readyReject(error); reject(error); });
    child.once("close", (code) => {
      if (code !== 0) {
        const error = new Error(`Authentication worker exited ${code}: ${stderr}`);
        readyReject(error); reject(error); return;
      }
      const line = stdout.split("\n").find((item) => item.startsWith("RESULT "));
      if (!line) {
        const error = new Error("Authentication worker did not return a result");
        readyReject(error); reject(error); return;
      }
      try { resolve(JSON.parse(line.slice(7))); } catch (error) { reject(error); }
    });
  });
  // The readiness phase runs before callers await result; retain early failures.
  void result.catch(() => {});
  return { child, ready, result };
}

async function competingWorkers(directory: string, action: string, values: string[]): Promise<unknown[]> {
  const workers = values.map((value) => startWorker(directory, action, value));
  try {
    await bounded(Promise.all(workers.map((worker) => worker.ready)), "worker startup", 20_000);
    workers.forEach((worker) => worker.child.stdin.end("GO\n"));
    return await bounded(Promise.all(workers.map((worker) => worker.result)), "competing workers", 25_000);
  } finally {
    workers.forEach((worker) => { if (worker.child.exitCode === null) worker.child.kill(); });
    await Promise.allSettled(workers.map((worker) => worker.result));
  }
}

async function workerMain(): Promise<void> {
  assertScratch(process.cwd());
  const api = await loadAPI();
  const go = new Promise<void>((resolve) => process.stdin.once("data", () => resolve()));
  process.stdout.write("READY\n");
  await bounded(go, "worker start signal", 20_000);
  let result: unknown;
  if (process.argv[3] === "claim") {
    result = await api.claimPairing(process.argv[4]);
  } else if (process.argv[3] === "migrate-and-add-user") {
    await api.storage.mutateCollection<UserRecord>("users", (users) => [...users, user(process.argv[4])]);
    result = { added: process.argv[4] };
  } else if (process.argv[3] === "read-authoritative") {
    try {
      await api.storage.readCollection<UserRecord>("users");
      result = { readSucceeded: true };
    } catch (error) {
      result = { readSucceeded: false, error: error instanceof Error ? error.message : String(error) };
    }
  } else {
    throw new Error("Unknown synthetic worker action");
  }
  process.stdout.write(`RESULT ${JSON.stringify(result)}\n`);
}

async function main(): Promise<void> {
  const originalDirectory = process.cwd();
  const scratch = await fs.mkdtemp(path.join(scratchParent, "auth-concurrency-"));
  assertScratch(scratch);
  process.chdir(scratch);
  try {
    const api = await loadAPI();
    const { storage, sha256Hex, createPairing, claimPairing, activateLicenseForUser, revokeLicense } = api;
    const authFile = path.join(scratch, ".data/auth-state.json");
    const originalRename = fs.rename;
    const sampleLicense = (id: string, key: string): LicenseRecord => ({
      id, keyHash: "synthetic-unused", keyFingerprint: sha256Hex(key), createdAt: fixtureDate,
      activatedBy: null, activatedAt: null, revokedAt: null, expiresAt: null,
    });
    const reset = async (users = [user("owner-a")], licenses: LicenseRecord[] = []) => {
      await storage.mutateAuthState(() => ({ users, licenses, devices: [], "pairing-codes": [] }));
    };
    const readState = async (): Promise<AuthState> => {
      const document = JSON.parse(await fs.readFile(authFile, "utf8"));
      assert.equal(document.items.length, 1);
      return document.items[0];
    };
    let passed = 0;
    const check = async (name: string, operation: () => Promise<void>) => {
      await operation();
      passed++;
      console.log(`PASS  ${name}`);
    };
    const assertOneClaim = async (results: Claim[], deviceId: string) => {
      const winners = results.filter((result) => "token" in result);
      assert.equal(winners.length, 1, "a pairing code must return exactly one token");
      const state = await readState();
      const device = state.devices.find((item) => item.id === deviceId)!;
      assert(device);
      assert.equal(device.tokenHash, sha256Hex(winners[0].token));
      const code = state["pairing-codes"].find((item) => item.deviceId === deviceId)!;
      assert(code.consumedAt);
      assert.equal(code.consumedByDeviceId, deviceId);
    };

    // Hold the first atomic commit while the second real operation starts.
    async function ordered<A, B>(first: () => Promise<A>, second: () => Promise<B>): Promise<[A, B]> {
      let signalEntered!: () => void;
      let signalSecondAttempt!: () => void;
      let release!: () => void;
      let armed = true;
      let observeSecond = false;
      const entered = new Promise<void>((resolve) => { signalEntered = resolve; });
      const secondAttempt = new Promise<void>((resolve) => { signalSecondAttempt = resolve; });
      const released = new Promise<void>((resolve) => { release = resolve; });
      const originalMutateAuthState = storage.mutateAuthState;
      storage.mutateAuthState = (fn) => {
        if (observeSecond) signalSecondAttempt();
        return originalMutateAuthState.call(storage, fn);
      };
      fs.rename = async (source, destination) => {
        if (String(destination) === authFile && armed) {
          armed = false;
          signalEntered();
          await released;
        }
        await originalRename(source, destination);
      };
      const firstResult = first();
      void firstResult.catch(() => {});
      let secondResult: Promise<B> | undefined;
      try {
        await bounded(entered, "first commit gate");
        observeSecond = true;
        secondResult = second();
        void secondResult.catch(() => {});
        await bounded(secondAttempt, "second transaction attempt before first commit");
        release();
        return await bounded(Promise.all([firstResult, secondResult]), "ordered authentication operations");
      } finally {
        release();
        await Promise.allSettled(secondResult ? [firstResult, secondResult] : [firstResult]);
        fs.rename = originalRename;
        storage.mutateAuthState = originalMutateAuthState;
      }
    }

    async function failedCommit(operation: () => Promise<unknown>): Promise<void> {
      const before = await fs.readFile(authFile, "utf8");
      let injected = false;
      fs.rename = async (source, destination) => {
        if (String(destination) === authFile) {
          injected = true;
          throw Object.assign(new Error("Injected authentication commit failure"), { code: "EIO" });
        }
        await originalRename(source, destination);
      };
      try {
        await assert.rejects(operation, /Injected authentication commit failure/);
      } finally {
        fs.rename = originalRename;
      }
      assert(injected, "test must reach the actual atomic replacement");
      assert.equal(await fs.readFile(authFile, "utf8"), before, "failed commit must preserve every authentication record");
      assert(!(await fs.readdir(path.dirname(authFile))).some((name) => name.includes(".tmp-") || name === ".mutation-lock"));
    }

    await check("two simultaneous pairing claims return one persisted token", async () => {
      await reset();
      const pairing = await createPairing("owner-a", "Synthetic phone", "worker");
      await assertOneClaim(await Promise.all([claimPairing(pairing.pairingCode), claimPairing(pairing.pairingCode)]), pairing.deviceId);
    });

    await check("two users competing for one key grant exactly one entitlement", async () => {
      await reset([user("owner-a"), user("owner-b")], [sampleLicense("license-a", keyA)]);
      const results = await Promise.all([activateLicenseForUser(keyA, "owner-a"), activateLicenseForUser(keyA, "owner-b")]);
      assert.equal(results.filter((result) => "licensed" in result).length, 1);
      const state = await readState();
      const granted = state.users.filter((item) => item.licensedAt);
      assert.equal(granted.length, 1);
      assert.equal(state.licenses[0].activatedBy, granted[0].email);
      assert.equal(state.licenses[0].activatedAt, granted[0].licensedAt);
    });

    await check("one user competing with two keys consumes only one key", async () => {
      await reset([user("owner-a")], [sampleLicense("license-a", keyA), sampleLicense("license-b", keyB)]);
      const results = await Promise.all([activateLicenseForUser(keyA, "owner-a"), activateLicenseForUser(keyB, "owner-a")]);
      assert(results.some((result) => "licensed" in result));
      const state = await readState();
      const consumed = state.licenses.filter((item) => item.activatedAt);
      assert.equal(consumed.length, 1);
      assert.equal(consumed[0].activatedBy, state.users[0].email);
      assert.equal(consumed[0].activatedAt, state.users[0].licensedAt);
      assert.equal(state.licenses.filter((item) => !item.activatedAt && !item.activatedBy).length, 1);
    });

    await check("activation commits before queued revocation without retaining entitlement", async () => {
      await reset([user("owner-a")], [sampleLicense("license-a", keyA)]);
      const [activation, revocation] = await ordered(() => activateLicenseForUser(keyA, "owner-a"), () => revokeLicense("license-a"));
      assert("licensed" in activation);
      assert("license" in revocation);
      const state = await readState();
      assert(state.licenses[0].revokedAt);
      assert.equal(state.users[0].licensedAt, null);
    });

    await check("revocation commits before queued activation and prevents a grant", async () => {
      await reset([user("owner-a")], [sampleLicense("license-a", keyA)]);
      const [revocation, activation] = await ordered(() => revokeLicense("license-a"), () => activateLicenseForUser(keyA, "owner-a"));
      assert("license" in revocation);
      assert("error" in activation);
      const state = await readState();
      assert(state.licenses[0].revokedAt);
      assert.equal(state.licenses[0].activatedAt, null);
      assert.equal(state.users[0].licensedAt, null);
    });

    await check("failed pairing commit preserves code and device; retry succeeds", async () => {
      await reset();
      const pairing = await createPairing("owner-a", "Synthetic phone", "worker");
      await failedCommit(() => claimPairing(pairing.pairingCode));
      await assertOneClaim([await claimPairing(pairing.pairingCode)], pairing.deviceId);
    });

    await check("retrying an old key revocation preserves a newer key entitlement", async () => {
      await reset([user("owner-a")], [sampleLicense("license-a", keyA), sampleLicense("license-b", keyB)]);
      const originalISO = Date.prototype.toISOString;
      // Force equal timestamps so an old grant cannot be distinguished merely
      // by comparing licensedAt with activatedAt; the current key must survive.
      Date.prototype.toISOString = () => fixtureDate;
      try {
        assert("licensed" in await activateLicenseForUser(keyA, "owner-a"));
        assert("license" in await revokeLicense("license-a"));
        assert("licensed" in await activateLicenseForUser(keyB, "owner-a"));
        const before = await readState();
        const retry = await revokeLicense("license-a");
        assert("license" in retry && retry.alreadyRevoked);
        const after = await readState();
        assert.deepEqual(after.users, before.users);
        assert.deepEqual(after.licenses, before.licenses);
        assert(after.users[0].licensedAt);
      } finally {
        Date.prototype.toISOString = originalISO;
      }
    });

    await check("failed license activation/revocation commits preserve both records; retries succeed", async () => {
      await reset([user("owner-a")], [sampleLicense("license-a", keyA)]);
      await failedCommit(() => activateLicenseForUser(keyA, "owner-a"));
      assert("licensed" in await activateLicenseForUser(keyA, "owner-a"));
      await failedCommit(() => revokeLicense("license-a"));
      assert("license" in await revokeLicense("license-a"));
      const state = await readState();
      assert(state.licenses[0].revokedAt);
      assert.equal(state.users[0].licensedAt, null);
    });

    await check("competing OS processes return exactly one pairing token", async () => {
      await reset();
      const pairing = await createPairing("owner-a", "Synthetic phone", "worker");
      const results = await competingWorkers(scratch, "claim", [pairing.pairingCode, pairing.pairingCode]);
      await assertOneClaim(results as Claim[], pairing.deviceId);
    });

    await check("concurrent first-use migration preserves legacy and newly committed records", async () => {
      const directory = path.join(scratch, "legacy-migration");
      const dataDirectory = path.join(directory, ".data");
      await fs.mkdir(dataDirectory, { recursive: true });
      const legacy: AuthState = {
        users: [user("legacy-owner")], licenses: [sampleLicense("legacy-license", keyA)],
        devices: [{ id: "legacy-device", userId: "legacy-owner", name: "Legacy synthetic phone", role: "worker",
          tokenHash: null, pairedAt: fixtureDate, lastSeenAt: fixtureDate }],
        "pairing-codes": [{ id: "legacy-code", code: "ABCD2345", userId: "legacy-owner", deviceId: "legacy-device",
          createdAt: fixtureDate, expiresAt: "2099-01-01T00:00:00.000Z", consumedAt: null, consumedByDeviceId: null }],
      };
      const originals = new Map<string, string>();
      for (const [name, records] of Object.entries(legacy)) {
        const contents = JSON.stringify({ version: 7, items: records });
        originals.set(name, contents);
        await fs.writeFile(path.join(dataDirectory, `${name}.json`), contents);
      }
      await competingWorkers(directory, "migrate-and-add-user", ["new-owner-a", "new-owner-b"]);
      const migrated = JSON.parse(await fs.readFile(path.join(dataDirectory, "auth-state.json"), "utf8")).items[0] as AuthState;
      assert.deepEqual(migrated.users.map((item) => item.id).sort(), ["legacy-owner", "new-owner-a", "new-owner-b"]);
      assert.deepEqual(migrated.users.find((item) => item.id === "legacy-owner"), legacy.users[0]);
      for (const name of ["licenses", "devices", "pairing-codes"] as const) assert.deepEqual(migrated[name], legacy[name]);
      for (const [name, contents] of originals) assert.equal(await fs.readFile(path.join(dataDirectory, `${name}.json`), "utf8"), contents);
    });

    await check("an existing empty authoritative document never reactivates legacy records", async () => {
      const directory = path.join(scratch, "empty-authoritative");
      const dataDirectory = path.join(directory, ".data");
      await fs.mkdir(dataDirectory, { recursive: true });
      const emptyAuthoritative = JSON.stringify({ version: 9, items: [] });
      const legacyUsers = JSON.stringify({ version: 2, items: [user("must-stay-inactive")] });
      await fs.writeFile(path.join(dataDirectory, "auth-state.json"), emptyAuthoritative);
      await fs.writeFile(path.join(dataDirectory, "users.json"), legacyUsers);
      const results = await competingWorkers(directory, "read-authoritative", ["", ""]) as { readSucceeded: boolean; error?: string }[];
      for (const result of results) {
        assert.equal(result.readSucceeded, false);
        assert.match(result.error ?? "", /Corrupt authentication state/);
      }
      assert.equal(await fs.readFile(path.join(dataDirectory, "auth-state.json"), "utf8"), emptyAuthoritative);
      assert.equal(await fs.readFile(path.join(dataDirectory, "users.json"), "utf8"), legacyUsers);
    });

    console.log(`\n${passed} authentication concurrency tests passed (isolated local storage; no live Blob store).`);
  } finally {
    process.chdir(originalDirectory);
    assertScratch(scratch);
    await fs.rm(scratch, { recursive: true, force: true });
  }
}

(process.argv[2] === "--worker" ? workerMain() : main()).catch((error: unknown) => {
  console.error(error instanceof Error ? error.stack : String(error));
  process.exitCode = 1;
});
