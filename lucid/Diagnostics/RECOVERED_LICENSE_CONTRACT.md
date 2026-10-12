# Recovered original licensing contract

Status: **original request, response and immediate persistence paths statically
recovered; SocialBox-to-original-engine authorization interoperability NOT_RUN**.

This contract concerns the supplied SocialBox **3.1.0-1** binaries. Recovery did
not execute those programs, contact their services, read device credentials, or
modify authorization checks. It does not authorize calling the original
approval methods with invented responses. The source-owned SocialBox exchange
in `lucid/Authorization/` remains a separate, unlinked component.

The central distinction is observable in both response processors: their
success callback can run without a signed token/signature pair. It reports a
response outcome, not a verified grant accepted by every original component.
The persistence methods return no durable authorization receipt either.

## Evidence identity and recovery

Addresses below are for the **arm64** slice. The original complete application
SHA-256 is `e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0`;
`secretsauced` is
`e21659cbacd5e74399cfcd0d3e370dbbb8dca395a23266577dff25c85d033a25`.
Original files remain under the private extraction
`work/private-socialbox-adoption-2026-09-20/socialbox-3.1.0-1/`.

Previously omitted functions were recovered on 2026-09-21 using a private copy
of the saved analysis project, a source-owned export script, normal C
decompilation with syntax-tree output, and `-noanalysis -readOnly`. No
archive-provided scripts/plugins were executed. Official pinned tools were:

- Ghidra 12.1.3, official release archive SHA-256
  `93a5d11a9ad510622acaaf908c556a7b9b764d338e78a7567f3689bf5081fd54`.
- Temurin 21.0.12.1+1, official macOS arm64 archive SHA-256
  `3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998`.

The official Ghidra C++ decompiler was built locally for macOS arm64. Fresh
private evidence is in the extraction parent's
`local-tools/license-recovery/output/`. In this document `app-ADDRESS.c` means
`SocialBox-ADDRESS.c`, and `daemon-ADDRESS.c` means
`secretsauced-ADDRESS.c` there. Same-line `.annotated.c` copies resolve selector
stub names from the archive's selector index; they are not buildable source.

Pinned recovered outputs:

- `app-10016285c.c`:
  `173772ea13714da24a1ef55be0259f04d574425e6be270d07cca5f8967beea3f`.
- `app-100164e9c.c`:
  `3a53a10e8167bae6685ce60b4f97d286127fc7f58f160bb7347db75b043a4131`.
- `app-1001d6158.c`:
  `adb83d56b11e9c0f77053f832ea18e597b9944956bfa7cf274402df1ab97dde5`.
- `daemon-10004990c.c`:
  `3bd3af8b1309fd2c6426fe489b19498755843a1862cdcda5ab4047ac81dd1ae8`.

Obfuscated literal **names and fixed paths** were recovered by a byte-only
decoder implementing the observed static loop; originals were never loaded
or called. Results are private `license-literal-names.json` and
`daemon-license-literal-names.json`. No token, key material, account, or session
value is reproduced here. A decompiler's inferred argument count/types are not
authoritative: Objective-C metadata determines the ABI.

## LIC-01 — Typed method boundaries

The extraction parent's `socialbox-app-arm64-objc-metadata.txt`, produced with
`otool -arch arm64 -ov`, records:

- `_Xm8u::processLicenseResponse:error:httpResponse:licenseKey:completion:`
  at `0x10016285c`, metadata lines 33065–33068:
  `v56@0:8@16@24@32@40@?48`. This is an instance void method taking five
  object/block arguments: response data, error, HTTP response, license key,
  completion. Uses support `NSData`, `NSError`, `NSHTTPURLResponse`,
  `NSString`, and a block; the encoding itself only establishes object types.
- `_Xm8u::persistAuthPayload:licenseKey:products:` at `0x100164e9c`,
  metadata lines 33069–33071: `v40@0:8@16@24@32`. Its first argument is the
  **deviceToken value**, not the whole response dictionary. The remaining
  arguments are the supplied license key and products collection.
