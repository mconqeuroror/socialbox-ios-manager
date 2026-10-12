# SocialBox update delivery — 28 September 2026

The owner release console and update notification client are delivered. This is
not a customer release or a completed isolation/activation acceptance. The stable
channel remains empty and the real candidate retains its engineering blockers.

## Delivered

- Owner console: <https://redditspoof.vercel.app/admin/releases> (sign-in required).
- Customer instructions: <https://redditspoof.vercel.app/updates>.
- English app: **Settings → App updates → Check for updates**.
- Candidate `3.1.0-1+socialbox.16`, rootless, exact predecessor `.15` only.
- Package SHA-256:
  `7963bd73c7e2be86f48f99e2a351551b37ec4f2ca61dc2dacece60fef3c5f24a`.
- Source commit `d2bb08bbaa4a0a71e9b153234bc1f4aee2605ee1`; candidate catalog
  committed in `9520e59`, preparation verification correction in `a695761`.
- arm64/arm64e build through ldid; no Apple signing team. Original core identities
  and license checks are preserved.

The candidate was uploaded to the dedicated public artifact store under the
shared APT publication lock. Its bytes and signed metadata were verified. It is
not in the approved stable channel. The administration page records tests against
the exact hash and cannot override build-owned engineering blockers.

## Verification results

PASS: 69 native update evaluator/transport checks; 174 synthetic source-owned
workspace assertions; 287 English catalog entries / 875 checks / 328 references;
9 Python and 31 native branding tests; strict UIKit compilation; 24-file branding
guard; static checks; 36 package tests; 7 helper tests; 8 leak-contract tests.

PASS: 27 release policy/API/private-storage checks; 17 mocked Blob publication
groups; 8 GPG package preparation tests; all existing cloud suites; TypeScript
and production Next.js build. The native stale-callback race has a regression
test. Complete package hashing protects final wrapped control-script bytes.

PASS: 18 browser checks on real built pages with synthetic admin APIs, including
incomplete/blocked candidates, exact hash, stale revisions, cancellation, errors,
anonymous access and narrow screens. These are not live release mutations.
The production `/updates` page was separately inspected in the browser and shows
**No public update yet**, with no misleading installation button.

PASS: staging deployment
<https://redditspoof-en5dz4vic-modelclone.vercel.app> was promoted to the existing
production domain. `/login` and `/updates` return 200; anonymous release and
license APIs return 403; the admin page redirects to login. The stable API returns
`available: false`, and the unapproved SocialBox APT Release returns 404. All 16
existing rootless/rootful RedditBox APT metadata files are byte-identical through
staging and production. Those repositories remain version `0.1.25`.

NOT_RUN: real owner web sign-in. The protected existing password was unavailable
to the deployment check; no password was reset or login attempted. Authentication
source and middleware are unchanged from `19cf95c`, and their automated
regressions pass. No live acceptance, app-release or license-record mutation was
performed.

## Owner iPhone installation and preservation scope

PASS: `.16` installed on the connected iPhone X / iOS 16.7.16 through the reviewed
private SSH upgrade procedure. All 59 payload file hashes match. Global container
metadata is byte-identical. A verified Mac-only private runtime backup was taken
before installation: 359,910,555 compressed bytes, 854,712,320 raw bytes, 17,906
entries over 18 roots. The `.15` recovery package is retained privately.

PASS within the recorded scope: three linked manifests agree on all 63 entries
and 14 regular/hardlink files in the container trees and metadata-resolved owned
app/group roots; no added, removed or modified scoped entries.

INCONCLUSIVE for all owned runtime bytes: the live daemon state and logs changed
between snapshots (`daemon_state.json`, `.daemon-audit.log`, `.remote.log`).
Those changes are recorded rather than excluded from the aggregate verdict.
Global Keychain and foreign target-account recovery were not covered. Existing
loader test metadata is not evidence of signed-in Facebook/Reddit accounts.

NOT_RUN: foreground phone UI/notification walkthrough, physical account switching,
packet-measured proxy failure, restore rehearsal, and activation of a newly issued
web license on a customer installation. The last USB preview shows the locked
phone, so no physical UI recording is presented.

## What prevents a customer launch

ADOPT-003 and ADOPT-004 remain open: global/deactivation/batch storage transitions
still discard stop failure; there is no completed launch fence or measured
network-isolation acceptance; the new web license integration with the retained
core is not established. Owner installation does not close these gaps. The
candidate is intentionally blocked from Release.

The public package alone does not provide the private SSH installer's complete
backup and quiescence procedure. Fresh installs, rootful/roothide, migration from
`com.redditbox`, and skipped-version upgrades are not supported by this lane.

## Quick acceptance and subsequent releases

Start with two disposable containers and the owner's own accounts. Verify
A → B → A preserves each account, identity and proxy; test proxy failure with
traffic evidence; export and restore a backup; reopen the app; then verify a
package upgrade preserves the same state. Separately test fresh web-license
activation and its device limit. Full steps are in
[the release workflow](socialbox-release-workflow.md).

After code blockers are resolved, prepare and install a new candidate, record the
five acceptance categories in **App releases**, then confirm **Release update**.
Promotion uses the exact tested bytes. Supported clients show an update notice on
a subsequent eligible foreground check (at most one automatic attempt per six
hours), or immediately after a manual check. Installation is approved by the
customer as **Upgrade** in Sileo, without uninstall/reset. Builds predating the
notification client require an initial manual upgrade.

Evidence: [sanitized receipt](release-evidence/socialbox-updates-2026-09-28/delivery.json),
[browser results](release-evidence/socialbox-updates-2026-09-28/browser-tests.json),
[workspace results](release-evidence/socialbox-updates-2026-09-28/workspace-tests.json).
Private archives, credentials and account data are not committed.

Leak-Surface: ADOPT-006, DIST-001. No new isolation verdict is asserted.
