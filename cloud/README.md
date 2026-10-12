# Jew Automations Cloud

Web console + API for **RedditBox**. Operators log in here, activate a license
key, pair iPhones, and manage encrypted container backups. The server is
**zero-knowledge**: it never sees plaintext container labels, Reddit usernames,
or backup passphrases — backups are AES-256-GCM encrypted on-device.

Landing page brand: **Jew Automations**. App launcher lists **Reddit** first
(and only). Admin issues access keys at `/admin`.

## Contents

- [Quick start](#quick-start)
- [Production](#production)
- [Deploy to Vercel](#deploy-to-vercel)
- [Storage / Blob](#storage--blob)
- [Selling: the license flow](#selling-the-license-flow)
- [API reference](#api-reference)
- [Crypto contract](#crypto-contract)
- [Security notes](#security-notes)

## Quick start

Requires Node.js 18.17+.

```bash
cd cloud
npm install
cp .env.example .env   # then edit values (at minimum AUTH_SECRET)
npm run dev            # http://localhost:3000
```

The admin account is created lazily on the first login attempt using
`ADMIN_USERNAME` / `ADMIN_PASSWORD` from `.env` (you can also run
`npm run seed` explicitly). Log in as username `typekpaco` (or whatever
`ADMIN_USERNAME` is). Internally it is stored as `username@redditbox.local`
unless `ADMIN_EMAIL` is set.

Development data lives in `cloud/.data/` (gitignored): JSON collections
(`users.json`, `devices.json`, `licenses.json`, `backups.json`,
`pairing-codes.json`, `license-audit.json`) and blob bytes as `backup-<id>.bin`
files.

Checks:

```bash
npx tsc --noEmit
npm test               # auth + license grant/revoke/validate unit tests
npm run build
npm start
npm run smoke          # needs the server running; set ADMIN_USERNAME + ADMIN_PASSWORD for admin cycle
```

## Production

**https://redditspoof.vercel.app**

GitHub: https://github.com/typekpaco2002/redditspoof (master). Root Directory
on Vercel must stay `cloud`.

Set `APP_URL=https://redditspoof.vercel.app` in the Vercel project env.

## Deploy to Vercel

1. From `cloud/`: `npx vercel login` then `npx vercel --prod --yes`.
   Or import the repo in the Vercel dashboard and set **Root Directory** to `cloud`.
2. Add environment variables (Vercel dashboard or `npx vercel env add`):

   | Variable | Required | Notes |
   |---|---|---|
   | `ADMIN_USERNAME` | yes | Admin login handle, e.g. `typekpaco` |
   | `ADMIN_PASSWORD` | yes | Set in the dashboard; do not commit |
   | `ADMIN_EMAIL` | no | Defaults to `<username>@redditbox.local` |
   | `AUTH_SECRET` | yes | Long random string (`node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`) |
   | `JWT_SECRET` | no | Alias for `AUTH_SECRET` |
   | `APP_URL` | yes in prod | `https://redditspoof.vercel.app` |
   | `BLOB_READ_WRITE_TOKEN` | yes in prod | Set automatically when a Blob store is attached |
   | `BLOB_ACCESS` | no | Default is private. Set `public` only for a legacy public store |

3. **Storage:** Vercel → **Storage** → create a **Blob** store with access
   **Private**, attach it to the project. Without Blob, serverless instances
   use an ephemeral local disk and data is lost between invocations.

4. Deploy. Log in as `typekpaco` + `ADMIN_PASSWORD`, open `/admin`, create keys.

## Storage / Blob

Collections (users, licenses, pairing codes, backups metadata, audit) and
backup bytes are **server-only**. API routes never return Vercel Blob URLs to
browsers. Reads go through the authenticated SDK (`get()`), not public CDN
links.

- Prefer a **private** Blob store so objects are not fetchable by URL.
- A store’s public/private mode is fixed at creation. If production is still
  on a public store, the adapter falls back to `access: "public"` so the app
  keeps working, but anyone who can guess a pathname can read that JSON until
  you create a private store and migrate.
- **Read-modify-write:** `mutateCollection` takes a short-lived lock object,
  then writes with `ifMatch` (ETag). Concurrent updates retry instead of
  silently clobbering.
- New documents use exclusive creation; existing documents use conditional
  replacement. Authentication records share one transaction document, including
  device-license activation slots, rate limits and lifecycle history.

## Selling: the license flow

1. **You (admin)** log in at `/admin` as `typekpaco` / `ADMIN_PASSWORD`.
   Enter how many keys (1–100), optionally **Expires in days**, and click
   **Create**. Keys look like `XXXX-XXXX-XXXX-XXXX`. Set the owner, maximum
   device activations (default 1), optional label and note. Owner defaults to
   the creating admin; select an existing tester account to put its devices
   and profile inventory under that account instead.
2. Keys are **shown only once**. Copy them and put one on the iPhone:
   **RedditBox launcher → activation screen**, with this deployment's HTTPS URL.
3. The phone claims the key using a stable random installation UUID, then
   validates through `/api/licenses/validate` using its opaque device token.
   Both responses contain an RSA-signed entitlement verified against the
   public key pinned into the app. Offline grace is at most **72 hours** from
   the last good validation and is shortened by the key's expiry. Invalid,
   revoked and expired responses are signed denials; they never extend grace.
4. **Revoke** on `/admin` is immediate on the server. Devices notice on the
   next online check. The console states this delay rather than promising
   offline instant revocation. Open **Manage device keys → Bound devices and
   history** for installation bindings, activation history and last check-in.
   **Re-enable** preserves bindings and expiry. **Delete key** permanently
   denies access and hides the key by default, while retaining its history,
   immutable activation slots and all device/container data. Select **Show
   deleted keys** to inspect those receipts.
5. Legacy account keys still use `/api/licenses/activate` and old pairing
   codes still claim exactly once. New `kind: device` keys cannot grant a
   web-account entitlement or use the old unsigned validation path. An old
   activated account key can gain a device activation under its existing
   account owner; an unassigned legacy key needs an explicit admin owner edit.

### Signing setup and admin migration

Generate one deployment keypair **outside this checkout**, from the repository
root, for example on the Mac:

```bash
python3 scripts/license-key.py generate --directory "$HOME/.redditbox-signing"
export LICENSE_PUBLIC_KEY_FILE="$HOME/.redditbox-signing/license-public.pem"
```

Store the contents of `license-private.pem` only in the cloud secret
`LICENSE_SIGNING_PRIVATE_KEY`; real PEM newlines and escaped `\n` are accepted.
Never put it in `cloud/public`, the repository, the app, or a release archive.
Set `APP_URL` to the canonical HTTPS origin with no path or query. The Mac build
pins the public RSA PKCS#1 DER bytes; JWT `kid` is their lowercase SHA-256 digest.
Missing/invalid signer configuration returns 503 before consuming an activation.
Key rotation requires rebuilding and distributing the matching public pin.

The first authentication-store read atomically snapshots **already claimed**
devices owned by an admin into the permanent-entitlement migration. Unclaimed
pairings, ordinary users' devices and later admin pairings do not qualify.
Migration is one-time and idempotent; stop older cloud writers during deployment.
The `/admin` **Migrated permanent admin devices** disclosure lists the frozen
result. An eligible phone supplies its existing bearer token and installation
UUID to a keyless claim, which preserves its device ID and token. Signing still
uses a bounded 72-hour lease, so the phone must occasionally refresh its permanent
server entitlement. Missing legacy credentials require explicit recovery, not an
automatic new-device exemption.

Claim retries with the same key and installation recover the same device and
opaque token without consuming another slot. The token is HMAC-derived from a
domain-separated signing-key secret and the license/device/binding tuple; only
its SHA-256 hash is stored. An existing authenticated pairing retains its current
token. Moving a device to another owner or replacing an installation binding is
refused. A lost installation UUID does not silently free a slot.

Rate limits are stored in the same auth transaction: **5 claim attempts per
installation per 15 minutes**, and **120 validations per minute**. Invalid-key
attempts count. HTTP 429 includes `Retry-After`; clients must wait and may only
use an already valid cached grace period. Cloud signing/storage failures are 503,
never unsigned affirmative licenses. Lifecycle history records activation and
status/admin changes; successful polling updates the last-check timestamp without
adding a repetitive history event.

## API reference

### Public Sileo / APT distribution

The cloud and release publisher require Node.js 20 or newer, matching the Blob
SDK's minimum runtime. The repository source is `/apt/redditbox/`. Release metadata (`Packages`,
`Packages.gz`, `Release`, signed indexes, the repository public signing key and
`repository.json`) is published together in `cloud/public/apt/redditbox/` as one
deployment. The release script promotes that complete deployment only after
validation. See `../scripts/release.sh` for orchestration; running this checkout
does not publish a repository automatically.
The six mutable index paths explicitly return `Cache-Control: no-store`, so
clients re-fetch the promoted metadata. Retained digest-addressed `by-hash`
indexes remain immutable files for clients holding a previous signed Release.

Large `.deb` files use a dedicated **public** Vercel Blob store. Set
`APT_BLOB_READ_WRITE_TOKEN` and `APT_BLOB_HOST` for release publishing. The exact
host looks like `<store-id>.public.blob.vercel-storage.com`. It must match the
store ID in the APT token and must differ from the store used by
`BLOB_READ_WRITE_TOKEN`, including when those two tokens have different secrets.
Private authentication, licenses, profiles and backups retain their original
storage adapter and authentication rules. No APT code reads that private store.

`GET`/`HEAD /apt/redditbox/debs/<filename>` is public and returns a 302 only for
an artifact listed in the **bundled deployment manifest**. It cannot redirect
from a query argument, unknown filename, arbitrary URL, another Blob host, or
a path outside `apt/redditbox/debs/<sha256>/<filename>`. Corrupt/unsupported
metadata returns 503; absent artifacts return 404. Next's file trace explicitly
includes the manifest in this route's serverless function. This route makes no
cloud-storage API call and needs no publishing secret at runtime. Optionally
set non-secret `APT_BLOB_HOST` on the deployment as a second check against its
bundled manifest.

The v1 manifest contains `package: "com.redditbox"`,
`architecture: "iphoneos-arm64"`, the newest `version`, exact `blobHost`, and
`versions` holding one to three entries in descending numeric `X.Y.Z` order.
Each entry contains `version`, canonical `filename` relative to the repository
(`debs/com.redditbox_X.Y.Z_iphoneos-arm64.deb`), lowercase `sha256`, byte `size`,
exact `blobURL`, and matching Debian `control` fields. Additional release and
signing metadata is preserved. The current version must match the first entry.
The release orchestrator retains the latest three indexes; immutable Blob bytes
are not automatically deleted, so an older deployment can still be rolled back
without a destructive storage operation.

`scripts/apt-publish.mjs` is a plain Node CLI using the locally installed Blob
SDK. It emits one JSON object on stdout and never prints tokens. The release
orchestrator journals the owner UUID before acquisition and uses these commands:

```text
node cloud/scripts/apt-publish.mjs lock --owner UUID
  → {owner,url,pathname,etag}
node cloud/scripts/apt-publish.mjs check --owner UUID --etag LOCK_ETAG
  → {owner,url,pathname,etag}
node cloud/scripts/apt-publish.mjs upload --owner UUID --etag LOCK_ETAG --file ABS_DEB --pathname apt/redditbox/debs/SHA256/FILENAME
  → {url,pathname,etag,sha256,size}
node cloud/scripts/apt-publish.mjs unlock --owner UUID --etag LOCK_ETAG
  → {ok:true,released:true}
```

The fixed `apt/redditbox/.publish-lock.json` is created with
`allowOverwrite:false`, never expired or stolen. Reads bypass the CDN cache;
only the same journaled owner may recover an uncertain acquisition. The read-only
`check` command proves ownership before promotion and never creates or replaces
an object. Uploads also refuse a missing lock and
verify lock ownership before and after writing, use immutable content-addressed
paths, and verify actual origin bytes against local SHA-256 and size. Existing
paths are reused only when that proof matches. Unlock re-reads owner and ETag,
then uses `del(..., {ifMatch: etag})` so a competing replacement cannot be erased.
There is no automatic lock cleanup after uncertain publication. Before manually
releasing a retained lock, prove the original publisher has stopped and resolve
whether its deployment was promoted; otherwise resume its journaled release.

Portable acceptance: `npm run test:apt` runs real manifest/public-route policy
checks and an injected Blob SDK model that enforces exclusive creation and
conditional deletion. It covers competing publishers, lost responses, wrong
owners, stale ETags, corrupted artifacts and loss of ownership during upload.
These tests make **no live Blob writes**. A real deployment, signed APT fetch and
Sileo install remain device/release acceptance steps.

All JSON unless noted. Base URL: `APP_URL` (dev: `http://localhost:3000`).
The **shared device contract** is the first table; extra website routes follow.

### Shared contract (device + website)

| Method | Path | Auth | Body / Notes |
|---|---|---|---|
| POST | `/api/auth/register` | — | `{email, password}` → `{token, user}` + session cookie |
| POST | `/api/auth/login` | — | `{username\|email, password}` → `{token, user}` + session cookie |
| POST | `/api/devices/pair` | Bearer user JWT (or cookie) | `{name, role:"factory"\|"worker"}` → `{deviceId, pairingCode}` |
| POST | `/api/devices/claim` | — | `{pairingCode}` → `{deviceId, token}` (64-hex device token) |
| POST | `/api/devices/claim` | key + installation; optional existing device bearer | `{key?,deviceIdentity,nonce,name?}` → `{deviceId,token,name,role,licenseToken}`; keyless only for migrated admin devices |
| POST | `/api/licenses/validate` | Bearer device token | `{deviceIdentity,nonce,key?}` → `{licenseToken,valid,revoked,expiresAt}`; revoked keys still receive a signed denial |
| POST | `/api/backups` | Bearer device token | `{containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed?}` → `{backupId}`. Ciphertext is opaque base64; server never decrypts. Checksum is SHA-256 hex of the ciphertext bytes. |
| GET | `/api/backups?containerId=` | Bearer user JWT or device token | `{backups:[{backupId,containerId,createdAt,checksum,...}]}` (no ciphertext) |
| GET | `/api/backups/:id` | Bearer user JWT or device token | `{backupId, containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed}` |
| DELETE | `/api/backups/:id` | Bearer user JWT or device token | `{ok:true}` |
| GET | `/api/rotation-settings` | user JWT or device token | User receives masked metadata; paired device receives decrypted proxy/rotation values over HTTPS |
| PUT | `/api/rotation-settings` | user JWT | Stores proxy URL and authorization value encrypted with `PROXY_SECRETS_KEY` |
| GET/POST | `/api/profiles` | user JWT or device token | Cloud/launcher profile inventory synchronization |

### Extra website routes

| Method | Path | Auth | Body / Notes |
|---|---|---|---|
| GET | `/api/auth/me` | session or Bearer user JWT | → `{user:{email,role,licensed}}` or 401 |
| POST | `/api/auth/logout` | — | clears the session cookie |

### Admin

| Method | Path | Auth | Body / Notes |
|---|---|---|---|
| POST | `/api/admin/licenses` | admin | `{count?:1..100,maxActivations?:1..100,ownerUserId?,label?,note?,expiresInDays?,expiresAt?}` → `{licenses:[{id,key,expiresAt}]}` — keys returned **once** |
| GET | `/api/admin/licenses` | admin | → `{licenses:[...], audit:[{at,actorUsername,action,keyIdPrefix}]}` (no keys) |
| POST | `/api/admin/licenses/:id/revoke` | admin | → `{id,revokedAt}` — immediate; devices lock on next check |
| PATCH | `/api/admin/licenses/:id` | admin | `{action?:"enable"\|"delete",label?,note?,ownerUserId?}`; owner cannot change after device activation |
| DELETE | `/api/admin/licenses/:id` | admin | Permanently denies key; retains bindings/history and all container data |
| GET | `/api/admin/users` | admin | → `{users:[{email,role,licensed,createdAt,deviceCount}]}` |

### Licensing (optional selling layer)

| Method | Path | Auth | Body / Notes |
|---|---|---|---|
| POST | `/api/licenses/activate` | session | `{key}` → `{licensed:true}`; single-use, binds email |
| POST | `/api/licenses/validate` | Bearer access key or `{key}` | → `{valid, revoked, expiresAt}` — device heartbeat, fail-closed |
| GET | `/api/pairing-code` | session | convenience wrapper: creates a factory pairing named "Device" |
| GET | `/api/devices` | session **or** Bearer device token | → `{devices:[{id,name,role,claimed,pairedAt,lastSeenAt}]}` |

Notes:

- `deviceToken` is 64-char hex; legacy pairing returns it once, new license claim
  supports safe same-installation retries. The server stores only its SHA-256 hash.
- `lastSeenAt` is updated on every deviceToken-authenticated call.
- Backup ids are random 16-hex chars.
- License keys / pairing codes use the unambiguous charset
  `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (no `0/O/1/I`).

## Crypto contract

Implemented device-side; the website never decrypts anything.

- Device encrypts the envelope with `PBKDF2-HMAC-SHA256(600000 iterations,
  16-byte salt)` → `AES-256-GCM(12-byte nonce, 16-byte tag)`.
- Upload fields: `ciphertext` (base64 of ciphertext\|\|tag), `iv` (base64
  nonce), `salt` (base64), `checksum` (SHA-256 hex of ciphertext bytes).
- The server stores those fields and the blob bytes. It never decrypts.
- Envelope plaintext (device-side) includes the specified fields plus
  `archiveB64` (container tar.gz) so a worker can restore session data.

## Security notes

- Backup contents remain encrypted. Inventory names, organizational roles,
  notes, device ownership and licensing history are server-readable metadata;
  do not put secrets in notes. Backups display as
  `Backup · <short id> · <date> · <size>`.
- Passwords and license keys are hashed with **bcrypt** (cost 10) — plaintext
  keys exist only in the admin's browser at generation time and in the buyer's
  hands.
- Sessions are **JWTs (HS256, `jose`)** in an **httpOnly, Secure, SameSite=Lax**
  cookie (`socialbox_session`, 7-day expiry). Device tokens are opaque 64-hex;
  only their SHA-256 is stored. Device entitlements use separate RSA signatures.
- Route protection via middleware; every API route re-verifies auth and license
  state server-side.
- Device license policy is **fail-closed**. `POST /api/licenses/validate`
  returns `{valid:false}` when the key is missing, unknown, revoked, or expired.
- The license-activation comparison runs bcrypt over unactivated keys only, so
  activation cost stays bounded (hundreds of keys max).

## Project layout

```
cloud/
  src/
    app/
      page.tsx                 # Jew Automations landing + Reddit launcher
      login/page.tsx           # username login
      admin/page.tsx           # create / list / revoke + audit
      apps/reddit/page.tsx     # Reddit dashboard (pair, backups)
      api/                     # all API routes (see reference above)
      error.tsx, not-found.tsx, loading.tsx
    lib/
      storage.ts               # local FS / Vercel Blob (private reads, ETag CAS)
      auth.ts                  # sessions, bcrypt helpers
      pairing.ts               # pair + claim helpers
      ids.ts                   # key/code/token generation
      devices.ts               # Bearer deviceToken auth
      admin.ts                 # lazy admin seeding (username + password)
      identity.ts              # username/email login matching
      licenses.ts              # access-key lookup + validity
      audit.ts                 # grant/revoke audit log
      client.ts                # fetch wrapper + formatters
    middleware.ts              # page-level route protection
    scripts/seed.ts            # explicit admin seed
  scripts/
    license-auth-test.ts       # unit tests
    smoke-test.mjs             # live API contract + admin license cycle
  .env.example
  README.md
```
