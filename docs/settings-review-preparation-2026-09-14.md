# Settings and morning test preparation — 2026-09-14

Seven bounded code units are committed and pushed on `feat/socialbox-multiapp`, without merge. The code revision is `d79dfd4`. This prepares controlled device testing; it does not certify full isolation, Facebook execution or a 30–50-container workload.

## Integrated units

- `bdbcf2c`: random identity generation preserves operator metadata, ownership and non-editor policies. Invalid battery offsets are rejected. Native candidate/generator/validator/decoder tests cover both descriptor types.
- `15361fc`: selected two-component iOS versions such as 26.6 return an implicit zero patch through the actual NSProcessInfo hook instead of falling back to the physical version.
- `e86a322`: retain 21 models and all previous choices; expand to 159 model/iOS tuples using exact Apple public release applicability. Five newer model templates now have five iOS choices. [Catalog evidence and limitations](device-catalog-update.md) explain deferred hardware, retained legacy fields and inferred Darwin values.
- `00f9a65`: fix picker result loss during modal dismissal, overwritten request errors, oldest-version fallback, pending controls and stale Save confirmations. First-use freeze and battery/loopback/font explanations now match behavior. Actual UIKit fixture: 84 checks pass.
- `f985097`: new forms consume app-scoped role/country defaults while retaining existing drafts and explicit Auto. Monitor settings require a valid interval and successful persistence before a reload action. Actual monitor persistence fixture: 49 checks pass.
- `e70948d`: selected model/iOS/scale invalidates obsolete Reddit UA overrides and uses the existing runtime builder. Reject invalid explicit device names, retain unchanged location and generate bounded coordinates for a changed city. Native candidate matrix: 1,982 checks over 318 app/model/iOS combinations. Actual candidate/UA/header fixture: 148 checks pass.
- `d79dfd4`: atomic passcode replacement preserves the previous verifier on failure. Unknown/corrupt reads keep the launcher gate protected; only not-found means absent. Explicit removal reports deletion failures. Provider fixtures and 14 actual action checks pass without accessing a real Keychain.

## Validation

Every unit passed `tools/static_check.py` and all host/native build entrypoints in its exact candidate checkout before commit. The final suite has **88 entrypoints** and retains all 80 earlier entrypoints, including all 72 Phase 1 entries. Exact names, per-unit revisions, counts and private log hashes are in [the validation manifest](settings-review-validation-2026-09-14.json).

Two obsolete source-spelling assertions were updated to follow their exercised behavior: ownership is already checked by actual candidate execution; creation defaults now pass through a shared helper. No old executable regression entrypoint was removed. Failing gates were fixed and remaining unchanged gates resumed; these are recorded in the manifest.

The separate UIKit test compiles and runs the shipped identity controller on an explicitly provisioned simulator. Its IPC and private-draft providers are inert. It proves selection, review payload and request/UI state, not daemon persistence, physical injection or Facebook acceptance. It is deliberately separate from default package gates because it requires a booted simulator.

[The field-consumption map](settings-consumption-review-2026-09-14.md) traces visible identity fields, derived values, eight policy toggles, sentinel controls, creation metadata/defaults, proxy, licensing, cloud, version monitoring, source import and MDM actions. [LEAK_SURFACE.md](../LEAK_SURFACE.md) includes EDIT-001 through EDIT-007; it remains a mixed evidence inventory, not an all-clear.

## Artifacts and device boundary

The completed local package version is **0.1.18**, rootless and rootful, built with Procursus ldid and the existing deployment public license key. The final [package inspection record](settings-review-packages-0.1.18.json) binds exact hashes, component architecture/entitlement checks, catalog payload and license pin. Inspection enumerates all seven Mach-O components, including the preference bundle omitted from the older six-entry 0.1.17 report, and compares every slice against the actual prior archive. Both full builds completed with all 88 gates. These are private test builds; this turn does not publish them to production APT/Vercel or automatically update Sileo.

The private morning folder on this Mac is `/Users/typekpaco/Downloads/SocialBox-ready-2026-09-14/`. It contains the built variants, a Slovak README, SHA-256 manifest and the Facebook source IPA. The source copy is version **578.1.0 / 1063022819**, 214,246,198 bytes, SHA-256 `2cdaab3bd8bd0238660ea23b566b7bd7713121d996032bbc045d4066d2233e8a`. The copy's hash and ZIP CRC match the prior audited dump. No IPA, credential, account data or private source is committed or published.

The IPA previously existed in private Mac audit storage. The prior successful phone import stores an unpacked app at `/var/mobile/Library/RedditBox/SourceFacebook/Facebook.app`; that private cache does not appear as an IPA in Files. No fresh phone import or device change is claimed here.

The phone's last captured version is **0.1.16**, iPhone 8 (`iPhone10,4`), iOS 16.7.16, rootless palera1n. USB enumeration returned no device during this turn. No package installation or new physical acceptance was performed. New signed-clone/MDM adoption remains a device prerequisite; the package records explicitly require MDM re-adoption.

## Morning acceptance sequence

1. Connect and unlock the iPhone; confirm active jailbreak, pairing and SSH. Capture installed version, source state, available storage and recovery state before changing anything. Install the rootless 0.1.18 package on the known rootless phone while retaining existing profiles/license/source.
2. Inspect Settings prerequisites. Confirm license/cloud, private Reddit source, assigned live proxy country and actual MDM/VPN/firewall evidence. A red or unknown prerequisite is not satisfied by a saved form or synthetic model selection.
3. Use a fresh, unused Reddit container to exercise model/iOS, Random fill, region, identifiers, Check and Save. Verify private persisted values and actual runtime APIs/headers agree. First-use freeze is intentional; a used container is not editable identity test material.
4. Run a controlled two-container A/B battery: launch/close/switch, proxy/egress failures, state canaries, sentinel evidence, recovery and next-launch persistence. Preserve unknown/NOT_RUN outcomes and crash diagnostics. Do not extrapolate two-container results to 30–50 without a separate capacity test.
5. Facebook source import is available; creation/launch stays inactive until multi-group Keychain lifecycle, process coordinator, family/machine identifier provenance, custom transports and MDM acceptance are integrated and tested. Having a decrypted IPA does not satisfy those gates.

Shared synthetic settings are tested for typed Facebook drafts, but there is no working Facebook clone claim. Newly announced hardware with incomplete required facts, untouched opaque imported UA overrides, legacy catalog discrepancies and version monitoring after source archival remain explicitly bounded follow-ups. No account login/posting/sharing or private-data migration was performed.
