# Presentation screen contracts

The appearance-only behavior below describes the original overlay. The new
source-owned workspace and its action/refresh boundary supersede that behavior
for supported screens; see [WORKSPACE_CONTRACT.md](WORKSPACE_CONTRACT.md).
The class/getter addresses below remain the ABI evidence.

The `.12` registry additionally admits the exact startup `_Xd2z` and welcome
`SocialBoxOnboardingViewController` classes (20 classes total). Their getter,
lifecycle and callback addresses are recorded in `WORKSPACE_CONTRACT.md`.
The historical exclusions below describe the earlier appearance-only unit;
startup/welcome now use source-owned layouts while validation stays original.

This list pins the supplied SocialBox 3.1.0/build 1 **arm64** Objective-C UI.
It is static evidence for source-owned appearance changes, not execution of
recovered UI or proof of backend behavior. Original field values, selections,
callbacks and admission remain owned by the original implementation.

Input references are relative to the private extraction
`work/private-socialbox-adoption-2026-09-20/`. The method index is
`socialbox-3.1.0-1/decompiled/SocialBox.functions.tsv`; getter bodies are in the
adjacent `SocialBox.c`. `socialbox-app-arm64-objc-metadata.txt` establishes the
class inheritance and method encoding. A name in an index alone is not enough
for a backend operation; this overlay invokes only the listed visual getters.

The established five-screen shell remains Home, Containers, LocSim, Proxy,
Settings. The additional mapped screens are:

- **Identity configuration — `FakeInfoViewController`.** `viewDidLoad`
  `0x1000d2b30`; `contentStack` `0x1000db980`; `meshGradientLayer`
  `0x1000db9a4`; class metadata starts at line 22038. Both getters return
  objects. Country/carrier/language, range/specific model, version, lock toggles
  and regeneration handlers are preserved; the overlay never calls them.
- **Country — `CountryPickerViewController`.** `viewDidLoad` `0x1000dbd74`;
  `tableView` `0x1000ddc6c`; metadata line 22819, UIViewController superclass.
  Existing country lists, search, favorites, delegate, Done and dismissal remain.
- **Carrier — `CarrierPickerViewController`.** `viewDidLoad` `0x1000dddf8`;
  `tableView` `0x1000e0b7c`; metadata line 24363. Existing country restriction,
  show-all control, marker/checkmark and selection callback remain.
- **Model — `ModelPickerViewController`.** `viewDidLoad` `0x1000e1124`;
  metadata line 25927. UITableViewController owns the inherited `tableView`
  getter. Model partitions, compatibility hints and range inversion handling
  remain original; the overlay does not expand the catalog.
- **Allowed models — `DRTAllowedModelsViewController`.** `viewDidLoad`
  `0x1000e43d0`; metadata line 26077; inherited UITableViewController table.
  Search, multiple selection, recommendation hints and Done remain original.
- **iOS versions — `VersionPickerViewController`.** `viewDidLoad`
  `0x1000e6c74`; metadata line 26695; inherited UITableViewController table.
  Version values, mode and inversion confirmation remain original.
- **Application selection — `AppListViewController`.** `viewDidLoad`
  `0x1000f64c8`; metadata line 27147; inherited UITableViewController table.
  This is original-app membership selection, not a new decrypted-IPA importer.
- **Local backups — `BackupsViewController`.** `viewDidLoad` `0x100068c6c`;
  `tableView` `0x10006e934`; metadata line 2458. Export/import/delete operations
  are not intercepted or invoked by the appearance layer.
- **Cloud list — `CloudViewController`.** `viewDidLoad` `0x10007feac`;
  `backupsTable` `0x10008978c`; metadata line 4538. Quota, passphrase, reload,
  restore and bulk operation handlers remain unchanged.
- **Cloud upload selection — `CloudPushViewController`.** `viewDidLoad`
  `0x100089b38`; `table` `0x10008ed6c`; metadata line 6201. Existing account,
  credential, app filters and upload data are not accessed by the overlay.
- **Existing item detail — `TokensDetailViewController`.** `viewDidLoad`
  `0x1000b18c4`; `table` `0x1000b5490`; metadata line 17893. The overlay only
  styles the table surface; it never reads or exports item/session values.
- **Bulk proxy import — `BulkProxyImportViewController`.** `viewDidLoad`
  `0x10021def8`; `previewTable` `0x100221d48`; metadata line 40448. Text entry,
  parser, deduplication and import remain untouched by this presentation unit.
- **Licence form — `_Xm8u`.** `viewDidLoad` `0x10015b9f4`;
  `containerCard` `0x100168028`, `titleLabel` `0x100168070`,
  `meshGradientLayer` `0x100168214`; metadata line 33029, UIViewController.
  The exact inert title literal at `0x100388134`, length 15, decodes to
  `SocialBox License`; its construction is `SocialBox.c:104558–104623`.
  Only that exact text in the title getter's noninteractive UILabel inside
  its own card becomes `SocialBox License`, preserving attributed typography.
  Custom/interactive titles, keys, device IDs, errors, progress, plan/product
  labels, buttons, validation and callbacks are unchanged. Its original logo
  loads the `AppIcon` resource; the existing candidate already supplies that
  resource. The overlay does not alter the license-screen root or authorization.

## Runtime safeguards

All 18 exact classes require the pinned host metadata and compatible lifecycle
signatures. Recovered classes must originate from the actual host executable;
visual getter implementations must belong to it too. Only the inherited
`tableView` implementation of a UITableViewController may originate in UIKit.
Paths are normalized for jailbreak symlinks. These checks establish expected
provenance, not a cryptographic verification of the complete binary.

The established five-screen shell is checked before any hook is installed.
An unsupported additional screen receives no hooks, is explicitly reported,
and leaves the shell available. Object class and descendant ownership checks
run before styling. A detached or wrong-typed surface is left unchanged.
Only `viewDidLoad`, `viewWillAppear:` and `viewDidLayoutSubviews` are hooked;
original methods run first. All data sources, delegates, field values and action
handlers remain original. Repeated styling does not rebuild the hierarchy.

## Exact remaining visual gaps

Inline UIAlertController language/source/import prompts use their existing
presentation and inherited navigation tint; this unit does not globally hook
UIKit alerts or rewrite their text. Checkout/marketplace, onboarding/splash,
QR camera and embedded web content are not newly restyled here. Their shapes
and dynamic text have not been approved as inert decoration. Additional
source-owned screens require their own recovered visual contracts.

Passing synthetic fixtures establishes behavior of this appearance code with
UIKit. Actual originals, jailbreak injection, current menus, keyboard layout
and appearance on the phone still require physical acceptance. Neither model
catalog completeness nor original Cloud/network/isolation correctness follows
from a palette change.


## Containers inherited progress decoration

Static retained arm64 manager SHA256
`e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0`
shows the UIViewController `_Xr7t` category loader inherited by `_Xc9m`.
Show `0x100223568` is `v24@0:8@16`; overlay getter `0x100223094` and label
getter `0x100223104` are `@16@0:8`. It creates a window dimming UIView,
200×140 card, large UIActivityIndicatorView and UILabel. Theme primary color
`0x10022415c` is orange `(1,.584,0,1)`. Switch body `0x100111358` calls show
through stub `0x10034ac80`; other Containers operations use this loader too.
Update `0x100223ce4` and hide `0x100223d78` remain unhooked. The decoration
changes the spinner's visible artwork only and adds no operation authority.
Static recovery/source fixture evidence is separate from owner installation.
