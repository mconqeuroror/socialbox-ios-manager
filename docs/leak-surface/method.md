# LEAK_SURFACE — RedditBox evidence contract

Initial structural audit: **2026-09-10**, on unmerged **feat/lifecycle-and-distribution**.
Current delta review: **2026-09-20**, on unmerged **feat/lucid-base**.
The prior [isolation review](docs/isolation-review-2026-09-14.md) remains historical evidence.
The current [reference UI validation](docs/leak-surface/reference-ui-validation-2026-09-19.json)
records the new prepare/review/commit and interface delta, with separate host, simulator and device status.
Source baseline before this audit: **fdf181f**. The source inventory records the
reviewed post-fix file hashes; the binary inventory records the unchanged user-supplied IPA.

**Coverage is incomplete. This document is not an “all clear.”** Mechanical
enumeration, code review, native regression tests and on-device observations are
separate evidence classes. In particular, global binary references do not prove
which SDK calls an API or what it sends. Unverified SDK data flows and first-run
storage observations remain explicit acceptance work, not assumptions.

The recovered owner-base candidate is a **separate implementation** from the
original clone-based SocialBox runtime. ADOPT-001 through ADOPT-004 describe its
presentation, packaging and unresolved integration boundary. Existing Reddit /
Facebook rows do not automatically become coverage claims for preserved SocialBox
binaries. The `lucid/` production source is now included in the source hash and
change gate; its synthetic test hosts are explicitly excluded from shipped
hook-reference counts. See [the adoption handoff](docs/socialbox-adoption-handoff.md).

## Phase 0 — mechanically enumerated baseline

The current input is Reddit **2026.36.0 (664762)**, not the older Android evidence:

- IPA SHA-256: `68cf3bb1ea394d225c5eec2d85032deeebaff2ccfd2153e9b1ce92c726782046`.
- 11,202 ZIP entries, 221 bundle Info.plist records, 28 privacy manifests and eight Mach-O executables.
- Main executable SHA-256: `b4feb734585599912e67a74493b1ba9b8f562eb77ac6659d20be92c209906ab5`.
- Executables: RedditApp, ExtensionDependencies, Lottie, NotificationServiceExtension,
  RedditIntents, RedditWidgetsExtension, ShareExtension and stickers.
- Each executable/slice is enumerated for load commands, encryption state, linked
  libraries, symbol and dyld imports, Objective-C class/selector references,
  method-name strings, Swift ABI descriptors, SDK candidates and static hostname/key candidates.
  Totals: 17,796 selector references, 1,628 class references, 17,586 class definitions,
  22,993 imports and 64,167 Swift descriptors; no unresolved decoded references.
  The scanner handles classic binding and chained fixups. Independent `nm`/`otool`
  comparisons are required to catch omissions in the scanner itself.
- Static SDK discovery includes AppsFlyer, Firebase Analytics/Installations/Sessions/
  Crashlytics/RemoteConfig, Google transport/utilities, reCAPTCHA Enterprise,
  AppAuth, PINCache, AFNetworking and SwiftNIO. The full SDK ledger records evidence
  and distinguishes declarations, references and actual call/transport proof.
- A separate source scan covers the daemon, tweak, launcher, SpringBoard hook,
  preference bundle, NetworkExtension, cloud, profile catalog and packaging. A
  declared hook is not counted as active until its installation path is traced.

The small [binary summary](docs/leak-surface/binary-inventory.json) contains input,
scanner and per-executable hashes and counts. The lossless
[compressed structural inventory](docs/leak-surface/binary-inventory.full.json.gz)
contains every decoded reference, not only selected SDK names. It contains names,
offsets and declarations; it does not contain the IPA or private device preference values.
[source-inventory.json](docs/leak-surface/source-inventory.json) is the reproducible
source reference and hash baseline. SDK/storage, OS/network, lifecycle and wire
row JSON files live beside those machine inventories.

Reproduce with the privately retained IPA (never commit or redistribute that IPA):

