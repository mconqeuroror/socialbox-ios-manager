# Single-active storage gate experiment — DEVISO-001 / SGATE-001

**Not a production fix. Facebook filesystem isolation remains a release blocker.** The candidate protects inactive clone file contents on the tested phone, including against a direct ARM64 syscall. It is deliberately excluded from the daemon and tweak build. It has no durable lifecycle integration or production launch authority.

The results below are historical. The subsequent durable lifecycle integration and installed 0.1.35 candidate are documented in [the follow-up](storage-lifecycle-0.1.35.md). Directory-metadata and managed-network gaps remain open.

## What the physical experiment establishes

Two disposable Facebook 578.1.0 clones ran on iPhone 8 / iOS 16.7.16 / rootless palera1n, offline. Their original own markers were seeded before permission changes. The normal clone manager supplied separate registered bundles and OS homes. Only the private diagnostic build enabled Facebook. No account was logged in, and no network lease or MDM readiness was granted.

The observer now reads the foreign canary through Foundation, POSIX `open`, and an inline `svc` using `SYS_openat`. Each run includes an own-file direct-syscall positive control. Before permission gating, the foreign marker bytes were returned even with an additional bundle-bound `com.apple.private.security.container-required` entitlement. That entitlement experiment did not repair the boundary and is not in the production package.

The permission candidate closes every test clone's main executable first, then its bundle directory and home. Closed state is root:wheel, executable mode 0600 and directories 0700. With both exact clone processes stopped, it admits one selected home as mobile:mobile/0700, then that bundle and executable as root:wheel/0755. The inactive clone remains closed. The host transition primitive pins descriptor device/inode identity, checks type/ownership/ACLs, rejects inode aliases and hard-linked executables, flushes changes and tries to reseal on admission failure.

In the final physical A-to-B and B-to-A runs, Foundation could not read the sibling file; both POSIX and direct-syscall reads failed with EACCES. Own direct-syscall reads still returned the original marker. The foreign file's attributes were inaccessible. However, the foreign **home directory's own attributes remained visible**. Each final run is therefore **38 PASS / 1 FAIL**, not an aggregate isolation PASS. The two initial seed runs each passed 28 checks. These are specific synthetic data points, not complete SDK, backup, account or network acceptance.

Locking only the bundle directory was insufficient: launchd still spawned the executable, which then failed in dyld while opening frameworks. Removing the main executable's execute bits prevented the tested launch: launchd reported spawn failure 111 and no clone process was created. This proves only the tested executable path, not all possible launch paths or a race-free production admission protocol.

Private-driver authorization was an unconditional callback. The external test controller checked that the exact test executable paths had no processes before transitions. The primitive does not itself establish process quiescence, path provenance, operation ownership or boot recovery. A permission change cannot revoke a file descriptor already held by a live process.

## Why this cannot be promoted by adding a chmod call

An actual `offline-acceptance sync` against a root-closed clone failed with **“Clone support directory ownership or no-follow traversal failed.”** `RBXCloneSupportDirectory` correctly requires the registered mobile home owner. Production deletion capture independently requires that owner in `RBXManagedRemovalPath`. Neither check was weakened to accommodate an unauthenticated root-owned directory.

Before production integration, every entry below needs an implementation and a regression that exercises the actual lifecycle path:

- Persist exact registered bundle/home identity and the authority for each permission state. Validate no-follow paths and pinned inodes again before admission; parent namespaces are writable by mobile on this phone.
- Integrate process closure, install completion, selection, launch, exit, cancellation and daemon/phone restart. Do not admit a clone while a sibling can retain an open descriptor or execute a different entrypoint.
- Support syncing and deleting a closed home using that explicit authority. Do not globally accept arbitrary root-owned homes.
- Treat staged code and user data separately during backup, export, replacement and rollback. Code copies currently preserve source modes, while signing expects an executable main. Do not export an unusable executable or reopen a foreign live home to make a copy.
- Cover every managed app, plus system-service backing stores and paths outside the home. A Facebook-only lock does not protect Reddit data. The existing runnable-only process coordinator also needs an explicit rule for owned inactive descriptors.
- Test capacity failure, interrupted adoption, path substitution, stale processes and alternate launch paths on-device. Host permission tests cannot establish these properties.

Root-owned data directories also do not conceal directory metadata, defeat root, repair the kernel sandbox, or prove account unlinkability. The experiment does not resolve the separately observed Facebook startup failure, network enforcement or cloud restore limitations.

## Reproduction and preserved evidence

Run `bash tools/test_storage_gate.sh` on macOS. It operates only in its temporary directory, with the current UID standing in for all owner roles. It exercises 40 targets, 120 selections, four authorization revocation points, 246 chmod failure positions, inode aliases, stale inode identity and hard links. The 50,386 assertions include repeated mode/content checks; they are not 50,386 independent attack surfaces. fchown/fsync failures and production lifecycle races are not exhaustively tested. The cross-role inode alias case failed before its guard was added.

The production-excluded primitive is in `tools/fixtures/storage_gate/RBXStorageGate.h`. The device-only observer is `tools/fixtures/facebook_offline_acceptance/FBOfflineProbe.m`. Use the existing offline acceptance provisioning/deletion helper with a fresh nonce and disposable A/B clones. Never target ordinary user profiles or the original App Store application. Preserve reports, stop and verify both exact test processes, restore their original ownership/modes, delete through the normal registry lifecycle, and restore the injection filter byte-for-byte.

[Sanitized device results and source/log hashes](release-evidence/facebook-storage-gate-experiment-0.1.34.json) retain the failed baseline and both final gated runs. The private driver was intentionally limited to the two recorded disposable identities. Both clones were removed through the real deletion lifecycle after restoring their modes. Their committed deletion receipts remain as recovery history. All pre-existing profile files retained identical bytes, uid/gid and modes, and the production injection filter was restored.

## Separate shipped repair

Build **0.1.34** fixes the final clone-local network-control writer: it now verifies the profile's app descriptor and derives the expected bundle from that descriptor. Previously it always derived a Reddit bundle, rejecting a valid Facebook target; it also lacked the explicit manager/profile owner check. The new failure-first fixture executes the actual method and passes 74 assertions for both apps, foreign owners, stale generations, home validation and scoped control documents.

The rootless build passed all 122 test entrypoints plus the pasteboard API check, including Reddit regressions. Seven packaged components / twelve architecture slices passed 1,384 code-directory page hashes; entitlements and the licensing public-key pin are unchanged. This build is installed by SSH, with daemon and launcher running, startup recovery passing, both original container IDs and profiles preserved, and traffic CLOSED. The candidate storage gate is absent from this package. [Build/install evidence](release-evidence/facebook-gate-writer-build-0.1.34.json) lists every validation entrypoint. No APT publication or branch merge occurred.
