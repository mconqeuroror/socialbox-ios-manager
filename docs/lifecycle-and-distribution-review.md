# Lifecycle, device licensing and distribution — completion and acceptance report

Date: 9 September 2026. Review branch: `feat/lifecycle-and-distribution`.
Implementation reviewed through `a7bca861b239556c1dad9fb5031d189b10b4b706`,
starting from `5e8fb90461212f91df797d8c3ac6ef5d371de5a3`.

**The requested implementation and detective fixes are committed and pushed.
The branch remains unmerged. Device acceptance is NOT RUN.** The cloud production
build passes locally. Windows checks cannot establish that an ldid-signed iOS
app installs, that MDM actually routes its traffic, or that Reddit login works.
No production release, real package installation or traffic capture was performed
during this batch.

This is the consolidated deliverable: changes and checks, findings with code
evidence, the ordered morning procedure, and ranked residuals. The expanded
[device runbook](on-device-smoke-checklist.md) and
[APT recovery/setup procedure](apt-distribution.md) provide operational detail.
The [earlier security review](phase2-phase3-review.md) remains relevant; its H08,
browser-authentication and recovery limitations have not become hardware PASSes.

**Subsequent compatibility work:** this report retains the original batch baseline.
See [rootless/rootful compatibility](jailbreak-compatibility.md) for the later
palera1n/Dopamine changes, their commits and pending device matrix.

## 1. Per-phase report

Every implementation commit below was pushed after its applicable checks passed.
`tools/static_check.py`, whitespace and the launcher/identity/clone/metadata
architecture checks were run after each commit. Additional checks are listed by
phase below. This report and the updated runbook form the final documentation
unit; they do not change the implementation SHA above.

| Phase | Pushed commit | Change |
| --- | --- | --- |
| 1 | `6d565af` | Organizational roles, notes, launcher controls and cloud reconciliation with revision checks. |
| 1 | `0261358` | Manual anonymous account-status viewer through the configured HTTP proxy. |
| 1 | `26c6211` | Durable replacement of inactive profiles; prepare candidate and rotate before old-profile deletion. |
| 1 audit | `e01c73d` | Recognize an already accepted metadata edit after its HTTP response was lost. |
| 2 | `4682c9d` | Cloud device-key generation, bindings, signed grants, administrator UI and frozen admin migration. |
| 2 | `3b9be9d` | Pinned native verification, activation UI, offline limits, active-session revocation and independent traffic deadline. |
| 2 audit | `986a51a` | Retire completed internal validation executions without allowing late callbacks to affect another request. |
| 3 | `70c3e58` | Version all shipped apps/package metadata; restrict package registration to the launcher and firewall host. |
| 3 | `ea63726` | Public APT package route, exact manifest validation, dedicated immutable Blob uploads and publisher locking. |
| 3 | `f72ea38` | Schema preflight/migration, guarded atomic publications, startup admission and post-update diagnostics. |
| 3 audit | `54071cb` | Prevent stale mutable APT indexes and verify publisher ownership before promotion. |
| 3 | `e14afae` | Signed one-command release, actual package inspection, staged verification, recovery journal and retention. |
| 4 | `d11caf4` | Protect both participants of unfinished replacements from Delete and nested replacement. |
| 4 | `6a310a5` | Export every eligible clone's MDM mapping even when the visible list has a role filter. |
| 4 | `0f5482c` | Preserve migrated-admin entitlement with a saved legacy key and bootstrap an unbound installation correctly. |
| 4 | `beb9b75` | Synchronize a newly created profile before first Open; explain retained local creation when cloud sync fails. |
| 4 | `1b310ad` | Keep newest request/alert evidence when bounded diagnostic buffers fill. |
| 4 | `a7bca86` | Show the signed offline-access deadline, including local date/time/timezone, on the license screen. |

### Phase 1 decisions

Roles are exactly `signup`, `warmup`, `spam`, `default`. They control labels,
filtering and optional grouping only. Notes allow 200 Unicode scalar values;
neither field changes identity, traffic authorization or isolation. Conflicting
cloud edits retain the local edit visibly until the operator resolves it.

