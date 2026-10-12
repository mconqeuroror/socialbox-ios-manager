# SocialBox → SocialBox recovery and adoption handoff

Date: 20 September 2026. Branch: `feat/lucid-base`, created and pushed from
`72899ee23f92cfe6d93a6c0f4b54bbf7232467ff`. Brand decision: **SocialBox**.

**Delivered so far:** the original binary recovery, all-component/all-slice
structural inventory, 73 bounded static mechanism reviews, and a new buildable
SocialBox presentation/evidence layer over the preserved base. The new derivative
is a private upgrade candidate, not a completed device-tested integration.
Original licensing and hosted services remain. The previous clone-only runtime
sentinel and network admission have **not** been ported into the recovered
data-switching backend; their earlier PASS results do not apply to it.

The owner no longer has original source and supplied an IPA after the handoff.
Both inputs were inspected. All 25 IPA files match the corresponding handoff app
files byte for byte; the IPA does not supply missing source or system services.
The handoff has enough surviving compiled code to recover a binary baseline.
It does not contain an original Xcode/Theos project, build recipes, server code,
or the complete original package-control set.

## Startup repair and distinct workspace — 23 September 2026

The `.12` private update is installed: 59 payload hashes match and global
container metadata is byte-identical. The missing `_Xd2z` startup registration
was the source of the old hardcoded brand. Startup and welcome now have
source-owned layouts, with the original live status/spinner and unchanged
license/delegate/completion paths. Overview uses a compact device profile,
ink/blue styling, an S mark and expandable identifier/tool/maintenance sections.

Five startup regressions failed before the repair; afterward 112 workspace and
202 installer/diagnostics/proxy assertions pass, plus 35 + 7 package groups.
Both arm64 variants build with ldid and all 15 original programs / 25 slices
remain byte-identical. Native previews are explicitly synthetic backend evidence.
The attempted physical foreground launch was rejected by SpringBoard with
`FBSOpenApplicationErrorDomain` code 7 (`Locked`), despite `uiopen` returning zero.
Cold-launch/cached-snapshot and original screen navigation acceptance are still
pending an unlocked foreground launch. This update changes no authorization or
network/readiness behavior and is not an APT publication or full app release.
See the [startup receipt](release-evidence/workspace-startup-2026-09-23.json).

## Owner contact and private admin — 23 September 2026

The `.11` candidate is now installed on the attached iPhone X / iOS 16.7.16:
all 59 payload files match and global container metadata is byte-identical.
The source-owned Home and Settings screens expose Contact @sctweaks,
opening Telegram with an HTTPS fallback. All 99 workspace assertions and seven
package composition tests pass. Physical foreground UI acceptance remains
separate; helper image mapping and a zero `uiopen` exit do not prove it.

The existing production domain now serves only the private owner license admin
and login as its website. Staging owner authentication/read-only listing and
production access controls pass. Both APT repositories and source archives are
unchanged. Original license-consumer interoperability and recovered isolation
remain unfinished (ADOPT-004 and ADOPT-003); this is not a complete app launch.
See the [release notes](socialbox-admin-contact-2026-09-23.md) and
[receipt](release-evidence/socialbox-admin-contact-2026-09-23.json).

## Original SocialBox interface — 23 September 2026

The `.10` private candidate replaces the appearance-only treatment with seven
source-owned workspace presentations. It uses a flat charcoal/mint visual system,
new Home/Settings/license/location layouts, compact container records and explicit
workspace actions. Original table delegates, conditional identity controls,
proxy-card interaction roots and sheet flows remain as backend adapters. This is
not a replacement of every recovered controller or its model logic.

Reviewed static prose, system permission descriptions, Files export and VPN
extension names now use SocialBox. Internal bundle/service identifiers, executable
names, export UTIs and authorization remain unchanged. Every original program
remains byte-identical, including its signature. Extension metadata changes are
accepted only when each original CodeDirectory leaves Info/resources unbound.
Unknown remote prose and unsupported runtime shapes remain acceptance residuals.

Host validation passes 196 existing plus 94 new UIKit assertions, 636 native
helper assertions, 35 recovered package groups and seven composition groups.
The arm64/arm64e ldid build passes independent readback of all 59 payload files.
The previews render production views with synthetic data, not an original
backend running on iPhone. `.10` is **not installed**: USB enumeration returned
no phone. Last physical package evidence remains `.9` below. This UI work adds
no data or network isolation claim; ADOPT-003 is still a gap.

See [the source/action contract](../lucid/Presentation/WORKSPACE_CONTRACT.md) and
[the build receipt](release-evidence/workspace-ui-2026-09-23.json).

## Original helper positive IPC acceptance — 22 September 2026

The `.9` private build is installed. The original helper now performs a single
read-only `check` after its verified method installation. On the physical
phone, helper and service emitted matching request nonces and the helper
reported `service_authenticated=yes`. This positively verifies the approved
helper's kernel-token/file authentication and the response path, complementing
the unrelated-root rejection tested in `.8`. No target app is resolved, stopped
or switched by this check. It does not change any network/readiness flag.

All 59 installed hashes match and global metadata is byte-identical. The 636
native helper assertions, 33 + 7 packaging groups and static checks pass.
The 129 protocol and 87 client assertions also pass on the iPhone; their mocked
transport tests are distinct from the original-helper round trip above. Both
architectures build with ldid. See [the physical receipt](release-evidence/service-check-2026-09-22.json).
Actual manager UI/licensing, real app switches, cross-container canaries and
network enforcement remain separate unfinished work; this is not a completed
isolation or forty-container acceptance claim.

## Installed caller authentication repair — 22 September 2026

The `.8` private candidate is installed on the iPhone X / iOS 16.7.16. The
privileged drain service previously accepted any root-owned, non-writable
program at an approved caller path. It now verifies the exact original byte
length and SHA-256 through a checked descriptor and resolves the same kernel
audit token again after hashing. Changed bytes, a replaced file and a caller
that exits or execs during that check are refused. No original code, licence
routine, entitlement or target-app filter is changed.

The peer regression failed before the fix. The full native helper suite passes
569 assertions; the unchanged drain suite passes 281, packaging passes 33 + 7
groups, static checks are clean and the leak contract passes eight tests.
The new 53 peer and 45 filesystem assertions also pass on the physical iPhone.
A separate invocation of the production verifier accepts both installed original
caller files. All 59 installed payload hashes match, all 15 original programs
(25 slices) remain byte-identical, and global container metadata is unchanged.
The running `.8` service refuses an unrelated root client with its own rejection
log. See [the receipt](release-evidence/caller-pinning-2026-09-22.json).

The new foreground launch attempt is still explicitly denied by iOS because
the device is locked, despite `uiopen` returning zero. Facebook, Reddit,
Instagram and X were absent from its application registry. These results do
not establish a positive manager/helper request, original UI operation, target
switches, 40-container acceptance or network containment. Current disk bytes
and a kernel identity are not an in-memory attestation. The unacknowledged
global/deactivation/batch storage paths remain unfinished; ADOPT-003 stays a gap.

## Real installer transition repair — 22 September 2026

The first physical `.5` upgrade passed external preflight but failed in the
incoming preinst: our guard rejected dpkg's transitional old-package status.
Both original and separate source packages were restored by the prepared private
recovery packages; no data was purged or dpkg status records edited. `.6` now
allows that state only at the incoming-preinst boundary. External preflight
requires a fully installed baseline, and all version, byte, control and path
checks still apply. This follows the [maintainer-script upgrade order](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html).
The regression failed before the fix; all 32 package groups and five helper
composition groups pass afterward. Both boundaries were checked in the actual
`.6` archive. See [the receipt](release-evidence/dpkg-transition-2026-09-22.json).
The `.6` package subsequently installed on iPhone X / iOS 16.7.16. All four
owned services run, all 58 installed hashes match, and original global metadata
is byte-identical. The empty separate source package was removed without purge;
its library/source data remain. A private 358 MB backup and both recovery
packages are retained. Original app injection/target/network acceptance is
recorded separately from successful package installation.

## Global metadata write fix — 22 September 2026

The `.5` private candidate replaces the original manager's global metadata
writer and mutator. Failed lock acquisition and corrupt existing data now stop
the write. Serialization, checked file sync and atomic rename share one lock;
post-rename durability failure is reported without claiming rollback. All 80
filesystem checks and 27 actual Objective-C adapter checks pass on Mac and on
iPhone X / iOS 16.7.16, including forty concurrent updates and real interruption
before/after rename. The existing 175 per-app checks also pass on that phone.
The actual `.5` service passes boot/rejection/cleanup and independent readback
verifies all 58 packaged files and unchanged bytes of 15 original programs.
This remains a single-file fix: other writers, outer error propagation, launch
fencing and network enforcement are separate integration work. See
[the implementation](../lucid/HelperSafety/GLOBAL_METADATA.md) and
[the receipt](release-evidence/global-metadata-2026-09-22.json).

## Per-app stop failure fix — 22 September 2026

The `.4` private candidate adds a source-owned adapter at the exact per-app stop
callsite. A failed checked drain now takes the original worker's pre-write
failure cleanup instead of acknowledging the stop and allowing active-data
changes. The old helper BOOL is never trusted by this path. Unrelated getter
calls are unchanged. Both original architecture boundaries are mechanically
verified, and 175 regression checks pass on the Mac and in a synthetic host on
the iPhone X / iOS 16.7.16. The `.4` service boot/rejection/cleanup test also passes.
Global/deactivation/batch writers and full network/storage isolation remain open;
this is not a forty-account or original-worker runtime acceptance result. See
[the per-app implementation](../lucid/HelperSafety/PER_APP_STOP.md) and
[its receipt](release-evidence/app-switch-safety-2026-09-22.json).

## Checked helper integration — 22 September 2026

The new source-owned [helper adapter](../lucid/HelperSafety/README.md) and private
`.3` candidate now connect the recovered one-BOOL stop method to an authenticated
Mach service. The exact main-app registry includes 16 original filter targets,
including Instagram and Threads. This avoids original SIGCHLD/waitpid behavior
without changing original program bytes, entitlements or licensing. There are
211 passing protocol/client/method/peer checks plus the existing 281 drain
checks, five new package-composition checks and 31 existing packaging groups.
The service booted and refused an unrelated root peer on iPhone X / iOS 16.7.16;
its temporary service was then stopped. Original helper injection, actual target
stops, checked storage transactions and network containment are still not device
accepted. The `.3` candidate is not installed. It is engineering progress on the
privileged stop boundary, not completion of the original worker-error propagation.

## Current implementation update — 21 September 2026

**22 September backend implementation:** [the process drain unit](../lucid/Switching/README.md)
is now an executable source-owned replacement operation for the recovered base,
with a private `socialbox-drain` root CLI and arm64/arm64e ldid build. It resolves
registered Reddit/Facebook main and extension executables, uses the stronger
task-right identity primitive, and requires two complete absent observations.
Its 46 orchestration + 235 Darwin-adapter assertions pass with mocked OS
boundaries; the existing 221 process identity assertions also pass. The CLI does
not run imported code or change storage/network/identity state. It is not included
in `.2` and is not yet consumed by the original switch workers. Actual device
permission/exit tests and acknowledged storage-switch integration remain open;
this is a concrete backend prerequisite, not a completed isolation port.

