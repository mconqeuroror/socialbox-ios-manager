/**
 * Smoke test for the SocialBox Cloud shared API contract.
 * Run with: node scripts/smoke-test.mjs [baseUrl]
 * Requires the dev server (or any deployment) running.
 *
 * Contract:
 *   POST /api/auth/register {email, password}
 *   POST /api/auth/login    {email, password} -> {token}
 *   POST /api/devices/pair  {name, role} Authorization: Bearer -> {deviceId, pairingCode}
 *   POST /api/devices/claim {pairingCode} -> {deviceId, token}
 *   POST /api/profiles {profileId} with device token -> registered inventory row
 *   POST /api/backups       {containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed?}
 *   GET  /api/backups?containerId=
 *   GET  /api/backups/:id
 *   DELETE /api/backups/:id
 */
const BASE = process.argv[2] || "http://localhost:3000";

let passed = 0;
let failed = 0;
function check(name, cond, extra = "") {
  if (cond) {
    passed++;
    console.log(`PASS  ${name}`);
  } else {
    failed++;
    console.log(`FAIL  ${name} ${extra}`);
  }
}

async function json(res) {
  try {
    return await res.json();
  } catch {
    return null;
  }
}

function randomEmail() {
  return `smoke-${Date.now()}-${Math.random().toString(16).slice(2)}@example.com`;
}

