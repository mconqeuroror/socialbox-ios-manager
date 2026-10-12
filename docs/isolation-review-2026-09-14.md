# Isolation review — 14 September 2026

The reviewed code defects are fixed and pushed, and the rootless **0.1.17** test package builds. **Full runtime isolation is not established.** The phone remains on **0.1.16** because USB disconnected before installation. Facebook remains inactive. Missing MDM adoption, two-clone tests, account flows and traffic capture still prevent declaring the product ready for 30–50 live containers.

Branch: `feat/socialbox-multiapp`, unmerged. Code baseline: `3440f5b`; final implementation: `0b3dfcc`. Production APT and Vercel were not changed in this review.

## Why the three boundaries matter

- **Keychain:** the original Facebook process actually accesses three shared groups, including generic-password and key-class items. Clone signing, runtime queries, omitted-group searches, references, deletion and recovery must agree on distinct owned groups. Mapping every original group into one group could conflate separate items; granting original groups could share state. Current Facebook admission stays blocked until this boundary has native evidence. See the [specific implementation and test plan](facebook-keychain-boundary-plan.md).
- **Restore:** a backup intentionally carries app state and often the same logical account identity. A new physical sandbox does not make inherited identifiers, tokens or old control receipts a fresh identity. Same-identity recovery and a deliberately new identity are different operations. This review fixes unchecked control cleanup while preserving the existing restore identity contract; preference-domain relocation and cross-device ownership remain open.
- **MDM and networking:** saved proxy credentials and NSURLSession hooks do not prove that custom sockets, background traffic or another process are routed through the managed provider. The current phone has no proven MDM adoption/association. The existing Open prerequisites remain enforced; they were not relaxed for testing.

## Fixes and failing-first evidence

1. **`e678df3` — reliable daemon observation, ACCEPT-002/003.** The phone lacked `pgrep`, so the old collector falsely reported a stopped daemon and skipped subsequent observations. The collector now uses exact process-name enumeration and binds the live executable to a canonical installed path. Unavailable enumeration is NOT_RUN, duplicate/missing daemons fail, and unrelated executable suffixes cannot pass.

2. **`f4837db` — container ownership, ISOOWN-001.** A profile for A could contain B's bundle metadata; the actual control writer then published A-owned data into B's selected sandbox. The regression reproduced this in temporary storage. Profile decoding, clone admission and explicit ensure targets now reject contradictory ownership before mutation. Sandbox lookup is descriptor scoped, and missing legacy pre-install metadata stays compatible. The native fixture has 34 assertions and an independent review passed.

3. **`f06c912` — executable, typed observer evidence, ACCEPT-002/003.** A temporary ldid helper was killed from `/tmp`; a helper built from the same source and signing policy ran from the existing rootless `/var/jb/tmp` mount. Staging now selects that existing mount without changing entitlements or trust policy. Separately, boxed C comparisons emitted JSON `1`/`0`, which the strict collector correctly refused as Boolean evidence. The compiled native fixture failed before explicit Boolean serialization and passes afterward. The two mount experiments were rebuilt separately: byte-identical inputs were not recorded, and an AMFI cause was not independently traced. The observed execution difference is the evidence, not a stronger kernel-cause claim.

4. **`b9ca3a1` — redirect destination policy, ISONET-001.** Disabling third-party networking was checked at task resume but could be lost after an HTTP redirect. Both the redirect URL and an application delegate's replacement request now undergo the current policy. A real Foundation loopback test fails before the change; the server independently verifies no denied destination receives a request after it. Allowed destinations, explicit compatibility mode, cancellation and old daemon delegate behavior remain covered. This was a destination-preference bypass, not a demonstrated proxy/IP escape.

5. **`901af69` — honest sentinel evidence, ISOSEN-001.** Historical Keychain absence and an unwitnessed empty clipboard cannot pass as isolation. Nil receivers and unknown errors remain inconclusive. A successful foreign metadata/defaults/handle observation remains LEAK even when subsequent probes or cleanup throw. Structurally valid old reports retain LEAK rows while unsupported PASS rows become NOT_RUN. Retained alerts are not cleared. Five failing-first regressions, a 44-call Security mock suite, architecture/launch-safety checks and iPhoneOS syntax checks cover the change. [Full storage review](isolation-storage-audit.md).

6. **`0b3dfcc` — restore control cleanup, LIFE-018.** Restore previously ignored removal errors for four old control/profile files and returned success. It now checks inspection/removal, verifies ENOENT afterward, and rechecks cancellation. Denied/no-op removal, inspection errors and cancellation fail into existing rollback/recovery handling. The actual restore function passes 42 synthetic fixture assertions; app bytes and new OS ownership metadata are preserved. Stale-control reactivation was not demonstrated; false restore success was.

