# SocialBox reference redesign

Reference review: 2026-09-19. Implementation update: 2026-09-20. Reference: the thirteen user-supplied screenshots `IMG_0003.PNG` through `IMG_0015.PNG`, plus the separate read-only installed-binary investigation in `doritoz-device-reference-2026-09-19.md`.

This is the implementation contract for the redesign, not a certification of reference-app isolation. The inventory distinguishes observable reference behavior, the implementation completed in this pass, and deferred or excluded behavior. Any earlier baseline limitation is explicitly labelled historical. Screenshots establish visible controls and wording; they do not establish working handlers, storage boundaries, proxy routing, or successful cloud restores. Screenshot device identifiers, seeds, licenses, and proprietary artwork are deliberately omitted.

## Intended daily flow

Choose an app workspace → choose a saved container → wait for the daemon's confirmed selection → open only after the existing launch checks allow it. Home summarizes that confirmed selection. Containers is the searchable inventory. Location edits the selected container's proposed region. Proxies manages saved connection settings. Settings holds initial setup, license, Cloud, and diagnostics.

The simple creation flow is now: name → choose the configured device proxy → prepare a draft → review/edit identity → create. Both Reddit Home and Containers enter this wizard. Preparing retains a daemon-private preview, not an installed container; the explicit Create action consumes the reviewed draft. The existing advanced legacy creation path remains available. Existing identities remain stable when switching. A green selection badge means **selected**, not that network enforcement or isolation has been proven.

The current implementation uses independent signed clones, app-scoped descriptors and a managed app-proxy provider. The reference has evidence of original-app data switching and a personal packet tunnel. Replacing those engines is a separate state/storage/network migration, not a styling change. An attractive interface must not make an unavailable original-app or no-MDM mode appear operational.

## Complete screenshot inventory and disposition

### IMG_0003 — Home, top

- Persistent five destinations: Home, Containers, LocSim, Proxy, Settings. Reuse the existing five-tab `RBXLauncherAppDelegate.m` shell, `RBXWorkspaceNavigation.h` tagged navigation and passcode guard. Use “Location” in SocialBox to avoid promising system-wide simulation.
- App logo, left menu, configuration gear. Retain original SocialBox branding; expose clear Setup/Cloud destinations without copying the reference logo or unknown menu contents.
- “Spoofing status / Enabled” switch. Do **not** map a local UI Boolean to isolation success. SocialBox must show the real selected-container, daemon, network and recovery states. No global disable control should silently remove protection from running apps.
- New Container button. Simple mode now enters the prepare/review/create wizard from both Home and Containers, including Reddit. The historical materialize-before-review wizard has been replaced with daemon-private draft preparation. Advanced legacy creation remains separate.
- Configure button. Reuse the selected profile's `RBXIdentityViewController`; disable when nothing is selected and retain identity locking after first use.
- Identity overview: the reference shows name, iOS version, marketing model, retail model number and serial. SocialBox Home now shows six existing non-secret summary fields: model, iOS, country, carrier, locale and time zone. Private identifiers remain in the protected editor; publication has not been widened to expose them. Missing values are marked unavailable.
- Network/cellular overview begins with Wi-Fi MAC, Bluetooth MAC, Ethernet MAC and IMEI. Those reference Home cards were not reproduced; supported values remain reviewable in the identity editor. Synthetic identity values do not alter physical radios.

### IMG_0004 — Home, lower

- Ethernet, IMEI, MEID, ICCID, carrier and MCC/MNC complete the network/cellular group. Match field labels to actual supported registry keys; do not manufacture a MEID/ICCID row as “covered” from a decorative value.
- Tracking IDs: IDFA, IDFV, UDID. Existing saved editor values and the zero-IDFA/ATT policy are retained. The Home redesign does not publish these private fields. A generated value remains distinct from evidence that every API returns it.
- “Kill App…” tool. Reference chooser and termination result are unseen. SocialBox's launch/switch/delete operations already use coordinated process shutdown. A manual Stop action needs a daemon operation that closes traffic first, targets only the registered app family and verifies termination. A UI-only `killall` is not equivalent.

