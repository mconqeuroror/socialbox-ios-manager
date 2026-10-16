import { createHash, createPrivateKey, createPublicKey, randomBytes, scryptSync, sign, timingSafeEqual } from 'node:crypto';

export const sha256 = value => createHash('sha256').update(value).digest('hex');
export const randomToken = () => randomBytes(32).toString('base64url');
export const equalSecret = (a, b) => typeof a === 'string' && typeof b === 'string' && timingSafeEqual(Buffer.from(sha256(a), 'hex'), Buffer.from(sha256(b), 'hex'));
export function passwordHash(password, salt = randomBytes(16).toString('hex')) {
  return `scrypt$${salt}$${scryptSync(password, salt, 64, { N: 16384, r: 8, p: 1 }).toString('hex')}`;
}
export function checkPassword(password, encoded) {
  if (typeof password !== 'string' || password.length > 1024) return false;
  const [, salt, digest] = encoded.split('$');
  const actual = scryptSync(password, salt, 64, { N: 16384, r: 8, p: 1 }).toString('hex');
  return equalSecret(actual, digest);
}
export function parseSigningKey(pem) {
  const key = createPrivateKey(pem.replaceAll('\\n', '\n'));
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('Invalid signing key');
  return key;
}
export function x963PublicKey(privateKey) {
  const jwk = createPublicKey(privateKey).export({ format: 'jwk' });
  return Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]).toString('base64');
}
export function createProof(config, keySHA256, installSHA256, issuedAt, expiresAt) {
  const claims = { v: 1, kid: config.proofKeyId, keySHA256, installSHA256, issuedAt, expiresAt, offlineUntil: Math.min(expiresAt, issuedAt + 259200) };
  const payload = Buffer.from(JSON.stringify(claims));
  const signature = sign('sha256', payload, { key: config.signingKey, dsaEncoding: 'der' });
  return `${payload.toString('base64url')}.${signature.toString('base64url')}`;
}
export function newLicenseKey() {
  // 256 random bits; no serial number, customer data, or predictable component.
  return `SBX-${randomBytes(32).toString('hex').toUpperCase().match(/.{1,8}/g).join('-')}`;
}
export function canonicalKey(value) {
  if (typeof value !== 'string') return null;
  const canonical = value.trim().toUpperCase();
  return /^SBX-(?:[A-F0-9]{8}-){7}[A-F0-9]{8}$/.test(canonical) ? canonical : null;
}
export function canonicalInstallation(value) {
  if (typeof value !== 'string') return null;
  const canonical = value.trim().toLowerCase();
  return /^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(canonical) ? canonical : null;
}
