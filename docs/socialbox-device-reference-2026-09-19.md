# Doritoz device reference — 19 September 2026

This is an implementation reference for the ongoing SocialBox work, not an isolation certification or a change to SocialBox's network admission policy. The operator authorized inspection of their installed reference app. Installed code, process metadata and configuration schemas were read; no container was created, switched or deleted, and no VPN was started. Account databases, session tokens, Keychain contents and license secrets were not collected.

## Evidence scope

The connected reference device is an iPhone X (`iPhone10,6`) running iOS 16.7.16 with a rootless jailbreak. This is a different device from the earlier iPhone 8 SocialBox acceptance target. The installed package is `com.socialbox` version `3.1.0-1`; its app is `com.socialbox.app`, version 3.1.0/build 1.

SSH password authentication and a privileged read-only inspection succeeded. Apple's locally bundled developer disk image was mounted for screen capture. Initial DVT captures were black. After the operator opened the app, a subsequent capture showed its Home screen; observations are recorded below. Earlier video observations remain in [reference-workflows-2026-09.md](reference-workflows-2026-09.md).

Private evidence is outside the Git repository in the workspace's `work/private-device/doritoz-reference-2026-09-19/` directory. It contains a file/hash manifest, installed executable copies, selected manifests, sanitized configuration key/type information and static-analysis results. Proprietary executables, assets, disassembly and device credentials are not committed here.

Thirty actual package files were collected, including fifteen Mach-O components. Two additional legacy FilesProvider paths listed by the package database were absent; collection continued with the actual files. This observation alone does not establish a broken installation.

Static analysis selected the actual arm64 slices, extracted their entitlements, decoded Objective-C relative method lists and selector stubs, and bounded method bodies using `LC_FUNCTION_STARTS`. Compiler-generated callback blocks were followed separately where described below. Symbols and entitlements indicate intent; neither proves successful runtime enforcement.

Reproducibility hashes (SHA-256 of the extracted arm64 slices):

- SocialBox: `8c878af640286602e4e44973c46cced74db5a7f5ffc674b049aa2d09e580a9d9`
- SocialBoxHelper: `a0455fd7aeb19712d7ebf147fe773788981204710cd2bfa6f5b087191d0888d2`
- SocialBoxPacketTunnel: `dadff71b596db02306e76970ff11bc9ac304af45ea001bcf5960986dd0f44187`

Addresses below are preferred arm64 virtual addresses before ASLR, not live process addresses.

## Components and privilege boundaries

The fifteen components are SocialBox, SocialBoxCLI, SocialBoxHelper, secretsauced, secretsaucemonitor, two extensions (FilesProvider and PacketTunnel), and eight injected libraries: SocialBox, SocialBoxAccountsd, SocialBoxCfPrefsd, SocialBoxContainermanagerd, SocialBoxLsd, SocialBoxMediaServerd, SocialBoxSecurityd and SocialBoxSpringBoard.

The app, helper and both background services were observed running as root. The app and CLI executable files have setuid/setgid root mode. Helper/service manifests declare persistent launchd services and XPC endpoints. Their code signatures include broad private privileges; these are not a portable security design or proof that every entitlement is honored.

The main tweak's filter includes original Facebook, Reddit and Instagram bundle identifiers. Other filters target system brokers including cfprefsd, securityd, containermanagerd, lsd, accountsd, mediaserverd, SpringBoard and runningboardd. This is substantially wider than injecting only into an app. Filter declarations do not establish that each library was loaded or that each hook provides correct isolation.

## Original-app container switching

There is concrete code supporting an original-app data-switching architecture. The method `_performPerAppSwitchForBundleID:fromContainer:toContainer:processedGroupIDs:skipKill:skipCacheFlush:skipKeychain:skipChown:` starts at `0x100232630` in SocialBox. Its body:

