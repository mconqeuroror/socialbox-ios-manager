# Original SocialBox workspace contract

The UI is authored in the source-owned `SB*` presentation modules and `LBXWorkspace.m`; the recovered
binary supplies state and action endpoints. This contract supplements the
historical appearance-only map in `RECOVERED_SCREENS.md`.

## Static bridge evidence

Input: reviewed 3.1.0/build 1 arm64 method index and decompiler output from the
private handoff; original manager SHA-256
`e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0`.
The runtime also checks getter/action encoding and implementation image.

- Startup: `_Xd2z::viewDidLoad` `0x100168700` constructs an AppIcon and a
  hardcoded SocialBox title before validation in `viewDidAppear:` `0x1001694ec`.
  That class was missing from the previous screen registry. The source-owned
  startup moves the native `spinner` and observes (without reusing raw copy) `0x100169e2c` and `statusLabel` `0x100169e50`,
  validates `logoImageView` `0x100169e74` and hides the original visual roots.
  `updateStatus:success:` `0x100169cfc`, `delegate` `0x100169df8` and the whole
  validation/routing path remain unchanged. All three view getters must return
  correctly typed descendants before any original content is hidden.
- Welcome: `SocialBoxOnboardingViewController::viewDidLoad` `0x10016a1c0`,
  `meshGradientLayer` `0x10016b7f8`. New buttons forward to the original
  `tapCreate` `0x10016b618` and `tapSkip` `0x10016b6ec`. Those original callbacks
  retain ownership of onboarding persistence and the onDone result.
- Home: label getters `deviceNameValue` through `udidValue`,
  `0x1000686d4–0x100068900`; native action controls `fingerprintButton`
  `0x10006868c`, `mainToggle` `0x100068644`. Explicit navigation includes
  `openConfigureSpoofing` `0x10005db58`, `openCloud` `0x10005dd24`,
  `showBackupPicker` `0x10005f194`, `selectAppToSpoof` `0x10005e1c4`,
  `openTokens` `0x10005dcc8`, `showKillAppDialog` `0x10005e730`.
- Settings: presentation getters `0x1000f62b4–0x1000f63c0` and
  `contentStack` `0x1000f626c`. Copy/import seed `0x1000f24d0/0x1000f3370`.
  Maintenance uses the original confirmation entry points, never its direct
  `perform*` workers. Original preference switch objects remain action senders.
- License: `licenseKeyField` `0x1001680b8`, `validateButton` `0x1001680dc`,
  loading/error labels `0x100168124/0x1001681b0` identify the historical host.
  As of the own-activation change, these controls are not used for key entry or
  submission. `SBActivationView` creates its own field and sends to our root
  licensing service. It does not unlock the original shell or engine, write
  their token store, or invoke their success callback. Startup and periodic
  original admission remain separate unresolved boundaries (ADOPT-004).
- Location: map/search getters `0x100134500/0x1001345f8`, visible state labels
  `0x1001346d0–0x100134718`, action control `0x10013473c`. Original
  `updateUIForSimulatingState:` `0x100132204` runs before UI refresh.
  All location actions are explicit operator actions, never renderer work.
- Containers: original table `0x100129644` and search `0x1001297cc` are retained
  privately by the core; the own list uses typed cached model snapshots and
  fresh stable-ID resolution before each original operation. `reconfigureAllVisibleRows`
  `0x100106298` and `refreshTableHeaderView` `0x100106470` retain original
  implementations before repaint. No metadata snapshot becomes action authority.
- Proxy: original content stack/search `0x10021c1e4/0x10021c250`, original
  `showAddProxyMenu` `0x100215838`. Source records preserve original card roots
  because the original tap/menu handlers use associated model data on them
  (`0x1002081e4/0x10020834c`). The renderer never reads that association.
- Identity configuration: original `contentStack` `0x1000db980` and
  `rebuildContent` `0x1000d3afc`; keep conditional rows, compatibility warnings,
  control tags and callbacks together, while changing their visible layout.

## Additional source-owned routes in `.15`

The adapter now recognizes `TokensViewController`, `TokensImportViewController`,
`CMVC_BulkCloudPushViewController`, `TokensBulkExtractViewController` and
`TokensRouteAllPickerViewController`. Their existing table getters require the
reviewed `@16@0:8` encoding, supported host image and descendant ownership.
Sessions retain the native spinner; destination retains the native search field;
batch Cloud upload retains the native label/passphrase fields, delegates and
secure-entry state. Existing navigation items and table selection callbacks remain
the only operation boundary. Missing or changed shapes show an owned unavailable
screen. No session loader, upload worker, completion block or model getter is
called to render these routes.