### IMG_0005 — Identity region and language

- Country chooser and note that carrier/MCC/MNC match the region. Reuse catalog country/locale/time-zone/carrier relationships and `detectProxyRegion`. Proxy country is observed through the proxy; a carrier is a catalog suggestion, not an observation of the proxy operator's cellular network.
- Carrier chooser with “Random per seed”. The new searchable picker uses valid in-country entries and shows MCC/MNC. Automatic preparation chooses a supported result that can be reviewed. The reference’s global carrier lock and explicit random-per-seed selector were not added; existing containers are not rewritten.
- App language Auto or explicit override. Current editor has a coupled locale and one locale per country. A distinct display-language override requires schema, hook and consistency coverage; a new picker alone cannot establish it.
- Model Range / Specific control, lower/upper model bounds. Current editor supports a specific catalog model with compatible iOS. Range-based creation rules are a proposed generation policy, not an existing hook feature.

### IMG_0006 — Carrier selector

- Search field, Done action, grouped countries, “No lock / Random per seed”, selected checkmark and named carrier rows. SocialBox now has a reusable searchable catalog picker with selected checkmark, Cancel, descriptive rows and country groups for carriers/cities. Carrier choices stay within the draft’s country; choose Region to update related catalog fields together. No global lock/random toggle is implied.
- Visible country groups are examples, not an authoritative global carrier database. Reuse `profiles/catalog.json` coverage and disclose absent countries rather than copying labels without MCC/MNC data.

### IMG_0007 — Identity generation bounds

- Model range lower/upper bounds and iOS version range lower/upper bounds. Validate both bound order and model/iOS compatibility. The reference screenshot visibly shows a descending iOS range; SocialBox should reject such a draft, not reproduce the inconsistency.
- Lock Device Model and current model. A draft-generation pin differs from SocialBox's whole-identity lock after first use. Keep those concepts separate.
- Lock iOS Version begins at the bottom. If draft pins are added, they constrain preparation only and must not override a used identity's immutability.

### IMG_0008 — Identity locks and regeneration

- Exact current model, exact current iOS/build, model/version lock switches. Reuse catalog model/version choices; mark absent build data unavailable.
- Regenerate Identity and its same-seed explanation. SocialBox already separates automatically filled draft, consistency check and save. Preserve that review boundary; never mutate the identity of the active/used account merely because a button was pressed.
- “Other identifiers / Auto-Generated Values” lists serial, UDID, MAC, IMEI and ads ID. SocialBox's generator and derived-field registry are the authority, not a numeric marketing count. All displayed values need a supported/derived/unavailable classification.

### IMG_0009 — Containers

- Import icon, Select mode, search containers/folders, sort button. SocialBox preserves search and recent/name/model sort. Cloud backups opens the real backup/restore workflow. There is no fake import, folder or multiselect action; folders/manual ordering/batch selection remain deferred.
- Separate current-session card with active badge. SocialBox must distinguish confirmed selection from running session and from network OPEN.
- Group count and container card with selected mark, name, abbreviated seed, date, app icon and “Empty”. Reuse per-app container rows and local phone artwork; show meaningful saved model/region and launch readiness. Empty cannot mean “no account” unless an actual account check establishes it.
- No fixed three-container limit is shown. Preserve the unbounded list and existing forty-row lifecycle/presentation tests.

### IMG_0010 — LocSim

- Map, search/place-or-coordinate field, map-mode control, location arrow, preset-city chips and selected pin.
- Selected coordinates with copy affordance, address, bookmark, history count, globe control and Start Simulation.
- Screenshots do not prove whether simulation affects selected apps, all apps, or system services; map/icon actions beyond their labels are unknown.
- SocialBox Location remains a per-container saved region view. Searchable country and city pickers now update the editor’s draft using catalog coordinates/time zones; proxy-based region suggestions are retained. System-wide simulation, a map, live geocoding, route/history/bookmark features remain deferred. Avoid silent direct geocoding/network requests that bypass the configured proxy.