```sh
python3 tools/enumerate_leak_binary.py --help
python3 tools/enumerate_leak_binary.py --self-test
python3 tools/enumerate_leak_binary.py PRIVATE.ipa \
  --output docs/leak-surface/binary-inventory.json \
  --details-output docs/leak-surface/binary-inventory.full.json.gz
python3 tools/enumerate_leak_source.py --output docs/leak-surface/source-inventory.json
python3 tools/check_leak_surface.py --write
python3 tools/check_leak_surface.py
```

**Limits of the word “full”:** enumeration is complete for the structural records
decoded by this scanner for this IPA, with the scanner residuals in its JSON. It is
not a proof that a finite static list covers every OS capability, dynamically
constructed selector, JIT/interpreted input, remote configuration or future SDK.
Every unmapped reference/dynamic path is an unresolved delta; absence from a
symbol table is never sufficient for “app does not use this surface.” WIRE-015
keeps this boundary explicit. Framework linkage and privacy declarations establish
candidate surfaces, not observed use or absence.

### Device evidence actually available

Earlier work verified RedditBox 0.1.2 source import on the connected iPhone 8
(iPhone10,4), iOS 16.7.16, palera1n rootless. It is not a two-clone isolation test.
The original Reddit app's existing preference file was inspected privately; only
key names and types enter this inventory. It had already run. It was **not** a
fresh sandbox and was **not** an observed first-run clone. Its AppSessionIdKey,
AppsFlyerInstallDate, analytics-install-ts-key and Firebase session entries are
observation evidence of storage, not proof of SDK-to-network data flow.

At the hardware check in this audit, the existing USB SSH endpoint reset the
connection. No fresh A/B capture, keychain enumeration, instrumented first launch,
managed per-app VPN assignment or native login/browser acceptance was completed.
The original app, IPA, account tokens, licenses and production service were not
modified by the audit. New host builds are not an installed-device acceptance run.

### Facebook input and latest device delta

The Facebook IPA is **578.1.0 (1063022819)**, SHA-256
`2cdaab3bd8bd0238660ea23b566b7bd7713121d996032bbc045d4066d2233e8a`.
Its [structural audit](docs/facebook-binary-audit.md) enumerates 20 Mach-O images,
with [independent validation](docs/leak-surface/facebook-binary-validation.json).
[Original-app runtime observations](docs/facebook-runtime-observations.md) establish
selected API names, groups, statuses and caller offsets; they do not establish
clone identity or transport isolation. Facebook execution remains inactive.

The [2026-09-14 partial device capture](docs/isolation-review-device-0.1.16.json)
used installed **0.1.16**, not the new **0.1.17** candidate. Publication, license,
saved proxy configuration, imported source, exact daemon binding, one clone's
structure/removed extensions/data-container metadata and helper cleanup passed.
These observations do not prove in-clone foreign access denial. Actual MDM,
A/B/A probes, routing, account flows and scale remain untested. USB subsequently
disconnected. The current source snapshot is regenerated after each committed
fix; previous device observations must never be relabeled as testing newer code.

## Meaning of a verdict

- **covered-in-code**: the exact, narrowly stated mechanism is present and its
  cited code path or native test was checked. It does not imply runtime coverage
  of all callers, transports or lifecycle transitions.
- **gap**: an identified missing or incorrect boundary. The next/fix cell records
  the required intervention and its prerequisites; unresolved rows remain blockers
  for a claim of complete coverage.
- **unverified**: evidence is insufficient to choose a coverage verdict. The row
  names the missing observation. It is not a pass and is not an assertion of a leak.
- **not-used-with-evidence** is reserved for an explicit exclusion proof. Missing
  strings/imports alone do not qualify. Removed clone extensions are an explicit
  packaging boundary, not proof that equivalent main-app functionality is absent.
- **hook / sandbox / generator / blocked / none** describes the proposed or actual
  mechanism. The verdict and evidence decide whether it is established; a mechanism
  name alone is not coverage.

Same account/session identity can legitimately remain the same during restoration
of that logical identity. A fresh clone has a different requirement. Zero IDFA with
tracking disabled, app version and other shared constants are not unique-device
identifiers. A duplicated field is a finding to investigate under the row's
semantics, not automatic proof of cross-container leakage or account unlinkability.

## Phase 2 — fixes and verification

