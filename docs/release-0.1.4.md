# RedditBox 0.1.4 — published 2026-09-11

Install/update: https://redditspoof.vercel.app/install

Both variants completed the existing sequential `scripts/release.sh` procedure with Procursus ldid and no Apple Development Team. The existing production domain, Vercel project, license signer and dedicated public APT Blob store were preserved. The branch `feat/lifecycle-and-distribution` remains unmerged; production Git auto-deploy remains disabled.

## Changes

- Bottom navigation: Containers, Proxies and Settings, with the existing launcher passcode gate retained.
- The proxy URL is visible, including any credentials in that URL. The rotation link is optional. Custom rotation headers, authorization token and HTTP method are under collapsed Advanced options.
- Without a rotation link, the connection test checks the configured proxy without making a rotation request or claiming a new exit IP. Existing operation, license and managed VPN requirements remain in force.
- Proxy-only saves preserve the existing license key. Separate settings request owners and visible-view receipt handling prevent hidden tabs from consuming each other’s completions.
- Feature commit: `a8da15b371f2d6b207d2ef05aa9ca3720c8506e0`. Rootful build includes the rootless metadata commit `c03ebc48defe2f958f1f3b5de3834221a5788133`; no application source changed between the variant builds.

## Published artifacts

- **rootless:** https://redditspoof.vercel.app/apt/redditbox/
  Package: `com.redditbox_0.1.4_iphoneos-arm64.deb`, 1,476,616 bytes.
  SHA256: `07684981681d785ce46ae2c456c57edc2297c06f40459126a87e444db0cfd39a`.
  Staged deployment: https://redditspoof-rbnwcw47c-modelclone.vercel.app
- **rootful:** https://redditspoof.vercel.app/apt/redditbox-rootful/
  Package: `com.redditbox_0.1.4_iphoneos-arm.deb`, 1,470,160 bytes.
  SHA256: `11c182c5f96d5da73cec36099e925ef0b92219e948182d2bd4e4095113290792`.
  Staged deployment: https://redditspoof-iyebeflih-modelclone.vercel.app

Both sources retain 0.1.3 and 0.1.2 plus their indexed appinst/AppSync dependencies. Signing contracts match the previous authenticated releases (`requiresMDMReadoption: false`); that flag is not proof of managed VPN adoption on a phone.

## Verification and limits

- Both full native builds, build-script checks, Xcode archives and Theos packages passed. Existing compiler warnings remain.
- Secure configuration regression tests cover proxy-only configuration, explicit rotation clearing, idempotence and license retention. A native fixture exercises the shipped proxy configuration/connection-test methods with mock providers: no-link behavior, stale rotation fallback suppression, health failure, explicit rotation and invalid configuration. These are not real proxy-provider or phone traffic tests.
- The publisher verified pinned GPG signatures, indexes, retained package downloads and companion-source preservation on staging before promotion, then on production before unlocking. Separate read-only license-health observations passed on both exact staged deployments before promotion; these observations are not a new publisher gate.
- Final read-only checks matched both production repositories to completed journals and local signed metadata, downloaded all retained packages, checked both installation-page versions, canonical Sileo links and copy controls, and confirmed the existing license public key matches the cloud signer. Homepage HTTP succeeded; its hydrated installation link was not rechecked in this pass.
- The Simulator target compiled. Automated UI interaction could not be completed because Computer Use permissions were not granted; an earlier simulator view is not full UI acceptance. No published 0.1.4 iPhone upgrade, proxy connection, clone lifecycle or Reddit login was exercised in this pass.
- The leak-surface ledger remains 304 rows: 126 covered in code, 25 gaps and 153 unverified. No device verdict was promoted based on publication or mock tests.

Initial lock readbacks stopped publication with the journal retained. A rootful resume also reported an owner/ETag mismatch; a subsequent read showed the exact journaled owner before resuming. Post-promotion verification initially reported a Packages.gz checksum mismatch for each variant and then passed on same-owner resume. No lock was stolen, deleted to bypass checks, or journal altered to skip a phase. The cause of these transient responses was not established.

Safe public evidence: [release-0.1.4-verification.json](release-0.1.4-verification.json).

## Update and phone acceptance

Refresh sources in Sileo, select RedditBox and update to **0.1.4**, keeping the same jailbreak variant. The website does not automatically update the installed app; uninstalling first is unnecessary. Open Proxies, enter an HTTP proxy including its port, optionally enter an HTTPS rotation link, then use Save and test. Confirm the new bottom tabs, visible URL and optional-link save behavior on the phone. Follow [device-acceptance-final.md](device-acceptance-final.md) for lifecycle and traffic acceptance; a successful proxy test alone does not prove clone isolation or managed VPN enforcement.
