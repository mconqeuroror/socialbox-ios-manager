# RedditBox

The [LEAK_SURFACE evidence contract](LEAK_SURFACE.md) records the current IPA,
surface inventory, known gaps and per-row verification requirements. Future
changes must reference affected row IDs in `Leak-Surface:` commit trailers.
Local build success does not establish complete on-device leak coverage.

## OS-isolated cloned profiles

Each profile is a separately registered app with a deterministic
`com.redditbox.profile.p…` bundle ID, a separate iOS data container, and a
separate `RBXCLONE00.<bundle-id>` keychain access group. Clone signatures carry
no shared App Group, iCloud, APNs, or associated-domain entitlement. App Attest
is absent by default and added only when that profile explicitly enables it.
Each clone also carries the signed `SBAppTags=hidden` and `RBXLauncherOnly`
markers. SpringBoard shows one **RedditBox** launcher; clone icons are hidden.

The tweak no longer installs path, keychain, UserDefaults/CFPreferences, cookie
archive, or request-log isolation. The iOS sandbox is the data boundary; hooks
remain for hardware identity, sensitive-service blocking, and defense-in-depth
proxy/socket enforcement.

After the `.deb` is installed, normal setup and operation require no SSH:
configure/test the proxy, pair cloud sync, check the Reddit source, create,
open/switch, export, refresh, diagnose, and delete containers in RedditBox.
The CLI remains an optional developer recovery path:

```sh
sudo redditbox-profile profile-01 US
```

The package declares `ldid`, `appinst`, `zip`, and AppSync Unified as
dependencies; their repositories must be available to the package manager. A
legally obtained decrypted Reddit IPA/source app is still required. An encrypted App Store binary
cannot be made cloneable by changing its signature; provisioning rejects it
before copying. Existing profiles migrate automatically when the updated daemon
starts. Swipe right on a launcher container and choose **Share IPA** to send the
exact signed clone to Files or MDM without SSH.

On a fresh install, open **Settings → Import Reddit IPA from Files**. The daemon
validates the decrypted source and stores it privately without installing a
visible Reddit app. VPN setup is deferred: settings, testing and profile
creation remain available before MDM deployment, while clone launches remain
blocked. Settings exposes the managed-deployment prerequisites and setup export.

Tap a container and choose **Identity & Cloaking** for its per-profile editor:

- **Coherent Random** regenerates every linked identity value as one valid set.
- **Advanced Manual** exposes geo, carrier, device name, IDFA posture, Reddit
  presentation, expert identifiers, timing offset, and compatibility policies.
- Device type and iOS use a validated synthetic catalog tuple, independent of the physical
  hardware/runtime; impossible claims are rejected rather than silently
  weakening isolation.
- The selected country must match the assigned or last-observed proxy country.
  The UI warns immediately and the daemon refuses the save on mismatch.
- Every proxy activation persists both the configured country and the country
  observed through the live exit. A provider returning the wrong country leaves
  Reddit blocked and shows the exact mismatch in the identity editor.
- Identity values freeze after first use to prevent observable fingerprint
  drift. Compatibility exceptions remain editable with an explicit warning.

After at least one profile is safely created or backed up, choose
**RedditBox → Settings → Hide source Reddit app**. The daemon first copies the
decrypted source to a root-only, unregistered source cache, then uninstalls the
visible original app (including its old data container). Future profile
creation uses the private cache. This explicit confirmation is what leaves
RedditBox as the only daily SpringBoard icon without silently deleting source
app data during an upgrade.

When the decrypted source Reddit version changes, clones are rebuilt
transactionally. That local `appinst` upgrade may clear managed-app state, so
each rebuilt clone remains blocked until MDM adopts the new installation again.

Thirty profiles are supported by lifecycle design: the daemon permits only one
clone process at a time, and bundle IDs are deterministic 64-bit profile
hashes. Every clone is installed as an IPA through `appinst`/`installd`, so
assume the app bundle is physically duplicated. For a 300–500 MB source plus
100–500 MB of warmed data per profile, budget roughly 12–30 GB for 30 profiles,
plus transaction headroom and 20% free space. Measure the actual Reddit release
with the guidance in `docs/on-device-smoke-checklist.md`.

## Single-link proxy rotation

`redditboxd` starts with Reddit traffic closed. On first launch, RedditBox shows
a skippable setup wizard for proxy URL, HTTPS rotation URL, authorization
header/value, GET/POST method, and the optional cloud access key. Values are
stored in a shared Keychain access
group available only to the signed launcher and daemon. **Save and test
connection** closes any current Reddit session, calls rotation once, validates
the proxy exit, and reports success/failure in the app.

