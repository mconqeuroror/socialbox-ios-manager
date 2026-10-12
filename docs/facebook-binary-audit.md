# Facebook 578.1.0 binary audit

Phase A static audit, 2026-09-13, for `feat/socialbox-multiapp`. This is an
evidence baseline for Facebook support, not device acceptance or a statement of
complete isolation. Reddit's existing binary snapshot is unchanged.

## Input and reproducibility — FB-001

- App: `com.facebook.Facebook`, executable `Facebook`, version **578.1.0**, build
  **1063022819**, minimum declared iOS **15.1**.
- IPA SHA-256: `2cdaab3bd8bd0238660ea23b566b7bd7713121d996032bbc045d4066d2233e8a`;
  214,246,198 bytes; 2,688 ZIP entries.
- Supplied dump provenance: iPhone10,4, iOS 16.7.16, bagbak 5.1.2 / Frida 17.18.0,
  all-process dump mode. Prior private validation passed ZIP CRC and all encryption
  metadata checks. This audit did not connect to or modify the phone.
- Twenty arm64 Mach-O images: main, ten embedded frameworks and nine extensions.
  Every recorded encryption command has `cryptid=0`; all decoded structural
  references resolved without scanner errors.
- The full scanner enumerated 284,286 selector references, 53,421 class references,
  60,269 class definitions, 129,290 import records, 410,629 method-name strings and
  39,468 Swift type descriptors. Counts include records across images, not unique
  SDKs or observed calls.
- Main executable SHA-256:
  `dda58bddb0cf203554217628c81cc98d23b47ccf9174011c3500187d7510438f`.
- Main original signature XML entitlement blob begins at slice offset `0x13a5d51`;
  its DER entitlement companion is recorded separately and is not decoded.

[facebook-binary-evidence.json](leak-surface/facebook-binary-evidence.json) retains
per-image hashes, offsets, original declarations, literal candidates and bounded
topic examples. Every topic records its full matching count; examples cap at 32
per image and structural record kind. The complete structural JSON gzip stays in
private storage; its hash is recorded in the committed supplement. The IPA,
extracted binaries, raw device storage, account values and traffic bodies stay out
of Git. URL evidence preserves hostnames only, not paths or queries.

```sh
python3 tools/enumerate_leak_binary.py --self-test
python3 tools/enumerate_leak_binary.py PRIVATE_FACEBOOK.ipa \
  --output PRIVATE/facebook-binary-summary.json \
  --details-output PRIVATE/facebook-binary-full.json.gz
python3 tools/enumerate_facebook_binary.py PRIVATE_FACEBOOK.ipa \
  --details PRIVATE/facebook-binary-full.json.gz \
  --output docs/leak-surface/facebook-binary-evidence.json
python3 tools/test_facebook_binary_audit.py
```

The supplement validates the input IPA, generic scanner and per-image/slice hashes
against the private full scan before writing. Its parser checks signature bounds
and does not validate code-signing trust. Independent `nm -uj` and `otool -L`
comparisons are recorded in the [validation evidence](leak-surface/facebook-binary-validation.json).
All 125,788 unique-per-image names reported by `nm` are retained. The scanner adds
3,502 chained-fixup imports that `nm` does not list; their origin is explicit,
and this does not independently validate all fixup decoding. Linked dependencies
match after excluding each framework's recorded `LC_ID_DYLIB` self identity.
These checks do not validate call sites or active hooks.

## Platform and local app identity — FB-002, FB-003

Main selector references include `identifierForVendor` at `0xfc6208` and
`advertisingIdentifier` at `0xfc5bd8`. FBSharedFramework also references IDFV, and
the embedded Widevine framework references IDFV at `0x133f88`. These are actual
selector-table entries, not merely method-name strings. They do not prove which
object receives the message, whether it executes or whether a hook reaches it.

Selected literals include main `app_scoped_device_id` at `0xc05bae`,
`app_device_id` at `0xbe2237` and `analytics_device_id` at `0xbe2269`;
FBSharedFramework contains `com.facebook.analytics.device_id` at `0x5f5050c`.
The key names, storage locations, owners, types, generation timing, cache lifetimes
and relation to emitted data remain unobserved. No new default key or wire
replacement is authorized by a name match alone.

## Family identity and machine/session state — FB-004, FB-005