async function main() {
  console.log(`Smoke test against ${BASE}\n`);

  const email = randomEmail();
  const password = "smoke-pass-123";

  // -- register -------------------------------------------------------------
  let res = await fetch(`${BASE}/api/auth/register`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  let data = await json(res);
  check("register 200", res.status === 200, JSON.stringify(data));
  check("register returns token", typeof data?.token === "string" && data.token.includes("."));

  // -- login ----------------------------------------------------------------
  res = await fetch(`${BASE}/api/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  data = await json(res);
  check("login 200", res.status === 200);
  check("login returns token", typeof data?.token === "string" && data.token.includes("."));
  const userToken = data?.token;
  const userAuth = { Authorization: `Bearer ${userToken}` };

  res = await fetch(`${BASE}/api/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: "wrong" }),
  });
  check("wrong password 401", res.status === 401);

  // -- pair -----------------------------------------------------------------
  res = await fetch(`${BASE}/api/devices/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: "Factory A", role: "factory" }),
  });
  check("pair without auth 401", res.status === 401);

  res = await fetch(`${BASE}/api/devices/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...userAuth },
    body: JSON.stringify({ name: "Factory A", role: "not-a-role" }),
  });
  check("pair bad role 400", res.status === 400);

  res = await fetch(`${BASE}/api/devices/pair`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...userAuth },
    body: JSON.stringify({ name: "Factory A", role: "factory" }),
  });
  data = await json(res);
  check("pair 200", res.status === 200, JSON.stringify(data));
  check("pair returns deviceId", typeof data?.deviceId === "string");
  check("pair returns pairingCode", typeof data?.pairingCode === "string" && data.pairingCode.length === 8);
  const pairingCode = data?.pairingCode;
  const deviceId = data?.deviceId;

  // -- claim ----------------------------------------------------------------
  res = await fetch(`${BASE}/api/devices/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairingCode: "ZZZZZZZZ" }),
  });
  check("claim unknown code 404", res.status === 404);

  res = await fetch(`${BASE}/api/devices/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairingCode }),
  });
  data = await json(res);
  check("claim 200", res.status === 200, JSON.stringify(data));
  check("claim deviceId matches", data?.deviceId === deviceId);
  check("claim returns token", /^[0-9a-f]{64}$/.test(data?.token ?? ""));
  const deviceToken = data?.token;
  const deviceAuth = { Authorization: `Bearer ${deviceToken}` };

  res = await fetch(`${BASE}/api/devices/claim`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ pairingCode }),
  });
  check("claim reuse rejected", res.status === 404 || res.status === 409);

  // -- backups JSON contract ------------------------------------------------
  const ciphertext = Buffer.from("opaque-ciphertext-bytes-for-smoke");
  const iv = Buffer.alloc(12, 7);
  const salt = Buffer.alloc(16, 9);
  const { createHash, randomUUID } = await import("node:crypto");
  const profileId = `smoke-${randomUUID()}`;
  const checksum = createHash("sha256").update(ciphertext).digest("hex");
  const createdAt = new Date().toISOString();
  const backupBody = {
    containerId: profileId,
    ciphertext: ciphertext.toString("base64"),
    iv: iv.toString("base64"),
    salt: salt.toString("base64"),
    checksum,
    createdAt,
    attestKeyUsed: false,
  };

  res = await fetch(`${BASE}/api/backups`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...deviceAuth },
    body: JSON.stringify(backupBody),
  });
  data = await json(res);
  check("unregistered profile backup rejected without receipt", res.status === 403 &&
    data?.error === "Register this profile on the authenticated device before uploading a backup" &&
    !Object.hasOwn(data, "backupId") && !Object.hasOwn(data, "id"));

  res = await fetch(`${BASE}/api/profiles`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...deviceAuth },
    body: JSON.stringify({ profileId: backupBody.containerId }),
  });
  data = await json(res);
  check("profile registration binds backup to authenticated device", res.status === 201 &&
    data?.profile?.profileId === backupBody.containerId && data?.profile?.deviceId === deviceId);

  res = await fetch(`${BASE}/api/backups`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...deviceAuth },
    body: JSON.stringify(backupBody),
  });
  data = await json(res);
  check("backup upload 200", res.status === 200, JSON.stringify(data));
  check("returns backupId", typeof data?.backupId === "string" && data.backupId.length === 16);
  const backupId = data?.backupId;

  res = await fetch(`${BASE}/api/backups`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      containerId: profileId,
      ciphertext: ciphertext.toString("base64"),
      iv: iv.toString("base64"),
      salt: salt.toString("base64"),
      checksum,
      createdAt,
    }),
  });
  check("backup without device token 401", res.status === 401);

  res = await fetch(`${BASE}/api/backups?containerId=${encodeURIComponent(profileId)}`, { headers: deviceAuth });
  data = await json(res);
  check("list 200", res.status === 200);
  check("list filtered has backup", (data?.backups ?? []).some((b) => (b.backupId || b.id) === backupId));
  check("list has no ciphertext", !(data?.backups ?? []).some((b) => "ciphertext" in b));

  res = await fetch(`${BASE}/api/backups?containerId=does-not-exist`, { headers: deviceAuth });
  data = await json(res);
  check("list other container empty", (data?.backups ?? []).length === 0);

  res = await fetch(`${BASE}/api/backups/${backupId}`, { headers: deviceAuth });
  data = await json(res);
  check("get backup 200", res.status === 200);
  check("get returns ciphertext", typeof data?.ciphertext === "string");
  check("get returns iv/salt/checksum", data?.iv && data?.salt && data?.checksum === checksum);
  check("get containerId", data?.containerId === profileId);
  check("get ciphertext opaque match", data?.ciphertext === ciphertext.toString("base64"));

  res = await fetch(`${BASE}/api/backups/${backupId}`, { method: "DELETE", headers: userAuth });
  check("delete via user JWT 200", res.status === 200);

  res = await fetch(`${BASE}/api/backups/${backupId}`, { headers: deviceAuth });
  check("deleted backup 404", res.status === 404);

  // -- license admin (fail-closed for non-admin; full cycle if admin env) --
  res = await fetch(`${BASE}/api/admin/licenses`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ count: 1 }),
  });
  check("grant without auth 403", res.status === 403 || res.status === 401);

  res = await fetch(`${BASE}/api/admin/licenses`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...userAuth },
    body: JSON.stringify({ count: 1 }),
  });
  check("grant as regular user 403", res.status === 403);

  res = await fetch(`${BASE}/api/licenses/validate`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
  data = await json(res);
  check("validate missing key fail-closed", res.status === 200 && data?.valid === false);
  check("validate missing key not revoked", data?.revoked === false);

  const adminUser = process.env.ADMIN_USERNAME || process.env.ADMIN_EMAIL;
  const adminPassword = process.env.ADMIN_PASSWORD;
  if (adminUser && adminPassword) {
    res = await fetch(`${BASE}/api/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        username: adminUser,
        email: adminUser,
        password: adminPassword,
      }),
    });
    data = await json(res);
    check("admin login 200", res.status === 200, res.status === 200 ? "" : `status ${res.status}`);
    const adminToken = data?.token;
    const adminUserId = data?.user?.id;
    const adminActor = data?.user?.username || data?.user?.email;
    check("admin login identifies actor", typeof adminUserId === "string" && adminUserId.length > 0);
    const adminAuth = adminToken ? { Authorization: `Bearer ${adminToken}` } : {};

    res = await fetch(`${BASE}/api/admin/licenses`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...adminAuth },
      body: JSON.stringify({ count: 1, expiresInDays: 30 }),
    });
    data = await json(res);
    check("admin grant 200", res.status === 200, `status ${res.status}`);
    const grantedKey = data?.licenses?.[0]?.key;
    const grantedId = data?.licenses?.[0]?.id;
    const grantedExpiry = data?.licenses?.[0]?.expiresAt;
    check("admin grant returns key once", typeof grantedKey === "string" && grantedKey.includes("-"));
    check("admin grant identifies exact license", typeof grantedId === "string" && /^[0-9a-f]{16}$/.test(grantedId));
    check("admin grant has expiresAt", typeof grantedExpiry === "string" && Date.parse(grantedExpiry) > Date.now());

    res = await fetch(`${BASE}/api/admin/licenses`, { headers: adminAuth });
    data = await json(res);
    check("admin list 200", res.status === 200);
    const grantedLicense = (data?.licenses ?? []).find((l) => l.id === grantedId);
    check("admin list contains exact active device license", !!grantedLicense &&
      grantedLicense.kind === "device" && grantedLicense.status === "active" &&
      grantedLicense.valid === true && grantedLicense.revoked === false &&
      grantedLicense.ownerUserId === adminUserId && grantedLicense.expiresAt === grantedExpiry &&
      grantedLicense.keyIdPrefix === grantedId?.slice(0, 8));
    check("admin list includes audit", Array.isArray(data?.audit));
    const generateEvent = (grantedLicense?.history ?? []).find((event) =>
      event.action === "generate" && event.licenseId === grantedId);
    check("device license generation history identifies actor and time", !!generateEvent &&
      generateEvent.actorUserId === adminUserId && Number.isFinite(Date.parse(generateEvent.at)));
    check("admin list and history never return granted key", typeof grantedKey === "string" &&
      !JSON.stringify(data).includes(grantedKey) && (data?.licenses ?? []).every((license) =>
        !Object.hasOwn(license, "key") && !Object.hasOwn(license, "keyHash") && !Object.hasOwn(license, "keyFingerprint")));

    res = await fetch(`${BASE}/api/licenses/validate`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: grantedKey }),
    });
    data = await json(res);
    // Signed claim/heartbeat success is exercised by device-license-test.ts.
    // A newly generated device key cannot authorize the legacy unsigned route.
    check("device key requires signed installation-bound validation", res.status === 200 &&
      data?.valid === false && data?.revoked === false &&
      data?.error === "Device keys require signed installation-bound validation");
    check("validate preserves exact license expiry", data?.expiresAt === grantedExpiry);

    res = await fetch(`${BASE}/api/admin/licenses/${grantedId}/revoke`, {
      method: "POST",
      headers: adminAuth,
    });
    data = await json(res);
    check("admin revoke 200", res.status === 200 && data?.id === grantedId &&
      data?.alreadyRevoked === false && Number.isFinite(Date.parse(data?.revokedAt)));

    res = await fetch(`${BASE}/api/licenses/validate`, {
      method: "POST",
      headers: { Authorization: `Bearer ${grantedKey}` },
    });
    data = await json(res);
    check("validate revoked key fail-closed", res.status === 200 && data?.valid === false &&
      data?.revoked === true && data?.expiresAt === grantedExpiry);

    res = await fetch(`${BASE}/api/admin/licenses`, { headers: adminAuth });
    data = await json(res);
    const revokedLicense = (data?.licenses ?? []).find((license) => license.id === grantedId);
    const revokeEvent = (revokedLicense?.history ?? []).find((event) =>
      event.action === "revoke" && event.licenseId === grantedId);
    check("admin list identifies exact revoked device license and history", res.status === 200 &&
      revokedLicense?.valid === false && revokedLicense?.revoked === true &&
      revokedLicense?.status === "revoked" && !!revokeEvent && Number.isFinite(Date.parse(revokeEvent.at)));
    const revokeAudit = (data?.audit ?? []).find((a) =>
      a.action === "revoke" && a.keyIdPrefix === grantedId?.slice(0, 8) && a.actorUsername === adminActor);
    check("audit has revoke event", res.status === 200 && !!revokeAudit &&
      Number.isFinite(Date.parse(revokeAudit.at)));
  } else {
    console.log("SKIP  admin grant/revoke/validate (set ADMIN_USERNAME + ADMIN_PASSWORD)");
  }

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
  console.error("Smoke test crashed:", err);
  process.exit(1);
});
