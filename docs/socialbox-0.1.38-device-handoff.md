# SocialBox 0.1.38 — installed candidate, 20 September 2026

**The candidate is installed on the connected iPhone X. It is not accepted for
normal online container use.** Local builds, UI regressions, actual installation,
source import and safe startup passed. Activation, Internet connectivity,
MDM-free enforcement and Facebook acceptance remain unresolved. Do not interpret
the successful installation as proof of complete isolation.

## Delivered changes

The existing dark Home / Containers / Location / Proxies / Settings flow now has
an original amber SocialBox icon. The screenshot-by-screenshot feature mapping
and explicit deferred features are in [the reference redesign](socialbox-reference-redesign.md).
The new icon does not change the launcher bundle identity or create an extra
Facebook entry application.

Five separate commits were pushed to `feat/socialbox-multiapp`, without merging:

- `c985cff`: recover unsent creation drafts, bind proxy preparation to an explicit
  successful selection, and reject a stale selected-proxy revision before any
  geographic lookup.
- `e5a0b98`: route unfinished operations to recovery, show the exact blocked-Open
  reason, open the correct license screen, and reject stale Cloud-key copy callbacks.
- `6aa74e2`: reject nonfinite current time, heartbeat or expiry in firewall leases.
- `533e758`: package the original SocialBox icon at all six declared sizes.
- `d3582ef`: keep unfinished replacements and isolation alerts visible across
  advanced role filters.

Detailed failing-first evidence is in [the launcher audit](socialbox-ui-action-audit-2026-09-20.md).
The subsequent evidence/tooling commits do not change the binaries built from
`d3582ef`.

## Build and automated verification — PASS

Both complete `scripts/build-mac.sh` runs passed: rootless and rootful 0.1.38,
Procursus ldid signing, no Apple Development Team. Each run executes 134 named
test entrypoints plus `tools/static_check.py`. The exact entrypoint list and
build-log hashes are retained in the [sanitized receipt](release-evidence/socialbox-0.1.38-device-handoff.json).
They include the existing Reddit payload, proxy transport, registry, lifecycle,
storage, Keychain, sentinel, license, Cloud, backup, replacement and upgrade
regressions; no test failure was waived to produce the packages.

Additional native UI and targeted checks passed:

- Workspace UIKit fixture: 239 checks, synthetic profiles and inert IPC.
- Creation wizard UIKit fixture: 53 checks.
- Proxy import/selection UIKit fixture: 23 checks.
- Creation daemon dispatch: 251 checks, including stale proxy selection.
- Workspace selection: 210 checks, including 40 profiles and repeated switches.
- Advanced role predicate: 23 checks.
- Firewall malformed-time cases: seven added regression assertions, with the
  original firewall policy and DNS tests passing.
- Six icon sizes, opaque PNGs, launcher Info.plist, and both package layouts passed.
- The generated license public-key header is byte-identical to the existing
  public pin saved before this work. No license signing key was replaced.

The actual UIKit recording is retained outside Git at
`private-device/socialbox-ui-2026-09-20/ui-audit-verified.mp4` in the task workspace.
It demonstrates native UI behavior on an iOS simulator. It is **not** a physical
iPhone recording, real account login, or measured network-isolation result.

Built packages:

- Rootless `com.redditbox_0.1.38_iphoneos-arm64.deb`, SHA-256
  `407b4d9d1d454e2cf72c2bb8031fc2b14932109c9dda380696bf2e1917d50014`.
- Rootful `com.redditbox_0.1.38_iphoneos-arm.deb`, SHA-256
  `d5a70dbd0c5fd47e453c54c2438169c9d7c9294bec4dc38852ec4c480979e693`.

These are local candidates. This pass did not publish 0.1.38 to the production
APT repositories or redeploy Vercel. Existing web licensing and signing keys are
preserved. Both packages correctly retain the MDM re-adoption requirement of the
currently implemented network backend.

## Physical device evidence