- `_Xt2w::processHTTPLicenseResponse:statusCode:licenseKey:completion:`
  at `0x1001d6158`, metadata lines 36326–36328:
  `v48@0:8@16q24@32@?40`. Arguments are response data, signed 64-bit HTTP
  status, license key, completion block.

Observed completion invocations carry `(BOOL success, object message/error)`.
There is no returned signed grant, storage generation, or daemon receipt in
that completion shape. The extra argument guessed in some pseudocode
prototypes must not be copied into an implementation.

## LIC-02 — Original request contract

`_Xm8u::validateLicenseWithServer:deviceId:completion:` at `0x100160394`
constructs a JSON request with exactly these observed fields:

- `licenseKey`: caller-supplied key.
- `deviceId`: caller-supplied device identifier.
- `product`: literal `socialbox`.
- `version`: main bundle `CFBundleShortVersionString`, fallback `0.0.0`.

Evidence: `app-100160394.c:122`, `:193`, `:256`–`:268` and decoded literals
at `0x100388271`, `0x10038827b`, `0x100388283`. The fixed endpoint literal is
`https://secretsauceautomations.com/api/license/validate`
(`0x10038828a`, same output `:282`). The request uses POST, JSON content type
and a 15-second timeout (`:338`, `:469`–`:471`). It can use the existing helper
proxy at `:487`. The direct transport at `0x1001d2530` uses an ephemeral
session, the same timeout, and `User-Agent: SocialBox/1 iOS`
(`app-1001d2530.c:46`, `:328`–`:342`).

This is a recovered historical endpoint, not a service contacted or a verified
currently available service. The meaning of its `deviceId` cannot be replaced
with SocialBox's installation UUID by name similarity: the original daemon
also has a separate `readDeviceSerial` method at `0x100063d10`.

## LIC-03 — Activation response, 0x10016285c

Transport error, absent data, JSON parse error or a nil parsed object fail the
completion (`app-10016285c.c:60`–`:74`). The code then reads `success` through
`boolValue`, plus `message` and `error`. It does not establish comprehensive
top-level dictionary/value-shape validation. The HTTP-response parameter is
not subsequently used in this recovered body.

On a false `success`, top-level `activatedDevices` and `maxDevices` can update
display configuration before the failure callback. On success, nested
`license.activatedDevices` and `license.maxDevices` map to
`LicenseActivatedDevices` and `LicenseMaxDevices` (`:297`–`:444`).

The successful branch projects response fields into original configuration:

- `tier` → `LicenseTier`; absent field defaults to `standalone`
  (`:447`, `:529`).
- `products` → `LicenseProducts`; absent field defaults to `["socialbox"]`
  (`:452`, `:599`). The fallback is an actual constant array at `0x100445ed0`,
  count 1, object storage `0x1004371a0`, string `0x1003f32e0` whose literal
  bytes at `0x1003669ac` are `socialbox`.
- `expiresAt` → `LicenseExpiresAt` (`:600`–`:753`). There are string/nonempty
  and null checks here, not a general typed grant validator.
- `features` → `LicenseFeatures` (`:458`, `:836`).
- `addons` → `LicenseAddons` (`:838`, `:911`).
- `partner` → `LicensePartner`, treating explicit null as removal
  (`:918`–`:994`).

Dictionary comparisons can schedule feature/addon/partner UI notifications
(`:1087`–`:1097`). These are display/configuration changes, not signature
verification. Only `tier == "automation"` plus a nonempty `deviceToken` calls
`persistAuthPayload:licenseKey:products:` (`:1100`–`:1102`).

The exact fields `signedLicenseToken` and `licenseSignature` are read at
`:1173` and `:1243`. If both have nonzero length, the code calls
`_Xr9c::_sA5:signature:` then `_sA2:` with the license key (`:1244`–`:1247`).
The completion is then **YES, nil even if that pair was absent** (`:1249`).
This observation is limited to this method; it does not show that downstream
original authorization checks can be omitted.