`BackupCell` type copy is Fixed only in the verified fourth centered 10-point
rounded badge. Filenames, including names that equal legacy product words, and
other labels remain UserData. Source-owned section-header overlays retain the
original root, tag and gesture; rendering does not select a section. Proxy card
interiors are replaced while native action carriers, hidden/enabled state and
user values remain intact. The exact `CloudPlansViewController` alias is denied
as a store surface without classifying the licensed Cloud flow as a store.

The scoped constructor review covered named methods and recovered anonymous
blocks in the eight session/Cloud controllers. The six retained edges are:
Sessions → Details (`0x1000a543c`), Sessions → Export (`0x1000a355c`),
Sessions → Import (block `0x1000a3fbc`), Import → Destination
(`0x1000ac1d8`), Cloud → Cloud Upload (`0x1000875a0`), and Cloud Upload →
Batch Upload (`0x10008bd8c`). Export/details terminate in original alerts,
password/save/progress or Files actions; destination retains its completion/pop;
batch upload retains original confirmation/delegate callbacks. The two commerce
branches (renew → checkout and change plan → market → CloudPlans) remain denied
by owned navigation. No additional controller constructor or `NSClassFromString`
was found in those reviewed method/block ranges. This is a finite route review,
not proof of whole-binary or physical navigation coverage.

Header delegate admission reads `method_getTypeEncoding` from the installed
method. It must not trust a signature inferred from an inherited method or
protocol: the malformed-section-argument regression demonstrates that difference.
The original callback runs once before the owned header overlay is updated.

## Scope and invariants

1. Do not create an admitted controller or overwrite the application's window
   root. The existing licensing and routing lifecycle decides what is shown.
2. Original UIKit controls/delegates remain the action boundary. No display text
   is interpreted as a container ID, proxy credential or executable command.
3. Original view-builder callbacks run first. Public UIKit bindings refresh
   labels/enabled state; no timer, new identity or storage operation is added.
4. Known-screen runtime mismatches show an owned unavailable form. Optional
   action mismatches are visibly disabled, never sent with guessed arguments.
   Unsupported bundle/version metadata refuses the overlay entirely.
5. Static display-copy mappings do not modify arbitrary input, protocol names,
   package identifiers, filesystem names or archive formats.
6. A successful UI fixture is not a network fence, a completed switch receipt,
   or physical cross-container isolation evidence. ADOPT-003 remains a gap.

## Responsive presentation checks

Containers use one scrollable header/results area plus a persistent create action.
The dock follows live bottom safe-area changes. Narrow and accessibility layouts
stack controls; the heading and persistent actions use bounded font growth while
body text keeps full accessibility scaling. The 559-check layout fixture covers
320/375/390-point portrait viewports, a 667-point landscape viewport, a changing
34-point bottom inset, the largest accessibility text category and a synthetic
216-point input view driving UIKit's native keyboard layout guide. All 40 stable
IDs remain reachable and rendering invokes zero backend operations. These are
synthetic geometry checks, not physical rotation or device acceptance.

## Physical acceptance still required

Open the nine workspace types and the existing picker/backup/Cloud sheets;
exercise search, scrolling to row 40, context menus, selection/reorder, cancel,
keyboard entry and async license/proxy/location updates. Confirm maintenance
still shows its original confirmation and no action fires simply by rendering.
Do not use the palera1n Loader as an isolation target. The `.15` update is installed
on iPhone X / iOS 16.7.16 with all 59 payload hashes and scoped data verified. The historical `.14` package/data comparison receipt is
`docs/release-evidence/socialbox-english-ui-2026-09-27.json`. Installation does not
establish foreground UI or cached launch snapshot acceptance; record cold launch
separately from simulator rendering. The synthetic workspace fixture waits for
modal detachment and visible selected content before taking its preview.

The `.15` source and fixture receipt is
`docs/release-evidence/socialbox-ui-completion-2026-09-28.json`. Final package readback and all six native synthetic UI suites pass there;
installation and unchanged scoped data are recorded separately from those host checks.
The working USB preview currently shows the lock screen, not an unlocked app.
Phone acceptance remains `NOT_RUN`; no earlier installation or synthetic result
is carried forward as current physical acceptance.
