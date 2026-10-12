# RedditBox 0.1.6 — interface and device repair

Published on 2026-09-11 at https://redditspoof.vercel.app/install.
Branch: `feat/lifecycle-and-distribution`; not merged.
Rows: UI-001, UI-002, UI-003, UI-004, UI-005, NET-038, ACCEPT-001, LIFE-026, LIFE-027, LIFE-029.

## Interface

- Bottom tabs: Containers, Proxies, Settings.
- Proxies: plus opens Add proxy; saved rows offer use, test, edit and delete.
  Proxy text is visible as requested. Rotation link is optional; uncommon
  authorization/method fields are collapsed under Advanced.
- Containers: plus adds a profile; tap offers Open, Edit, Role & notes, Delete.
  Edit opens the existing complete identity settings with its existing locks.
- Settings retains license, source IPA and MDM/VPN setup.
- Isolation checks shows verified observations, failures and unverified checks,
  with bounded local history and freshness checks. It does not claim 100%
  isolation. Real cross-container canaries, network capture and login acceptance
  remain distinct manual checks.

There is one selected proxy used for connections. Saving multiple proxies does
not establish a different proxy assignment per container.

## Verified observations

- Both ldid-only package builds completed, without an Apple development team.
- Native proxy-library, secure configuration, proxy challenge, acceptance
  evaluator, cleaner and deletion-journal tests passed. Build checks passed.
- On the connected rootless iPhone, the 0.1.5 daemon proxy test returned
  `Proxy connected. No rotation link configured.`. The iOS CONNECT authentication
  correction retained origin/proxy credential separation and TLS verification.
- Real device Keychain-backed proxy add/edit/delete test passed and restored
  the existing rows and selection.
- Existing signed license remained active and imported Reddit source reported
  version 2026.36.0 before the latest service restart. No license key was replaced.
- Exact rootless 0.1.6 package bytes were transferred with SHA-256 verification
  and installed successfully. Installed appinst is 2.1.1-redditbox2.
- appinst2, rebuilt from the existing source with explicit Procursus signing,
  executes on the phone. The earlier appinst1 returned Bad executable.
- An exact-group cleaner probe for our failed test container returned a complete
  canary/cleanup receipt after correcting Darwin primary-group handling. This
  probe does not replace a daemon deletion journal checkpoint.

## Outstanding device acceptance

The first test container did not finish creation with appinst1. Its deletion
journal remains retryable. After the 0.1.6 service restart, startup refused
mutations because process enumeration could not read a live process executable
path. Logs reproduced that failure. This is not a successful container lifecycle
or isolation test. No recovery journal was cleared to bypass it.

A synthetic legacy-fence test was blocked by startup preflight before reaching
the target deletion handler; its own marker and directory were removed after
checking ownership. It must not be recorded as a passed migration-fence test.
The real failed deletion journal remains intact.

USB/SSH disconnected during diagnosis. The phone must be reachable to identify
the specific process failure and finish create/delete acceptance. MDM association,
managed VPN routing, clone launch/login, full A/B isolation, rootful device tests
and visible UI tap/screenshot acceptance are not complete.

## Published repositories and packages

- https://redditspoof.vercel.app/apt/redditbox/ — iphoneos-arm64, version 0.1.6, SHA-256 `a18e7c29de02b18f4f7b1646cb8e28200cc24978c2ac91f03be3abcf0c98dcff`.
- https://redditspoof.vercel.app/apt/redditbox-rootful/ — iphoneos-arm, version 0.1.6, SHA-256 `3296bb2ec12943a1f621c0a9bafa6be1735af1676503d68f34d5942c7464ed59`.

Both repositories include appinst 2.1.1-redditbox2 and retain the unchanged
AppSync dependency. The corresponding source archive is linked on the install
page. Existing public package Blob storage, private license storage and APT
signing keys were retained. Both staging license checks passed before promotion.
Publication encountered transient index mismatches/connection reset; only the
same-owner journal resume was used, and both publisher journals reached complete.