### IMG_0011 — Proxy

- Search, plus, overflow, total count and empty state. Existing `RBXProxiesViewController.m` implements saved entries, add/edit/delete, selection, connection testing and search. Retain visible proxy URL per user preference; do not expose credentials in logs/diagnostic exports.
- Scan QR, Paste a list, Import from Shadowrocket. “Paste a list” is implemented for HTTP proxies: bounded input, canonicalization, duplicate detection, per-line issues, preview and explicit atomic import. Editing input or changing the library invalidates an old preview. QR and Shadowrocket import are not implemented and are not offered as working buttons.
- Per-container Link Proxy promise. **Current saved library selection is device-wide setup; actual launch assignment comes from Cloud.** Do not relabel `RBXProxyLibrary selectIdentifier:` as container assignment. That needs explicit profile ownership, assignment validation and daemon/cloud agreement.
- The reference's claim that different proxies prevent account correlation is not a valid guarantee. Use exact connection/enforcement/measurement status instead.

### IMG_0012 — Settings status and identity backup

- Server Connected, device license-binding identifier, jailbreak type. The new “This device” card shows configured server host, actual activation/offline-grace status, historical sync information and local OS/package/app version. A saved host or old receipt is not labelled “Connected.” Reference device-binding values and jailbreak-brand claims are not copied.
- Copy Identity / Import Identity. Reference mentions a seed, not full app-data backup. SocialBox Cloud transfers an encrypted app-data/identity backup; that is a different operation. An identity-template export/import must use a versioned, validated schema and avoid duplicating identifiers across live containers.
- Masked license, activated-device count, license plan and app version. Reuse `RBXLicenseViewController` and `RBXLicensePresentation.h`; display only fields actually supplied by the current signer, never invented device quotas or plan names.

### IMG_0013 — Settings preferences

- Spoof Settings App switch. This implies mutation visible outside the selected app and is contrary to narrowly scoped container identity. Do not add it as a default or as a fake toggle; document as intentionally excluded.
- Reddit NSFW presentation toggle. Unrelated to container isolation and unimplemented; do not introduce a hook under this UI refactor or imply it exists.
- Floating system-wide keyboard-dismiss overlay. Unimplemented and not required for the isolation flow. Native keyboard dismissal/accessibility inside SocialBox addresses the actual form usability problem without a global overlay.
- Respring / SBReload tiles are visible. These are separate system operations, not prerequisites for normal container switching. Keep diagnostics/recovery discoverable without adding destructive system controls as decoration.

### IMG_0014 — Recovery and destructive actions

- Respring, graceful SpringBoard reload, userspace reboot, Clean Crane orphan keys, Recover palera1n icon, Recover Daemon.
- Reset Everything and Logout danger zone.
- Reference action results and confirmations are not shown. SocialBox must not delete another tweak's keys, perform broad root cleanup or restart the phone merely to imitate these tiles. Existing diagnostics/support export and recovery journals are the integration points; any targeted repair needs verified ownership and explicit user confirmation.
- Logout needs the current license lifecycle and a closed-session transition; Reset Everything needs a separate enumerated deletion/backup design. Neither should be a nonfunctional or overbroad shortcut.

### IMG_0015 — Container context menu

