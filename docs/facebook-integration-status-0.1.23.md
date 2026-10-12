# Integration candidate 0.1.23 — Facebook still inactive

Both ldid-only package variants are built and inspected. All 109 build test entrypoints and the static check pass for this source; the branch is unmerged. [Package evidence](facebook-user-agent-build-0.1.23.json) records artifact hashes, source snapshot, test entrypoints, all seven Mach-O components/twelve slices, license pin and effective entitlement values. Neither package is installed or published. Last verified phone installation is [0.1.22](facebook-integration-status-0.1.22.md); the phone is currently absent from USB.

## Completed producer unit

[FBUA-001](facebook-user-agent-policy.md) implements the observed Facebook User-Agent producer with exact app, profile, bundle, source-version and framework ownership. It keeps device/OS/scale/locale fields coherent and preserves real app metadata. Unsupported output is withheld. Both absent and non-null invalid trampolines are rejected before invocation. The two new host fixtures pass 69 policy assertions and 66 actual installer/wrapper assertions across 19 processes. Existing Reddit production dispatch is unchanged; the complete build list includes its registry, bootstrap, identity/editor, payload, hook-readiness, socket/proxy, clone/lifecycle and backup regressions.

No runnable or defaults-wire admission flag was enabled. The producer self-report is installation evidence only. Actual clone interception and first-use ordering, SDK identifiers/defaults, restored state, Tigon/MQTT/QUIC, managed routing and A/B account acceptance remain open.

## Package inspection scope

The independent read-only inspector recomputed every CodeDirectory code-page hash and every nonzero available special-slot hash: 1,290 pages for rootless and 1,286 for rootful. In-memory code-page and entitlement-blob corruption tests both failed as expected; package bytes were unchanged. Structure and slot meanings follow the [Apple XNU CodeDirectory definitions](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/osfmk/kern/cs_blobs.h). This is content integrity, not OS trust, certificate validation, full resource-tree verification or MDM adoption.

The macOS `codesign --verify --all-architectures` check rejected all seven rootless targets with “code object is not signed at all”; the same check rejected the prior 0.1.18 package identically. This result is retained, not reported as a pass. Procursus ldid entitlement extraction and independent CodeDirectory hash checks succeed. Both new variants retain the prior effective entitlement values and deployment license public-key pin. Their signing contracts match 0.1.22; build metadata conservatively requests MDM re-adoption when no authenticated previous contract is supplied.

## Remaining prerequisites and next execution

1. Reconnect and unlock the test iPhone; verify USB/SSH identity and quiet CLOSED state, then install the exact rootless candidate and repeat package/component health checks. Do not select the rootful package for this phone.
2. Supply the existing MDM service or state that none exists. The last device measurement had zero verified managed installations, zero armed VPN rows and `firewallSetupReady=false`. The repository exports configuration but does not provide an MDM service. Its ability to adopt these exact ldid/AppSync artifacts is itself unverified.
3. Complete the [Facebook acceptance runbook](facebook-acceptance-runbook.md) with disposable A/B clones and real managed routing before enabling/publishing Facebook. Original-app captures and synthetic Keychain boundaries are not live Facebook clone acceptance. Account login and deliberate social actions require the operator.

The local preparation folder contains the audited Facebook IPA and both 0.1.23 packages. It is a private test handoff, not a production-ready Facebook release. No 30–50-container load result or 100% isolation claim is made.

Earlier implementation commits and their test boundaries are listed in [0.1.22 integration status](facebook-integration-status-0.1.22.md): group policy/wrappers, device Keychain evidence, signing/runtime, cleanup, installation recovery, deletion, all-app launch/gate/recovery, replacement and backup reconstruction. Their detailed ledger rows remain the durable evidence contract.
