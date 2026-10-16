import { newLicenseKey, randomToken, sha256 } from './crypto.mjs';

export const RATE_SCRIPT = `
local count = redis.call('INCR', KEYS[1])
if count == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end
local ttl = redis.call('TTL', KEYS[1])
if ttl < 0 then redis.call('EXPIRE', KEYS[1], ARGV[1]); ttl = tonumber(ARGV[1]) end
return {count <= tonumber(ARGV[2]) and 1 or 0, ttl}
`;
export const GENERATE_SCRIPT = `
local now = tonumber(redis.call('TIME')[1])
for i = 2, #KEYS do
 if redis.call('EXISTS', KEYS[i]) == 1 then return 0 end
end
for i = 2, #KEYS do
 local offset = (i - 2) * 2
 redis.call('HSET', KEYS[i], 'id', ARGV[offset+1], 'maskedKey', ARGV[offset+2], 'days', ARGV[#ARGV-1], 'note', ARGV[#ARGV], 'createdAt', now, 'activatedAt', 0, 'expiresAt', 0, 'lastCheckIn', 0, 'revokedAt', 0)
 redis.call('ZADD', KEYS[1], now, ARGV[offset+1])
end
return now
`;
export const VALIDATE_SCRIPT = `
local now = tonumber(redis.call('TIME')[1])
if redis.call('EXISTS', KEYS[1]) == 0 then return {0, 0, now} end
if tonumber(redis.call('HGET', KEYS[1], 'revokedAt') or '0') > 0 then return {0, 0, now} end
local binding = redis.call('HGET', KEYS[1], 'installationHash')
if binding and binding ~= ARGV[1] then return {0, 0, now} end
local expires = tonumber(redis.call('HGET', KEYS[1], 'expiresAt') or '0')
if binding and expires <= now then return {0, 0, now} end
if not binding then
 local days = tonumber(redis.call('HGET', KEYS[1], 'days'))
 if not days or days < 1 or days > 3650 then return {0, 0, now} end
 expires = now + days * 86400
 redis.call('HSET', KEYS[1], 'installationHash', ARGV[1], 'activatedAt', now, 'expiresAt', expires)
end
redis.call('HSET', KEYS[1], 'lastCheckIn', now)
return {1, expires, now}
`;
export const REVOKE_SCRIPT = `
if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
local now = tonumber(redis.call('TIME')[1])
if tonumber(redis.call('HGET', KEYS[1], 'revokedAt') or '0') == 0 then redis.call('HSET', KEYS[1], 'revokedAt', now) end
return 1
`;
export const NOTE_SCRIPT = `
if redis.call('EXISTS', KEYS[1]) == 0 then return 0 end
redis.call('HSET', KEYS[1], 'note', ARGV[1])
return 1
`;

export class LicenseStore {
  constructor(redis, config) { this.redis = redis; this.prefix = config.prefix; }
  key(id) { return `${this.prefix}:license:${id}`; }
  async rateLimit(bucket, seconds, limit) {
    const [allowed, retryAfter] = await this.redis.eval(RATE_SCRIPT, [`${this.prefix}:rate:${bucket}`], [seconds, limit]);
    return { allowed: allowed === 1, retryAfter: Math.max(1, Number(retryAfter)) };
  }
  async generate(count, days, note) {
    const keys = Array.from({ length: count }, () => newLicenseKey());
    const records = keys.map(key => ({ id: sha256(key), key, maskedKey: `${key.slice(0, 12)}…${key.slice(-4)}` }));
    const now = await this.redis.eval(GENERATE_SCRIPT, [`${this.prefix}:licenses`, ...records.map(item => this.key(item.id))], [...records.flatMap(item => [item.id, item.maskedKey]), days, note]);
    if (!now) throw new Error('Key collision');
    return records.map(item => ({ ...item, days, note, createdAt: new Date(now * 1000).toISOString() }));
  }
  async validate(keyHash, installationHash) {
    const [valid, expiresAt, issuedAt] = await this.redis.eval(VALIDATE_SCRIPT, [this.key(keyHash)], [installationHash]);
    return { valid: valid === 1, expiresAt: Number(expiresAt), issuedAt: Number(issuedAt) };
  }
  async list(offset = 0, limit = 50) {
    const [ids, total, time] = await this.redis.pipeline([['ZREVRANGE', `${this.prefix}:licenses`, offset, offset + limit - 1], ['ZCARD', `${this.prefix}:licenses`], ['TIME']]);
    const now = Number(time[0]);
    const rows = ids.length ? await this.redis.pipeline(ids.map(id => ['HGETALL', this.key(id)])) : [];
    const iso = value => Number(value) ? new Date(Number(value) * 1000).toISOString() : null;
    return { total, offset, limit, licenses: rows.filter(row => row.length).map(row => {
      const data = Object.fromEntries(Array.from({ length: row.length / 2 }, (_, i) => [row[i * 2], row[i * 2 + 1]]));
      return { id: data.id, maskedKey: data.maskedKey, note: data.note, days: Number(data.days), status: Number(data.revokedAt) ? 'revoked' : !Number(data.activatedAt) ? 'unactivated' : Number(data.expiresAt) <= now ? 'expired' : 'active', createdAt: iso(data.createdAt), activatedAt: iso(data.activatedAt), expiresAt: iso(data.expiresAt), lastCheckIn: iso(data.lastCheckIn), revokedAt: iso(data.revokedAt) };
    }) };
  }
  async revoke(id) { return (await this.redis.eval(REVOKE_SCRIPT, [this.key(id)])) === 1; }
  async updateNote(id, note) { return (await this.redis.eval(NOTE_SCRIPT, [this.key(id)], [note])) === 1; }
  async createSession() {
    const token = randomToken(), csrf = randomToken();
    await this.redis.command('SET', `${this.prefix}:session:${sha256(token)}`, JSON.stringify({ csrf }), 'EX', 28800);
    return { token, csrf };
  }
  async session(token) {
    if (typeof token !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(token)) return null;
    const value = await this.redis.command('GET', `${this.prefix}:session:${sha256(token)}`);
    if (!value) return null;
    try { const data = JSON.parse(value); return /^[A-Za-z0-9_-]{43}$/.test(data.csrf) ? data : null; } catch { return null; }
  }
  async deleteSession(token) { await this.redis.command('DEL', `${this.prefix}:session:${sha256(token)}`); }
}