The subsequent [process-identity stop repair](process-identity-stop-2026-09-21.md)
is now linked into the source-owned SocialBox daemon and builds for both iOS
architectures. It removes numeric-PID termination after stale app selection;
221 primitive checks and the controller/coordinator regressions pass. A second
repair binds launch and observer authority to kernel process birth, rejecting
same-PID relaunches under old authority; its failing-first launch/observer tests
and coordinator Thread Sanitizer run pass. The periodic observer is not a
zero-packet-leak guarantee. These are prerequisites retained from our stronger
source implementation, **not a completed
port into the preserved SocialBox helper**. Device task-right compatibility is
NOT_RUN, the original entitlements are unchanged, and `.2` is not rebuilt or
installed by this unit. The acknowledged recovered switching/admission work
described below remains open.

The source-owned sentinel now also binds current reports to that daemon-owned
process birth and rechecks launch authority after observation. Its actual-controller
regression reproduced same-PID report reuse before the fix and passes 66 checks
afterward. This is not installed in the recovered backend and does not change
the integration status below. A second sentinel repair makes quarantine/alert
publication checked and journaled before consuming a report; its expanded 98
assertions cover restart evidence and failed writes. Both source-owned daemon
architectures build, with unchanged entitlements. See
[the sentinel acceptance contract](isolation-sentinel.md). No recovered `.deb`,
APT publication, device installation or original backend patch is claimed.

**Whole-app integration remains incomplete.** The new `.2` candidate adds two
implemented units, rather than treating more static inventory as a finished app:

- **`cba26ad` — eighteen-screen presentation extension.** Original five-tab order
  is unchanged. Configuration, model/iOS/country/carrier pickers, app selection,
  backup/Cloud screens, details, bulk proxy import and the licence screen now
  receive guarded styling. Only the exact inert licence heading is renamed;
  activation fields, actions and locked/disabled state are preserved.
- **`5dc5dc8` — proxy input integration and verified build provenance.** The linked app-only module reuses the SocialBox
  HTTP parser and calls the original typed proxy methods. Recognized HTTP proxy
  URLs no longer fall into the subscription downloader; HTTPS retains its TLS
  flag. Raw credentials and URL-encoded credentials are handled separately,
  malformed inputs are rejected, and validation precedes all batch additions.
  Original persistence/connection handling remains. A reproduced UIKit error
  dismissal race and an off-screen delayed-alert regression were fixed.

The final combined synthetic UIKit run has **196 passing assertions**; the
native proxy module has **139 passing assertions**. Existing HTTP proxy and
45-case proxy-import suites pass. The package and its current validation receipt
are recorded in [the new candidate receipt](release-evidence/socialbox-recovered-candidate-2026-09-21.json).
These tests execute source-owned code and synthetic host controllers, not the
original jailbreak daemon, target-app hooks or production account flows.

Two concrete remaining integration problems are now established:

1. [Original admission consumers](../lucid/Diagnostics/RECOVERED_ADMISSION_CONTRACT.md)
   use a different compiled public signing key, message format and hosted-session
   contract. The original app, daemon and injected engine each enforce a part of
   admission. The source-only SocialBox exchange has not been connected across
   those boundaries. Original valid licensing remains the current engine path;
   the existing SocialBox web licence alone is not a substitute.
2. [Switching interposition](../lucid/Switching/INTERPOSITION_BOUNDARY.md) identifies
   an ignored `waitpid` result, discarded stop acknowledgements and direct
   creation/import writers outside a switch-button wrapper. A callback wrapper
   cannot establish stopped processes and atomic storage transitions. A complete
   source-owned transaction boundary and real target-app tests are still needed.

The stronger SocialBox runtime sentinel/network enforcement is still preserved
in its original source, **not ported into this recovered backend**. No network
containment or cross-container runtime result is promoted to PASS. The remaining
work includes replacing the unacknowledged privileged transaction path and
integrating all admission consumers, with regression coverage of those paths.
This is unfinished engineering integration, not merely a remaining visual check
or a claim that reconstruction is impossible.

The Mac reported no USB iPhone in `idevice_id -l` during this pass. Installation,
original injection, licence/Cloud operation, measured network leakage,
cross-context canaries and forty real contexts remain **NOT_RUN**. The package
is a private, unvalidated exact-base upgrade; its preflight/migration constraints
still apply. No APT production package, license key or server was replaced.

## Delivered units and checks

1. **`7954256` — binary recovery tooling and baseline.** Pushed. The CLI pins
   input SHA-256, rejects unsafe archive paths and special files, checks CRC and
   manifest hashes, compares the IPA, checks decompiler block addresses, scans
   every Mach-O slice and reconstructs a deterministic `.deb` without executing
   any imported program or installer. Six focused tests PASS; independent review
   found no critical construction flaw for these pinned inputs. Two real runs
   produced identical inventory, private full inventory and package bytes.
2. **This report and its evidence register.** Three independent bounded reviews:
   23 identity/storage categories, 25 UI/container/Cloud/location mechanisms and
   25 network/lifecycle mechanisms. UI family enumeration includes 65 families /
   2,498 indexed methods; index-only entries are explicitly not behavior proof.
   The comparison register retains all 382 SocialBox rows: 50 have explicit
   static comparison links and 332 remain NOT_REVIEWED. **Zero ports are marked
   complete.** This is not the requested exhaustive semantic audit of every hook.

For those first two units, `tools/static_check.py`, native `test_launch_safety.sh` and native
`test_firewall_policy.sh` PASS. Recovery-specific tests also PASS. The existing
leak register remains unchanged. The full SocialBox native/build battery was not
rerun for this tooling/documentation-only change; the earlier 0.1.39 build result
is recorded in [its handoff](socialbox-0.1.39-device-handoff.md), not attributed to
the recovered SocialBox package.

## Source-owned candidate added after recovery

**`af935f4` — guarded presentation/evidence candidate and upgrade builder.**
Committed and pushed to `feat/lucid-base`; the branch is not merged. Original
SocialBox native regression entrypoints, the new native adapter/assessment
suites, static checks and the leak-surface change gate pass. Evidence below
records scope; no host success is counted as physical-device acceptance.

The new `lucid/` module is an actual arm64/arm64e Theos/ldid build. It retains
**Home → Containers → LocSim → Proxy → Settings**, uses a dark teal/navy/violet
presentation, replaces known inert Home branding with SocialBox, and adds an
Isolation checks screen under Settings. Existing controls, callbacks, field
values, action menus, map/location behavior and semantic status colors remain.
The known app icon/display name is SocialBox. In this first candidate,
licensing-screen branding remained unchanged; the subsequent eighteen-screen
unit above maps and renames its exact inert heading.

This is not generated pseudocode presented as original source. The 15 original
programs retain their exact executable/signature bytes; the new presentation
and diagnostics implementation is maintained as normal source. Neither
entitlements, target-app hooks, original identities, accounts, stored containers,
licence state nor server endpoints are patched by this unit.

The metadata adapter validates actual getter encodings and implementation images,
requires an already-existing controller on the main thread, and never calls
`loadData` or a singleton factory. The target-app manager's active ID updates
before its path; this prevents treating the ID as a completed-switch receipt.
See [the exact recovered context contract](../lucid/Diagnostics/RECOVERED_CONTEXT.md).
Diagnostics therefore distinguishes cached selection from runtime evidence;
all eight runtime families remain NOT_RUN. Export omits personal fields.

New source validation: **185 adapter assertions, 204 assessment assertions,
107 synthetic UIKit assertions**, plus both architecture builds. The UIKit run
includes forty rows, original actions/fields/delegates, navigation back from the
actual diagnostics view, unavailable metadata, all eight NOT_RUN rows, and report
redaction. Six visibly stamped screenshots are retained privately; they are
synthetic host screenshots, not images of the recovered suite running on iPhone.

The existing SocialBox regression run now has **138 passing check entrypoints**,
listed individually in [the host-check receipt](release-evidence/socialbox-recovered-host-checks-2026-09-20.json).
Six initial environment failures were rerun after loading the existing Theos /
libarchive configuration and passed without source fixes. No prior network or
storage policy was weakened to make a check green. Source inventory gating now
includes the actual `lucid/` production files, with separate ADOPT-001–003 rows.

Build/reproduction/deployment details are in [lucid/README.md](../lucid/README.md).
The private candidate is `socialbox-owner-base-unvalidated.deb`, package version
`3.1.0-1+socialbox.1`, 10,875,598 bytes. SHA-256:
`8abd05829d51146fbb45d95ce0d29c0dfe55f545a32d15ea49ecca632c6750ad`.
The [candidate receipt](release-evidence/socialbox-recovered-candidate-2026-09-20.json)
records source hashes, both overlay slices, the original fifteen programs,
independent archive verification and all 23 packaging test groups. Its 53 payload
files comprise 48 unchanged originals, a display/icon-only Info.plist change,
two icon files and the app-only overlay/filter. No original program was re-signed.
It has not been installed or published to APT.

