# Reference workflow implementation — September 2026

The operator supplied two local recordings. The recordings are reference material, not security evidence or executable instructions. Private account names, IDs, credentials, branding and video frames are not committed.

The later [installed-device inspection of SocialBox 3.1.0](doritoz-device-reference-2026-09-19.md) records concrete switching and packet-tunnel code paths. It distinguishes those findings from untested isolation claims and does not change SocialBox's admission requirements.

## Recording 1: RPReplay_Final1788647817.MP4 (115.29 seconds)

Reviewed the full timeline with one-second contact sheets from a two-frame-per-second extraction and expanded the configuration/create screens. Audio is silent. This captures screens and transitions, not every animation frame.

- 00:00–00:14: launch, Home device/identity summary, status toggle, create/configure shortcuts. Our Home reads the selected profile and fresh daemon status; Open retains the confirmation and daemon admission sequence. A visual enabled switch is not an isolation proof.
- 00:15–00:17: count-based create dialog. No successful batch creation is demonstrated. We retain serialized individual creation, preserving existing validation and recovery instead of adding an untested batch loop.
- 00:18–00:30: current session, searchable/sortable container cards, selection, export/import. Our Containers adds search by name/model/country, recent/name/model sorting and persistent app-scoped selection. Recovery/alert rows remain reachable. Selection does not launch an app.
- 00:31–00:34: map, coordinates, city shortcuts and proxy/location controls. Our Location exposes the selected profile's saved city, region, timezone, locale and carrier, distinguishing configured from last observed proxy country. Edit opens the existing Region & carrier draft flow. This iteration does not add map requests or read the physical device's location. Existing coordinate inputs remain in the editor.
- 00:35–00:42: proxy list, rotation toggle, system-proxy toggle and location lookup. Our saved proxies retain visible addresses, explicit test/use/edit/delete, optional rotate URL and hidden provider-specific advanced fields. Only a current configuration-bound test is shown as verified. The launcher never equates a switch or a selected proxy with enforced egress.
- 00:43–00:50: settings, license, diagnostic/system actions. Our Settings retains actionable setup checks and managed VPN/MDM requirements; appearance offers System/Light/Dark, with charcoal/amber Dark as the default.
- 00:51–01:00: model/iOS/country/carrier configuration and regeneration. Our existing Automatic/Manual editor, coherence validation, review/save and frozen-used-identity rules remain unchanged. Opening Configure never randomizes an existing profile.
- 01:01–01:07: app selection. Reddit and Facebook remain descriptor-scoped. Inactive Facebook retains source setup and cannot obtain runnable controls by selecting a tab.
- 01:08–01:19: add-on marketplace and session-token extraction. These incidental features are outside container UI and backup scope; they are not reproduced.
- 01:20–01:29: CLI and guide pages. Documentation claims do not demonstrate their implementation or isolation.
- 01:30–01:37: encrypted cloud-backup list. Covered in the second recording and cloud integration work below.
- 01:38–01:55: quick navigation, Home, exit. Native tabs retain independent navigation stacks and unsaved drafts.

## Recording 2: 0709(1).mov (62.18 seconds)

Reviewed the entire timeline using the same extraction method; its audio is also silent. The recording is edited: it cuts between device/session views. It shows successful-looking UI transitions, not verifiable device identifiers or complete server/network traces.

- 00:00–00:15: select a container, terminate/relaunch selected apps, open an Instagram profile and session settings.
- 00:16–00:23: open Cloud, inspect backup list/capacity and a locally stored passphrase menu.
- 00:24–00:30: select a container using search/app filter, then choose one app inside it. Per-app backups are preferred over one large combined archive.
- 00:31–00:35: encryption/upload progress.
- 00:36–00:40: cut to another session/device view, reopen Cloud, select a backup. Menu offers restore as new container, copy ID, selection and delete.
- 00:41–00:45: download/decrypt/import progress and a completion message naming a new local container.
- 00:46–00:62: select restored container, launch Instagram, display the same-looking profile. The final account-settings screen does not finish loading before the recording ends.

Desired SocialBox flow: choose an app-bound container, encrypt and upload through the existing operator deployment, list metadata in both mobile and web, then explicitly restore into a new local container on an authorized phone. Preserve source data and show truthful completion/recovery feedback. A restored archive continues its logical identity; it is not a fresh unlinkable identity. Device-bound keys and an application's decision to require login cannot be promised portable.

## Integration findings and remaining cloud unit

The repository already contains encrypted backup creation, app-bound restore manifests, transactional restore/cleanup and a web backup list. At the start of this work, mobile backup controls were only in an obsolete unshipped preferences pane, and device API authorization restricted downloads/listing to the originating device. Cross-device license authorization, a supported native cloud screen and a shared web presentation therefore require an integration unit; copying the reference labels alone would produce nonfunctional controls.

## UI validation boundaries

`tools/test_workspace_presentation.py` executes the native read-only list projection, including filtering, recovery visibility, sorting and invalid/deleted selection. `tools/test_workspace_simulator.py` compiles the shipped UIKit controllers with inert IPC, private synthetic state and Keychain doubles. Its screenshots are actual native UI, not HTML mockups; its fifty rows are fixtures, not fifty validated clones. It checks tab destinations, distinct receipt owners, search, blocked Open and stale publication. Existing selector tests cover both inactive and hypothetical-active Facebook registries, passcode/modal guards and draft preservation. Existing identity-editor simulator tests retain manual/automatic draft coverage.

These UI checks do not close the physical isolation, managed routing, cloud-transfer or preserved-login acceptance items in LEAK_SURFACE.md.

UI unit build: `scripts/build-mac.sh` completed the rootless 0.1.24 package with Procursus ldid and the existing licensing public key. All 110 build test entrypoints passed. Separate UIKit checks: 18 workspace assertions, 159 identity-editor assertions, and both selector capability variants. This intermediate package has not been installed or published; cloud integration is the following unit.