- Switch to Default: reference's original/default storage mode has no direct equivalent in the independent-clone engine. Do not launch the original App Store app as if it were protected.
- Edit Apps: reference container can contain several apps. Current SocialBox descriptors scope one profile to one app. A multi-app workspace grouping layer is possible later; do not change profile ownership in place or merge app sandboxes.
- Link Proxy: blocked on explicit per-container assignment integration described above.
- Export: reuse actual Cloud encrypted backup, with a named selected-container entry point. Preserve limitations: Keychain and hardware-bound credentials are not transferred; login survival is unverified.
- Rename: implemented as an organizational label through the existing metadata operation, with validation, daemon publication and revision-checked Cloud reconciliation. It writes one optional profile label; central installation name remains the legacy fallback. Bundle IDs, paths, accounts, generated identity and app files stay unchanged. Editing device name is separate.
- Move to Folder, Reorder: can be local app-scoped presentation metadata; must not alter container IDs, identities, paths or selection.
- Session Tokens: contents and export behavior unseen. Do not add token extraction or display from a screenshot label; provide account/login-verification status and diagnostics instead.
- Delete is disabled for the active reference container. SocialBox may either disable and explain, or reuse its existing close/stop/owned-data deletion transaction. Retain explicit destructive confirmation and retryable failure state.

## Implementation map and preserved boundaries

- `launcher/RBXAppearance.h`: default dark appearance, card/button/field/navigation styling. Shared ownership by the native shell implementer avoids inconsistent per-screen styling.
- `launcher/RBXLauncherAppDelegate.m`, `launcher/RBXWorkspaceNavigation.h`: five tabs, app selector, independent navigation/drafts and passcode checks. Keep registered-app admission unchanged.
- `launcher/RBXLauncherViewController.m`, `launcher/RBXWorkspacePresentation.h`: Home, Containers and current Location mode; selected profile, durable IPC receipts, search/sort, real launch/selection/deletion actions. Good boundary for identity overview, current-selection card and context-menu refinements.
- `launcher/RBXSettingsViewController.m`, `shared/RBXSetupChecklist.h`, `launcher/RBXAppSetupStatus.h`: real readiness, source import, managed VPN setup and Cloud/account links. Good independent boundary for concise Settings overview and progressive disclosure; no protocol changes required for visual grouping.
- `launcher/RBXIdentityViewController.m`, `launcher/RBXIdentityHelp.h`, `launcher/RBXIdentityReview.h`, `shared/RBXIdentityFields.h`, `daemon/RBXDeviceCatalog.m`: keep draft generation/validation/locking; `launcher/RBXCatalogPickerViewController.m` now supplies searchable model, compatible iOS, region, language, city and carrier choices. Do not let the UI invent identities or bypass daemon consistency checks.
- `launcher/RBXSimpleWizardViewController.m`, `launcher/RBXCreationDefaults.h`, `daemon/RBXCreationDraftStore.h`, `daemon/main.m`, `daemon/RBXContainerRegistry.m`: real prepare/review/edit/discard/commit flow. Only the daemon-held reviewed envelope can create a clone. Device-proxy selection is explicitly distinct from the Cloud assignment required before Open.
- `launcher/RBXProxiesViewController.m`, `shared/RBXProxyLibrary.m`, `shared/RBXSecureConfig.m`: library editing and secure saved connection configuration. Separate ownership from profile assignment/network enforcement.
- `launcher/RBXCloudVaultViewController.m`: encrypted backup list, same-license restore-as-new, encryption-key transfer, delete-cloud-only and searchable source-container selection. Web navigation now uses the selected registered app’s `/apps/<appType>#cloud-backups` under the configured HTTPS server origin.
- `daemon/RBXLauncherState.m`, `daemon/main.m`, `daemon/RBXContainerRegistry.m`: authoritative publication, transactions and stored identity. Change only for a real missing operation with tests, not to make a UI indicator green.

## Ownership boundaries used for this pass

1. Shell/Home/Containers owner: `RBXAppearance.h`, `RBXLauncherAppDelegate.m`, `RBXLauncherViewController.m`, workspace presentation/navigation, corresponding UI tests.
2. Settings owner: `RBXSettingsViewController.m` and a new read-only settings presentation helper/test if needed. Reuse shell styling; coordinate additions to that header rather than editing it concurrently.
3. Identity/pickers owner: identity controller/help/review plus a new searchable picker; coordinate before changing the generator/schema. No daemon lifecycle edits for a presentation-only change.
4. Proxy owner: proxies controller/library and parser/list-import tests. Clearly identify device configuration versus actual per-container assignment.
5. Documentation/sketch owner: this document and `socialbox-reference-preview.html` only. The preview is a proposed flow using synthetic memory-only data, not the native implementation or isolation evidence.

