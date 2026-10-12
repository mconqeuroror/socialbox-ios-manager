# Original engine admission: concrete SocialBox integration boundary

Status: **three independent admission consumers recovered; unchanged engine
does not trust the existing SocialBox signer**. This is a bounded follow-up to
[the response/persistence contract](RECOVERED_LICENSE_CONTRACT.md), not another
authorization module. No original executable was run, no service was contacted,
no device was modified, and no signer, trust pin or verification result changed.

## Decisive public-key compatibility check

The injected engine's token verifier obtains a compiled public pin through
`FUN_001496d0`, reached by the once-initializer at `FUN_0033b708`. The retained
`SocialBox.dylib.c:234715`–`:234887` reconstructs the wrapped public-key bytes and
stores the resulting PEM in `DAT_003cd510`. The pin comes from compiled bytes,
not the license reply or a configurable SocialBox origin.

The public pin was reconstructed with a source-owned byte reader and the
documented operations visible in that initializer, then parsed and normalized
to SPKI DER with the system OpenSSL. The existing SocialBox **public** PEM at
`work/private-release/license/license-public.pem` was normalized the same way.
No private signing key or device token was read. Results:

- Original engine SPKI SHA-256:
  `fb408ece548e9cf806210836031bd424c1d125fd8b1d0a6f3321bb489be8004d`.
- Existing SocialBox SPKI SHA-256:
  `088d2957221651db5a4c0c27853fed50be4743bbdc7efdd467d3c0fa75082788`.
- Keys are **different**. These are SPKI fingerprints, not SocialBox's PKCS#1
  DER `kid`; comparing those different encodings directly would be incorrect.

Private reproducible evidence is
`work/private-socialbox-adoption-2026-09-20/local-tools/license-recovery/compare_public_pins.py`
and its `output/public-pin-comparison.json`. The original public-key material
was not copied into the repository. The check establishes a concrete trust
mismatch: changing reply field names cannot make a SocialBox signature pass
the unchanged original engine verifier.

## Admission consumer 1: the application

`AppDelegate::_sF2` at `0x10003a010` is an instance `B16@0:8` method
(`socialbox-app-arm64-objc-metadata.txt:34`–`:36`). It reads `_Xr9c::_sA1`,
requires a nonempty stored license key, and requires nonnil `_sA4`/`_sA3`
token/signature values. It is a **cache-presence predicate**, not a signature
verifier. Fresh private output `SocialBox-10003a010.c:15`–`:25` confirms this.
Returning a source-owned grant from this Boolean alone would skip the original
contract and would not authorize the injected engine.

The periodic instance method `_sF3` at `0x10003c608` has ABI `v16@0:8`
(same metadata `:61`–`:63`). Its reconstructed body includes integrity checks
and eventually invokes `_sF1` (`SocialBox-10003c608.c:7462`), which calls the
original `_Xt2w::validateLicenseWithServer:` path. It also conditionally checks
original method implementations if legacy-named selectors are present
(`:2559`–`:2571`, `:6546` onward). Which legacy selector aliases resolve on a
live installation is NOT_RUN; the static condition must not be presented as
an observed device failure.

Consequently, replacing only the activation screen/completion or cache Boolean
does not replace periodic validation or establish equivalent trust behavior.
`showMainApp` is navigation, not an authorization extension point.

## Admission consumer 2: the daemon's authenticated session

`_Zy3d::currentWSStateWithReply:` at `0x100089630` has ABI `v24@0:8@?16`
(`output/secretsauced-admission-objc.txt:425`–`:427`). Its callback reports
connection state, **`licenseValid && serverVerified`**, and the device ID
(`secretsauced-100089630.c:17`–`:29`). The getter ABIs are `B16@0:8` at
`0x100089828` and `0x100089868` (metadata `:533`–`:559`).

`auth_success` updates license/session state as documented in LIC-06. Separately,
`handleServerChallengeResponse:` at `0x100065d68` has ABI `v24@0:8@16`
(metadata `:359`–`:361`). Its signature verification result precedes setting
server verification and calling the next session phase `_mGg`
(`secretsauced-100065d68.c:2015`–`:2027`, `:2116`). Rejection paths disconnect.
`_securityTimerTick` is another independent instance `v16@0:8` method
(`0x100076d08`, metadata `:377`–`:379`), not part of HTTP response projection.

