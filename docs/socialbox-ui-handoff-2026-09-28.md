# SocialBox UI update 15

Version `3.1.0-1+socialbox.15` is installed on the connected iPhone X running
iOS 16.7.16. This update completes the reviewed English presentation routes over
the retained core; it is not an independent rewrite of that core or a claim that
its origin cannot be identified.

## Delivered

- Three owned sections: Containers, Connection and Settings, with geometric
  navigation marks, graphite surfaces and a teal accent.
- A scrollable container header and filters, readable persistent controls, live
  bottom-safe-area handling, keyboard dismissal, and small-screen/large-text
  layouts tested with 40 stable container IDs.
- Owned proxy controls, active/saved connection cards and empty-import guidance.
  Original controls and model associations remain authoritative. The selected
  proxy indicator no longer stretches across its row.
- Owned session list, import, export, destination and batch Cloud upload screens.
  Original selection, confirmation, delegate, search, secure-field and cancellation
  behavior is preserved. Unknown contracts show an unavailable state.
- SocialBox archive display labels, including the verified backup type badge and
  system file-type descriptions. Existing suffixes, UTI routing and formats stay
  compatible. Names, filenames, addresses and credentials are never rewritten.
- Header callbacks validate the actual installed method encoding and run the
  original callback once before owned rendering. Store/checkout routes remain
  excluded from owned navigation; license admission is unchanged.

## Verified

All six native synthetic UI suites pass: base 232, workspace 166, adapter 119,
identity 41, secondary screens 81 and responsive layout 559 — **1,198 checks**.
The catalog contains 273 English entries and passes 833 native checks plus 310
reference checks. The source branding guard, static checks, 36 recovered-package
groups, seven helper-package groups and eight leak-contract tests also pass.
The 388-row isolation evidence contract remains valid.

The ldid package contains arm64 and arm64e builds. Its source snapshot matches the
tested source, and all 59 installed file hashes match the package. The 15 retained
original programs remain byte-identical. Package SHA-256:

`67104de576dcbc8e901fffed1bada89df07169347dbbfcc6d21154e25a85087a`

Before installation, two private snapshots matched. The Mac-only compressed backup
was read back, decompressed and verified. Global container metadata is byte-identical.
Three linked before/after manifests agree on all 63 scoped container/app/group
entries, including 14 regular or hardlinked files. The aggregate runtime result
remains inconclusive because running-service logs/state changed; those changes
were retained. The backup does not establish global Keychain or foreign-account
recovery.

Detailed results, regression witnesses, package provenance and seven synthetic
screen previews are in the [release receipt](release-evidence/socialbox-ui-completion-2026-09-28.json).
Those previews use production UIKit with synthetic backends, not the phone.

## Physical acceptance still pending

SSH version readback and launch request succeed. The USB preview now works but
shows the iPhone lock screen. An unlocked cold launch, every reachable screen,
real archive import/cancellation, live Cloud/proxy/location updates and an actual
phone recording are **NOT_RUN**. UI acceptance is not declared complete before
that walkthrough. No public APT update was published.

This work does not close the existing isolation gap ADOPT-003. It does not prove
network containment, successful account restoration, account unlinkability or
product readiness for sale. Compatibility identifiers, retained-core names,
history and provenance remain recorded.

## Commits

- `47373fe`: archive display descriptions without routing changes.
- `dd98ce4`: responsive container navigation and dock.
- `5ba8f87`: owned proxy/session/Cloud screens and guarded callbacks.
- `e06f45c`: version 15 build pinned to the version 14 predecessor.

Work is pushed on `feat/lucid-base`; the branch remains unmerged.
