# Phase 2 decisions

Base: phase 1 commit `06e5745`. Implement the explicitly listed High findings
in their requested order, then M01–M05. The omitted H08/H09/H11 will be assessed
with the corresponding phase 3 mapping, asynchronous-policy and switch audit.
Each fix has its own commit, followed by `tools/static_check.py`; the final
handoff records the actual commit IDs and check results.

## H02 — package lifecycle

The rootless launchdaemon is bootstrapped into `system` during package
configuration. Existing services are booted out before reloading; launchd must
report a running PID within five seconds. Upgrade/removal scripts stop the
loaded service before its binary is replaced or removed. Failures are surfaced
to the package manager. Data/profile files are not deleted by package removal.
Shell syntax is checked on the host; actual launchd acceptance needs a device.

## H07 — deferred setup and source import

Daemon startup establishes a verified local CLOSED lease without opening the
firewall host. A missing App Group is allowed only for CLOSED; ARMED and OPEN
still require both stores and a current provider acknowledgement. Maintenance
after proven process termination can proceed without a running provider. This
includes the daemon's configuration probe, which uses its own control-plane
URLSession/proxy path outside the clone's per-app mapping. A live provider must
acknowledge CLOSED before maintenance continues.

Settings exposes IPA import, its correlated result, the deferred-firewall
banner, explicit firewall startup and the existing MDM export. Imported ZIPs
are validated and extracted into private staging; only a decrypted Reddit
source passing the existing source validation can replace the private cache.
An invalid archive preserves the existing source. The user does not need to
install a visible Reddit source through another app.
The importer links iOS libarchive; macOS builds need its headers (`brew install
libarchive`, or `LIBARCHIVE_INCLUDE`). It rejects links, traversal, duplicate
paths, encrypted ZIP entries, oversized expansion and malformed Mach-O slices.
The Source directory remains root-only; contained bundle modes allow the
subsequent signed IPA to be read and executed after installation.

Managed deployment remains an external platform prerequisite: the launcher
exports the payload and assignment metadata, but an MDM administrator must
apply it. The UI states this requirement; it does not claim that opening the
firewall host configures management. Actual document-picker import, encrypted
and malformed IPA rejection, provider authorization and MDM installation
require device tests. On a fresh device, verify settings/test/import/create
with no provider, then verify clone launch is refused until setup completes.

## H01 — unsigned compilation and ldid signing

