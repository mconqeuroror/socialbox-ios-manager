# SocialBox Phase 2–3 report

**Full Facebook support is NOT COMPLETE.** This work produced the Facebook binary/runtime evidence, bounded app-aware code changes, regression coverage and an ordered acceptance plan. Facebook remains `runnable: false`; clone creation/execution and app-specific defaults/wire readiness remain blocked. No Facebook clone login, browse, post/share, A/B isolation, restore or MDM acceptance is claimed.

Prepared on 2026-09-14 for `feat/socialbox-multiapp`, following the [Phase 1 baseline](socialbox-phase1.md). The governing instruction was: “If any change risks breaking the Reddit flow beyond test coverage, stop and document instead.” The observed shared Keychain groups and unresolved recovery/restore contracts made a complete Facebook activation exceed the available coverage. The strict global traffic/MDM gate and existing Reddit wire behavior were retained.

## Phase outcomes and commits

### Phase A — binary and runtime audit: evidence collected, coverage gaps retained

**`429ca81` — Audit the installed Facebook binary and record unresolved isolation paths.** Ran the existing structural scanner against the actual decrypted IPA, added the hash-bound Facebook supplement, independently compared imports/dependencies with `nm`/`otool`, and added `FB-001`–`FB-016` to the [leak-surface ledger](../LEAK_SURFACE.md). The [binary audit](facebook-binary-audit.md), [selected structural evidence](leak-surface/facebook-binary-evidence.json) and [independent validation](leak-surface/facebook-binary-validation.json) record offsets, input identities and limits. `test_facebook_binary_audit.py` validates the evidence contract. Static references identify investigation targets; they do not establish storage/wire ownership.

Two original-app launches added actual value-free caller/storage evidence, committed with the runtime unit below. The probe was prepared privately and executed by the root agent on the connected phone. No login or social UI action was automated. The stable [runtime observation report](facebook-runtime-observations.md) and [selected records](facebook-runtime-evidence.json) preserve the results and correction of an early defaults-domain placeholder. Meta SDK findings are **reused for Instagram phase later**; Instagram itself is neither registered nor accepted.

### Phase B — hooks and identity coverage: bounded implementation, Facebook identity coverage blocked

**`b9d70b1` — Bind audited Facebook keychain metadata to the exact clone group.** The clone-copy policy rewrites only the observed `FBKeychainAccessGroup` Info.plist hint to the canonical Facebook clone group. It validates that exact result, leaves the original source unchanged and is a no-op for Reddit. The native test failed first because platformFamily remained; passing tests cover malformed/foreign values, idempotence and exact legacy behavior. The signing-contract digest now includes this policy input. `FBAPP-001` is covered in code for this bounded metadata fix; it does not solve runtime requests to multiple groups.

**`9ec15d5` — Scope tweak runtime admission and retain the Facebook isolation block.** Canonical app/bootstrap/container/bundle/group matching now selects the runtime policy. Facebook is present in the executable filter, but constructors remain inert while its descriptor is inactive. Generic identity/security and destination policy are app-aware; existing Reddit adapters keep their original wire outputs. Facebook cannot satisfy defaults/wire readiness using Reddit's adapter. The native runtime suite passed 172 assertions plus existing payload/architecture/schema checks. `FBTWEAK-001` describes admission coverage and `FBRUN-001` retains the actual shared-storage blocker.

**`6a8bdde` — Preserve app ownership through profile generation and create admission.** Unsaved Facebook identity drafts use the shared generator and retain explicit ownership. The legacy untagged Reddit document shape stays unchanged. Facebook create preflight rejects a missing source or inactive descriptor before operation admission, proxy-region work, identifier reservation or publication. Ensure/sync and durable result construction derive the immutable owner. Actual generator/catalog and extracted shipped-method fixtures cover these paths. `FBPROF-001` is covered in code for ownership and refusal. Facebook drafts' `reddit` section is internal schema compatibility; it does not identify or sanitize Meta SDK fields, UA or installation timestamps. See [profile scoping](facebook-profile-scoping.md).

### Phase C — container flow: source UI and ownership implemented, end-to-end lifecycle blocked