The original audit used separate fix commits and affected-row trailers. Its historical build and
test ledger is in [validation.json](docs/leak-surface/validation.json). The current UI delta
is recorded separately below; its missing historical trailers are a governance failure, not a waived check.

- `aa25953` / **WIRE-002**: preserve opaque server-owned JSON subtrees before recursion.
  The actual production function failed on nested session data before the change.
- `c9cafe8` / **LIFE-014**: bind the decrypted manifest to the selected backup identity
  before side effects. Seven wrong/missing-identity cases failed before; all 13
  ownership fixtures pass with the fix.
- `fa2d835` / **WIRE-001**: exact DNS-label boundaries for Reddit header classification.
  `notreddit.com` was accepted by the old function; it is rejected by the regression.
- `de3f654` / **NET-039**: independently fix substring matching in the critical-request
  policy. `redditmedia.attacker.invalid` failed the pre-fix regression.
- `845132d` / **LIFE-015**: replace external tar extraction with bounded descriptor-relative
  libarchive extraction. Eighteen fixtures cover current/legacy roots, links,
  traversal, duplicates/case aliases, special/sparse/truncated/oversized entries,
  cancellation and attempted writes outside the permitted data root.
- `98aecc9` / **AUDIT-001**: replace the always-clear deduplicating observer with
  locally labelled per-container comparisons and private per-run fingerprints.
- `cd96ddc` / **LIFE-019, ID-010**: persist a checked `identityFrozenAt` marker before
  ARMED/launch; uncertain or failed persistence aborts admission. Thirteen native
  fault cases pass. Same-identity restore starts frozen; a fresh replacement has
  its own first-use boundary. Successful `lastActiveAt` semantics stay unchanged.
- `6c48b23` / **AUDIT-001**: include observed requests even without a response and
  report missing-field coverage separately. All twelve capture-verifier cases pass.

No new generated device identity fields are introduced by these changes. The
existing install UUID, external installation UUID and staggered timestamp already
existed at the baseline. `identityFrozenAt` is private lifecycle metadata, not a
generated device identity or an outbound identifier. No audit fix is described as deployed until a separate
release and device acceptance record exists.

The principal unresolved groups are global/schema-blind body mutation and HMAC
ordering (WIRE-003 onward), SDK-specific storage-to-send attribution (SDK/STORE),
unhooked referenced NSProcessInfo surfaces, external browser/authentication service
state, effective app-proxy enforcement for every transport, and cross-device
restore ownership. Broad new hooks or blocking login brokers without acceptance
fixtures would change critical behavior; this audit does not invent a safe result.

## Phase 3 — rules for future changes

1. Keep row IDs stable. Add rows for new surfaces; never silently delete or reuse
   an ID. Preserve unresolved rows until the evidence actually closes them.
2. A feature/fix touching a row must include a commit trailer, for example
   `Leak-Surface: LIFE-014, WIRE-002`. Update the row's mechanism, evidence and tests.
   The source file must appear in the affected row's evidence, including newly
   introduced files. For deleted files, retain the history in the row and use the
   appropriate current replacement/absence evidence; the gate resolves deleted paths
   through the retained row's earlier evidence.
3. Review source and binary inventory deltas first, then verify all affected rows.
   Regenerating a hash snapshot is not a substitute for review. A new IPA hash
   requires a new binary enumeration and a comparison of all imports, selectors,
   modules, privacy declarations and observed storage keys.
4. Run `python3 tools/check_leak_surface.py --base BASE_COMMIT` before push. CI
   checks row completeness, stable IDs, evidence locations, generated Markdown,
   source drift (including entitlements and the workflow), unresolved binary
   references and each commit's own row trailers for changed shipped files. Initial
   adoption starts at `fdf181f`, as recorded in `audit-inventory.json`, so unrelated
   earlier branch history is not retroactively audited by this gate. This gate validates
   the contract's structure; reviewers still assess semantic completeness.
5. Native tests compile the actual production functions/helpers where feasible.
   A failing regression must demonstrate the boundary violation before the fix.
   Do not replace behavioral checks with source-string assertions or a copied model.
