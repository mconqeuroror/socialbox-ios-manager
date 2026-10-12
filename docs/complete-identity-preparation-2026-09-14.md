# Complete automatic identity preparation — 0.1.21

Automatic fill now carries the entire currently generated Reddit identity through private draft → manual review → Check → Save. It previously generated more values than the editor returned: logic-board serial, ECID, boot epoch/initial uptime, installation timestamp and exact coordinates could be lost or replaced by saved values during manual candidate construction. The failing-first test reproduced differences in five complete sections before the fix.

## Field contract

[The mechanical field inventory](complete-identity-fields-2026-09-14.json) enumerates 75 generated leaf values: 27 device fields, 8 serial/chip fields, 3 advertising/vendor fields, 3 timing fields, 7 Reddit fields and 27 canonical MobileGestalt aliases. There are 48 primary values; aliases do not constitute 27 additional independent identifiers.

Automatic fill supplies every supported primary value. Model-linked RAM, GPU, display dimensions/scale/rate, hardware board, regulatory model, iOS build and Darwin version remain derived from a coherent catalog tuple. The new hardware/software section shows those dependencies and updates with edits. MLB, ECID, installation/boot times and both coordinates are now visible and editable, with explanations. City selection and proxy-region suggestions update the coordinate pair and timezone together.

The user's current compatibility switches, proxy credentials/assignment, license, app ownership and metadata are preserved. Automatic identity generation is not authorization to enable real attestation, sensors or shared clipboard access. Sentinel settings and external MDM provisioning are separate from generated identity values. The existing pre-use identity freeze remains enforced.

Explicit invalid added fields fail input validation, including malformed unsigned ECID/overflow, future or invalid timestamps, partial coordinates and coordinates outside the selected catalog city's bounded area. Omitted fields from older partial API callers retain saved semantics. The complete editor sends all its reviewed fields without generating another identity during Save.

Generic catalog templates intentionally have no IMEI or retail SKU where the catalog has no supported value. Denied ATT intentionally reports zero IDFA. Those are explicit policies, not missing automatic-generation work. This change does not invent extra modem/SIM identifiers, new hooks or Facebook SDK identities to inflate the count. Proxy country is a live IP-geolocation observation; carrier, locale and catalog coordinates are suggestions, not measurements of a SIM or GPS receiver.

## Validation

- `6452843`: implementation and tests. `3175fdc`: inventory contract and moved evidence anchors; `Leak-Surface: EDIT-012`.
- Failing-first actual generator/registry fixture: 48 checks, 5 section-equality failures before the fix.
- Final actual generator/registry fixture: 180 checks, zero failures. It compares every field in all six generated sections, proves repeated candidate construction retains exact values, and round-trips every catalog model through JSON/manual review.
- Actual manual-input/candidate fixture: 497 checks, zero failures, including exact maximum unsigned 64-bit ECID and invalid input refusal.
- Actual UIKit editor fixture: 159 checks, zero failures, using inert IPC/private-storage providers. It tests automatic display, manual edit, Check/Save payload equality, derived display and city-coordinate updates.
- All 92 host/native build entrypoints passed. Local runs initially needed the configured libarchive include path and OpenSSL 3; these were environment failures, not suppressed tests. The complete rootless build used the corrected existing build environment and passed all 92 again.

Device installation/readback and package hashes are recorded separately in the accompanying versioned evidence. Earlier 0.1.20 checks only established the fields returned by its editor; they did not establish this full 75-value round-trip. Physical editor taps, clone launch, Facebook support, network/MDM acceptance and 100% isolation are not implied by these tests.


## Actual phone result

Both complete 0.1.21 ldid builds passed all 92 entrypoints. [Both package inspections](automatic-identity-packages-0.1.21.json) check seven Mach-O components/twelve slices per variant, unchanged entitlements and the existing deployment license public key. Rootless is installed; rootful is built/inspected only. Neither is published to production APT/Vercel.

[Device acceptance](complete-identity-device-acceptance-0.1.21.json) passed all 30 checks through the shipped daemon on the connected rootless iPhone. Auto → explicit manual preview → Save → persisted readback includes all newly exposed fields. The original user profile remained byte-identical. The test identity remains unused. Across 930 observations: no safe-mode marker, SpringBoard identity change, stale CLOSED heartbeat or read error; maximum observed CLOSED heartbeat age was 1.078 seconds. Sampling does not exclude every transient event. No network OPEN, clone launch or physical editor taps were performed.
