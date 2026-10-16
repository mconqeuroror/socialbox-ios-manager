import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, createPublicKey, verify, generateKeyPairSync } from 'node:crypto';
import { startHarness } from './support.mjs';
import { canonicalKey, canonicalInstallation, createProof, newLicenseKey, passwordHash, sha256, x963PublicKey } from '../lib/crypto.mjs';
import { loadConfig } from '../lib/config.mjs';
import { RedisRest } from '../lib/redis.mjs';
import { RATE_SCRIPT } from '../lib/store.mjs';
let h;
before(async () => { h = await startHarness(); });
after(async () => { if (h) await h.close(); });
beforeEach(async () => { await h.reset(); });
function req(endpoint, body, options = {}) {
  return new Request(`https://license.example.com/api/${endpoint}`, { method: options.method || (body === undefined ? 'GET' : 'POST'), headers: { 'Content-Type': 'application/json', Origin: h.config.origin, 'x-vercel-forwarded-for': '203.0.113.4', ...options.headers }, ...(body === undefined ? {} : { body: typeof body === 'string' ? body : JSON.stringify(body) }) });
}
async function validate(key, installationId = randomUUID(), headers = {}) {
  return h.app(req('validate', { key, installationId }, { headers: { 'x-socialbox-client-key': h.config.clientKey, ...headers } }));
}
async function login() {
  const response = await h.app(req('login', { email: 'owner@example.com', password: 'correct-horse-socialbox-admin' }));
  assert.equal(response.status, 200);
  const data = await response.json(); return { cookie: response.headers.get('set-cookie').split(';')[0], csrf: data.csrfToken, response };
}
function adminReq(endpoint, body, auth, headers = {}) { return req(endpoint, body, { headers: { Cookie: auth.cookie, 'x-csrf-token': auth.csrf, ...headers } }); }

test('256-bit license keys normalize case and trim only; installation requires a random UUID', () => {
  const keys = Array.from({ length: 1000 }, newLicenseKey); assert.equal(new Set(keys).size, 1000);
  assert.equal(canonicalKey(`  ${keys[0].toLowerCase()}\n`), keys[0]);
  assert.equal(canonicalKey('SBX-short'), null); assert.equal(canonicalKey({}), null);
  const uuid = randomUUID(); assert.equal(canonicalInstallation(uuid.toUpperCase()), uuid);
  assert.equal(canonicalInstallation('physical-device-serial'), null);
});

test('bulk generation is atomic, stores only masked/hash keys and starts duration on activation', async () => {
  const generated = await h.store.generate(100, 30, 'Launch batch');
  assert.equal(generated.length, 100);
  const listed = await h.store.list(); assert.equal(listed.total, 100); assert.equal(listed.licenses.length, 50);
  assert.ok(listed.licenses.every(item => item.status === 'unactivated' && item.activatedAt === null && item.expiresAt === null));
  const stored = await h.command(['HGETALL', h.store.key(generated[0].id)]);
  assert.ok(!JSON.stringify(stored).includes(generated[0].key));
  assert.equal(await h.command(['TTL', h.store.key(generated[0].id)]), -1);
  assert.equal(generated[0].id, sha256(generated[0].key));
});

test('64 simultaneous first activations produce exactly one installation winner', async () => {
  const [license] = await h.store.generate(1, 30, 'Race');
  const installations = Array.from({ length: 64 }, randomUUID);
  const results = await Promise.all(installations.map(installation => h.store.validate(license.id, sha256(installation))));
  const winners = results.map((result, index) => ({ result, index })).filter(item => item.result.valid);
  assert.equal(winners.length, 1);
  const { result, index } = winners[0]; assert.equal(result.expiresAt - result.issuedAt, 30 * 86400);
  const repeat = await h.store.validate(license.id, sha256(installations[index])); assert.equal(repeat.valid, true); assert.equal(repeat.expiresAt, result.expiresAt);
  const [record] = (await h.store.list()).licenses; assert.equal(record.status, 'active'); assert.ok(record.activatedAt); assert.ok(record.lastCheckIn);
});