The new candidate builder includes its own narrow maintenance scripts, not the
original broad postinst. Independent review reproduced failed-upgrade service
loss and unsafe destination/alias acceptance in its first draft; those cases
were fixed with failing-first regressions. The final builder's **23 behavioral
test groups pass**. The original postinst also lacks
an action guard: dpkg can call it during rollback even though our builder never
executes it. The builder now emits a narrow rollback script and exact backup /
replacement preparation manifest. Preflight refuses installation until that
separate mitigation is applied and verified. This ordering follows the official
[Debian upgrade/unwind procedure](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html#details-of-unpack-phase-of-installation-or-upgrade).

### Morning device sequence

1. Connect/unlock the phone and establish its actual package, bootstrap and
   installed maintainer-script state with read-only checks. The last observed
   phone had both SocialBox and `com.redditbox`; preserve both sets of data and
   resolve that coexistence before this exact-base upgrade can pass preflight.
   Removing the old SocialBox package alone does not verify stopped clones or
   tunnels and does not migrate its accounts, containers, sources or licences.
2. Review any installed old controls missing from the handoff. Preserve the
   original postinst backup and apply the narrowly scoped rollback mitigation;
   run the emitted preflight **before dpkg**, then perform the reviewed upgrade.
   The emitted rollback postinst handles dpkg abort recovery only. The original
   recovery `.deb` contains unsafe legacy scripts and is not an automatic
   post-install rollback; test disabling only the added overlay on-device.
3. Verify installed hashes, overlay dependency loading, base startup/licensing,
   five-tab order, menus, icon and diagnostics. Capture the real screen.
4. With disposable contexts and no personal account credentials in diagnostics,
   test create → switch A/B/A → close/reopen, interrupted switching, proxy and
   location behavior. User performs account login. Keep each failed or unrun
   check explicit, including any original-server dependency failure.
5. Run witnessed in-target data probes and independent traffic measurements
   before describing isolation/network containment as verified. Scale to forty
   contexts only after that basic lifecycle passes. Host rows are not forty
   verified logged-in accounts.

The requested full merge of stronger SocialBox runtime protections, a replacement
for original licensing/server logic, complete rebranding of unknown UI, network
fail-closed acceptance and physical installation are still unfinished. The
candidate is an implementation step, not a declaration that the whole request
is complete or that the morning can be reduced to an untested install.

### Follow-on source authorization unit

**`c1ddb1d` — source-only SocialBox licence exchange adapter.** Committed and
pushed without merging. This reuses the existing signer protocol and pinned
`RBXLicenseToken` verifier, with one-use nonce/revision/endpoint binding and
signed expiry/denial handling. Independent review reproduced and fixed trailing
line-separator acceptance and verification-time expiry/configuration gaps.
**109 native assertions**, the existing **23 signed-token cases**, architecture
contract, static checks and both production architecture compiles pass; test
key/clock selectors are absent from the production objects. See the
[receipt](release-evidence/socialbox-authorization-adapter-2026-09-21.json) and
[adapter contract](../lucid/Authorization/README.md).

The adapter deliberately performs no transport, credential storage, original
engine call or admission. It is **not linked into the `.deb` above**. Therefore
this source unit does not turn the original engine's activation green or make
its hosted services compatible with our cloud. Those are separate integration
tasks. Existing keys and production services were not changed.

The [recovered original licensing contract](../lucid/Diagnostics/RECOVERED_LICENSE_CONTRACT.md)
now includes all three previously omitted response/persistence methods and the
daemon's approval dispatcher. It distinguishes display configuration, the
automation device token, and the encrypted signed-token/signature store. Both
response processors can report success without a signed pair; persistence is
void or asynchronous and supplies no verified engine-approval receipt. Original
challenge verification still runs separately. These recovered field names and
callback encodings enable further integration work, but do not establish that
the original consumers accept the SocialBox JWT. No synthetic approval response
was sent and no original token store was changed.

The missing global switching worker has now been recovered into a separate
private supplement. The [completed-switch contract investigation](../lucid/Diagnostics/RECOVERED_SWITCH_CONTRACT.md)
confirms discarded kill-wait/helper errors, per-app write failures that do not
reach the global completion, a same-ID fast-success path, and success delivered
after releasing the switch lock. Its current callback is not a process/path/
generation-bound storage receipt. These are static findings, not reproduced
device leak results. The old archive's unresolved-worker references below are
historical; the supplemental recovery closes that visibility gap, but does not
fix the original switching implementation. A safe stronger sentinel needs a
source-owned acknowledged transaction boundary, not just another ID getter.

## Inputs and reconstructed package

- Handoff SHA-256:
  `8730c17abbfb8cf12fbbbe19669120e5266b1782dd2a34f814ef0fab557187a2`.
- IPA SHA-256:
  `91f011992565e9f38a41a74abafc0864e664608ee0d9a2e0e47aefb47f77adeb`.
- Recovery package SHA-256:
  `9f042a879149b1fbfd40c842a52fceb45ca9d49dc9d3a77950fd60139dcb3bc7`.
- Package size: 10,785,358 bytes. Identity: `com.socialbox`, version
  `3.1.0-1+recovery.1`, rootless `iphoneos-arm64`, iOS 16 minimum.
- Local private output: `work/private-socialbox-adoption-2026-09-20/recovery-output/`
  relative to the enclosing workspace. Package file:
  `socialbox-original-binary-recovery-unvalidated.deb`.

All 49 available payload files and both original postinst/prerm scripts match
their input hashes when independently read back out of the `.deb`. This is not
the original `.deb`: control metadata/checksums were reconstructed, and the
legacy iOS 15 FileProvider and original preinst/other unexported controls are not
invented. Executables retain original bytes and signatures; they were neither
recompiled nor re-signed. No Apple development team is needed to preserve these
bytes. Their effective on-device signature/entitlement behavior is NOT_RUN.

The original postinst contains broad process cleanup, system-service operations,
permission changes and an unauthenticated dependency-install fallback. It was
preserved as an input artifact, never executed. The generated package is not in
SocialBox APT/Vercel, and was not installed on the phone. Reinstalling unchanged
binaries over the phone would not deliver the requested update.

Reproduction and exact package differences:
[recovery instructions](socialbox-adoption/README.md). Full component/file hashes,
load dependencies, filter plists and original entitlement declarations:
[binary-baseline.json](socialbox-adoption/binary-baseline.json).

## Phase 1 — licensing and startup

**Recovered-engine licensing integration: NOT_IMPLEMENTED.** No always-valid patch or replacement
credential was generated. The current SocialBox license root and cloud signer
were preserved. SocialBox's original licensing remains in the recovery package.

The supplied readable pseudocode deliberately omits 153 auth/licensing-named
functions. Those functions still exist in the original binaries, disassembly
and Ghidra project. Name omission is not code removal. The app's inspected
`AppDelegate::_sF2` (`0x10003a010`, `SocialBox.c:688`) checks cached state;
`_sF1` (`0x10003a0a8`, line 717) invokes the protocol client with a completion;
`_sF8` (`0x10003c538`, line 1832) installs recurring validation;
`_sF5` (`0x10004a500`, line 1860) selects an entry root. The supplied auth report
also describes integrity/IMP checks during startup. Changing a single return
value would not supply missing identity, feature or hosted-service state.

Creation/switch and Cloud have their own helper/daemon/client interactions
(UI-03, UI-08, UI-13–16 below). Removing an entry screen is insufficient to prove
they work. The supplemental recovery above now distinguishes the immediate
request, response and persistence contracts. The next licensing unit must
establish verified engine consumers, feature admission and hosted authentication
across that boundary. Existing server-side authorization cannot be removed by
editing only an IPA. Source can be reconstructed module by module from behavior
and binary evidence; original source cannot be recreated exactly by renaming
the Ghidra `.c` files.

This is an integration gap, not a claim that a new legitimate licence client is
impossible without the old server's private key. SocialBox already has its own
client, signer and pinned JWT/device binding contract in
`daemon/RBXLicenseGuard.m:369–399`, `daemon/RBXLicenseToken.m:61–103` and
`cloud/src/lib/license-signing.ts:6–36`. The original app **and daemon** independently
verify signed server challenges (`SocialBox.c:138665–138686`,
`secretsauced.c:9471`); accepting a SocialBox JWT in an added screen would not
authorize those unchanged implementations. Original response/persistence methods
at `0x10016285c`, `0x100164e9c`, and `0x1001d6158` have now been recovered;
their session/product/device/approval contract has not been integrated or tested
against our cloud. The original server implementation, operational configuration and
validated responses are absent from the handoff. No existing signer was replaced.

Identity generation is also not wholly dependent on a missing server:
`_Xw4g::generateDeviceProfileForSeed:` has local model selection at
`SocialBox.c:473698–473705` and carrier selection at `477175–477182`. Those
mechanisms are preserved in the original program; their existence is not proof
that activation, Cloud restore or target-app identity state are ready.

**Static load inventory: PASS, with limits.** Fifteen components / 25 retained
architecture slices parse. All structural selector/class/Swift references
resolved in the scanner. This establishes file structure and declarations,
not successful loading of injected code on a device. The 15 components are:
the app, CLI, helper, two daemon executables, FilesProvider and PacketTunnel
extensions, plus SocialBox, Accountsd, CfPrefsd, Containermanagerd, Lsd,
MediaServerd, Securityd and SpringBoard libraries.

Counts across all slices (repeated architecture references included): 13,429
selector references, 1,180 class references, 357 class definitions, 5,639 imported
symbols and 16,964 method-name strings. The supplied function indexes cover
18,025 successful pseudocode exports, 3,883 external/thunk entries, 153 omitted
named auth entries and three unresolved routines. Mechanical completeness of
these tables is not semantic completeness of an isolation review.

## Phase 2 — architectural findings

The central difference is **original-app data switching** versus SocialBox's
current separately signed clones. SocialBox's app catalog can include several
original apps in one selected context. Its privileged path works with installed
apps' `dataContainerURL`, Keychain, metadata and filesystem redirection, and
injects system brokers. SocialBox's existing per-app bundle, keychain and signed
sandbox assumptions cannot simply be copied into those brokers.

Concrete review leads, not reproduced runtime leaks:

- UI-09 / DRT-NET-023: the central global switch worker was unresolved in the
  original export and is now recovered in the supplement above. Discarded
  helper/write errors and callback ordering still prevent treating its success
  as verified process termination and durable per-app storage completion.
- DRT-NET-015: host stop completion uses a fixed 500 ms callback. It is not
  demonstrated to acknowledge provider shutdown or drained old flows.
- DRT-NET-017: one helper switch endpoint returns an explicit 501
  “Not implemented (Phase 2)” error. A different app-driven path exists;
  this does not mean every UI switch invokes the stub.
- DRT-NET-004–008: IPv4 default routing, a local HTTP(S) bridge and TCP/SOCKS
  transport are present. Broad route exclusions, conditional DNS interception
  and no demonstrated full IPv6 capture prevent a complete egress claim.
- DS-01/02/08/09: inspected identifier/carrier/timezone branches can return
  original values when replacement state is absent. Reachability with an
  intended enabled profile needs testing.
- DS-10: the inspected pasteboard installer suppresses seven read selectors;
  that is not a demonstrated private writable clipboard across all API families.
- DS-11–19: service request identity, cached PID state, Keychain entitlement
  responses and CFPreferences path rewrites need caller-bound, concurrent A/B
  tests. Broad query branches are test targets, not a proven cross-account read.

Detailed findings preserve exact component/address/line references. Paths named
`decompiled/...` refer to the hash-pinned private handoff, not original source:
[identity/storage](socialbox-adoption/identity-storage-findings.json),
[network/lifecycle](socialbox-adoption/network-lifecycle-findings.json),
[UI/containers/Cloud/location](socialbox-adoption/ui-container-findings.json).

## Phase 3 — integration decisions and dependencies

**Completed merged extras: none.** The recovery tool, inventories and comparison
register are developer artifacts; they do not add runtime isolation. The
[382-row comparison register](socialbox-adoption/comparison-register.json) keeps
unknowns visible and does not alter `LEAK_SURFACE.md` verdicts.

- Retain SocialBox's immutable per-profile identity, consistency checks and
  readiness contracts as source-backed candidates. Adapt to SocialBox's selection
  authority only after recovering exact persistence/response formats. Do not
  regenerate existing identities during a switch.
- Retain exact app/host matching, nested payload handling and Keychain result
  validation as port candidates. SocialBox's service-side entitlement rewriting
  cannot inherit clone-side proofs; all broad query, result and persistent-ref
  cases require independent tests in the recovered architecture.
- Retain SocialBox's wider pasteboard API policy and sibling sentinel as
  candidates. Install only one authoritative hook implementation per API, with
  tested original-pointer chaining. Merely loading both products is not a merge.
- Retain CLOSE → verified process termination/drain → rotate → ARM → OPEN as
  an admission requirement. Investigate the recovered packet tunnel as transport,
  not a substitute for independent enforcement. **NET-040 stays GAP**; the user
  has no MDM, and a working personal VPN alone does not prove per-app fail-closed
  behavior after crash, route changes or proxy loss.
- Preserve current license/signer/web/Cloud data. Recover the archive/envelope,
  identity and remote-operation contract before connecting reference Cloud flows
  to SocialBox's server. Unknown payload fields and crypto parameters must not be
  guessed or answered with fabricated success.
- System-broker hooks and original-app sandbox extensions are conditional reuse
  candidates. Their broader authority and global state require own-vs-sibling
  path, extension, XPC identity and delayed-callback tests before adoption.

These choices select review/port boundaries, not a declaration that one product
is universally stronger. Existing SocialBox Facebook filesystem and launch
acceptance issues remain open as recorded in its own ledger.

## Phase 4 — re-skin decision

**Source-owned overlay: IMPLEMENTED; complete rebranding: PARTIAL;
recovered-device rendering: NOT_RUN.** The `af935f4` unit adds the guarded
SocialBox presentation, existing SocialBox icon assets and diagnostics route,
with 107 synthetic UIKit assertions. It preserves all five destinations and
the selected-container flow. Original licensing and unmapped screens are not
claimed as fully rebranded. Bundle IDs, app groups, service labels and persisted
paths remain unchanged until migration tests exist. Changing all matching
“SocialBox” strings indiscriminately would also change those functional contracts.

## Device acceptance needed before a new usable release

The built candidate needs a controlled installation with rollback and
existing-data preservation; reviewed maintainer scripts; app/helper/daemon/tweak
load evidence; recovered license/identity state; and XPC callers scoped to the
intended UI/CLI. Then test A/B/A original-app switching, own/foreign file and
Keychain canaries, preferences, app groups, pasteboards, kill acknowledgement,
interruption recovery and unchanged source/account data. Use actual API/syscall
results rather than displayed values or hook counters.

Network acceptance needs captured IPv4/IPv6/DNS/UDP/QUIC traffic, all route
exceptions, proxy loss, provider/daemon death, network changes and reboot. Map,
Cloud encryption/restore, file-provider mutations, UI re-skin and 40-context
capacity/lifecycle need separate acceptance. Account login remains an operator
step. These tests are **NOT_RUN for the recovered package**.

The phone, production website, signing keys and current SocialBox package were
not changed in this recovery pass. The branch remains unmerged. Full direct
adoption is not complete; the surviving binary is preserved, and the remaining
server/engine/transaction integration gaps are recorded explicitly.

## Mechanism inventory — bounded static review

The following 73 entries are the reviewed mechanisms. Every entry states an
observation, evidence and an unresolved condition or port decision. The full
function indexes in the private structural inventory remain the backlog;
unreviewed functions do not receive a PASS by association.

### Identity and storage


#### DS-01 — UIDevice IDFV

UIDevice identifierForVendor is registered to FUN_000ff534. The wrapper consults per-bundle app-level values and a configured IdentifierForVendor value, creates NSUUID, and has an explicit original-call fallback when no replacement is available. Obfuscated activation/application gates precede it; no claim that every bundle receives a replacement.

Evidence: `SocialBox.dylib` — `FUN_000fec98` at `0x000fec98` (decompiled/SocialBox.dylib.c:188652).

**Decision:** retain. Keep SocialBox validated immutable per-profile identity and identity-readiness mechanism. The reference fallback is a test case, not proof of separation.

**Needed:** A/B/A seeded values; missing/invalid configured values; independent LSD producer; process restart; log only equality verdicts.


#### DS-02 — Advertising ID and tracking enabled

ASIdentifierManager advertisingIdentifier and isAdvertisingTrackingEnabled are installed. When the common gate allows it, AdvertisingIdentifier is converted to NSUUID; missing value calls original. Tracking-enabled returns zero in the enabled branch.

Evidence: `SocialBox.dylib` — `FUN_001034d8` at `0x001034d8` (decompiled/SocialBox.dylib.c:192226).

**Decision:** retain. SocialBox explicitly tracks its IDFA/ATT posture; do not import reference fallbacks or infer ATT authorization from one deprecated tracking selector.

**Needed:** Compare ATT authorized/denied, zero/nonzero IDFA, invalid UUID and SDK-cached first-run values.


#### DS-03 — UIDevice model/name/system version

An installer registers systemVersion, name, model, localizedModel, systemName and optional platform. The inspected model replacement reads DeviceClass and falls back to the original if missing.

Evidence: `SocialBox.dylib` — `FUN_000fec98` at `0x000fec98` (decompiled/SocialBox.dylib.c:188652).

**Decision:** retain. Use coherent SocialBox catalog identity and screen recommendations; these reference hooks do not change physical hardware or prove model/build consistency.

**Needed:** Compare selected model/build/name across public APIs, MG/sysctl and screen scene/rendering paths.


#### DS-04 — NSProcessInfo version and memory

Registration covers operatingSystemVersion/String, hostName, operatingSystemName, globallyUniqueString, isOperatingSystemAtLeastVersion, thermalState, low power and physicalMemory. Inspected version parses ProductVersion; memory branch derives a model key and can call original.

Evidence: `SocialBox.dylib` — `FUN_001027a0` at `0x001027a0` (decompiled/SocialBox.dylib.c:191581).

**Decision:** unknown. Reference demonstrates a wider installed NSProcessInfo set than SocialBox ledger OS-054, but OS-availability/version predicates affect app behavior. Need actual caller evidence and compatibility proof before changing them.

**Needed:** Record values and caller sites across two clones, missing model data, real memory pressure and supported API availability; preserve app stability.


#### DS-05 — sysctl/sysctlbyname/uname

All three C entrypoints are hooked. Named wrapper includes hw.machine and kern.boottime and obtains activeContainerID for synthetic boot-time state. uname calls original then supplies configured hostname/release/version/machine fields. Numeric sysctl wrapper includes mixed-purpose logic that was not fully classified.

Evidence: `SocialBox.dylib` — `FUN_000f7158` at `0x000f7158` (decompiled/SocialBox.dylib.c:184982).

**Decision:** retain. SocialBox already has named/numeric mapping plus explicit unknown-key/syscall gaps. Do not convert broad reference symbol coverage into syscall-level isolation.

**Needed:** Compare numeric/named APIs and direct syscall with size-only/buffer-short requests; no hidden original-value fallback for configured fields.


#### DS-06 — MobileGestalt

Installer resolves MGCopyAnswer, MGCopyAnswer_internal and MGCopyAnswerWithError. Inspected MG wrapper consults a mapping dictionary/profile values, has IntegratedCircuitCardIdentity handling and an original-call route for unmapped/missing fields.

Evidence: `SocialBox.dylib` — `FUN_000f7c8c` at `0x000f7c8c` (decompiled/SocialBox.dylib.c:185800).

**Decision:** retain. Retain SocialBox typed-return handling and record private/hashed keys as unverified. Reference aliases are useful comparison targets, not proof of coverage.

**Needed:** Exercise typed callers and hashed/plain aliases; verify ownership and CF type contracts; preserve the existing numeric MobileGestalt crash regression.


#### DS-07 — IOKit registry properties

Both scalar create and search C APIs are registered. The inspected scalar wrapper has named profile substitutions including platform UUID, inverse ID, AWDID and chip identifier, with original-call fallbacks.

Evidence: `SocialBox.dylib` — `FUN_000f5a54` at `0x000f5a54` (decompiled/SocialBox.dylib.c:183868).

**Decision:** retain. SocialBox additionally models bulk property rewriting in source; no runtime breadth comparison is established. Keep raw/user-client and unknown-property gaps.

**Needed:** Join actual imported IOKit calls to scalar/search/bulk APIs and test type/buffer semantics and unknown property behavior.


#### DS-08 — Telephony carrier and subscriber fields

Installer registers carrierName, MCC/MNC, country and several private IMEI/MEID/ICCID methods. The inspected carrierName wrapper reads CarrierName and falls back to original when absent.

Evidence: `SocialBox.dylib` — `FUN_0010c978` at `0x0010c978` (decompiled/SocialBox.dylib.c:195922).

**Decision:** retain. Use SocialBox per-profile coherent region/carrier data. Private selector registration is not evidence of SIM behavior or valid proxy geography.

**Needed:** Test dual-SIM/service dictionaries, missing carrier data, proxy-country mismatch and all API names actually referenced by the app.


#### DS-09 — Locale, language and timezone

Registers locale countryCode, localeIdentifier, objectForKey, preferredLanguages and timezone system/local/default getters. Timezone helper derives a catalog timezone from country, creates NSTimeZone, and falls back to original for absent/invalid country or timezone.

Evidence: `SocialBox.dylib` — `FUN_0010c978` at `0x0010c978` (decompiled/SocialBox.dylib.c:195922).

**Decision:** retain. SocialBox already keeps country/city/timezone consistency and explicit CFLocale/autoupdating gaps. Do not replace city timezone by arbitrary country-only choice without checking multi-zone regions.

**Needed:** A/B locale/autoupdating/CFLocale, explicit app language, DST and multi-timezone countries; compare proxy observation without claiming GPS measurement.


#### DS-10 — Pasteboard read suppression

Inspected installer explicitly installs string, strings, URL, URLs, items, hasStrings and hasURLs. Scalar wrappers return nil/false and items returns empty array when common gate and bundle predicate apply; otherwise original access remains. This is read suppression, not an observed private mutable clipboard.

Evidence: `SocialBox.dylib` — `FUN_001191c4` at `0x001191c4` (decompiled/SocialBox.dylib.c:203649).

**Decision:** retain. SocialBox source deliberately blocks factory/named/unique, writes, metadata, typed/item-provider/detection and concrete subclasses, with an explicit compatibility mode. The inspected reference installer does not establish these families; absence elsewhere is not asserted.

**Needed:** Foreign canaries through every public pasteboard family, writer/reader switch-back, class clusters, compatibility mode and new selectors; inspect other constructors before concluding reference absence.


#### DS-11 — securityd caller attribution

securityd installs a private connection handler alongside SecItem functions. The handler checks XPC connection type, gets caller PID through a resolved function, checks cached classification, and uses proc_pidpath on a miss. Exact lifecycle/cache invalidation and process-owner binding are not proved by this bounded trace.

Evidence: `SocialBoxSecurityd.dylib` — `FUN_0000714c` at `0x0000714c` (decompiled/SocialBoxSecurityd.dylib.c:1939).

**Decision:** unknown. Service hooks change a global security authority. Retain clone signing/compiled exact group authority until a complete audited service contract is available.

**Needed:** PID reuse/start-time/audit-token binding, unknown client rejection, daemon threads/concurrency, extensions, service restart and simultaneous original app vs clone.


#### DS-12 — securityd SecItemCopyMatching and result reconstruction

Private __SecItemCopyMatching/_SecItemCopyMatching symbol resolution leads to FUN_0000e0a0. That wrapper contains a _drt_ prefix check, calls original and reconstructs attribute dictionaries including class/service/account/access-group/generic/label/description/sync/data/protection. The full namespace and result-ownership contract is obscured by helper calls and not established here.

Evidence: `SocialBoxSecurityd.dylib` — `FUN_0000714c` at `0x0000714c` (decompiled/SocialBoxSecurityd.dylib.c:1939).

**Decision:** unknown. Do not replace SocialBox signed access-group boundary with reconstructed item rewriting merely because a broad hook exists. Retain exact foreign-group rejection and unchanged Security results.

**Needed:** A/B/A all item classes, omitted groups, broad matches, return attributes/data/ref/persistent-ref arrays, synchronization modes and unchanged OSStatus/error semantics.


#### DS-13 — securityd Add/Update/Delete transformations

Private add/delete/update are all registered. Update calls a common transformation separately for query and changes before forwarding. Delete transforms only when identity/reference selector keys are present; a broad query without those keys goes to original in the inspected branch. Add contains delete-before-add handling for a branch. These are concrete branch targets for testing, not confirmed leakage.

Evidence: `SocialBoxSecurityd.dylib` — `FUN_0000714c` at `0x0000714c` (decompiled/SocialBoxSecurityd.dylib.c:1939).

**Decision:** unknown. Broad deletion and fallback query paths must be combined with entitlement/caller context before assessing isolation. SocialBox preserves Security behavior with exact per-app aliases and bounded cleanup receipts.

**Needed:** Broad delete/update without service/account, persistent refs, four stored classes, access controls, duplicate items, one sibling retained unchanged, crash/restart mid-operation.


#### DS-14 — securityd entitlement response rewriting

SecTaskCopyValueForEntitlement is intercepted. Wrapper explicitly branches for keychain-access-groups, application groups, application-identifier and associated-application-identifier; original entitlement calls and thread-context lookups participate. Exact returned sets are not completely recovered in this review.

Evidence: `SocialBoxSecurityd.dylib` — `FUN_0000714c` at `0x0000714c` (decompiled/SocialBoxSecurityd.dylib.c:1939).

**Decision:** unknown. Never port a general entitlement-response rewrite as an isolation shortcut. Keep SocialBox signed exact groups and deny foreign groups; entitlement rewriting can enlarge blast radius and conflict with OS authorization.

**Needed:** Actual securityd authorization versus exposed entitlement return values for own/sibling/source/system callers; nested requests; denied operations remain denied; failure fallback.


#### DS-15 — cfprefsd preferences path virtualization

Private __CFPrefsGetPathForTriplet is installed. Its wrapper first obtains an original path and then branches on Library/Preferences and application-container paths; it constructs a Shared/AppGroup preferences path and alternative rewritten path and copies it to the output. Namespace selection depends on other helpers.

Evidence: `SocialBoxCfPrefsd.dylib` — `FUN_00029bd0` at `0x00029bd0` (decompiled/SocialBoxCfPrefsd.dylib.c:23060).

**Decision:** unknown. This is a different shared service storage architecture. Keep SocialBox per-clone domains plus recorded filesystem limitations; do not add shared preference roots until permission and path authority are proven.

**Needed:** Domain/user/host/suite matrix, symlinks/path traversal, atomic writes, cross-process caches, direct file reads, original app coexistence and service restart.


#### DS-16 — cfprefsd XPC request context

Hooks CFPrefsDaemon handleSourceMessage:replyHandler:. Wrapper verifies dictionary and XPC connection shapes, reads CFPreferencesHostBundleIdentifier and a connection-derived caller value, then records thread context. Whether the supplied bundle is bound to authoritative audit identity needs further tracing.

Evidence: `SocialBoxCfPrefsd.dylib` — `FUN_00029bd0` at `0x00029bd0` (decompiled/SocialBoxCfPrefsd.dylib.c:23060).

**Decision:** unknown. Do not trust a request-supplied bundle identifier solely because a connection exists. SocialBox has exact app/profile domains but direct-file boundary remains unresolved.

**Needed:** Forged host bundle, PID reuse, concurrent nested requests, missing connection, exceptions and thread-context cleanup; original source calls must not inherit another context.


#### DS-17 — cfprefsd domain policy and active selection

Private withSourceForDomain:inContainer:... is hooked. Wrapper has explicit checks for Instagram and Apple/group/systemgroup prefixes, reads activeContainer and DEFAULT, and forwards changed arguments. Exact policy and namespace derivation require further recovery.

Evidence: `SocialBoxCfPrefsd.dylib` — `FUN_00029bd0` at `0x00029bd0` (decompiled/SocialBoxCfPrefsd.dylib.c:23060).

**Decision:** unknown. Retain SocialBox compiled exact four Facebook source aliases; Reddit remains unchanged. Dynamic active-selection service state must not affect unrelated platform preference domains.

**Needed:** Compare exact-domain versus prefix edge cases, system/Apple domains, rapid switch, in-flight operations, crash between selection and path update, shared group aliases.


#### DS-18 — containermanagerd interception

Installer hooks two MCMContainerFactory creation variants and MCMContainerCacheEntry setCorrupt:. Both creation wrappers first call original then common helper FUN_0002e4d4. setCorrupt inspects containerPath and can force false for a matching root. This alone does not establish a denied sibling read boundary.

Evidence: `SocialBoxContainermanagerd.dylib` — `FUN_0002838c` at `0x0002838c` (decompiled/SocialBoxContainermanagerd.dylib.c:22290).

**Decision:** unknown. SocialBox has an actual foreign-content failure history and gated storage remediation. Preserve that evidence; suppressing a corruption flag is not isolation and could hide inconsistencies.

**Needed:** Trace helper before port; direct open/stat/openat syscall canaries across A/B, metadata consistency, locked-home lifecycle and power loss.


#### DS-19 — accountsd client/store coupling

Registers ACDDatabaseInitializer dataclass/account-type methods and ACDAccountStore initWithClient:databaseConnection:. The inspected initializer gets the client PID, resolves context, forwards original, then binds context via helper and schedules asynchronous work. Actual account partition and credential access are not established.

Evidence: `SocialBoxAccountsd.dylib` — `FUN_000282a4` at `0x000282a4` (decompiled/SocialBoxAccountsd.dylib.c:23306).

**Decision:** unknown. Global account service changes can affect system accounts unrelated to supported apps; retain current architecture until exact account scope and transaction ownership are proven.

**Needed:** Synthetic app-local service canaries only, client spoof/PID reuse, concurrent stores, original accounts unaffected, process exit/restart and database recovery.


#### DS-20 — lsd identifier production

Hooks _LSDDeviceIdentifierClient getIdentifierOfType:completionHandler: (selector pointer name truncated in pseudocode). The inspected type-zero branch reads XPCConnection processIdentifier, resolves process path/context, uses activeContainer/DEFAULT, hashes an input string with SHA256 and constructs UUID-shaped bytes for callback; other branches can forward original.

Evidence: `SocialBoxLsd.dylib` — `FUN_0002766c` at `0x0002766c` (decompiled/SocialBoxLsd.dylib.c:22291).

**Decision:** port. Candidate for a narrowly scoped supplementary producer audit/reimplementation if actual app traffic bypasses in-process IDFV. Not authorization to copy service hook now; retain SocialBox until true caller binding and UUID lifetime are proven.

**Needed:** Confirm requested type, exact hash inputs and per-container namespace; original/system apps unaffected; A/B/A restart consistency and process attribution race tests.


#### DS-21 — mediaserverd identifiers and media User-Agent

Service installs MGCopyAnswer, sysctlbyname and CFHTTPMessageSetHeaderFieldValue. Inspected MG branch supplies ProductVersion/BuildVersion/ProductType/DeviceClass from globals. Header wrapper specifically recognizes User-Agent and AppleCoreMedia and reconstructs matching portions. Per-request client/container binding was not established.

Evidence: `SocialBoxMediaServerd.dylib` — `FUN_00027f54` at `0x00027f54` (decompiled/SocialBoxMediaServerd.dylib.c:22866).

**Decision:** port. Candidate for measuring media-service egress and adding a caller-bound policy if relevant. Shared global service values must not be mistaken for per-container isolation.

**Needed:** Capture actual media requests from two clones and unrelated apps; concurrent playback, switch while request in-flight, no credentials logged; define daemon-side attribution before adoption.


#### DS-22 — Cookie identifier persistence

Main tweak registers setCookie:. Wrapper recognizes loid under a bundle predicate, replaces its value from a helper, and recognizes mid under another bundle predicate, reading/writing an app value store. The inspected body does not show a cookie-domain guard before the named-cookie branch. This does not prove all cookie stores are partitioned.

Evidence: `SocialBox.dylib` — `FUN_001039e0` at `0x001039e0` (decompiled/SocialBox.dylib.c:192560).

**Decision:** retain. Keep per-clone cookie storage and domain-specific SocialBox wire policy. Reference name-only branches require unrelated-domain negative tests; do not infer absence of additional guards elsewhere.

**Needed:** NSHTTPCookieStorage/custom/session/WebKit stores, same cookie names on unrelated domains, authenticated cookie continuity and new-container initial state.


#### DS-23 — Sandbox extension request/consume path

Named applyExtensionsForContainer:bundleID: opens an XPC connection, requests extensions via the recovered issueSandboxExtensionsForContainer:bundleID:reply: stub, waits up to five seconds, iterates returned strings through a resolved consumer and returns success only when consumed count matches. Exact granted paths/classes and helper authorization are outside this inspected function.

Evidence: `SocialBox.dylib` — `_Xs8c::applyExtensionsForContainer:bundleID:` at `0x00336a28` (decompiled/SocialBox.dylib.c:61247).

**Decision:** unknown. Do not broadly grant extensions to sibling data as a compatibility workaround. Retain exact SocialBox storage authority and require a least-privilege helper contract.

**Needed:** Trace the issuing helper and consumer symbol, authorize caller bundle/container/audit identity, deny sibling and arbitrary paths, revoke on switch and test actual syscall access after revocation.


### Network and lifecycle


#### DRT-NET-001 — Proxy configuration handoff

The host writes proxy host, port, type, credentials, exclusions and rotation URL into shared defaults and vpn_config.plist. The extension reads suite defaults and falls back to the shared group configuration file. No credential values are reproduced here.

Evidence: `SocialBox.c` — `_Xvm1::startWithHost:port:type:username:password:excludeIPs:rotationURL:completion:` at `0x10024ab9c` (socialbox-3.1.0-1/decompiled/SocialBox.c:190219).

**Limit:** Shared configuration is not a container/generation-bound authorization receipt. Atomic plist writes alone do not establish transaction-wide consistency across both stores.

**Decision:** Keep SocialBox authoritative profile/proxy binding, operation ownership and generation revalidation; do not substitute global defaults for a scoped lease.


#### DRT-NET-002 — Personal/on-demand VPN manager

The host creates NETunnelProviderProtocol, sets provider bundle/server/configuration, enables the manager and installs NEOnDemandRuleConnect with interface match 0. The save/load/start chain is present.

Evidence: `SocialBox.c` — `FUN_10024b9d0` at `0x10024b9d0` (socialbox-3.1.0-1/decompiled/SocialBox.c:404193).

**Limit:** On-demand activation is not an independent kill switch, an all-networks rule, a per-app identity check or proof that flows remain blocked while the provider restarts.

**Decision:** This could support a separately labelled no-MDM transport experiment. Current SocialBox app-proxy MDM receipt cannot be satisfied by this personal tunnel.


#### DRT-NET-003 — IPv4 capture and routing

Provider startup sets 198.18.0.1/24 and an NEIPv4Route defaultRoute before submitting NEPacketTunnelNetworkSettings.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::startTunnelWithOptions:completionHandler:` at `0x10002cc1c` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:13807).

**Limit:** Route configuration does not prove every app flow enters this provider, and exclusions in the next row intentionally remove destinations.

**Decision:** A no-MDM backend needs a distinct device-wide assurance scope and physical routing evidence; NET-040 remains a gap.


#### DRT-NET-004 — Direct route exclusions

Startup explicitly excludes 192.168/16, 10/8, 172.16/12, 127/8, the proxy IPv4 /32, 17/8, 224/4 and 169.254/16; configured values are appended as /32 exclusions.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::startTunnelWithOptions:completionHandler:` at `0x10002cc1c` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:13807).

