/**
 * Unit tests for auth helpers + license grant/revoke/validate rules.
 * No live server. Run: npx tsx scripts/license-auth-test.ts
 */
import assert from "node:assert/strict";
import { accessKeyFromRequest, licenseValidity, normalizeAccessKey } from "../src/lib/licenses";
import { isValidLicenseKeyFormat } from "../src/lib/ids";
import { findUserByLogin, loginCandidates } from "../src/lib/identity";
import { getUserFromRequest, hashPassword, verifyPassword } from "../src/lib/auth";
import { keyIdPrefix } from "../src/lib/audit";
import { decryptProxySecret, encryptProxySecret } from "../src/lib/proxy-secrets";
import {
  AssignmentConflict,
  assignProxy,
  parseProxyInput,
  publicProxy,
} from "../src/lib/proxies";
import type {
  LicenseRecord,
  ProfileProxyAssignment,
  ProxyRecord,
  UserRecord,
} from "../src/lib/storage";

let passed = 0;
let failed = 0;

function check(name: string, fn: () => void | Promise<void>): Promise<void> {
  return Promise.resolve()
    .then(fn)
    .then(() => {
      passed++;
      console.log(`PASS  ${name}`);
    })
    .catch((err: unknown) => {
      failed++;
      const message = err instanceof Error ? err.message : String(err);
      console.log(`FAIL  ${name} ${message}`);
    });
}

function sampleLicense(over: Partial<LicenseRecord> = {}): LicenseRecord {
  return {
    id: "abcd1234efgh5678",
    keyHash: "hash",
    createdAt: "2026-01-01T00:00:00.000Z",
    activatedBy: null,
    activatedAt: null,
    revokedAt: null,
    expiresAt: null,
    ...over,
  };
}

