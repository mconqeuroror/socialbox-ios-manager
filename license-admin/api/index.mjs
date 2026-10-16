import { createApplication } from '../lib/app.mjs';
import { loadConfig } from '../lib/config.mjs';
import { RedisRest } from '../lib/redis.mjs';
import { LicenseStore } from '../lib/store.mjs';

let app;
export default {
  async fetch(request) {
    try {
      if (!app) {
        const config = loadConfig();
        app = createApplication(config, new LicenseStore(new RedisRest(config), config));
      }
      return await app(request);
    } catch {
      const url = new URL(request.url);
      const isValidate = url.pathname.endsWith('/validate') || url.searchParams.get('endpoint') === 'validate';
      return Response.json(isValidate ? { valid: false, expiresAt: null } : { error: 'Service temporarily unavailable' }, { status: 503, headers: { 'Cache-Control': 'no-store', 'Retry-After': '30' } });
    }
  }
};