**Limit:** This cannot be described as proxy-only for all destinations. In particular broad Apple/LAN exclusions are not restricted to a single control-plane process or socket. Actual route precedence and egress still require device measurement.

**Decision:** Do not copy these exclusions into SocialBox fail-closed policy. USB recovery, DNS and control traffic require precise separately reviewed exceptions.


#### DRT-NET-005 — IPv6 capture completeness

The inspected startup constructs IPv4 and DNS/proxy settings; its body contains no IPv6 settings assignment. classifyPacket has a non-AF_INET branch that only admits a fixed-header next-protocol TCP value into lwIP.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::startTunnelWithOptions:completionHandler:` at `0x10002cc1c` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:13807).

**Limit:** A branch capable of reading an IPv6 TCP packet does not prove an IPv6 default route, extension-header handling, all IPv6 transport interception, or direct IPv6 blocking.

**Decision:** Retain NET-040 IPv4/IPv6 acceptance as NOT_RUN. A device-wide adapter must explicitly define and measure both families.


#### DRT-NET-006 — DNS interception varies with bridge availability

When no local listener or no listener port exists, startup assigns the synthetic DNS server 198.18.0.2 and match domains. When a live local listener exists it instead adds HTTP/HTTPS proxy settings; the DNS assignment is conditional.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::startTunnelWithOptions:completionHandler:` at `0x10002cc1c` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:13807).