Replace preserves name and role; notes and login start empty. Its ordered states
are `prepared → created → rotated → deleting → committed`. The candidate ID is
journaled before creation. The original remains intact through candidate creation
and a failed rotation. Candidate Open is denied until the replacement commits;
ordinary Open rotates again. A partially deleted original is recovered through
the existing H05 machinery, with evidence retained on failure. Pending originals
before deletion can still use permitted normal actions; either participant's
independent Delete and a candidate's nested Replace are refused.

Nonzero persistent identifiers are reserved against reuse, including existing
profiles when migrated. A catalog model/OS tuple can repeat; the blocked all-zero
IDFA remains a privacy sentinel. Values from profiles deleted before reservation
history existed cannot be reconstructed. Tombstones reserve IDs, not nicknames,
so same-name recreation gets a fresh ID.

Account status is an explicit, fresh, anonymous proxied request with no shared
cookies or credentials. The HTML is displayed as an inert snapshot: scripts,
subresources and outbound navigation are blocked. There is no scrape, automatic
polling, proxy rotation, direct fallback or automated account classification.
**A 404 alone does not establish shadowban status.** A bot challenge or a page
requiring JavaScript can be inconclusive and must be recorded that way.

Checks: actual cloud metadata/inventory/ownership fixtures; portable metadata,
replacement and viewer contracts; native source/fixture syntax. The replacement
fixture includes 21 transition cases and 43 ownership cases. Foundation runtime
execution remains part of the Mac build.

### Phase 2 decisions

Cloud `/admin` manages individual/bulk device keys, owner, label/note, expiry,
status, maximum activations (default one), bindings, history and last check-in.
Revocation and deletion retain activation history and device data. Re-enable
does not revive a deleted-key tombstone. The permanent admin exemption applies
only to the admin's token-paired devices captured by the frozen migration;
later pairing or merely knowing an installation UUID cannot acquire it.

The cloud signs RS256 grants with the deployment RSA private key. The build pins
the matching public key. Verification binds issuer, device ID, installation UUID
fingerprint, key fingerprint and request nonce. The installation UUID is held in
Keychain; activating a key also establishes cloud pairing. No separate pairing
code is needed on the fresh key-activation path.

Active grants last at most 72 hours from validation, shortened by key expiry.
The daemon checks every Open/switch, at a daily idle interval, and approximately
every 60 seconds while a clone is active. A transient network/429/5xx failure can
use a still-valid signed grant; it cannot extend the grant. Explicit signed
revocation/expiry/invalid status, bad signatures, bad bindings, clock errors or
unprovable persistence lock access. Retry timing is enforced locally and in the
cloud; activation is limited to five attempts per 15 minutes per installation.

Revocation closes the active session and terminates its clone once observed;
it does not let the session continue until the next switch. An independent gate
checks the signed deadline and limits the lease to it, even while the ordinary
work queue is occupied. Cloud revocation cannot reach a fully disconnected phone
immediately: its last valid grant remains usable only until its signed deadline.
This is the intentional offline-grace tradeoff, not instantaneous remote push.

The key screen, local setup and diagnostics remain reachable while locked.
License enforcement does not delete profiles or block unrelated daemon
maintenance. A separate schema/recovery safety failure may still refuse unsafe
mutations while allowing inspection.

Checks: 19 cloud device-license groups; authentication 18, concurrency 11 and
device-scope 7 groups; actual OpenSSL key generation/pinning; 19 executable C
presentation boundary cases. The native RSA, service-lifetime, offline/revoke
and migration fixtures compile against iOS headers; their Security/Foundation
runtime awaits macOS/iOS.

### Phase 3 decisions

The repository is flat at `/apt/redditbox/`. Small signed indexes ship as a
Vercel deployment snapshot; `.deb` bytes live under content hashes in a dedicated
**public** Blob store. The existing auth/backups store remains private. The
download route permits only exact package entries from the deployed manifest.

