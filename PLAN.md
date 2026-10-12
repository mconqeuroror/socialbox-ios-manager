# RedditBox — Multi-Account Container & Anti-Fingerprint System for palera1n

**Goal:** Run 40–50 isolated Reddit accounts on one jailbroken (palera1n, rootless) iPhone for
OnlyFans model promotion, where Reddit's server cannot correlate the accounts to each other or to
one physical device.

**Core UX:** Long-press the Reddit app icon → pick a container → app relaunches as a completely
separate "phone": separate identity, separate data, separate IP. Close Reddit → everything is torn
down (process killed, network reach gone, no residue).

---

## 1. Requirements

| # | Requirement |
|---|-------------|
| R1 | Hold the Reddit app icon → context menu to switch containers (like Crane) |
| R2 | Each container = fully separate app data (login, cookies, keychain, prefs, caches) |
| R3 | Each container = separate device identity (all identifiers spoofed, ~130 cataloged below) |
| R4 | Zero cross-container leakage — Reddit must not be able to link accounts |
| R5 | Proxy rotation: each container gets its own proxy; switching containers rotates the exit IP |
| R6 | Closing Reddit kills its reach inside the phone (process + network + residue purge) |
| R7 | Starting a container preloads everything before the app makes its first request |
| R8 | Jailbreak state hidden from Reddit at all times |
| R9 | Works on palera1n rootless (checkm8 devices, iOS 15–17), Theos `THEOS_PACKAGE_SCHEME=rootless` |

**Design constraint (accepted):** one container active at a time. Switching container = terminate
app process and relaunch it bound to the new container. (Parallel containers are possible later
via LiveContainer-style double-install, but they multiply detectability; not in v1.)

---

## 2. Threat model — what Reddit can actually observe

Reddit iOS (`com.reddit.Reddit`) collects, per tech-stack analysis + API reversing:

- **Anti-fraud stack:** Apple App Attest / DeviceCheck, Google reCAPTCHA Enterprise, own device-risk scoring on GraphQL/REST (`gql.reddit.com`, `oauth.reddit.com`, `accounts.reddit.com`)
- **Attribution/analytics SDKs:** AppsFlyer (full device fingerprinting), Firebase (FID + app_instance_id), Branch
- **Transport identity:** HMAC-signed request headers (`X-Hmac-Signed-Body/Result`), `Client-Vendor-Id`, `X-Reddit-Device-Id` (persisted UUID), `x-reddit-loid` (server-issued device cookie), `x-reddit-session`, attestation headers
- **Client signals:** IDFA/IDFV, model identifiers, iOS version, screen metrics, locale/timezone, carrier, boot time, disk/RAM, device name, push token, keychain-stored trust tokens

So the leak surface is: **in-app readable identifiers, persisted state, network exit, Apple
hardware-attestation services, and jailbreak artifacts.** The plan addresses each in turn.

---

## 3. Architecture

```
┌────────────────────────── SpringBoard ──────────────────────────┐
│  RedditBox SB tweak: long-press Reddit icon → container menu      │
│  (lists containers, badge shows active one, "New container")     │
└───────────────┬─────────────────────────────────────────────────┘
                │ sets REDDITBOX_CONTAINER=<id> + relaunches app
                ▼
┌─────────────────── Reddit app process (injected) ───────────────┐
│ RedditBox Tweak (Logos, the heart):                              │
│  1. Container resolution (env var)                                │
│  2. Data-container path redirection (+ sibling-hiding)            │
│  3. Keychain access-group remap per container                     │
│  4. Identity spoof engine (MGCopyAnswer, IORegistry, sysctl,     │
│     uname, IDFA/IDFV, UIDevice, CTCarrier, boottime, screen…)    │
│  5. Per-container proxy enforcement (all CFNetwork/NSURLSession)  │
│  6. Push-registration suppression + background-fetch disable      │
│  7. Jailbreak hiding (Shadow-class hooks, scoped to Reddit)       │
│  8. Termination hooks (clean exit, kill residue triggers daemon)  │
└───────────────┬─────────────────────────────────────────────────┘
                │ XPC/darwin notifications
                ▼
┌─────────────────────── RedditBox daemon (root) ─────────────────┐
│ - Container registry (create/rename/delete/export/import)         │
│ - Identity profile store + generator (plausible fake devices)     │
│ - Proxy pool manager (per container, sticky-per-session rotation) │
│ - Process watcher: app dies → verify no sockets, flush DNS,      │
│   stop proxy route, purge temp residue                            │
│ - Preload on launch: apply identity, spin proxy, warm DNS        │
│ - Keychain purge (wildcard entitlement helper) on container delete│
└───────────────┬─────────────────────────────────────────────────┘
                ▼
┌────────────────── Settings preference bundle (UI) ────────────────┐
│ Manage containers, proxies, identities; export/import accounts    │
└──────────────────────────────────────────────────────────────────┘
```

**Deployment:** one rootless `.deb` (`iphoneos-arm64`, `/var/jb` prefix) containing:
`tweak` (injected into Reddit processes), `sbhook` (SpringBoard), `daemon` (launchd plist),
`prefs` (Settings pane), `redditboxd` helper binaries.

---

## 4. Container isolation design (R1, R2)

Modeled on how Crane (opa334) does it, but standalone (no license, full control):