test('repeat winner does not move first activation or extend expiry; expiry and revocation deny access', async () => {
  const [license] = await h.store.generate(1, 7, ''); const installHash = sha256(randomUUID());
  const first = await h.store.validate(license.id, installHash);
  const repeats = await Promise.all(Array.from({ length: 20 }, () => h.store.validate(license.id, installHash)));
  assert.ok(repeats.every(result => result.valid && result.expiresAt === first.expiresAt));
  await h.command(['HSET', h.store.key(license.id), 'expiresAt', first.issuedAt]);
  assert.equal((await h.store.validate(license.id, installHash)).valid, false);
  assert.equal((await h.store.list()).licenses[0].status, 'expired');
  await h.store.revoke(license.id); assert.equal((await h.store.list()).licenses[0].status, 'revoked');
  assert.equal((await h.store.validate(license.id, installHash)).valid, false);
  assert.equal(await h.store.revoke('0'.repeat(64)), false);
});

test('revoking an unactivated key prevents any activation; completed revoke wins all following checks', async () => {
  const [license] = await h.store.generate(1, 90, ''); await h.store.revoke(license.id);
  const results = await Promise.all(Array.from({ length: 40 }, () => h.store.validate(license.id, sha256(randomUUID()))));
  assert.ok(results.every(result => !result.valid));
  const row = (await h.store.list()).licenses[0]; assert.equal(row.activatedAt, null); assert.equal(row.status, 'revoked');
});

test('validate response body is minimal and proof is DER P256 over exact JSON, bound to key/install', async () => {
  const [license] = await h.store.generate(1, 7, ''), installation = randomUUID();
  const response = await validate(license.key.toLowerCase(), installation.toUpperCase()); assert.equal(response.status, 200);
  const body = await response.json(); assert.deepEqual(Object.keys(body).sort(), ['expiresAt', 'valid']); assert.equal(body.valid, true);
  const proof = response.headers.get('x-socialbox-license-proof'), parts = proof.split('.'); assert.equal(parts.length, 2);
  const payload = Buffer.from(parts[0], 'base64url'), signature = Buffer.from(parts[1], 'base64url'); assert.equal(signature[0], 0x30);
  assert.equal(verify('sha256', payload, createPublicKey(h.config.signingKey), signature), true);
  const claims = JSON.parse(payload); assert.equal(claims.v, 1); assert.equal(claims.kid, h.config.proofKeyId);
  assert.equal(claims.keySHA256, sha256(license.key)); assert.equal(claims.installSHA256, sha256(installation));
  assert.equal(claims.expiresAt, Date.parse(body.expiresAt) / 1000); assert.equal(claims.offlineUntil, Math.min(claims.expiresAt, claims.issuedAt + 259200));
  assert.equal(Buffer.from(x963PublicKey(h.config.signingKey), 'base64').length, 65);
  payload[5] ^= 1; assert.equal(verify('sha256', payload, createPublicKey(h.config.signingKey), signature), false);
});

test('unknown, bound elsewhere, revoked and malformed requests reveal no key details', async () => {
  const [license] = await h.store.generate(1, 30, ''), installation = randomUUID(); await validate(license.key, installation);
  for (const key of [license.key, newLicenseKey()]) {
    const response = await validate(key); assert.equal(response.status, 200); assert.deepEqual(await response.json(), { valid: false, expiresAt: null }); assert.equal(response.headers.get('x-socialbox-license-proof'), null);
  }
  await h.store.revoke(license.id); assert.deepEqual(await (await validate(license.key, installation)).json(), { valid: false, expiresAt: null });
  const malformed = await validate('bad'); assert.equal(malformed.status, 400); assert.deepEqual(await malformed.json(), { valid: false, expiresAt: null });
});

test('shared client key rotation accepts current/previous and rejects missing or incorrect header', async () => {
  const [license] = await h.store.generate(1, 30, ''), installation = randomUUID();
  assert.equal((await validate(license.key, installation, { 'x-socialbox-client-key': h.config.previousClientKey })).status, 200);
  for (const secret of ['', 'wrong']) {
    const response = await validate(license.key, installation, { 'x-socialbox-client-key': secret }); assert.equal(response.status, 401); assert.deepEqual(await response.json(), { valid: false, expiresAt: null });
  }
});

