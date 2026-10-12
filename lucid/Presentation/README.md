# SocialBox presentation

The `.15` interface is source-owned UIKit over the retained, version-pinned compiled core. It is not an independent rewrite of that core. The launcher exposes **Containers · Connection · Settings**, a graphite/teal visual system and locally drawn geometric navigation icons.

## Architecture

`SBBackendAdapter` is the only screen/getter/action compatibility registry. It checks the original bundle/version/build, class and implementation image, exact method ABI, main thread, view ownership, current control availability and stable container IDs. It never creates an admitted shell, license outcome, generator value or backend success receipt.

`SBWorkspaceCoordinator` retains the original five-controller array for core callbacks, hides its navigation artwork and mounts three own sections. The existing successful license flow must construct that shell first. `SBActivationView` now uses a separate key field and the source-owned license IPC client; the original key field, target and delegate never receive new keys. It verifies the cloud pairing only and explicitly keeps this preview locked because retained-engine admission is not implemented. Switching sections and rendering screens do not switch accounts or mutate persistent state.

The activation form offers Saved setups only after a typed active license reply,
fresh source validation and authenticated existing root status. It clears the
entered code only after that readiness check succeeds. Missing storage or an
uncertain response keeps the code and provides retry/support guidance. A revoked
validation closes the handoff. Each callback checks the current attempt and
phase; old or duplicate callbacks cannot clear a later input. Invalid-format
errors and final results are announced for accessibility. Readiness creates no
namespace, metadata record, installation or engine grant. The browser performs
its own fresh checks when opened; the visible button is never runtime authority.

The Saved setups editor offers explicit permanent retirement of authored saved
settings, using its full loaded original and a separate confirmation. Fresh
signed validation, authenticated status/full read and exact retained root
retirement proof govern removal. Check/Retry removal are separate from save
recovery; unresolved input is preserved across dismissal in the current process.
UI generation, presentation and current-editor checks reject stale effects.
The new control preserves the existing design and never removes app data,
accounts, numeric-CID containers or allocated runtime resources. Private UUID
retirement history remains; source UI testing does not imply owner installation.

`SBContainersView` now exposes only names, Selected, Switch and Create container.
There are no app counts/filters, search, Tools, details, hidden swipe actions or
saved-settings shortcuts in Containers. Original create and switch entrypoints
retain their guarded confirmations/completions. Switch resolves the current model
by stable ID; dispatch cannot change the Selected marker. A fresh original
snapshot alone updates it. Duplicate or missing records remain unavailable.
No device-wide identity change, completed switch or isolation verdict is invented.

The heading and names scroll with the list; persistent Create remains reachable.
Names and actions use bounded growth at large text sizes, and the existing dock
retains the three sections. Synthetic layouts include seven width/safe-area/text
scenarios; actual owner installation and creation screens remain separate.

`SBIdentityForm` owns the shared rules form. It preserves exact native inputs, target/action senders, control tags and picker gesture carriers. A reviewed shape/caption contract distinguishes values from fixed prose. Unknown or incomplete layouts receive an own unavailable form. Original range/specific rebuilds run first, then refresh the owned form. No original layout is copied.

`SBSecondaryScreens` provides own picker, backup, Cloud, app-selection, session and import presentation over the original table data source/delegate and native action carriers. The `.15` registry adds current sessions, session import, batch Cloud upload, session export and session destination. Exact table getters and the original spinner, search, label/passphrase fields and navigation actions remain authoritative. Unrecognized interactive row structures or missing control contracts receive an owned unavailable result. Backup type copy changes only in the verified badge slot; filenames and other values remain UserData. Section-header overlays retain original tags and gestures. `SBGuideViewController` is a local guide. Store/checkout, including the exact CloudPlans alias, are absent from owned navigation and guarded modal routes; licensed Cloud and admission are unaffected.

`LBXWorkspace` provides current-session identity, the grouped settings pages, source-owned startup/onboarding/license and the connection shell. Proxy cards replace their interior artwork and layout while preserving original model/gesture carriers, native controls, enabled/hidden state and exact user values. Unknown card structures receive an owned unavailable row. Location keeps the real map/search delegate and original simulation control in an own map/panel layout. Its tools are a menu rather than a column of primary actions.

## Text and data boundary

All authored interface copy must be English. The display-copy tests check the known Slovak regressions while allowing Unicode user values and exact compatibility inputs. Authored visible copy is centralized in `SBInterfaceCopy` under semantic keys. Reviewed legacy inputs are isolated separately in `SBLegacyDisplayCatalog`; compatibility captions and user data never become translation keys. `LBXDisplayCopy` has explicit Fixed, Status, Diagnostic and UserData roles. User values are byte-preserved, even if a name equals a product word. The exact empty import result is:

> No importable container archives found. Save an archive to Downloads in Files, then try again.

Unknown diagnostic results receive neutral text and a stable reference; raw secrets/URLs are not reflected. The original Cloud, CloudPush and License `showError:` entrypoints supply a narrow diagnostic context, restored with `@finally`. Other confirmations retain unknown prose because it can contain user filenames. Original alert actions, handlers, text fields, delegates, styles, enabled states and completion stay intact; readonly action titles are not rewritten through private KVC.

The compatibility registry, legacy archive suffixes, internal service names, historical evidence and provenance remain intentionally recorded. The branding guard is a source-presentation guard, not a claim of zero legacy strings in the retained original binary. It does not modify users' filenames, passwords, addresses or container names.