## LIC-04 — HTTP revalidation response, 0x1001d6158

This second processor rejects missing data/invalid JSON (`app-1001d6158.c:61`,
`:69`), reads `success` through `boolValue` (`:73`–`:74`), and updates nested
and top-level device counts (`:75`–`:78`, `:225`, `:299`). The status-code
argument has no demonstrated validation use after its declaration. A failed
response uses its error or the `License invalid` fallback (`:373`–`:450`).

Success projects `tier`, `products`, `features`, `addons`, `partner` into the
same configuration keys (`:454`–`:847`), with the same absent-tier/product
defaults. **This body has no `expiresAt` handling.** It cannot be substituted
for the activation parser with a claim of identical behavior.

Unlike activation, a nonempty `deviceToken` is persisted without an automation
tier condition (`:953` onward). It updates `AuthToken` and, only if the supplied
key is nonempty, `LicenseKey` in SecretSauce configuration (`:1104`–`:1178`).
An atomic successful write plus a changed token posts the daemon reload
notification (`:1180`–`:1233`). This path does not populate all of LIC-05's
activation metadata.

The signed pair is read at `:1305`/`:1375`, stored if both are nonempty at
`:1378`, and a nonempty key can be stored at `:1381`. Completion succeeds at
`:1385` without requiring the pair. A legitimate new adapter must enforce its
own HTTP-status, typed-shape, signature and binding contract rather than copy
these display-response success semantics.

## LIC-05 — Three distinct persisted contracts

**SecretSauce daemon configuration.** `persistAuthPayload:licenseKey:products:`
selects `/var/jb/var/mobile/Library/SecretSauce/config.plist` for the detected
rootless layout or `/var/mobile/Library/SecretSauce/config.plist` otherwise.
It creates the parent, reads a mutable existing dictionary or starts empty,
then writes these names (`app-100164e9c.c:300`–`:394`):

- `AuthToken` ← deviceToken argument.
- `LicenseKey` ← supplied license key.
- `ActivatedProducts` ← supplied products.
- `ActivatedAt` ← current date.
- `DeviceAlias` ← current device name, fallback `Unknown`.

The write is atomic. `com.secretsauce.daemon.reload` is posted only when the
write succeeds and the token changed (`:396`, `:473`). Directory failure
returns early; the void method does not return a persistence acknowledgement.

**SocialBox display configuration.** `_Xr9c::plistPath` at `0x100276618`
resolves the base `/var/mobile/Library/SocialBox/config.plist` through the
original jailbreak path logic. It holds the `License*` display fields listed
above. A tier/products label is not a grant.

**Protected SocialBox license store.** The `_sB4` initializer at `0x10027b790`
uses base `/var/mobile/Library/SocialBox/license.plist` and the original jailbreak
prefix resolver. `_sB2:forKey:` at `0x10027bc48` performs dictionary writes,
removes null values, writes atomically and sets the file to mode 0444. It
returns no checked durable-write receipt.

`_sA5:signature:` at `0x100282dec` encrypts token and signature separately
using random IVs and writes `enc_token`, `enc_sig`; it clears legacy
`SignedLicenseToken`, `LicenseSignature`, and writes `_plist_seal` and
`_seal_version` 2 (`app-100282dec.c:179`, `:250`, `:320`, `:391`, `:486`,
`:558`). This is an **at-rest protection writer**, with no
`SecKeyVerifySignature` call in that method. `_sA4`/`_sA3` at `0x100284024` /
`0x100284834` read/decrypt these values with seal-version/legacy handling.
`_sA2:` at `0x10027be64` stores the protected license key as `_elk_x9m2` and
clears the legacy `LicenseKey`; `_sA1` includes migration/device-dependent
derivation. None is a documented compatibility conversion for SocialBox JWTs.

## LIC-06 — Daemon approval is a separate protocol

