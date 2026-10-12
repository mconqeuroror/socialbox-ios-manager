# Isolated owner blue progress addon

## Historical profile — superseded for the current UI composition

The 2 October owner UI composition now includes the progress hook, exact
`#007AFF` artwork, shared blue controls and Settings update handoff. Use
`tools/build_socialbox_owner_ui.py` for that current private composition.
Do not load this isolated addon alongside it: the addon deliberately refuses
when the full progress installer is present.

The addon builder reads and records the current `SBSwitchProgress.m` bytes; it
does not pin that source to an old Git revision. Its fixed pins concern the
historical installed manager and overlay. The shared artwork color has changed
since the Unit33 receipt, so rebuilding now produces a different addon and does
not inherit that receipt's artifact or physical acceptance. The historical
record below remains evidence for the earlier source and artifacts only.

This private addon reuses the exact tested progress artwork under unique class,
function and helper names. It links only `SBBlueProgressAddon.m`, the shared
`SBSwitchProgress.m` and renamed read-only `LBXCallerFile.m`. The full newer
presentation overlay carries other unaccepted source changes and must not be
treated as an animation-only replacement of the current owner UI.

The fixed historical profile checks manager/old-overlay disk bytes, real501 and
effective0, own install/glyph image paths, old loaded-overlay path and exact
metadata. A full newer progress installer refuses. The reused show/getter/ABI,
window/shape/geometry guards remain. The constructor attempts only the visual
hook; it creates no controller/loader, navigation, license or metadata action.
The blue rotating ring/pulse and static Reduce Motion ring retain the original
live message, timer, spinner state, update and asynchronous hide completion.

Disk and loaded-path observations are not mapped-byte or permission-lifetime
proof. The profile is a required pin, not a fresh owner observation, installer
authority or runtime grant. No current phone access is available. Before any
effect, inspect fixed paths read-only in a NEW attempt, quiesce, privately back
up, prove the exact owner baseline and recovery path, then freshly relaunch from
witnessed bytes. Only the new allowlisted `SBBlueProgress.dylib` and matching
filter may be added/removed. Preserve the old overlay/filter, original programs,
all default licensing/storage state and accounts; unknown existing nodes refuse.
Test only the original loader component on an already normally admitted current
Containers controller with no in-flight overlay. Do not invoke a switch to make
the visual test appear. Exact overlay ownership governs preview hide/completion.
No current or customer installation is accepted by this unit.

PASS42 synthetic UIKit assertions with11 quoted inputs and a unique simulator
app; production12 inputs/14 retained tool invocations, both signed slices,
fixed ad-hoc ID, empty entitlements and9 isolated exports each. Fixture disk,
role, loaded-image and metadata substitutions are explicit. Wrong actual roles,
foreign/duplicate images, full-installer presence and physical Reduce Motion are
source-reviewed only. The independent production/data reviewer authored the
UIKit fixtures; root separately reviewed/ran them.

The new offline verifier persists checked, bounded tool journals and explicitly
pinned artifacts/reports/current production graphs. Its25 methods include actual
inert child failure/timeout/output/cleanup cases and synthetic graph drift. An
exact new verification of the earlier full overlay passes; that result supplies
no owner deployment or first-provisioning authority.

Use NEW private directories only:

```sh
python3 scripts/build-socialbox-progress-addon.py --ldid <trusted-local-tool> --output <new-private-directory>
python3 lucid/ProgressAddon/Tests/run_addon_fixture.py --device <booted-simulator-UUID> --output <new-private-directory>
python3 tools/verify_socialbox_presentation.py --overlay <private-full-overlay> --build-report <private-build-report> --expected-overlay-sha256 <reviewed-SHA256> --expected-report-sha256 <reviewed-SHA256> --ldid <trusted-local-tool> --output <new-private-directory>
```

These commands neither connect to the owner phone nor install customer software.
Evidence: `docs/release-evidence/socialbox-isolated-progress-addon-2026-10-01.json`.