When paired cloud sync has encrypted global rotation settings, refresh replaces
the local Keychain values and labels their source as `cloud`. Per-profile cloud
authorization overrides still take final precedence.

For developer recovery only, environment variables are supported:

- `RBX_PROXY_URL`
- `RBX_ROTATION_URL` (HTTPS is mandatory)
- `RBX_ROTATION_AUTHORIZATION` (optional complete Authorization header)
- `RBX_ROTATION_AUTH_HEADER` (optional header name; default `Authorization`)
- `RBX_ROTATION_METHOD` (`GET` or `POST`; default `POST`)

The root-owned `com.redditbox.rotation.plist` remains an optional fallback when
no Keychain configuration exists. Precedence is: per-profile cloud
authorization override → launcher/cloud Keychain configuration → development
environment/plist fallback. Values and credentials are never logged.

Profiles can override that header through the cloud console. Overrides are
AES-256-GCM encrypted with server-only `PROXY_SECRETS_KEY` and are returned
only to an authenticated device; absent overrides use the global value.

Every switch is serialized as: close the network lease, revoke the binding,
kill and verify all Reddit processes, wait for socket drain, call rotation,
validate a different proxy exit IP, open a generation-bound lease, then launch.
Any failed step leaves the lease closed.

## One-command Mac build

For complete ldid-only Mac setup, MDM association and traffic capture, follow the
[device acceptance runbook](docs/on-device-smoke-checklist.md). It identifies the
remaining H08 routing gap, blocked browser authentication and callback-ownership
issue; device acceptance is pending.

The release build includes the RedditBox UIKit launcher, tweak, daemon,
preferences bundle, and managed app-proxy firewall:

```sh
brew install xcodegen libarchive ldid-procursus
export THEOS="$HOME/theos"
bash scripts/build-mac.sh
```