- Requests `killApp:reply:` at `0x100232880`.
- Waits on a semaphore at `0x1002328a8`.
- Resolves the original application's proxy and `dataContainerURL` at `0x1002328dc` and `0x1002328ec`.
- Calls privileged cleanup/ownership helpers, updates per-app metadata and invokes rename, unlink, symlink and permission operations. Examples are rename at `0x100233658` and symlink at `0x100233998`.
- Calls the cache-flush path.

The helper's `atomicBatchSwapContents:reply:` method starts at `0x1000545cc` and dispatches a captured block starting at `0x1000546c8`. That block contains rename calls at `0x10005493c` and `0x100054a90`. The method name does not prove crash-safe atomicity of the entire operation.

These paths support the inference that at least one mode keeps the original app identity/entry point while replacing or redirecting the selected data context. They are not evidence that all modes work this way, or that Keychain, shared groups and broker caches switch consistently. No live A/B switch was performed.

Two details prevent treating this as an implementation to copy without verification:

1. At the semaphore site above, the timeout is five seconds and the return value is not tested before the next sleep/processing instructions. Callback and upstream checks may affect the outcome; this is a static failure-handling concern, **not a reproduced leak**. SocialBox must independently prove process termination before a data-context change.
2. The older helper method `switchToContainer:forBundleID:reply:` at `0x100055c34` constructs an error with code 501 and the literal “Not implemented (Phase 2)”, then invokes its callback with failure. This particular handler is a stub. It does not establish that the separate app-driven switching path is broken.

## Network path and the no-MDM question

The installed PacketTunnel extension has the packet-tunnel extension point, `SocialBoxPacketTunnelProvider` principal class and `packet-tunnel-provider` entitlement. The app references `NETunnelProviderManager`; both share `group.com.socialbox`. The provider contains lwIP/SOCKS client and local HTTP CONNECT listener implementation references.

The direct `startTunnelWithOptions:completionHandler:` body starts at `0x10002cc1c`. It reads configuration from the shared app group, starts the local proxy listener, builds IPv4 tunnel settings, creates a default included route (`0x10002f5f4`), adds excluded routes (`setExcludedRoutes:` at `0x10002f930`), configures DNS and HTTP/HTTPS proxy settings, and calls `setTunnelNetworkSettings:completionHandler:` at `0x10002fde0`.

This is evidence of a packet-tunnel design worth investigating for SocialBox's no-MDM requirement. It is **not** evidence that SocialBox enforces a per-app, fail-closed tunnel without MDM, or that SocialBox's existing app-proxy implementation can use this route unchanged. The distinction between whole-device routing and app-specific enforcement remains unresolved.

No IPv6-setting call was found in the inspected direct startup body. No `includeAllNetworks` selector was found in the scanned app selector references. Dynamic resolution and other paths have not been ruled out. These are verification gaps, not a finding of an actual IPv6 leak. No active SocialBox tunnel process was observed during this inspection, and traffic was not captured.

## Persisted configuration

Observed storage includes `/var/jb/var/mobile/Library/SocialBox/Containers`, `Backups`, and `.daemon_relay`, plus `/var/jb/var/mobile/Library/___SocialBox_Containers/1/`. Compatibility/default directories also exist under `/var/mobile/Library/`; the two path families must not be assumed equivalent without resolution evidence.

The inspected configuration's enabled/disabled app arrays were empty. Only a loader-app metadata entry was visible in the inspected per-app container store; prepared Facebook A/B contexts were not established. No wider claim about all possible storage locations is made.

The identity cache has 72 fields, including model, system version, locale, timezone, carrier and identifier-related values. Only field names/types were retained in the sanitized schema. Seventy-two fields do not mean seventy-two independently verified spoofed identifiers. Hash comparison showed the inspected configuration and identity cache were unchanged across the inspection; this does not claim that every file on the live phone remained unchanged.

## Decisions for SocialBox

