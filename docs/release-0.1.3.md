# RedditBox 0.1.3 — published 2026-09-11 (Europe/Bratislava)

Install/update: https://redditspoof.vercel.app/install

Both variants completed `scripts/release.sh 0.1.3`, using Procursus ldid with no Apple Development Team. The existing Vercel project, canonical domain, license signer and separate public APT Blob store were reused. Publication followed explicit user authorization. The branch `feat/lifecycle-and-distribution` remains unmerged; production Git auto-deploy remains disabled.

For an existing installation, refresh sources in Sileo, select RedditBox and update to **0.1.3**. A website deployment does not automatically update the phone. Use the same jailbreak variant; an ordinary update does not require uninstalling RedditBox first.

## Published artifacts

- **Rootless:** https://redditspoof.vercel.app/apt/redditbox/
  Package: `com.redditbox_0.1.3_iphoneos-arm64.deb`, 1,469,664 bytes.
  SHA256: `b7765c0fcdfb3a0ebc876e970699a269b79d1cd1925c8b5dc9d2f0b721030e83`.
  Verified staged deployment: https://redditspoof-xoxjb92p8-modelclone.vercel.app
- **Rootful:** https://redditspoof.vercel.app/apt/redditbox-rootful/
  Package: `com.redditbox_0.1.3_iphoneos-arm.deb`, 1,463,700 bytes.
  SHA256: `f0f60af3ea5eb5928ea9603cb8da11eff6b3973d6379052e91e46eaeb095c57a`.
  Verified staged deployment: https://redditspoof-ic7t5nxsg-modelclone.vercel.app

Both sources retain 0.1.2 and 0.1.1 plus appinst and AppSync dependencies. These hashes identify the actual publication rebuilds and supersede the local acceptance artifact hashes in the historical [integration report](final-integration.md). Rootless was built from `f03f817`; rootful from `ef164b8`, whose only changes were rootless publication metadata and its inventory evidence.

The signing contracts match the authenticated previous releases, so the published manifests have `requiresMDMReadoption: false`. This means this release did not change that contract; it does not establish that any clone has already been supervised or adopted into its managed per-app VPN. The historical standalone acceptance builds lacked this authenticated release comparison.

## Verification

- Both native builds completed their build checks, Xcode archives and Theos packages. The full cloud test suite and source/LEAK_SURFACE contract checks passed. Existing compiler warnings remain.
- Each publisher staged without moving the production domain, verified pinned GPG signatures, index hashes, retained indexes and package downloads, checked the companion source, then promoted and verified production before releasing its shared publication lock.
- Separate read-only checks of `/api/licenses/status` passed on each exact staged URL while its journal remained `deployed`, before promotion. These were independent observations, not an additional gate built into `release.sh`.
- Final read-only verification checked both production sources against their completed journals and local signed metadata, all retained downloads, both displayed website versions, canonical Sileo links, rendered copy controls and the hydrated home-page installation link. The actual Sileo URL handler and clipboard clicks were not tested on a phone during this release.
- Production license health remains ready with issuer `https://redditspoof.vercel.app` and key ID `b2c5d4176c727107c9826ad69386d4d65f90920074981bd842127d6b22add6e9`, matching the existing build PEM. No license key was replaced. This release did not run write-producing production smoke tests or change the private license/backup store.
- APT signing key: `B020EEB51600D74C02D6FE57448FA877778E0D1F`. Package binaries remain in the dedicated public store `iyitgqxbaggwqtn3.public.blob.vercel-storage.com`; the decrypted Reddit IPA remains private.

Safe timings, staging observations, hashes and final production results are recorded in [release-0.1.3-verification.json](release-0.1.3-verification.json).

Both initial lock attempts reported a missing readback, and immediate post-promotion verification failed once per variant (rootless HTTP error; rootful `Packages.gz` digest mismatch). Each stopped with its journal and lock retained. Resuming the same owner and variant completed verification; no lock was stolen/deleted, journal bypassed, signature check disabled or unverified deployment substituted. The cause of the transient responses was not established.

Post-publication [Cloud CI](https://github.com/typekpaco2002/redditspoof/actions/runs/34539049861) exposed a stale smoke fixture: it uploaded a backup before profile registration and expected newly generated device licenses to succeed through legacy unsigned validation. Install, typecheck, unit tests and build passed; the smoke step reported 34 passed / 11 failed. The fixture now checks rejection before registration, performs registration and the backup round trip with a fresh profile ID, checks the exact generated license and its history/revocation, and requires unsigned device validation to fail closed. Signed activation remains covered by the dedicated device-license unit fixtures, not this smoke run. This correction changes test code and evidence only; the published application and cloud runtime are unchanged. LIFE-031 and NET-038 retain their existing verdicts.

The corrected fixture passed **52 checks / 0 failures** against a fresh isolated local production build on Node 24.5.0, using only CI placeholder authentication settings and local test storage. No private environment files were copied, no production requests were made, and the owned test server was stopped. This local result is distinct from the subsequent Linux CI run and from iPhone acceptance.

## Changes and acceptance limits

This release includes the prepared Simple UI and onboarding, dispatch-scoped Reddit request handling, preservation of recognized authenticated requests, opt-in local-only Keychain sync policy, diagnostic timing correction and bounded SSH/canary acceptance tooling. See the [integration report](final-integration.md) for individual fixes and commit evidence.

The [leak-surface ledger](../LEAK_SURFACE.md) remains **304 rows: 126 covered in code, 25 gaps, 153 unverified**. Publication changes LIFE-029's distribution evidence, not its device verdict. No 0.1.3 iPhone installation or runtime acceptance was performed in this publication pass. Existing-profile upgrades, license continuity on the updated phone, clone creation/replacement/deletion, A/B state isolation, managed VPN/proxy enforcement and Reddit login still require the [device acceptance runbook](device-acceptance-final.md). Previous 0.1.2 observations are not 0.1.3 acceptance.