Main references `cachedFamilyDeviceIDWithConfiguration:SourceFile:SourceLine:` at
`0xfbbac0` and `familyDeviceIDWithConfiguration:SourceFile:SourceLine:` at
`0xfc5ac8`. FBSharedFramework defines `FBFamilyDeviceID` at `0x832e438`;
NotificationServiceExtension also defines that class at `0xc1d6b8`.
FBSharedDynamicFramework literals include `CROSS_APP_DEVICE_KEY` at `0x1472046`,
`LEGACY_DEVICE_KEY` at `0x1472075`, `legacy_device_key` at `0x1479def` and
`shared_device_key` at `0x1479e11`.

FBSharedFramework defines `FBMachineIDDataSource`, `FBMachineIDKeychainFetcher`
and `FBMachineIDKeychainPersister` at `0x832e448`, `0x832e450` and `0x832e458`.
It references `initWithMachineIDKeychain:` at `0x8938688` and
`logMachineIDStoreEventMachineID:currentMachineID:source:loginType:loginSource:`
at `0x8938690`. Main literals `mid` at `0xc1dc90` and `machine_id` at `0xc5fc35`
remain schema candidates. These names suggest investigation targets; they do not
establish which value is local, server-assigned, signed, tied to login or safe to
rewrite. Preserve authentication/session state until actual provenance is known.

## Keychain, defaults, app groups and cloud — FB-006, FB-007

Original main XML declares `keychain-access-groups = [T84QZS65DQ.platformFamily]`.
Main Info.plist independently declares `FBKeychainAccessGroup` with the same
value. The original application identifier is
`T84QZS65DQ.com.facebook.Facebook`, while the team identifier is `V9WTTPBFK9`;
the prefixes must not be conflated.

Original main app groups are `group.com.facebook.Facebook`,
`group.com.facebook.family`, `group.com.metaplatforms.family` and
`group.com.facebook.msysstorage`. It declares iCloud containers
`iCloud.com.facebook.Wilde` and `iCloud.com.facebook.Messenger.encryptedBackups`,
and ubiquity KV store `V9WTTPBFK9.com.facebook.Wilde`.

FBSharedFramework imports `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`
and `SecItemUpdate` at `0x97fc848` through `0x97fc878`. Actual selector refs
include `_keychainAccessGroup` at `0x890c698`, `_readStringFromKeychain:` at
`0x890c6a0`, `_writeString:toKeychain:` at `0x890c6a8`, `initWithSuiteName:` at
`0x8903280` and `containerURLForSecurityApplicationGroupIdentifier:` at
`0x890c718`. These support an audit of shared state; they are not observed reads
or writes. Effective clone entitlement stripping/remapping, data-root isolation,
access failure behavior and restore behavior require artifact/runtime evidence.

## Meta framework and SDK attribution — FB-008

Embedded framework directories are FBCameraFramework, FBFeedAttachmentsFramework,
FBRarelyUsedFramework, FBReactNativeProductsFramework, FBSharedDynamicFramework,
FBSharedFramework, SpotifyiOS, libavcodec, libavutil and
widevine_cdm_secured_ios. Eleven privacy manifests are preserved as declarations.
Structural names include FBAnalytics, FBFamilyDeviceID, FBAppAttestationKit,
FBMQTT, FBTigon, RCT, Odin and MetaEncryptedMessaging candidates.

Presence, class prefixes and privacy declarations do not establish SDK ownership
of an API call or data flow. Each contributing transport/storage path still needs
runtime call attribution; React Native/web/server configuration remains open.

## HTTP fields, host candidates and non-HTTP transports — FB-009, FB-010

Main literal candidates include `X-FB-Device-ID` at `0xbe381d`,
`X-FB-Family-Device-Id` at `0xbe41eb`, `family_device_id` at `0xbdf910` and
`X-FB-Integrity-Session-ID` at `0xc4bfe8`. Literal occurrence does not prove these
headers are sent, define their semantics, or justify modifying them. Request
compression, serialization, signed payload ordering and server-owned subtrees
require transport-specific observation before any schema-aware replacement.

Static URL hostnames provide candidate domain families `facebook.com`,
`fbcdn.net`, `facebook.net` and `fbsbx.com`: main has `api.facebook.com`,
`graph.facebook.com` and `secure.facebook.com`; FBSharedFramework includes
`gateway.facebook.com`, `rupload.facebook.com`, `scontent.xx.fbcdn.net`,
`connect.facebook.net`, `prefetch.fbsbx.com` and `www.fbsbx.com`. They can inform
an explicitly scoped host policy using exact DNS-label boundaries. They are not
an observed list of critical endpoints or proof that all egress uses these roots.
The evidence also contains Meta/Messenger/Instagram/WhatsApp and external static
hosts; allowing every static literal would be unjustified.