test('rate limit is atomic across requests and has bounded TTL', async () => {
  const results = await Promise.all(Array.from({ length: 100 }, () => h.store.rateLimit('concurrent', 60, 20)));
  assert.equal(results.filter(result => result.allowed).length, 20);
  assert.ok(results.every(result => result.retryAfter >= 1 && result.retryAfter <= 60));
  assert.ok(await h.command(['TTL', `${h.config.prefix}:rate:concurrent`]) > 0);
});

test('a final fractional second never extends an existing rate-limit window', async () => {
  await h.store.rateLimit('window-edge', 60, 2);
  const key = `${h.config.prefix}:rate:window-edge`;
  // Keep expiry setup, observation and the exact production Lua in one Redis turn.
  const script = `redis.call('PEXPIRE', KEYS[1], 250)
local before = redis.call('TTL', KEYS[1])
local function limit() ${RATE_SCRIPT} end
local result = limit()
return {before, result[1], result[2], redis.call('PTTL', KEYS[1])}`;
  const [before, allowed, retry, remaining] = await h.rest.eval(script, [key], [60, 2]);
  assert.equal(before, 0); assert.equal(allowed, 1); assert.equal(retry, 0);
  assert.ok(remaining >= 0 && remaining <= 250, 'limiter must preserve the original expiry');
});

test('validate limits installations at 20/min and IP at 60/min using trusted Vercel header', async () => {
  const [license] = await h.store.generate(1, 30, ''), installation = randomUUID();
  for (let i = 0; i < 20; i++) assert.equal((await validate(license.key, installation)).status, 200);
  const response = await validate(license.key, installation); assert.equal(response.status, 429); assert.ok(Number(response.headers.get('retry-after')) > 0);
  assert.deepEqual(await response.json(), { valid: false, expiresAt: null });
  await h.reset();
  for (let i = 0; i < 60; i++) assert.equal((await validate(newLicenseKey(), randomUUID(), { 'x-forwarded-for': `192.0.2.${i}` })).status, 200);
  assert.equal((await validate(newLicenseKey())).status, 429);
});

test('secure server-side session cookie, admin permissions, same-origin CSRF and logout', async () => {
  const denied = await h.app(req('generate', { count: 1, days: 30 })); assert.equal(denied.status, 401);
  const auth = await login(), cookie = auth.response.headers.get('set-cookie');
  assert.ok(cookie.startsWith('__Host-socialbox-admin=')); for (const attr of ['Secure', 'HttpOnly', 'SameSite=Strict', 'Path=/', 'Max-Age=28800']) assert.ok(cookie.includes(attr));
  const token = auth.cookie.split('=')[1]; const stored = await h.command(['GET', `${h.config.prefix}:session:${sha256(token)}`]); assert.ok(!stored.includes(token));
  const session = await h.app(adminReq('session', undefined, auth)); assert.equal((await session.json()).csrfToken, auth.csrf);
  for (const headers of [{ 'x-csrf-token': '' }, { Origin: 'https://evil.example' }, { 'Sec-Fetch-Site': 'cross-site' }]) assert.equal((await h.app(adminReq('generate', { count: 1, days: 30 }, auth, headers))).status, 403);
  const created = await h.app(adminReq('generate', { count: 2, days: 30, note: 'Customer' }, auth)); assert.equal(created.status, 201); const generated = (await created.json()).licenses;
  const listed = await h.app(adminReq('licenses', undefined, auth)); const list = await listed.json(); assert.equal(list.licenses.length, 2); assert.ok(!JSON.stringify(list).includes(generated[0].key));
  assert.equal((await h.app(adminReq('note', { id: generated[0].id, note: 'Updated' }, auth))).status, 200);
  assert.equal((await h.app(adminReq('revoke', { id: generated[0].id }, auth))).status, 200);
  assert.equal((await h.app(adminReq('logout', {}, auth))).status, 200);
  assert.equal((await h.app(adminReq('licenses', undefined, auth))).status, 401);
});