**`6250821` — Keep launcher workspaces and durable requests bound to their app.** App-owned views, source staging, IPC requests, diagnostics and MDM export namespaces retain the selected owner. Shared license/proxy/network state remains device-wide. The inactive Facebook workspace exposes **Source setup → Import Facebook IPA from Files**, with durable app-bound receipt recovery. Container creation/Open/delete/replace/MDM controls remain absent while inactive. Typed IPC/MDM/native scope tests and UIKit fixtures in both inactive and test-only active states pass. `FBUI-001` is code/UI containment evidence, not working Facebook lifecycle evidence.

**`5c7c49e` — Fence multi-app process coordination against overlapping operations.** Added a coordinator that requests all app-family stops before bounded drains, routes the selected owner, and rejects overlapping/stale launch, stop and observation work. Failing-first concurrency fixtures reproduced false early-drain results, then passed after ownership epochs and in-flight effect tracking were added. Tests run the actual controller dispatch handler with inert process/binding boundaries. Normal and Thread Sanitizer runs pass. **The coordinator is not wired into daemon main/startup/recovery or the production target's coordinator path.** Existing controller synchronization is changed, but this is not a completed global daemon integration. `FBPROC-001` remains a gap. See [process design and evidence](multiapp-process-coordinator.md).

The device check verified package upgrade and decrypted Facebook source import on the physical phone through the daemon's durable `import-source` receipt. Actual inactive create was denied. Device Files-picker/launcher visual interaction was not tested. Source import, profile admission and active UI fixtures do not resolve app-aware installation recovery, multi-group deletion, replacement, backup restore, actual managed routing or FB critical-path compatibility. Those operations remain blocked; the [Keychain boundary plan](facebook-keychain-boundary-plan.md) enumerates the exact coordinated changes and failing-first tests required before implementation.

### Phase D — verification and deliverables: host gates and device import passed, clone acceptance pending

All **72 original build gates passed** and the **77-gate current suite passed**, including the final successful ldid build after the type-only Objective-C++ fix below. All 72 original commands remain in the current build script; five Facebook/multi-app gates were added. Both UIKit selector states and normal plus Thread Sanitizer concurrency fixtures pass. Complete command names and their scope appear below; [machine-readable validation](socialbox-phase23-validation.json) binds per-unit private test-log hashes.

The [acceptance runbook](facebook-acceptance-runbook.md) covers install/license/proxy/source, A/B creation, exact managed adoption, manual owned-account login/browse/post/share, canaries, both switch orders, inbound/outbound closure, background/wake, restart, restore, delete, replace and scale. It separates shared steps from app-specific verification and never treats a source import as clone acceptance. The generated ledger retains open Facebook rows rather than applying a blanket isolation verdict.

## Actual IPA and runtime evidence

The audited input is `com.facebook.Facebook`, executable `Facebook`, version **578.1.0**, build **1063022819**. IPA SHA-256: `2cdaab3bd8bd0238660ea23b566b7bd7713121d996032bbc045d4066d2233e8a`; size 214,246,198 bytes. Supplied dump provenance is iPhone10,4 / iOS 16.7.16, bagbak 5.1.2 and Frida 17.18.0. This identifies the supplied dump context; the metadata probe itself did not independently retrieve the installed version or device/iOS identity.

All 20 arm64 Mach-O images—main, ten frameworks, nine extensions—were scanned with recorded encryption commands at `cryptid=0`, no scanner errors and no unresolved decoded structural references. The scan contains 284,286 selector references, 53,421 class references and 60,269 class definitions. Independent validation retained all 125,788 unique-per-image `nm` undefined names; 3,502 additional scanner imports are explicitly attributed to chained fixups. These totals are structural records, not live call coverage or unique SDK counts.

Original signature XML declares Keychain group `T84QZS65DQ.platformFamily`, four App Groups, iCloud containers and production APNs. Its application-identifier prefix and team identifier differ and must not be conflated. DER entitlement data is recorded but not decoded. Nine extensions and seven background modes are audited declarations; neither declaration removal nor effective Facebook clone permissions were accepted on device.

The private Frida 17.18.0 captures began on 2026-09-13 at 21:30:35 and 21:37:28 UTC and each covered a 20-second original-app launch. The first emitted 430 records (21 Keychain, 14 identity calls, one HTTP metadata record); the second emitted 448 (31 Keychain, 16 identity calls, one HTTP record). Both recorded zero probe errors. Counts are capped emitted events, not exhaustive invocation totals. The repository retains 81 selected redacted records and capture hashes; proprietary binaries, raw account storage and full traces remain private.