`bash scripts/release.sh [X.Y.Z]` authenticates the published repository, selects
a strictly newer version, builds via `build-mac.sh`, inspects the actual new
Debian archive, uploads immutable bytes, signs indexes, verifies a staged
production deployment, promotes it, verifies production, and prints publication
success. This follows Vercel's documented
[staged deployment and promotion sequence](https://vercel.com/docs/cli/deploying-from-cli).
A separate GPG key signs the APT archive. No Apple signing team is used.

Local process exclusion and a remote owner/ETag lock serialize releases. Failures
retain the journal, lock and artifacts; `--resume` continues the same operation.
Lost promotion acknowledgements are reconciled by verifying the live version.
Locks are never stolen automatically. The newest three versions remain indexed
and accessible through the repository filename route. Older immutable bytes are
retained at their Blob URLs, but an older cached index outside those three versions
may receive 404 from the filename route and must refresh its index. Generated
signed metadata must be committed on the future cloud deployment branch: an
unrelated deployment from an older checkout can still revert its indexes.

The package inspector rejects user-state payloads, imported/source/clone IPAs,
unsafe paths/links, unexpected components and unreviewed maintainer scripts.
Package maintenance restarts the daemon through H02 and narrowly refreshes the
two shipped app registrations; it does not globally unregister/re-register
clones or clean `/var/mobile` data. The signing-contract hash produces an explicit
MDM re-adoption warning when changed, including initial adoption. Clone bundle
IDs remain determined by profile ID.

Store/profile schema version is now 2. Startup establishes CLOSED, then preflights
all relevant live data and recovery evidence before forward migration. Newer,
corrupt or unsupported state stays intact and blocks unsafe startup work. Unique
temporary files, atomic replacement, stable locks and expected-byte comparisons
protect publications against lost updates. Unknown fields survive supported
migration. There is no reverse migration: selecting an older indexed package may
remain CLOSED if it cannot understand the current data. Legacy clone journals
without a provable install-attempt boundary require explicit recovery.

After successful startup recovery, diagnostics record
`update applied: vX.Y.Z, containers loaded: N` from the checked local inventory.
The update record is historical; later creates/deletes do not rewrite that
original count. Actual login/session retention through `appinst` and MDM still
requires an upgrade test with five real profiles.

Checks: 11 release test groups, including actual Debian parsing, actual GPG
signing/verification/tampering, three-version indexes, redirect-header isolation,
local lock exclusion and seven interrupted-publication boundaries; 13 mock Blob
publication groups plus route fixtures; version/signing tests; schema fixtures
and startup contracts. Live Vercel/Blob publication and Sileo installation were
not performed.

### Final verification boundary

At implementation SHA `a7bca86`, all 16 portable Python test files pass, as do
static/whitespace checks. All 24 changed production Objective-C translation
units pass syntax checks for arm64 iOS 15 using the iOS 15.6 SDK; existing
nullability warnings remain. All three changed Logos files preprocess and pass
Objective-C++ syntax. Relevant native test sources also pass syntax. Shell
wrappers pass Bash syntax checking.

The complete cloud production build passes with locked Next.js 14.2.35: compile,
lint/types, 25 static pages, optimization and tracing. Cloud suites use isolated
test storage; the release suite mocks publication calls. Windows required a
TypeScript test loader equivalent to the package's `tsx` entrypoints; the Mac
procedure runs the normal `npm test`. An initial native-check harness failure
for the service fixture was missing test-only macros; matching its real runner
resolved it without weakening or changing production code.

These are not a complete Mac build, Swift runtime test, iOS link, UI interaction
test, production smoke test or device acceptance. The Mac script runs the real
native fixtures before packaging; stop on their first failure.

## 2. Detective findings and first-run trace

“Break first launch” describes the defect or remaining boundary, not a claim
that a portable test proves the phone's behavior. Code links identify the
implementation path; named methods disambiguate longer files.

| Area | Break first launch? | Code-path evidence | Resolution / acceptance condition |
| --- | --- | --- | --- |
| Fresh install before VPN setup | No expected deadlock; hardware unverified | [NetworkGate](../daemon/RBXNetworkGate.m), `RBXPersistLease` and `waitForMaintenanceClosure`; [main](../daemon/main.m), `closeForLicense` | CLOSED can persist locally before an App Group exists. With no running clone/provider, maintenance and key activation can proceed; Open still requires strict provider proof. |
| License screen without connectivity | Yes, intentionally locked | [LicenseGuard](../daemon/RBXLicenseGuard.m), `_validateWithContext`; [LicenseViewController](../launcher/RBXLicenseViewController.m), `openDiagnostics/openSettings` | No prior signed grant means no unlock. Offline key/setup/diagnostics show the reason and bounded retry. |
| Saved legacy key on migrated admin | Yes, fixed | [device-licenses.ts](../cloud/src/lib/device-licenses.ts#L75); [Guard](../daemon/RBXLicenseGuard.m#L363) | `0f5482c`: exact authenticated frozen-admin entitlement wins; never-successfully-validated installations use claim even after an initial signed denial. |
| First Create followed by Open | Yes, fixed | [main](../daemon/main.m#L747), create success; [CloudSync](../daemon/RBXCloudSync.m#L1333), `syncRotationAuthForContainer` | `beb9b75`: creation attempts inventory publication before success. Cloud failure retains the local clone and says Refresh before Open. H17 binding is still required. |
| Proxy/source setup reachability | Yes if prerequisites fail; hardware unverified | [Settings](../launcher/RBXSettingsViewController.m), `testConfiguration`; [CloneManager](../daemon/RBXCloneManager.m), source import/validation | HTTP URL and separate rotation URL are required. Source must be readable/decrypted and physically OS-compatible. Failures keep launch denied. |
| Active Replace / failed rotation | No expected destructive regression | [Replacement](../daemon/RBXReplacement.m#L81), `RBXRunReplacement`, `establishClosureForJournal` | Active target rejected. Creation and successful durable rotation precede original deletion. Failure preserves recovery evidence; fixture/device interruption tests apply. |
| Delete/nested Replace during recovery | Yes, fixed | [Replacement](../daemon/RBXReplacement.m), `RBXReplacementMutationAllowed`; [main](../daemon/main.m), delete precheck | `d11caf4`: both pending IDs protected; only original ID resumes. UI offers Resume Replace. Ordered internal H05 deletion is still allowed. |
| Same-name recreation / identity reuse | No expected regression; historical bound stated | [ContainerRegistry](../daemon/RBXContainerRegistry.m), `reserveIdentityForProfile`, create/delete; [metadata](../shared/RBXProfileMetadata.h) | Tombstone excludes old ID; new generated ID may retain nickname. Identifier reservation history persists; pre-history deleted values cannot be recovered. |
| Role-filtered MDM export | Yes, fixed | [Launcher](../launcher/RBXLauncherViewController.m), `Share MDM/VPN setup`; [metadata contract](../tools/test_profile_metadata.py) | `6a310a5`: use full healthy snapshot, independent of visible role filter. New/replaced clones still need actual MDM adoption. |
| Role coupling / cloud edit conflict | No coupling found | [profile-metadata](../cloud/src/lib/profile-metadata.ts); [inventory](../cloud/src/lib/profile-inventory.ts); [native metadata contracts](../tools/test_profile_metadata.py) | Role/notes do not enter gate/proxy/identity decisions. `e01c73d` reconciles an accepted edit after lost acknowledgement without dropping newer local edits. |
| License revoked during Open | Yes, intended session closure; hardware timing unverified | [main](../daemon/main.m), `scheduleLicenseCheck/closeForLicense`; [NetworkGate](../daemon/RBXNetworkGate.m), heartbeat | Active polling detects denial; CLOSED/termination precede further use. Offline still-valid grants expire at signed deadline. No profile deletion. |
| Busy queue / stale UI / expiry | Yes, fixed prevention | [Guard](../daemon/RBXLicenseGuard.m), `trafficEntitlementValid`; [gate](../daemon/RBXNetworkGate.m); [presentation](../shared/RBXLicensePresentation.h) | Independent monotonic/wall deadline limits traffic; stale launcher snapshot cannot keep controls unlocked. `986a51a` removes retired internal execution retention. |
| Hidden offline deadline | Operator could misdiagnose lock, fixed | [LicenseViewController](../launcher/RBXLicenseViewController.m), `RBXLicenseScreenDeadline` | `a7bca86`: display signed deadline with timezone; display does not grant access. |
| Upgrade with five profiles | Unverified on hardware | [postinst](../layout/DEBIAN/postinst), [postrm](../layout/DEBIAN/postrm), [package inspector](../scripts/apt_repository.py), [main](../daemon/main.m), `recordAppliedUpdate` | Only shipped code/app registrations changed. Compare all five IDs, identities, metadata, sessions and MDM associations before/after. Count alone is insufficient. |
| Newer/corrupt schema / competing writer | Yes, intentionally fail closed | [DataMigration](../daemon/RBXDataMigration.m), `preflightAndMigrateWithError`; [DataSchema](../shared/RBXDataSchema.h); [ProfileIO](../daemon/RBXProfileIO.m) | `f72ea38`: preflight before writers, forward-only migration, atomic expected-byte publication; preserve failed/unsupported evidence and allow diagnostics. |
| Diagnostic evidence disappears at cap | Masks failure, fixed | [CentralStore](../daemon/RBXCentralStore.m); [RequestAudit](../tweak/LeakDetection/RBXRequestAudit.xm); [schema fixtures](../tests/test_data_schema.m) | `1b310ad`: seven request/alert sites remove oldest overflow. Actual store fixtures cover empty, cap, cap+1 and oversized history. |
| APT interruption / stale index / concurrent resume | Yes, fixed in implementation; live path unverified | [release driver](../scripts/release.py), `Publisher._run`; [publisher](../cloud/scripts/apt-publisher.mjs); [cache headers](../cloud/next.config.mjs) | Owner locks, signed baseline, immutable uploads, verified promotion, no-store mutable indexes and resumable journal. Preserve metadata in future deployment commits. |
| MDM managed flag versus VPN coverage (H08) | **Unverified, acceptance blocker** | [MDM exporter](../launcher/RBXMDMExporter.m); [provider](../network-extension/PacketTunnel/PacketTunnelProvider.swift); [device runbook](on-device-smoke-checklist.md) | Exported association intent and local “managed” status do not prove iOS routes this installation. Capture traffic and inspect effective VPNUUID. |
| Browser login / callback ownership | **Unverified, known open issue** | [auth hooks](../tweak/Container/RBXWebStorageHooks.xm); [CloneManager](../daemon/RBXCloneManager.m), preserved `CFBundleURLTypes`; [triage](on-device-smoke-checklist.md#first-login-triage--browser-coverage-and-callback-ownership) | Browser authentication may be blocked or callbacks may reach the wrong clone. Do not treat a wrong-clone kill as successful login. Candidate fixes below require actual OAuth contract and routing tests. |

Cross-feature conclusions: revocation does not block an ordinary package update
or remove profiles; restart re-establishes CLOSED before renewal. Replace while
licensing is stale cannot confer a launch grant: candidate and later Open still
face the license and traffic gates. Role-only profile changes retain canonical
ID/device ownership and tombstone checks. Existing multi-user routes remain
scoped to owner/device; no other branch was merged to obtain tester behavior.

## 3. Ordered Mac and phone morning procedure

Use disposable accounts/data for destructive lifecycle tests. Record PASS, FAIL
or NOT RUN with the built commit SHA and actual phone/iOS/jailbreak version.
The synthetic catalog describes spoof identities, not physical compatibility.

### A. Prepare, build and publish on the Mac

Use full Xcode, its iOS platform, Homebrew and a supported Theos/rootless setup.
The expanded [Mac procedure](on-device-smoke-checklist.md#mac-build--ldid-only-no-apple-team)
contains signer/version probes and source installation details. Run in Bash:

```bash
set -euo pipefail
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
brew install xcodegen libarchive ldid-procursus xz python node gnupg
npm install --global vercel
export THEOS="$HOME/theos"
export LDID="$(brew --prefix ldid-procursus)/bin/ldid"
export PATH="$(brew --prefix python)/libexec/bin:$PATH"
unset DEVELOPMENT_TEAM
if [ ! -e "$THEOS" ]; then
  git clone --recursive https://github.com/theos/theos.git "$THEOS"
  "$THEOS/bin/install-sdk" latest
fi
test -f "$THEOS/makefiles/common.mk"
test -x "$LDID"
git clone --branch feat/lifecycle-and-distribution --single-branch \
  https://github.com/typekpaco2002/redditspoof.git redditspoof-acceptance
cd redditspoof-acceptance
git rev-parse HEAD
node --version
npm --prefix cloud ci
npm --prefix cloud test
```

PASS: clean intended branch, initialized Theos/SDK, Node >=20, cloud suites pass,
and Procursus ldid supports shallow signing (`-w`). If ordinary Homebrew `ldid`
conflicts, follow the unlink/reinstall step in the expanded runbook. The
[Homebrew formula](https://formulae.brew.sh/formula/ldid-procursus) and
[Theos prerequisites](https://theos.dev/docs/installation-macos) describe those
external tools; their installed versions still need recording.

For a new deployment generate the device-license keypair once; otherwise reuse
the public key matching the deployed private key:

```bash
# New deployment only; the helper refuses to overwrite an existing keypair.
python3 scripts/license-key.py generate --directory "$HOME/.config/redditbox-signing"
export LICENSE_PUBLIC_KEY_FILE="$HOME/.config/redditbox-signing/license-public.pem"
test -r "$LICENSE_PUBLIC_KEY_FILE"
mkdir -p build/acceptance
python3 tools/static_check.py | tee build/acceptance/static-check.log
bash scripts/build-mac.sh 2>&1 | tee build/acceptance/build.log
```

Before activation, deploy matching cloud code with canonical `APP_URL` and
`LICENSE_SIGNING_PRIVATE_KEY`, retaining the existing private auth/storage
settings described in [cloud/README.md](../cloud/README.md). Do not replace
working auth data with seed fixtures. The key's private PEM stays outside the
checkout/public deployment; the phone receives the public pin only.

PASS: all native fixtures, Xcode archive, ldid verification and Theos package
finish successfully. No Apple team/certificate/provisioning download is used.
A missing/mismatched license pin is a build/activation failure, not a reason to
disable verification. Retain build logs and the actual package hash.

Configure a separate GPG key, dedicated public Blob store and the existing Vercel
project according to [APT preparation](apt-distribution.md#one-time-mac-and-deployment-preparation).
Supply actual deployment values and secrets from private local configuration:

```bash
export APT_REPOSITORY_URL="https://YOUR-CLOUD-HOST/apt/redditbox/"
export APT_BLOB_HOST="YOURSTORE.public.blob.vercel-storage.com"
export APT_SIGNING_KEY_FINGERPRINT="FULL_GPG_PRIMARY_FINGERPRINT"
export VERCEL_ORG_ID="YOUR_ORGANIZATION_ID"
export VERCEL_PROJECT_ID="YOUR_PROJECT_ID"
# Also load APT_BLOB_READ_WRITE_TOKEN and VERCEL_TOKEN securely.
# Set cloud production APT_BLOB_HOST to the same exact public store host.
# Unlock the GPG signing key in its agent before this noninteractive command.
export APT_BOOTSTRAP=1  # only for the first absent repo
bash scripts/release.sh 0.1.1
unset APT_BOOTSTRAP     # only after successful publication
```

For an existing repo use `bash scripts/release.sh` to choose the next version,
or specify a version greater than the authenticated published version. The
release builds again; the preceding standalone build was an optional earlier
build-only check. PASS: staged verification, promotion, production verification
and final `Published` output all succeed. Record any MDM re-adoption warning.
On interruption keep the journal and use `bash scripts/release.sh --resume`.
For an interrupted first release still in the `prepared` phase, retain/reload
`APT_BOOTSTRAP=1` in the retry shell; it still accepts only a fully absent repo.
Commit/push the exact generated `cloud/public/apt/redditbox/` indexes before any
later cloud deployment, leaving this review branch unmerged.

### B. Trust the source and install with Sileo/APT

Transfer the exported archive key and compare its full fingerprint to the
trusted release Mac fingerprint. In the rootless phone's root SSH shell:

```sh
mkdir -p /var/jb/etc/apt/keyrings
install -m 644 /PATH/TO/VERIFIED/redditbox-archive-keyring.gpg \
  /var/jb/etc/apt/keyrings/redditbox-archive-keyring.gpg
printf '%s\n' 'deb [signed-by=/var/jb/etc/apt/keyrings/redditbox-archive-keyring.gpg] https://YOUR-CLOUD-HOST/apt/redditbox/ ./' \
  > /var/jb/etc/apt/sources.list.d/redditbox.list
apt-get update
apt-cache policy com.redditbox
```

Open Sileo, refresh sources and install/upgrade the exact published version.
PASS: signature verification, dependency resolution and Sileo's flat-source
handling succeed; `dpkg-query -W com.redditbox` and Diagnostics match. APT fallback
is `apt-get install com.redditbox`; record Sileo as NOT RUN/FAIL if only that path
was tested. Do not bypass signature errors. First-install authorization and
rootless package dependencies remain hardware prerequisites.

### C. Activate and prepare the first container

1. In cloud `/admin`, create a **device license key**, max activations one,
   with the correct owner. On the phone open RedditBox, enter its HTTPS cloud
   origin and key, then Activate. PASS: signed activation succeeds, the device
   is paired once, and the empty launcher is reachable. A frozen pre-paired
   admin can use Validate paired device; no extra pairing code is required.
   First-run cloud outage must leave the key screen with an explanation and
   working local Settings/Diagnostics.
2. In Settings, set the proxy as
   `http://USER:PERCENT_ENCODED_PASSWORD@HOST:PORT` (or `http://HOST:PORT`
   without credentials). **H15 removed SOCKS5; HTTPS upstream URLs are also
   rejected.** HTTPS destinations still use CONNECT through the HTTP proxy.
   The rotation URL is a separate HTTPS endpoint with its configured method
   and credentials. Save and test intentionally closes traffic and rotates.
   PASS: rotation acknowledged, a usable changed exit observed, network remains
   CLOSED. Never paste `host:port:user:password` into the URL field.
3. Import the authorized, decrypted Reddit IPA through the source-import flow.
   The private source is `/var/mobile/Library/RedditBox/Source/Reddit.app`.
   PASS: source validates against the physical OS and a hidden clone can be
   built; no encrypted archive or globally shared source login is accepted as
   a successful isolated first run.
4. Set default role `warmup`, create `Lifecycle test`, add a short note and
   record ID, bundle ID and persistent identifiers. Keep it inactive. PASS:
   metadata appears, clone exists, cloud inventory binds it. If creation says
   synchronization is pending, retain it and use Refresh before Open.
5. Replace it before first Open. PASS: same name/role, new ID/bundle identity,
   fresh persistent identifiers, empty notes/login, old deletion only after
   successful rotation. Repeat with a deliberately failed rotation on disposable
   data: original survives, candidate cannot Open, Resume Replace keeps the
   journaled candidate. Delete/nested Replace on pending participants must fail.
6. Delete the completed disposable replacement, then create A and B, including
   reusing a prior nickname. PASS: H05 cleanup/tombstone preserved, new IDs,
   no identity reuse or resurrection on cloud Refresh. Do not Open yet.

### D. MDM association, capture, Open and login

1. Use **Share IPA** for each exact signed clone. Use **Share MDM/VPN setup**
   for the full inventory; test once with a role filter selected. The export
   supplies the VPN profile, clone bundle IDs and per-app mapping. Deploy/adopt
   those exact installations in MDM. Apply each bundle's
   `Attributes.VPNUUID` to the exported VPN UUID, and authorize all intended
   clone bundle IDs in the provider configuration. A replacement needs a new
   export/adoption. Keep launcher/host/provider outside the clone association.
2. Start the managed firewall and inspect the effective application attributes,
   provider status and CLOSED lease. PASS requires the same effective VPNUUID,
   exact clone bundle ID, fresh provider/daemon heartbeats and no active old
   process. **H08 remains open until routing is proved:** an exported mapping
   and “managed=true” alone are insufficient. The expanded runbook contains the
   [MDM command and payload checklist](on-device-smoke-checklist.md).
3. Start captures before A opens. On the Mac, substituting actual UDID/interface:

   ```bash
   export RBX_DEVICE_UDID="YOUR_ACTUAL_DEVICE_UDID"
   rvictl -s "$RBX_DEVICE_UDID"
   export RBX_RVI="INTERFACE_PRINTED_BY_RVICTL"
   sudo tcpdump -i "$RBX_RVI" -nn -s 0 -U -w rbx-ab-switch.pcap
   # Stop capture only after A → B → A and the failure tests.
   rvictl -x "$RBX_DEVICE_UDID"
   ```

   Identify the RVI created by `rvictl` rather than assuming `rvi0`. Retain
   daemon/provider logs and proxy-side connection/exit observations too. Capture
   both IPv4/IPv6, TCP, UDP/QUIC and DNS; protect raw captures containing proxy
   authorization. Logs alone do not prove absence of leaked traffic.
4. Open A, then B, then A. PASS order: CLOSED → old source/clone termination and
   socket drain → rotation request/acknowledgement → quarantine → changed usable
   exit → ARMED with matching epoch/generation/hook readiness → OPEN. No old
   account connection may survive into the new lease, and clone destination
   traffic/DNS must not go directly through the phone's ordinary egress. Test
   proxy failure, unchanged exit, provider death, daemon restart and removal of
   the actual MDM association. Any direct escape or unproven closure is FAIL.
5. Exercise password login, browse, post and vote using the actual source build.
   Record which actions were attempted. If browser login is required, keep it
   as a distinct acceptance case: it is not established by a successful native
   browse or account-status snapshot.

**Browser login open issue:** out-of-process authentication may be rejected or
cancel immediately because coverage is not proven. If a browser does run, a
shared callback scheme can open the source/wrong clone, leave the initiating
clone logged out, or produce a spinner/login loop. Retain auth/provider logs and
the initiating/receiving bundle IDs. Candidate fix: use a service-approved unique
per-clone redirect in both request and callback handler, or an authenticated
session-bound callback broker if the redirect is fixed. Both require state/
redirect validation and proven browser traffic coverage. Do not simply enable
unprotected Safari or remove shared schemes without checking the OAuth contract.

### E. Licenses, metadata and upgrade acceptance

| Test | Expected PASS |
| --- | --- |
| Fresh activation while cloud is down | Clear key-screen failure/backoff; Settings and Diagnostics usable; no containers opened. |
| Valid token, transient outage within 72-hour grant | Existing signed entitlement remains usable only to its displayed deadline; no extension by retry/restart. |
| Grant expired / revoked / invalid signature or binding | Key screen and CLOSED; active clone terminated when denial/expiry is observed; all profile data retained. |
| Repeated activation taps / reopen launcher | Durable request receipt prevents duplicate UI submission; local/cloud backoff honored. |
| Role/notes edited on cloud and phone | Correct colors/filter/default role; 200-scalar validation; conflict visible; no identity or traffic changes. |
| Anonymous account status | New cookie-free proxied request only on tap; no direct fallback; response status visible; 404/challenge can remain inconclusive. |
| Upgrade with five existing profiles | Publish next version, close active session, Sileo update; five identical IDs/identities/notes/roles and correct historical update count; verify each session and MDM mapping. |
| Downgrade/newer schema/recovery fault | Unsupported data preserved and CLOSED with diagnostic; never delete store/journals to force startup. |

## 4. Honest residuals, ranked

1. **Traffic enforcement on the actual jailbreak/MDM installation.** ldid,
   AppSync, managed adoption, effective VPNUUID, provider entitlement acceptance
   and failure behavior must be proved together with captures. Loss of mapping
   or provider is the most consequential acceptance boundary.
2. **Real Reddit login and browser callback ownership.** The first source build
   may require a currently blocked browser route. Native login/browse/post/vote,
   challenge handling and callback routing are not proven by this batch.
3. **Full Mac build and phone installation.** Windows syntax tests cannot find
   all Swift/linker/runtime/SDK/signing issues. Run every native fixture and keep
   the first failing build/install output. There is no certified Xcode/Theos/
   physical-device combination yet.
4. **Upgrade, rollback and retained sessions.** Actual clone sandbox/Keychain
   retention through appinst/installd and MDM re-adoption needs five-profile
   testing. A safety fence or unsupported legacy transaction may require manual
   recovery; there is no universally safe one-tap recovery reset.
5. **Real network stack and anonymous viewer.** CFNetwork proxy authentication,
   CONNECT, IPv6, UDP/DNS denial, captive/offline networks and inert WebKit
   rendering require captures. A visually successful page is not sufficient.
6. **License persistence and time behavior.** Verify Keychain entitlement access,
   stable installation identity across upgrade/reboot, signed-denial timing and
   active-session interruption. Offline grace intentionally delays observation
   of remote revocation. Monotonic checks protect the running boot; local device
   time and a privileged/jailbroken environment are not a tamper-proof licensing
   root of trust.
7. **Production distribution integration.** Local cloud build passed, but actual
   Vercel permissions/domain/pin alignment, public Blob credentials, GPG-agent
   signing and Sileo key/source handling remain untested. Retain the signed
   metadata for later deployments and the publisher journal for failures.
8. **Isolation limits outside the exercised paths.** Physical hardware/private
   APIs, attestation, out-of-process services and server-side account linkage
   need targeted observation. Existing `security.appAttest`/clipboard policies
   remain configurable where already supported; malformed/newer schema is never
   a reason to bypass guards. Synthetic identity is not a guarantee of universal
   unlinkability or of successful account login.

Acceptance evidence should include commit/package hash, Mac/Theos/SDK versions,
phone/iOS/jailbreak details, the exact source-app version, five-profile before/
after records, MDM association output, license cases, logs and packet captures.
Leave every missing or failed hardware case explicitly NOT RUN or FAIL.