## Validation and acceptance

Keep `tools/static_check.py` and the existing native/regression suite green. In particular retain app registry/scope, workspace dispatch/selection, simple wizard drafts, setup checklist, launch safety, proxy parsing/configuration, identity editor/choices/manual inputs, license presentation, Cloud restore and owned-data deletion regressions. Add tests around newly added state transformations and operations, not decorative pixel values.

Build the native launcher after integration. On-device acceptance remains separate: safe-area/keyboard/Dynamic Type checks, forty-row search and selection, preserved drafts between tabs/apps, actual selection confirmation, blocked Open explanation, proxy failure, switching interruption, reboot recovery, and measured network behavior. Do not record PASS for screenshots of another product or a browser sketch.

The supplied screenshots show no successful Cloud transfer, no forty-account stress run, no IPv6/DNS/QUIC leak capture, no background/death fail-closed result, and no proof of inaccessible sibling data. Those remain NOT_RUN unless separately measured. A changed identifier does not establish that accounts cannot be correlated.

## Implemented native flow in this pass

### Home and Containers

The launcher uses an original local dark amber/blue background, translucent rounded
cards, existing local phone artwork, five navigation tabs and a clear selected row.
Light appearance remains supported. The compact current-selection card leaves a
list row visible on the small-screen fixture. Home shows the six saved non-secret
identity summary fields listed above. An incomplete switch clears the previous
identity from Home until the daemon confirms the new selection.

The row menu exposes selection, Configure identity, Rename, Role & notes, Cloud
backups and confirmed deletion using actual operations. Cloud opens the existing
backup screen, where a source container is explicitly chosen; opening the menu
does not switch, back up or launch anything. Selection confirmation says to Open
from SocialBox and does not promise that an original App Store icon is protected.

### Prepare, review and create

Simple-mode New from Reddit Home and Containers now enters the same wizard. The
registered app/source gates remain in place, and disabled apps do not become
runnable merely because the shared wizard supports their descriptor. The existing
advanced legacy path is retained for compatibility.

Prepare checks the configured proxy and source, observes country through that
proxy, and creates the supported identity in a daemon-private in-memory envelope.
It does not install a clone or publish a live container. Country mismatches and
failed proxy observations reject preparation; there is no direct-network fallback.
The launcher gets only a token, revision, expiry and safe summary; private identity
editing uses the existing protected response path.

Review opens the identity editor in creation-draft mode. Check and Save update
that preview, not a live profile. Create consumes the reviewed daemon envelope
once; it cannot trust a forged profile, changed nickname or older review sent by
the UI. Source, proxy, account/app binding, draft revision and expiry are checked
again. An uncertain or failed commit cannot be reset into a silent duplicate.
Discard removes only an uncommitted preview. Previews expire after five minutes
or daemon restart, and at most eight pending previews are retained; this is not a
limit on the number of saved containers. Created containers still require the
existing Cloud proxy assignment and verified managed VPN checks before Open.

### Proxy library import

The plus menu and empty state offer Add one proxy and Paste a list. The importer
accepts the supported HTTP forms, including a copied “HTTP ” prefix. It previews
new entries, duplicates and invalid line numbers before saving. Every invalid
line blocks the batch. Confirmation rechecks the original library so a stale
preview cannot overwrite concurrent edits; entries are saved together. Editing
the text clears the preview. Import never selects a proxy, starts traffic or
assigns it to a container. SOCKS, HTTPS-to-proxy, QR and app-specific exported
configuration files are not presented as supported imports.

### Settings and Cloud

Settings now leads with This device, Before you open an app, Cloud & transfer and
Appearance. Each prerequisite has a red/green status plus its actual setup action.
Advanced & evidence holds service/isolation evidence, managed VPN details,
defaults, updates and legacy pairing. A successful prerequisite is a status for
that check, not a blanket isolation guarantee. Configured host, historical Cloud
receipt, offline grace and current activation are distinguished.

