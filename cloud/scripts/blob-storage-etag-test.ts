/** Real Blob SDK, intercepted transport; synthetic records and no live network. */
import assert from "node:assert/strict";
import { MockAgent, getGlobalDispatcher, setGlobalDispatcher } from "undici";
import { getStorage, resetStorageAdapterForTests } from "../src/lib/storage";

async function main() {
  const original = getGlobalDispatcher(), mock = new MockAgent();
  mock.disableNetConnect(); setGlobalDispatcher(mock);
  const previousToken = process.env.BLOB_READ_WRITE_TOKEN, previousAccess = process.env.BLOB_ACCESS;
  process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_fixture_synthetic";
  process.env.BLOB_ACCESS = "private";
  resetStorageAdapterForTests();
  const state = { id: "auth-state", formatVersion: 1, users: [], devices: [], licenses: [], "pairing-codes": [],
    deviceLicensing: { version: 1, migratedAt: "2026-01-01T00:00:00.000Z", adminDevices: [], rates: [], events: [] } };
  const body = JSON.stringify({ version: 1, items: [state] });
  const pool = mock.get("https://fixture.private.blob.vercel-storage.com");
  const headers = (value: unknown) => new Headers(value as HeadersInit);
  try {
    pool.intercept({ path: "/collections/auth-state.json?cache=0", method: "GET" }).reply((options) => {
      const identity = headers(options.headers).get("accept-encoding") === "identity";
      return { statusCode: 200, data: body, responseOptions: { headers: {
        "content-type": "application/json", etag: identity ? '"fixture-version-1"' : 'W/"fixture-version-1"',
      } } };
    });
    assert.deepEqual(await getStorage().readAuthState(), state);
    pool.intercept({ path: "/collections/auth-state.json?cache=0", method: "GET" }).reply(200, body,
      { headers: { "content-type": "application/json", etag: 'W/"unexpected-transform"' } });
    await assert.rejects(getStorage().readAuthState(), /requires a strong ETag/);
    mock.assertNoPendingInterceptors();
    console.log("Blob storage checks passed: uncompressed strong validator; unexpected weak validator fails closed.");
  } finally {
    resetStorageAdapterForTests();
    if (previousToken === undefined) delete process.env.BLOB_READ_WRITE_TOKEN; else process.env.BLOB_READ_WRITE_TOKEN = previousToken;
    if (previousAccess === undefined) delete process.env.BLOB_ACCESS; else process.env.BLOB_ACCESS = previousAccess;
    setGlobalDispatcher(original); await mock.close();
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
