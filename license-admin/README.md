# SocialBox license administration

A standalone Vercel application with one private administrator, a public activation API, and permanent Upstash Redis storage. It does not change or use the iOS manager's container, identity, keychain, proxy, or legacy cloud data. All license records are scoped under `SOCIALBOX_REDIS_PREFIX`.

## Deployment

1. Create **your own permanent Upstash Redis database** in the [Upstash console](https://console.upstash.com/) or [Vercel Upstash Marketplace](https://vercel.com/marketplace/upstash/upstash-kv). Choose a region near the Vercel function. Keep **eviction disabled**, use the primary REST endpoint and full-access REST token, and retain database backups. License records have no TTL; sessions and rate counters expire automatically. Upstash persistence is always enabled ([durable storage](https://upstash.com/docs/redis/features/durability)). A free plan can be used within its current limits; review its quota and inactivity/archival policy before launch. A temporary `start-redis` database is unsuitable for production.
2. Put this directory in its own Git repository, or set the existing repository's Vercel **Root Directory** to `license-admin`. Framework preset: **Other**; Node.js: **22.x**. The committed `vercel.json` configures the build, static assets and API rewrite. Never publish `.env.local`, private PEMs, downloaded license files, or `work/`. The parent repository's unrelated Vercel configuration is not used when this directory is the project root.
3. With Node.js 22 installed, run `npm run setup -- --email your@email.com --origin https://YOUR-PRODUCTION-DOMAIN`. This writes a new `.env.local` with mode `600`, a scrypt password hash, a 256-bit client header, and a P-256 signing key. It prints the generated admin password **once** plus the iOS public configuration. Save the password in a password manager. It refuses to overwrite an existing file, preserving already-issued proof signatures. Generating a new signing key invalidates previously issued offline proofs unless the iOS app trusts both keys.
4. Fill in the two Upstash values in `.env.local`. Run `npm run check:env`. Copy each variable into Vercel **Settings → Environment Variables → Production**. For `SOCIALBOX_PROOF_PRIVATE_KEY_PEM`, paste the PEM text with literal `\n` separators, or real newlines; both are accepted. Do not paste the surrounding shell quotes. Put secrets in sensitive environment variables. Set the exact production origin before deployment. Use a separate database namespace and credentials for preview deployments, or leave preview API access unconfigured.
5. Import/deploy the repository through Vercel, or run `vercel --prod` from this directory after signing in to the Vercel CLI. If the final hostname differs, update `SOCIALBOX_ADMIN_ORIGIN` and redeploy. Keep the production validation endpoint reachable by native apps: Vercel Deployment Protection must not require a Vercel login for the public API. The admin API has its own authentication; do not enable wildcard CORS.
6. Open the production site, sign in with the configured email and generated password, and create one **30 days**, quantity **1** license. Copy or download it immediately. The full key is shown only in the generation response and page memory; the database retains its hash and masked preview. Duration begins on the first successful activation, not creation. Keep the raw key out of logs and screenshots.
7. Put only the production `/api/validate` URL, current client header, proof key ID and X9.63 public key into a JSON file with exact keys `ValidateURL`, `ClientKey`, `SigningKeyID`, `PublicKeyX963`. From the repository root, run `node tools/SBLicense/write-configuration.mjs --input /path/to/public-license-configuration.json --output lucid/Manager/Resources/LicenseConfiguration.plist`. The writer validates HTTPS and the real P-256 point, rejects extra fields, and atomically writes only these four public values. Include that resource in the iOS app bundle. The private signing key, password hash, and Redis token stay server-side. Perform one activation from the app and confirm the same row shows first activation and last check-in.

No hosting or database account is created by the source, setup script or test suite. Deployment and permanent database provisioning require the owner's connected accounts.

## Exact environment variables

| Variable | Meaning |
| --- | --- |
| `UPSTASH_REDIS_REST_URL` | HTTPS primary REST endpoint, without credentials or query parameters. |
| `UPSTASH_REDIS_REST_TOKEN` | Full-access Upstash REST token. Never ship in iOS or JavaScript assets. |
| `SOCIALBOX_ADMIN_EMAIL` | Single administrator email; compared case-insensitively. |
| `SOCIALBOX_ADMIN_PASSWORD_SCRYPT` | `scrypt$<32 hex salt>$<128 hex digest>` from setup. Parameters are N=16384, r=8, p=1, 64-byte output. |
| `SOCIALBOX_ADMIN_ORIGIN` | Exact HTTPS origin, e.g. `https://licenses.example.com`, with no trailing slash or path. Local dev permits `http://localhost:3000` only outside Vercel. |
| `SOCIALBOX_CLIENT_KEY_CURRENT` | Random 32+ character base64url shared iOS client header. This is a rotatable abuse barrier, not administrator authorization. |
| `SOCIALBOX_CLIENT_KEY_PREVIOUS` | Optional previous client header during rollout. Remove after supported apps migrate. |
| `SOCIALBOX_PROOF_PRIVATE_KEY_PEM` | P-256 / prime256v1 PKCS#8 private PEM, generated once and backed up securely. |
| `SOCIALBOX_PROOF_KEY_ID` | Public identifier for the signing key; must match the iOS trusted-key entry. |
| `SOCIALBOX_REDIS_PREFIX` | Optional namespace; default `socialbox:production`. Never change it accidentally or production licenses will appear missing. |

Vercel supplies `VERCEL=1`; the API then uses only Vercel's trusted `x-vercel-forwarded-for` header for its IP limiter. Local dev uses a loopback rate bucket. No other `X-Forwarded-For` value is trusted.

To change the password without changing signing keys, generate a new scrypt hash using `passwordHash` from `lib/crypto.mjs` in a local Node script or REPL. Update `SOCIALBOX_ADMIN_PASSWORD_SCRYPT`, redeploy, and invalidate existing sessions by deleting only `<prefix>:session:*` keys in the Upstash console. Do not run `FLUSHDB` against production. To immediately terminate a leaked admin session, delete its session key; all sessions expire after eight hours regardless of activity.

## HTTP contract

All API responses use `Cache-Control: no-store`. License values and upstream errors are never logged by the application. Never configure request-body or sensitive-header capture in external logging. Browser assets have no environment secrets.

### Public activation and revalidation

`POST /api/validate`, `Content-Type: application/json`, header `X-SocialBox-Client-Key: <current-or-previous>`:

```json
{"key":"SBX-<eight groups of eight random hexadecimal characters>","installationId":"random-persisted-UUID"}
```

The key is trimmed and uppercased; UUID is trimmed and lowercased before hashing. The UUID is an app-generated random identifier retained in the app's private keychain, never a physical identifier. License keys have 256 random bits. A Redis Lua script uses Redis `TIME` and atomically binds a key to the first installation hash, sets activation and expiry, checks revocation and records successful check-ins. A repeated check from the same installation cannot extend duration. A different installation is rejected; deleting or recreating the installation identifier does not reset the binding.

Success (HTTP 200):

```json
{"valid":true,"expiresAt":"2026-11-15T12:00:00.000Z"}
```

Unknown, revoked, expired or bound elsewhere (HTTP 200):

```json
{"valid":false,"expiresAt":null}
```

The public body always contains only `valid` and `expiresAt`, including error responses. Malformed key/UUID/JSON returns 400; wrong/missing shared header returns 401; oversized bodies return 413; non-JSON returns 415; wrong method returns 405. These are definitive client/gate errors. The database limiter is 60 requests per IP per rolling-start fixed 60-second window and 20 per installation per 60-second window, including failed license checks. Rejected requests return 429 with `Retry-After`; database/timeout/signing/configuration errors return 503 with `Retry-After: 30`. The API fails closed when its limiter or database is unavailable and never manufactures a valid result.

A successful response also contains `X-SocialBox-License-Proof`:

```text
base64url(original UTF-8 JSON claim bytes).base64url(DER ECDSA P-256 SHA-256 signature)
```

This is a **custom two-part signed envelope**, not a standard JWT. Verify the signature over the decoded JSON bytes exactly, using `SecKeyVerifySignature` and `kSecKeyAlgorithmECDSASignatureMessageX962SHA256` on iOS. The public key is the 65-byte uncompressed X9.63 representation (0x04 followed by X and Y), base64-encoded. The setup and environment-check scripts print it. Do not verify a reserialized JSON object. Signature encoding is ASN.1 DER, not JOSE's raw R||S.

Claims:

```json
{"v":1,"kid":"socialbox-2026-10-16","keySHA256":"64 lowercase hex characters","installSHA256":"64 lowercase hex characters","issuedAt":1792152000,"expiresAt":1794744000,"offlineUntil":1792411200}
```

Times are integer Unix seconds from Redis. `offlineUntil = min(expiresAt, issuedAt + 259200)`. The client must verify signature, version, known `kid`, both local hashes, sensible claim ordering and expiry. Store the raw key/proof only in the app's private keychain. Revalidate at every launch. HTTP 200 false or a definitive 4xx gates immediately and clears accepted proof. A transport failure, 429, or 5xx may use an already verified proof until `offlineUntil`; it may never activate a new installation offline or extend a proof. At expiry or after 72 hours without a successful online check, show the license gate. A successful online check renews the proof within the original license expiry. Keep clock rollback defenses client-side; a tampered/jailbroken device cannot be made perfectly trustworthy.

Revocation is immediate for online validation. An already offline installation can retain access until its previously signed grace expires, at most 72 hours and never beyond license expiry. The admin UI states this when revoking.

### Administrator

`POST /api/login` JSON `{email,password}` requires the exact Origin and returns a random eight-hour `Secure; HttpOnly; SameSite=Strict; Path=/` session cookie plus `{authenticated:true,csrfToken}`. Sessions are random 256-bit values, stored by hash in Redis. Login throttles at eight attempts per IP per 15 minutes plus 60 attempts globally per minute. Login errors do not reveal which credential was wrong. Password comparison uses scrypt; there is no third-party authentication service.

`GET /api/session` returns `{authenticated:false}` or `{authenticated:true,csrfToken}`. Admin mutation requests require both the session cookie, exact Origin, and `X-CSRF-Token` from the session. Admin mutations throttle at 60/minute per session. No API permits cross-origin browser access.

| Endpoint | Method and JSON | Result |
| --- | --- | --- |
| `/api/licenses?offset=0` | GET; admin cookie | 50 most recent rows, total and pagination. Status is unactivated/active/expired/revoked. Includes duration, note, masked preview, first activation, last successful check-in, expiry, creation, revocation. |
| `/api/generate` | POST `{count:1,days:30,note:"Launch"}` | 201 `{licenses:[...]}` with full keys shown once. Bulk 1–100; duration 1–3650 whole days. Atomic batch; no partial issuance. |
| `/api/revoke` | POST `{id:"64-character key hash from list"}` | `{ok:true}`; idempotent permanent revocation. |
| `/api/note` | POST `{id:"...",note:"Customer label"}` | `{ok:true}`; maximum 240 characters. |
| `/api/logout` | POST `{}` | Deletes server-side session and clears cookie. |

A network timeout after a mutation may mean it completed but the reply was lost. Refresh the list before retrying. If a generation reply is lost, revoke the newly created masked rows and issue a fresh batch; the plaintext cannot be recovered. Label batches to make this easy. Do not blindly retry bulk generation.

## Local verification

There are no runtime npm dependencies. With Node 22+:

```sh
npm run build
# Install Redis 7+ locally, or set REDIS_SERVER=/absolute/path/to/redis-server.
npm test
```

Tests spawn an isolated Redis process on a temporary Unix socket with persistence disabled and use an authenticated local HTTP bridge to exercise the real REST adapter and exact Lua scripts. They never connect to or flush a configured production database. The tests cover 64 concurrent activation contenders, revoke/expiry behavior, batch persistence, signed proof tampering and bindings, rate limit concurrency and IP spoofing, scrypt login, cookies/session invalidation, Origin and CSRF rejection, input bounds, secret-free failures and environment validation.

For manual development, generate local credentials with `npm run setup -- --email you@example.com --origin http://localhost:3000`, fill permanent development Upstash credentials and choose a **development** prefix, then run `npm run dev`. Use production HTTPS before shipping. `npm run check:env` checks local configuration and prints only the public iOS key configuration; it makes no database changes. `npm run build` intentionally validates syntax without requiring secrets, so build output can be safely inspected before deployment.

Implementation references: [Vercel Node runtime](https://vercel.com/docs/functions/runtimes/node-js), [trusted request headers](https://vercel.com/docs/headers/request-headers), [Upstash REST commands](https://upstash.com/docs/redis/features/restapi), [Lua EVAL](https://upstash.com/docs/redis/sdks/ts/commands/scripts/eval), [Upstash free-plan FAQ](https://upstash.com/docs/redis/help/faq). Database schema is the explicit hash/index layout in `lib/store.mjs`; no SQL migration or external auth setup is needed.
