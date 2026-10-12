# RedditBox 0.1.1 — release evidence

Installation: https://redditspoof.vercel.app/install

Both variants were built through scripts/release.sh and scripts/build-mac.sh on this Mac with Procursus ldid, without an Apple Development Team. Both have completed publication journals, signed APT metadata, verified staged and public downloads, and preserve the companion repository.

- rootless: https://redditspoof.vercel.app/apt/redditbox/
  Package: com.redditbox_0.1.1_iphoneos-arm64.deb
  SHA256: 5c50f8f8cdc91c05606446f99a38598e3d773a90c4ada619dbb832cbb9df3dbf
- rootful: https://redditspoof.vercel.app/apt/redditbox-rootful/
  Package: com.redditbox_0.1.1_iphoneos-arm.deb
  SHA256: 24e3061f0e65afb1dc3e8359f779a1d62b3c4c5081d2e6277beae6aac19c38ca

Archive GPG fingerprint: B020EEB51600D74C02D6FE57448FA877778E0D1F
License public key ID: b2c5d4176c727107c9826ad69386d4d65f90920074981bd842127d6b22add6e9

Verified: cloud tests and production build; native Mac checks; real GPG/release recovery tests; matching signer/public pin; public source signatures, metadata and package hashes; installation-page source links and homepage navigation. The release Mac retains the full logs, package files, and release journals.

NOT RUN: installation/key trust/dependencies in Sileo on a physical iPhone, license activation on the device, five-profile upgrade, MDM/per-app VPN association, A/B traffic switching and Reddit login. Initial packages require MDM adoption; keep device traffic closed until the checklist passes. The Sileo button adds a source and does not prove device installation succeeded.

Existing license/authentication records were preserved. The first RSA signer was configured with the user's authorization; private keys and tokens are outside this deliverable and the Git checkout. The separate archive store contains public package artifacts only.

Branch: feat/lifecycle-and-distribution, left unmerged. Automatic Git deployments remain disabled because master does not contain the new signed repositories. Future deployments must preserve both public/apt directories.

## Sileo Release parsing correction — 2026-09-09

A physical-device source-add attempt reported `Could not parse release file`.
The published flat `Release` files lacked `Components`, which Sileo's
`RepoManager` requires even for flat sources. Both now include `Components: main`.
Source URLs and package versions remain unchanged.

The upstream Sileo C control-file parser at commit
`c9f70158a037dc76b91c450e72af2de0514dd3ee` was compiled on this Mac and used with
the required-field check from `RepoManager.swift`. It rejected both old headers
and accepted both corrected headers, including fresh downloads from production.
This checks parsing on the Mac; a successful refresh and installation in Sileo
on the iPhone still need confirmation.

`refresh-apt-metadata.py` completed its shared-lock publication journal. The
staged deployment `https://redditspoof-3cec9ftff-modelclone.vercel.app` passed
signature, exact metadata and package-download checks before promotion; the
same checks passed at both canonical production sources afterward. Only the
Release headers and their two signatures changed. Both `.deb` hashes above,
package indexes, retained by-hash indexes and archive keys are unchanged.
All seven existing private-store documents were byte-identical before and
after this correction.

Validation: 14 Debian/GPG/release tests passed; the two metadata-repair tests
passed, including five interrupted-publication recovery scenarios. The initial
Blob lock visibility delay was recovered using the same journal owner and
`--resume`, without deleting or stealing a lock. No package rebuild was needed.

## appinst dependency correction — 2026-09-09

The next Sileo attempt parsed the repository and queued RedditBox, but failed
with `Depends ai.akemi.appinst`. The user reported an iPhone 8-class device
around iOS 16.7.7 and expects iPhone 8/8 Plus/X support. Those devices on this
OS are palera1n targets; rootless and rootful remain separate package layouts.
The existing iOS >= 15 minimum and device acceptance requirements still apply.

Both production indexes now contain RedditBox 0.1.1 plus:

- appinst 2.1.1-redditbox1, rebuilt from upstream AppSync commit
  235aca6cddfbdc9fa87fcb5b2aec2df37ed6d65a, with static libzip 0.11.2,
  arm64/iOS 15 minimum and exact upstream ldid entitlements. Only the Debian
  revision and minimum firmware metadata changed. Rootless SHA256:
  46fd302cbea71ee7f4fd56cc2bd6b2d181d0beb6f44dcc81031a9bded896d445.
  Rootful SHA256:
  e2fe7e98e36daf1235661e93b0f7ee437b98831f83300fcbb9feb40fab6652a6.
- AppSync Unified 116.0, unchanged official GitHub release assets.
  Rootless SHA256:
  2bdaac72a6d1b006309b7dd28f51b1e3d351d3d8758fc9f08ca670f1d71eb382.
  Rootful SHA256:
  0036f28fcbdb165d4f58968a237ca9fe7b6ed33fea25b9a5eb1fc141f6bf5a09.

The shared-lock journal completed for deployment
https://redditspoof-jnhtk3cku-modelclone.vercel.app. Every listed package was
verified by download and hash on staging before promotion and on production
afterward. The original RedditBox package bytes/versions and archive keys are
unchanged. All seven private-store documents were byte-identical before and
after this deployment. Existing lock ownership was preserved during recovery;
resumption now reads the owned lock instead of repeating PUT. A temporary
post-promotion index mismatch cleared before successful production verification.

Validation: 15 Debian/GPG/release tests, three metadata refresh tests (including
dependency-upload/recovery cases), full cloud tests, Next production build,
actual Sileo C parser against both live package indexes, and source archive
public download all passed on this Mac. Both payloads have the correct prefix,
arm64 architecture, minimum iOS 15 and upstream entitlements. The install page
explains automatic dependencies and retrying a stale Sileo queue.

Corresponding source, licenses, packaging patch and build procedure for appinst
and the AppSync source tree are available at
https://redditspoof.vercel.app/install/sources/appinst-2.1.1-redditbox1-source.tar.xz
(archive SHA256 712629cc3f991b3197ebcfd77688c6804b7f4c65c1b635310eb00d5f92782147).

A successful dependency installation, clone installation and full smoke run on
the physical iPhone remain unconfirmed. Availability in a signed source does
not establish support for every jailbreak or iOS version.

## Device activation storage repair

The user installed RedditBox and reached activation, but `/api/devices/claim`
returned HTTP 503. Blob's compressed authentication document was delivered with
a weak `W/"..."` ETag. Conditional writes rejected that validator and exhausted
all transaction retries. Reads now request `Accept-Encoding: identity` and
require a strong validator; conditional-write protection remains enabled.
The existing RSA signer and installed public pin were verified to match.

The failure was reproduced on staging, then the fix passed an actual private
storage transaction and staged activation request. A request without a key now
returns the expected 403 instead of 503. Regression coverage uses the real Blob
SDK with an intercepted transport, plus the full cloud suite and five metadata
refresh/recovery tests. Both signed repositories passed staging checks before
promotion. No native package rebuild is required; both remain 0.1.1.

The physical iPhone must still retry activation with a valid device license.
Successful RSA verification, entitlement persistence and later offline operation
on that device remain on-device smoke checks.