Both launches successfully queried **three separate access groups**: `T84QZS65DQ.platformFamily`, `group.com.facebook.family`, and `group.com.facebook.Facebook`. Each queried a key-class item in the family group. The named generic-password service `group.com.facebook.family.securefamilydeviceid` was read successfully at `FBSharedFramework+0x176a7b4`. Services and access groups are separate attributes; merging the three namespaces would be an untested behavioral change.

The first probe labeled an unresolved NSUserDefaults receiver `<current-app>`; the durable records correct that to `<unresolved-receiver-suite>`. In capture two, `com.facebook.familydeviceid.backup.vendordeviceid` was read through a receiver observed returning from `standardUserDefaults`. This proves receiver origin, not which search-list domain supplied a value. Weak tracking prevents a deallocated receiver's address from being reused as false provenance in the tested cases. Named family and Facebook suites were also constructed.

Actual IDFV and family-device method invocations occurred. Capture two invoked App Attest generation and attestation and added two attestation-named services; completion results and server acceptance were not inspected. Each capture observed one NSURLSession request's host (`www.facebook.com`) and header names (`content-length`, `content-type`). No identifier values, account fields, tokens, Keychain payloads, key material, persistent-reference bytes, HTTP values/bodies or full URLs were requested. These observations do not prove wire equality, UA consistency or local-versus-server origin.

## Facebook identifier and storage matrix

“Unverified” means no current claim of complete per-container coverage, safe scrub/regeneration or shared acceptability. Generic sandbox/hook coverage is a proposed boundary until the relevant Facebook caller, fresh/restore path and emitted behavior are verified. Row IDs refer to the [machine-readable Facebook ledger](leak-surface/facebook-inventory.json), supplemented by `FBRUN-001`, `FBAPP-001`, `FBTWEAK-001` and `FBPROF-001`.

| Rows | Surface and actual evidence | Local/server provenance | Current verdict and next required proof |
| --- | --- | --- | --- |
| FB-002; FBRUN-001 | IDFV selector references and actual `UIDevice.identifierForVendor` invocation. | Platform API origin observed; returned value and subsequent copying unknown. | Generic profile hook available, active Facebook behavior unverified. Prove fresh A/B stability and every SDK persistence/restore path. |
| FB-002 | IDFA `advertisingIdentifier` selector references in the main image. No call recorded in these short launches. | Platform API candidate; runtime usage unknown. | Existing policy is available. Absence in the trace is not non-use evidence; verify caller and profile posture on clones. |
| FB-003 | `app_scoped_device_id`, `app_device_id`, `analytics_device_id`, `com.facebook.analytics.device_id` literals. | Generation, storage type/location and server ownership unknown. | No key-name-only scrub or wire patch. Attribute actual owner/callers before deciding sandbox versus regeneration. |
| FB-004; FBRUN-001 | Family/cached-family API calls, successful family-group `securefamilydeviceid` service read, vendor-device backup defaults key. | Item storage/API use observed; payload, generation and source/derived/server relationship unknown. | Shared-storage gap. Implement distinct groups and audit backup/fallback paths before any targeted create/restore policy. |
| FB-004; FB-007 | `CROSS_APP_DEVICE_KEY`, `LEGACY_DEVICE_KEY`, `legacy_device_key`, `shared_device_key` literals; named defaults suites. | Exact storage and migration semantics unknown. | Suite construction does not prove physical storage or safe isolation. Trace fresh and restored clone domains without reading unrelated user data. |
| FB-005 | Machine ID data-source/fetcher/persister classes and `mid`/`machine_id` candidates. | Local-generated versus server/session-issued **unknown**. | Preserve current semantics. Do not rewrite machine/session values based on names; establish caller-to-store-to-response/request provenance. |
| FB-006; FBRUN-001; FBAPP-001 | Three successful original Keychain groups; genp and keys classes; one Info.plist hint safely rewritten in clone copies. | Storage location known for selected calls; item contents and key origin unknown. | Single-group boundary is insufficient for compatibility. Distinct entitlements/mapping, SecKey/reference behavior and complete group cleanup remain blocked. |
| FB-007 | Four original App Groups, cloud declarations, defaults and container API references. | Local/shared/cloud scopes declared; actual values and usage unknown. | Source App Groups must not be granted to clones. Prove effective signed policy and app-data/cloud/restore separation. |
| FB-009 | Header/body literals including `X-FB-Device-ID`, `X-FB-Family-Device-Id`, `family_device_id` and integrity/session candidates. | Value source, schema and ownership unknown. | No new Facebook wire rewriting. Trace the real serialized path, signed/server-owned subtrees and stored counterpart first. |
| FB-012; FBRUN-001 | DeviceCheck/App Attest references; actual support/generate/attest invocations and attestation-named service writes. | Platform cryptographic API invoked; key storage relation, completion and server outcome unknown. | Default-blocked policy/per-profile override preserved. Fresh/restore and enabled/blocked compatibility need device proof; never forge assertions or carry opaque device keys as portable identity. |
| FB-013 | Multiple Meta UA builder selector references. No emitted UA value captured. | Client formatter candidates; dependency on hooked fields unknown. | Verify actual UA model/OS/device-name/version consistency in every path without changing Reddit outputs. |
| FB-003; FB-015; FBPROF-001 | Shared generator creates staggered compatibility timestamps; no actual Meta install-time source observed. | Draft field is locally generated; actual Facebook timestamp ownership/location unknown. | Generator staggering alone is not Facebook coverage. Identify persisted/wire time sources and check batch/create/restore behavior. |
| FB-014 | WebView/cookie/auth-broker/pasteboard structural candidates. | Local versus external broker/server/session state unknown. | Verify cookie/data-store and callback ownership with deliberate operator login flows; native sandbox proof alone is insufficient. |
| FB-008; FB-010; FB-011; FB-016 | Meta SDKs/custom transports, sockets/MQTT/QUIC, background modes and extensions; dynamic paths remain possible. | API/transport declarations only; complete caller/data-flow attribution unknown. | Retain residual rows. Prove routing and both directions of closure under background/wake and actual critical-path load. |

