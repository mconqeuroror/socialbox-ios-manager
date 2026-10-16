import { isIP } from 'node:net';
import { canonicalInstallation, canonicalKey, checkPassword, createProof, equalSecret, sha256 } from './crypto.mjs';

class HttpError extends Error {
  constructor(status, message, headers = {}) { super(message); this.status = status; this.headers = headers; }
}
const invalid = { valid: false, expiresAt: null };
function json(body, status = 200, extra = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store, private', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', ...extra } });
}
function cookieValue(request, name) {
  const cookies = (request.headers.get('cookie') || '').split(';').map(value => value.trim());
  const found = cookies.filter(value => value.startsWith(`${name}=`));
  return found.length === 1 ? found[0].slice(name.length + 1) : null;
}
function sessionCookie(config, token, maxAge = 28800) {
  return `${config.cookieName}=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAge}${config.secureCookie ? '; Secure' : ''}`;
}
function originCheck(request, config) {
  if (request.headers.get('origin') !== config.origin || request.headers.get('sec-fetch-site') === 'cross-site') throw new HttpError(403, 'Request origin rejected');
}
function clientIP(request, config) {
  // Vercel overwrites this header. Never trust an arbitrary X-Forwarded-For.
  const value = config.vercel ? request.headers.get('x-vercel-forwarded-for') : '127.0.0.1';
  const ip = (value || '').split(',')[0].trim();
  return isIP(ip) ? ip : 'unknown';
}
async function bodyJSON(request) {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') throw new HttpError(415, 'Use application/json');
  if (Number(request.headers.get('content-length')) > 16384) throw new HttpError(413, 'Request too large');
  const reader = request.body?.getReader();
  if (!reader) throw new HttpError(400, 'JSON body required');
  let bytes = 0; const chunks = [];
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 16384) { await reader.cancel(); throw new HttpError(413, 'Request too large'); }
      chunks.push(Buffer.from(value));
    }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!body || Array.isArray(body) || typeof body !== 'object') throw new Error();
    return body;
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, 'Invalid JSON body');
  }
}
function noteValue(value) {
  if (value === undefined) return '';
  if (typeof value !== 'string' || value.length > 240 || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) throw new HttpError(400, 'Note must be at most 240 characters');
  return value.trim();
}
function requireID(value) {
  if (typeof value !== 'string' || !/^[a-f0-9]{64}$/.test(value)) throw new HttpError(400, 'Invalid license ID');
  return value;
}
function endpointFor(url) {
  // The explicit rewrite parameter works with Vercel's rewritten URL and local dev.
  const path = url.searchParams.get('endpoint') ?? url.pathname.replace(/^\/api\/?/, '');
  return path.replace(/^\/+|\/+$/g, '');
}
export function createApplication(config, store) {
  async function rate(bucket, seconds, limit) {
    const result = await store.rateLimit(bucket, seconds, limit);
    if (!result.allowed) throw new HttpError(429, 'Too many requests', { 'Retry-After': String(result.retryAfter) });
  }
  async function authenticate(request, mutate = false) {
    const token = cookieValue(request, config.cookieName);
    const session = await store.session(token);
    if (!session) throw new HttpError(401, 'Sign in required');
    if (mutate) {
      originCheck(request, config);
      if (!equalSecret(request.headers.get('x-csrf-token'), session.csrf)) throw new HttpError(403, 'Request verification failed');
      await rate(`admin:${sha256(token)}`, 60, 60);
    }
    return { token, session };
  }
  return async request => {
    const url = new URL(request.url), endpoint = endpointFor(url), isValidate = endpoint === 'validate';
    try {
      const method = request.method;
      const methods = { validate: 'POST', login: 'POST', session: 'GET', logout: 'POST', licenses: 'GET', generate: 'POST', revoke: 'POST', note: 'POST' };
      if (!Object.hasOwn(methods, endpoint)) throw new HttpError(404, 'Endpoint not found');
      if (method !== methods[endpoint]) throw new HttpError(405, 'Method not allowed', { Allow: methods[endpoint] });
      const ipHash = sha256(clientIP(request, config));
      if (isValidate) {
        await rate(`validate-ip:${ipHash}`, 60, 60);
        const supplied = request.headers.get('x-socialbox-client-key');
        if (!equalSecret(supplied, config.clientKey) && !(config.previousClientKey && equalSecret(supplied, config.previousClientKey))) throw new HttpError(401, 'Client authentication required');
        const body = await bodyJSON(request), key = canonicalKey(body.key), installationId = canonicalInstallation(body.installationId);
        if (!key || !installationId) throw new HttpError(400, 'Invalid activation request');
        const keyHash = sha256(key), installHash = sha256(installationId);
        await rate(`validate-install:${installHash}`, 60, 20);
        const result = await store.validate(keyHash, installHash);
        if (!result.valid) return json(invalid);
        const proof = createProof(config, keyHash, installHash, result.issuedAt, result.expiresAt);
        return json({ valid: true, expiresAt: new Date(result.expiresAt * 1000).toISOString() }, 200, { 'X-SocialBox-License-Proof': proof });
      }
      if (endpoint === 'login') {
        originCheck(request, config);
        await rate(`login-ip:${ipHash}`, 900, 8);
        await rate('login-global', 60, 60);
        const body = await bodyJSON(request);
        // Always perform the same expensive password calculation, even for an unknown email.
        const passwordOK = checkPassword(typeof body.password === 'string' ? body.password : '', config.adminPasswordHash);
        const emailOK = equalSecret(typeof body.email === 'string' ? body.email.trim().toLowerCase() : '', config.adminEmail);
        if (!emailOK || !passwordOK) throw new HttpError(401, 'Email or password incorrect');
        const session = await store.createSession();
        const oldToken = cookieValue(request, config.cookieName);
        if (oldToken && /^[A-Za-z0-9_-]{43}$/.test(oldToken)) await store.deleteSession(oldToken);
        return json({ authenticated: true, csrfToken: session.csrf }, 200, { 'Set-Cookie': sessionCookie(config, session.token) });
      }
      if (endpoint === 'session') {
        const origin = request.headers.get('origin');
        if ((origin && origin !== config.origin) || request.headers.get('sec-fetch-site') === 'cross-site') throw new HttpError(403, 'Request origin rejected');
        const session = await store.session(cookieValue(request, config.cookieName));
        return json(session ? { authenticated: true, csrfToken: session.csrf } : { authenticated: false });
      }
      const auth = await authenticate(request, method !== 'GET');
      if (endpoint === 'logout') {
        await store.deleteSession(auth.token);
        return json({ ok: true }, 200, { 'Set-Cookie': sessionCookie(config, '', 0) });
      }
      if (endpoint === 'licenses') {
        const offset = Number(url.searchParams.get('offset') || 0);
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > 10000000) throw new HttpError(400, 'Invalid page');
        return json(await store.list(offset));
      }
      const body = await bodyJSON(request);
      if (endpoint === 'generate') {
        const { count = 1, days } = body;
        if (!Number.isInteger(count) || count < 1 || count > 100 || !Number.isInteger(days) || days < 1 || days > 3650) throw new HttpError(400, 'Choose 1–100 keys and 1–3650 days');
        return json({ licenses: await store.generate(count, days, noteValue(body.note)) }, 201);
      }
      if (endpoint === 'revoke') {
        const found = await store.revoke(requireID(body.id));
        if (!found) throw new HttpError(404, 'License not found');
        return json({ ok: true });
      }
      if (endpoint === 'note') {
        const found = await store.updateNote(requireID(body.id), noteValue(body.note));
        if (!found) throw new HttpError(404, 'License not found');
        return json({ ok: true });
      }
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 503;
      // Never include upstream errors, payloads, credentials, key values or stack traces.
      return json(isValidate ? invalid : { error: error instanceof HttpError ? error.message : 'Service temporarily unavailable. Refresh before retrying a change.' }, status, { ...(error instanceof HttpError ? error.headers : { 'Retry-After': '30' }) });
    }
  };
}