test('login is origin-protected, uses generic errors and fails closed under brute force', async () => {
  assert.equal((await h.app(req('login', { email: h.config.adminEmail, password: 'correct-horse-socialbox-admin' }, { headers: { Origin: 'https://evil.example' } }))).status, 403);
  let previous;
  for (let i = 0; i < 8; i++) { const response = await h.app(req('login', { email: i % 2 ? 'other@example.com' : h.config.adminEmail, password: 'bad' })); assert.equal(response.status, 401); const body = await response.text(); if (previous) assert.equal(body, previous); previous = body; }
  assert.equal((await h.app(req('login', { email: h.config.adminEmail, password: 'correct-horse-socialbox-admin' }))).status, 429);
});

test('bad inputs cannot generate or modify licenses; request bodies are bounded and JSON-only', async () => {
  const auth = await login();
  for (const body of [{ count: 101, days: 30 }, { count: 0, days: 30 }, { count: 1, days: 0 }, { count: 1, days: 3651 }, { count: 1, days: 1.5 }, { count: '1', days: 30 }, { count: 1, days: 30, note: 'x'.repeat(241) }]) assert.equal((await h.app(adminReq('generate', body, auth))).status, 400);
  assert.equal((await h.store.list()).total, 0);
  assert.equal((await h.app(adminReq('revoke', { id: '../../oops' }, auth))).status, 400);
  assert.equal((await h.app(adminReq('note', { id: 'a'.repeat(64), note: '' }, auth))).status, 404);
  assert.equal((await h.app(req('validate', '{', { headers: { 'x-socialbox-client-key': h.config.clientKey } }))).status, 400);
  assert.equal((await h.app(req('validate', {}, { headers: { 'Content-Type': 'text/plain', 'x-socialbox-client-key': h.config.clientKey } }))).status, 415);
  assert.equal((await h.app(req('validate', 'x'.repeat(17000), { headers: { 'x-socialbox-client-key': h.config.clientKey } }))).status, 413);
  assert.equal((await h.app(req('validate', undefined))).status, 405);
});

test('database/REST failure returns 503, no successful proof, no credentials or upstream exception', async () => {
  const [license] = await h.store.generate(1, 30, ''); h.state.fail = true;
  const response = await validate(license.key); assert.equal(response.status, 503); assert.equal(response.headers.get('retry-after'), '30');
  assert.deepEqual(await response.json(), { valid: false, expiresAt: null }); assert.equal(response.headers.get('x-socialbox-license-proof'), null);
  const admin = await h.app(req('login', { email: h.config.adminEmail, password: 'correct-horse-socialbox-admin' })); const output = await admin.text();
  for (const secret of [h.config.redisToken, license.key, 'correct-horse-socialbox-admin', h.env.SOCIALBOX_PROOF_PRIVATE_KEY_PEM]) assert.ok(!output.includes(secret));
  for (const fake of [async () => { throw new Error('secret upstream'); }, async () => new Response('{"error":"secret upstream"}'), async () => new Response('invalid')]) {
    const adapter = new RedisRest(h.config, fake); await assert.rejects(adapter.command('GET', 'a'), { message: 'License storage unavailable' });
  }
});

test('configuration fails closed for missing credentials, insecure origins, wrong curves and namespace', () => {
  assert.ok(loadConfig(h.env));
  for (const field of ['UPSTASH_REDIS_REST_TOKEN', 'SOCIALBOX_ADMIN_PASSWORD_SCRYPT', 'SOCIALBOX_PROOF_PRIVATE_KEY_PEM']) assert.throws(() => loadConfig({ ...h.env, [field]: '' }));
  assert.throws(() => loadConfig({ ...h.env, SOCIALBOX_ADMIN_ORIGIN: 'http://example.com' }));
  assert.throws(() => loadConfig({ ...h.env, UPSTASH_REDIS_REST_URL: 'http://example.com' }));
  assert.throws(() => loadConfig({ ...h.env, SOCIALBOX_REDIS_PREFIX: 'bad namespace' }));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'secp384r1' });
  assert.throws(() => loadConfig({ ...h.env, SOCIALBOX_PROOF_PRIVATE_KEY_PEM: privateKey.export({ type: 'pkcs8', format: 'pem' }) }));
});

test('Vercel rewrite endpoint routes to the same authenticated handler', async () => {
  const response = await h.app(new Request('https://license.example.com/api/index?endpoint=session'));
  assert.deepEqual(await response.json(), { authenticated: false });
});
