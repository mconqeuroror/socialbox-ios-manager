# Source-owned SocialBox licensing

Leak-Surface: CLOUD-001

The independent implementation is the source stack built by
`scripts/build-mac.sh`: `launcher/`, `daemon/`, `tweak/`, `shared/`, and
`network-extension/`. It does not build or load the recovered `lucid/` engine,
its AppDelegate, license caches, keys, callbacks, helper service or endpoints.
It is a replacement implementation, not an authorization patch for the recovered
binary. The recovered package on the phone is a different implementation.

## Admission

1. The launcher constructs only its license screen until a fresh daemon grant
   is available. Revocation removes the entire workspace, including sheets.
2. The daemon obtains an installation UUID from its own ThisDeviceOnly Keychain
   group. It activates against the existing SocialBox cloud and verifies RS256
   with the existing compile-time public pin, nonce, origin, device ID, binding
   and key fingerprint. No server boolean authorizes access.
3. The same verified grant supplies the daemon's monotonic traffic entitlement.
   The container launch sequence separately requires network closure, process
   termination, managed installation and proxy/firewall acceptance. Licensing
   cannot skip those steps. No original-engine admission callback is involved.
4. A saved pairing is reused for validation/re-activation. A UUID and key alone
   cannot obtain an already issued credential. Revocation and expiry lock access;
   an existing signed offline grant cannot be extended by an offline failure.

The queue dispatcher checks this authority before resolving selections, reading
profiles, synchronizing Cloud or invoking a mutation. Unknown actions require a
grant too. A locked refresh returns local state without entering Cloud sync.
Activation/validation, traffic closure and diagnostic collection remain available
while locked. Direct `provision-clone` requires the same grant; root-only
`migrate-clones` remains a closed-state upgrade/recovery operation. This is request
admission; long-running network launch still has its separate live lease checks.
`tools/test_license_dispatch.py` executes the shipped dispatcher with inert
services and a mocked grant: 166 assertions pass, and the first unauthorized
creation-draft assertion failed before the fix.

Fresh installations now select `https://redditspoof.vercel.app`. Explicit invalid
configuration stays invalid instead of silently switching origins. The unused
legacy preferences source also has no external default license host. Data keys
and historical compatibility/provenance documentation are preserved.

## Regression and live acceptance

`tools/test_service_lifetime.sh` compiles the actual guard against an adversarial
HTTP fixture. It covers fresh claim, saved-pairing validation, visible first-run
rejection, late callbacks, key/server changes, unsigned replies, signed revocation,
72-hour grace and clock rollback. The first-rejection regression failed on the
previous implementation and passed after the fix.

`tools/license_guard_live_probe.m` additionally runs the actual verifier and HTTPS
transport against the production signer with a disposable one-device license.
It substitutes only the acceptance key and pairing store. The phone build uses
the real Keychain identity implementation in a separate acceptance access group.
It is not the installed daemon or evidence of container/network isolation.
Private fixtures, bearer credentials and raw responses must never be committed.

## Deployment boundary

The source package preserves the historical `com.redditbox` identities and data
formats for upgrades of that source implementation. It must not be silently
coinstalled with the recovered engine, whose injected components and container
formats differ. Replacing the currently installed recovered package needs a
verified backup and an explicit data-preserving transition. Merely hiding its
icon or sharing its license screen does not remove its independent authority.

Source Facebook admission is currently disabled by its registry. MDM/per-app
network acceptance is still required for online container launch. This change
neither enables Facebook without evidence nor claims full feature parity,
complete isolation, or a customer-ready upgrade from the recovered package.

## September 29 acceptance results

The actual verifier and HTTPS code passed live cloud activation, cached access
in a new process, saved-credential validation, copied-UUID-without-credential
rejection, second-installation rejection, and signed revocation on the Mac.
The arm64/arm64e probe then passed activation, process restart, validation,
second-installation rejection and signed revocation on the connected iPhone.
The iPhone run used the production Keychain identity code in a separate test
access group. Both disposable licenses were revoked afterward; the phone's test
executables, private files and two test Keychain identities were removed.
The installed `.17` application's version and executable hash were unchanged.

The actual launcher passed 49 license-root UIKit checks and 240 workspace UIKit
checks using inert IPC and synthetic publications. The cloud service's 23 device
licensing checks passed. These complementary tests do not constitute a tested
upgrade of the recovered application or an end-to-end container launch.

Use `scripts/build-socialbox-source.sh` with an explicit `RBX_RELEASE_VERSION`,
`LICENSE_PUBLIC_KEY_FILE`, prepared Theos/ldid environment and OpenSSL 3 on PATH.
It builds the source stack and checks all seven native components, both native
architectures (the system firewall uses arm64), package identities and the public
pin in each daemon slice. The pre-install check refuses a mixed-engine installation
before stopping processes or modifying files. It does not remove the old engine,
convert its data, publish an update or grant a license.
