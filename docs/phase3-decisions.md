# Phase 3 decisions and verification

## P301 â€” native compiler blockers

The complete arm64 iOS 15 syntax pass found five failing translation units that
text-only static checks had missed. Registry now uses CentralStore's implemented
`dictionary` accessor; untyped dictionary values use Objective-C `boolValue`
messages; the termination callback is wrapped in its declared block type; the
health check dispatch closes with the correct syntax. Health checks share the
existing HTTP-only proxy parser, PAC settings and scoped authentication delegate,
instead of unavailable macOS CFNetwork constants. Timed-out health sessions are
cancelled and invalidated. Background account health checks remain disabled by
the daemon's existing startup policy.

Validation: portable Clang with iPhoneOS 15.6 SDK, arm64 iOS 15 target; this is
syntax validation, not an Xcode link, signed install, or device execution.

## P302 â€” generation-bound process exit and readiness (H11)

The polling timer now runs on the same serial queue as launch/switch, using an
immutable container/bundle/executable/PID/generation/boot-epoch identity captured
after verified launch. It evaluates the current kernel snapshot rather than
queuing a prior exit observation. An absent PID is handled even if it exited
before the first poll. Unknown enumeration closes traffic and remains retryable.
Normal exit revokes the on-disk binding, clears the dashboard launch state and
permits subsequent deletion. Readiness must name the verified live PID at the
exact clone executable path. Proxy cache revocation is permitted without a
mutating request context because it only removes state.

The process timer waits behind an active transition; provider/daemon heartbeat
expiry remains on independent queues. This is not a hardware proof of process
isolation. Exercise rapid A/B switches, exit before first poll, same-profile
relaunch, failed enumeration, and normal exit followed by deletion on device.

## P303 â€” identity rebuild preserves the previous installation

Identity Apply previously uninstalled the working clone before calling the
transactional installer, bypassing its previous-app/data backup. It now requests
replacement with the original installation intact. Clone reuse and validation
compare the signed bootstrap's immutable identity sections against the requested
profile, so an identity change reliably enters the existing backup/install/
rollback transaction. Mutable proxy credentials and runtime security switches
are excluded from this identity comparison. Failure recovery checks both profile
restoration and reinstall instead of silently ignoring their errors. A failed
recovery reports the need for recovery and does not delete its transaction backup.

Device fault tests: fail before install, during replacement, profile publication,
and rollback; confirm the original app sandbox/session is preserved. Syntax
validation does not prove LaunchServices replacement preserves login state.

## P304 — remove launcher-owned IPA share copies

IPA shares now use unique private 0700 directories and 0600 files, with no
profile identifier in the filesystem path. Completion and cancellation both
remove the owned directory; interrupted shares are retried on next launcher
start. Cleanup failure is surfaced in the launcher. Deletion is constrained to
this launcher's own tmp export directories, and daemon export deletion is
restricted to its known path. Already delivered Files/MDM copies cannot be
recalled. The daemon refuses another export while its prior file awaits collection, so
receipts cannot silently deliver the next profile's IPA. A stranded daemon
export after a lost receipt still needs recovery. Legacy flat tmp IPA copies
from older versions require ownership verification before migration cleanup;
this change does not delete arbitrary user files.

## P305 — diagnostics distinguish setup and routing evidence

Deferred VPN with local CLOSED now produces informational provider checks; empty
clone inventory is informational. Active readiness requires the full mandatory
hook receipt, current epoch/generation and a live exact executable, rather than
a matching container/generation alone. The report exposes an unfinished operation
fence and explicitly marks actual managed routing unverified. Exported MDM
configuration no longer asserts browser-auth coverage merely from requested
Safari domains. Missing configuration/source/license remain actionable setup
findings; the launcher itself remains usable.

H08 remains a release blocker: LaunchServices' managed-app Boolean is not proof
of the clone's VPNUUID assignment. Apple documents per-app routing as an MDM
association, separately from managed-app status:
https://developer.apple.com/documentation/networkextension/netunnelprovidermanager
https://support.apple.com/en-gb/guide/deployment/dep0323d652d/web
No guessed private API or self-asserted configuration flag was substituted for
that evidence. ASWebAuthenticationSession remains denied; password login in the
clone must be tested against the actual Reddit build. This does not establish
an all-in-app, no-MDM setup flow.

## P306 — explicit clipboard compatibility for credential entry

The default still blocks every audited UIPasteboard family. A profile can now
explicitly enable the system clipboard in its existing Identity compatibility
screen, allowing password/one-time-code paste when required. Missing legacy
policy means blocked. The validator rejects unknown policy values; the daemon
closes/stops the clone before applying the setting. Readiness verifies the
selected policy without touching clipboard contents. The UI and profile warnings
say that this exception exposes shared content and metadata across profiles;
it is not isolated clipboard storage. Disable after credential entry and clear
the clipboard manually if desired. Test both modes on real login forms.