**Limit:** Do not infer all DNS is sent through the proxy merely from the presence of the DNS mapper. Successful bridge operation does not follow the same synthetic-DNS setup branch.

**Decision:** SocialBox must separately measure resolver, background and encrypted-DNS behavior; its current app-proxy DNS responder is a different mechanism.


#### DRT-NET-007 — Fake DNS and resolver bypass

The DNS mapper returns synthetic IPv4 addresses for ordinary A questions, empty answer data for other ordinary types, and uses getaddrinfo(AF_INET) on its bypass branch. Bypass matching lowercases names and checks equality or suffix.

Evidence: `SocialBoxPacketTunnel.c` — `DLWDnsMapper::_isDomainBypassed:` at `0x1000f8af0` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:18510).

**Limit:** Bypassed domains are resolved by the system path, whose egress is not proven proxy-confined here. Exact runtime bypass list and suffix delimiter need retained data/disassembly validation before reuse; no hidden constants were decoded.

**Decision:** Keep control-plane attribution separate from clone DNS; do not claim NXDOMAIN-only policy matches this mapper.


#### DRT-NET-008 — Captured UDP/QUIC and ICMP

IPv4 classifier only sends TCP to lwIP, UDP destination port 53 to DNS processing and protocol 1 to local ICMP processing; other captured UDP/protocols return. ICMP echo requests are answered by swapping IP addresses and writing a locally synthesized reply.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::classifyPacket:protocol:` at `0x100031ff8` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:3331).

**Limit:** Dropping a captured QUIC packet is not proof no QUIC takes excluded routes. Local ICMP success is not an internet reachability or proxy-health measurement.

**Decision:** Acceptance must distinguish synthetic replies, denied captured traffic and independently observed physical egress.


#### DRT-NET-009 — TCP packet adaptation

readPackets callbacks classify frames. handleTcpAccept resolves fake destination addresses back to hostnames, creates a DLWTcpSession, registers the PCB in sessions and starts the SOCKS client path.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::startReadingPackets` at `0x100031d00` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:3026).

