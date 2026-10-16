import { parseSigningKey } from './crypto.mjs';

export function loadConfig(env = process.env) {
  const required = ['UPSTASH_REDIS_REST_URL', 'UPSTASH_REDIS_REST_TOKEN', 'SOCIALBOX_ADMIN_EMAIL', 'SOCIALBOX_ADMIN_PASSWORD_SCRYPT', 'SOCIALBOX_ADMIN_ORIGIN', 'SOCIALBOX_CLIENT_KEY_CURRENT', 'SOCIALBOX_PROOF_PRIVATE_KEY_PEM', 'SOCIALBOX_PROOF_KEY_ID'];
  for (const name of required) if (!env[name]) throw new Error(`Missing environment variable: ${name}`);
  const origin = new URL(env.SOCIALBOX_ADMIN_ORIGIN);
  const isLoopback = ['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname);
  if (origin.origin !== env.SOCIALBOX_ADMIN_ORIGIN || (origin.protocol !== 'https:' && !(isLoopback && env.VERCEL !== '1' && origin.protocol === 'http:'))) throw new Error('SOCIALBOX_ADMIN_ORIGIN must be an exact HTTPS origin');
  const redis = new URL(env.UPSTASH_REDIS_REST_URL);
  if (redis.protocol !== 'https:' && !(env.NODE_ENV === 'test' && redis.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(redis.hostname))) throw new Error('UPSTASH_REDIS_REST_URL must use HTTPS');
  if (redis.username || redis.password || redis.search || redis.hash || (redis.pathname !== '/' && redis.pathname !== '')) throw new Error('Invalid Redis REST URL');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(env.SOCIALBOX_ADMIN_EMAIL)) throw new Error('Invalid admin email');
  if (!/^scrypt\$[a-f0-9]{32}\$[a-f0-9]{128}$/.test(env.SOCIALBOX_ADMIN_PASSWORD_SCRYPT)) throw new Error('Invalid password hash; use setup script');
  for (const name of ['SOCIALBOX_CLIENT_KEY_CURRENT', 'SOCIALBOX_CLIENT_KEY_PREVIOUS']) if (env[name] && !/^[A-Za-z0-9_-]{32,128}$/.test(env[name])) throw new Error(`Invalid ${name}`);
  const prefix = env.SOCIALBOX_REDIS_PREFIX || 'socialbox:production';
  if (!/^[A-Za-z0-9:_-]{1,80}$/.test(prefix)) throw new Error('Invalid Redis namespace');
  if (!/^[A-Za-z0-9._-]{1,48}$/.test(env.SOCIALBOX_PROOF_KEY_ID)) throw new Error('Invalid signing key ID');
  return Object.freeze({
    redisUrl: redis.origin, redisToken: env.UPSTASH_REDIS_REST_TOKEN, prefix,
    adminEmail: env.SOCIALBOX_ADMIN_EMAIL.toLowerCase(), adminPasswordHash: env.SOCIALBOX_ADMIN_PASSWORD_SCRYPT,
    origin: origin.origin, secureCookie: origin.protocol === 'https:', cookieName: origin.protocol === 'https:' ? '__Host-socialbox-admin' : 'socialbox-admin-local',
    clientKey: env.SOCIALBOX_CLIENT_KEY_CURRENT, previousClientKey: env.SOCIALBOX_CLIENT_KEY_PREVIOUS || '',
    proofKeyId: env.SOCIALBOX_PROOF_KEY_ID, signingKey: parseSigningKey(env.SOCIALBOX_PROOF_PRIVATE_KEY_PEM), vercel: env.VERCEL === '1'
  });
}