## P307 — deleting the active or last profile has a reachable flow

Explicit Delete now establishes CLOSED and stops running clone processes before
continuing, even when its target is active. It no longer tells the user to find
a nonexistent Close button. Later deletion checkpoints still reject an active
binding. `killAllAndWait` now verifies the durable blocked binding and reports
failure even if process termination succeeded; it still attempts termination
when that write fails. The existing destructive confirmation explains that
running clones stop before the selected profile is erased. Device tests must
cover last-profile deletion, binding-write failure, termination failure and
retry after a partially completed journal.

## P308 — nested IOKit dictionaries no longer bypass key filtering

Scalar, search and bulk IOKit properties previously filtered only the outer
property name. A harmless outer key could return nested physical serial/chip
identifiers unchanged. The same filter now walks dictionary and array values,
replaces known platform serial/UUID keys with the profile tuple, removes named
sensitive fields, and drops branches beyond a bounded depth. The actual hooked
bulk-property readiness probe includes nested dictionaries and arrays. Opaque
unnamed data and unknown keys still cannot be classified as safe by this filter;
private IOKit/user-client interfaces need device probing.

## P309 — update obsolete source-audit contracts

The standalone isolation audit still required removed SOCKS constants, legacy
storage labels and profile-embedded rotation credentials. Its guards now check
the current HTTP proxy, daemon-only secrets, generation/PID watcher, signed
identity comparison and nested IOKit policies. Duplicate-profile output redacts
values instead of printing identifiers or credential-bearing proxy URLs. Its
success label explicitly means a source check. Profile schema notes now match
synthetic catalog identity, clipboard compatibility and device-scoped backup
access; the profile loader type-checks the new clipboard policy.

## P310 — corrupt clone-local profiles enter the blocked fallback

Clone startup chained subscripts into parsed JSON before checking whether its
root or sections were dictionaries. A malformed local profile could throw before
installing fail-closed hooks. The clone now validates the relevant structural
boundaries and entitlement strings before using them, including a persisted
fallback record. Invalid structure enters the existing unvalidated fallback;
it never grants readiness. The ContainerManager header no longer describes the
removed shared-binding/default-profile authorization design. Device test:
replace local profile with an array, scalar, null section and corrupt fallback,
and verify no network opens and no constructor exception occurs.

## P311 - preserve UTF-8 source and UI text

The identity-editor check caught a non-UTF-8 dash in Registry. The same scan found
an invalid apostrophe in the cloud profile page and mixed encoding in phase-3
notes. These bytes are repaired without changing behavior. The required static
check now rejects invalid UTF-8 in source/docs roots, excluding dependencies.
This prevents a Windows-default code page from silently corrupting UI strings.

## P312 - remaining legacy native declarations (C03 follow-up)

The exhaustive native-source pass included legacy preferences controllers that
are not shipped (`prefs/Makefile` builds only RootListController). One retained
file still used NSJSONPrettyPrinted from C03; the legacy dashboard also had
untyped Boolean property syntax and a nonexistent PSSubtitleCell constant.
These are corrected, and the static check now guards native sources including
prefs against that invalid JSON constant. The legacy screen uses a declared
static-text cell with the existing detail in its label. This does not reconnect
legacy preferences IPC or make those unshipped controllers part of the product.

## P313 - reject source IPAs requiring a newer physical iOS

Source import checked decryption but not the executable's MinimumOSVersion. It
could report successful setup and fail later at installation on an older phone.
Import now validates the version string and compares it with the daemon's actual
OS before replacing the private source. Synthetic profile versions cannot make
a newer executable run on the physical OS. This improves the error location;
framework/architecture compatibility still needs a real install and launch.

## P314 - remove the shared daemon boot identifier from clone files

The C07/H12 control design copied one daemon boot UUID into every clone's own
readable lease/status file. An observing client could submit that shared value
to correlate profiles. Clone mirrors now replace it with HMAC-SHA256 of the
bundle identifier under the daemon boot epoch, with domain separation. Both
mirrors use the same scoped token; hook readiness and diagnostics compare against
the daemon's derived expectation. Daemon/provider renewal still uses the raw
epoch. Restart invalidates both forms. Control endpoint lists and historical
exit IP are omitted from clone mirrors because the clone does not need them.

Raw local daemon lease/status records are now root-owned 0600; provider-group
leases are mobile-owned 0600 inside the authorized App Group. Private temporary
records receive permissions before atomic rename, preventing publication with
default readable modes. Root diagnostics/smoke access still works. A compromised
kernel, jailbreak permission bypass or same-process memory inspection remains
outside this protection. Operation-context fixtures cover stable, cross-clone
and restart epoch behavior; their execution requires the Mac test host.