async function main() {
  await check("normalizeAccessKey trims and uppercases", () => {
    assert.equal(normalizeAccessKey("  abcd-efgh-jkmn-pqrs  "), "ABCD-EFGH-JKMN-PQRS");
    assert.equal(normalizeAccessKey(""), null);
    assert.equal(normalizeAccessKey(null), null);
  });

  await check("accessKeyFromRequest prefers Bearer key over body", () => {
    const req = new Request("http://local/api/licenses/validate", {
      headers: { authorization: "Bearer ABCD-EFGH-JKMN-PQRS" },
    });
    assert.equal(accessKeyFromRequest(req, { key: "ZZZZ-ZZZZ-ZZZZ-ZZZZ" }), "ABCD-EFGH-JKMN-PQRS");
  });

  await check("accessKeyFromRequest ignores user JWTs (dots)", () => {
    const req = new Request("http://local/api/licenses/validate", {
      headers: { authorization: "Bearer aaa.bbb.ccc" },
    });
    assert.equal(accessKeyFromRequest(req, { key: "ABCD-EFGH-JKMN-PQRS" }), "ABCD-EFGH-JKMN-PQRS");
  });

  await check("licenseValidity: active key is valid", () => {
    const status = licenseValidity(sampleLicense());
    assert.equal(status.valid, true);
    assert.equal(status.revoked, false);
    assert.equal(status.expiresAt, null);
  });

  await check("licenseValidity: revoked is fail-closed", () => {
    const status = licenseValidity(
      sampleLicense({ revokedAt: "2026-02-01T00:00:00.000Z" })
    );
    assert.equal(status.valid, false);
    assert.equal(status.revoked, true);
  });

  await check("licenseValidity: expired is invalid but not revoked", () => {
    const now = Date.parse("2026-06-01T00:00:00.000Z");
    const status = licenseValidity(
      sampleLicense({ expiresAt: "2026-05-01T00:00:00.000Z" }),
      now
    );
    assert.equal(status.valid, false);
    assert.equal(status.revoked, false);
    assert.equal(status.expiresAt, "2026-05-01T00:00:00.000Z");
  });

  await check("licenseValidity: future expiry still valid", () => {
    const now = Date.parse("2026-06-01T00:00:00.000Z");
    const status = licenseValidity(
      sampleLicense({ expiresAt: "2026-12-01T00:00:00.000Z" }),
      now
    );
    assert.equal(status.valid, true);
    assert.equal(status.expiresAt, "2026-12-01T00:00:00.000Z");
  });

  await check("isValidLicenseKeyFormat accepts generated shape", () => {
    assert.equal(isValidLicenseKeyFormat("ABCD-EFGH-JKMN-PQRS"), true);
    assert.equal(isValidLicenseKeyFormat("ABCD-0000-IIII-OOOO"), false);
    assert.equal(isValidLicenseKeyFormat("not-a-key"), false);
  });

  await check("loginCandidates maps username to local email", () => {
    assert.deepEqual(loginCandidates("typekpaco"), ["typekpaco", "typekpaco@redditbox.local"]);
    assert.deepEqual(loginCandidates("TypeKPaco@example.com"), ["typekpaco@example.com"]);
  });

  await check("findUserByLogin matches username handle", () => {
    const users: UserRecord[] = [
      {
        id: "1",
        email: "typekpaco@redditbox.local",
        username: "typekpaco",
        passwordHash: "x",
        role: "admin",
        licensedAt: "2026-01-01T00:00:00.000Z",
        createdAt: "2026-01-01T00:00:00.000Z",
      },
    ];
    assert.equal(findUserByLogin(users, "typekpaco")?.id, "1");
    assert.equal(findUserByLogin(users, "TYPEKPACO")?.id, "1");
    assert.equal(findUserByLogin(users, "nobody"), undefined);
  });

  await check("hashPassword / verifyPassword round-trip", async () => {
    const hash = await hashPassword("ci-admin-password");
    assert.equal(await verifyPassword("ci-admin-password", hash), true);
    assert.equal(await verifyPassword("wrong", hash), false);
  });

  await check("keyIdPrefix is first 8 of license id, not the key", () => {
    assert.equal(keyIdPrefix("abcd1234efgh5678"), "abcd1234");
  });

  await check("proxy API auth helper rejects an unauthenticated request", async () => {
    assert.equal(await getUserFromRequest(new Request("http://local/api/proxies")), null);
  });

  await check("proxy input accepts supported types and rejects URL syntax", () => {
    const valid = parseProxyInput({
      name: "Residential",
      type: "http",
      host: "proxy.example.com",
      port: 1080,
      username: "worker",
      password: "secret",
    });
    assert.equal(valid.ok, true);
    assert.equal(
      parseProxyInput({
        name: "Bad",
        type: "ftp",
        host: "https://proxy.example.com/path",
        port: 99999,
      }).ok,
      false
    );
  });

  await check("public proxy responses mask stored passwords", () => {
    const proxy: ProxyRecord = {
      id: "proxy-1",
      userId: "user-1",
      name: "Residential",
      type: "https",
      host: "proxy.example.com",
      port: 443,
      username: "worker",
      password: "never-return-this",
      healthStatus: "healthy",
      lastCheckedAt: null,
      latencyMs: 50,
      healthMessage: null,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    const exposed = publicProxy(proxy);
    assert.equal(exposed.hasPassword, true);
    assert.equal(exposed.maskedPassword, "••••••••");
    assert.equal("password" in exposed, false);
    assert.equal(JSON.stringify(exposed).includes("never-return-this"), false);
  });

  await check("profile/proxy uniqueness does not rotate implicitly", () => {
    const existing: ProfileProxyAssignment = {
      id: "assignment-1",
      userId: "user-1",
      profileId: "profile-a",
      proxyId: "proxy-a",
      assignedAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:00.000Z",
    };
    const conflicting: ProfileProxyAssignment = {
      ...existing,
      id: "assignment-2",
      profileId: "profile-b",
    };
    assert.throws(
      () => assignProxy([existing], conflicting, false),
      AssignmentConflict
    );
    assert.deepEqual(assignProxy([existing], conflicting, true), [conflicting]);
  });

  await check("grant/revoke/validate state machine", () => {
    const granted = sampleLicense({ expiresAt: "2027-01-01T00:00:00.000Z" });
    assert.equal(licenseValidity(granted).valid, true);

    const revoked = { ...granted, revokedAt: "2026-09-01T00:00:00.000Z" };
    const afterRevoke = licenseValidity(revoked);
    assert.equal(afterRevoke.valid, false);
    assert.equal(afterRevoke.revoked, true);
    assert.equal(afterRevoke.expiresAt, "2027-01-01T00:00:00.000Z");
  });

  await check("per-profile rotation secrets encrypt and authenticate", () => {
    process.env.PROXY_SECRETS_KEY = "11".repeat(32);
    const encrypted = encryptProxySecret("Bearer profile-specific");
    assert.notEqual(encrypted, "Bearer profile-specific");
    assert.equal(decryptProxySecret(encrypted), "Bearer profile-specific");
    const parts = encrypted.split(".");
    parts[3] = `${parts[3]}A`;
    assert.throws(() => decryptProxySecret(parts.join(".")));
  });

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("license-auth-test crashed:", err);
  process.exit(1);
});
