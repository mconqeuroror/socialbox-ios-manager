# Container profile schema (v1)

Each container has one JSON profile at
`/var/mobile/Library/Preferences/com.redditbox.profiles/<containerId>.json`.

The daemon generates profiles (`RBXProfileGenerator`) and writes a derived
`mgOverrides` dictionary: a flat `{ MobileGestaltKey: value }` map covering the
known identity-bearing fields from the profile sections. Unknown sensitive keys
are blocked rather than passed through. The tweak consumes `mgOverrides`
(+ direct paths like `proxy.url`, `ids.*`, `timing.*`, `reddit.*`), so hook answers stay O(1)
and exhaustive.

## Sections

- `profileVersion` — schema version
- `containerId` — matches filename
- `identityCustomization` — `mode=random|manual` plus last pre-use update time.
  The launcher may regenerate or manually edit a coherent identity only before
  the container's first launch. Afterwards identifiers are frozen; only
  explicitly warned compatibility policies may change.
- `app` — immutable clone binding: `architecture=clonedApp-v2`,
  `sourceBundleIdentifier=com.reddit.Reddit`, deterministic
  `bundleIdentifier`, registered `bundlePath`, unique `keychainAccessGroup`,
  and `cloneState=ready`. The daemon refuses launch if signed bundle metadata
  does not match these values or lacks `SBAppTags=hidden`,
  `RBXLauncherOnly=true`, and clone metadata `launcherOnly=true`.
- `device` — model/OS/screen/region/language/timezone/carrier/location (all geo-consistent);
  `productType` is pinned to the REAL device family (B1); `location` is
  `{ city, lat, lon }` from the proxy country's `countryCities` catalog (C3)
- `serials` — UDID, serial, IMEI, MEID, ICCID, MACs, MLB, platform UUID
- `ids` — `posture` (`random` | `zeroWithATTDenied`), `idfa`, `idfv`; for the zero
  posture `idfa` is the all-zeros UUID and ATT reports denied (A5/A6, D3)
- `timing` — `bootTimeOffsetSeconds`, `batteryOffsetPercent` (-8…+8, B5)
- `proxy` — `url`, `country`; optional cloud-managed
  `rotationAuthHeader` / `rotationAuthValue` override the global rotation API
  header for this profile
- `security` — `appAttest` and `deviceCheck`, each `blocked` (default) or
  `enabled` (explicit login-compatibility exception); `localNetworking`,
  `sensorAccess`, `networkMetadata`, and `thirdPartyNetwork` default to
  `blocked`; `strictTiming` defaults to `enabled`. Every relaxation is
  per-profile and takes effect after relaunch.
- `reddit` — wire-identity for the Reddit API / analytics layer (not MobileGestalt):
  `installId` (UUID, Client-Vendor-ID / x-reddit-device-id / device_id),
  `installTimestampMs` (stable ms epoch, generated at profile create),
  `deviceName` (`Apple;<ProductType>` for the Device-Name header),
  `externalInstallationId` (UUID),
  `screenWidth` / `screenHeight` (must exactly match `device.screen`),
  `fontSize` (`16` / `17` / `19`). Optional `userAgent` override; otherwise the tweak
  builds `Reddit/<CFBundleShortVersion>/<CFBundleVersion> (iPhone; iOS <profile>; Scale/…; <ProductType>)`.
  Before first use, a manual change to the Reddit model, iOS version or screen scale
  clears this override so the runtime rebuilds it from the selected tuple and
  installed app metadata. Unchanged tuples and security-only edits retain it.
  IMEI is **not** sent on these headers.
- `validation` — `proxyCountry`, `geoConsistent`, plus validator output on last check
- `mgOverrides` — generated flat MobileGestalt key map, e.g.:

```json
{
  "UniqueDeviceID": "00008101-0A1B2C3D4E5F6A7B",
  "SerialNumber": "F2LXK0Q2HQ",
  "InternationalMobileEquipmentIdentity": "356728110123456",
  "WifiAddress": "A4:83:E7:12:34:56",
  "BluetoothAddress": "F0:18:98:65:43:21",
  "ProductType": "iPhone14,2",
  "ProductVersion": "17.4.1",
  "BuildVersion": "21E236",
  "DeviceName": "Alex's iPhone",
  "UserAssignedDeviceName": "Alex's iPhone",
  "GSDeviceName": "Alex's iPhone",
  "MobileSubscriberCountryCode": "310",
  "MobileSubscriberNetworkCode": "260",
  "IDFA": "8C1F…",
  "IDFV": "3B7A…"
}
```

Rules:
- Fields are **immutable after first use** (serial/UDID/IMEI/IDFA/IDFV drift is
  a red flag). Before first use, **Coherent Random** regenerates the complete
  set. **Advanced Manual** accepts expert overrides only after daemon
  validation and cross-container uniqueness checks.
- Product type and iOS version form a synthetic catalog identity, including in
  manual mode. The validator checks that tuple; it does not require physical
  hardware equality. Real capabilities and unhooked APIs can still reveal the
  physical device, so a consistent tuple is not proof of indistinguishability.
- Country, locale, timezone, carrier, city and model region must agree with the
  assigned/last-observed proxy country. A mismatch is shown in the launcher and
  blocks both saving and network activation.
- `mgOverrides` is regenerated on every daemon write. The tweak reads the
  daemon-synchronized copy inside its own OS data container, falling back only
  to the profile embedded and signed into that clone.
- MG capability keys (e.g. `HasAppleNeuralEngine`, camera capabilities) are **not**
  in `mgOverrides` — they must stay real so the app doesn't crash or behave oddly.
- Cloud backups preserve profile metadata and app files, but do not export
  keychain or Secure Enclave credentials. The launcher requires login verification
  after import. Ordinary device tokens can access only their own device's backups;
  cross-device transfer requires a separate owner-authorized contract.

Phase-3 compatibility: `security.systemClipboard` accepts `blocked` (default,
including absent legacy values) or `enabled`. Enabling it deliberately exposes
the system clipboard to that profile for password/code paste; it is not an
isolated clipboard. Apply stops the clone, and the policy takes effect on relaunch.