A valid SocialBox installation grant does not demonstrate possession of the
original hosted service's challenge key or existence of its authenticated
session. Setting `licenseValid`/`serverVerified`, forging `auth_success`, or
changing this status callback would conflate those different authorities.
The original cloud/automation session must remain explicitly separate.

## Admission consumer 3: the injected local engine

Fresh private `SocialBox.dylib-000bbd88.c` recovers a configuration-reload C
callback `void FUN_000bbd88(void)`, with no application-supplied grant argument.
It is referenced through the original global block at `0x00390d10`.

Its actual sequence is:

1. Reload original configuration and read the enabled setting.
2. Read `_Xr9c::_sA4` and `_sA3`, the original stored token/signature.
3. Decode the signature as hexadecimal bytes, encode the token string as
   UTF-8, and import the compiled original public key.
4. Verify `kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256` over those exact
   token bytes (`SocialBox.dylib-000bbd88.c:383`–`:387`). This is not JWT
   `header.payload` verification and does not accept the reply's `success` flag.
5. Combine verification with enabled state before enabling the local hook
   admission flag, then consider path-manager initialization/active context
   (`:400` onward). `_Xk2n::_sD6` at `0x0024fc08` is the predicate
   `activeContainerID > 0`, not a completed-switch/isolation receipt.
6. On failure, clear admission flags (`:498`–`:499`). Other hook paths read
   these flags; the retained file contains actual consumers at
   `SocialBox.dylib.c:3736`, `:5345`, `:10015`, `:138353` and subsequent paths.

The callback also performs configuration/cache work. Replacing its entire
body with a Boolean SocialBox check would discard behavior. Patching its
global flags or the shared `SecKeyVerifySignature` import is not a safe
equivalent integration. This callback is one proven consumer, not a claim
that all constructor/service/integrity admission consumers have been mapped.

## What a legitimate completion needs

There is **no established injectable grant API** accepting an independently
verified SocialBox entitlement while preserving these original checks.
The exact local blockers are now known rather than inferred from missing
source: a different compiled engine pin, different signed message format,
separate original session/challenge state, and periodic validation consumers.

The existing SocialBox JWT also signs installation status/binding/expiry, not
the original `products`, `tier`, addon quotas or partner policy. Those fields
drive distinct original feature accessors such as `isProductEnabled:` at
`0x1002868bc`, `isCloudAddonEnabled` at `0x100286f44`, and partner allowances.
An active SocialBox status must not silently grant every original feature or
claim that its old hosted features are connected.

With this candidate's original trust pins/checks retained, the concrete
external dependency is legitimate original-backend authorization for those
original consumers. Existing SocialBox responses cannot manufacture it. This
does not require reading or sharing a private signer; a compatible authorized
service can issue its own grant through its existing API.

For a **SocialBox-only** engine, a buildable implementation of the engine
admission/config reload/initialization paths and app/daemon validation/session
boundaries, including their integrity integration, is still needed. Original
source would shorten that work; its loss does not make reconstruction
impossible. This candidate has not reconstructed those consumers. A complete
source-level integration would verify the existing SocialBox pinned
JWT at each local admission boundary, preserve expiry/revocation/device binding
and configuration generations, map only explicitly licensed local features,
and retain the original remote session as a separate unavailable/connected
state. Required proof includes bad signature, wrong device, expiry, revocation,
restart, disabled state and configuration-change denial in app, daemon and
injected engine, followed by on-device tests. It cannot honestly be implemented
as an always-valid callback or a token-store write.

No speculative Authorization module was added in this pass. The verified
source-owned exchange remains unlinked until there is a legitimate consumer
boundary; runtime acceptance remains **NOT_RUN**.

## New evidence fingerprints

All fresh exports remain private under the recovery output directory named in
LIC-01; no original binary, wrapping material or full pseudocode is committed.

- `SocialBox.dylib-000bbd88.c`:
  `e70a6bd1e71c21525b438a08b88171548c61c647f3297beaddb344739ca64d39`.
- `SocialBox-10003c608.c`:
  `3afef5c5c194a4f6cd98c4898f5a852bcadaf0914a448bca3ca59543032053fb`.
- `secretsauced-100089630.c`:
  `2b47992d1f651dc3e1a0d9677653aa16f977bd5f8f5877083fc0a354f62514a0`.
