# Recovered-backend process drain — 22 September 2026

This is the first executable source-owned backend unit for the recovered
SocialBox application. It builds as **`socialbox-drain`**, a private, one-shot
root acceptance tool. It is **not yet wired into the original switch workers
or included in the `.2` upgrade candidate**. Existing app UI, licensing,
container files, network policy and original executables are unchanged.

The original `_Zw5h::killApp:reply:` kills by executable name and can mistake
a failed `waitpid` for success. Its callers also ignore failure acknowledgements.
See [the instruction/call-site evidence](INTERPOSITION_BOUNDARY.md). This unit
implements the replacement stop operation without reusing those assumptions;
it does not pretend that returning a better BOOL fixes the original callers.

## Operation

Only the exact 16 source applications in `LBXManagedApplications.def` are
accepted, including Instagram, Facebook and Reddit. Registration in that policy
does not establish app launch or isolation acceptance. No arbitrary PID, bundle
path, executable name, clone prefix or shell fragment is accepted. More
applications need an explicit reviewed policy extension.

1. Resolve the installed application through LaunchServices. Require the exact
   UUID-based iOS app installation path, a matching Info.plist and registered
   canonical executable. Verify ownership/mode and reject symlinks inside the
   resolved bundle. Read metadata through a bounded `O_NOFOLLOW` descriptor.
   Normalize only the documented `/var` alias after Foundation resolves and
   standardizes paths: on the tested iPhone, both APIs shorten `/private/var`.
2. Inventory its main executable and embedded `.appex` executables. Unknown,
   inaccessible or foreign extensions fail resolution. Fingerprint registration,
   file identity and metadata. A trusted read-only extension executable without
   execute permission is still inventoried by its exact metadata path. The tool
   never launches it; missing, writable, user-owned and symlink files still fail.
   The main app retains its execute-permission requirement.
   Ancestor directory timestamps are intentionally
   excluded: unrelated filesystem work must not look like an app replacement.
3. Read a complete kernel process table. A live unreadable or changing process
   invalidates the observation, rather than being silently omitted. PID 0/1,
   the helper itself and zombies are excluded; shared system services are never
   kill targets. Match exact executable paths, recognizing only the documented
   `/var` → `/private/var` alias while retaining the raw kernel identity.
4. For drain mode, capture the complete target set before effects. Recheck
   registration and deadline before each termination; use the existing
   `RBXTerminateObservedProcess` RunningBoard handle predicate with PID, birth,
   executable and audit-token-bound kernel-path revalidation. There is no `killall`, numeric-PID fallback,
   subprocess, or child wait. Denial, replacement or partial failure aborts.
5. Require two complete absent observations separated by a 20 ms pause and a
   final registration/deadline check. A new app/extension process causes failure
   rather than being killed using the earlier authority. Already-stopped apps
   succeed only after the same observations. A successful terminate request is
   never called a completed exit.

The cooperative deadline defaults to two seconds in the CLI; a six-second
independent watchdog terminates a stuck CLI without a success receipt. The core
also has a 256-observation cap. JSON identifies the caller's request UUID,
registration fingerprint, initially observed process births and termination
requests. Status is `observed_absent`, `observed_running` (inspection only), or
`failed`. Error text does not include account, proxy or licence material.

The tool never writes a container, switches an identity, changes a gate, calls
an original binary, or installs a hook. It is not setuid and starts no service.
Its newly signed executable requests `platform-application` and the narrowly
scoped `com.apple.runningboard.terminateprocess` service entitlement. The source
SocialBox daemon uses the same primitive and entitlement. No task-control,
debugger, all-task-port or new keychain permissions were added. Denial remains
failure; there is no direct PID or name signal fallback.

The prior Mach-task implementation is **invalid on the tested iOS 16 phone**:
`task_terminate` refuses BSD-backed tasks, even when a task right is available.
The earlier mocked success was not physical acceptance. The replacement checks
RunningBoard's handle audit token with `proc_pidpath_audittoken`, rechecks birth
and path, then sends a handle predicate (identity + PID). The final dispatch
belongs to the system service: it is **not an atomic PID-version-bound signal
proof**. In particular, do not reuse the old claim that holding a task right
makes termination race-free. An independent launch fence and observed absence
are still mandatory before data changes.

## Build and acceptance interface

Use the configured Theos/Procursus environment, then:

```sh
make -C lucid/Switching all FINALPACKAGE=1 TARGET_CODESIGN="$LDID"
```

Output: `lucid/Switching/.theos/obj/socialbox-drain`, arm64 + arm64e.
It is deliberately a separate target from `lucid/Makefile`; the original `.2`
package builder must continue to exclude it pending acknowledged worker wiring.

On a reviewed root SSH acceptance session, after copying/verifying the exact
private artifact, the interface is:

```text
socialbox-drain inspect com.facebook.Facebook <fresh-request-UUID>
socialbox-drain drain com.facebook.Facebook <fresh-request-UUID>
```

Inspection is read-only. Drain intentionally stops that application and its
embedded extensions; use a test session after saving user work. Exit codes:
0 = observed absent, 3 = observed running in inspection, 1 = failed operation,
64 = usage error, 77 = not a root session, 74 = output failure, 124 = watchdog.
No output, truncated JSON, a different request UUID, nonzero exit or helper
death must never be promoted to a successful drain by a future caller.

## Evidence and remaining integration

**PASS, host:** `tools/test_recovered_process_drain.sh`: 46 orchestration
assertions and 235 actual Darwin-adapter assertions with filesystem, process
and LaunchServices boundaries mocked. These include main/extension targeting,
same-name unrelated apps, interrupted reads, process-table growth, denied
enumeration, PID reuse, relaunch, registration changes, partial failure,
timeouts, and absence versus requested termination. Tests reproduced and fixed
a late-stop deadline bug and the `/var` alias mismatch in this new code.
`tools/test_process_identity.sh`: 402 assertions on the replacement primitive,
with kernel/RunningBoard boundaries mocked. No real process was signalled on Mac.

**PASS, build:** both iOS architectures compile and Procursus ldid signs the new
tool. The full source-owned `scripts/build-mac.sh` also completed its checks,
Xcode archive and rootless package build with the existing cloud public key.
Independent package readback confirms the RunningBoard entitlement in both
daemon architectures and no new task-control grant. This separate source build
has test version **0.1.0**, is **not** an upgrade of installed 0.1.39 and does
not contain the recovered runtime. It was not installed or published. The
private receipt records hashes. No Apple signing team or original program
modification is used.

**PASS, connected iPhone X / iOS 16.7.16:** three successive executions of
`tools/device_process_identity_probe.m` stopped only the selected owned child
under the mobile UID (five threads), refused a deliberately stale birth, and
left its same-executable sibling alive. Each stop took 29 ms, ended by SIGKILL
and needed no fallback cleanup for the target. All six children were reaped.
A private unentitled control request was refused by RunningBoard.

**NOT_RUN:** actual Facebook/Reddit app and extension termination, launch-fence
integration, watchdog under a blocked service, cross-container data probes and
network capture. Neither original application was installed when the attached
phone was inspected; both exact registrations were correctly refused. The
acceptance tools are staged privately, not installed as an app update. The
recovered `.2` package's read-only upgrade preflight also refused the coexistence
of `com.redditbox`; the existing app and data were preserved. Installed original
postinst/prerm hashes match the supplied baseline. See the
[physical receipt](../../docs/release-evidence/process-stop-device-2026-09-22.json).

**PASS, 1 October 2026, Instagram 448.0.0 on iPhone X / iOS 16.7.16:**
the standalone private helper inspected the running Instagram main process,
requested its identity-bound stop and observed two complete absent snapshots.
An independent inspection again observed absence without a stop request.
Instagram reopened, was observed running and displayed the signed-in feed.
All five original app/CLI/daemon/engine/presentation payload hashes were
unchanged. The exact private helper was removed after verification. The
earlier registration failures are retained in the
[safe receipt](../../docs/release-evidence/socialbox-instagram-drain-2026-10-01.json).
They reproduced Foundation alias normalization and a non-executable embedded
extension. New failing-first regressions pass: 54 orchestration and 334 Darwin
adapter assertions; OS boundaries remain mocked on Mac. Both iOS slices build,
the ad-hoc signature verifies strictly and the two existing entitlements match
readback. Only arm64 was physically executed. This is a process-stop result,
not a switch transaction, extension-launch test or account-isolation result.