Main defines `FBMQTTManager` at `0xf7a540` and references `mqttHostName` at
`0xfcad98` and `mqttPort` at `0xfcada0`. FBSharedFramework imports `socket` at
`0x980efb8`, `connect` at `0x980ea78`, `send` at `0x980e4b8`, `sendmsg` at
`0x980ef58` and `CFStreamCreatePairWithSocketToHost` at `0x97f87f8`.
Tigon, Proxygen/Liger and QUIC/Fizz candidates are enumerated separately.
These invalidate an assumption that NSURLSession hooks alone cover Facebook;
actual MQTT/TLS/UDP paths and proxy enforcement remain unverified.

## Background, push, VoIP and extensions — FB-011

Original main Info.plist declares `bluetooth-peripheral`, `external-accessory`,
`fetch`, `processing`, `remote-notification`, `voip` and `audio` background modes.
Original XML declares production APNs, multicast, HotspotConfiguration and
Wi-Fi information entitlements. These are declarations, not proof of background
execution or effective clone permissions.

Nine extensions are BroadcastUploadExtension, FBLockscreenWidgetExtension,
IntentsExtension, NotificationContentExtension, NotificationServiceExtension,
NotificationsWidgetExtension, ShareExtension, VideoWidgetExtension and
WidgetExtension. NotificationServiceExtension independently contains family ID,
keychain and socket references. Removed extensions form a packaging boundary
only after the built IPA is inspected; equivalent main-process features remain
possible. Fresh launch, background/foreground, push/VoIP wake, stop, lease expiry
and restored profile admission require device acceptance.

## App integrity, DeviceCheck and App Attest — FB-012

Main imports `DCAppAttestService` at `0x1229658`, defines
`DCAppAttestDeviceAttestationService` at `0xf7b2f8` and `DeviceCheckKeyManager`
at `0xf7b308`, and references `generateAssertion:clientDataHash:completionHandler:`
at `0xfd1c48`. FBSharedDynamicFramework references
`generateKeyWithCompletionHandler:` at `0x1aa44d0` and
`attestKey:clientDataHash:completionHandler:` at `0x1aa44d8`.
FBSharedFramework defines `FBAppAttestationStorage2` at `0x832eeb0`.

The original main XML contains no `com.apple.developer.devicecheck.appattest-environment`
key. This is a bounded declaration observation, not absence of attestation usage;
DER has not been compared and actual API behavior remains unknown. Renamed bundle
identity, signature, local key storage, restored keys, reinstall markers and
server validation may affect compatibility. Do not forge attestation results or
replace server-owned assertion material. Record actual support/result codes and
login behavior using disposable profiles before declaring Facebook ready.

## User agent and browser state — FB-013, FB-014

Main references `initDefaultConfigWithProxyUserAgentFormattingBlock:sandboxProvider:`
at `0xfca6c0`. FBSharedFramework references `userAgent` at `0x891ecb0` and
`buildUserAgentWithNonViewableType:enableSafariTag:enableSafariUserAgentSuffix:enableShortestUserAgent:fixIncorrectUserAgent:`
at `0x891e500`. These identify multiple UA construction candidates; no emitted
Facebook UA shape, caller coverage or consistency with generated device fields
has been established.

WKWebView, website data, cookie storage, web authentication and pasteboard
candidates are inventoried separately. Safari/authentication service state,
same-account restore semantics and first-run browser/cookie behavior remain
unverified. OS sandbox and API hooks require separate runtime evidence.

## Runtime acceptance and residual limits — FB-015, FB-016

No instrumented first-run clone, paired A/B local storage comparison, keychain
observation, same-identity restore, cross-app switch, Facebook login, actual UA,
HTTP/MQTT/QUIC capture, background wake or attestation acceptance occurred in this
static audit. Every such row stays unverified. Static enumeration does not prove
Facebook readiness, unlinkability, no leaks or compatibility.

Acceptance must bind the source IPA and built package hashes, iPhone/iOS, profile
identity, fresh-versus-restored state, lifecycle transition and capture interval.
Record key names/types and private per-run fingerprints with provenance; keep
credentials and raw payloads private. Resolve caller-to-storage-to-transport
attribution before expanding mutation policy. A repeated value may be legitimate
server/session state or a shared constant; its semantics decide the finding.

The stable [FB-001–FB-016 ledger](leak-surface/facebook-inventory.json) follows the
existing evidence schema. It is intentionally distinct from Reddit's rows, and
it does not silently close unresolved Reddit acceptance items. Missing imports,
selectors or strings are never an absence proof for runtime-generated names,
remote configuration, web content or future builds.
