# Actual Facebook clone acceptance — 18 September 2026

**FAIL: cross-container filesystem isolation is not enforced on the tested iPhone. Facebook remains inactive.** A helper-only PASS was insufficient: two actual Facebook clones could read each other's synthetic canary files. No account was logged in, and no online or MDM acceptance is claimed.

The results below are historical. The subsequent durable lifecycle integration and installed 0.1.35 candidate are documented in [the follow-up](storage-lifecycle-0.1.35.md). Directory-metadata and managed-network gaps remain open.

## Test boundary and results

Device: iPhone 8 (`iPhone10,4`), iOS 16.7.16, palera1n rootless. Source: decrypted Facebook 578.1.0 / 1063022819. Both copies were created and signed through the actual clone manager, installed through AppSync/appinst and launched through LaunchServices. They had distinct OS homes, bundles and three distinct Keychain groups. Their executable entitlements contained only application/team identifiers and the exact three clone groups; no original Facebook App Group/iCloud entitlements were retained.

A private build enabled the Facebook descriptor solely for these disposable offline clones. The production registry remained inactive. A separate diagnostic dylib was filtered to the two exact bundles; the normal Facebook injection filter was temporarily excluded to prevent duplicate classes. `defaults-wire` stayed false, no lease was opened, and the phone had neither IPv4 nor IPv6 reachability. Source import, ordinary account data and the two user profiles were preserved.

- PASS: own canaries in all three Keychain aliases; foreign group reads rejected.
- PASS: own standard defaults and four distinct suites; CFPreferences interoperability; foreign suite/domain reads absent; own values survive relaunch.
- PASS after ownership fix: four private group directories return their own marker bytes.
- **FAIL:** B reads A's existing Documents canary and stats A's home. A reads/stats B; B repeats the failure after relaunch. These are public Foundation API calls in the actual Facebook processes, not a root helper reading for them.
- PASS, limited to the process hooks: TCP connect denied with the implementation's `EHOSTUNREACH`, IPv4 and IPv6 UDP socket creation denied with `EACCES`, while AF_UNIX IPC works. An offline TCP error alone was not counted as sufficient evidence. No packet capture, proxy transport or MDM enforcement was tested.
- FAIL: after the constructor hang was fixed, Facebook later terminated with `EXC_GUARD / ILLEGAL_MOVE` in `FBSharedFramework`. Stable interactive Facebook execution is not established.

The four primary runs contain 132 checks: 126 pass and six repeated failures (foreign file read/stat). Counts describe these specific synthetic probes, not comprehensive isolation. A further diagnostic reports `sandbox_check(file-read-data, sibling)` denied while the actual read succeeds; `csops` succeeds with flags `637538319`. A policy query is therefore not evidence of effective enforcement on this device.