**Still unfinished:** the original async, batch, creation/import and CLI writers
must consume a transaction-bound result *before* storage changes, under a shared
launch/write fence, with checked persistence and interruption recovery. The
original BOOL callback is not that boundary. This tool's receipt explicitly
states `networkFenced=false`, `launchesFenced=false`, `reusableAdmission=false`.
Even two empty process snapshots cannot stop a launch after observation or drain
shared URLSession/WebKit services. Neither network isolation, cross-container
data isolation nor account unlinkability is established by this unit. ADOPT-003
therefore remains **gap**; do not enable a legacy switch based only on this JSON.

## Root-observed registered Instagram binding — 1 October 2026

`LBXInstalledApplicationBinding` is a separate read-only root consumer.
`observeOfficialInstagram:` owns lookup of exactly `com.burbn.instagram`;
`matchesCurrentInstallation:` repeats that fixed observation and compares the
complete immutable snapshot. No caller path/backend/PID, stored receipt parser,
license Boolean, launch or data/group operation is accepted. The object is not
a transferable permit. It is not connected to current container UI, metadata
IPC, closed allocation or target runtime.

Production first enforces UID/EUID 0. It captures raw LaunchServices bundle and
canonical executable paths with only the explicit `/var` to `/private/var`
alias; it never generally resolves interior symlinks. The existing Darwin
resolver is a before/after cross-check. Descriptor traversal independently pins
trusted root/installd-owned non-writable ancestors, bundle/extension directories,
main and embedded executables and Info.plist files. Nonempty ACLs, symlinks,
hard-linked regular files and missing/changed nodes are refused. The main needs
execute permission; a retained read-only embedded binary is inventory only.

The private snapshot includes registered installation UUID, paths/fingerprint,
directory identities, file metadata/content SHA-256 and exact extension
inventory. Files are read through held descriptors and checked before/after;
relevant PlugIns membership/absence is recaptured after final registration
queries. Directory timestamps are omitted so unrelated installations do not
invalidate ancestors. Matches never mutate the original snapshot. Public status
and descriptions contain only fixed flags/counts. Never log/export the private
snapshot, installation UUIDs, paths or digests.

The cooperative 30-second budget begins before registration and checks returned
queries, hashing and final completion. It cannot cancel a blocked system query
or regular-file read. Descriptor hashing is bounded to 2 GiB, 512 MiB/executable
and 1 MiB/Info.plist, with at most 128 embedded extensions and a 256 KiB snapshot.
Legacy resolver's separate bounded metadata reads are outside that byte counter.
There is no hard watchdog, future-launch fence or lifetime authority. Registered
file digests do not verify Apple/Meta publisher signatures, a code-signing seal
or loaded Frameworks/dylibs/resources.

PASS — 520 filesystem fixture assertions and 4 production-host root/provider
boundaries. Strict arm64/arm64e shipping compilation excludes all 3 test-only
fixture hooks. Actual filesystem counterexamples cover writable/ACL/symlink/
hardlink nodes, content/inode/plist/registration/reinstallation drift, immutable
redaction and late extension/PlugIns inventory changes. Earlier compile and test
failures remain in private evidence.

PASS — The final unentitled production probe on iPhone X / iOS 16.7.16 passed 21
root observations, actual UID501 factory denial and 16 independent specified-file
content comparisons. Seven embedded extensions were inventoried. Repeated
observations preserve the exact snapshot, and the actual registered canonical
path exercises `/var` alias normalization. Independent shell hashes compare
contents; they do not establish descriptor lifetime or admission. Exact private
cleanup and six unchanged installed owner payload hashes pass. A first private
reply encoded a denied result as integer 1; its strict rejection and cleanup are
retained, with a fresh Boolean-corrected probe passing.

UNVERIFIED — A private read-only main-app LaunchServices audit observed data
directory metadata and three group URLs/three declared groups, without reading
contents. This is not validated storage ownership or a complete extension/shared
writer/broker or signed-entitlement inventory. Group names, paths and identifiers
remain private.

NOT_RUN — Full code-signature/whole-bundle verification, extension data/group
registration and complete shared writers, source UUID/configuration/allocation
transaction binding, target identity hooks, UI/mobile runtime IPC, launch/write/
network fencing, automatic switching, ongoing session licensing, real account
A/B/A, Facebook/Twitter/proxy acceptance, reboot/power loss and fresh customer
installer/download. The standalone host alias fixture is NOT_RUN separately from
the actual phone canonical-path alias check. Only arm64 ran physically.

Evidence: [registered Instagram binding](../../docs/release-evidence/socialbox-installed-instagram-binding-2026-10-01.json).