Cloud retains the real encrypted backup list and adds a searchable container
picker instead of a long action sheet. Backup requires an explicit confirmation;
restore creates a new local container. Private encryption-key responses remain
masked and are cleared when authorization becomes stale. The web button opens
the correct registered app’s Cloud section at the configured server origin.
Keychain and hardware-bound credentials are not transferred, and preserved login
on another phone has not been established by these UI tests.

### Searchable identity choices

Model, compatible iOS/build, region, language/locale, carrier and city use the
shared native searchable picker. Carrier and city groups stay scoped to the
current draft country; country changes update related catalog values together.
Selections change draft fields, and the editor rechecks loaded, unlocked and
not-busy state when a picker returns. An empty catalog gives an explanation.
Existing identity consistency checks, model/iOS compatibility and post-use
identity locking remain. Independent display-language overrides, generation
ranges and model/version pin policies were not added.

### Measured validation for this pass

- Final integrated native workspace, Rename and simple-entry routing fixture:
  **216 PASS**. It covers fifty rows, forty exact target selections,
  pending-switch identity clearing, blocked Open, Cloud navigation,
  rename/cancel/invalid/unchanged handling and searchable confirmed labels.
  Actual Reddit Home and Containers New actions each push the real wizard and
  send no preparation/creation IPC merely by entering it. The earlier Rename
  checkpoint had 212 assertions; the four route assertions are included in 216.
- Searchable picker / identity editor fixture: **198 PASS** with the actual UIKit
  editor, inert IPC and protected synthetic drafts.
- HTTP list importer fixture: **20 PASS** with actual UIKit and inert Keychain/
  daemon responses; existing entries and selection are preserved.
- Creation wizard fixture: **26 PASS**, including preview/review/edit/discard and
  explicit creation, with inert service responses. Release build evidence is
  recorded separately in the final handoff.
- Settings status and registered-app Cloud routing have dedicated native
  behavioral tests. The Settings visual checkpoint also passed the then-current
  **200-assertion** workspace fixture; that is an earlier checkpoint, not another
  two hundred independent device-isolation tests.
- Existing targeted host tests passed for launcher architecture, multi-app
  architecture, workspace presentation and actual workspace dispatch (**177
  assertions**, including forty selections). The creation-defaults fixture passes
  **16 assertions**: the normal route opens the scoped wizard without IPC, the
  advanced alert still displays/submits country and role defaults, explicit Auto
  remains respected, and extracted wizard initialization preserves app-scoped and
  saved-draft preferences. Rename-specific counts are below.

These checks exercise production UI or extracted production handlers against
synthetic/inert boundaries. They do not constitute a physical-device forty-account
run, packet capture, successful cross-phone session transfer or full isolation
proof. Build and device acceptance must be reported independently.

The separate `socialbox-reference-preview.html` remains an explicitly proposed,
self-contained five-tab sketch using memory-only synthetic values. It was checked
in headless Chrome at desktop and 375px width: navigation, draft review/selection,
search, rename, sample transfer and blocked region mismatch produced no JavaScript
page errors. Sketch-only controls are not a claim of native backend support.

## Per-screenshot outcome

- **IMG_0003:** achieved the five-tab dark-card shell, selected identity summary,
  Configure and real reviewed creation. Deferred full sensitive-identifier Home
  dashboard; excluded a misleading global isolation-on switch.
- **IMG_0004:** preserved supported tracking/cellular fields in the protected
  editor. Deferred the full reference card grid and an independent Kill App tool.
- **IMG_0005:** achieved searchable region, in-country carrier and supported
  locale choices with proxy-country consistency. Deferred separate app-language
  override and model-range policy.
- **IMG_0006:** achieved search, selected checkmarks, descriptive carrier rows and
  country grouping. Deferred global carrier lock/random-per-seed controls.
