import { generateKeyPairSync } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { parseArgs } from 'node:util';
import { passwordHash, randomToken, x963PublicKey } from '../lib/crypto.mjs';
const { values } = parseArgs({ options: { email: { type: 'string' }, origin: { type: 'string' } } });
if (!values.email || !values.origin) {
  console.error('Usage: npm run setup -- --email you@example.com --origin https://YOUR-PRODUCTION-DOMAIN'); process.exit(1);
}
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(values.email)) throw new Error('Enter a valid email');
const origin = new URL(values.origin);
if (origin.origin !== values.origin || (origin.protocol !== 'https:' && !(origin.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(origin.hostname)))) throw new Error('Enter an exact HTTPS origin (or localhost HTTP for dev)');
const password = randomToken(), clientKey = randomToken(), { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const keyId = `socialbox-${new Date().toISOString().slice(0, 10)}`;
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
const env = {
  UPSTASH_REDIS_REST_URL: '', UPSTASH_REDIS_REST_TOKEN: '', SOCIALBOX_ADMIN_EMAIL: values.email,
  SOCIALBOX_ADMIN_PASSWORD_SCRYPT: passwordHash(password), SOCIALBOX_ADMIN_ORIGIN: values.origin,
  SOCIALBOX_CLIENT_KEY_CURRENT: clientKey, SOCIALBOX_CLIENT_KEY_PREVIOUS: '',
  SOCIALBOX_PROOF_PRIVATE_KEY_PEM: pem.replaceAll('\n', '\\n'), SOCIALBOX_PROOF_KEY_ID: keyId,
  SOCIALBOX_REDIS_PREFIX: 'socialbox:production'
};
const text = '# Local secret file. Never commit or upload to a public repository.\n' + Object.entries(env).map(([key, value]) => `${key}='${value}'`).join('\n') + '\n';
try { await writeFile('.env.local', text, { flag: 'wx', mode: 0o600 }); }
catch (error) { if (error.code === 'EEXIST') { console.error('.env.local already exists. Preserve its signing key; setup will not overwrite it.'); process.exit(1); } throw error; }
console.log('Created .env.local (mode 600). Add permanent Upstash REST URL/token before starting.');
console.log(`Admin email: ${values.email}\nAdmin password (save now in a password manager): ${password}`);
console.log(`iOS validate URL: ${values.origin}/api/validate\niOS client header value: ${clientKey}\niOS proof key ID: ${keyId}\niOS X9.63 public key base64: ${x963PublicKey(privateKey)}`);
