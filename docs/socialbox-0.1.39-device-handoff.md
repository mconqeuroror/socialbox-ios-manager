# SocialBox 0.1.39 — candidate handoff, 20 September 2026

**Both 0.1.39 packages passed the complete build and package inspection.
The rootless candidate is installed on the connected iPhone X.**
This is not acceptance for normal online container use. The last physical
observations still require an unlocked phone, working Internet/DNS and a valid
SocialBox license. The no-MDM network backend and Facebook runtime acceptance
remain unresolved.

## Delivered changes

Separate commits on `feat/socialbox-multiapp` retain the existing app,
license infrastructure and isolation admission rules. The branch remains
unmerged.

- `e6b0c46` — put the entire launcher behind a fresh license gate. An unlicensed
  launch shows only SocialBox, the secure license-key field, Activate and status.
  Revocation removes all app workspaces, tabs and presented sheets. A background
  cover hides private content until foreground license state is checked again.
  Deep links cannot bypass the gate; the separate launcher passcode still
  applies after licensing. The licensed Account screen observes the complete
  fresh daemon publication. Existing secure key storage, signer and device-wide
  activation requests are preserved.
- `aa56289` — add a map for reviewing a location draft and screen-aware device
  model choices. Coordinate validation and explicit draft acceptance remain
  required. Choosing a map location is not evidence of proxy geography or a
  global location simulation.
- `c47e68e` — add an **offline experimental** PF policy/transaction model. It is
  absent from shipping targets, performs no kernel/network changes and always
  reports application admission as false. Immutable policy digests and a
  mutation-fence contract address the independently reviewed mutable-digest and
  delayed-write recovery problems. A real adapter is still required.
- `e269329` — fix a reproduced small-screen keyboard layout defect. The map
  form now scrolls instead of collapsing the map and truncating its explanation.
  Software-keyboard regression assertions and an actual simulator screenshot
  verify the input, map, full explanation and reachable draft action.
- `034e294` — update the 382-row isolation register and 386-file source
  inventory. Existing gaps remain open; launcher MapKit traffic is explicitly
  distinguished from a clone's proxy route.

The earlier UI and source-import baseline is recorded in
[the 0.1.38 handoff](socialbox-0.1.38-device-handoff.md). Screenshot feature
decisions remain in [the reference redesign](socialbox-reference-redesign.md).

## Build and automated verification

**PASS — focused native and UIKit checks:**

- License gate: 49 actual UIKit assertions with synthetic publication and inert
  IPC; activation and local publication: 33 native assertions plus privacy and
  wiring contracts.
- Full workspace: 240 actual UIKit assertions with synthetic state and inert IPC.
- Location/model editor: 233 normal actual UIKit assertions, extended to
  **240 PASS** with seven real software-keyboard checks; 48 native location and
  screen-geometry assertions. The pre-fix keyboard fixture failed one of 238
  checks because the routing explanation was truncated. The final evidence is
  retained privately at `private-device/license-gate-2026-09-20/map-keyboard/`
  in the task workspace; `05a-location-system-keyboard.png` includes the actual
  system keyboard. The opt-in runner fails when no software keyboard appears.
- Experimental PF policy/transaction model: 596 native assertions under
  ASan/UBSan. Both independent review findings received regressions and fixes.
  These results establish model behavior, not loaded kernel policy or network
  enforcement. See [the module's contract and limitations](../experimental/pf/README.md).

**PASS — complete package builds.** Both `scripts/build-mac.sh` runs completed
with Procursus ldid and no Apple Development Team. Each ran 136 named test
entrypoints, including existing Reddit, lifecycle, proxy, license, Cloud,
Keychain, storage and recovery regressions. The separate static check passed.
The [sanitized receipt](release-evidence/socialbox-0.1.39-device-handoff.json)
contains the exact entrypoint list and completed build-log hashes. The generated
public license pin is byte-identical to the existing saved pin. The map source
hash is unchanged between the build start and final source commit.

Validated packages:

- `com.redditbox_0.1.39_iphoneos-arm64.deb`: SHA-256
  `eb65889e8435116ade435e5f8eb4c7a5a1b40a743faad66d364e4317ae00f93e`.
- `com.redditbox_0.1.39_iphoneos-arm.deb`: SHA-256
  `b4e99966c7ef48b35a9671c5b2350d1be09fcb008e8251abe9b2bf793d00c66f`.

Both passed the existing release package inspector: architecture/version,
stable bundle identities, reviewed maintainer scripts, allowed payload paths
and absence of private IPAs/keys/user configuration. The experimental PF module
is not linked into any installed target.

These are local candidates. This pass did not publish 0.1.39 to production APT
or redeploy Vercel. The installed candidate retains the current backend's MDM
re-adoption requirement.

## Physical device evidence

**PASS — installation and safe startup.** Connected iPhone X (`iPhone10,6`),
iOS 16.7.16, palera1n rootless: package manager upgraded 0.1.38 to 0.1.39 and
returned zero; `dpkg -s` reports `install ok installed`. Fourteen installed
payload files match the package by SHA-256. The fresh daemon runs as root,
startup recovery completed, no operation recovery remains, no container is
selected and the network is `closed` with firewall scope `none`.

**PASS — source preservation.** Reddit 2026.36.0 and Facebook 578.1.0 remain
decrypted private-cache sources. Each source's main executable and Info.plist
hash is unchanged across the upgrade. No original app, reference-product data,
license key or cloud signer was replaced. Temporary diagnostic helpers and
remote diagnostic files were removed; the candidate .deb remains on the phone.

The latest blockers carried into this handoff are:

- After installation a read-only lock probe still reported locked and correctly
  skipped the requested own-app launch. No unlock API was used. The physical
  launcher display is **NOT_RUN**; this is not evidence of a crash or signing
  failure. Rootful physical installation is also **NOT_RUN**.
- DNS lookup for the existing licensing host failed; the actual proxy test
  reported offline. Working phone connectivity and proxy health need fresh
  checks. No direct-network fallback was introduced.
- This phone has no valid SocialBox license activation or signed offline
  entitlement. Its configured production origin is retained. The user's
  existing SocialBox key is required; no replacement signing key or license was
  generated for this change.

The physical activation screen, keyboard behavior, location editor, container
flow, real account login and cross-phone Cloud restore remain **NOT_RUN** for
0.1.39. No forty-container physical run, packet-capture battery or online
handoff/reboot acceptance is implied by the automated results.

## Why online use is still blocked

1. **Device prerequisites:** unlock the phone, restore working Internet/DNS and
   activate it with the existing SocialBox license before testing proxy health
   and the licensed workspace.
2. **Network implementation:** the shipping app-proxy provider still requires
   managed per-app VPN/MDM, which the user does not have. The offline PF model
   supplies neither a kernel adapter nor independent expiry enforcement. Real
   policy ownership, fenced commits, state purging, safe recovery and measured
   traffic remain prerequisites; no readiness gate is overridden. See the
   [no-MDM assessment](no-mdm-network-feasibility-2026-09-20.md).
3. **Facebook acceptance:** Facebook remains inactive. Having an imported
   decrypted IPA does not close the in-process storage/identifier acceptance
   gaps in [the device audit](facebook-clone-device-acceptance.md) and
   [the isolation register](../LEAK_SURFACE.md).

After these prerequisites are met, verify one container with actual in-clone
A/B probes and traffic measurement before scaling to forty. Account logins
remain with the user. Cross-container data isolation, direct network escape and
server-side account correlation are separate claims; a green build proves none
of them by itself.