`_Zy3d::readLicenseKeyFromConfig` at `0x10006385c` reads the SecretSauce
configuration's `LicenseKey`, with a rootful fallback and nonempty-string
check (`daemon-10006385c.c:186`–`:192`).

The formerly omitted `_Zy3d::_m0a:` at `0x10004990c` was also recovered. It
parses an incoming JSON string and its `type` (`daemon-10004990c.c:149`–`:194`).
An `auth_success` branch (`:1424`) updates connection state and optionally
persists a nonempty `deviceToken` (`:2125`–`:2128`). A distinct `device_token`
branch does the same (`:2603`–`:2609`). `auth_pending`, `auth_error` and
`license_revoked` are distinct decoded message types. These are handlers in
the original socket protocol, not a public grant API to invoke with synthetic
JSON after another service says success.

`persistTokenFromApproval:` at `0x100064a10` first updates the cached token and
then dispatches disk work asynchronously (`daemon-100064a10.c:24`–`:35`). The
worker at `0x100064b48` transforms its supplied token through an existing
helper, writes `AuthToken` and `ActivatedAt`, serializes/writes the plist, and
only after a successful write updates daemon state (`daemon-100064b48.c:47`,
`:117`–`:129`). The transformation is not asserted to be plaintext identity.
There is no completion returning a verified grant/persistence generation.

The original stack separately verifies signed challenges: app
`sendServerChallenge` at `0x1001bc08c` generates a nonce;
`handleServerChallengeResponse` at `0x1001bc4bc` verifies an RSA/SHA-256
signature before setting server verification state. Retained original
`decompiled/SocialBox.c:137338`, `:138665`–`:138686` and daemon
`decompiled/secretsauced.c:9471` show the challenge/signature boundaries.
Additional app key-exchange/challenge-result methods at `0x1001c68f0` and
`0x1001cce24` retain verification paths. This pass did not establish that the
original trust pins, signed payload representation, device binding or session
protocol accept the existing SocialBox signer's output.

## LIC-07 — Legitimate integration seam and remaining evidence

The existing SocialBox contract is different: `RBXLicenseGuard` claims or
validates an installation identity with a fresh nonce; the service returns
`licenseToken`. `RBXLicenseToken` verifies an RS256 JWT with its expected key
ID and `v`, `aud`, `iss`, `sub`, `deviceBinding`, `keyFingerprint`, `nonce`,
`status`, `iat` and `exp` constraints. Its audience is `redditbox-device`.
See `daemon/RBXLicenseGuard.m`, `daemon/RBXLicenseToken.m`, and
`cloud/src/lib/license-signing.ts`. An original `deviceToken`, original
`signedLicenseToken` + `licenseSignature`, and SocialBox `licenseToken` are
three different contracts; no byte-compatible mapping was established.

The safe implementable unit is a source-owned, typed, fail-closed SocialBox
exchange/verification adapter plus an immutable projection of **its own**
verified state. It can be tested offline against the existing signer contract.
The committed but unlinked `lucid/Authorization/LBXLicenseExchange` implements
that separate unit; its tests do not prove original-engine authorization.
This recovery supplies field names and persistence side effects, not a
permission to write that JWT into original stores or call approval callbacks.

Actual engine integration still needs one of these legitimate boundaries:

- A verified original-side signed-response and device-binding contract that
  the authorized existing server can issue, including its trust-pin/session
  compatibility; then device evidence that the app, daemon and injected
  components accept it through their existing checks.
- Or a source-owned authorization boundary in the engine with equivalent
  checks, an explicit migration contract and testable consumers. The supplied
  compiled archive alone is not such source.

Locally recovered request shapes, callback ABI and file formats are no longer
missing inputs. Local identity generation also exists and is not classified
as requiring an absent remote generator. What remains unproven is authorized
interop with the original trust/session consumers, durable approval, and
runtime end-to-end behavior. Until then the original authorization remains
unchanged; engine readiness and interoperability remain **NOT_RUN**.