Device: iPhone X (`iPhone10,6`), iOS 16.7.16, palera1n rootless. SSH worked over
the USB network link. Reference-product packages and their configuration were
left intact; their hooks are not counted as SocialBox protection.

**PASS — installation and safe startup.** Installed 0.1.37, then upgraded to the
final 0.1.38 rootless candidate using the package manager. The daemon runs as root.
Fourteen installed payload files, including seven Mach-O components, Info.plist
and all six icon renditions, match the final package by SHA-256. Startup recovery
completed, no unfinished operation fence remains, no container is active, and
the network state is `closed` with firewall scope `none`.

**PASS — required tools.** AppSync Unified 116.0 and appinst
2.1.1-redditbox2 were installed from the existing signed repository. InRelease
signature and dependency hashes were checked before installation. No broad
package upgrade or package removal was performed.

**PASS — source import and preservation.** Actual daemon requests imported both
decrypted IPAs into its private source stores, and both remain present after the
0.1.38 upgrade:

- Reddit 2026.36.0 (build 664762) in `Source/Reddit.app`.
- Facebook 578.1.0 (build 1063022819) in `SourceFacebook/Facebook.app`.

Both report `found=true`, `decrypted=true`, `location=private-cache`. The temporary
UUID import inboxes were consumed. Main executable cryptid checks and the
daemon's complete import validation passed. Private IPAs are not committed or
published. Importing Facebook does not mark its runtime audit as passed.

**PASS — configuration storage; FAIL — online proxy test.** The supplied HTTP
proxy was saved through SocialBox's secure configuration and proxy library.
Configuration-change IPC succeeded. The actual proxy test returned “The Internet
connection appears to be offline.” A read-only network snapshot found no
non-link-local uplink address and no IPv4 default route; only interface-scoped
IPv6 tunnel defaults were present. A separate lookup of the existing licensing
host failed DNS resolution. This does not establish that the supplied proxy
credentials are wrong. No direct-network fallback was used for proxy preparation.

**EXPECTED BLOCK — activation.** The existing production origin
`https://redditspoof.vercel.app` is configured. This new phone has no SocialBox
license activation or valid signed offline entitlement. A missing-key activation
request correctly failed. The user was asked for the existing SocialBox license
key; no replacement license or signing key was generated.

**NOT_RUN — physical launcher display and complete application acceptance.**
`uiopen` accepted the launch request, but a persistent foreground launcher and its
physical screen were not verified. A later, narrow SpringBoardServices probe
confirmed the current screen-lock state and correctly skipped launching our app
while locked. It never called an unlock API. This does not prove a signing
failure or a crash; those cannot be excluded until an unlocked launch is tested.
The device was not discoverable through the paired USB screenshot service. It is
therefore incorrect to claim the on-phone visual flow passed.
No forty-container physical run, real account login,
cross-phone Cloud restore, packet capture or online handoff/reboot battery ran.

## Why online use is still blocked

1. **Phone setup:** Internet access and the existing SocialBox license key are
   required before activation and proxy health can be checked.
2. **Network implementation:** the shipping app-proxy provider requires managed
   per-app VPN/MDM. The user has no MDM. Read-only PF capability and policy
   inspection passed on this kernel, but no alternative enforcement backend or
   independently measured egress protection has been installed. See the
   [no-MDM assessment](no-mdm-network-feasibility-2026-09-20.md). A successful PF
   query is not a reason to override launch readiness.
3. **Facebook acceptance:** Facebook remains inactive. Its imported IPA is now
   available, but existing in-process storage and identifier acceptance gaps
   remain recorded in [the device audit](facebook-clone-device-acceptance.md)
   and [the isolation register](../LEAK_SURFACE.md). UI tests and installation
   cannot close those gaps.

Next acceptance must establish a real no-MDM network backend (or use a valid
managed deployment), re-run actual in-clone A/B probes and measured traffic,
then test one container before scaling to forty. Account logins remain with the
user. Cross-container data isolation, direct network escape and server-side
account correlation are different claims; none is proved by a green build alone.