The upstream [palera1n PongoOS kernel patch code](https://github.com/palera1n/PongoOS/blob/iOS15/checkra1n/kpf/main.c) replaces several vnode policy checks, including stat/access checks. This is consistent with the observed policy-versus-I/O discrepancy, but the exact booted kernel patch set has not been identified. Do not present that source comparison as a forensic identification of this phone's kernel.

## Reproduced defects and fixes

1. Facebook journal creation boxed a C comparison as integer 0/1 while its reader required CFBoolean. Actual installation failed before appinst and recovery rejected its own record. Facebook now writes booleans and precisely owned legacy integer records are durably normalized; Reddit bytes remain unchanged. 799 actual recovery assertions pass.
2. The constructor instantiated CoreMotion/UIScreen during dyld initialization and hit the iOS 20-second launch watchdog. Hooks still install synchronously; hardware behavior verification runs after the initializer returns, before readiness. The failing-first native fixture covers premature hardware construction, bad display values and failed hook installation.
3. Root-created `Application Support` was mode 0700/root, blocking the clone's own private group storage. Profile synchronization now provisions every parent with checked ownership and no-follow traversal; real device rechecks and 22 filesystem assertions pass.
4. Global schema preflight knew only Reddit recovery versions and blocked startup on valid Facebook deletion tombstones. It now recognizes exactly owned Facebook install/deletion/replacement records even while runtime admission is inactive. Native cases cover valid, future, unknown-owner, foreign-group and missing-owner records, with no rewrite of journal bytes.

These fixes do **not** repair the demonstrated cross-container filesystem access. Do not replace the OS boundary with path-hiding hooks and call it complete: native and direct syscall paths would still need enforcement. A solution requires a separately verified boundary on the supported jailbreak/device, or a different storage architecture with appropriate acceptance tests. Kernel/jailbreak mutation is outside this bounded fix and was not attempted.

## Reproduction and evidence

[Sanitized per-probe results](release-evidence/facebook-clone-acceptance-0.1.32.json) retain hashes of private originals and crash evidence. Diagnostic source is in `tools/fixtures/facebook_offline_acceptance/`; it is excluded from production build manifests. To repeat, use a private checkout, enable the descriptor there, add the helper command to the normal operation-context wrapper, and call the probe after hook installation. Sign with the existing ldid setup. Never patch production admission or emit a readiness PASS for this experiment.

The helper requires root, a fresh 32-hex nonce, role A/B, and no IPv4/IPv6 route. Create A/B, seed A, seed B with A's exact home/bundle, then verify A against B and verify B again without reseeding. Each request is in the exact clone's `Documents/SocialBoxOfflineProbe.plist`. Preserve reports before deletion. Delete with the normal registry lifecycle, restore the injection filter byte-for-byte and remove the diagnostic dylib. Do not hand-edit recovery journals.

Both disposable clones were removed via the actual durable deletion lifecycle. Committed deletion receipts and empty schema locks remain as deliberate identity/recovery history. The original injection filter was restored. Six pre-existing profile files retain their original bytes, uid/gid and modes; the two user container IDs are unchanged. The local maintenance package is installed separately from public APT publication.

NOT_RUN: real logins, account continuity, cloud restore/new-bundle preference migration, online packet measurement, managed per-app VPN, 40 real containers, and complete SDK/private-API/server-correlation coverage. No 100% isolation claim follows from this run.

## Previously installed candidate

**0.1.33** is installed by SSH. All 121 test entrypoints plus the pasteboard API check pass, including the existing Reddit regressions; static checks and the 374-row contract pass. Seven packaged Mach-O components / twelve architecture slices passed 1,384 code-directory page hashes with unchanged entitlements and license pin. [Build and installation evidence](release-evidence/facebook-clone-fixes-build-0.1.33.json) lists every validation entrypoint.

After installing, SocialBox and the daemon run, startup recovery passes with the genuine Facebook deletion receipts retained, the license is unlocked, both original user container IDs and profile bytes/permissions are preserved, and both imported sources remain present. The network remains CLOSED, firewall scope is `none`, and managed per-app setup remains incomplete. This candidate is not published to APT and does not make Facebook runnable.

## Follow-up candidate 0.1.34

**0.1.34** is now installed by SSH. It fixes the app binding of the actual clone-local network-control writer; 74 failure-first assertions execute the real method. All 122 test entrypoints plus the pasteboard API check pass, including Reddit regressions. The package preserves entitlements and licensing pin. Startup recovery, original profile bytes/permissions and both user container IDs pass post-install checks. Network remains CLOSED and Facebook remains inactive. See [build/install evidence](release-evidence/facebook-gate-writer-build-0.1.34.json).

The [single-active storage experiment](facebook-storage-gate-experiment.md) blocks the demonstrated foreign content reads, including direct syscalls, in both directions. It still exposes sibling home metadata and breaks the existing closed-home sync assumption. It is **not production-integrated** and is excluded from 0.1.34. DEVISO-001 remains a release blocker; this does not make Facebook ready for login.