**Limit:** The adapter receives packets without an app identity field in these call paths. Sessions dictionary membership is not per-container attribution or a finite lease.

**Decision:** SocialBox current NEAppProxyFlow sourceAppSigningIdentifier and exact bundle checks cannot be inferred from raw packetFlow.


#### DRT-NET-010 — Local HTTP(S) bridge

DLWLocalConnectListener binds an AF_INET stream listener to 127.0.0.1 with an ephemeral port, listens and dispatches accepted clients to a worker. Startup installs that local listener as the system HTTP and HTTPS proxy.

Evidence: `SocialBoxPacketTunnel.c` — `DLWLocalConnectListener::startWithProxyType:proxyHost:proxyPort:username:password:` at `0x100129fac` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:21763).

**Limit:** No client identity or per-container authorization is demonstrated by the listener accept path. Loopback reachability does not identify the selected container.

**Decision:** Treat localhost proxy as shared broker traffic; NET-040 cannot claim selected-container-only access simply from the bridge.


#### DRT-NET-011 — Upstream socket behavior

The bridge worker creates upstream connections using FUN_100133a00; that helper opens AF_INET TCP sockets, applies socket options and connects to a literal or a system-resolved host. Bridge error paths emit HTTP 502 and close handles. DLWSocks5Client separately creates a proxy TCP connection and performs SOCKS negotiation.

Evidence: `SocialBoxPacketTunnel.c` — `FUN_100133a00` at `0x100133a00` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:24306).

**Limit:** Socket option numeric values and obfuscated branch behavior need deeper ABI/disassembly review before assigning special bypass claims. Proxy handshake success alone is not a measured exit-IP or immutable route receipt.

**Decision:** Reuse protocol ideas only behind exact proxy endpoint policy, bounded cancellation and evidence binding; retain no-direct-fallback tests.


#### DRT-NET-012 — Orderly extension shutdown

stopTunnel cancels both timers, stops the local listener, closes each tracked lwIP session, clears the session dictionary, shuts down the net stack, invokes completion and calls _exit(0). DLWTcpSession.close marks closed and cancels its read source or closes a proxy descriptor.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::stopTunnelWithReason:completionHandler:` at `0x100032890` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:3662).

**Limit:** This is normal provider teardown. It does not demonstrate post-crash kernel blocking, old external socket/state purge, or that the host waits for this completion before starting a replacement.

**Decision:** Retain explicit CLOSE acknowledgement, registered process death and socket drain in the SocialBox transaction.


#### DRT-NET-013 — Runtime tunnel status

handleAppMessage only recognizes a stats request and returns tx/rx packet/byte counters, tracked sessions and running=true; other messages reply nil.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::handleAppMessage:completionHandler:` at `0x100032af4` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:3834).

**Limit:** No container UUID, boot epoch, generation, expiry, source-app binding or verified CLOSED/ARMED/OPEN receipt is returned by this method.

**Decision:** Never convert these stats to SocialBox systemFirewall enforced=true; preserve the existing provider identity and fresh scoped receipt requirements.


#### DRT-NET-014 — Serialized proxy reconfiguration

Host reconfigure builds a fingerprint, deduplicates an equivalent connection, retains latest pending parameters and completion callbacks under objc_sync, and drains the pending configuration queue. Apply reconfigure short-circuits unchanged configuration or uses stopWithCompletion then startWithHost.

Evidence: `SocialBox.c` — `_Xvm1::reconfigureWithHost:port:type:username:password:rotationURL:completion:` at `0x10024d21c` (socialbox-3.1.0-1/decompiled/SocialBox.c:190980).

**Limit:** Serializing parameter updates does not prove no packet escapes during stop/restart. In-flight sockets and app launch remain separate concerns.

**Decision:** Useful UI/control-plane pattern; preserve SocialBox operation token, stale callback fencing and exact lease generations.


#### DRT-NET-015 — Stop completion uses a timer

FUN_10024c728 disables on-demand, initiates save/stop callbacks, and independently schedules caller completion after 500,000,000 ns. FUN_10024c980 calls selector stopTunnel; FUN_10024c9cc invokes the retained completion without a status/readback predicate in that callback.

Evidence: `SocialBox.c` — `FUN_10024c728` at `0x10024c728` (socialbox-3.1.0-1/decompiled/SocialBox.c:404699).

**Limit:** A 500 ms timer cannot establish that the old provider and every upstream socket have stopped. Reconfiguration callback starts a new tunnel; this timing assumption must not serve as isolation proof.

**Decision:** SocialBox killAndWait/CLOSED receipt/socket drain ordering is stricter in code and must survive any backend adoption.


#### DRT-NET-016 — Active proxy is global selection

AppDelegate reloads the proxy store, reads ActiveProxyUUID, chooses a record, updates active selection/status and calls the shared VPN manager reconfigure with host, port, protocol and credentials.

Evidence: `SocialBox.c` — `AppDelegate::reconfigureVPNForActiveContainer` at `0x100038ccc` (socialbox-3.1.0-1/decompiled/SocialBox.c:137).

**Limit:** A per-container proxy association in metadata can select a global transport, but does not create multiple concurrent app-attributed enforcement domains.

**Decision:** Adopt one-active-container semantics explicitly if pursued; do not advertise independent simultaneous proxy isolation from this global manager.


#### DRT-NET-017 — Helper container switch endpoint is a stub

Helper switchToContainer:forBundleID:reply: constructs NSError code 0x1f5 (501) with the visible Notimplemented_Phase2 description and replies with failure; it performs no container or network transition.

Evidence: `SocialBoxHelper.c` — `_Zw5h::switchToContainer:forBundleID:reply:` at `0x100055c34` (socialbox-3.1.0-1/decompiled/SocialBoxHelper.c:53574).

**Limit:** A selector in the API inventory is not implemented behavior. Actual global switching is elsewhere and must be traced separately.

**Decision:** Do not replace the tested SocialBox transaction with this endpoint or count it as implementation coverage.


#### DRT-NET-018 — Helper process termination

killApp dispatches to a worker that scans installed bundle Info.plist for matching CFBundleIdentifier and derives CFBundleExecutable; it uses killall -9 and falls back to transformed bundle-name components. A helper waits for the killall subprocess exit.

Evidence: `SocialBoxHelper.c` — `_Zw5h::killApp:reply:` at `0x100050668` (socialbox-3.1.0-1/decompiled/SocialBoxHelper.c:50165).

**Limit:** Name-based killall and its exit status do not prove exact registered process paths, descendants/brokers or zero residual sockets. The decompiler infers a void helper even though the caller uses a result; retain that uncertainty.

**Decision:** Keep SocialBox exact registered bundle paths, explicit service exclusions, cancellation fencing and independent process/socket verification (including the earlier C04 regression).


#### DRT-NET-019 — CLI termination route

CLI killAppViaSocket creates an AF_UNIX stream, connects to its helper endpoint and exchanges a request, with fallback into the CLI kill path. killApp includes a posix_spawn path deriving a process name.

Evidence: `SocialBoxCLI.c` — `_Yca1m::killAppViaSocket:` at `0x1000c152c` (socialbox-3.1.0-1/decompiled/SocialBoxCLI.c:40275).