The build compiles an unsigned Xcode archive, then signs nested code, the
provider and the host inside-out with Procursus ldid. `DEVELOPMENT_TEAM` is
optional and is not needed for this path. Use ldid with shallow bundle signing
(`-w`, Procursus 2.1.5-procursus7 or later); Homebrew provides
[ldid-procursus](https://formulae.brew.sh/formula/ldid-procursus).
The signer verifies embedded entitlements and bundle resource envelopes before
Theos packaging. It rejects a missing firewall app or unexpected extension.

Signing places the `app-proxy-provider` and `group.com.redditbox.firewall`
entitlements in the package. Whether the jailbreak permits those entitlements
and iOS starts the managed provider must be verified on the target device.
Compilation and signature inspection cannot establish that authorization.

After installation, open **RedditBox → Settings → Open firewall setup** once
after deploying the updated MDM app-proxy payload. The firewall host itself is hidden from SpringBoard, so
RedditBox remains the daily entry point. A
production deployment also needs a supervised MDM-managed per-app On Demand
VPN assigning every clone—and the original Reddit app for as long as it
remains registered—to the app proxy. Choose **RedditBox → Settings → Share
MDM/VPN setup** to export the `.mobileconfig` and stable-UUID assignment JSON
through the iOS share sheet. The Python generator remains a developer fallback.

The MDM server must attach the generated `VPNUUID` as a managed-app attribute.
This Apple-controlled step cannot be manufactured by Theos or `ldid`; the
daemon refuses to open traffic unless LaunchServices reports the clone as
managed and the provider reports `scope=per-app`.

Guarantee boundary:

- **Managed per-app On Demand VPN:** each clone and the original Reddit app are
  mapped to the custom provider. Missing daemon heartbeat closes its policy;
  supervision/MDM prevents the user from removing the mapping.
- **Unmanaged device:** the daemon refuses launches without managed-provider
  acknowledgement. App-proxy configurations can only be created through MDM;
  there is no host-created global VPN fallback. Unassigned applications are
  outside the provider's scope.

Apple's undeletable **Always On VPN** is a supervised, device-wide IKEv2
feature; it does not turn a custom app-proxy extension into an OS firewall.
Therefore no custom NetworkExtension can promise deny if its own provider or
managed configuration is absent. The strongest independent guarantee requires
an additional supervised IKEv2 Always On gateway that drops Reddit traffic
unless the RedditBox proxy policy is active. This repository enforces daemon
failure (heartbeat), tweak failure, and uninjected original-bundle traffic
while the managed custom provider is installed and running.

The provider is default-deny, mirrors the daemon's generation-bound lease, and
drops every captured packet. Only validated proxy IPs are excluded while the
lease is open. A one-second daemon heartbeat is mandatory; if it disappears,
the provider returns to deny within 2.5 seconds.

## Isolation versus login compatibility

- WebKit uses the clone's OS-owned website data store and is allowed only while
  both the clone-local lease and system firewall agree. WebRTC remains blocked.
- `ASWebAuthenticationSession` is forced ephemeral and allowed only when the
  supervised per-app payload reports Reddit `SafariDomains` coverage. Unknown
  third-party identity-provider domains fail closed until added and verified.
  In-process `WKWebView` uses the clone's own WebKit container.
  WebKit/OAuth through this drop-only tunnel requires an HTTP/HTTPS CONNECT
  upstream; SOCKS5 remains supported for injected app traffic but needs a
  separately audited tun2socks engine before WebKit can use it.
- App Attest and DeviceCheck default to `blocked`. Each can be enabled
  independently under `security.appAttest` / `security.deviceCheck` for a
  disposable-profile login test. Enabling either exposes an Apple
  physical-device signal and is an explicit isolation exception.
- Clone startup performs an explicit keychain add/read/delete probe in its
  unique access group. If Reddit requests a stock hard-coded access group,
  Security returns `errSecMissingEntitlement`; the code does not fall back to a
  shared group. Treat a resulting login failure as a release blocker.
- CoreMotion/proximity sensors, local listeners/loopback, SSID/BSSID/interface
  metadata, third-party NSURLSession hosts, notifications, background tasks,
  iCloud KVS, and ubiquity containers are blocked by default. The compatibility
  exceptions are per profile: `security.sensorAccess`,
  `security.localNetworking`, `security.networkMetadata`, and
  `security.thirdPartyNetwork`.
- `security.strictTiming=enabled` virtualizes monotonic uptime against a
  persistent per-profile boot epoch. Disabling it exposes the real device
  uptime but may be used as a temporary compatibility diagnostic.
- APNs/PushKit and pasteboard remain blocked because the critical Reddit path
  does not require them.

Open **RedditBox → Settings → Diagnostics** for daemon, source, configuration,
lease/firewall, per-app VPN, hook-readiness, clone-isolation and managed-app
checks. **Share Logs** creates a redacted support export. The packaged shell
smoke script remains only a developer fallback.

## No-SSH boundary

After installing the `.deb`, RedditBox-owned setup has no required terminal
step. External platform operations still exist, but can be completed with
graphical tools: the package manager resolves the declared clone-tool/AppSync
dependencies, the legally obtained decrypted source opens from Files in an IPA
installer, and launcher-shared IPA/MDM files upload in the MDM web console. Device
supervision and Apple's managed-app `VPNUUID` assignment cannot be performed by
an ordinary launcher app. CLI scripts remain supported only for development and
recovery.

Multi-account container + anti-fingerprint system for the Reddit iOS app on
palera1n (rootless/rootful) and Dopamine (rootless). One RedditBox launcher manages hidden, OS-isolated Reddit
clones, each with its own data, keychain, device identity, proxy, and
geo-consistent profile.

See [PLAN.md](PLAN.md) for the full architecture, identifier inventory, zero-leak matrix,
and leak-audit test plan.

## Components

| Component | Path | Loads into | Purpose |
|---|---|---|---|
| `tweak` | `tweak/` | cloned Reddit main apps | Identity spoof engine, service blocks, proxy defense, JB hiding |
| `launcher` | `launcher/` | standalone UIKit app | List/create/open/delete containers; daemon request client |
| `daemon` | `daemon/` | root, launchd | Container registry, profile generator/validator, proxy pool, kill switch, preload |
| `prefs` | `prefs/` | Settings app | Legacy notice directing users to the RedditBox launcher |
| `profiles` | `profiles/` | (data) | Device model tables, carrier tables, OUI pools, schema doc |
| `tools` | `tools/` | host | Leak-audit scripts (mitmproxy addon etc.) |
| `cloud` | `cloud/` | Vercel / Node | SocialBox Cloud website + API (zero-knowledge backups) |

## Data flow

```
Select a container in RedditBox launcher
  → pending plist + darwin doorbell → redditboxd
  → daemon serializes the request; launcher has no direct launch/network API
  → validate profile (consistency validator §13) → activate proxy (validate exit IP/geo)
  → verify signed hidden-clone metadata and supervised per-app VPN scope
  → launch clone while traffic is ARMED
  → sync profile/lease into that clone's OS data container
  → verify identity hooks → open firewall
  → app runs with OS-separated files/defaults/cookies/keychain
Close/kill Reddit
  → redditboxd watcher → deactivate proxy, flush residue (kill switch §6.3)
```

## Building

Theos packaging can run on Linux/macOS, but the required signed
NetworkExtension archive needs macOS/Xcode. Use the complete Mac build:

```sh
RBX_PACKAGE_SCHEME=rootless bash scripts/build-mac.sh  # Dopamine / palera1n rootless
# Or, for palera1n rootful:
RBX_PACKAGE_SCHEME=rootful bash scripts/build-mac.sh
```

Choose one, or run sequentially to build both. Install the matching `.deb` via
Sileo/SSH on the device. See the [compatibility and installation guide](docs/jailbreak-compatibility.md)
for the architecture/source mapping and the [Mac acceptance runbook](docs/on-device-smoke-checklist.md)
for full ldid-only setup. Mac builds and all three device configurations remain
**NOT RUN**; implemented compatibility is not a hardware acceptance result.

### One-time environment setup (Windows/WSL2)

```powershell
wsl --install -d Ubuntu
```

then inside WSL:

```sh
sudo apt install git make perl curl ldid xz-utils fakeroot
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
export THEOS=~/theos   # add to ~/.bashrc
```

## Status

- [x] P0 — repo scaffold (tweak, sbhook, daemon, prefs, profiles, tools)
- [x] Core identity hook engine (MGCopyAnswer_internal, IOKit, sysctl/uname, IDFA/IDFV, UIDevice)
- [x] Per-profile signed app clones + OS data/keychain-container separation
- [x] Jailbreak hiding (Shadow-class hooks)
- [x] Per-container proxy enforcement (in-process layer; NE kill-switch layer next)
- [x] Daemon skeleton: registry, generator (diversity spread), consistency validator, process controller, proxy manager
- [x] Feature 6 — identifier hygiene: synthetic catalog model/OS policy (see docs/identity-policy.md), posture-aware IDFA/IDFV + ATT hooks (A5/A6, D3), locale/timezone hooks (C1/C2), GPS city spoof (C3), battery offset (B5), app-version drift alert (D2), location-city validator warning
- [x] Central store (com.redditbox.store.json: shared tweak/daemon/prefs state, atomic writes, capped alerts/requests)
- [x] Feature 1 — App Attest control: per-container/global toggle, OFF = graceful DeviceCheck error, key budget tracker (80/95 alerts), keyId dedup guard (cloned keys blocked)
- [x] Feature 3.1 — account health checker: proxy-only about.json checks, calibration mode, fresh-account shadowban alert, karma tracking
- [x] Feature 2 — leak detection suite: push token block/monitor (PUSH LEAK), DeviceCheck toggle (devicecheckUsed), reddit.com request audit (IP LINK), FNV-1a fingerprint registry (FINGERPRINT DUP)
- [x] Feature 4 — launcher dashboard/diagnostics: daemon, VPN, hooks, clone isolation, source and redacted support logs
- [x] Feature 5 — A/B framework: 50/50 group assignment at creation, group-default attest for "auto" mode, dashboard report + winner action
- [x] Feature 7 — SocialBox Cloud (device + website): launcher pairing, encrypted global rotation settings, profile sync, encrypted backup/import, and per-profile overrides
- [x] Prefs UI: container add/delete, proxy pool editor, per-container IDFA posture
- [x] Reddit API header/body rewrite (install UUID, X-Dev-Ad-Id, Device-Name, UA, install timestamp, analytics device fields)
- [x] Remaining static leak coverage: protobuf/upload rewrite, early HMAC
  handling, non-Apple suite/app-group remapping, push blocking, configurable
  attestation, HTTP/3 blocking, sensors/runtime/network-metadata hardening.
- [x] NetworkExtension default-deny kill switch and daemon acknowledgements.
- [ ] Compile + on-device bring-up (requires macOS, Xcode signing and Theos).
- [ ] Runtime leak audit: packet capture, OS-container/keychain sentinel diff,
  private-API probes, OAuth and scale test. TLS/JA3 jitter is deliberately not
  claimed; native TLS remains a documented residual.

Note: code is written to compile but has **not** been built yet (Theos requires Linux/
macOS/WSL; WSL is not installed on this machine). First compile will surface
SpringBoard-private-API and header-level nits that only appear against real SDKs.

C09 transport design, configuration migration, and disconnect validation are in
[docs/firewall-transport.md](docs/firewall-transport.md).