## Test commands

Simulator runners require an already booted simulator and a new output directory:

```sh
python3 lucid/Presentation/Tests/test_interface_copy.py
python3 tools/test_socialbox_branding.py
python3 tools/check_socialbox_branding.py
python3 lucid/Presentation/Tests/run_backend_fixture.py --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_identity_fixture.py --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_secondary_fixture.py --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_simulator.py --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_simulator.py --workspace --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_simulator.py --activation --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_simulator.py --retirement --device <UDID> --output <new-directory>
python3 lucid/Presentation/Tests/run_layout_fixture.py --device <UDID> --output <new-directory>
```

Fixtures use the production presentation source with synthetic backend objects. They never run the imported original binary or contact licensing/Cloud services. Their previews and PASS results do not establish physical navigation, successful authentication, archive restoration, container switching or network isolation.

The current `.15` evidence receipt is [`socialbox-ui-completion-2026-09-28.json`](../../docs/release-evidence/socialbox-ui-completion-2026-09-28.json). Verified synthetic checks are backend 119, secondary 81, workspace 166, responsive layout 559, base 232 and identity 41 (1,198 total); the copy catalog has 273 entries, 833 native checks and 310 source references. The header callback guard now validates the actual method encoding; a malformed-ABI regression proved that inherited signatures are insufficient. Final arm64/arm64e ldid build and source/payload readback pass; installation and scoped unchanged-data verification pass separately in the receipt. The USB preview currently shows the lock screen. Phone UI acceptance is `NOT_RUN`. The layout runner also supports `--compile-only --output <new-directory>` without a simulator.

The private ldid build targets arm64/arm64e, snapshots all shipped sources, excludes fixture seams and preserves all original executable bytes. Device upgrade requires the pinned predecessor, private runtime backup, original service quiescence and verified recovery package. The release receipt and branding register keep phone checks separate from simulator results. ADOPT-003 remains a gap; this UI work does not establish readiness for sale or complete isolation.

## Loaded activation screen and package-state preservation (Unit 20)

Late presentation installation now adopts the already-loaded registered locked
license page through the same host/getter/ABI guards. It retains the root,
original controls, delegates, actions and load count. Repeated installation
preserves one source form and entered code; rendering sends no license/readiness
or metadata request and creates no admitted navigation shell.

PASS:242 synthetic presentation and86 activation checks. A private source copy
with startup-only adoption fails exactly three focused checks; working sources
remain unchanged. Source-stable arm64/arm64e production overlay,815 copy checks
and36 recovered-builder tests pass. This overlay is not installed on the owner
phone; real locked-page injection timing/default transport remain NOT_RUN.

Package preflight and incoming preinst now refuse any present fixed source
installation, pairing, configuration, pending or external-marker node, including
dangling links, after fixed parent checks. They preserve established/partial
state before image replacement while migration is unsupported. All-absent state
does not authorize preparation or a fresh customer install. Preparation remains
explicit; no initializer runs in package/abort branches. This read-only check
does not hold an atomic lock across dpkg. Focused synthetic package shell tests
are recorded in the receipt; no owner package is installed or released.

PASS read-only owner-phone inventory: new service/installer/job and five source
state nodes absent, original manager image pinned. No account/credential contents
were read, no device change or new key occurred, and absence was not used as
first-install authority. Current package remains an upgrade candidate. Corrected
report copy acknowledges implemented paired establishment without claiming a
customer installer or runtime readiness. Client release remains NOT_READY.

Next: implement the explicit trusted first-install package transaction and
normal endpoint/original locked-page acceptance, preserving all existing state
and keeping preparation out of abort or failed-check fallbacks. Runtime,
switching/isolation, actual accounts and proxy acceptance remain separate gaps.

Evidence: docs/release-evidence/socialbox-loaded-activation-preservation-2026-10-01.json.


## Containers progress animation (Unit 32)

The owner requested different animation and color for container switching.
`SBSwitchProgress` adds a cool blue circular arc and expanding halo to the
original Containers loader, with a static ring when Reduce Motion is enabled.
The exact pinned Containers show method calls its original once first. Current
host/ABI/getter witnesses and strict inert same-window shape/geometry checks
precede decoration; unfamiliar structures keep their original artwork.

The original overlay, spinner/constraints/animation state, status label/timer,
message updates and asynchronous hide completion are retained. Decoration is
noninteractive, idempotent and stops its own animations on detachment. There
is no switch/identity/helper/license/admission operation hook or success claim.
The original loader serves other Containers operations too; their progress
artwork shares the new appearance. No global legacy theme color is changed.

PASS33 focused synthetic UIKit assertions and242 presentation regressions with
60 stable quoted inputs each;36 builder methods with two direct edited files
stable (not the imported Python graph). The initial synthetic symbol inventory
FAIL2/errors2 is retained and corrected without relaxing production guards.
The arm64/arm64e overlay passes strict host ad-hoc/per-slice empty entitlement
checks with71 stable production inputs; test providers are absent. Host signing
confers no publisher/device trust. Owner installation remains NOT_RUN because
the trusted SSH session refuses authentication. No phone, account, default
storage, service, real key, website or customer release changed.

```sh
python3 lucid/Presentation/Tests/run_simulator.py --switch-progress --device <UDID> --output <new-directory>
```