No unknown Meta device/machine/session identifier is classified as shared-acceptable. The narrow Info.plist fix and exact admission checks are covered in code; they do not close the broader rows in this matrix.

## Regression commands and verification scope

The baseline command list below is extracted from `git show 1bb7311:scripts/build-mac.sh`. The current [build script](../scripts/build-mac.sh) contains the same 72 gate commands plus five additions. Counts are entry-point commands; individual suites contain many assertions and some expanded fixtures. This comparison is not a claim that every test file is unchanged.

An initial completed 77-gate run preceded the one-line Objective-C++ cast fix. The real ldid build exposed that Objective-C accepted a `const void *` conversion that Logos Objective-C++ rejected. The expanded native registry test reproduced the failure first; an explicit byte-pointer cast retains the exact hash algorithm/bytes, and the same golden vectors now pass in both languages. The final ldid build, including all 77 gates, succeeded using those corrected source bytes. After build and artifact inspection, **`a336fd0`** committed the same source bytes and dual-language regression, recorded as `FBBUILD-001`, before phone installation.

Original 72 gates, all reported passing:

```sh
python3 tools/test_build_version.py
python3 tools/test_package_variants.py
python3 tools/test_apt_release.py
bash tools/test_app_registry.sh
bash tools/test_app_process.sh
python3 tools/test_app_source.py
bash tools/test_app_mdm.sh
bash tools/test_app_scope.sh
python3 tools/test_launcher_multiapp.py
python3 tools/test_apt_metadata_refresh.py
python3 tools/test_clone_architecture.py
python3 tools/test_identity_editor.py
python3 tools/test_launcher_architecture.py
python3 tests/test_replacement_architecture.py
bash tools/test_firewall_policy.sh
bash tools/test_request_queue.sh
bash tools/test_secure_config.sh
bash tools/test_identity_draft_store.sh
python3 tools/test_preinstall.py
python3 tools/test_postinstall.py
python3 tools/test_macho_probe.py
python3 tools/test_request_budgets.py
bash tools/test_proxy_library.sh
python3 tools/test_proxy_configuration.py
sh tools/test_proxy_region.sh
python3 tools/test_proxy_region_transport.py
bash tools/test_rotation_secrets.sh
bash tools/test_backup_snapshot.sh
python3 tools/test_backup_identity.py
python3 tools/test_backup_archive.py
python3 tools/test_identity_freeze.py
python3 tools/test_smoke_log_order.py
python3 tools/test_sign_firewall_app.py
bash tools/test_keychain_cleaner.sh
bash tools/test_keychain_sync.sh
bash tools/test_clone_acceptance.sh
bash tools/test_isolation_sentinel.sh
bash tools/test_launch_safety.sh
python3 tools/test_proxy_route_transport.py
bash tools/test_acceptance_checks.sh
bash tools/test_operator_wording.sh
bash tools/test_wizard_draft.sh
python3 tools/test_device_acceptance_ssh.py
python3 tools/test_device_acceptance_canaries.py
bash tools/test_deletion_journal.sh
bash tools/test_profile_metadata.sh
bash tests/test_replacement.sh
python3 tools/test_profile_metadata.py
python3 tools/test_account_status_browser.py
python3 tools/test_license_key.py
python3 tools/test_license_screen.py
python3 tools/test_license_presentation.py
bash tools/test_license_presentation.sh
bash tests/test_license_token.sh
python3 tests/test_license_architecture.py
bash tests/test_data_schema.sh
python3 tests/test_data_schema_architecture.py
python3 tools/test_update_startup.py
bash tools/test_device_catalog.sh
bash tools/test_fingerprint_registry.sh
bash tools/test_operation_context.sh
bash tools/test_memory_budget.sh
bash tools/test_request_deadlines.sh
bash tools/test_bounded_process.sh
bash tools/test_service_lifetime.sh
bash tools/test_socket_guard.sh
bash tools/test_hook_readiness.sh
bash tools/test_http_proxy.sh
bash tools/test_reddit_payload.sh
python3 tools/test_leak_audit.py
python3 tools/test_leak_surface.py
python3 tools/check_pasteboard_api.py
```

