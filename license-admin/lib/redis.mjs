export class StorageError extends Error {
  constructor() { super('License storage unavailable'); this.name = 'StorageError'; }
}
export class RedisRest {
  constructor(config, fetcher = fetch) { this.config = config; this.fetcher = fetcher; }
  async request(path, body) {
    try {
      const response = await this.fetcher(this.config.redisUrl + path, { method: 'POST', headers: { Authorization: `Bearer ${this.config.redisToken}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(4000), redirect: 'error', cache: 'no-store' });
      if (!response.ok) throw new StorageError();
      const decoded = await response.json();
      if (Array.isArray(decoded)) {
        if (decoded.some(item => !item || Object.hasOwn(item, 'error') || !Object.hasOwn(item, 'result'))) throw new StorageError();
        return decoded.map(item => item.result);
      }
      if (!decoded || Object.hasOwn(decoded, 'error') || !Object.hasOwn(decoded, 'result')) throw new StorageError();
      return decoded.result;
    } catch { throw new StorageError(); }
  }
  command(...args) { return this.request('', args); }
  pipeline(commands) { return this.request('/pipeline', commands); }
  eval(script, keys, args = []) { return this.command('EVAL', script, keys.length, ...keys, ...args); }
}
