# SocialBox Phase 1 implementation report

Base: `c089804` on `feat/lifecycle-and-distribution`. Work branch: `feat/socialbox-multiapp`, created and pushed before edits. It remains unmerged. This change does not deploy the cloud console or publish a production package.

## Decisions and intentionally stopped work

The actual shipped Reddit clone prefix is `com.redditbox.profile.p` followed by 16 lowercase hexadecimal digits. The prompt's assumed `socialbox.profile.rd.*` is not the installed contract. Preserving the actual prefix takes precedence over renaming existing/new Reddit containers. The legacy nonstandard FNV offset basis, UTF-8 encoding, keychain group prefix, team identifier, source path, clone marker, profile paths, export names and global lease/binding remain unchanged. Missing local `appType` means Reddit; no local profile rewrite is performed solely for this refactor.

`cloud/src/config/app-registry.json` is the single descriptor data source. The cloud imports it directly; `tools/generate_app_registry.py` generates the committed native data header, and static/build checks reject drift. Facebook reserves `socialbox.profile.fb.p*`, `SBXFBCLN00.*`, and a separate private cache at `/var/mobile/Library/RedditBox/SourceFacebook/Facebook.app`. The existing UUID-named staging inbox and publication lock stay shared; import still closes the current session before the existing serialized maintenance operation. Instagram is reserved as a future addition, not registered or selectable tonight.

**Facebook clone creation/installation and execution are intentionally not enabled in Phase 1.** This is the explicit risk-rule exception to the requested Facebook clone creation. The current tweak bootstrap/readiness, identity generator, recovery/deletion journals, backups and one-active-app network lease are Reddit contracts. A source IPA alone cannot establish safe Facebook behavior. The code parameterizes construction inputs and validates/imports the selected app's source, but refuses an inactive app before clone installation, source removal, recovery, MDM export or launch. Missing Facebook source produces a specific error; an imported source still requires Phase 2. No failing/uncovered runtime change is hidden behind a runnable Facebook button.

The app selector wraps the original Reddit tabs and preserves their controller/navigation state. Facebook is a clean read-only placeholder. Shared license, proxy, network and recovery status remain device-wide; app-specific rows and results are filtered by app. Switching cannot bypass the passcode or an active sheet. Production package names and launcher branding remain RedditBox in this first abstraction step.

Cloud `appType` is additive and immutable. Existing rows normalize to Reddit in memory and persist the additive field on the next existing CAS mutation. Old device list requests default to Reddit; explicit app queries preserve authentication and device ownership. IDs and tombstones remain globally unique in their existing owner scope. The existing console URL is retained and gains app filtering. See `cloud/docs/app-types.md` for request contracts.

## Logical units