**Limit:** CLI/helper request success alone cannot replace process or socket-table verification; endpoint identity and concurrency need a separate review.

**Decision:** Expose a constrained operation-owned CLI if needed; do not adopt an unchecked kill result as CLOSED proof.


#### DRT-NET-020 — Privileged helper caller admission

The listener obtains a process identifier/path, accepts a path substring match or an installed-app path containing .app/, and then admits effective UID 0 or 501 before exporting an XPC object.

Evidence: `SocialBoxHelper.c` — `_Zy1d::listener:shouldAcceptNewConnection:` at `0x100025f90` (socialbox-3.1.0-1/decompiled/SocialBoxHelper.c:22102).

**Limit:** The shown branch admits generic installed-app paths for mobile/root; exact code-signature/team/bundle allowlisting is not demonstrated here. Audit-token presence in imports is not sufficient. Do not expose privileged mutation methods by copying this admission policy.

**Decision:** Preserve SocialBox own authenticated/scoped IPC and root-owned private state; review caller admission independently of the tunnel.


#### DRT-NET-021 — Daemon disconnect is control-plane cleanup

secretsauced disconnect stops pending keepalive, invalidates/cancels its connection with daemon_intentional, and transitions connection phase. prepareForAirplaneDisconnect schedules follow-up work after 200 ms.

Evidence: `secretsauced.c` — `_Zy3d::prepareForAirplaneDisconnect` at `0x1000471ec` (socialbox-3.1.0-1/decompiled/secretsauced.c:4468).

**Limit:** These methods concern the daemon transport. No kernel packet policy or selected-clone lease revocation is demonstrated by these methods; do not relabel server keepalive as an independent firewall revoker.

**Decision:** SocialBox lease heartbeat expiry is separately consumed in its provider; NET-040 still requires independent revocation after controller death.


#### DRT-NET-022 — Daemon path monitoring and reconnect

setupNetworkMonitor starts nw_path_monitor on the main queue. Its callback observes path status/interface type and calls connect on recovery branches; reconnectDelayForError returns bounded retry delays.

Evidence: `secretsauced.c` — `_Zy3d::setupNetworkMonitor` at `0x100070080` (socialbox-3.1.0-1/decompiled/secretsauced.c:12137).

**Limit:** Detecting network/VPN changes and reconnecting a cloud socket is not evidence of a packet-level deny policy while connectivity is unavailable or changing.

**Decision:** Retain network-change, tunnel-death and stale-lease acceptance tests rather than treating path satisfied as permission to OPEN.


#### DRT-NET-023 — Global switch worker coverage limit

switchToGlobalContainer asynchronously dispatches FUN_100236804. The extraction marks that worker unresolved_with_instruction_listing. Its retained ARM64 listing contains a call to the killApp:reply: selector at instruction 0x100237160, so termination is attempted somewhere in the worker.

Evidence: `SocialBox.c` — `_Xr4s::switchToGlobalContainer:progress:completion:` at `0x1002366ec` (socialbox-3.1.0-1/decompiled/SocialBox.c:189807).

**Limit:** No reliable complete CLOSE → kill → socket drain → rotate → arm → open ordering can be asserted for the whole worker from this extraction. Presence of one call is not a verified transaction or rollback design.

**Decision:** Retain SocialBox ordering invariant and interruption journal. Do not replace it wholesale based on UI behavior or this unresolved worker.


#### DRT-NET-024 — Kernel and per-app enforcement inventory

A case-sensitive mechanical search of the five inspected component pseudocode files for NEIPv6, includeAllNetworks, enforceRoutes, NEAppRule, appRules, routingMethod, DIOC, /dev/pf and pfctl found no match. On-demand selectors were found separately and traced above.

Evidence: `SocialBoxPacketTunnel.c` — `SocialBoxPacketTunnelProvider::startTunnelWithOptions:completionHandler:` at `0x10002cc1c` (socialbox-3.1.0-1/decompiled/SocialBoxPacketTunnel.c:13807).

**Limit:** Obfuscated strings, dynamic selectors, omitted methods and external OS/provider policy mean a negative text search is not proof no such mechanism exists. No kernel policy installation or per-app enforcement proof was recovered in the inspected paths.

**Decision:** NET-040 remains GAP. Existing actual PF read-only observations and unlinked policy model do not become deployment evidence through reference-product adoption.


#### DRT-NET-025 — Stuck-VPN recovery policy

Host watchdog starts for connecting/disconnecting states, Tier1 requests stop/changes on-demand preferences and schedules another timer, and Tier2 can remove the VPN manager configuration from preferences.

Evidence: `SocialBox.c` — `_Xvm1::_updateStuckStateWatchdogForStatus:` at `0x10024e8d8` (socialbox-3.1.0-1/decompiled/SocialBox.c:191689).

**Limit:** Availability recovery is not default-deny behavior. Removing/stopping a personal tunnel can restore ordinary routing; actual physical egress during both recovery tiers remains untested.

**Decision:** Keep safe closure and explicit operator recovery separate from UI availability. Never mark protected because a stuck tunnel was removed.


### UI, containers, Cloud and location


#### UI-01 — Five-tab shell and pending import routing

Builds navigation stacks for Home, Containers, LocSim, Proxy and Settings; applies appearance, assigns the window root and selects Containers for pending import.

Evidence: `SocialBox` — `AppDelegate::showMainApp` at `0x10004a5f4` (decompiled/SocialBox.c:1911).

**Limit:** Full authenticated lifecycle and nested routes were not executed.

**Recovery boundary:** Source-owned presentation shell over an unchanged authenticated backend.


#### UI-02 — Home identity cards

Reads configuration into device/model/OS/serial/network/carrier/IDFA/IDFV/UDID cards; missing values have NotSet presentation.

Evidence: `SocialBox` — `HomeViewController::refreshAllCards` at `0x10005886c` (decompiled/SocialBox.c:4841).

**Limit:** A displayed identity does not prove API interception, network rewriting or isolation.

**Recovery boundary:** Typed configured-identity DTO, separate from runtime-observed evidence.


#### UI-03 — New container selection, catalog allocation and identity request

Requires selected apps; recovered create block reads global metadata, finds a free positive ID, preserves previous profile/location, sends name/apps/localContainerID/options/seed through daemon-or-fallback requestCreateContainer, waits up to 95 seconds, consumes generated values/seed and bootstraps per-app redirect trees.

Evidence: `SocialBox` — `HomeViewController::showNewContainerDialog` at `0x10005fae0` (decompiled/SocialBox.c:8355).

**Limit:** Server generation rules, limits, idempotency, rollback and all timeout paths are not recovered; no offline-generator or capacity guarantee.

**Recovery boundary:** Versioned create command/result and durable helper transaction; requires existing server/generator and per-app storage contracts.


#### UI-04 — Global catalog, active selection and folders

Reads global containers/activeContainer/folders; reconciles duplicate IDs via locked metadata mutation and rebuilds content.

Evidence: `SocialBox` — `_Xc9m::loadData` at `0x10010199c` (decompiled/SocialBox.c:79458).

**Limit:** Catalog does not establish independent clone bundle IDs or crash-safe consistency with per-app state.

**Recovery boundary:** Versioned catalog DTO and migration/reconciliation contract.


#### UI-05 — Context menu and active restrictions

Recovered action-provider offers Activate or Switch to Default, Edit Apps, Link Proxy, Export, Rename, Move to Folder, Reorder, Session Tokens and Delete. Active Reorder and Delete are disabled.

Evidence: `SocialBox` — `_Xc9m::_containerMenuActionProviderForInfo:` at `0x10010be60` (decompiled/SocialBox.c:84359).

**Limit:** Menu presence does not prove action success or safety. Token processing internals were not audited.

**Recovery boundary:** Availability derived from authoritative state; separate review for destructive/token actions.


#### UI-06 — Search, sorting and folders

Normalizes query, filters container collection and sorts by name/date/ID. Folder save writes folders into global metadata.

Evidence: `SocialBox` — `_Xc9m::filteredContainers` at `0x10010d208` (decompiled/SocialBox.c:84620).

**Limit:** Locale ordering and concurrent folder edits were not tested; observed folder save is read-modify-write.

**Recovery boundary:** Presentation-only search/sort plus transactional organizational metadata.


#### UI-07 — Edit container app membership

Computes app-list differences, updates matching global container apps, writes metadata, synchronizes per-app metadata and schedules follow-up work.

Evidence: `SocialBox` — `_Xc9m::saveApps:forContainer:` at `0x100116210` (decompiled/SocialBox.c:86674).

**Limit:** Every add/remove side effect and rollback path was not inspected.

**Recovery boundary:** Authoritative membership transaction; do not directly edit apps arrays from replacement UI.


#### UI-08 — Switch orchestration and identity response

Guards switch-in-progress with timeout/watchdog handling; sends command ID/container ID through requestSwitchContainer. Recovered callback handles returned identity/seed and spoofProfile metadata.

Evidence: `SocialBox` — `_Xc9m::performSwitchToContainer:` at `0x100111358` (decompiled/SocialBox.c:86350).

**Limit:** Serialization, stale-callback rejection, server availability and timed-out mutations remain unproven.

**Recovery boundary:** Versioned switch command with command binding, explicit completion and durable recovery.


#### UI-09 — Original-app filesystem switching

Resolves installed original app with LSApplicationProxy/dataContainerURL; helper kills app and handles root files/ownership. Body works on Library/Documents and per-container roots, records activeContainer, uses rename/unlink/symlink and flushes caches.

Evidence: `SocialBox` — `_Xr4s::_performPerAppSwitchForBundleID:fromContainer:toContainer:processedGroupIDs:skipKill:skipCacheFlush:skipKeychain:skipChown:` at `0x100232630` (decompiled/SocialBox.c:187526).

**Limit:** Not equivalent to separate clone sandbox identities. Process-stop completeness, open-file races, every app-group/extension path, interrupted recovery and network closure require physical tests.

**Recovery boundary:** Privileged switch transaction across original app storage; cannot be adopted by simply changing SocialBox clone paths.


#### UI-10 — Helper-mediated Keychain save/restore

Invokes helper dumpKeychainForBundleID:containerID:reply: and restoreKeychainFromDictionary:forBundleID:containerID:reply: with bounded synchronous waits.

Evidence: `SocialBox` — `_Xr4s::synchronouslyDumpKeychainForBundleID:` at `0x10022ec48` (decompiled/SocialBox.c:185418).

**Limit:** Access groups, item classes, sync/accessibility behavior, entitlement effects and rollback were not audited from wrappers.

**Recovery boundary:** Typed Keychain archive/RPC schema and strict scope; requires Securityd/helper implementation recovery.


#### UI-11 — Export orchestration and post-extraction validator

Export enters asynchronous loading flow. Inspected import validator checks metadata/version/apps, bundle IDs/system-app exclusion, file-count/size bounds, traversal/resolved paths/symlinks, top-level allowlist, Keychain dictionary and container name.

Evidence: `SocialBox` — `_Xc9m::exportContainer:userPassword:` at `0x10011cda4` (decompiled/SocialBox.c:89307).

**Limit:** Export bodies are only partly traced. Post-extraction validation does not prove safe extraction before writes or exclude TOCTOU.