- Keep the user's desired flow: select a stored context, then open one ordinary app entry point. The reference confirms a technically different implementation family from SocialBox's current separate signed sandboxes. Replacing that architecture requires its own transaction, crash recovery and isolation tests.
- Retain SocialBox's current blocked network admission when enforcement is unproven. A packet-tunnel prototype must measure IPv4, IPv6, DNS, UDP/QUIC, route exclusions, provider death, proxy loss, network changes and reboot before it can replace the existing MDM requirement.
- Require verified app/extension termination, journaled switching, Keychain/shared-group isolation and broker-cache handling. Presence of root helpers or many identity fields is not evidence of those properties.
- Preserve the existing Reddit regression contract. No executable SocialBox source, entitlements, hooks or network admission settings were changed by this reference inspection.

## Observed Home screen after unlocking

The private `doritoz-open.png` capture is an actual 1125-by-2436 device screenshot, not a mockup. It contains displayed identity values and is not committed.

- A dark gradient background, rounded translucent cards, large text and orange accents establish the visual hierarchy. The header has a menu and settings shortcut.
- A prominent “Spoofing Status / ENABLED” card has a green switch. This is a UI state, not evidence that isolation or network enforcement passed.
- “New Container” and “Configure” are the two large primary shortcuts.
- Identity fields appear in a two-column grid with occasional full-width rows, grouped under “Device Identity” and “Network & Cellular”. Displayed model/system/identifier values are claims shown by the app, not measurements from a target app.
- The persistent bottom navigation has Home, Containers, LocSim, Proxy and Settings. In this captured scroll position the lower identity cards remain visible beneath the dark translucent navigation; the full scroll/inset behavior has not been tested.

This confirms the desired visual direction from the videos on the installed version: separate destinations, clear creation/configuration shortcuts and a readable summary. SocialBox should use its own assets and labels, preserve its readiness explanations, and reserve technical identity fields for the review/details flow. The reference's enabled switch must not replace proven admission checks.

The accessibility inspector enumerated status-bar elements but did not expose SocialBox's app controls in this attempt. No blind activation or settings change was attempted. Additional screen captures require operator navigation until a reliable control path is established.

## Observed Containers screen

After the operator navigated to Containers, the private `doritoz-containers.png` screenshot shows a search field for containers/folders, a sort control, an upper-left tray/down-arrow action and an upper-right “Select” action. Their behavior has not been exercised.

A “Current Session” card names the selected container and marks it ACTIVE. Below it, the same container appears again under “Ungrouped — 1”, with a green check, green title, truncated seed, date, one app icon and an “Empty” label. Only one row is visible; this is not evidence of a successful switch or a populated account. The persistent bottom navigation remains visible with Containers highlighted.

For SocialBox, the useful pattern is a searchable list with an unmistakable selected state and per-container actions. Repeating the selected item in a separate large card is optional; technical seed values belong in Details. The reference binary includes `_buildContextMenuConfigForContainer:` at `0x10010bdf8` and table/context-menu handlers, but the actual menu options have not yet been visually observed.

## Verification status

- **PASS:** SSH access; installed component/version inventory; arm64 method and entitlement extraction; unchanged inspected configuration/cache hashes; Home and Containers screen captures after operator navigation.
- **NOT_RUN:** other current UI screens and interactive flows, including the container menu; live A/B switching, cross-context canaries, Keychain/shared-group isolation, crash recovery, actual VPN/proxy behavior, packet capture, 40-context acceptance and preserved account login.
- **UNRESOLVED:** timeout handling in the identified switching path; IPv6 and tunnel-failure coverage; active use of each broker hook; which switching mode the current UI invokes.

No “all clear” or 100% isolation conclusion follows from this inspection. These observations are design inputs for the existing isolation register, not new PASS verdicts in `LEAK_SURFACE.md`.

Repository validation for this documentation-only unit: `python3 tools/static_check.py` reported ALL CLEAN; `bash tools/test_launch_safety.sh` passed the native admission/setup checks; `bash tools/test_firewall_policy.sh` passed the native firewall and local DNS checks. These checks cover existing SocialBox behavior, not the reference application's runtime safety. No package was built or installed for this unit.