6. Hardware evidence must bind package/IPA hashes, physical iOS/jailbreak, profile
   identities, state transition, capture interval and transport. Keep credentials,
   raw private preferences and traffic bodies out of Git. Report sanitized field
   names/types and within-run fingerprints with provenance.

### Remaining on-device acceptance sequence

- Reconnect the authorized iPhone and record exact installed build/IPA hashes.
  Preserve user data and the existing recovery journal.
- Prepare two disposable fresh profiles A/B with valid proxy and managed per-app
  VPN association. Keep the existing CLOSED gate until all prerequisites pass;
  never disable enforcement to obtain a nominally successful test.
- Snapshot each fresh sandbox and accessible keychain/pasteboard/cookie/WebKit
  domains before launch and after first launch. Record created names/types,
  privacy-preserving fingerprints and the actual responsible SDK/call site.
  Distinguish generated, server-issued, restored and device-shared state.
- Start labelled captures before launch, binding the local A/B label at request
  creation. Exercise default/ephemeral/background/stream/upload/WebKit/native socket
  paths, DNS/DoH/QUIC/IPv6 and closed-gate failures. A capture limited to HTTPS via
  one library cannot clear other transports.
- Compare A → B → A, replacement, import, same-identity restore, failed restore,
  deletion and package upgrade. Verify both inherited state and erased state;
  test pending background work and delayed callbacks across each boundary.
- Validate native browse/login and browser callback ownership with the test
  account. Sensitive real account actions need a deliberate test plan. Collect
  actual per-SDK storage-to-send evidence before promoting SDK/STORE verdicts.
- Treat missing captures, unlabelled samples, opaque encodings, unresolved dynamic
  dispatch and incomplete MDM routing evidence as **NOT VERIFIED**. Publish no
  aggregate “all clear” while any relevant gap or unverified row remains.


### Reference interface and reviewed creation delta — 2026-09-19

The [13-screen feature map](docs/socialbox-reference-redesign.md) distinguishes
implemented, adapted and deferred controls. The [offline sketch](docs/socialbox-reference-preview.html)
uses synthetic data and is not execution or isolation evidence.

- **UI-002 / UI-003:** preparation creates a private candidate, followed by review,
  optional candidate edits and explicit Create. Token/revision, source, proxy and
  account binding are rechecked; commit consumes authority before clone effects.
- **UI-007 / UI-008:** Home, Containers and Location show selected state while retaining
  existing admission. Original App Store icon redirection and a no-MDM network engine
  are not implemented by this UI work.
- **UI-009:** HTTP list import previews and confirms one secure-record update without
  selecting a proxy, changing licenses or asserting per-container assignment.
- **UI-010 / UI-011 / UI-012:** conservative setup and app-scoped Cloud presentation,
  searchable catalog choices and organizational rename keep their existing authority
  boundaries. They do not prove that generated identities match real physical hardware.

The [current validation record](docs/leak-surface/reference-ui-validation-2026-09-19.json)
contains test scope/counts, commit-to-row mapping and explicit NOT_RUN physical work.
Earlier implementation commits in this delta omitted required Leak-Surface trailers.
Their supplemental mapping is recorded without rewriting history; it does **not** make
the historical per-commit gate pass. Future commits must carry their own correct trailers.

No original gap or unverified verdict is closed by these interface changes. Foreign
container data visibility, direct network escape and server-side account correlation
remain distinct questions. No new phone/traffic/account acceptance is claimed.

### Published Unit 30 declaration omission — 2026-10-01

Commit `954a52a73120988354416a0193e4e06f594add9b` omitted the required
`Leak-Surface: ADOPT-010, ADOPT-012` declaration. It was already exported when
the post-commit gate failed. The [supplemental own-commit mapping](docs/release-evidence/socialbox-saved-settings-retirement-audit-supplement-2026-10-01.json)
binds its original parent/tree/message and the three changed shipped files to
their existing evidence at that exact commit. Published history and the checker
remain unchanged. The historical per-commit gate remains **FAIL**; the supplement
does not waive it. A check beginning at this commit validates only later changes,
excluding this known omission. Host/UI acceptance remains separate, and client
release remains NOT_READY.
