# Private owner UI composition

Unit 45 extends the palette to the retained native manager theme and public orange
color requests, removes the empty connection guidance card and repairs saved-proxy
context menus and refresh. The exact signed owner overlay was applied on 3 October
with fresh quiesced backups. Independent reads verified original services, program
identities and unchanged container selections/counts. The phone screenshot confirms
the blue Containers list; actual popup/menu interaction and Instagram account/proxy
acceptance remain open. No proxy is currently saved. See
`release-evidence/socialbox-blue-proxy-ui-2026-10-03.json` for exact scope and evidence.

Unit 44 adds inactive-row left-swipe Delete, right-swipe Rename, a selected-name
heading and blue native alert tint. On 3 October its exact reviewed UI dylib was
applied to the owner phone with fresh backups. Existing state and the other
witnessed programs/controls stayed unchanged. A real screenshot confirms the
saved names, selected heading and blue list; physical gestures and popup
interaction remain untested. Simulator action/popup/layout/creation regressions
pass. See `release-evidence/socialbox-container-controls-2026-10-03.json`.

Unit 43 installed the exact reviewed blue presentation dylib as a backed-up
private owner UI trial on 2 October. A real screenshot and process observation
confirm the minimal blue Containers screen; the existing selected container is
visually unchanged. This did not install the composition deb. Other witnessed
programs/controls, the filter and quiesced manager-state files remained unchanged.
Physical Settings/profile navigation, live loader, create/switch, accounts/proxy
and complete isolation acceptance are still open. See
`release-evidence/socialbox-blue-updates-2026-10-02.json`.

`tools/build_socialbox_owner_ui.py` composes the accepted owner UI source at
`ca333e80d89e3ee86f3c62a77503738430239467` (tree
`81ca825314080cc958a20e5abfd9e5080013650f`). It changes thirteen source paths: the reviewed Containers view, its authored
presentation copy, the blue loader implementation/header and visual hook,
the shared brand palette, the diagnostic tint, update service/header,
the narrow Settings update entry, activation button color and native alert
display implementation/header. The remaining 39 original graph files are byte-identical to that Git source. The workspace
and activation implementations are also byte-identical after removing only
the reviewed Settings entry, proxy empty-card removal and native context-menu preservation, and reverting the single button-color literal. This is source preservation, not a fresh phone/mapped-image observation.

Containers shows saved names, Selected, Switch and Create container. The selected
name also appears in the heading. Swipe left for Delete (inactive containers only),
or right for Rename. Full-swipe execution is disabled. Each action re-resolves the
captured stable ID against fresh native state, forwards the original confirmation
once and leaves list changes to the original operation and refresh callbacks. The latest owner request adds a pre-create
review of sixteen current reported profile values, a Device settings entry to the
existing country/carrier/model/iOS controls, Cancel and explicit Continue. Rendering
and Cancel invoke no original entry. Editing never queues creation; users return
to Containers and review again. The existing settings are shared, and the displayed
values are not an exact proposed or generated per-container profile. Unavailable
values stay unavailable. The create wizard is still the existing
native flow; automatic app choice, whole-device identity changes and safe isolation
are not implemented by this UI. The accepted activation behavior, backend adapter, proxy input and license-client
source are preserved. Activation changes only its button color. The workspace
adds the Settings update entry, removes the exact native empty guidance card and
retains UIKit context-menu gestures on saved proxy rows, including after refresh.
Later source
saved-settings/activation readiness modules are excluded from this profile.

The 52-file quoted production graph is captured before compilation and checked
after final universal ad-hoc signing, strict per-slice verification, entitlement
extraction and archive creation. Three producer Python files are observed before
and after the build; their imports precede that observation. SDK, Theos, compiler,
OS and dynamically linked signer dependencies are outside the frozen graph.
Host signature checks do not establish publisher or iOS launch trust.

The resulting private `.deb` is **composition only**. Its payload is exactly
`LBXPresentation.dylib` and its app-only filter. Original programs, helper controls,
installation/pairing/configuration/pending state, credentials and licensing jobs
are absent. Both preinst and postinst refuse every invocation with exit78.
It cannot be installed through Sileo or offered as a customer artifact. There is
no preparation authority, policy migration, root reset or fallback initializer.

