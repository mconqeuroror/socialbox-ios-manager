# Shared app entry — 0.1.26 implementation and acceptance

This is a **partial implementation**, not a declaration that the complete forty-container Facebook plan is ready. Both local packages built successfully; rootless 0.1.26 is installed on the attached iPhone. Neither package was published to production APT. The branch remains unmerged.

## Implemented

- One separate `Facebook · SocialBox` application (`com.socialbox.facebook.entry`). It opens the exact `socialbox://open/facebook` URL and carries no container ID, private Keychain group or network capability. The main launcher retains passcode/license checks; the daemon resolves the current selection. The original App Store Facebook and its data are retained. Use the SocialBox-labelled icon for this workflow; the original icon continues to mean the original application.
- Daemon-owned, durable selection, without a three-container limit or first-row fallback. It publishes `switching`, closes traffic, stops all runnable app families, verifies closure/socket drain, revalidates ownership and commits `selected`. Failed/interrupted selection cannot silently choose the old account. Selection never regenerates identity and never grants a network lease.
- Home and container cards show the daemon-confirmed selection, with original local phone artwork. Existing searchable lists, five navigation tabs, Cloud, licensing and advanced identity editing remain available.
- Fixed the legacy cloud assignment-revocation method: CLOSED and all-app process/socket quiescence precede profile mutation. Failed closure or persistence fences recovery. This previously Reddit-only method is not newly activated or scheduled by this change; this is a regression-tested latent path repair, not a reproduced live Facebook traffic leak.
- Mechanical source enumeration now includes the new entry application.

## Checks actually completed

Machine-readable evidence, package hashes and the full build-test list are in [workspace-0.1.26.json](release-evidence/workspace-0.1.26.json).

- **PASS:** full rootless and rootful `scripts/build-mac.sh`, 116 test entrypoints each, plus static checks. Existing Reddit tests, native launch/recovery, identity, proxy, Keychain, backup, queue and firewall-policy regressions remain green.
- **PASS:** 210 transition assertions; 177 assertions executing the actual daemon selection/dispatch; 492 existing multi-app launch assertions. Forty synthetic targets do not mean forty installed clones.
- **PASS:** 155 actual UIKit checks, including fifty synthetic rows, forty selections, pending-switch rejection, exact deep-link validation, inactive-Facebook denial and missing-network-setup denial. IPC and data are inert fixtures.
- **PASS:** 18 failing-first cloud-revocation assertions, including closure and profile-write failures.
- **PASS:** eight Mach-O components and fourteen architecture slices in each package. Independent checks recomputed 1,380 CodeDirectory page hashes per variant. Existing twelve entitlement payloads match the previous package; the two new entry slices contain only their own application identifier. The existing licensing public-key pin is unchanged. This is not Apple certificate trust or MDM installation acceptance.
- **PASS:** upgrade on iPhone10,4 / iOS 16.7.16 from 0.1.25 to 0.1.26. Both existing container IDs and all six files in their profile directory were byte-identical after upgrade. License remained unlocked, network CLOSED. LaunchServices lists the new shared entry and the original Facebook separately.
- **PASS:** forty serialized offline daemon selections on the physical iPhone, alternating between its two existing Reddit containers. Each confirmed publication matched the request, traffic remained CLOSED, and all six profile-directory files remained byte-identical. No containers were created and no account was opened. This is not a forty-Facebook-container acceptance run.
- **NOT_RUN:** visual SpringBoard confirmation. `idevicescreenshot` could not connect to screenshotr. App registration and the existing hidden-clone metadata are insufficient visual evidence.
- **NOT_RUN:** successful physical common-icon → selected Facebook clone workflow. Remote `uiopen` did not establish entry/launcher process execution; an unlocked foreground phone is needed to continue this observation. Facebook remains inactive under the existing admission contract.

The local `workspace-40-ui-demo.mp4` is an actual 27.67-second Simulator recording labelled **SIMULATOR / SYNTHETIC DATA / NETWORK BLOCKED**. It demonstrates the tested UI and its blocked states, not a successful Facebook login or physical isolation.

## Network feasibility on this phone

Read-only inspection found about 40.9 GiB free, both decrypted sources available (Reddit 2026.36.0 / 664762; Facebook 578.1.0 / 1063022819), `firewallScope=none`, and `firewallSetup.ready=false`. The operator has no MDM service configured. The presence of `/dev/pf` alone does not establish usable per-app enforcement. No new firewall bypass, supervision flag change, phone wipe or network OPEN was performed.

Apple documents per-app mapping through managed apps and supports VPN payloads with User Enrollment, Device Enrollment and Automated Device Enrollment. Thus **MDM does not universally imply wiping the device**. Those platform capabilities do not prove that a service can adopt this project's exact ldid/AppSync clone artifacts on this jailbreak. That adoption, provider startup, exact bundle mapping and captured traffic failure tests still need evidence. Sources: [Apple VPN enrollment support](https://support.apple.com/en-gb/guide/deployment/-dep2d2adb35d/web), [managed-app attributes and consent](https://support.apple.com/en-gb/guide/deployment/dep575bfed86/1/web/1.0). Configurator preparation/supervision was not run.

## Work still required by the approved plan

1. **Implement true draft-before-create.** The current simple Reddit form submits creation directly; the legacy wizard provisions before review. Neither is the requested name → proxy → complete editable draft → review → explicit commit transaction. This work was not hidden behind the MDM blocker or marked complete. It needs daemon-owned draft expiry/cancellation, exact reviewed-value commit, collision/capacity handling and real UI tests. Existing used identities must retain their freeze rules.
2. **Implement per-container saved-proxy binding.** A selected device proxy and a cloud per-profile assignment currently have different authorities. A new selector must not silently bypass cloud ownership, revocation, license or gate checks. Proxy mutation during draft/commit/launch, deletion, restore and server reassignment require regression coverage before that change is shipped.
3. **Finish Facebook admission and managed-network acceptance.** Do not flip the descriptor to runnable merely to make the new icon appear functional. H08 and the Facebook runtime/lifecycle acceptance remain open.
4. **Execute forty-container CRUD and capacity failure testing.** Existing individual lifecycle regressions and forty selection fixtures are not a forty-container create/edit/delete/install/restore battery. The physical forty-Facebook-container run, per-container canaries, proxy outage/network change/reboot packet captures and successful phone recording are **NOT_RUN**.

## Isolation claims remain separated

- **Foreign data:** separate clone sandboxes and hook/entitlement boundaries need live sibling Keychain, filesystem, defaults, cookie/WebKit and pasteboard evidence. UI selection success is not that evidence.
- **Direct network traffic:** protocol/lease policy fixtures do not prove packet enforcement on this phone. No MDM/provider proof means network launch stays blocked.
- **Account correlation:** shared physical signals, server history, login details and behavior are a different problem from cross-container file access. No claim that Facebook can never link accounts is made.

The current [isolation register](../LEAK_SURFACE.md) has 369 rows: 172 covered in code, 28 gaps and 169 unverified. These counts are deliberately not converted into a “100% isolated” label.

## Commits

- `8030db7`: durable selection, shared entry application, local artwork and initial regressions.
- `f5239ce`: global cloud assignment-revocation closure and entry source enumeration.
- `e6a81b6`: forty UIKit selections and exact shared-entry admission tests.

All three were pushed to `feat/socialbox-multiapp`; no merge or production APT promotion was performed.