1. **Data redirection.** Per-container app data lives at
   `/var/mobile/Containers/Data/Application/<app-uuid>/RedditBox/<container-id>/…`
   (inside the app's real sandbox → sandbox profile still passes; no permission issues).
   The tweak, at constructor time (before `main()`), rewrites the resolved container/home
   path for the app process so `NSHomeDirectory()`, `getenv("HOME")`,
   `containerURLForSecurityApplicationGroupIdentifier:` (app groups), `NSCachesDirectory`,
   cookies, `WKWebsiteDataStore`, `URLCache`, `NSUserDefaults` domain plist — everything —
   resolves into the container subdir.
2. **Sibling hiding (zero-leak critical).** Because all containers live in the same real
   container directory, the app could `ls ..` and see sibling containers. We hook
   `opendir/readdir`, `getattrlist`, `NSFileManager` enumeration, `stat/access` on the real
   container root to hide `RedditBox/` and everything but the active container from the app.
   (Crane's "prevent sandbox lookups" equivalent.)
3. **Keychain separation.** Hook `SecItemAdd/SecItemCopyMatching/SecItemUpdate/Delete` and
   rewrite `kSecAttrAccessGroup` to a per-container group
   (`<original-group>.rbx<container-id>`). Reddit OAuth tokens, AppsFlyer UID, Firebase FID,
   App Attest key IDs all become per-container.
4. **UserDefaults/prefs/caches/cookies:** automatically inside the container → separated.
5. **Pasteboard:** optionally cleared on every container switch (belt & suspenders).
6. **Safari cookie hygiene:** if Reddit ever uses `SFSafariViewController` /
   `ASWebAuthenticationSession` (shared Safari cookie jar), hook to redirect to in-app
   `WKWebView`, and wipe `accounts.reddit.com`/`reddit.com` Safari cookies on switch.
7. **App extensions (share sheet, widgets, notification service):** injected with the same
   tweak and bound to the active container; widgets optional per-container. Background app
   refresh and silent push for Reddit are force-disabled (part of R6).
8. **Push notifications (critical leak):** the APNs token is per app-install/per device —
   identical across containers. If all 50 accounts register push, Reddit sees 50 accounts on
   one push token = instant correlation. We hook
   `UIApplication.registerForRemoteNotifications` (and `PKPushRegistry`) to no-op per
   container. Local notifications still work.
9. **Switching:** long-press menu (SpringBoard hook into the icon context menu) → daemon
   SIGKILLs Reddit, sets launch env `REDDITBOX_CONTAINER`, relaunches.
10. **Deleting a container:** daemon wipes the container dir + purges its keychain group via a
    helper with wildcard keychain entitlement (keychain-dumper technique, extended to delete).

---

## 5. Identity spoof engine (R3, R4)

### 5.1 The full identifier inventory (the "73" is really ~130+)

Legend: **H** = hooked per container, **C** = separated by container automatically,
**P** = managed by proxy/network layer, **A** = Apple-side residual (see §9 risk table).

#### A. Hardware/device identity (MobileGestalt `MGCopyAnswer`, hooked at `MGCopyAnswer_internal` — covers protected *and* unprotected keys)

| Identifier | MG key(s) | Spoof rule |
|---|---|---|
| UDID | `UniqueDeviceID`, `UniqueDeviceIDData`, `InverseDeviceID` | Modern format `<8-hex board prefix>-<16 hex>`; board prefix table per ProductType |
| Serial number | `SerialNumber` | 10-char, real factory-code prefix pool per model |
| Logic-board serial | `MLBSerialNumber` | 17-char alphanumeric, model-plausible |
| IMEI 1/2 | `InternationalMobileEquipmentIdentity(2)` | 15 digits: model-true TAC + SN + Luhn |
| MEID | `MobileEquipmentIdentifier` | 14 hex |
| ICCID (SIM) | `IntegratedCircuitCardIdentifier(2)` | `89` + country/issuer + Luhn |
| Wi-Fi MAC | `WifiAddress(Data)`, `SecondaryWifiMacAddress(Data)` | Apple OUI pool + random |
| Bluetooth MAC | `BluetoothAddress(Data)`, `SecondaryBluetoothMacAddress(Data)`, `RemoteBluetoothAddress(Data)` | Apple OUI pool |
| Ethernet MACs | `EthernetMacAddress(Data)`, `SecondaryEthernetMacAddress(Data)`, `PintoMacAddress(Data)` | Apple OUI pool |
| SoC chip IDs | `UniqueChipID`, `ChipID`, `chip-id`, `DieId`, `die-id`, `HardwarePlatform`, `CPUType`, `CPUSubType`, `CPUArchitecture` | Fixed per model profile (e.g. A15 → constant chip-id family) |
| Baseband | `BasebandSerialNumber`, `BasebandUniqueId`, `BasebandChipId`, `BasebandChipset`, `BasebandFirmwareVersion`, `BasebandVersion`, `BasebandBoardSnum`, `BasebandCertId` | Plausible per profile |
| Secure elements | `SecureElementID`, `EUICCChipID`, `euicc-chip-id`, `NFCUniqueChipID` | Random per profile |
| UWB | `YonkersChipID`, `YonkersSerialNumber`, `YonkersUID` | Only if profile has UWB |
| Component serials | `PanelSerialNumber`, `RawPanelSerialNumber`, `AmbientLightSensorSerialNumber`, `BatterySerialNumber`, `CoverglassSerialNumber`, `MesaSerialNumber`, `LynxSerialNumber`, `LynxPublicKey`, `SavageUID/ChipID/SerialNumber`, `RoswellChipID`, `ArcModuleSerialNumber`, `RosalineSerialNumber`, `FrontFacingCameraModuleSerialNumber`, `RearFacingCameraModuleSerialNumber`, `NandControllerUID`, `AWDID`, `TristarID`, `WirelessBoardSnum`, `wifi-module-sn` | Random, format-true per key |
| NAND / storage | `DiskUsage`, free space via `statfs`/`NSURL` volume APIs | Total fixed per profile model; free space jittered per container |

#### B. Device marketing identity (must be internally consistent)

| Identifier | Sources (all hooked) |
|---|---|
| Model name | `marketing-name`, `MarketingProductName`, `ProductName`, `UIDevice.model` |
| Model number (SKU) | `ModelNumber` (e.g. `MPXV3LL/A` — region suffix per RegionCode) |
| Model identifier | `ProductType` (`iPhone14,2`), `HWModelStr`, `modelIdentifier`, `uname()` `machine`, `sysctl hw.machine/hw.model` |
| Device class | `DeviceClass`, `DeviceClassNumber`, `DeviceBrand`, `DeviceSubBrand` |
| Regulatory | `RegulatoryModelNumber` (e.g. `A2631`) |
| iOS version | `ProductVersion`, `UIDevice.systemVersion`, `NSProcessInfo.operatingSystemVersion`, `utsname.release`, `sysctl kern.osrelease` |
| OS build | `BuildVersion`, `BuildID`, `SoftwareBundleVersion`, `ReleaseType` |
| Device name (user) | `DeviceName`, `UserAssignedDeviceName`, `GSDeviceName`, `device-name(-localized)`, `ComputerName`, `name`, `UIDevice.name` — human-plausible per profile |
| Region | `RegionCode`, `RegionInfo`, `RegionalBehavior*` |
| Color/material | `DeviceColor`, `DeviceEnclosureColor`, `DeviceBackingColor`, `DeviceCoverGlassColor`, `DeviceHousingColor`, `DeviceEnclosureRGBColor`, `DeviceEnclosureMaterial`, `DeviceBackGlassMaterial` |
| Screen | `UIScreen bounds/nativeBounds/scale/nativeScale/maximumFramesPerSecond`, `main-screen-width/height/scale/pitch/class`, `MaximumScreenScale`, `screen-dimensions` |
| Wi-Fi/chipset | `WifiVendor`, `WifiChipset`, `wifi-chipset`, `WSKU` |
| RAM | `sysctl hw.memsize`, `hw.physmem` |
| IORegistry | `IOPlatformSerialNumber`, `IOPlatformUUID`, `IOPlatformExpertDevice` props (hook `IORegistryEntryCreateCFProperty`) |

#### C. Cellular / carrier

| Identifier | Sources |
|---|---|
| MCC/MNC | `MobileSubscriberCountryCode`, `MobileSubscriberNetworkNumber`, `CTCarrier.mobileCountryCode/NetworkCode` |
| Carrier name | `CarrierBundleInfoArray`, `CTCarrier.carrierName`, `CTTelephonyNetworkInfo` |
| SIM status | `SIMStatus(2)`, `SIMTrayStatus(2)`, `AirplaneMode` |
| Phone number | `PhoneNumber` (rarely readable) |
| MEID/baseband region | `BasebandRegionSKU` |

Carrier profile must be geo-consistent with the container's proxy (e.g. proxy in DE → Vodafone DE MCC 262 MNC 02).

#### D. Apple platform identifiers

| Identifier | Source | Strategy |
|---|---|---|
| IDFA | `ASIdentifierManager.advertisingIdentifier`, ATT status | Per-container UUID (all-zero fallback optional) — **H** |
| IDFV | `UIDevice.identifierForVendor` | Per-container UUID — **H** (without this, all containers share one IDFV = same "device" for AppsFlyer/Firebase/Reddit) |
| App Attest keys | `DCAppAttestService` (Secure Enclave) | Keys persist in per-container keychain → distinct per container — **C**; see fraud-metric risk §9 |
| DeviceCheck bits | Apple-side 2 bits per app | Residual — **A** |
| APNs push token | push registration | Suppress registration per container — **H** |
| iCloud/KVS | `NSUbiquitousKeyValueStore` | Disable ubiquity for Reddit — **H** |
| Game Center, StoreKit receipts | — | Not used by Reddit; ignore |

#### E. Reddit app-level identifiers (persisted → per-container **C**; forced on the wire → **H**)

`X-Reddit-Device-Id` / `Client-Vendor-Id` UUIDs, `x-reddit-loid`, `x-reddit-session`, bearer +
refresh tokens, GQL client/trusted-device IDs, experiment bucket assignments, any "device trust"
cookies. All live in app data/keychain → separated by §4. In addition, `tweak/Network/RBXRedditAPIHooks.xm`
forces per-container `Client-Vendor-ID`, `x-reddit-device-id`, `User-Agent`, `X-Dev-Ad-Id`,
`Device-Name`, GraphQL/analytics `device_id` / advertising id / install timestamp / screen
fields on the wire, and isolates `loid` / `installation_id` UserDefaults keys so a shared
suite cannot leak them. Verified by leak audit (§10).

#### F. SDK-level identifiers (persisted → **C**; in-process reads → covered by §5 hooks)

AppsFlyer UID + fingerprint inputs, Firebase Installations FID + Analytics `app_instance_id`,
Branch identity, reCAPTCHA Enterprise signals, Sentry install ID (if present).

#### G. Network & environment identity

| Vector | Strategy |
|---|---|
| Exit IP (v4/v6) | **P** — per-container proxy, sticky within session, rotated across sessions/containers |
| DNS | Remote DNS through proxy (no local resolver leak) |
| TLS JA3/JA4, HTTP/2 fingerprint | Same binary ⇒ same JA3. Safe jitter: some containers TLS 1.3-only + HTTP/3 off. Full JA3 randomization not attempted (pinning / HTTP3 breakage) |
| User-Agent | Must match profile: model identifier + iOS version from profile (Reddit iOS UA embeds them) |
| Timezone/locale/keyboard/first language | Per-profile, geo-consistent with proxy |
| Boot time | `sysctl KERN_BOOTTIME` — per-container random offset (all containers sharing one boot time is itself a correlation signal) |
| Fonts (CoreText enumeration) | Must be plausible for profile iOS version; accepted minor risk, hookable if audit shows use |
| Uptime, battery, brightness | Natural variance; fine |
| File timestamps | Container dirs get staggered creation/mod times |
| Pasteboard | Cleared on switch — **H** |

### 5.2 Identity profile generator

Each container is assigned a generated **device profile** — a JSON blob (schema-versioned,
stored by the daemon, applied at launch before the app's first line runs):

```
{ "profileVersion": 1, "containerId": "model-alice",
  "device": { "productType": "iPhone14,2", "marketingName": "iPhone 13 Pro",
              "modelNumber": "MLPF3LL/A", "hwModelStr": "D63AP", "regulatoryModel": "A2483",
              "boardUdidPrefix": "00008101", "iosVersion": "17.4.1", "buildVersion": "21E236",
              "chip": "A15", "ramGB": 6, "screen": { "w": 2532, "h": 1170, "scale": 3, "fps": 120 },
              "color": "sierra-blue", "regionCode": "LL/A", "language": "en-US",
              "timezone": "America/New_York", "carrier": { "name": "T-Mobile", "mcc": "310", "mnc": "260" } },
  "serials": { "serialNumber": "F2LXK0Q2HQ", "udid": "00008101-0A1B2C3D4E5F6A7B",
               "imei1": "356728110123456", "imei2": null, "meid": "99001234567890",
               "iccid": "8901260000123456789", "wifiMac": "A4:83:E7:xx:xx:xx",
               "btMac": "F0:18:E2:xx:xx:xx", "mlb": "C0ZCB07FQ1HJM3DQ1", "basebandSerial": "..." },
  "ids": { "idfa": "8C1F…-UUID", "idfv": "3B7A…-UUID" },
  "timing": { "bootTimeOffsetSeconds": 913444 },
  "proxy": { "list": ["socks5://u:p@gw1.example.com:1080", "…"], "sticky": true } }
```

**Consistency rules enforced by the generator (this is where most competitors fail):**

1. UDID board prefix, ProductType, HWModelStr, chip family, RAM, screen metrics, `maximumFramesPerSecond`, regulatory model all match the real device family (built from a curated table of real devices; only screen-compatible models are allowed if we also spoof `UIScreen`).
2. IMEI TAC, serial factory prefix, model number, region suffix, carrier MCC/MNC are model- and geo-true.
3. iOS version ↔ buildVersion ↔ utsname.release ↔ UA string ↔ font set all match.
4. Timezone/locale/currency/carrier match the proxy's geo.
5. IDFA/IDFV are v4 UUIDs; MACs from Apple OUI pools; Luhn checksums on IMEI/ICCID.
6. Profiles are immutable once assigned (a device that changes its serial next login = red flag).

### 5.3 Hook implementation notes

- `MGCopyAnswer_internal` hooking follows the MGSpoof/Lessica pattern (resolve the internal
  branch after `_MGCopyAnswer` in `libMobileGestalt.dylib`, then `MSHookFunction`); works on
  iOS 15–17 arm64/arm64e (verified patterns exist for both legacy and modern prologues).
- One generic override dictionary (`profile → key → value`) covers all MG keys in §5.1A/B/C;
  anything not in the profile passes through untouched (capabilities keys must stay real or apps crash).
- `uname`/`sysctl`/`sysctlbyname`/`getenv` hooking for `hw.*`, `kern.boottime`, `kern.osrelease`.
- `IOKit`: hook `IOServiceGetMatchingService`/`IORegistryEntryCreateCFProperty` for
  `IOPlatformExpertDevice` serial/UUID answers.
- ObjC-level: `UIDevice` (name, model, systemVersion, identifierForVendor, batteryLevel),
  `ASIdentifierManager`, `UIScreen` (bounds/scale/nativeBounds/maximumFramesPerSecond),
  `CTTelephonyNetworkInfo`/`CTCarrier`, `NSLocale` where needed for tz/locale.
- All hooks are scoped to `com.reddit.Reddit` processes (and its extensions) only.

---

## 6. Network layer: proxy rotation, kill switch, preload (R5, R6, R7)

### 6.1 Per-container proxy enforcement

- Primary: in-process hook forces **all** of the app's traffic through the container's proxy:
  hook `CFNetworkCopySystemProxySettings`, `NSURLSessionConfiguration.connectionProxyDictionary`,
  and the `CFStream`/`CFSocketStream` low-level connect path (covers AFNetworking/Alamofire,
  WebViews, and raw sockets Reddit uses). Upstream: HTTP/HTTPS or SOCKS5 with auth.
- Optional enforcement layer (recommended): a Network-Extension (or daemon-controlled tun2socks)
  route that only accepts Reddit-process traffic via the active container's upstream, blocking
  any direct (non-proxied) egress = hard kill switch against proxy bypass/UDP leaks.
- IPv6: prefer proxies with v6 support; otherwise NE layer drops v6 so no v6 leak.

### 6.2 Rotation policy (anti-fraud aware)

- **Within a session: sticky.** An account's IP must not change mid-session (rapid IP churn is
  itself a fraud signal). The container keeps its current upstream while the app is running.
- **Across sessions/containers: rotate.** On each container activation, the next proxy from
  the container's pool is selected (round-robin or least-recently-used).
- Per-container pools can point at a rotating residential/mobile proxy gateway with a
  sticky-session flag — one gateway URL, stable IP per container session, new IP on next
  session. This is the most natural-looking pattern.

### 6.3 Kill switch on close (R6)

- Tweak watches app lifecycle; after the app is backgrounded for N seconds (configurable,
  default 30s) it force-terminates the process (iOS would otherwise keep it suspended).
- Background app refresh + silent push for Reddit are disabled → no reach while closed.
- Daemon process-watcher notices death: verifies no Reddit sockets remain (`lsof`-style scan),
  flushes DNS cache, tears down the container's proxy route (NE layer), clears pasteboard,
  prunes temp/cache residue flagged for purge.
- Result: a closed Reddit has zero processes, zero sockets, zero routes, zero tokens that
  identify the other containers.

### 6.4 Preload on container start (R7)

Before SpringBoard launches the app (or in the first milliseconds of launch):
1. Daemon applies the identity profile + container binding.
2. Spins up/validates the proxy upstream (handshake test — no traffic sent to Reddit yet).
3. Warms DNS through the proxy for `reddit.com`, `gql.reddit.com`, `accounts.reddit.com`,
   `oauth.reddit.com`, AppsFlyer/Firebase endpoints.
4. (Optional) pre-opens TLS sessions so the first app request isn't a cold start.
All of this happens before the app's first network call, so the very first request Reddit
sees is already consistent (right IP, right device).

---

## 7. Jailbreak hiding (R8)

Shadow-class hook set, active only in Reddit processes (modeled on jjolano/shadow, retargeted
to palera1n rootless):

- **File system:** hide `/var/jb`, `/var/jb/usr`, `/private/var/lib/apt`, `/Applications/Cydia.app`,
  `/var/mobile/Library/palera1n`, `/etc/apt`, `/bin/bash`, `/usr/sbin/sshd`, `/var/checkra1n`, etc. —
  hook `stat/lstat/access/fopen/opendir` so existence checks fail naturally.
- **Restricted-dir write / fork / symlink tests:** return jailed-looking results.
- **Dynamic linker:** hide jailbreak dylibs (Substrate/Substitute/ElleKit, our own RedditBox
  dylib, TweakLoader) from `_dyld_image_count/_dyld_get_image_name/_dyld_get_image_header`,
  `dladdr`, `task_info`.
- **Environment:** scrub `DYLD_*`, `_MSSafeMode`, jailbreak-related env vars from `getenv`/`environ`.
- **URL schemes:** `canOpenURL:` for `cydia://`, `sileo://`, `zbra://` etc. returns NO.
- **Suspicious classes/symbols:** avoid detectable class names in the injected code path.
- **Our own footprint:** prefs stored outside app-visible paths; dylib renamed to something
  neutral in the dyld list; no strings like "RedditBox" reachable from the Reddit process.
- **vnode-level fallback:** optionally layer `vnodebypass`-style protection on `/var/jb`.
- Note for later: migrating to palera1n-roothide/roothide Bootstrap would give stronger
  systemic hiding for free; our tweak-layer approach works on stock palera1n.

---

## 8. Zero-leak matrix (R4 summary)

| Leak vector | Mitigation | Where |
|---|---|---|
| Shared app data (tokens, cookies, prefs, caches) | Data-container redirection | §4.1 |
| App sees sibling containers | Sibling-hiding hooks | §4.2 |
| Shared keychain items | Access-group remap per container | §4.3 |
| Shared IDFA/IDFV | Per-container UUIDs | §5.1D |
| Shared MobileGestalt/IOKit identifiers | Per-container profile | §5.1A/B/C |
| Shared model/OS/screen fingerprint | Consistent per-container profile | §5.2 |
| Shared boot time | Per-container boot-time offset | §5.1G |
| Shared IP | Per-container proxy + rotation | §6 |
| Shared APNs push token | Suppress push registration + blank token in API bodies | §4.8, §17 |
| Shared Reddit install UUID / Device-Name / UA / IDFA on the wire | Force headers + JSON rewrite from `reddit.*` profile | §17 |
| Shared iCloud/KVS | Disable ubiquity | §5.1D |
| Safari shared cookies (login webviews) | WKWebView redirect + cookie wipe | §4.6 |
| Pasteboard residue | Clear on switch | §4.5 |
| Background/silent reach after close | Kill switch + BGFetch/push off | §6.3 |
| Jailbreak detection | Shadow-class hiding | §7 |
| Proxy bypass (app ignoring proxy) | NE kill-switch layer | §6.1 |
| DNS leaks | Remote DNS via proxy | §6.1 |
| Geo mismatch (IP vs tz/carrier/locale) | Profile generator consistency rules | §5.2 |

### Residual hardware-level risks (cannot be 100% spoofed — must be managed)

| Residual | Why it survives | Mitigation |
|---|---|---|
| **App Attest fraud metric** | Apple counts unique attested keys per device per app over 30 days (WWDC fraud metric); Reddit can query it | Keys are stable per container (don't regenerate); start with 10–15 accounts/device, scale up while monitoring ban/flag rates; Reddit's actual use of the metric is unknown |
| **DeviceCheck 2 bits** | Per-device bits stored at Apple | Only a coarse flag; if Reddit uses it for bans, the mitigation is fewer accounts/device |
| **TLS/HTTP2 fingerprint** | Same app binary for all containers | Mild per-container TLS-min / HTTP3 jitter only; full JA3 randomization would break pinning — accepted residual |
| **HMAC stale-copy** | Reddit may HMAC a local copy of the original body after we rewrote `HTTPBody` | Cannot re-sign without Reddit's key (`CCHmac` hook is fragile). We keep HMAC when rewrite happened first; strip only if body changes after HMAC headers exist |
| **Behavioral signals** (touch cadence, usage hours, content overlap) | Human factor | Operational discipline: different usage windows/patterns per account; different subreddits/caption styles per model |
| **Secure Enclave key** (per app-team) | Hardware-bound | Distinct attestation *keys* per container are fine (look like re-installs); only the count metric (above) correlates |

**Honest bottom line:** everything Reddit can *observe* is spoofed per container; the only
device-level joins left are Apple-attestation counters and behavioral patterns. Practical
experience in this niche suggests device-fingerprint separation + IP separation + behavior
hygiene is what actually keeps accounts alive.

---

## 9. Build plan

### 9.1 Environment

- Theos in WSL2 (or Linux/macOS), `THEOS_PACKAGE_SCHEME=rootless`, `TARGET = iphone:clang:latest:15.0`,
  `ARCHS = arm64 arm64e` → `.deb` for `iphoneos-arm64`.
- Deploy over SSH/Sileo to the palera1n device; debugging via `os_log` + console.
- Code: Objective-C/Logos + C hook code (substrate/ElleKit API), daemon in Objective-C.

### 9.2 Repo layout (planned)

```
redditbl/
├── PLAN.md
├── tweak/              # RedditBox.x(m) — identity, keychain, proxy, JB hiding hooks
│   ├── Makefile, RedditBox.plist (filter: com.reddit.Reddit.*)
│   ├── Identity/, Network/, Container/, JailbreakHiding/
├── sbhook/             # SpringBoard long-press container menu
├── daemon/             # redditboxd + launchd plist + keychain purge helper
├── prefs/              # Settings preference bundle
├── profiles/           # device profile generator + model tables (JSON)
└── tools/              # leak-audit scripts (mitmproxy addon, keychain dump diff)
```

### 9.3 Phases

| Phase | Deliverable | Effort est. |
|---|---|---|
| P0 — Skeleton | Theos rootless repo, tweak injects into Reddit, logging infra | 1–2 days |
| P1 — Containers | Data redirection + sibling hiding + keychain remap + SB long-press menu; 2 containers with separate logins | 4–7 days |
| P2 — Identity engine | Profile store/generator; MGCopyAnswer/IORegistry/uname/sysctl/IDFA/IDFV/UIDevice/CTCarrier hooks; ~130 identifiers | 5–8 days |
| P3 — Jailbreak hiding | Shadow-class hooks; validated with Reddit + 2–3 banking apps as proxies | 3–5 days |
| P4 — Network | Per-container proxy enforcement, rotation policy, kill switch, preload | 4–6 days |
| P5 — Hardening & leak audit | Full audit per §10; 10→50 container scale test; App Attest check | 4–6 days |
| P6 — Ops polish | Prefs UI, export/import, badge labels, docs | 2–4 days |

Total: roughly 3–5 weeks of focused dev to production quality.

---

## 10. Leak-audit test plan (how we *prove* zero leakage)

1. **Traffic diff:** run two containers through mitmproxy; diff every header/cookie/body field
   across accounts — must show zero shared identifiers (IDs, loid, tokens, IDFA/IDFV, model
   fields, UA).
2. **Keychain diff:** dump keychain per container (keychain-dumper); zero shared items.
3. **Storage diff:** diff container dirs; no absolute paths pointing at sibling containers.
4. **Fingerprint test:** load fingerprint-testing page in the app's webview per container;
   compare hashes.
5. **Idle-capture test:** close the app; capture traffic on-router for 24h → zero packets.
6. **JB-detection test:** Reddit runs clean; banking apps (N26/Revolut) run clean with tweak active.
7. **Attestation test:** capture `X-Attestation*` headers per container; verify distinct key IDs,
   server-accepted; monitor account health over weeks.
8. **Scale test:** 10 → 25 → 50 containers; automated login/logout smoke test per container.
9. **Proxy leak test:** DNS/IPv6/WebRTC leak checks through each upstream.
10. **Switch test:** rapid container switching under a packet capture — no request may leak on
    the previous container's proxy/identity.

---

## 11. Operational guidance (what keeps the accounts alive)

- 40–50 accounts on one physical device is aggressive; Reddit's abuse systems also weigh
  behavior (posting cadence, content similarity, engagement patterns, payments). Start with
  10–15 containers/device, add weekly while watching for shadowbans/flags.
- Keep proxy geo ↔ profile geo ↔ posting hours consistent.
- Pin the Reddit app version (disable auto-update) — every app update can add new detection;
  re-run the leak audit after updates.
- Never log the same account into two containers.
- Rotate content/subreddits per account; avoid identical link captions across models.

---

## 12. Decisions (resolved)

1. **Standalone container solution** — own container implementation (no Crane dependency).
   Full control over identity+proxy integration; Reddit-focused.
2. **Proxy enforcement:** in-process hooks **+ Network-Extension kill switch** (strongest).
   Reddit must never be able to connect containers — any single direct-egress leak burns the
   device IP for all 50 accounts, so the NE layer is mandatory.
3. **IDFA posture:** user-selectable per container in prefs: `random` (default) or
   `zero + ATT denied`. Not hardcoded.
4. **Push notifications:** suppressed per container by default (safest). If needed later,
   re-enable selectively.
5. **Smart geo-consistency validator (new):** the system actively detects senseless combos
   and warns/auto-fixes instead of silently shipping a red flag. See §13.

---

## 13. Smart consistency system (validator + warnings)

The profile generator doesn't just *allow* geo-consistent profiles — it **checks every
combination before a container can go live** and reports anything nonsensical to the user.

### 13.1 Validation rules (hard errors — container won't start)

| Check | Example of nonsense it catches |
|---|---|
| Proxy geo vs timezone | Proxy in SF, timezone `Europe/Berlin` |
| Proxy geo vs locale/currency | Proxy in DE, locale `en_US` / currency `USD` |
| Proxy geo vs carrier MCC/MNC | Proxy in Germany, carrier T-Mobile US (310-260) |
| Model vs region SKU | `iPhone14,2` with `ZP/A` (HK) model number while proxy is in US |
| iOS version vs build number | iOS `17.4.1` with build `19H12` (a 15.x build) |
| Model vs screen metrics | iPhone 14 Pro metrics on an `iPhone13,2` profile |
| Model vs chip/RAM/screen fps | 120Hz on a 60Hz-only device; 6GB RAM on a 4GB model |
| UDID prefix vs ProductType | Wrong board prefix for the model |
| IMEI TAC vs model | TAC for a different device family |
| Serial prefix vs factory | First chars don't map to the model's factories |
| WiFi/BT MAC vs Apple OUI | MACs from non-Apple OUIs |
| UUID format | IDFA/IDFV must be valid v4 |
| Luhn on IMEI/ICCID | Failed checksum |
| UUID stability | IDFA/IDFV/UDID/serial immutable once assigned (alert on drift) |
| ATT posture vs IDFA value | `zero` posture but IDFA non-zero (and vice versa) |

### 13.2 Warning-level signals (container starts, user notified)

| Signal | Meaning |
|---|---|
| Carrier popular but proxy geo odd (e.g. Vodafone DE on a US-geo proxy) | Mismatch suspicions |
| Carrier popular in proxy-geo but unusual (e.g. always the same rare regional carrier) | Pattern across containers |
| Language vs region | e.g. `de-DE` language in a US-geo profile |
| Keyboard/first-language vs locale | Inconsistent language signals |
| MCC of carrier not in proxy country | Carrier doesn't operate in the proxy country |
| Proxy ASN reputation (if database available) | Datacenter IP where a mobile/residential is expected |

### 13.3 Data sources for validation

- **On-device tables:** models (ProductType ↔ marketing name ↔ HWModelStr ↔ board prefix ↔ chip ↔ RAM ↔ screen ↔ fps ↔ regulatory model ↔ regions), carriers (name ↔ MCC/MNC ↔ countries), region SKUs, Apple OUI ranges, factory code pools, build-version tables, TAC pools per model.
- **Proxy geo lookup:** at container activation, the daemon performs one geo-IP lookup of the **current exit IP** (via the proxy itself) through an external geo service. Result is cached per container, refreshed if the exit IP changes. It is compared against the profile's timezone/locale/carrier. Any exit-IP geo change mid-session (see §6.2) trips an alert.
- **Auto-fix option:** if the user picks "Fix & start", the daemon regenerates the *derived* fields (timezone, locale, carrier, model number region suffix) to match the *primary* fields (device model, iOS version) and the proxy geo, then revalidates.

### 13.4 Auto-regulation behaviors (scale hygiene)

- **Diversity spread:** when generating N containers, enforce minimum diversity in models, iOS versions, and carriers so 50 containers don't look like 50 clones of the same iPhone 13 (weighted sampling without replacement, small leftover probability of repeats).
- **No shared serials/MACs/UUIDs:** generator checks against all existing containers' values.
- **Soft cap alert:** >15 containers active on the device prompts the user (App Attest fraud metric risk, §8).

---

## 14. Feature 6 — identifier hygiene (implemented)

Status legend: **Spoofed** = per-container hook · **Shared** = same for all containers, acceptable if internally consistent · **Gap** = closed here.

### B1 — Model pinned to the real device family (Critical)

`device.productType` is **pinned to the physical device** at generation time
(`RBXProfileGenerator.realProductType()` reads `sysctlbyname("hw.machine")`; the daemon
runs as root). Rationale: screen resolution, GPU (Metal), RAM and core count come from
real hardware — a profile claiming iPhone 15 Pro on a 4.7" device is an internally
inconsistent fingerprint Reddit could detect. We do **not** spoof Metal/GPU, so the model
must match reality. Model is therefore **Shared** across containers (accepted: Reddit cannot
compare across accounts it doesn't already know are linked). Marketing number base, region
suffix, iOS version, carrier, locale, timezone, city still vary per container. If the real
ProductType is not in the catalog, generation falls back to the old diversity-spread
behavior. Screen/RAM/etc. in the profile come from the catalog entry of the pinned model.

### A5/A6 — IDFA / IDFV (verified + closed)

`ids.idfa` / `ids.idfv` are stable per-container UUIDs generated once at container
creation and never re-randomized (profiles are only generated at creation; the registry
never regenerates existing ones). Posture support:

- `random` — IDFA = per-container UUID; `ATTrackingManager` reports **authorized**.
- `zeroWithATTDenied` — IDFA = `00000000-0000-0000-0000-000000000000`;
  `isAdvertisingTrackingEnabled` returns NO; `ATTrackingManager` reports **denied**;
  `requestTrackingAuthorizationWithCompletionHandler:` invokes the completion
  synchronously without showing the system prompt (D3).

Posture is drawn once at generation (50/50) and then stable per container, so a container
never flips ATT state between sessions (flapping would itself be a red flag).

### C1/C2 — Locale + timezone hooks (new)

`tweak/Identity/RBXLocaleHooks.xm` (`+[NSLocale currentLocale/systemLocale]`,
`+[NSLocale preferredLanguages]`, `-[NSLocale localeIdentifier]` for the instances we
hand out) and `tweak/Identity/RBXTimezoneHooks.xm` (`+[NSTimeZone
systemTimeZone/localTimeZone/defaultTimeZone]`, `systemTimeZoneName`,
`timeZoneWithName:` for the profile zone) answer from the persisted profile
(`device.locale`, `device.language`, `device.timezone`), so they are stable per
container and geo-aligned with the proxy. `device.language` is now derived from the
geo locale (proxy DE → `de`). All hooks pass through with no profile.

### C3 — GPS location spoof (new)

`catalog.json` gains `countryCities` (3–5 major cities per country, all 10 catalog
countries). Profiles gain `device.location = { city, lat, lon }`, picked from the proxy
country (also re-picked by `autofixProfile`). `tweak/Identity/RBXLocationHooks.xm`
hooks `CLLocationManager`: `startUpdatingLocation`/`requestLocation` deliver a spoofed
`CLLocation` after 1–2s (jittered) with a ±0.002° per-fix random offset so consecutive
fixes aren't bit-identical; `-[CLLocationManager location]` returns the cached spoofed
fix (never the real last-known fix). The app's delegate is read from
`manager.delegate` at delivery time (the property is `assign`/weak — no eager capture).
`%orig` is not called on the start paths when spoofing, so the real permission prompt
never fires. Documented limitations (best-effort per spec): significant-location-change
monitoring, visit monitoring, region monitoring, `CLGeocoder` reverse geocoding and
iBeacon ranging are not covered. `CoreLocation` added to tweak FRAMEWORKS (the app
already links it).

### B5 — Battery offset (new)

Profiles gain `timing.batteryOffsetPercent` (integer −8…+8, stable per container).
`-[UIDevice batteryLevel]` returns clamp(realLevel·100 + offset)/100 clamped to
[0.05, 1.0]; `batteryState` and monitoring flags pass through (real charging state is
the internally consistent choice — the cable is physically plugged in). Rationale:
50 accounts with a perfectly synchronized battery level is a soft cross-link.

### D2 — App version drift alert (daemon)

`daemon/RBXAppVersionMonitor.h/.m`, started from `daemon/main.m`. Reads the installed
Reddit version (`CFBundleShortVersionString` from the first
`/var/containers/Bundle/Application/*/Reddit.app/Info.plist` matched by bundle id) and
compares against `latestKnownVersion`. Config lives in a standalone plist
(`/var/mobile/Library/Preferences/com.redditbox.appversion.plist`; default latest version
`2025.30.0`, `checkIntervalHours` 24) so this feature has **no dependency on the central
store**; the store's `app.latestKnownVersion` is consulted only if present. If installed
is >2 minors behind, an alert `{type: "APP UPDATE", message, timestamp, day}` is
appended to the plist's `alerts` array (capped at 20, deduped per calendar day). Check
runs at daemon start + every 24h via a dispatch timer. No network calls — the operator
maintains the version manually (PLAN.md §11 already advises pinning the app version).

### Validator extension

`RBXConsistencyValidator.warningsForProfile:` now warns (not errors) when
`device.location.city` is not in `countryCities` for the profile's proxy country.

### Verification notes (acceptance §6/§7)

- Distinct + time-stable: `device_id`/IDFA/IDFV/locale/TZ/GPS all come from the persisted
  profile; the generator runs only at container creation, so values never re-randomize.
  Model is intentionally Shared (pinned real device, B1).
- Proxy geo X → locale/TZ/GPS all correspond to X (generator + validator + autofix all
  derive them from the same proxy country).
- Model in UA == uname == DeviceProfile holds automatically because all three read the
  pinned `device.productType`.
- Every hook passes through unchanged when no profile is loaded (each hook checks the
  profile first and calls `%orig` otherwise).


---

## 15. App Attest control, leak detection, health checker (implemented)

Shared foundation: **central store** (`daemon/RBXCentralStore.h/.m`) at
`/var/mobile/Library/Preferences/com.redditbox.store.json` — one JSON document shared by
tweak, daemon and prefs, with atomic read-modify-write, capped ring buffers (`requests`
last 500, `alerts` last 100) and the `com.redditbox.storeChanged` darwin notification.
Schema: `device` (attest key registry + budget + default), `containers.<id>`
(nickname/username/status/lifecycle/attest/push/fingerprint/lastHealth/karma/paused),
`health` (interval + calibration), `alerts`, `requests`.

### Feature 1 — App Attest module (tweak/AppAttest/RBXAppAttestHooks.xm)

- Hooks `DCAppAttestService generateKeyWithCompletionHandler:`,
  `attestKey:clientDataHash:completionHandler:` and
  `generateAssertion:clientDataHash:completionHandler:` (DeviceCheck framework linked in
  the tweak).
- Effective mode resolution per call: container `attest.mode` (`on`/`off`) →
  else A/B group default (`auto`) → else global `device.attestDefault`. Cached and
  refreshed on `com.redditbox.storeChanged` + `com.redditbox.prefsChanged`.
- OFF: every call completes with a synthetic NSError (domain `com.apple.devicecheck.error`,
  code `DCErrorUnknown`) and never reaches `%orig` — Reddit treats the device like an
  iPhone that cannot attest (graceful, no crash).
- ON: pass-through; a successful generateKey records `{containerId, keyId, timestamp}`
  into `device.attestKeysUsed` (the budget source of truth) and into the container's
  `attest.keyIds`.
- Key budget tracker: warn (yellow alert) at >=80, red alert at >=95 of `keyBudget`
  (default 100); alerts only fire when a threshold is newly crossed.
- KeyId dedup guard: any keyId observed via generateKey/attestKey is checked against all
  other containers' keys (device registry + per-container lists). A key shared with another
  container (cloned keychain) sets `attest.duplicateKey=true`, `attest.blocked=true`,
  adds a `DUPLICATE KEYID` alert and blocks all attest calls for that container (behaves
  like OFF). A dead/banned account's key is never re-sent.

### Feature 3.1 — shadowban / account health checker (daemon/RBXHealthChecker.h/.m)

- Unauthenticated `GET https://www.reddit.com/user/{username}/about.json` per container
  with a username, not dead and not paused.
- **Proxy-only**: the check rides the container's upstream via
  `NSURLSessionConfiguration.connectionProxyDictionary` (same pattern as
  `RBXProxyManager`). No/invalid proxy → check SKIPPED + logged warning (never the
  phone's direct IP; acceptance #7).
- On-demand (`com.redditbox.healthCheck` darwin notification) + scheduled dispatch timer
  (`health.intervalSeconds`, default 6h).
- Status interpretation driven by `health.calibration` (default
  `{200: healthy, 403: suspended, 404: shadowbanned}`, editable). Calibration mode
  (`health.calibrationMode`) logs status + first 500 bytes of the body and leaves status
  untouched so the operator can verify the mapping against a real banned test account.
- Result: container `lastHealth` + status (green/red/yellow) + `total_karma` →
  `karma` on 200. Suspended → `deathReason=ban`; shadowbanned → `deathReason=shadowban`.
- `checkFreshAccount:` — post-creation check; shadowbanned from day one → status red,
  `deathReason=shadowban` + a `FRESH ACCOUNT BANNED` alert.
- Gold-standard backup (documented only): post a test comment to a decoy subreddit from the
  container and verify visibility from an incognito session (see comment in source).

### Feature 2 — leak detection suite

- **2.1 Push monitor + block** (`tweak/LeakDetection/RBXPushHooks.xm`):
  `registerForRemoteNotifications` (and the `Matching:` variant) no-ops unless the
  container's `push.enabled` is ON (default OFF). Token capture hooks
  `application:didRegisterForRemoteNotificationsWithDeviceToken:` on the app-delegate
  class via `MSHookMessageEx` once the delegate exists (dispatch_after from the ctor),
  recording the hardware hex into the container's `push.token` for the daemon monitor
  but **never forwarding that NSData to Reddit** — the delegate gets a per-container
  SHA-256 dummy (or the callback is dropped when push is OFF). Daemon-side
  `RBXLeakMonitor` flags `PUSH LEAK` when two LIVE containers share a token.
- **2.2 DeviceCheck monitor** (same AppAttest file): `DCDevice generateTokenWithCompletionHandler:`
  and `isSupported` are fail-closed: OFF by default (prefs `devicecheckEnabled`) **and**
  blocked when the container's attest mode is OFF / blocked, so a shared hardware
  DeviceCheck token cannot join containers. When allowed through, usage is recorded as
  `devicecheckUsed`/`devicecheckAt`. No synthetic App Attest assertions.
- **2.3 IP audit** (`tweak/LeakDetection/RBXRequestAudit.xm` + daemon `RBXLeakMonitor`):
  `-[NSURLSession dataTaskWithRequest:completionHandler:]` /
  `dataTaskWithURL:completionHandler:` record reddit.com hosts into the `requests` ring
  buffer `{containerId, host, time, proxyId}` (async, coalesced writes — at most one
  flush per 2s batch). The monitor adds an `IP LINK` warning when two LIVE containers
  used the same `proxyId` within the last 10 minutes.
- **2.4 Fingerprint registry** (`daemon/RBXFingerprintRegistry.h/.m`): per-container
  `bundleHash` = FNV-1a 64-bit over sorted `userAgent|model|screen|locale|timezone`
  (observed UA captured by the request audit into `fingerprint.userAgent`). Two LIVE
  containers with an identical hash → `FINGERPRINT DUP` alert with operator-friendly
  wording. Diversity itself is guaranteed by `RBXProfileGenerator` (no change needed).

### Feature 4 — operator dashboard (prefs/RBXDashboardController.h/.m)

Registered from `RBXRootListController` as a `PSLinkCell` subpage. Header always
visible: `Keys X / ~100 (device)` (red ≥95, yellow ≥80), `Leaks: N`, `App Attest
default: ON/OFF`. One card per container (`PSSubtitleCell`): nickname + `● status ·
karma N · group A · attest ON`. Tap → action sheet: **Refresh health** (posts
`com.redditbox.healthCheck`), **Rotate container** (marks current dead
`deathReason=other` + daemon doorbell `com.redditbox.rotate` → generates a fresh
profile + A/B group and launches it), **Pause** (`paused=true`, daemon skips its health
checks). Alerts list is visible in the header count. Interface reloads on every appear.

### Feature 5 — A/B test framework (daemon/RBXABTestFramework.h/.m + dashboard)

New containers get `attest.group = A|B` (50/50, `arc4random_uniform(2)`) and
`attest.mode = auto` at creation (`createdAt` recorded). Effective attest for `auto`
= group default (A=ON, B=OFF). Lifecycle tracking (`createdAt`, `diedAt`,
`deathReason`, `missionCompleted`) feeds the dashboard's **A/B Report** section:
per group average survival days, % mission completed, ban rate (deathReason in
`{ban, shadowban}`). Once a group has >=30 containers a `Winner: group X — set as
default?` button appears; tapping it sets `device.attestDefault` accordingly.


---

## 16. Doritos Cloud — device side (implemented)

Factory/worker handoff: a **factory** phone creates + warms accounts and EXPORTS
containers to an operator-run website (cloud/, separate app, same contract); a
**worker** phone IMPORTS them and runs missions (no new accounts created there).
PUSH stays OFF everywhere.

### What travels in a snapshot (per container)

- tar.gz of the container data dir (includes Reddit's device_id, cookies/OAuth
  session, keychain data) — created via posix_spawn of /var/jb/usr/bin/tar
  (fallback /usr/bin/tar) with file actions (stdout dup2'ed to a temp file).
- `manifest.json`: {v:1, containerId, nickname, username, exportedAt,
  appVersion, profileSeed {productType, iosVersion, locale, timezone,
  location, idfa, idfv, batteryOffset, bootTimeOffset, installId,
  installTimestampMs, redditDeviceName}, proxy {url, country},
  attState, pushEnabled:false}.
- What does NOT travel: the App Attest key (Secure Enclave bound). After import
  the app re-attests with a fresh keyId = the account looks like a user who
  bought a new iPhone (natural pattern).

### Blob format (must match the cloud/ web app)

`passphrase -> PBKDF2-HMAC-SHA256 (600,000 iterations, 16-byte random salt,
32-byte key) -> AES-256-GCM (12-byte random nonce, 16-byte tag)`.
AAD = the exact JSON string
`{"v":1,"kdf":"PBKDF2-SHA256","iter":600000,"cipher":"AES-256-GCM"}`.
`blob = salt(16) || nonce(12) || ciphertext || tag(16)`;
ciphertext = `4-byte big-endian manifest JSON length || manifest JSON (UTF-8) ||
tar.gz bytes`. A server dump therefore contains nothing decryptable without the
passphrase.

Implementation note: CryptoKit's AES.GCM is Swift-only, so the Objective-C
daemon uses the system `libcommonCrypto` SPI
(`CCCryptorGCMOneshotEncrypt/Decrypt`, local prototypes) — same algorithm, same
wire format.

### Device flow

1. **Pairing** — operator creates a pairing on the website
   (`POST /api/devices/pair {name, role}` with a user JWT) and enters the
   returned `pairingCode` in Settings > RedditBox > **Cloud**. The pane writes
   the action to `/var/mobile/Library/Preferences/com.redditbox.cloud.plist`
   and posts `com.redditbox.cloudAction`; the daemon (RBXCloudSync) POSTs
   `/api/devices/claim {pairingCode}` and stores {deviceId, deviceToken} in
   the same plist. Server URL is a PSTextField (default https://doritos.example.com).
2. **Passphrase** — generated on-device at daemon start (24 chars, mixed
   alphabet, SecRandomCopyBytes entropy; stored in the cloud plist), shown
   copyable in the Cloud pane so the operator can transfer it to another phone
   manually. Never leaves the device. A "Regenerate passphrase" button exists
   (old exports become undecryptable locally).
3. **Export** — snapshots the ACTIVE container (binding file; a container-id
   text field overrides). Plaintext envelope (before encrypt) matches the
   shared contract:
   `{schemaVersion, containerId, profile, exportedAt, sourceDeviceModel,
   proxyHint, attest:{keyId?, attestEnabled}}` plus `archiveB64` (tar.gz of
   the container data dir — required so a worker can restore cookies/OAuth).
   Uploads `POST /api/backups` JSON
   `{containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed}`.
   Ciphertext is AES-256-GCM of the envelope (PBKDF2-HMAC-SHA256, 600k iters).
   Server stores only ciphertext + metadata and never decrypts. Cloud sync
   uses a DIRECT connection (operator infrastructure, not Reddit traffic).
4. **Import** — "Import newest backup" / "Import by ID" buttons. Flow:
   list (`GET /api/backups`) -> pick backup (newest = skipping backups older than
   `expireDays` (default 7, logged)) -> `GET /api/backups/:id` JSON -> freshness check
   (>72h refused unless "Allow stale imports" is on -> "STALE BACKUP" alert;
   >24h warning alert) -> decrypt (failure = "WRONG PASSPHRASE" alert, clean
   abort) -> manifest validation. **Proxy continuity is a HARD FAIL**: the
   backup's proxy URL must be well-formed and its country must match the
   profileSeed's locale + timezone countries (§13.1-style checks via
   RBXDeviceCatalog), and the SAME upstream is registered in the local proxy
   pool so RBXProxyManager can activate it (exit-IP validation re-runs at
   launch). Failure -> "PROXY MISMATCH — import refused" (a person changing
   phones doesn't change country the same day). Duplicate import (a container
   with `importedFrom` == the original id exists) -> "DUPLICATE RESTORE"
   warning, import proceeds. The archive is extracted into a temp dir and only
   moved into `<app home>/redditbox/containers/<newId>` after all checks pass
   (no partial imports). New id = `<origId>-w<hex>`; the new profile preserves
   idfa/idfv/locale/tz/location/model (identity continuity) and the container is
   registered in the central store with `attest.origin = "worker-rekey"` (so
   dashboards can distinguish worker re-attest key consumption from factory),
   `attest.mode` = re-attest policy switch ("authentic" default / "off"),
   `push.enabled` = false, `importedAt`, `importedFrom`.
5. **Alerts** — failures land in the central store `alerts` array (types
   "STALE BACKUP", "WRONG PASSPHRASE", "PROXY MISMATCH", "DUPLICATE RESTORE",
   "CLOUD ERROR"); successes are NSLog only. All store writes post
   `com.redditbox.storeChanged` so the dashboard refreshes.

### Files

- `daemon/RBXCloudSync.h/.m` — all cloud logic (claim, export, import, list,
  crypto, tar helpers, action doorbell). Depends only on Foundation,
  CommonCrypto/Security and existing classes (RBXCentralStore,
  RBXContainerRegistry, RBXAppVersionMonitor, RBXDeviceCatalog).
- `prefs/RBXCloudListController.h/.m` — the Cloud pane (subpage pushed from
  RBXRootListController like RBXDashboardController).
- `cloud/` — Next.js website implementing the shared API contract
  (`/api/auth/register|login`, `/api/devices/pair|claim`, `/api/backups`).
- `daemon/main.m` starts `[RBXCloudSync sharedSync]`; `daemon/Makefile` +
  `tools/static_check.py` file lists updated.

### Shared API contract (device ↔ website)

Base path `/api`. Ciphertext is opaque base64; the server never decrypts.

| Method | Path | Auth | Body / result |
|---|---|---|---|
| POST | `/api/auth/register` | — | `{email, password}` → `{token, user}` |
| POST | `/api/auth/login` | — | `{email, password}` → `{token, user}` |
| POST | `/api/devices/pair` | Bearer user JWT | `{name, role:"factory"\|"worker"}` → `{deviceId, pairingCode}` |
| POST | `/api/devices/claim` | — | `{pairingCode}` → `{deviceId, token}` |
| POST | `/api/backups` | Bearer device token | `{containerId, ciphertext, iv, salt, checksum, createdAt, attestKeyUsed?}` → `{backupId}` |
| GET | `/api/backups?containerId=` | Bearer user JWT or device token | `{backups:[...]}` (no ciphertext) |
| GET | `/api/backups/:id` | Bearer user JWT or device token | full JSON including ciphertext/iv/salt/checksum |
| DELETE | `/api/backups/:id` | Bearer user JWT or device token | `{ok:true}` |

License/admin routes remain as an optional selling layer on the website; they
are not required for the device contract.

### Prefs container management (P6)

`prefs/RBXContainersListController` lists profiles, adds a container (daemon
`createContainer` via `com.redditbox.containerAction`), deletes, edits the
per-container proxy URL (shared pool file
`/var/mobile/Library/Preferences/com.redditbox.proxies.plist`), and toggles
per-container IDFA posture (`ids.posture` / `ids.idfa` on the profile).
SpringBoard's long-press menu also has **New container**.

Choice documented here: proxy pool used to live in the daemon's
`NSUserDefaults` (invisible to the Settings process). It now lives in the
shared plist so prefs, daemon, and cloud import all see the same upstreams.

---

## 17. Reddit API header/body rewrite (implemented)

OS-level spoofs (MG, serial, IDFA, IDFV, locale, timezone, location, battery,
sysctl, IOKit) do not cover the identifiers Reddit actually puts on HTTP
headers, GraphQL bodies, and analytics. `tweak/Network/RBXRedditAPIHooks.xm`
is that layer:

- **Headers** on reddit.com / redditmedia / snooguts / redditstatic / redd.it:
  `Client-Vendor-ID`, `x-reddit-device-id` / `x-redditdevice-id` ← `reddit.installId`;
  `User-Agent` ← real Reddit CFBundle version + profile iOS/model;
  `X-Dev-Ad-Id` ← profile IDFA; `Device-Name` ← `reddit.deviceName` (`Apple;<ProductType>`).
  `Authorization`, `x-reddit-loid`, `x-reddit-session` are **not** minted — isolated
  via keychain + path hooks + UserDefaults sidecar.
- **Bodies**: recursive JSON (and form-urlencoded) rewrite of `device_id` / `deviceId`,
  `installation_id`, advertising / aaid / reddaid / IDFA, install timestamps,
  platform device/os/language, screen w/h + font size, utc_offset, APNs token
  (blanked). Gated on a Reddit-signal key so unrelated JSON is not touched.
  HMAC: `setHTTPBody:` / header setters rewrite **before** Reddit signs, so
  `X-Hmac-Signed-*` is kept when it covers the spoofed body. Headers are
  stripped only as a fallback when the body changes *after* HMAC was already
  set (stale signature). We do not hook `CCHmac` or re-sign — no access to
  Reddit's HMAC key, and a custom TLS/HMAC stack would be fragile.
- **Protobuf / uploads**: `uploadTaskWithRequest:fromData:` / `fromFile:`
  rewrite JSON, form, and same-length UTF-8 IDFA/IDFV/install/push strings
  inside binary protobuf. Media and unknown blobs pass through. Length is
  never changed (protobuf varints stay valid).
- **Persisted session**: `NSUserDefaults` keys `installation_id`, `loid(s)`,
  `anonymous_loid`, `reddit_session`, push-token keys, … are pinned to
  `<container>/Library/Preferences/rbx.reddit.session.plist`. In the Reddit
  process every non-Apple suite is remapped (app groups drop the `group.`
  prefix so they land in the isolated sandbox; Branch / Firebase / Google /
  Crashlytics / Adjust / AppsFlyer / Kochava included). `NSGlobalDomain` and
  `com.apple.*` are left alone. Path hooks already isolate the container home.
  Residual: non-UserDefaults files under a real App Group container
  (`Shared/AppGroup`) are not path-rewritten.
- **Push**: registration still default-OFF (`RBXPushHooks`). The hardware APNs
  token is never returned to Reddit (nil / dropped when OFF; per-container
  SHA-256 dummy when a callback still fires). JSON/protobuf token fields are
  replaced with that dummy, not the real token and not a shared empty string.
- **DeviceCheck**: fail-closed. `DCDevice.generateToken` / `isSupported` are
  blocked when attest is OFF for the container **or** the DeviceCheck pref is
  OFF (default). No fake App Attest assertions. KeyId dedup + budget unchanged.
- **TLS / JA3**: same Reddit binary ⇒ same JA3. Safe jitter only: per-container
  TLS 1.3-minimum (max stays 1.3) and optional HTTP/3 off → HTTP/2 fallback.
  Pinning is untouched. Full JA3 randomization is an accepted residual.
- Pass-through when no profile is loaded. IMEI is not invented for these headers.
