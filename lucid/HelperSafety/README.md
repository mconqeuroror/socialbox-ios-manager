# Checked helper process drain

This source-owned adapter replaces the **one-BOOL** `_Zw5h::killApp:reply:`
method in the pinned original helper with a request to a separate root Mach
service. It uses the existing exact-registration/process-birth/RunningBoard
backend; it never falls back to `killall`, executable-name matching, or a raw
caller-supplied PID. All 16 main applications in the reviewed injection filter
are registered in `../Switching/LBXManagedApplications.def`. This list excludes
the manager, Settings and standalone extensions. Extensions must resolve inside
the parent's actual installed bundle. X/Twitter is not in that reviewed filter.

The original helper sets `SIGCHLD` to `SIG_IGN` at entry (`SocialBoxHelper.c`,
function `0x1000278f8`, lines 23508–23510), while its stop worker ignores
`waitpid` failures with a zero-initialized status. The new adapter does not spawn
or wait for a subprocess and does not change the original signal disposition.
The root service carries the narrow RunningBoard permission separately;
original program signatures/entitlements and licence behavior are unchanged.

The service authenticates each message with its kernel-provided audit token and
`proc_pidpath_audittoken`, requiring exact root-owned, non-writable helper/manager executables. The `.8` service additionally reads the approved file through a nonblocking, no-follow descriptor, checks its exact size and SHA-256, rejects hardlinks and changes during the read, then resolves the same audit token again. Reusing the path with different bytes is refused. This checks current disk bytes and kernel process identity, not loaded-image memory or every injected library. The manager may also call as mobile; other paths/users are refused.
The protocol has an absolute monotonic deadline, strict version/app/request
binding, bounded JSON, a serialized backend and a hard service watchdog. The
client reports exactly once, rejects stale/foreign/incomplete replies and
cancels its connection. Queued requests consume their original time budget.
A success means two complete absent observations, **not a launch/network fence**.
The hook checks the original whole-file SHA-256, UID, executable path, method
image and exact recovered type encoding before replacing the method.

Build with Xcode's current SDK (the original 16.5 SDK lacks XPC headers):

```
make -C lucid/HelperSafety TARGET=iphone:clang:26.5:15.0 FINALPACKAGE=1 TARGET_CODESIGN="$LDID"
bash tools/test_helper_safety.sh
bash tools/test_recovered_process_drain.sh
```

`LBXHelperSafety.dylib` uses an executable filter restricted to `SocialBoxHelper`
in the existing jailbreak injection directory. Its constructor additionally pins
the original whole executable, root UID, path and method ABI. This does not add
a filter for any target app, system service or licence routine. The existing
MobileSubstrate → TweakInject alias is preserved.

Physical testing found that the `.6` launchd `DYLD_INSERT_LIBRARIES` setting was
absent from the registered job and the helper did not map the safety library.
Reloading the job did not repair this. A private executable-filter probe loaded
the exact signed library and emitted `LBX_HELPER_DRAIN installed=yes` on the
actual original helper. `.7` packages that filter and restores the original
helper plist bytes. See `docs/release-evidence/helper-loader-2026-09-22.json`.
This establishes helper method installation, not end-to-end isolation.

The `.9` builder accepts `--upgrade-from-candidate <exact .8 archive>`.
Only the hard-coded `.8` archive SHA-256 is admitted; reports are not trusted as
an authority. Both external preflight and incoming preinst verify every prior
payload hash, root ownership/mode and all three installed controls. External
preflight requires `installed`; the incoming preinst additionally admits dpkg's
reviewed transition states. Unknown controls, versions and foreign destination
files fail before unpack. Original base upgrades retain their existing guard.

**Integration boundary:** the replacement method now has a concrete checked
service path and retains its existing callback ABI. Original switch workers
that discard that BOOL still need an acknowledged transaction boundary before
storage changes. This unit cannot make their unchecked writes atomic, prevent
new launches, close network sockets, or transfer clone-only isolation results.
Do not promote ADOPT-003 to covered or install it as a complete isolation fix.
Original app, CLI and target-engine metadata writers remain separately tracked
in `../Switching/INTERPOSITION_BOUNDARY.md`.

Private package `3.1.0-1+socialbox.9` retains executable-filter wiring and caller-file verification, and adds a read-only authenticated startup check. Build it with
`scripts/build-socialbox-helper-safety.py`; the exact-base guard, separate
com.redditbox migration block and original-postinst rollback preparation remain.
Original program bytes and helper launch plist bytes are unchanged. Service starts before the helper and stops after it.
The OLD rollback postinst does not depend on the new service being unpacked.

On 22 September the actual service binary booted on the connected iPhone X /
iOS 16.7.16. All three required private symbols were available, and an unrelated
root caller was refused, with a matching service-side rejection log. The service
was then stopped and unregistered. This was a temporary acceptance service,
not an upgrade or an injection into the original helper. See the sanitized
`docs/release-evidence/helper-safety-2026-09-22.json` receipt.

The `.4` candidate additionally connects the specific per-app stop callsite to
the checked service and its existing pre-write timeout cleanup. See
[the per-app contract](PER_APP_STOP.md) for the exact scope, device tests and
remaining global/transaction gaps. Its app-only guard does not trust a legacy
helper BOOL, and the manager executable is packaged non-group-writable.

The `.5` candidate also installs the checked global metadata writer/mutator.
[Its contract](GLOBAL_METADATA.md) records exact scope, forty-update concurrency
and interruption tests, physical-device fixture results and remaining writers.

## Caller-file regression — 22 September

The previous service admitted a different root-owned executable at either
approved path. The peer regression failed before this repair. It now passes
53 assertions, including process exit/exec during the file check. Another 45
assertions exercise the real filesystem: equal-size changed bytes, ownership,
writable files, symlinks/hardlinks, FIFO, interrupted/short reads, truncation,
atomic replacement and chmod during hashing. Both suites pass on the Mac and
iPhone X. A separate read-only invocation of the production verifier accepts
both installed original programs; that is not an original-app switch test.

The full helper suite has 569 passing assertions; the existing drain suite
has 281. See `docs/release-evidence/caller-pinning-2026-09-22.json` for build and
installation results and the remaining integration boundary.

## Authenticated startup check

After the exact original helper method is installed, `.9` sends one `check`
request to the privileged service. It carries a fresh nonce and deadline and
no application, executable path or PID. The service first applies the same
kernel-token and caller-file authentication as a drain; a valid check returns
before any target resolution, process snapshot or termination. Missing/extra
fields, late replies and a drain receipt cannot satisfy this check. The client
completes once and cancels the connection. No readiness flag or gate changes.

Correlate the same request nonce in the helper's `operation=check
result=authenticated` log and the service's `authenticated_check` log; the
helper separately logs `service_authenticated=yes scope=read_only_round_trip`.
This is positive IPC/authentication evidence. It does not prove that a target
can be stopped, data switched, networking contained or a user licence accepted.
There is no retained/reusable launch-admission receipt.

The helper suite now has 636 passing native assertions. The 129 protocol and
87 client checks also pass on iPhone X, with transport boundaries mocked in the
client suite. Actual helper/service evidence is recorded separately in
`docs/release-evidence/service-check-2026-09-22.json`.
