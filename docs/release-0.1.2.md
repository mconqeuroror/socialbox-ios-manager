# RedditBox 0.1.2 — published 2026-09-10

Install: https://redditspoof.vercel.app/install

Both variants completed scripts/release.sh with ldid-only signing and no Apple Development Team. Staging and production verification checked GPG signatures, index hashes, all retained downloads and preservation of the companion repository. Both retain 0.1.1 plus appinst and AppSync dependencies.

- rootless: https://redditspoof.vercel.app/apt/redditbox/
  Package: `com.redditbox_0.1.2_iphoneos-arm64.deb`
  SHA256: `56ae19783eba84de5f46153c2492f0e5a6e12ca137759bd146eefe293fbad968`
  Verified deployment: https://redditspoof-i5j0gy7lj-modelclone.vercel.app
- rootful: https://redditspoof.vercel.app/apt/redditbox-rootful/
  Package: `com.redditbox_0.1.2_iphoneos-arm.deb`
  SHA256: `23031080a1fee7514d459e97f916d8a2c58c8607fb92d21940f4af4ffa3e170a`
  Verified deployment: https://redditspoof-3tbxe5ho8-modelclone.vercel.app

The daemon now applies and verifies a 256 MiB budget when the kernel imposes a smaller positive limit. Source ZIP extraction and nested validation release temporary objects per entry. Missing support-log tools produce a specific error instead of a generic spawn failure.

Verified on the connected iPhone 8 (iPhone10,4), iOS 16.7.16, palera1n rootless: installation of 0.1.2, active existing license, successful import of fully decrypted Reddit 2026.36.0 / 664762, stable daemon, 256 MiB kernel limits and successful startup recovery. All eight Mach-O files in the private source archive passed the encryption scan; ZIP integrity passed. The IPA remains private and is not hosted in the public APT store.

The final reinstall left a running old RedditBox Firewall host with an unlinked executable. Its exact process identity was verified and it was closed; restarting the idle daemon restored successful preflight. Automatic handling of this upgrade case remains open. This phone lacks a log executable; the new explicit export failure was verified, and USB logs were used.

Mac validation: both complete native build check suites, memory-budget unit tests, real Darwin bounded-child tests including missing executable, 14 APT publication policy fixtures, public route checks, installation page checks, and both actual staged production builds. The live install page returned HTTP 200 with both canonical Sileo links and version 0.1.2.

The seven private-store documents retained the same paths; six were byte-identical. The remaining auth document changed only its version counter and the device lastSeenAt timestamp. Existing license/account records and the RSA key were preserved.

Still NOT RUN: rootful/Dopamine runtime, clone creation/replacement/deletion, Reddit login, upgrade with existing profiles, MDM/per-app VPN association, proxy routing and traffic isolation. Release metadata requires MDM re-adoption checks for existing clones. The connected phone had no profiles/proxy configured and network state remained closed.

Branch: feat/lifecycle-and-distribution, unmerged. Keep both signed APT directories in every subsequent deployment.
