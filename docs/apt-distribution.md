# Signed APT distribution and Mac release procedure

The implementation builds rootless and rootful `com.redditbox` packages with
separate flat repositories: `/apt/redditbox/` for rootless (including Dopamine),
and `/apt/redditbox-rootful/` for palera1n rootful. See the
[compatibility matrix and variant commands](jailbreak-compatibility.md). Live publication,
Sileo signature handling, installation and an upgrade with five real profiles
remain **NOT RUN** until the Mac and target phone acceptance run. The portable
test executes real Debian archive parsing and real GPG signatures; its cloud
calls are fault fixtures, not evidence of a successful production deployment.

Use `feat/lifecycle-and-distribution` for this review. Keep `master` unmerged.
The ordinary Mac build procedure and the device/proxy/MDM traffic checks are in
[the acceptance runbook](on-device-smoke-checklist.md). Distribution does not
remove the need for a supported jailbreak, the package dependencies, ldid
entitlement acceptance, or managed per-app VPN association on each clone.

## One-time Mac and deployment preparation

Use full Xcode, its iOS platform, an initialized Theos installation with its
patched iOS SDK, and Procursus ldid. This path uses **no Apple development team**.
After the Xcode and Theos steps in the acceptance runbook, install release tools
and enter the review checkout:

```bash
set -euo pipefail
brew install xcodegen libarchive ldid-procursus xz python node gnupg
npm install --global vercel
export THEOS="$HOME/theos"
export LDID="$(brew --prefix ldid-procursus)/bin/ldid"
export PATH="$(brew --prefix python)/libexec/bin:$PATH"
unset DEVELOPMENT_TEAM
git switch feat/lifecycle-and-distribution
git pull --ff-only origin feat/lifecycle-and-distribution
npm --prefix cloud ci
```

There are two separate signing keys:

1. The device-license RSA key is generated outside the checkout using
   `python3 scripts/license-key.py generate --directory "$HOME/.config/redditbox-signing"`.
   Configure its **private** PEM as the cloud production environment variable
   `LICENSE_SIGNING_PRIVATE_KEY`; set `APP_URL` to the canonical HTTPS origin.
   The Mac build receives only `license-public.pem` and embeds its public pin.
   Keep this key stable across upgrades. Changing it invalidates existing
   cached device tokens until a matching deployment revalidates them.
2. The APT archive key is a **separate GPG signing key** kept on the release Mac
   or its configured GPG agent/hardware signer. Create it once, for example with
   `gpg --full-generate-key`, choosing an RSA signing key of at least 3072 bits.
   Use `gpg --list-secret-keys --with-subkey-fingerprint` to record its full
   primary fingerprint. Unlock that signing key in the GPG agent before a
   noninteractive release. The script uses `--batch --pinentry-mode error` and
   stops if signing would require an interactive prompt. Keep the key's private
   material and revocation certificate outside the repository and deployment.

Create a **dedicated public Vercel Blob store** for package binaries. Keep the
existing authentication/backups Blob store private. Copy the public store's
exact `STORE.public.blob.vercel-storage.com` hostname and its read/write token.
The upload helper checks the token's store ID against that hostname and rejects
the private store when `BLOB_READ_WRITE_TOKEN` is also present. Never point an APT
token at the authentication/backups store. Set `APT_BLOB_HOST` on the cloud
production environment too; the public download route checks it against the
deployed manifest. The upload token is needed on the release Mac only.