**Recovery boundary:** Versioned archive format plus safe pre-write extractor, verified with synthetic compatibility archives.


#### UI-12 — Security-scoped import and URL dispatch

External file import starts security-scoped access, copies into temporary storage, stops scope and queues pending import in Containers. URL routes include shortcuts, Cloud, settings and VPN commands.

Evidence: `SocialBox` — `AppDelegate::application:openURL:options:` at `0x10003ad54` (decompiled/SocialBox.c:1201).

**Limit:** Caller authorization, every argument validation branch and temp cleanup are not proven.

**Recovery boundary:** Strict source-owned route parser retaining established bundle/scheme contracts during migration.


#### UI-13 — Cloud inventory and restore presentation

Guards concurrent reloads and calls cloudListBackups with existing client/device context. Restore accepts blob ID/label/passphrase and presents a restoring flow; global-passphrase availability affects prompting.

Evidence: `SocialBox` — `CloudViewController::reloadBackupsFromServer` at `0x100082050` (decompiled/SocialBox.c:22009).

**Limit:** Server storage/database, license ownership, quotas, authorization and successful end-to-end restoration are absent/unverified.

**Recovery boundary:** Versioned list/push/pull/delete API and tenant/archive ownership contract; existing service required.


#### UI-14 — Cloud push and helper command bridge

Push stages passphrase file and constructs Cloud CLI operation with container/name, optional app and passphrase-file argument. Recovered run block calls helper remote proxy executeCommand:reply:; push expects a success marker.

Evidence: `SocialBox` — `CloudOps::pushContainer:bundleID:name:passphrase:completion:` at `0x1000c8b40` (decompiled/SocialBox.c:53491).

**Limit:** Shell quoting, result parsing, CLI authorization and all cancellation/error paths are not audited.

**Recovery boundary:** Replace shell-string construction with a typed helper façade only after recovering CLI contract; preserve original auth.


#### UI-15 — Cloud temporary secret staging

Writes UTF-8 passphrase to a randomized temporary path through helper writeFileData:toPath:permissions:reply: with mode0600 and bounded wait.

Evidence: `SocialBox` — `CloudOps::stagePassphraseFile:` at `0x1000c815c` (decompiled/SocialBox.c:53307).

**Limit:** Owner, symlink/race resistance and cleanup on all outcomes require verification; no runtime passphrases read.

**Recovery boundary:** Opaque short-lived secret handle with explicit cleanup/expiry, outside catalog and source control.


#### UI-16 — Cloud crypto envelope and decrypt checks

Creates versioned KDF/cipher envelope with PBKDF2-HMAC-SHA256 and AES-256-CBC/HMAC-SHA256 labels, salt/iterations/IV/tag/plaintext hash/manifest. Decrypt validates structure/lengths, computes tag before decrypt and checks plaintext hash.

Evidence: `SocialBox` — `SocialBoxCloudCrypto::encryptPlaintext:passphrase:manifest:envelope:error:` at `0x1000d12a4` (decompiled/SocialBox.c:56527).

**Limit:** Labels are not crypto proof. Iteration constant, randomness, constant-time comparison and exact authenticated manifest/data coverage remain unresolved.

**Recovery boundary:** Recover codec test vectors and exact constants before writing interoperable source adapter.


#### UI-17 — FileProvider local enumeration

Enumerates local directory and filters container-pack, token-bundle and JSON export suffixes; change enumeration completes with sync-anchor state.

Evidence: `SocialBoxFilesProvider` — `SocialBoxEnumerator::enumerateItemsForObserver:startingAtPage:` at `0x100019548` (decompiled/SocialBoxFilesProvider.c:14663).

**Limit:** Base directory helper chain not fully decoded; no remote Cloud download shown; path/anchor consistency needs review.

**Recovery boundary:** Local Files export façade with explicit shared root and opaque item identifiers.


#### UI-18 — FileProvider local fetch

Checks local item metadata, creates temporary directory, copies item and completes with URL/metadata; root content has error path.

Evidence: `SocialBoxFilesProvider` — `FileProvider::fetchContentsForItemWithIdentifier:version:request:completionHandler:` at `0x100019d04` (decompiled/SocialBoxFilesProvider.c:15127).

**Limit:** No network fetch/decryption inferred. Traversal, symlink handling and cleanup on all failures remain unresolved.

**Recovery boundary:** Opaque ID-to-local-export mapping with bounded temp lifecycle.


#### UI-19 — FileProvider actual mutation capabilities

createItem returns an unsupported/error response. deleteItem denies root and removes local file. modifyItem checks filename change/allowed extension, moves file and returns metadata.

Evidence: `SocialBoxFilesProvider` — `FileProvider::createItemBasedOnTemplate:fields:contents:options:request:completionHandler:` at `0x10001a1a4` (decompiled/SocialBoxFilesProvider.c:14981).

**Limit:** Content upload/create not demonstrated. Version conflicts, complete input validation and concurrent rename behavior are unverified.

**Recovery boundary:** Honest capability flags and tested rename/delete semantics rather than claiming full bidirectional Cloud provider.


#### UI-20 — Location coordinate search/map selection

Trims/parses coordinates with range checks, otherwise runs cancellable timed map search; selection replaces marker/labels and reverse-geocodes. Action button calls start/stop and updates UI/history.

Evidence: `SocialBox` — `LocSimViewController::searchBarSearchButtonClicked:` at `0x10012f96c` (decompiled/SocialBox.c:93784).

**Limit:** All malformed coordinate cases and actual target app location are unverified; UI state is not execution proof.

**Recovery boundary:** Source-owned draft coordinate/map editor, separate from acknowledged simulation.


#### UI-21 — Private location simulation backend

Allocates CLsimulationManager, restores saved state/subscribes notification. Start stops/clears/appends CLLocation/flushes/starts; persists coordinates/enabled state. Stop stops/clears/flushes and resets timezone handling.

Evidence: `SocialBox` — `_Xl5s::init` at `0x10018b180` (decompiled/SocialBox.c:123722).

**Limit:** Private API support, target scope and cross-container isolation are not established; do not claim per-app behavior.

**Recovery boundary:** Capability-checked location adapter with explicit scope/acknowledgment; private framework and configuration dependencies.


#### UI-22 — Location bookmarks/history

Loads bookmarks from standard UserDefaults; history contains coordinates/date, is saved and updates badge.

Evidence: `SocialBox` — `LocSimViewController::loadBookmarks` at `0x100130f54` (decompiled/SocialBox.c:94246).

**Limit:** Retention, protection and container scoping beyond observed standard preferences call are not established.

**Recovery boundary:** Explicit local preference scope and clear-history controls.


#### UI-23 — Settings maintenance actions

Builds Respring, SBReload, Userspace Reboot, Clean Crane, Recover palera1n and Recover Daemon cards attached to confirmation targets.

Evidence: `SocialBox` — `SettingsViewController::buildSystemSection` at `0x1000ef3cc` (decompiled/SocialBox.c:72340).

**Limit:** Execution bodies and cleanup scope not audited; none executed.

**Recovery boundary:** Keep privileged maintenance separate from daily flow, disabled until exact behavior and jailbreak compatibility known.


#### UI-24 — Remote command UI reception

Notification handler reads commandType/payload/cmdId then dispatches on main queue. Function index contains status/configuration/identity/backup/clear-data/system command handlers.

Evidence: `SocialBox` — `HomeViewController::handleWebSocketCommand:` at `0x100063b78` (decompiled/SocialBox.c:8608).

**Limit:** Authorization origin, replay protection and every handler not proven by reception wrapper.

**Recovery boundary:** Versioned authenticated command protocol/result correlation; server and transport source still required.


#### UI-25 — Bundle/resource contracts and re-skin constraints

Application includes URL scheme and distinct PacketTunnel/FilesProvider extension identities. FilesProvider declares document app group/enumeration. Icons/logo are compiled package resources; inspected main controls are programmatic.

Evidence: `Info.plist` — `declaration` at `not applicable` (compiled/var/jb/Applications/SocialBox.app/Info.plist).

**Limit:** Changing brand assets or plist display name does not recover editable application source. Bundle, group, service, notification, data-root or extension renames can break companion components and persisted data.

**Recovery boundary:** Binary-preserving package plus immutable compatibility manifest, followed by individually reconstructed source-owned adapters/screens.


### 22 September — actual helper loading and pinned .6 → .7 upgrade

The phone reproduced a runtime loader failure missed by package-only checks:
`.6` contained the requested DYLD environment setting, but the registered job
omitted it and no helper safety image was mapped. An executable-filter probe
loaded the signed image and the original helper logged `LBX_HELPER_DRAIN
installed=yes`. `.7` now uses that exact executable filter, retaining the
whole-host/UID/path/method guards and restoring the original helper plist.
It is installed on the iPhone X, with all 59 payload hashes verified and global
metadata byte-identical. Original licensing and all 15 original programs remain
unchanged. No new target-app filter was added.

The incoming upgrade can admit only the hard-coded `.6` archive, and verifies
all its installed payload hashes, modes/owners and source-owned controls. An
actual private rollback restored `.6` during acceptance. A manager still mapped
to the replaced vnode subsequently made proc_pidpath fail with ENOENT; the normal
full-snapshot check correctly refused it. A separate management-only close
through RunningBoard recovered the app. No container-drain fallback was added.

501 helper assertions, 33 package groups, 7 composition groups, static checks
and 8 leak-contract tests passed. The filter regression failed before the fix.
The signed arm64/arm64e build was independently inspected. This receipt proves
original-helper method installation on arm64; manager/UI, global transaction,
network containment and target-container acceptance remain distinct tests.
See `docs/release-evidence/helper-loader-2026-09-22.json` and
`lucid/HelperSafety/README.md` for the precise scope.


### Current device acceptance inputs

The installed `.7` helper reports successful hook installation, but foreground
manager acceptance is blocked by the phone lock. `uiopen` returned zero while
SpringBoard returned `FBSOpenApplicationErrorDomain` code 7 (`Locked`). A zero
`uiopen` exit must not be treated as successful application launch.

Neither Facebook nor Reddit is registered on this iPhone X. The retained
Facebook 578.1.0 and Reddit 2026.36.0 IPAs contain unencrypted arm64 images, but
both main `UISupportedDevices` arrays exclude the physical iPhone10,6. The
actual Facebook installation was refused by MobileInstallation with error 86,
`DeviceNotSupportedByThinning`; no Facebook account/app was replaced. The Reddit
install was not attempted after identifying the same metadata restriction.
Obtain the applications on this physical phone through the App Store, then run
acceptance with the phone unlocked. Do not delete the thinning restriction and
call the resource variant compatible, or substitute a spoofed identity for the
physical hardware in this check.

`tools/check_ipa_device.py FILE.ipa --device iPhone10,6 --ios 16.7.16` checks the
main app and its immediate extensions before transfer/install. It is read-only
and rejects device-variant and minimum-OS mismatches; a pass covers only those
metadata checks, not resources/signatures, successful launch or isolation.
Five synthetic regression groups and the two actual archive checks are recorded
in `docs/release-evidence/target-preparation-2026-09-22.json`.