Each unit passed static and native/host gates before its commit and was pushed immediately. Unchanged passing gates were retained when a later collector-only correction reran the affected fixture and remaining gates. The prepared libarchive environment resolved an initial host include-path omission. No failing gate was treated as a pass.

## Final validation and package

The final `scripts/build-mac.sh` invocation passed **all 80 test entry points**, then completed the unsigned Xcode archive, Theos builds and ldid package signing. The original 72 Phase 1 regression entry points remain in the gate list; the earlier Facebook work added five, and this review added ownership, redirect and restore regressions. This includes native registry goldens in Objective-C and Objective-C++, app/source/process/MDM scoping, clone/readiness, storage, proxy/route/firewall/socket, backup/replacement/recovery, IPC, license and launcher contracts. The exact list, per-unit commit identities and private-log SHA-256 records are in [validation evidence](isolation-review-validation-2026-09-14.json).

- Artifact: `packages/com.redditbox_0.1.17_iphoneos-arm64.deb`, **1,768,222 bytes**.
- SHA-256: `5b34a170b96cad9275c4298e62548b5c1f72524890253933e6358d263c80692a`.
- Existing licensing public key ID: `b2c5d4176c727107c9826ad69386d4d65f90920074981bd842127d6b22add6e9`; independently derived from the existing PEM and found in every daemon slice. No replacement key or Apple Development Team was used.
- Six packaged components were checked for architecture and entitlement values against 0.1.16. The package inspector also checked install-tree scope, versions, maintainer scripts and absence of user data/imported IPAs/private keys. [Package evidence](isolation-review-package-0.1.17.json).
- Signing contract: `6760ccd2f0abbe4e127ee14e759fb91cd6ca80780dacc8383b5517cacc111991`; `requiresMDMReadoption` is true. This test package was neither installed nor published to production. A rootful 0.1.17 device/build is not claimed.

## What the actual phone established

The [timestamped 0.1.16 capture](isolation-review-device-0.1.16.json) records PASS for current publication, license, saved configuration, source, one installed daemon, the existing clone's structural entitlement checks, removed extensions, its independently identified data container and temporary-helper cleanup. A separate GET-only native read observed 256 MiB active/inactive daemon limits. This is partial structural evidence from the previously installed build.

The collector capture predates the explicit JSON Boolean fix; its NOT_RUN statuses are deliberately preserved. USB then disappeared, so the corrected collector and 0.1.17 cannot be claimed as tested on the phone. No account was logged into, no post/share/vote was made, and no gate was bypassed. Source/license/profile preservation observations from the previous 0.1.16 upgrade are historical evidence, not a 0.1.17 upgrade result.

## Inventory and remaining acceptance

[LEAK_SURFACE.md](../LEAK_SURFACE.md) now contains **337 rows: 141 covered-in-code, 27 gaps and 169 unverified**. All inventory verdicts were reconciled against the active implementation; zero rows claim “not used” merely from missing symbols. This review reused the existing hash-bound Reddit and Facebook binary inventories, rather than presenting a fresh binary scan. The source hash/reference snapshot was regenerated for every implementation unit. Stale APP-003/FB-004 evidence now acknowledges the completed Facebook source audit/import and original-app API observations; ID-009 correctly distinguishes a Keychain group from forbidden App Groups. LIFE-018 now records tested cleanup behavior. Counts describe mechanisms and evidence gaps, not independent probabilities of safety.

Morning acceptance must proceed in this order:

1. Reconnect/unlock the phone, install the exact candidate through the existing non-destructive package workflow, and verify installed code hashes, license/source/profile preservation, startup and CLOSED state. Do not uninstall or remove recovery data first. Re-run the corrected read-only collector.
2. Complete real supervision/MDM adoption and exact per-app VPN mapping for the current clone signature. A configuration card or proxy exit check alone cannot close NET-034. Keep the existing Open refusal until this evidence exists.
3. Use two disposable admitted **Reddit** containers for the documented A → B → A canary sequence, then deliberate proxy-loss, restart, restore/delete/replace and bidirectional traffic tests. Do not use the Reddit-only helper to claim Facebook coverage. A retained isolation alert requires investigation; disabling the sentinel is not a reset.
4. Keep **Facebook inactive** until multi-group Security/cleanup, restore identity policy and global lifecycle coordination are integrated and verified. Family/machine IDs, UA/timestamp provenance, custom transports, callbacks and background paths remain open. Follow the [Facebook acceptance runbook](facebook-acceptance-runbook.md).
5. Only after A/B and operator-driven account behavior pass should 30–50-container resource testing begin. Account login/browse/post/share require deliberate operator test-account actions. Shared accounts, proxies and intentionally shared compatibility settings are also possible links outside a local sandbox claim.

There is no evidence-based claim of 100% isolation or unlinkability here. These fixes improve concrete boundaries and prevent misleading success reports; the remaining rows and device prerequisites remain visible and binding for future changes.