Five added gates, all included in the reported 77-gate pass:

```sh
python3 tools/test_facebook_binary_audit.py
bash tools/test_app_bundle_policy.sh
bash tools/test_app_runtime.sh
python3 tools/test_app_profile.py
bash tools/test_app_process_coordinator.sh
```

Additional reported successful coverage outside that 77-command count:

```sh
python3 tools/test_launcher_selector_simulator.py --facebook-capability inactive
python3 tools/test_launcher_selector_simulator.py --facebook-capability active
RBX_TEST_THREAD_SANITIZER=1 bash tools/test_app_process_coordinator.sh
```

The UIKit runner uses an already booted simulator (an explicit `--device` is required if more than one is eligible), a temporary app and an isolated registry copy for active-state testing. It executes shipped selector containment with inert workspace bodies, not daemon/MDM/account flows. Coordinator tests use fake process/lease/binding I/O and actual controller observation-handler barriers; no real target process is killed or launched. The private runtime probe's offline privacy and weak-receiver deallocation/address-reuse checks also passed. Source/signature fixtures and host Security stubs cannot establish real securityd authorization or account compatibility.

## Package, installation and source-import record

The build, artifact inspection, device package upgrade and daemon source import completed successfully. [Package evidence](socialbox-phase23-package-evidence.json) and [device evidence](socialbox-phase23-device-evidence.json) retain the redacted artifact/receipt checks. These passes cover installation and source admission; Facebook clone acceptance remains NOT RUN.