Configure the existing Vercel project's production license/storage environment,
and retain its exact project ID and organization/team ID. An access token with
permission to deploy and promote that project is required. The production
domain must be the host in `APT_REPOSITORY_URL`. The release uses Vercel's
[staged production deployment](https://vercel.com/docs/cli/deploying-from-cli)
sequence, `deploy --prod --skip-domain` followed by `promote`, so verification
precedes moving the production domain. If deployment protection covers the
unique staged `.vercel.app` URL, configure an automation bypass secret and set
`VERCEL_AUTOMATION_BYPASS_SECRET` locally. It is sent only to that staged URL,
never to a redirected Blob download or the public production APT endpoint.

Supply secrets through your shell's secret manager or a private environment
file outside the checkout. Do not paste real tokens into these docs, commit
them, or enable shell tracing. Required exports are:

```bash
export LICENSE_PUBLIC_KEY_FILE="$HOME/.config/redditbox-signing/license-public.pem"
export RBX_PACKAGE_SCHEME=rootless  # rootful requires /apt/redditbox-rootful/ below
export APT_REPOSITORY_URL="https://YOUR-CLOUD-HOST/apt/redditbox/"
export APT_BLOB_HOST="YOURSTORE.public.blob.vercel-storage.com"
export APT_SIGNING_KEY_FINGERPRINT="FULL_GPG_PRIMARY_FINGERPRINT"
export VERCEL_ORG_ID="YOUR_VERCEL_ORGANIZATION_ID"
export VERCEL_PROJECT_ID="YOUR_EXISTING_VERCEL_PROJECT_ID"
# Load APT_BLOB_READ_WRITE_TOKEN and VERCEL_TOKEN securely into this shell.
# Optional: VERCEL_AUTOMATION_BYPASS_SECRET for protected staged deployments.
```

Keep the existing project root directory set to `cloud`. The publisher uploads
from the repository root; `.vercelignore` includes only cloud sources and public
APT metadata, excluding local build outputs and environment files.

Check the selected Vercel project and production domain in its dashboard before
the first release. Disable automatic production Git deployments until the
generated signed indexes have been committed to the branch used for deployment;
otherwise an older checkout can replace the newly published index.

## Release command

For the **first publication of each variant** only, set `APT_BOOTSTRAP=1`. Bootstrap is accepted
only when `InRelease`, `Release`, `repository.json` and `Packages` all return
HTTP 404. Authentication failures, timeouts, HTTP 500 and partial repositories
stop publication. Existing repositories must have a valid signature matching
the configured GPG fingerprint; `APT_BOOTSTRAP=1` never bypasses verification.

```bash
export APT_BOOTSTRAP=1    # first publication only; unset after it succeeds
bash scripts/release.sh 0.1.1
unset APT_BOOTSTRAP
```

Later, one command builds and publishes the next version:

```bash
bash scripts/release.sh
```

An explicit version uses canonical `X.Y.Z`, with each component from 0 through
9999 and no leading zeros. It must exceed the authenticated published version.
Without an argument, the script increments the larger of the checkout control
version and published version, carrying from patch to minor to major at 9999.

The command performs these steps:

1. Hold a nonblocking local process lock and a public Blob publisher lock with
   a journaled UUID/ETag. A second publisher cannot overwrite, expire or steal
   that lock. Authenticate the existing `InRelease`, its SHA-256 index entries,
   the repository manifest and all retained by-hash index bytes.
2. Build using `RBX_RELEASE_VERSION=X.Y.Z` and the authenticated previous
   `RBX_PREVIOUS_SIGNING_CONTRACT_HASH`. The build runs its native and portable
   checks, archives without Apple signing, applies ldid signing, and produces a
   gzip-compressed Debian package. A failed build never selects an old `.deb`.
3. Inspect the actual new `.deb`: package ID, version, selected architecture/prefix,
   stable launcher/host/provider bundle IDs, versions and release metadata.
   Reject user-state files, raw source/clone IPAs, private key files, traversal,
   links, special files, user-data cleanup and changed maintainer scripts.
4. Upload immutable package bytes to the dedicated public Blob store under
   their SHA-256 pathname and verify the origin bytes. Build `Packages`,
   deterministic `Packages.gz`, `repository.json`, `Release`, `InRelease`,
   `Release.gpg`, public key exports and by-hash indexes. Keep the newest three
   indexed versions and up to three generations of index hashes. Older Blob
   bytes are never automatically deleted, but the repository filename route
   serves only the current three manifest versions. A cached older index outside
   that window may receive 404 and must refresh; retention is not a promise that
   every historical repository filename remains available.
5. Prove the local companion repository matches its live signed version (or
   both are absent), then deploy the complete snapshot with `--prod --skip-domain`.
   Both variants share one local process lock and one remote publisher lock. Verify the
   staged GPG signature, every index hash and downloads of every retained
   package through the actual redirect route. Verify the production baseline
   and publisher lock again, promote, then repeat verification against the
   public production URL before releasing the lock and printing `Published`.
   Require the companion repository to remain unchanged throughout verification
   and promotion; an outdated checkout cannot erase the other variant.

If the signing contract changed, the package and manifest explicitly set
`requiresMDMReadoption=true`, and the command prints an MDM re-adoption warning.
The initial package also requires adoption. Existing clone bundle IDs remain
stable, but the flag does **not** prove iOS retained each clone's VPN association.
Check every association and keep traffic CLOSED until the device probe passes.

The command leaves exact deployed metadata in `cloud/public/apt/redditbox/`
(rootless) or `cloud/public/apt/redditbox-rootful/` (rootful) and prints required
preservation commands with the released version. Keep both directories when
both exist. For example, after a rootless release:

```bash
git add cloud/public/apt/redditbox
git commit -m "Publish APT repository X.Y.Z"
git push origin HEAD
```

Review and retain that commit on the branch used for subsequent cloud deploys.
Before any ordinary cloud deployment, compare its local `repository.json`
version with the live signed repository and keep the published index or newer.
Do not deploy an earlier branch's index or a checkout missing `public/apt`.
The publisher serializes its own releases; manually deleting its lock or an
unrelated external deployment bypasses that coordination and must be avoided.

## Interrupted publication

Keep `build/release/publish.json` for rootless or
`build/release/rootful/publish.json` for rootful, the inspected package and signed
metadata. Resume with the same `RBX_PACKAGE_SCHEME` and matching repository URL.
The journal contains no private key or access token. It records the owner,
ETag, version, immutable upload and deployment URL before promotion. No failure
automatically removes the public lock or rewinds production. Resolve the cause
and use the same checkout and configuration:

```bash
bash scripts/release.sh --resume
```

For the first publication interrupted while its journal is still `prepared`,
retain or reload `APT_BOOTSTRAP=1` before resuming. The normal configuration
exports must also be present in a new shell. Bootstrap still requires a fully
absent repository; it cannot bypass signature or partial-publication checks.

The requested version is saved in the prepared journal before acquiring the
remote lock. A newly created lock may take a short time to become readable; the
publisher retries only reads for a bounded visibility window and validates the
same owner/ETag. It never recreates or steals a lock during a pre-promotion check.
For older prepared journals without a saved requested version, pass it explicitly:
`bash scripts/release.sh --resume X.Y.Z`. A conflicting saved version is rejected.

A lost promotion acknowledgement re-verifies production and completes without
promoting twice. A lost unlock acknowledgement can reacquire the now-absent lock
with the same journaled owner, re-verify production and release it. A lock owned
by another release is always refused. If the original machine/journal is lost,
stop all publishers, inspect the public lock and Vercel deployment history, and
recover the matching journal from backup. There is deliberately no automatic
lock-stealing or destructive cleanup command. Keep failed artifacts for review.

## Morning Sileo/APT installation and upgrade

Obtain `public-key.asc` or `redditbox-archive-keyring.gpg` from the published repo
and compare its **full** fingerprint against the fingerprint recorded directly
on the release Mac. Do not trust a key merely because it was downloaded beside
the repository. On the Mac this displays the exported key's fingerprint:

```bash
curl --fail --silent --show-error \
  "${APT_REPOSITORY_URL%/}/public-key.asc" -o build/release/downloaded-public-key.asc
gpg --show-keys --with-fingerprint build/release/downloaded-public-key.asc
```

On the phone, use its SSH root shell and the verified exported binary key.
Select paths from the active bootstrap architecture, not the phone model.
Replace the source hostname and transfer path with your actual values:

```sh
case "$(dpkg --print-architecture)" in
  iphoneos-arm64) RBX_PREFIX=/var/jb; RBX_REPO=redditbox ;;
  iphoneos-arm) RBX_PREFIX=; RBX_REPO=redditbox-rootful ;;
  *) echo 'Unsupported package architecture' >&2; exit 1 ;;
esac
mkdir -p "$RBX_PREFIX/etc/apt/keyrings" "$RBX_PREFIX/etc/apt/sources.list.d"
install -m 644 /PATH/TO/VERIFIED/redditbox-archive-keyring.gpg \
  "$RBX_PREFIX/etc/apt/keyrings/redditbox-archive-keyring.gpg"
printf '%s\n' "deb [signed-by=$RBX_PREFIX/etc/apt/keyrings/redditbox-archive-keyring.gpg] https://YOUR-CLOUD-HOST/apt/$RBX_REPO/ ./" \
  > "$RBX_PREFIX/etc/apt/sources.list.d/redditbox.list"
apt-get update
apt-cache policy com.redditbox
apt-get install com.redditbox
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' com.redditbox
```

PASS means APT verifies the repository signature, offers the exact published
version, resolves package dependencies, and the launcher and Diagnostics show
that version. Open Sileo and refresh sources after installing the trusted key
and source above; require it to display the same repository/version and install
or upgrade successfully. **Sileo support for this signed flat source remains an
on-device acceptance item.** Do not use `trusted=yes`, permit insecure repos or
silence signature errors to mark it passing.

Before an upgrade with five profiles, record all five profile IDs, names,
identities, role/notes and clone bundle IDs, then close the active session.
Upgrade through APT/Sileo and verify all five still exist with identical IDs,
metadata and clone associations. Confirm Diagnostics' container count and
installed version, sequential schema migration outcome and CLOSED state before
opening a profile. Check Keychain/session persistence on the device. A newer
unknown data schema or a failed migration must preserve its files and stay
CLOSED; never delete the store or journals as a workaround. Run the A/B capture
and browser-login checks in the acceptance runbook after the upgrade.

Portable release verification:

```bash
python3 tools/test_apt_release.py
```

This covers actual package fixtures, three-version retention, deterministic
hashes, wrong/malformed/signed-manifest rejection, real GPG signing and tamper
rejection, bootstrap error classification, shared publisher exclusion and eight
interrupted-publication/resume boundaries for both variants. It also rejects
cross-variant payloads/manifests and missing, corrupt or stale companion metadata. It does not execute a Mac build,
contact a production Blob store, promote Vercel, or install on a phone.


## Installation page

The existing console links to `/install`. Set `APP_URL` to the exact production
HTTPS origin (for example, the domain already configured for this project),
`APT_BLOB_HOST` to the dedicated public archive store, and
`APT_SIGNING_KEY_FINGERPRINT` to the full archive-key fingerprint in the Vercel
build environment. These are public values; never put either private signing key
in a public variable, artifact, or checkout.

The page reads each architecture's bundled manifest independently. It offers
Sileo and copy-source actions only when that variant has a valid matching manifest
and all required signed repository/key files. The release driver must still verify
the actual signatures and downloads before promotion. The source addresses use
`APP_URL`, including in staged deployments, so preview hostnames cannot leak into
installation instructions.

The Sileo link format is `sileo://source/https://HOST/apt/redditbox/` (or
`redditbox-rootful/`), without percent-encoding the nested source URL. This follows
Sileo's `AppDelegate.swift` source-link dispatch and
`UI/SourcesViewController/SourcesViewController.swift` handling in the
[official Sileo source](https://github.com/Sileo/Sileo). The link adds a source;
it does not prove key trust, dependency installation, or on-device compatibility.
Do not replace signature verification with `trusted=yes`.

## Repair signed Release headers without changing packages

Sileo requires a `Components` field even for a flat `./` source. The generator
sets `Components: main`; clients still request `Packages` at the flat repository
root. Do not add `/main/` to either public source URL.

With the same release environment and both package-release journals complete,
refresh both repositories together without rebuilding or incrementing versions:

```bash
python3 scripts/refresh-apt-metadata.py
# After an interrupted attempt, keep the journal and lock:
python3 scripts/refresh-apt-metadata.py --resume
```

The repair authenticates both live repositories, retains all package indexes,
by-hash files and archive keys byte-for-byte, and regenerates only `Release`,
`InRelease` and `Release.gpg`. It uses the same local and Blob publication locks
as `release.sh`. One staged deployment contains both repaired repositories;
signatures, exact metadata bytes and package downloads must pass before promotion
and again on production before unlocking. Exact metadata comparison matters here:
the package manifest and version intentionally stay unchanged.

The resumable journal is `build/release/metadata-refresh.json`. Commit both
`cloud/public/apt/` repositories after successful publication. Run
`python3 tools/test_apt_metadata_refresh.py` for repair recovery checks in
addition to `python3 tools/test_apt_release.py` for Debian/GPG release checks.

### Publish the missing installer dependencies

Both signed manifests may carry an optional `dependencies` inventory containing
only `ai.akemi.appinst` and `ai.akemi.appsyncunified`, with their actual Debian
identity, size, SHA256 and same-store immutable Blob URL. The public `.deb`
route serves only the listed architecture-matching artifacts. The next ordinary
`release.sh` publication preserves this inventory and includes it in `Packages`.
Every staging/production check downloads these packages as well as RedditBox.

To add the inspected dependencies without rebuilding RedditBox, provide a local
JSON document with `rootless` and `rootful` arrays, each containing the two
records `{ "file": "/absolute/package.deb", "sha256": "INSPECTED_SHA256" }`, then:

```bash
python3 scripts/refresh-apt-metadata.py --dependencies /absolute/inventory.json
# Keep the same journal and owner after any failure:
python3 scripts/refresh-apt-metadata.py --resume
```

The input is journaled before publication. Actual control fields and bytes are
checked before immutable upload under the shared publisher lock. This mode may
change only the dependency inventory and index generations; all existing
RedditBox version records and archive keys must remain identical. Both variants
are staged and promoted together after signatures and downloads pass.

The initial appinst build is `2.1.1-redditbox1`, with upstream code from AppSync
commit `235aca6cddfbdc9fa87fcb5b2aec2df37ed6d65a`, static libzip 0.11.2,
arm64, and minimum iOS 15. Only Debian revision/minimum firmware metadata was
changed; no Objective-C changes. The corresponding source, licenses and build
instructions are published at `/install/sources/appinst-2.1.1-redditbox1-source.tar.xz`.
AppSync Unified 116.0 packages are the unchanged official GitHub release assets;
the source archive includes that complete upstream tree as well.

### Check cloud changes before promoting both repositories

For a server-only repair, keep the same publication environment and use:

```bash
python3 scripts/refresh-apt-metadata.py --stage-only
# Read deploymentURL from build/release/metadata-refresh.json.
# Check that deployment's /api/licenses/status through the existing staging bypass.
# ready must be true; issuer must be APP_URL; keyId must match the installed RSA pin.
# Exercise the changed API before production promotion.
python3 scripts/refresh-apt-metadata.py --resume
```

The staging checkpoint retains the shared publication lock and does not change
production. If the service check fails, fix its code and run
`--resume --restage --stage-only`; the previous staging URL remains in the
journal. This is allowed only before promotion and after verifying that both
production repositories still match the original snapshot. Re-check the new
staging deployment before resuming promotion. Signing keys, package files and
both repository inventories stay unchanged.

`GET /api/licenses/status` returns only readiness, canonical issuer and public
signing key ID. A 503 identifies the failing signing/storage stage; logs contain
bounded error identifiers, never request keys, PEM contents or license records.
It does not prove that a license key is valid or that an iPhone can activate.
