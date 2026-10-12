# Private console and first-screen presentation — 28 September 2026

The website now exposes only the owner's license console. The owner iPhone has
candidate `3.1.0-1+socialbox.17`, which addresses a reproduced startup-brand flash
and the native empty-proxy screen. This is not a public app release or an
isolation acceptance result.

## Private website

Production: <https://redditspoof.vercel.app/login>. The verified staging deployment
<https://redditspoof-butr5yu7d-modelclone.vercel.app> was promoted to the existing
production domain under the shared publication lock.

Only the existing configured owner with a currently stored admin role can enter
the console. Both server-rendered admin pages and admin APIs re-read stored user
state; possessing another admin session or a stale owner token is insufficient.
The owner's password, licenses, customer device APIs and private data were not
reset or migrated. The old `/updates`, `/install`, app pages and release-console
page now redirect to login or the owner's license page. Release implementation
and the machine update endpoint remain available internally; the stable channel
still reports no available public release.

PASS: full cloud suite and production build; ten real-handler authorization
groups; ten real local-browser checks using disposable storage, including owner
login, create/copy/search license, non-owner denial, revocation and narrow layout.
PASS: staging and production routes, exact existing owner identity verified
read-only, and all sixteen existing APT metadata files byte-identical. Production
login and the retired update page's redirect were inspected in the browser.
NOT_RUN: entering the owner's protected password on production. No test key was
created on production.

This supersedes the public-page availability in the earlier
[update-delivery receipt](socialbox-update-delivery-2026-09-28.md).

## Startup and proxy corrections

The physical `.16` recording showed the original logo during **Verifying license**,
followed by SocialBox. The presentation constructor queued its installation after
the original AppDelegate could create and show the startup controller. `.17`
registers the guarded lifecycle hooks synchronously on the main thread, without
creating UIKit objects or accessing UIApplication in the constructor. A bounded
fallback adopts an already-loaded, exact registered startup controller. Original
license verification, spinner, status and delegate operations are preserved.

The before regression failed one of 234 assertions; the fix passes all 234.
The test explicitly loads the startup controller before installation and verifies
adoption without another lifecycle callback or backend action.

The observed empty-proxy screen was rejected because the native hero-button
factory formats its fixed captions with two leading spaces. The adapter now
recognizes that exact known variant. It preserves the original controls and
senders and does not trim proxy names, credentials or user data. The before
regression failed three assertions; all 174 workspace assertions pass after the
fix.

## Owner package and data

Package SHA-256:
`5a095ad0c05a6eabfb335ae9be03c15a6be9d443c77f0fc33bdd9ff3bf92bba7`.

PASS: arm64/arm64e ldid build; 36 package tests; seven helper tests; strict UIKit
compilation; 24-file source-branding check; 287 English catalog entries / 875
checks; static checks; 390-row leak-surface contract. The original executable
and internal compatibility identifiers remain intact.

PASS: owner `.16` to `.17` upgrade, all 59 payload files and unchanged package
metadata verified. Before installation, a 359,811,044-byte private backup was
verified against two matching manifests. The scoped container comparison has
63 entries and 14 files/hardlinks identical before and in both post-upgrade
snapshots, excluding timestamps only. This does not claim global Keychain or
foreign-account recovery. The aggregate runtime comparison is INCONCLUSIVE:
two entries continued changing between post snapshots.

USER_REPORTED PASS: after installing `.17`, the owner reports that the original
startup brand no longer appears. Agent-recorded post-upgrade cold start and the
proxy-screen walkthrough remain NOT_RUN. This is an owner observation of startup
presentation, not proof of the other screens or licensing integration. The existing core/network/license-integration blockers remain
as recorded in the isolation register; this UI correction does not close them.

Evidence: [delivery receipt](release-evidence/private-console-startup-2026-09-28/delivery.json),
[startup before](release-evidence/private-console-startup-2026-09-28/startup-before.json),
[startup after](release-evidence/private-console-startup-2026-09-28/startup-after.json),
[proxy before](release-evidence/private-console-startup-2026-09-28/proxy-before.json),
[proxy after](release-evidence/private-console-startup-2026-09-28/proxy-after.json),
[real browser checks](release-evidence/private-console-startup-2026-09-28/console-browser.json).
Private recordings, archives, manifests and credentials are not committed.

Leak-Surface: ADOPT-001, ADOPT-002, CLOUD-004, DIST-001.
