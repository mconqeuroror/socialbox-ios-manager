# Location map and screen recommendations

Leak-Surface: UI-003, UI-007, OS-064, OS-066, OS-075

The identity editor now opens a native dark MapKit map. The existing Location
page's Edit action opens this map after loading the private identity draft.
There is no additional profile-write or launch route.

## Location workflow

1. Search a city from the installed catalog, enter `latitude, longitude`, or tap
   near a supported city on the map.
2. Review the pin, country, coordinates and any proxy-country mismatch.
3. Tap **Use in draft**, then use the existing **Check consistency** and **Save**
   actions. Cancelling the map leaves the whole identity unchanged.

Search is local and limited to the draft's existing country. The map uses the
same city-coordinate allowance as the daemon: latitude and longitude each must
remain within 0.031 degrees of a catalog city's center. It does not invent
country/timezone data for arbitrary coordinates or silently snap a chosen point.
Selecting a city derives its catalog timezone while retaining the other identity
fields. The daemon remains authoritative when saving.

Configured or last observed proxy-country mismatch is visible and blocks the
map's draft action. Unknown proxy evidence is not called verified. Existing
proxy lookups and launch checks are unchanged. A map callback also rechecks the
editor's pending operation, first-use lock and complete displayed choices before
applying. Used identities have a read-only map.

Apple Maps tile loading, failures and slow responses have explicit status text;
local catalog search and coordinate entry remain available offline. No
`CLLocationManager`, physical-location permission, online geocoder or proxy
request is added. Map tile traffic belongs to the SocialBox launcher, and is not
evidence of a clone's proxy routing or network isolation.

## Model recommendation

The model picker compares catalog dimensions with the launcher's actual
`UIScreen` native pixel bounds, logical bounds, display scale and native scale,
normalizing orientation. Exact geometry matches are grouped first; if there
are none, the closest entries are explicitly marked **not an exact match**.
Missing, malformed or nonfinite metrics never produce a verified match.

The catalog currently starts at iPhone 13; an iPhone X therefore has no exact
screen geometry candidate. No older device specifications are invented. Sorting
never selects a model or changes an existing identity. Explicitly choosing a
different model still uses the existing compatible-iOS selection and draft
generation path. Default automatic creation is unchanged.

Screen similarity does not replace the physical GPU, renderer, scene geometry,
refresh rate, kernel or other shared hardware properties. The existing OS-066
gap remains open; this feature does not claim indistinguishable hardware.

## Verification

- `bash tools/test_location_screen.sh`: 48 native assertions covering coordinate
  parsing/bounds, country/proxy mismatch, first-use lock, logical/native geometry,
  scale, orientation, malformed catalog values and preserved selection.
  A failing-first boundary regression demonstrated that rounding a typed
  longitude to six decimals could change the daemon's city-radius verdict;
  preview now validates exactly the serialized value that Save will receive.
- `python3 tools/test_identity_editor.py`: existing architecture checks pass.
- `python3 tools/static_check.py`: source/framework integration passes.
- `tools/test_identity_editor_simulator.py`: **233 assertions PASS**, including
  the previous 198 identity-editor assertions. Actual UIKit editor and MapKit
  interaction; inert IPC/private drafts. Service failure/readiness callbacks
  are injected independently of the natural native-map screenshot. Results are
  recorded in the generated `identity-result.json` artifact.

Final local evidence: `/tmp/socialbox-map-editor-verified/identity-result.json`,
`05-location-map.png`, `05b-location-tile-failure.png`, and
`06-location-proxy-mismatch.png` in that directory. The three map screenshots
were visually inspected at the fixture's 375 × 667-point screen size: dark
navigation, map, service state, primary action and proxy-route explanation fit.

The native map was visibly rendered in the simulator. Physical-device map
loading, saved clone-location values and cross-container/network acceptance
remain separate device tests. No hook, entitlement or backend admission changes
are included in this unit.

## Small-screen keyboard regression

An opt-in actual software-keyboard run reproduced a layout failure on the
375 × 667-point simulator: the fixed stack collapsed the map and truncated the
proxy-routing explanation. The failing-first fixture reported 238 checks with
one truncation failure. The map form now scrolls above the keyboard and retains
its map and full explanation instead of compressing them.

`tools/test_identity_editor_simulator.py --keyboard` now passes **240 assertions**
(the same 233 editor cases plus seven keyboard assertions). It requires a real
software-keyboard notification and visible keyboard layout guide, checks input
visibility, full text height, non-overlapping controls, retained map geometry and
scrolling the draft action above the keyboard. Ordinary headless runs retain the
233-case suite; they do not claim keyboard coverage. The runner does not change
host keyboard preferences.

Final evidence is `/tmp/socialbox-map-keyboard-final/identity-result.json` and
`05a-location-system-keyboard.png` in that directory. The latter is a `simctl`
whole-screen capture including the system keyboard, not a rendered app-window
snapshot. It and the normal `05-location-map.png` were visually inspected. The
originally absent Simulator hardware-keyboard preference was restored after
this opt-in run. Physical-device keyboard and clone acceptance remain separate.

The final and failing-first keyboard artifacts are retained outside the Git repo
in workspace `work/private-device/license-gate-2026-09-20/map-keyboard/`;
`before-identity-result.json` and `before-05a-location-system-keyboard.png`
record the reproduced pre-fix truncation.