Xcode compilation uses CODE_SIGNING_ALLOWED=NO, CODE_SIGNING_REQUIRED=NO,
an empty CODE_SIGN_IDENTITY and Manual signing style. No Apple team is required.
The archive is then signed using Procursus ldid shallow bundle signing: nested
Mach-O libraries first, framework bundles, the provider extension, then the
host. The signer reads CFBundleExecutable, checks the expected entitlement
dictionary from each signed executable and checks bundle resource envelopes.
An unexpected code extension fails rather than inheriting host entitlements.
Theos uses the same selected ldid for the launcher, daemon and tweak.
The host/provider explicitly carry distinct application identifiers and the
same `RBXBOXCFG` team identifier. This is the existing local signing namespace,
not an Apple-issued team. Unsigned compilation does not synthesize the identity
entitlements normally added during Xcode signing ([Apple TN2415](https://developer.apple.com/library/archive/technotes/tn2415/_index.html)).
The jailbreak must authorize that local namespace for the App Group; merely
matching it does not establish [App Group permission](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.application-groups).

The `-w` operation and resource-envelope behavior come from the
[Procursus ldid manual](https://github.com/ProcursusTeam/ldid/blob/master/docs/ldid.1)
and [implementation](https://github.com/ProcursusTeam/ldid/blob/master/ldid.cpp).
The feature requires [procursus7 or later](https://github.com/ProcursusTeam/ldid/releases/tag/v2.1.5-procursus7).
Mock signing tests check ordering and rejection behavior on the host. A real
macOS archive/build and target-device NetworkExtension/App Group authorization
remain required; an ldid signature alone does not prove that iOS grants them.

## H10 — queued requests and correlated terminal results

Darwin notifications now wake a shared filesystem queue. Each request has a
UUID, an atomic ownership transfer into daemon-only processing storage and an
immutable terminal receipt queried by that UUID. The daemon snapshots a claimed
request into a new private inode before execution. Results are persisted before
claims are removed; failed result writes retry without replaying side effects.
Startup marks unfinished claims interrupted rather than repeating a rotation,
installation or deletion. Periodic draining covers missed notifications.

Rapid switches queue in order; a later request does not erase an earlier one.
All actions use the transition queue, with explicit replies for launch stages,
configuration, source import, identity, diagnostics, exports and cloud work.
Launcher consumers retain outstanding IDs and read their own receipts. A queued
diagnostic is no longer mislabeled failed after three seconds. Settings only
reports reload completion after the daemon's result. The inactive legacy prefs
controllers are not reactivated; their singleton action slots are retired.

During integration, local refresh was found to inherit a cloud-not-paired error.
It now succeeds locally when optional cloud pairing is absent, preserving H07's
first-run flow. The old cloud C-function-call syntax error was also corrected.
Existing H12 helper/network lifetime limits remain the next ordered dependency;
this change retains transition ownership until callbacks finish instead of
publishing a timeout and allowing later callbacks to mutate a newer transition.
Native queue tests cover concurrent submission, A-to-B ordering, duplicate
receipts, inode replacement, unsafe links, persistence failures and restart
recovery. They are wired into the macOS build and cannot run on this Windows
host. Review caught and corrected UUID-based reordering and exception paths
that could omit a terminal receipt before this fix was committed.

## H18 — compare effective rotation settings

Cloud refresh compares only the secure proxy/rotation overrides. It ignores
local timestamps, cloud timestamps, source labels and the separate license
key. Nil and empty override dictionaries compare equally. Method case follows
runtime normalization; URL and credential bytes remain exact. An absent
authorization inherits a fallback, while an empty authorization explicitly
clears it. The plist fallback now respects that clear and a secure header.

Saving a metadata-only refresh performs no Keychain write and preserves the
existing revision/source. Real override changes or access-key changes still
persist; only rotation changes cause the refresh transition to close the
session. Keychain read errors are errors, not an empty configuration, and leave
the session closed if closure can be verified. Native tests exercise the real
normalization/save path with an in-memory persistence subclass; they are wired
into the Mac build and remain unexecuted on Windows. Device check: refresh an
open clone repeatedly with unchanged cloud settings and verify its PID/lease
generation remain unchanged, then change a proxy credential and verify closure.

## H19 — atomic authentication transitions

Users, devices, licenses and pairing codes share a versioned authentication
document. Pairing-code consumption and the device token commit together;
license consumption and the user's entitlement commit together. Revocation
uses the currently bound user within that same transaction. Eligibility is
checked again inside the mutation callback, including after a storage conflict.
Tokens are returned only after the corresponding state is committed.

Existing collection callers use the same document through the storage adapter.
The first access migrates the four legacy collections without deleting them;
a competing migration always keeps the current committed document. Deploy with
old server instances stopped: an old binary does not know the new authority.
Do not roll back to an old binary and silently resume writes to legacy files.

Local writes use an exclusive cross-process directory lock and a synced unique
temporary file followed by atomic rename. A failed replacement preserves the
previous document; there is no direct-write fallback. Locks are never stolen
because of age. An abruptly terminated writer can therefore leave a lock that
blocks later writes. Recovery requires stopping every local server instance,
verifying that no writer remains, then removing only `.data/.mutation-lock`.
Vercel Blob uses conditional creation or an ETag compare-and-swap; a lost lock
does not authorize an unconditional document overwrite.

The seed command now uses the authoritative adapter too. A present but empty
or corrupt authentication document fails; legacy backups are not resurrected.
Windows file-sharing conflicts use bounded replacement retries. The tests use
synthetic temporary stores and actual helper functions, including separate
processes, competing claims, activation/revocation interleavings, failed commits
and concurrent migration. They do not connect to a production Blob store.

## H03 — checked application launch

Both launch paths resolve executable `uiopen` from `/var/jb/usr/bin`, then
`/usr/bin`, and pass `--bundleid` explicitly. The package depends on
`uikittools (>= 2.1.6)`. The [upstream helper](https://github.com/ProcursusTeam/uikittools-ng/blob/main/uiopen.m)
does not return the result of its bundle-open call, so a zero exit status is
only one check. The daemon also resolves LaunchServices registration and proves
the expected executable has a live PID. A clone's registration must match its
verified bundle path; reopening the setup host may find its existing process.
The [Procursus package](https://github.com/ProcursusTeam/Procursus/blob/main/build_info/uikittools.control)
supplies the helper.

Helper execution and process appearance have deadlines. A hung helper's process
group is terminated and reaped with bounded checks; failure leaves the launch
closed. Missing registration, helper errors, unprovable process enumeration,
and a zero-exit helper that starts no app all produce a correlated UI error.
The clone process proof does not replace the subsequent hook/provider readiness
handshake. On-device verification must cover rootless helper selection, a hung
helper, an invalid bundle ID, delayed or absent app startup and reopening setup.
Those LaunchServices/process tests cannot run on this Windows host.

## H04 — installation-service uninstall

The pinned installer dependency is `ai.akemi.appinst (>= 2.1.1)` and appinst is
used only to install IPA files. The [upstream CLI](https://github.com/akemin-dayo/AppSync/blob/master/appinst/appinst.m)
does not accept `-u`. A correction to the first review: its
[package metadata](https://github.com/akemin-dayo/AppSync/blob/master/appinst/control)
does provide the old `com.linusyang.appinst` virtual name; the unsupported
uninstall invocation was the functional defect.

Removal uses the guarded `LSApplicationWorkspace`
`uninstallApplication:withOptions:` interface also declared by upstream appinst.
Only the source Reddit app or a verified clone identifier may be removed.
Launcher, firewall host and provider identifiers are excluded. Registration
and container evidence is captured before removal; success requires both
service completion and verification that registration and captured paths have
disappeared. A failed or unavailable service query is not an empty app list.
The daemon does not manually delete a registered app bundle to simulate success.

Because the daemon now calls the service itself, its signature declares the
uninstall SPI and deletion entitlements used by
[TrollStore's installation helper](https://github.com/opa334/TrollStore/blob/main/RootHelper/entitlements.plist),
plus the platform identity and installd lookup grant used by
[upstream appinst](https://github.com/akemin-dayo/AppSync/blob/master/appinst/appinst_entitlements.plist).
Actual acceptance of those entitlements remains a device check; root UID alone
is not treated as installation-service authorization. Failed or partial removal
retains an on-disk capture of the exact paths so a retry cannot forget residue.
The capture also identifies the installation and its filesystem objects; a
different installation at the same path is not silently removed. Pending
uninstall evidence blocks installation/restoration, and explicit removal refuses
an unfinished installation journal until recovery is resolved. A retained initial
profile without app metadata still resolves its deterministic clone identifier
through the checked service instead of being treated as already removed.

This private iOS interface requires device validation on each supported iOS/
jailbreak combination: delete a clone with plugin containers, remove the visible
source after archiving, retry an already absent app, reject a protected bundle,
and simulate failed service completion or retained containers. The transaction
journal remains available after failed rollback. H05 adds complete keychain
cleanup and durable profile retirement; H12 covers operation lifetimes.

Critical regression prevention during H04: the original registry callers
uninstalled a clone when the following profile write failed, even if the clone
manager had reused an existing working installation. The old unsupported
uninstall command masked this C11 gap. Those callers now preserve the installed
clone and previous/initial profile for recovery and retry. A failed create also
retains its profile while an installation journal may still refer to it.
This guard is part of making the uninstall fix safe, not a claim that disk-write
failure can be treated as successful profile creation.

## H05 — verified credential cleanup and durable retirement

Explicit profile deletion reserves its identifier in a durable journal before
destructive cleanup. Cleanup proceeds through recorded phases; a failed step
keeps the reservation and a visible retry row. Opening, rebuilding and editing
a reserved profile are refused. A completed tombstone remains after the profile
file disappears so that a repeated request cannot recreate or reuse its identity.
The launcher does not report deletion complete until the final journal commit.

Credential erasure is separate from ordinary clone removal, which is also used
by rebuild and recovery. A narrowly signed helper targets only
`RBXCLONE00.<clone-bundle-id>`. It checks its effective entitlements and proves
access using a fresh keychain canary before deleting and checking each supported
item class. An empty query alone is insufficient: Apple's
[keychain access-group guidance](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
explains that an unauthorized group query can report item-not-found. Queries
explicitly select the target group and include synchronizable items using
[kSecAttrSynchronizableAny](https://developer.apple.com/documentation/security/ksecattrsynchronizableany).

Missing authorization, a locked keychain, failed signing, timeout, residual data
or an unverifiable helper receipt leaves deletion incomplete. The original
clone is retained until credential cleanup succeeds. Checked uninstall, owned
local recovery-copy cleanup, proxy/store publication and profile removal must
then succeed. The profile normally remains until the final steps; a crash
between profile removal and the final journal write is represented by the
durable retry row even when restoring the profile file is impossible.

Device validation remains required: prove the helper runs in the intended
mobile keychain context, seed all supported classes in two distinct clone
groups, delete one group and verify the other survives. Exercise locked-device
and denied-entitlement cases, partial uninstall, failure at each journal write
and restart after profile removal. Static checks on Windows cannot establish
those iOS Security and installation-service guarantees.

The cleaner and signer run with bounded deadlines. A durable marker is written
before each helper starts and cleared only after its exit is proven. If that
proof is unavailable, the job remains fenced across daemon restarts and needs
recovery inspection; a new request cannot erase the marker and assume that the
old process stopped.

`tools/test_keychain_cleaner.sh` includes the actual helper with synthetic
Security and credential calls. Its six scenarios cover failed privilege drop,
extra entitlements, failed canary authorization/read, locked keychain, a
retained class and successful cleanup that preserves a second group. It never
accesses a real host keychain. The suite is included in the Mac build preflight;
on this Windows host it is skipped, so no native pass is claimed.

`tools/test_deletion_journal.sh` exercises the actual journal helpers with
temporary paths and injected write, rename, file/directory sync and cleanup
failures. It also checks corrupt records, phase retries and a profile reappearing
after a committed receipt. It excludes device services and is likewise included
in Mac preflight and unexecuted on this Windows host.

Additional verification used portable Clang 19.1.7 with the Theos iPhoneOS15.6
SDK and an iOS 15 target. The cleaner, clone manager, launcher state/controller
and both test sources passed syntax checks. The changed registry, central store
and proxy manager retained only compiler errors reproduced in the preceding
commit: missing `snapshot` accessors, a chained `boolValue` property on `id`,
and six CFNetwork constants unavailable on iOS. These inherited blockers remain
tracked for their relevant fixes and the final build audit. No H05 compiler
error was introduced; no linking or native test execution is claimed.

## H06 — Checked profile and catalog reads

`RBXProfileIO` distinguishes unsafe identifiers, missing files, read failures,
empty data, malformed JSON, non-object roots, malformed known sections and a
profile ID that disagrees with its filename. Reads require a regular file,
reject a final symlink and are bounded to 32 MiB. Optional sections may be
absent for recovery; generation, launch and launcher availability additionally
require the complete consistency policy. The identifier rule is the existing
local rule; cloud/local canonicalization remains H17.

Registry, cloud, proxy, launcher and fingerprint paths use the checked loader.
An unreadable profile inventory or another unreadable identity blocks checks
that need proof of uniqueness. A missing rootless catalog alone permits the
rootful fallback; an existing invalid or unreadable catalog is an error.
Catalog maps, models, OS tuples, screens, carriers and city pools are checked
before lookup or random selection. No empty identity or default country is
invented to hide an unavailable catalog. Catalog results are cached for the
daemon lifetime, so repairing an installed catalog requires a daemon restart.

The launcher includes stored IDs even when their profile files are missing.
Invalid profiles remain visible with a reason and recovery/diagnostics/delete
actions; Open, identity editing and exports are unavailable. An unreadable
inventory has a visible warning instead of claiming there are no profiles.
Fingerprint publication removes stale hashes for unavailable or retired
profiles; only populated, well-typed fingerprint inputs enter collision checks.
The proxy configuration test remains in memory and creates no placeholder
profile file.

Explicit deletion of a malformed profile derives identity only from its safe
filename and retains the original bytes in the private deletion journal before
cleanup. Actual clone ownership and keychain authorization still need the H05
proofs. If the evidence cannot be read or fit in the bounded journal, deletion
fails visibly and retains the source; malformed app paths are never interpreted
as deletion targets.
After profile absence is durable, the completed deletion record removes the
raw recovery bytes and their parsing error. A failed final publication keeps
pending evidence for retry; a completed record that still contains raw bytes
is shown as needing cleanup until compacted.

`tools/test_device_catalog.sh` runs actual loader/catalog/generator/validator
fixtures, including missing-only fallback, empty/read/parse/root failures,
malformed sections and generated-profile round trips. The fingerprint suite
runs the real computation and refresh against in-memory dependencies, checking
invalid inputs, removed stale hashes and valid collision deduplication. Both
are wired into Mac preflight. On Windows both report skipped (77), so runtime
passes are not claimed. Portable iOS 15 Clang syntax checks and the host static
and architecture checks are recorded separately in the phase ledger.

## H12 — Bounded operation ownership and recovery

Each accepted request owns an immutable request token, daemon boot epoch and
monotonic deadline, including time spent waiting in the serial queue. Budgets
are 600 seconds for clone/import/export/recovery and multi-stage refresh,
240 seconds for launch/delete, 60 seconds for diagnostics and 120 seconds for
other actions. HTTP waits and subprocess stages consume the remaining budget.
An independent supervisor publishes one correlated terminal result even when
the mutation worker cannot finish. An unstarted queued timeout has no authority
to close the preceding active session.

The operation context tracks queued work, delayed rotation quarantine, HTTP
tasks and child processes until their callbacks/cleanup finish. Cancellation
stops only owned resources; callback effects must still pass the captured
context check. License responses additionally match the current key, server
and validation revision before persisting authorization or applying a lock.
Cached license authorization is bound to that same key/server combination.

The first mutation durably publishes a private active-operation marker before
effects begin. The marker is removed only after proven quiescence. An earlier
daemon boot's marker, corrupt journal or unproven cancellation creates a safety
fence: subsequent mutations and ARMED/OPEN leases are refused. CLOSED revocation
and its heartbeat mirrors use a narrowly scoped writer and remain available.
The launcher shows the recovery reason and inspection actions can run on a
separate queue if the mutation worker is stalled. Startup establishes CLOSED
and accepts IPC before running migration/recovery as a tracked operation.

The shared process runner uses an owned process group, bounded output, nonblocking
waits, TERM then KILL, and verifies group quiescence before reaping the leader.
Its reserved leader PID prevents signaling a reused process group. Failed
enumeration is uncertainty, not an empty group. Unproven helpers retain their
operation marker and transaction evidence; cancellation does not start destructive
rollback. Successful helper exit alone does not prove a pending installation or
SpringBoard launch request was retracted, so those failures are fenced too.
Trusted helpers are expected to stay in their owned group; arbitrary descendants
that escape with a new session are not proven stopped by group enumeration.

Ordinary local work can be cooperatively canceled; a kernel filesystem call or
private device service cannot be forcibly unwound safely from another thread.
In that case the supervisor reports failure, preserves evidence and blocks new
mutations rather than claiming the work stopped. A safety fence is deliberately
not cleared automatically by a daemon restart. Recovery must establish stopped
work and reconcile the retained clone/deletion journals before clearing it.

Mac preflight now includes actual-source operation-context, request-controller,
child-runner and delayed-license-response fixtures. Cases cover late replies,
queue expiry, one terminal receipt, cancellation waking an absent callback,
inspection during a stalled mutation, durable journal failures/restart fences,
child output limits, TERM-resistant children and stale license credentials.
Integration review also found that synchronous cancellation delivery or a
watchdog waiting on the worker's gate lock could still suppress its failure
receipt. This H12 regression was corrected before proceeding: cancellation
deliveries are independent, revocation cleanup is counted before dispatch,
and unsafe admission fencing is immediate in memory while persistence runs
independently. Receipts never wait under the ownership lock for gate cleanup.
A fixture deliberately blocks both the original worker and CLOSED publication
and checks that failure and diagnostics remain reachable. An unsafe owner keeps
its active marker even after a late drain if writing the unsafe record failed.
Portable iOS 15 Clang syntax checks are recorded separately. Native execution,
linking and real installer/launchd/NetworkExtension cancellation still require
the Mac and target device; Windows skips (77) are not runtime passes.

## H13 — Local IPC and lease-bound numeric endpoints

Every connect/bind/listen/send/write wrapper now distinguishes the descriptor's
actual socket family. Unix sockets retain native behavior in CLOSED, ARMED and
OPEN, including datagrams. Internet datagrams/raw sockets remain denied. An
Internet stream needs OPEN plus the exact authorized peer address and port;
descriptor-only sends check the connected peer rather than trusting a prior
connect. Ordinary file and pipe writes keep native behavior. The optional local
network setting permits loopback TCP under OPEN, not wildcard Internet listeners.

The daemon resolves and canonicalizes proxy addresses before ARMED. The provider
and clone reject empty, malformed, scoped or oversized numeric sets. The clone
uses a matching lease/provider snapshot, bound to container, bundle, boot epoch
and generation, instead of resolving the proxy during hook installation.
Proxy name lookups select a current numeric endpoint in the requested family;
getaddrinfo uses numeric-only flags, legacy host entries are synthesized per
thread, and CFHost objects are built from socket addresses. Raw DNS query/search
and DNSService transactions are refused. These checks do not prove that every
private OS resolver or broker API is intercepted; that remains in the leak audit.

Before issuing readiness, the guard checks real Unix socketpair I/O, IPv4/IPv6
datagram denial, nonblocking ARMED connect denial, and numeric resolver answers.
No fresh DNS is needed to run those checks. The host fixture calls the actual
wrappers with real local sockets, synthetic leases and an Internet-connect spy;
it covers every send family, connected-peer revalidation, stale receipts and
malformed address sets. It is wired into Mac preflight. Portable iOS 15
Objective-C++ syntax checks pass; macOS/iOS execution and actual hook-engine
reachability remain unverified on this Windows host. Provider Swift fixtures
also cover invalid endpoint sets and require the Mac Swift toolchain.

API reference: [Apple CFHost address-based construction](https://developer.apple.com/documentation/cfnetwork/cfhostcreatewithaddress(_:_:)).

## H14 — Checked installation, behavior evidence and MobileGestalt ABI

All 23 active installers now return checked installation evidence. The Substrate
wrapper clears original pointers before installation, requires a distinct C
trampoline, and verifies Objective-C replacement IMPs against the installed
method, with pointer authentication stripped for comparison. Missing required
classes/selectors or symbols fail the group. A returned trampoline alone does
not establish C-hook behavior. The entry point no longer logs 20 unconditional
READY groups or manufactures readiness from a few unrelated successful probes.

The readiness receipt carries versioned installation and behavior dictionaries;
the daemon independently requires every named entry. Probes run against an ARMED
lease and the receipt is issued only if boot epoch, generation, bundle, profile
and upstream endpoints still match afterward. A failed receipt write is reported
as failure. Startup reports distinguish installation from behavior evidence and
identify the tested lease generation and PID. Effective entitlements and a
clone-keychain round trip come from container validation; these are specifically
labelled evidence, not a claim that all OS sandbox behavior has been tested.

Public API probes cover sysctl size queries, short buffers, named/MIB values and
uname, IDFA/IDFV/device/ATT, locale/timezone, timing clocks, sensor/display values,
Metal identifiers, network metadata, process proxy configuration and the H13
socket checks. IOKit probes enter the actual exported scalar/search/bulk APIs;
a thread-local probe input feeds synthetic owned values into the installed
sanitizer without reading a physical registry entry. This verifies detour
reachability and sanitization, not sandbox authorization to real IOKit services.
An unavailable GPU no longer passes its identity test. Resolver installation
loads libresolv and checks both plain and Darwin versioned query/search exports.

MobileGestalt learns each supported key's opaque output code and CF value type
from two calls to the original target provider with different sentinels. Only
the contract is retained; original answer values are released. CFTypeID is used
to validate the object, never as the private output code. Numeric strings are
parsed completely with overflow rejection. Unsupported or incompatible overrides
return no value using the observed target failure-output convention; sensitive
unmapped keys never fall through to the physical provider. The synthetic iPhone
policy explicitly answers IsSimulator=false. Supported overrides are checked
through the public export and provider output ABI; string, Boolean and signed
numeric accessors plus a data answer must match the profile before readiness.
An unknown stub layout, unavailable required accessor, protected required probe
key or unlearnable contract denies readiness. Those target compatibility failures
must be measured on the intended phone rather than guessed into a pass.

Actual Logos preprocessing exposed inherited compile blockers that prevented
verification of these active installers: invalid DeviceCheck/CoreMotion/CoreLocation
SDK names, imports, C++ data pointer conversions and inline/nested %orig syntax.
These were corrected with the supported iOS 15 declarations. Two deliberately
uninitialized legacy hook groups were removed; activating them would restore
obsolete defaults/nonpersistent WebKit behavior. Proxy helper linkage was made
consistent with its header. The six unavailable CFNetwork proxy constants remain
the ordered H15 transport work; a full project build is therefore not claimed.

Validation: actual Logos + arm64 iOS 15 SDK syntax checks pass for every tweak
translation unit except those six existing proxy errors. Changed daemon/shared
sources and actual-source MobileGestalt/readiness and socket fixtures also pass
iOS syntax checks. The new fixture covers opaque non-CF type codes, Boolean,
string, numeric and data answers, missing/inconsistent codes, type mismatch,
overflow, unsupported sensitive keys, missing/failed evidence and a no-op hook
engine. Mac preflight runs it; on this Windows host it exits 77 (not executed).
Link/signing, Substrate behavior on arm64e and real OS enforcement remain hardware
validation requirements. H15/H16 and the phase 3 audit still address broader
transport, clipboard and untested API coverage; this receipt is not proof of
universal unlinkability or exhaustive hook coverage.

## H15 — Authenticated HTTP proxy contract

The supported upstream scheme is now `http://host:port`, with HTTP forwarding
and CONNECT for HTTPS destinations. TLS-to-proxy (`https://`) and SOCKS5 are
rejected by cloud input, launcher settings, daemon activation, lease admission
and provider policy. Existing unsupported records remain inspectable but cannot
launch; they need a supported replacement. An HTTP proxy is not advertised as
a TLS-to-proxy transport. The six iOS-unavailable CFNetwork constants in both
daemon and tweak are replaced with supported inline PAC settings selecting one
HTTP proxy for every destination, with no DIRECT fallback or credentials in PAC.

Credentials are decoded once from explicitly percent-encoded URL components.
Malformed escapes, controls, username colons, empty credential usernames, paths,
queries and unsupported schemes are rejected. Explicit port 80 and IPv6 are
supported. Usernames are preserved without silently trimming meaningful spaces.
The provider sets NEProxyServer authenticationRequired, username and password
for both HTTP and HTTPS destination policies and uses an already leased numeric
address. This applies credentials to OS proxy configuration, including eligible
brokered requests, rather than assuming a clone's CFNetwork dictionary supplies
credentials to another process.

In-process NSURLSession authentication uses a forwarding delegate. It supplies
nonpersistent Basic/Digest credentials only for a first proxy challenge at the
currently authorized proxy host and port, cancels repeated/mismatched/revoked
proxy challenges, and preserves the app delegate's ordinary origin challenge
handling. Shared/default sessions receive the same transport; ambient credential
storage is disabled. The daemon's proxy probe uses the same parser/PAC/delegate
and checks its operation owner before answering a challenge. Clone proxy PACs
use numeric lease endpoints and do not require a fresh hostname lookup.

The provider still reports outOfProcessAuthCovered=false: credential settings do
not establish which app a WebKit/Safari service flow is attributed to, nor the
actual managed OAuth mapping. ASWebAuthenticationSession therefore remains
denied until the phase 3 H08 mapping work establishes that evidence. A successful
daemon IP probe is not labelled a successful OAuth login. Actual out-of-process
login with correct/wrong credentials, redirects and mid-login revocation remains
a hardware validation requirement; it has not run on this Windows host.

Validation: cloud transport cases, the existing 18 helper and 11 authentication
concurrency tests, and TypeScript checking pass. All actual Logos/iOS 15 tweak
syntax checks now pass, as do the changed daemon/launcher/shared sources and the
native proxy fixture. The native fixture exercises real CFNetwork PAC evaluation
for HTTP/HTTPS URLs and the real authentication delegate, including origin
credential separation and revocation; it is added to Mac preflight. Its Windows
exit 77 is a skip. Swift policy cases cover credential decoding and unsupported
schemes and still require the Mac toolchain. These results do not establish
on-device proxy authentication, managed broker routing or login retention.

API references: [Apple NEProxyServer authenticationRequired](https://developer.apple.com/documentation/networkextension/neproxyserver/authenticationrequired),
[Apple inline proxy configuration script](https://developer.apple.com/documentation/cfnetwork/kcfnetworkproxiesproxyautoconfigjavascript).

## H16 — Complete public clipboard blocking without a global clear

Startup no longer assigns empty items to the real system clipboard. The existing
blocked clipboard policy now covers arrays of URLs/images/colors, item providers,
object writers, indexed reads, type/content queries, change metadata, item options,
named/unique board factories and all four detection callback families. Callbacks
complete with empty results. The general board is an intercepted view; named
and unique board creation is denied. No copied content is shared with another
profile or written into Universal Clipboard by these public methods.

UIKit may return a concrete subclass whose override bypasses a base-class hook.
Blocking instance hooks are therefore installed on the base class and mirrored
onto differing concrete overrides, with checked IMPs. This helper is limited to
methods that never invoke an original trampoline. Readiness now requires clipboard
behavior checks for scalar/array/provider/indexed/query and detection APIs. The
probe never writes content: an incorrectly installed hook must not overwrite the
user's clipboard as a side effect of discovering its own failure.

Validation: an SDK-driven check finds coverage for all 53 public entry points in
the iOS 15.6 UIPasteboard header and is added to Mac preflight so a newer SDK's
uncovered APIs fail visibly. All tweak Logos/iOS syntax checks pass. The existing
actual-source hook fixture now reproduces an Objective-C subclass override bypass
and verifies installing the blocking replacement there; its iOS syntax passes,
but native execution still requires Mac Foundation. On-device acceptance must
place a sentinel in another app, open/switch clones, exercise every clipboard API
family and confirm the other app's clipboard stays unchanged. Private APIs,
system notifications and newer OS behavior remain in the phase 3 audit. The
current product policy intentionally disables paste/copy; it does not claim a
usable shared clipboard for login or cross-app workflows.

## H17 — Exact profile IDs and durable deletion reconciliation

Creation and the cloud wire contract accept 1–128 ASCII letters, digits,
underscores and hyphens. Neither side trims or rewrites a supplied ID; case-only
collisions are rejected for compatibility with phone filesystem semantics.
Default phone IDs use UUIDs. Both implementations consume one fixture set in
their tests. Existing unsupported IDs remain available for explicit recovery or
deletion; migration does not silently rename their identity or archive.

Cloud profiles, proxy assignments and permanent deletion tombstones now share
one CAS/atomic document. Deletion removes the live profile and releases its
proxy in that same transaction. All generic writers validate retirement, so a
stale profile, proxy or rotation-auth writer cannot resurrect a deleted ID.
Tombstones cannot be removed or retargeted through collection updates. A backup
alone is not live inventory and cannot implicitly create an unbound profile or
receive proxy/rotation authorization: first restore/register it on its device.

Deployment requires stopping old-version cloud writers before the first new
writer migrates profiles/proxies into inventory-state. Original collection files
remain migration backups and are never read again after the authoritative
document exists. Invalid legacy IDs or case collisions stop migration before
commit, with an explicit repair error. Migration of the separate older
profile-proxy-assignments collection is still H22, not claimed by this change.

The phone persists server/device provenance before publishing a local profile
or creating a cloud-imported profile. Delete copies that binding into its
durable journal, including the compact completed tombstone. Refresh first posts
bound local deletion intent in bounded batches and verifies the response, then
validates the complete cloud inventory, records remote retirements and imports
only available IDs. It verifies actual returned IDs rather than assuming local
creation preserved them. A lost response leaves the journal intact for an
idempotent retry. A delete before an uncertain first publication can retire its
device's not-yet-published ID. Other-device live or retired IDs cannot be claimed.

A remote retirement gates the local profile and closes/stops an active lease;
the launcher exposes pending local cleanup for its existing Delete action.
Local deletion success explicitly says cloud reconciliation happens on refresh.
Unchanged refresh does not close a live profile. Legacy unbound deletion receipts
still prohibit local resurrection but cannot authorize deletion in a potentially
different cloud account. Conflicting legacy/unbound local and cloud IDs preserve
local data and report explicit recovery rather than infer a transfer. Launch's
credential refresh no longer silently publishes profiles; unregistered local
profiles require inventory refresh first. These legacy recovery limitations must
remain visible in the final UX report.

Validation: nine actual-storage/route inventory cases pass, covering exact IDs,
case/device conflicts, injected atomic commit failure, idempotent deletion,
assignment release, stale writers, offline intent, publication/deletion races,
retired/backup-only API writes and corrupt-authority handling. Existing 18 helper
and 11 authentication concurrency cases pass, including separate OS processes;
TypeScript checking passes. Windows tsx fails before loading tests in its OS-user
lookup; these executions used the installed TypeScript compiler with a temporary
CommonJS runner (same sources and independent-process storage tests).
CloudSync and the extended native journal fixture pass iOS 15 syntax checking.
Registry retains the original five errors involving the nonexistent snapshot
selector (git blame traces them to a9acd19); no new syntax errors were introduced.
Native Foundation execution and phone/cloud offline-delete/restart/active-revoke
tests remain hardware/Mac requirements, not claimed passes.

## H20 — Daemon-only per-profile rotation credentials

Per-profile rotation authentication now uses a separate Keychain service and
the `RBXBOXCFG.com.redditbox.daemon-control` access group. Only redditboxd's
entitlements grant that group; it is absent from launcher/provider and generated
clone entitlements. Entries are keyed by the exact profile ID, explicitly
non-synchronizable and `WhenUnlockedThisDeviceOnly`. Save and deletion verify
readback; malformed, locked or failed reads stop rotation instead of falling back
to plaintext profile fields. An explicit clear leaves an empty override record
so an older profile copy cannot silently restore the cleared secret.

Cloud refresh writes this store instead of profile.proxy. Startup migration
first saves/verifies a legacy profile's header/value, then atomically removes
control metadata from the profile. Existing secure values win on a retry.
Deletion removes the profile's daemon credential as part of its retryable
cleanup checkpoint. Imported archive metadata cannot establish rotation control
authority; credentials must come from the paired cloud configuration.

All profile publication boundaries apply the same redaction: daemon profile
writes, signed bootstrap JSON, clone-local JSON and cloud backup envelopes.
The proxy section is restricted to connection URL, proxy ID and country; those
connection credentials remain necessary for the selected authenticated transport.
Bootstrap/local files use checked 0600/mobile ownership. Backup staging excludes
the older clone-local profile file before archiving, with checked removal and
symlink-parent rejection. Clone reuse/validation reads the actual bootstrap and
rejects a non-redacted legacy bundle. The existing clone transaction rebuilds it
from the source before reuse; IPA export also requires that validation.

Validation: changed secret store, CloudSync, ProxyManager, CloneManager and the
actual-source Keychain fixture pass iOS 15 syntax checking. The fixture uses
synthetic Security calls and covers exact access group/accessibility, per-profile
separation, corrupt/locked/failed operations, migration, explicit clear, redaction
and verified deletion. It is added to Mac preflight; native execution has not
run on Windows. Existing clone and launcher architecture checks pass. Effective
Keychain entitlement enforcement on the jailbroken phone remains a device test.

This prevents future distribution through these known profile paths. It cannot
retract a credential already read by a previously installed clone, copied by app
code, or included in an older exported archive. Previously exposed rotation
credentials must be replaced at their control service; retained recovery
artifacts remain private and are not treated as clean export sources.

## H21 — Quiescent backups and pre-publication restore validation

Cloud backup/restore retains the main request controller's operation ownership.
Export resolves its source, persists CLOSED, kills and proves absence of clone
processes, then waits for maintenance closure before reading app data. Restore
does the same before creating its destination profile or copying restored data.
No operation reopens traffic at completion; opening a profile remains an explicit
launch transition. This uses the same NetworkGate/ProcessController enforcement
as switching, including its bounded errors and operation deadline.

Snapshot copying hashes every regular file, records source file identity/size/
mtime/ctime and requires identical source inventories before and after copying,
plus matching staged contents. Links and special/unreadable entries fail the
snapshot. Any process or broker that changes a file during capture causes an
error and no upload. Staged SQLite databases are opened read-only with bounded
busy/progress handling and `quick_check(1)`; their WAL files are copied as part
of the same stopped tree. Restore checks databases in the extracted tree before
writing a profile. Encrypted/unsupported files named .db/.sqlite/.sqlite3 are
explicitly rejected rather than labelled integrity-checked. This cannot prove
application-level consistency across unrelated files beyond the stopped-process
and unchanged-copy evidence; app-specific/session checks remain on-device work.

The candidate imported identity now runs the same consistency and cross-profile
uniqueness checks as launch before profile publication. An existing source or
another restored copy with matching unique identity values rejects the import.
A fresh UUID-based local ID stays within the H17 canonical contract. Central
registry publication is checked before reporting import success; failed recovery
retains its staged source and operation record.

The archive transfers app files and profile metadata. It does not export the OS
Keychain group or transfer device-bound keys. The encrypted manifest explicitly
records this policy; launcher completion messages state that login must be
verified and sign-in may be required. A restored username is never sufficient
for a known-login row. Legacy profile-only archives are labelled metadata-only.
No arbitrary third-party Keychain export or claim of a reusable logged-in session
was added. App-held session tokens may survive in the copied files, but only an
actual authorized login/browse/relogin test can establish the restored behavior.

Validation: changed snapshot, CloudSync, launcher state/UI and the native snapshot
fixture pass iOS 15 syntax checks. Registry still has the five original snapshot
selector errors, with no additional syntax errors. The actual-source fixture
covers a committed but uncheckpointed SQLite WAL, restored row contents, source
mutation during copying, canceled ownership, symbolic links and corrupt database
rejection. It is included in Mac preflight; native execution has not run here.
Hardware acceptance must backup A while open, prove A stops before copying,
restore with A absent locally, verify SQLite integrity and actual login behavior,
and reject a second restore while its identity is still present.

## H22 — Versioned legacy proxy-assignment migration

First inventory access migrates `profile-proxy-assignments` into each proxy's
assignedProfileId under the same inventory CAS commit as a versioned completion
marker. It also upgrades an existing H17 inventory document without re-reading
stale profile/proxy collection files. A competing migration uses the latest
committed document; after completion the legacy collection is never replayed.
Subsequent unassignment, reassignment or deletion therefore remains authoritative.
New writes through the deprecated collection interface are explicitly rejected.

Migration validates same-owner proxy/profile references and one-to-one claims
across both old and current representations. Identical duplicate claims can
coalesce; conflicting claims, case aliases and missing live profiles stop the
migration without committing partial results. Tombstoned profiles are skipped,
counted in the migration receipt and never resurrected. Profiles/assignment GET
responses expose an actionable 503 migration error. Legacy collections remain
unchanged for explicit repair. Stop old cloud writers during deployment; an old
server does not understand the new authority or completion marker. Backup-only
legacy IDs require explicit registration/data repair and are not auto-assigned
to an invented device.

Validation: six migration groups pass against actual local storage and real
device/console GET handlers: concurrent first use, both response shapes,
no replay after unassignment, upgrade from H17 state, multiple conflict forms,
injected commit failure/retry and retired-ID suppression. Nine H17 inventory
cases and eleven authentication concurrency cases also pass, along with
TypeScript checking. Tests use synthetic scratch data only; production Vercel
Blob ETag behavior still requires deployment validation. The version marker and
assignment changes use its existing one-document CAS implementation.

## M01 — Remove unused global switches

Removed launcher Enable RedditBox and Random IDFA switches and their unused
preference writes. Settings now points to the existing per-profile Identity
editor for IDFA posture and explains that protected launch is required for
traffic. Default-country selection remains wired to the creation form. Legacy
preference values have no authority to bypass CLOSED or alter an identity.
The changed Settings controller passes iOS 15 syntax checking.

## M02 — Rootless PreferenceLoader staging

Both creation and copy destinations now include THEOS_PACKAGE_INSTALL_PREFIX.
With the rootless /var/jb prefix the entry stages at
`/var/jb/Library/PreferenceLoader/Preferences/RedditBoxPrefs.plist`.
The source path and plist are unchanged. A final built .deb file-list inspection
still requires the Mac/Theos packaging run; no package was produced on Windows.

## M03 — One heartbeat age contract and separate policy timestamp

Provider status now publishes heartbeatAt on its existing periodic timer and a
separate policyAppliedAt only after a current successful settings application.
An in-flight/obsolete application has no policy-applied timestamp. Daemon ACKs,
socket gating, clone mirroring, diagnostics and launcher VPN status all require
the same finite, non-future heartbeat age of at most 2.5 seconds. Provider policy
reads enforce that same daemon-heartbeat bound. Diagnostics also compares the
epoch and active tuple, and cannot pass an old enforced flag on its own.

There is no timestamp fallback for older providers: upgrade/start the matching
provider before protected launch. Native boundary cases cover exact expiry,
future, absent/wrong-type and nonfinite timestamps; Swift policy cases mirror
the boundaries. Changed native sources and the socket Logos source pass iOS
syntax checks. Native/Swift fixture execution still requires Mac; on-device
acceptance must leave a policy unchanged for several seconds, then suspend each
heartbeat producer separately and verify expiry closes admission and status.

## M04 — Deferred-setup smoke checks and correlated final evidence

Smoke setup/launcher/profile/clone modes no longer require a provider status file;
source-cache validation has its own explicit mode. Setup checks local CLOSED and
launcher publication. Status/production/log modes retain the configured-provider
requirement. The checklist now uses the actual final order: hook readiness,
provider OPEN acknowledgement, NETWORK OPEN. It uses the final mandatory-check
receipt rather than treating an early control-state wait or another generation's
NOT_READY log as the tested launch result.

These three daemon events now include full request and generation UUIDs; final
hook verification also logs the receipt's clone PID. The optional shell log mode
requires that exact tuple, and the shipped AWK checker rejects missing evidence,
wrong PID and out-of-order acknowledgement. Nine synthetic log cases execute the
actual checker and pass. Shell syntax and the changed NetworkGate iOS syntax
checks pass. This checks final authorization ordering, not external packet
capture or the truth of an OS routing association. Launcher Diagnostics/Share
Logs remains the user-facing workflow; device execution is still required.

## M05 — Device-scoped profile credentials and explicit global sharing

Device-token profile inventory and proxy/rotation-override delivery now use the
same registered device filter. Another device's secret is not decrypted at all.
Health mutation checks the proxy's current assigned profile/device within the
inventory transaction. H17's immutable device registration also rejects an
implicit transfer through profile POST or deletion/reconciliation from another
device. Device-authenticated device listings return only the caller's record.

Encrypted backups can include profile proxy credentials, so device-token list,
download and deletion are restricted to the backup's owner AND originating
device. Upload requires a live profile registered to that device. Owner-console
access remains account-wide. Automatic factory-to-worker backup transfer through
an ordinary device token is therefore unavailable; no implicit transfer or new
sharing feature was invented. A future explicit owner-authorized transfer needs
its own reviewed contract. Same-device restore remains supported subject to H21
identity-collision and login limitations.

The existing global-settings feature intentionally shares one gateway/rotation
configuration. Its save button now explicitly says it shares with all current
and future paired devices; the API requires the owner's explicit
deviceAccess=all-paired grant. Legacy records without that grant return an error
to devices until the owner saves them through that action. Per-profile overrides
remain device-scoped even when global settings are shared. This is an explicit
shared resource, not a claim that global credentials are isolated by device.

Device authentication now awaits last-seen persistence and rechecks the token,
device owner and existing user in that transaction. A concurrent token revocation
cannot return the stale authenticated device. This also removes detached writes
that the two-device test exposed after HTTP completion.

Validation: seven groups pass through actual authenticated handlers with two
devices under one synthetic owner, including secret delivery/non-decryption,
transfer/deletion denial, health scope, backup scope/upload, explicit global
grant and revocation between read and commit. Six migration and eleven auth
concurrency groups still pass; TypeScript checking passes. No live account or
secrets were used. Previously delivered credentials cannot be retracted from
another phone's memory/files; replace credentials that need revocation. Cloud
API scope is proven here with synthetic local storage, not a production rollout.