- **Candidate build — PASS:** real Procursus ldid rootless `0.1.16`, source commit `a336fd0`, including all 77 build gates. Package `com.redditbox_0.1.16_iphoneos-arm64.deb`, 1,760,954 bytes, SHA-256 `591e706353ac3e8efcd3768b49ad656093dd468be764beaf68bdfb1d6a669fa0`. The artifact was inspected with `apt_repository.inspect_package` and each Mach-O architecture and ldid entitlements were checked. This is artifact evidence, not clone runtime proof.
- **Signing contract:** `0bbd679aef6fd269cc87e2cf078da1747ff82af4bde774f5a4d4c0a8807a5309`; `requiresMDMReadoption: true`. No Apple Developer Team is used. The build used the existing deployment public PEM at `../private-release/license/license-public.pem`; no license key was generated or replaced. The generated pin and both the old 0.1.13 and new 0.1.16 daemon binaries match that PEM's public key ID (`b2c5d4176c727107c9826ad69386d4d65f90920074981bd842127d6b22add6e9`). The phone's active license was observed; a separate production license-server test was not run.
- **Build fix — PASS:** `a336fd0` contains the explicit Objective-C++ byte-pointer cast and passing dual-mode registry golden-vector regression. It was committed after the final successful build/inspection with the same source bytes, and pushed before phone installation.
- **Installation — PASS:** upgraded the existing phone from `0.1.13` to `0.1.16`. Fresh startup reported license active, network closed and no operation recovery. Installed daemon, tweak and launcher hashes match the `.deb`. Existing container IDs and identity fields were preserved. This is the observed phone upgrade; rootful installation and managed Facebook execution were not tested.
- **Source import — PASS:** imported the audited IPA through the daemon's durable `import-source` operation. The terminal receipt and source status identify Facebook `private-cache`, decrypted, version `578.1.0`, build `1063022819`. Reddit remains `private-cache`, decrypted, version `2026.36.0`, build `664762`; SHA-256 of its source Info.plist and actual executable remained unchanged. An actual Facebook create request was refused while inactive. The Files-picker/launcher visual source-import flow was not exercised; simulator containment fixtures remain separate evidence.
- **Publication:** changes through `a336fd0` are committed and pushed. Production is unchanged; no APT package publication occurred.
- **Facebook clone acceptance:** NOT RUN; no full MDM routing, Facebook clone login/browse/post/share, paired identity or restore/delete/replace acceptance. The current phone has no configured MDM.

The refreshed ledger contains 334 rows, including 24 Facebook-prefixed rows; `FBDEVICE-001` records the bounded device upgrade/source-import evidence. Passing that row does not close the remaining Facebook runtime/lifecycle gaps.

## Remaining work ranked for resumption

1. **P0 — Define and test the whole Keychain/lifecycle boundary before implementation.** Preserve distinct group namespaces; cover SecItem, SecKey nested attributes, reference-only and omitted-group behavior, signing/readiness, all four cleanup classes, complete group receipts and interrupted journals. Current cleanup is already four-class, but Reddit/single-group. Implement app-aware installation recovery, deletion, replacement and backup admission together with their identity semantics. See the [boundary plan](facebook-keychain-boundary-plan.md).
2. **P0 — Integrate the coordinator through all daemon owners and prove concurrency.** Wire main/startup/recovery/sentinel/maintenance ownership under the single traffic lease. Normal/TSAN component tests do not cover every existing caller. Run failing-first daemon overlap fixtures, then real cross-app orders with observed process/socket drain. See the [process note](multiapp-process-coordinator.md).
3. **P0 — Establish real managed routing.** Obtain supervision/MDM setup and managed adoption for the exact signed clone artifacts. Preserve missing/stale association and readiness refusal. A healthy proxy, local IPA install or exported mapping alone cannot satisfy this gate.
4. **P1 — Resolve identifier provenance and restore policy.** Trace family/vendor backup, machine/server/session fields, actual Meta timestamp sources, UA/device-name paths and attestation state. Choose targeted regeneration only after semantics are known; preserve server-issued and authentication material. A new local restore ID is not necessarily a new logical identity.
5. **P1 — Accept egress, background and critical functionality on disposable clones.** Verify custom/persistent transports, IPv4/IPv6, UDP/QUIC, both directions after closure, extension/callback policy and wake behavior. The operator deliberately performs owned-account login/browse/post/share in A and B; no social action is automated by this report.
6. **P2 — Complete restart/failure/restore/delete/replace and scale evidence.** Run the ordered [acceptance runbook](facebook-acceptance-runbook.md), preserving recovery state on failure, surviving-container canaries and exact package/source binding. Re-run Reddit hardware regression and the requested 30–50-container resource workload after A/B passes. Existing unresolved Reddit acceptance rows remain open.

The intended end state is a working Facebook container with the existing isolation quality bar. The delivered state is an audited, tested partial implementation with explicit admission blocks. Host regression success and original-app metadata observations do not establish complete Facebook support or an unlinkability guarantee.
