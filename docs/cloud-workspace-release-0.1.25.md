# SocialBox workspace and Cloud — 0.1.25

Published 2026-09-17 to the existing Vercel project, domain and license system.
Branch `feat/socialbox-multiapp` remains unmerged. Both referenced videos were
reviewed; the timecoded findings are in `reference-workflows-2026-09.md`.

## Use it

- Existing web console: https://redditspoof.vercel.app/apps/reddit#cloud-backups
- Installation: https://redditspoof.vercel.app/install
- Rootless source: https://redditspoof.vercel.app/apt/redditbox/ — 0.1.25
- Rootful source: https://redditspoof.vercel.app/apt/redditbox-rootful/ — 0.1.25

The connected rootless iPhone was upgraded from 0.1.22 to 0.1.25. Its two profile
IDs and active license were preserved. Other phones update through their matching
Sileo source; the app does not silently install its own package update.

The launcher now has Home, Containers, Location, Proxies and Settings tabs,
searchable container/proxy lists and a selected-container Home screen. Cloud is
available from Home and Settings. The existing website has the corresponding
searchable, app-filtered backup section. Upload and restore remain native phone
operations; the website manages encrypted backup records without receiving the
decryption key. See `cloud-workspace-integration.md` for the same-license,
cross-phone key transfer and explicit restore-as-new-container flow.

## Validation actually performed

Both variants passed the full `scripts/build-mac.sh` test/build sequence with
Procursus ldid and the existing license public key, without an Apple signing team.
Static checks, native Cloud bridge/store/admission/backup transaction tests,
server authorization and chunked transfer tests, Next production build and the
release recovery tests passed. Actual shipped UIKit was exercised with 50
synthetic containers (28 checks); the built web interface with 50 synthetic
backups passed nine browser checks, including mobile layout and denied deletion.
These fixture counts are not a claim that 50 real clones were launched.

For each variant the standard release journal verified staged APT signatures,
indexes and all retained package downloads, promoted that deployment, and verified
production. An additional runtime gate before promotion checked license readiness,
unchanged public key ID, denied unauthenticated backup routes, protected console
and both canonical installation sources. Final production metadata for both
repositories matches the committed signed files byte-for-byte.

Both actual packages were inspected: seven Mach-O components and 12 architecture
slices per variant, 1,342 code-page hashes per package, matching existing license
pin, catalog and entitlement values. CodeDirectory inspection proves those hashes,
not Apple trust or functioning per-app VPN adoption. The rootful release metadata
requires MDM readoption relative to its previous published package.

The physical iPhone passed upgrade/data-retention and a read-only production Cloud
list request through the installed daemon and private Keychain response channel.
It currently has zero cloud backups. No user backup/profile was created or deleted
and no clone network gate was opened during this acceptance check.

## Release recovery and commits

- `ecf7103`: native workspace navigation and reference analysis.
- `1c259da`: native Cloud, private response channel, same-license authorization,
  bounded encrypted transfer and existing web console integration.
- `16fc45c`: preserve an intermediate signed rootless 0.1.15 publication.
- `c8d5961`: preserve the requested release version across interrupted lock
  acquisition; tolerate bounded visibility delay only for this publisher's newly
  created lock, while retaining exact ownership/ETag checks.
- `7478063`: signed rootless 0.1.25 metadata.
- `31a341e`: signed rootful 0.1.25 metadata.

The initial interrupted prepared journal had lost the explicit version; its old
resume behavior published the intermediate 0.1.15. A failing regression test
reproduced this for both variants before the driver fix. Final versions are
0.1.25 for both. Immediately after promotion the CDN briefly exposed mixed index
generations. Verification failed closed and preserved the journal/lock; resuming
the same journal after propagation completed signature/hash verification and
released the lock. No lock was stolen, signature check bypassed or key replaced.

## Still requires device acceptance

On the connected phone firewall readiness remains false and the gate remains
CLOSED. Finish managed per-app VPN/MDM setup and verify actual proxy routing before
opening a clone. Facebook remains inactive pending its separate physical acceptance.

Two-phone backup/restore with a real logged-in app, restored login persistence,
large archive throughput/memory and packet-level A/B isolation are not verified.
App Keychain and hardware-bound credentials are not included in these backups,
so a restored app can require login again. No 100% isolation or universal session
portability claim is made. Existing open leak-surface rows remain open.

Machine-readable, sanitized evidence: `release-evidence/0.1.25-cloud-workspace.json`.
