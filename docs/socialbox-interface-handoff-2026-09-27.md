# SocialBox: own interface over preserved core

This is the historical `.13`/`.14` handoff. The current installed `.15` update is
documented in [the September 28 UI handoff](socialbox-ui-handoff-2026-09-28.md).

## Implemented

The new UI uses three sections: Containers, Connection and Settings. It keeps the existing core, containers, license verification and archive formats. It does not describe the retained compiled core as independently rewritten.

Containers have a source-owned searchable list, app/folder filters, compact detail and operation menu. Actions resolve the stable ID against current core models. The old import icon is replaced by a named Import action under Tools. The exact reported empty-import message is mapped to the English import guidance without changing user names or extensions.

Connection groups Proxy and Location. Location has the original functional map/search delegates inside an own layout, a selected-location panel, one simulation action and a tools menu. Settings groups server, licensing, Cloud/backups, current identity/shared generation rules, maintenance, local guide and the owner contact. The locked state does not expose navigation or create an admitted workspace.

The adapter is explicitly pinned to reviewed original metadata and method ABI. It preserves original controls/arguments/callbacks and refuses unknown contracts. Original Cloud/CloudPush/license diagnostics have a narrow error context; unknown diagnostic content receives a neutral reference rather than raw server text. Confirmation/user fields remain intact. Store and checkout routes are removed from owned navigation.

## Decisions and limits

- Containers' display sorting is local. A proven stable-ID API for persistent manual order was not recovered; the new UI does not claim to persist that order.
- Per-container session-token and individual identity-edit entrypoints were not proven. The UI labels current-session details and shared generation rules separately and explains the unavailable individual operation.
- Native proxy/secondary table action carriers retain their original associations and delegates; the visible presentation is owned. Unsupported shapes show an unavailable result.
- Fixed input compatibility and user values are deliberately distinct. Unknown original UIAlertAction titles are not modified through private handler extraction; original actions and confirmations are preserved.
- Original class/service IDs, archive suffixes, provenance and history remain. The guard applies to source presentation, not every byte of the original executable.
- A private runtime backup covers owned namespaces and exact resolved own app/group containers. It does not back up the global system Keychain or establish recovery of accounts in foreign app sandboxes.
- A UI PASS does not close ADOPT-003 or prove storage/network isolation, account unlinkability, Cloud/licensing interoperability or product readiness for sale.

## English language correction

Version `.14` changes all 249 authored catalog entries and the reviewed diagnostic/status replacements to English. User names, credentials, filenames, compatibility inputs and identity values are preserved. This supersedes the Slovak wording shipped in `.13`; the `.13` evidence below remains historical.

## Current English `.14` installation

Private candidate `3.1.0-1+socialbox.14` is installed on the iPhone X / iOS 16.7.16. The separate version readback and all 59 payload hashes pass; global container metadata is byte-identical. The original 15 compiled programs remain byte-identical in the package. The update is not published to APT.

The verified Mac-only backup contains 17,763 entries across 18 owned roots. Two pre-install manifests matched, and the saved gzip was decompressed and checked against the raw digest and manifest before package installation. The prior package remains available for reviewed recovery. No duplicate runtime archive was needed on the phone.

Three hash-linked manifests agree on 63 scoped current-container/app/group entries (14 regular or hardlinked files), including contents, ownership, permissions, links and preserved ACLs/extended attributes. The separately checked older retained namespace also matches across all three manifests: 17,378 entries including 13,900 regular or hardlinked files. These are scoped results, not a global Keychain or foreign-account recovery claim. The aggregate runtime comparison remains inconclusive because two running-service log/state files change between post-install captures; those changes were retained.

The English production-source fixtures pass 228 base, 141 workspace, 90 backend, 41 identity and 27 secondary assertions. All 249 authored catalog entries are English; all original compatibility input strings and format signatures are preserved. `docs/release-evidence/socialbox-english-ui-2026-09-27.json` records the build and installation evidence; its sibling directory contains the reports and synthetic preview.

The SSH launch request succeeds. The USB preview still displays black, so physical screen acceptance and a recording remain NOT_RUN. Installation and English simulator checks do not prove complete isolation or product readiness.

## Historical `.13` acceptance

The machine-readable record is `docs/release-evidence/socialbox-interface-2026-09-27.json`. Per-screen records are in `docs/socialbox-branding-inventory.json`. All test screenshots are clearly marked as production UI running against a synthetic backend; they are not physical phone acceptance.

Historical candidate `3.1.0-1+socialbox.13` was installed on the connected iPhone X / iOS 16.7.16. All 59 package files match their build hashes and global container metadata is byte-identical. The preceding package and scoped runtime backup remain available privately. The backup preserves 17,748 entries across 18 owned roots; two pre-install captures matched. The phone lacks gzip, so its verified backup is raw tar, while the Mac retains a compressed copy.

Three stored manifests (before, after 1 and after 2) agree on the scoped container/app/group data, including bytes, permissions and preserved extended attributes. The aggregate runtime comparison remains inconclusive: the running daemon changed two log/state files between observations, and six log/state/relay files differ from the pre-install baseline. Those live runtime changes were retained. This is not evidence of unchanged global Keychain or foreign target-app account data.

The production-source fixtures passed 224 base, 141 workspace, 90 backend, 37 identity and 27 secondary assertions. Their reports and the 40-record preview are stored under `docs/release-evidence/socialbox-interface-2026-09-27/`. The final workspace fixture waits for actual modal detachment before navigation, then checks selected content, dock, visible rows and successful rendering before taking a screenshot. Production code was not changed to accommodate the fixture.

SSH launch returned success, but the USB preview remained black and no unlocked foreground was confirmed. No physical recording was created. The per-screen phone results therefore remain NOT_RUN; the installed candidate is not declared a completed physical UI acceptance or an APT production release.

Physical acceptance requires the phone's visible unlocked UI: cold launch, all three sections, empty/valid/pack/corrupt/cancelled archive import, field edits, keyboard, dynamic states, original confirmation and secondary pages. No restore or account sign-in is assumed successful from rendering a screen. A recording is delivered only when it actually records the connected phone.
