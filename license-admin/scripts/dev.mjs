import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import handler from '../api/index.mjs';
import { loadConfig } from '../lib/config.mjs';

const config = loadConfig(), origin = new URL(config.origin);
if (!['127.0.0.1', 'localhost'].includes(origin.hostname) || origin.protocol !== 'http:') throw new Error('For local dev set SOCIALBOX_ADMIN_ORIGIN=http://localhost:3000');
const types = { '/': ['index.html', 'text/html'], '/app.js': ['app.js', 'text/javascript'], '/style.css': ['style.css', 'text/css'], '/favicon.svg': ['favicon.svg', 'image/svg+xml'] };
const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, origin);
    if (url.pathname.startsWith('/api/')) {
      const chunks = []; let bytes = 0;
      for await (const chunk of req) { bytes += chunk.length; if (bytes > 16384) { res.writeHead(413); res.end(); return; } chunks.push(chunk); }
      const body = Buffer.concat(chunks);
      const request = new Request(url, { method: req.method, headers: req.headers, ...(body.length ? { body } : {}) });
      const response = await handler.fetch(request);
      res.writeHead(response.status, Object.fromEntries(response.headers)); res.end(Buffer.from(await response.arrayBuffer()));
      return;
    }
    const file = types[url.pathname];
    if (!file || req.method !== 'GET') { res.writeHead(404); res.end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': `${file[1]}; charset=utf-8`, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'" });
    res.end(await readFile(resolve('public', file[0])));
  } catch { res.writeHead(500); res.end('Local server error'); }
});
server.listen(Number(origin.port) || 3000, '127.0.0.1', () => console.log(`License admin listening at ${config.origin}`));