- **IMG_0007:** specific model and compatible iOS choices are available. Range
  bounds and independent generation pins are deferred rather than decorative.
- **IMG_0008:** achieved reviewed automatic identity preparation and exact
  catalog choices. Existing used-identity lock remains; same-seed regeneration
  semantics and independent model/iOS lock switches are not copied.
- **IMG_0009:** achieved searchable/sortable inventory, current selection,
  distinct setup status and real menus. Folders, multiselect and manual reorder
  remain deferred; no “Empty account” status is inferred.
- **IMG_0010:** achieved per-container region/city choice and existing coordinate
  review. Map/geocoding, system-wide simulation, history and bookmarks remain
  deferred.
- **IMG_0011:** achieved saved HTTP proxy management plus reviewed atomic list
  import. QR, Shadowrocket import and local per-container Link Proxy are deferred.
- **IMG_0012:** achieved truthful device/license/server status and access to real
  encrypted Cloud transfer. Raw seed-copy/import, invented quotas/plans and
  guaranteed account-session portability are excluded.
- **IMG_0013:** achieved clear Settings groups, local appearance choice and
  advanced disclosure. Settings.app spoofing, NSFW hooks and global keyboard
  overlays are excluded from this isolation/UI pass.
- **IMG_0014:** retained targeted diagnostics and existing recovery state.
  Respring/reboot, third-party key cleanup, global reset and a new logout engine
  were not added merely to reproduce reference tiles.
- **IMG_0015:** achieved selection, identity configuration, Rename, actual Cloud
  backup entry and confirmed deletion. Original/default-app switching, multi-app
  sandboxes, direct proxy linking, folders/reorder and session-token extraction
  remain deferred or outside this implementation.

## Native rename verification

The Home/Containers menu now exposes Rename in both simple and advanced views.
The form starts with the saved label, accepts a trimmed 1–120 Unicode-scalar name,
and sends only the canonical container ID plus nickname through existing metadata
IPC. Cancel and an unchanged label send nothing. A rejected write keeps the old
label. Cloud backups and replacement preparation use the accepted display label;
the installed app name and bundle are not rewritten.

Nickname shares the existing metadata revision. Name-only publication increments
that revision, a stale rename conflicts, and revisionless inventory heartbeats
cannot overwrite newer labels. A lost successful response is acknowledged only
when the pending label, role and notes match a newer Cloud revision. Existing long
legacy labels and 128-character canonical-ID fallbacks can still synchronize
unchanged; they are neither silently truncated nor treated as new renames. The
daemon accepts an exact echoed legacy label in a successful POST without copying
it into the new optional name field; other malformed reply fields remain subject
to strict validation.

Regression evidence: the original native acknowledgement test failed for a
different Cloud label, and the original Cloud name-only test failed because it
changed the name without incrementing the revision. Both pass after the change.
`tools/test_profile_rename.py` executes the actual registry metadata/discard
methods with inert profile persistence: 55 assertions cover both app types,
exact field preservation, admission denial, invalid metadata, write failure,
Cloud snapshots and legacy fallback. `cloud/scripts/profile-metadata-test.ts`
runs authenticated handlers with isolated atomic storage: 14 checks, including the first upload of a previously offline legacy label.
These are metadata tests, not new evidence of device isolation.

## Follow-up action audit — 2026-09-20

The expanded actual UIKit fixture now passes **239 checks**. It adds regression
coverage for simple-mode recovery menus, Home editing during replacement,
blocked-Open navigation to Settings, correct license destinations and delayed
Cloud-key copy after activation expires. The concrete failing-first cases, fixes,
recording and isolation-register references are documented in
[`socialbox-ui-action-audit-2026-09-20.md`](socialbox-ui-action-audit-2026-09-20.md).
Earlier fixture counts above describe prior checkpoints. The accompanying
creation/proxy pass now verifies wizard53, creation dispatcher251 and proxy23;
none of those counts represents a physical-device account/isolation test.