The builder accepts only the accepted Git tree, the unchanged blue header Git
pin and fixed SHA-256 pins for the reviewed UI/update source. It imports only
nine creation-review strings, two update-handoff strings and two container-heading
strings into the accepted copy. Existing Delete and Rename strings remain intact.
The Settings entry and narrowly reviewed proxy presentation blocks are extracted
from pinned source between unique markers; activation receives one exact color replacement. The alert presentation hook is
also extracted between fixed markers, preserving the rest of the accepted hook
implementation. Original alert objects, action handlers, styles, enabled states and
text fields remain intact. Public view tint is set to brand blue around the original
presentation and completion; destructive actions retain UIKit semantics. The
retained manager theme and its observed public orange color requests also receive
brand blue. These replacements validate the exact manager metadata, method ABI
and source image; public system/RGB calls from other images keep their original
colors, and RGB replacements preserve alpha. It
uses a new output directory, retains bounded tool journals, and verifies canonical
archive nodes, content and controls. The focused tests execute only inert refusal
scripts and synthetic files. `tools/test_owner_ui_simulator.py` tests the composed
view/accepted adapter against inert UIKit hosts. PASS is published after the unique
simulator fixture is uninstalled successfully. No phone or original engine runs.
`tools/test_creation_review_simulator.py` additionally checks the actual review
against inert original-shaped controls, using both the current source and the
composed owner profile. It freezes all candidate graph files and its control inputs,
and publishes PASS only after successful unique-fixture uninstall. The local
receipt is `docs/release-evidence/socialbox-creation-profile-review-2026-10-02.json`.

Physical UI acceptance remains separate: establish current trusted phone access,
observe role, fixed paths, original program/control identities and default state
without reading account contents, then quiesce and take new private backups.
Do not replace unknown nodes or established prepared-policy images. The full current
overlay is still unsuitable as an owner UI-only replacement. The old isolated
blue addon pins the accepted old overlay and cannot be combined with this new
full visual-hook registration. No switch/account action is used merely to preview
the loader. Actual creation, confirmations, navigation, live loader and restoration
must be accepted before an owner installation is called complete.

This profile completes local private composition, not the final customer package.
Fresh provisioning/normal activation, actual safe isolation, accounts/proxy traffic
and final Sileo/download acceptance remain open. The Instagram sibling leak stays
unfixed. The owner's two-Facebook-container report is preserved as
OWNER_REPORTED_PASS, with independent current runtime acceptance still open.

## Brand blue and package-manager handoff — 2 October

The shared accent, activation button, loader and diagnostic status/share tint use
`#007AFF`. The alternate legacy launcher also replaces its orange button/status
colors; synthetic orange fixture inputs remain so the loader replacement is tested.
Containers controls, proxy input and the existing switch operation are unchanged.

Settings exposes **App updates**. Opening that page reads its current status;
**Check for updates** requests the existing approved stable-channel manifest. A
compatible available release then hands off to the fixed SocialBox source in
Sileo, falls back to Zebra if the OS rejects that open, then opens the owned HTTPS
instructions page if neither handler opens. The instructions button remains
available when there is no public release. Closed, incompatible or failed checks
never imply an available upgrade or open a package manager.

The URLs follow the upstream [Sileo source handler](https://github.com/Sileo/Sileo/blob/main/Sileo/AppDelegate.swift)
and [Zebra source handler](https://github.com/zbrateam/Zebra/blob/v1/Zebra/ZBAppDelegate.m).
They point only to `https://redditspoof.vercel.app/apt/socialbox/`; no manifest URL,
access key or container data is passed to another app. A successful OS handoff
proves that an app opened, not that the source refreshed or an upgrade installed.
The customer approves **Upgrade** in the package manager. These changes do not
remove, reset or recreate existing containers, and they do not open the stable
channel or turn this private composition archive into an installable release.