- Registry — [079b990](https://github.com/typekpaco2002/redditspoof/commit/079b990ae2dc4bc8704299f7b6fcbd57d004ad7c): canonical descriptors and generated native mirror; exact legacy identity/path vectors, malformed-type and collision-family tests. Static check and all original build regression entry points passed before commit and push.
- Process scope — [b1566b6](https://github.com/typekpaco2002/redditspoof/commit/b1566b6171f5c7730f274e9269941812b8a15528): immutable app-scoped controller; exact registered source/clone/main/plugin paths, protected infrastructure exclusions and existing Reddit compatibility wrappers. Native captured-signal tests, original inactivity architecture check and all original build regressions passed before commit and push.
- Source, clone inputs and admission — [772aa05](https://github.com/typekpaco2002/redditspoof/commit/772aa05aa330863a60fcebbc07d7bba1756d82bc): static checks, the original regression suite, all five extra architecture/release regressions, source/signing and MDM fixtures passed before commit and push. Actual import validator and signing allowlist tests cover both descriptors; foreign backup admission had 22 failures before the fix and 50 passing cases afterward. Actual MDM export tests compare the complete legacy payload after normalizing only generated UUIDs, and reject foreign/mistagged bundles before publication.
- Launcher — [b31b32e](https://github.com/typekpaco2002/redditspoof/commit/b31b32ee98bc3fb84726dde6d981415259e7de92): static checks, the original regression suite, extra architecture/release checks and new scope/selector tests passed before commit and push. Foundation scoping and actual UIKit selector fixture passed; the latter uses inert workspace controller bodies and does not prove jailbroken-phone behavior.
- Cloud — [d786b2f](https://github.com/typekpaco2002/redditspoof/commit/d786b2f4826ae0d940ef0f27b3dbf8bb0e09caea): static checks, original native regressions, extra architecture checks, full cloud tests, TypeScript typecheck and production compilation passed before commit and push. Full existing test suite plus new app-type storage/auth/route tests, TypeScript typecheck and production compilation passed with synthetic local data. Three existing exact-object assertions explicitly account for the requested additive Reddit appType field.

- Signing-input follow-up — [ca31733](https://github.com/typekpaco2002/redditspoof/commit/ca3173369914abbb9e52707e8a4c03037d4c3e19): final check caught that moved registry values were missing from the conservative signing-contract digest. Three new drift assertions failed first and pass after including the canonical JSON, native mirror and derivation helper. The complete 72-entry-point native build passed again before this follow-up commit and push.

## Validation boundary

Passing host tests do not establish 100% isolation or working Facebook support. No Facebook binary, SDK or identifier audit was performed. No real Facebook source IPA was available to exercise complete atomic import on an iPhone. Real Reddit clone opening, MDM routing, A/B isolation, and 30–50-container load acceptance retain their prior device-verification gaps. The existing one-active-container design is unchanged. The signing-contract fingerprint is deliberately conservative and changes with signing implementation source; the local development package marks MDM re-adoption required. This is not a claim that the Reddit bundle IDs or entitlements changed. Production was not updated, and no existing device installation or MDM association was altered.

The UIKit fixture verifies actual shipped selector containment, original tab/navigation/editor preservation, passcode/modal guards and layout separation. It does not substitute for the real launcher, jailbreak services or Reddit runtime on a phone. Host process tests capture signals rather than kill real processes. Native MDM tests mock preferences and use temporary exports.

## Phase 2 input

Supply a decrypted Facebook IPA for the exact Facebook version to support, preferably the same arm64 build intended for the jailbroken iPhone, with its version/build and provenance recorded. Phase 2 can then enumerate the real Mach-O binaries, SDKs, networking/identifier APIs, entitlements and persistence keys; define Facebook-specific identity/bootstrap/readiness requirements; complete app-aware backup, recovery and MDM/network handling; and run physical-device launch plus A/B isolation acceptance before changing Facebook to runnable. An encrypted App Store IPA or an old Android evidence list cannot replace that input.

## Regression entry points

The unchanged baseline passed all 61 build regression entry points using the installed Mac dependency environment (libarchive headers and Homebrew OpenSSL). Each code-unit candidate was checked in an isolated checkout, then committed and pushed immediately. The additional five existing architecture/release tests were checked as their affected units were integrated, and all pass on the final code. No original behavioral assertion was removed: two architecture assertions follow the renamed helper / registry path, and three cloud object assertions include the new additive field.

The final native build runs 72 entry points: 66 original checks and 6 new checks. Full command list:

- `python3 tools/test_build_version.py`
- `python3 tools/test_package_variants.py`
- `python3 tools/test_apt_release.py`
- `bash tools/test_app_registry.sh`
- `bash tools/test_app_process.sh`
- `python3 tools/test_app_source.py`
- `bash tools/test_app_mdm.sh`
- `bash tools/test_app_scope.sh`
- `python3 tools/test_launcher_multiapp.py`
- `python3 tools/test_apt_metadata_refresh.py`
- `python3 tools/test_clone_architecture.py`
- `python3 tools/test_identity_editor.py`
- `python3 tools/test_launcher_architecture.py`
- `python3 tests/test_replacement_architecture.py`
- `bash tools/test_firewall_policy.sh`
- `bash tools/test_request_queue.sh`
- `bash tools/test_secure_config.sh`
- `bash tools/test_identity_draft_store.sh`
- `python3 tools/test_preinstall.py`
- `python3 tools/test_postinstall.py`
- `python3 tools/test_macho_probe.py`
- `python3 tools/test_request_budgets.py`
- `bash tools/test_proxy_library.sh`
- `python3 tools/test_proxy_configuration.py`
- `sh tools/test_proxy_region.sh`
- `python3 tools/test_proxy_region_transport.py`
- `bash tools/test_rotation_secrets.sh`
- `bash tools/test_backup_snapshot.sh`
- `python3 tools/test_backup_identity.py`
- `python3 tools/test_backup_archive.py`
- `python3 tools/test_identity_freeze.py`
- `python3 tools/test_smoke_log_order.py`
- `python3 tools/test_sign_firewall_app.py`
- `bash tools/test_keychain_cleaner.sh`
- `bash tools/test_keychain_sync.sh`
- `bash tools/test_clone_acceptance.sh`
- `bash tools/test_isolation_sentinel.sh`
- `bash tools/test_launch_safety.sh`
- `python3 tools/test_proxy_route_transport.py`
- `bash tools/test_acceptance_checks.sh`
- `bash tools/test_operator_wording.sh`
- `bash tools/test_wizard_draft.sh`
- `python3 tools/test_device_acceptance_ssh.py`
- `python3 tools/test_device_acceptance_canaries.py`
- `bash tools/test_deletion_journal.sh`
- `bash tools/test_profile_metadata.sh`
- `bash tests/test_replacement.sh`
- `python3 tools/test_profile_metadata.py`
- `python3 tools/test_account_status_browser.py`
- `python3 tools/test_license_key.py`
- `python3 tools/test_license_screen.py`
- `python3 tools/test_license_presentation.py`
- `bash tools/test_license_presentation.sh`
- `bash tests/test_license_token.sh`
- `python3 tests/test_license_architecture.py`
- `bash tests/test_data_schema.sh`
- `python3 tests/test_data_schema_architecture.py`
- `python3 tools/test_update_startup.py`
- `bash tools/test_device_catalog.sh`
- `bash tools/test_fingerprint_registry.sh`
- `bash tools/test_operation_context.sh`
- `bash tools/test_memory_budget.sh`
- `bash tools/test_request_deadlines.sh`
- `bash tools/test_bounded_process.sh`
- `bash tools/test_service_lifetime.sh`
- `bash tools/test_socket_guard.sh`
- `bash tools/test_hook_readiness.sh`
- `bash tools/test_http_proxy.sh`
- `bash tools/test_reddit_payload.sh`
- `python3 tools/test_leak_audit.py`
- `python3 tools/test_leak_surface.py`
- `python3 tools/check_pasteboard_api.py`

Additional completed checks:

- `python3 tools/static_check.py` — ALL CLEAN.
- `python3 tools/check_leak_surface.py --base c089804` — final branch contract and changed-file trailers; all prior gaps remain visible.
- `python3 tools/test_launcher_selector_simulator.py` — actual UIKit selector fixture PASS on the booted simulator, no screenshots or real Reddit execution.
- `cd cloud && npm test` — original suites plus the new app-registry suite PASS.
- `cd cloud && npx tsc --noEmit` — PASS.
- `cd cloud && npm run build` — PASS.

The UIKit fixture creates a unique temporary test application, uses inert workspace controller bodies and removes its own app after completion. Native process fixtures capture signals. Source fixtures create synthetic Mach-O files; no proprietary Facebook binary was analyzed.


## Build artifact

Rootless development package: `packages/com.redditbox_0.1.15_iphoneos-arm64.deb`. Version 0.1.15, 1698472 bytes, SHA-256 `d61552759c42c654fb457e3c52dedf8feb0121694325116cdd21a85177347eae`. Full Mac build PASS with Procursus ldid and no Apple Development Team. Package control version/architecture, unchanged launcher bundle identifier, and entitlements for both architecture slices of launcher/daemon were inspected. Machine-readable evidence is in `docs/socialbox-phase1-validation.json`.

This package was not published to either APT repository or installed on the phone. Its conservative signing-contract metadata requires MDM re-adoption review if it is later installed. Rootful device/package acceptance was not performed for this Phase 1 branch.

Cloud GitHub CI, including its HTTP smoke flow, [passed on the cloud commit](https://github.com/typekpaco2002/redditspoof/actions/runs/34779102848). Native and cloud production compilation success do not change the explicit Facebook/device acceptance limits above.
