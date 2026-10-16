import { createConnection, createServer as netServer } from 'node:net';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { generateKeyPairSync } from 'node:crypto';
import { loadConfig } from '../lib/config.mjs';
import { passwordHash } from '../lib/crypto.mjs';
import { RedisRest } from '../lib/redis.mjs';
import { LicenseStore } from '../lib/store.mjs';
import { createApplication } from '../lib/app.mjs';

function parseReply(buffer, position = 0) {
  if (position >= buffer.length) return null;
  const end = buffer.indexOf('\r\n', position); if (end < 0) return null;
  const type = String.fromCharCode(buffer[position]), value = buffer.toString('utf8', position + 1, end);
  let next = end + 2;
  if (type === '+') return { value, next };
  if (type === '-') return { value: new Error(value), next };
  if (type === ':') return { value: Number(value), next };
  if (type === '$') {
    const size = Number(value); if (size < 0) return { value: null, next };
    if (buffer.length < next + size + 2) return null;
    return { value: buffer.toString('utf8', next, next + size), next: next + size + 2 };
  }
  if (type === '*') {
    const count = Number(value); if (count < 0) return { value: null, next };
    const result = [];
    for (let i = 0; i < count; i++) { const item = parseReply(buffer, next); if (!item) return null; result.push(item.value); next = item.next; }
    return { value: result, next };
  }
  throw new Error('Unexpected Redis response');
}
export function redisCommand(socketPath, args) {
  return new Promise((resolvePromise, reject) => {
    const socket = createConnection(socketPath); let buffer = Buffer.alloc(0);
    socket.setTimeout(5000, () => socket.destroy(new Error('Redis test timeout')));
    socket.on('error', reject);
    socket.on('connect', () => {
      const chunks = [Buffer.from(`*${args.length}\r\n`)];
      for (const arg of args) { const data = Buffer.from(String(arg)); chunks.push(Buffer.from(`$${data.length}\r\n`), data, Buffer.from('\r\n')); }
      socket.write(Buffer.concat(chunks));
    });
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]); const parsed = parseReply(buffer);
      if (parsed) { socket.end(); parsed.value instanceof Error ? reject(parsed.value) : resolvePromise(parsed.value); }
    });
  });
}
const delay = ms => new Promise(resolvePromise => setTimeout(resolvePromise, ms));
export async function startHarness() {
  const dir = await mkdtemp(join(tmpdir(), 'socialbox-licenses-')), socketPath = join(dir, 'redis.sock');
  const localRedis = resolve('work/redis-source/redis-7.4.2/src/redis-server');
  const binary = process.env.REDIS_SERVER || (existsSync(localRedis) ? localRedis : 'redis-server');
  const redis = spawn(binary, ['--port', '0', '--unixsocket', socketPath, '--save', '', '--appendonly', 'no', '--dir', dir], { stdio: 'ignore' });
  let spawnError; redis.on('error', error => { spawnError = error; });
  try {
    for (let i = 0; !existsSync(socketPath) && i < 100; i++) { if (spawnError) throw spawnError; await delay(20); }
    if (!existsSync(socketPath)) throw new Error('Redis did not start');
  } catch { redis.kill(); await rm(dir, { recursive: true, force: true }); throw new Error('Redis 7+ is required for atomic Lua integration tests. Install redis-server or set REDIS_SERVER=/absolute/path/to/redis-server.'); }
  const state = { fail: false, calls: 0, commands: [] };
  const server = createServer(async (req, res) => {
    state.calls++;
    if (state.fail) { res.writeHead(503); res.end('Unavailable'); return; }
    if (req.headers.authorization !== 'Bearer test-only-redis-token') { res.writeHead(401); res.end(); return; }
    try {
      const chunks = []; for await (const chunk of req) chunks.push(chunk);
      const data = JSON.parse(Buffer.concat(chunks));
      const execute = async args => { state.commands.push(args[0]); try { return { result: await redisCommand(socketPath, args) }; } catch (error) { return { error: error.message }; } };
      const result = req.url === '/pipeline' ? await Promise.all(data.map(execute)) : await execute(data);
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(result));
    } catch { res.writeHead(400); res.end('{}'); }
  });
  await new Promise(resolvePromise => server.listen(0, '127.0.0.1', resolvePromise));
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const env = {
    NODE_ENV: 'test', VERCEL: '1',
    UPSTASH_REDIS_REST_URL: `http://127.0.0.1:${server.address().port}`, UPSTASH_REDIS_REST_TOKEN: 'test-only-redis-token',
    SOCIALBOX_ADMIN_EMAIL: 'owner@example.com', SOCIALBOX_ADMIN_PASSWORD_SCRYPT: passwordHash('correct-horse-socialbox-admin'),
    SOCIALBOX_ADMIN_ORIGIN: 'https://license.example.com', SOCIALBOX_CLIENT_KEY_CURRENT: 'C'.repeat(43), SOCIALBOX_CLIENT_KEY_PREVIOUS: 'P'.repeat(43),
    SOCIALBOX_PROOF_PRIVATE_KEY_PEM: privateKey.export({ type: 'pkcs8', format: 'pem' }), SOCIALBOX_PROOF_KEY_ID: 'test-key', SOCIALBOX_REDIS_PREFIX: 'socialbox:test'
  };
  const config = loadConfig(env), rest = new RedisRest(config), store = new LicenseStore(rest, config), app = createApplication(config, store);
  return { config, env, rest, store, app, state, socketPath, command: args => redisCommand(socketPath, args),
    reset: async () => { state.fail = false; state.calls = 0; state.commands = []; await redisCommand(socketPath, ['FLUSHDB']); },
    close: async () => { await new Promise(resolvePromise => server.close(resolvePromise)); redis.kill('SIGTERM'); await new Promise(resolvePromise => redis.once('exit', resolvePromise)); await rm(dir, { recursive: true, force: true }); }
  };
}
