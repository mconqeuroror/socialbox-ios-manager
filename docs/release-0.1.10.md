# RedditBox identity editor update

Branch `feat/lifecycle-and-distribution` remains unmerged.
Rows: UI-003, LIFE-029. Versions are tracked separately for each package variant.

## Changes

- Edit retrieves saved values through a private, request-bound Keychain draft.
  UUID/UDID and the other identifier fields are filled rather than blank.
- Random fill generates a coherent draft. Check consistency and Save changes
  are explicit. Identity freeze after first use remains enforced.
- Startup fingerprint inspection no longer recursively reads the central store
  from its serial write transaction. The native fixture failed before the fix.
- Package bootstrap runs once, without killing startup with a second kickstart.
- Nested resource classification reads four bytes, rather than loading whole
  files. Encryption inspection requires a mapping and releases it in a local
  autorelease pool. A native 1 GiB sparse-file fixture verifies bounded reads.
- Identity rebuild receives the same bounded 600-second deadline as creation,
  including preservation of the existing clone and its rollback archive.

The header-reading change and successful 0.1.9 recovery followed the 0.1.8
Save changes jetsam failure; that earlier version was not accepted for saving.
See release-0.1.8.md for the failed test and preserved evidence history.

## Recovery and limits

Manual recovery was limited to exact task-owned markers. Before retiring each,
the daemon was stopped; live process enumeration, pending IPC, helper-exit
fences, CLOSED local lease and schema/journal state were inspected. The last
interrupted clone journal was specifically bound to the test container and
still `prepared`, before any installer attempt. Its staged files were handled
by the normal daemon recovery, not manually erased. Startup on 0.1.9 then
completed successfully. This does not establish a general automatic recovery UI.

Visible touchscreen rendering/taps, MDM adoption, managed VPN routing, clone
login, cross-container canaries and rootful device acceptance remain unverified.
No claim of 100% isolation. Proxy library still uses one selected connection
proxy; saved rows do not establish per-container proxy assignments.

## Published verification

Production checks passed for rootless **0.1.10** and rootful **0.1.8**.
Both use the updated editor and rebuild fixes; package version histories are
separate. Signed indexes, all retained package downloads and exact local
metadata were verified. Both staging license-health checks passed before
promotion. The existing signer still matches the existing public PEM; no
license key or private Blob store was replaced.

- Install: https://redditspoof.vercel.app/install
- Rootless: https://redditspoof.vercel.app/apt/redditbox/
- Rootful: https://redditspoof.vercel.app/apt/redditbox-rootful/

The install page exposes both matching versions, canonical Sileo links and two
copy-source buttons. These are HTTP/HTML checks, not a new Sileo tap test.
Transient publication visibility failures were resolved with the same-owner
release journal resume. Both publisher journals reached complete.

## Final connected-device results

Rootless 0.1.10 was transferred with SHA-256 verification and installed over
0.1.9 normally, without retiring another recovery marker. Installed version,
successful startup, empty recovery state and active license were checked.

The actual daemon actions and private Keychain channel passed the full sequence
on the task-created, unused Test container: load all ten saved identifier
fields; generate a changed random draft; validate that exact draft; reload to
prove Random fill alone did not save; apply the draft through the normal clone
rebuild; reload and compare all ten saved identifiers exactly. The daemon
stayed running and the final identity result reported applied successfully.
Raw identifiers were absent from public launcher state and safe receipts.
This is backend-on-device acceptance, not touchscreen rendering acceptance.

The configured proxy also passed an actual daemon connection test on 0.1.9
with no rotation link configured. The clone remains subject to MDM/network
setup before launch; that setup and full isolation acceptance were not bypassed.
