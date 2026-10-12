# SocialBox: test candidate → owner release → customer upgrade

The website currently exposes only the private owner license console. Following
the owner's request, **App releases** and the public `/updates` page are dormant;
their source and machine update API remain intact. Do not direct an operator to
those pages as currently available controls. The English app has
**Settings → App updates**. This is an update notification system, not an
unattended installer. The existing license database and both RedditBox APT
repositories remain separate and unchanged.

## Customer launch prerequisites

The current `.17` package is an owner-only, exact-predecessor upgrade. Its startup
flash is resolved according to the owner; that does not establish a customer
installation. Before a customer pilot:

1. Finish the verified SocialBox license integration with all retained admission
   consumers (ADOPT-004), then test a new web key, one-device binding, another
   device rejection, revocation and relaunch. Do not reset the owner's working
   license to simulate a clean installation.
2. Build and test a supported fresh-install package with recoverable state; the
   existing `.16` to `.17` preflight is not a fresh-install route.
3. Close the acknowledged-switch and launch/network enforcement gaps in
   ADOPT-003, then run the physical acceptance battery below with measurements.
4. Test export/restore and upgrade preservation on disposable data. Only then
   register the exact accepted customer package and publish its installation
   instructions through a deliberate release. The private website remains
   limited to license management unless the owner requests a change.

These are implementation and acceptance prerequisites, not a promise that a
Release button alone can make the current owner candidate customer-ready.

## Physical acceptance check

Use two disposable containers with your own accounts, not forty production
accounts. Keep a recovery backup outside the iPhone before changing packages.

1. Record the installed SocialBox version and export a test container. Restore
   that export as a separate test; merely creating an archive does not test recovery.
2. Give A and B different names, identities and proxy assignments. Open each,
   sign in yourself, then switch A → B → A repeatedly. Check account, data,
   identity, selected container and assigned proxy every time.
3. Stop a proxy or provide an invalid endpoint. Verify there is no successful
   direct connection with packet evidence; a red label alone is not proof.
4. Close and reopen SocialBox. Test a restart separately, accounting for the
   jailbreak's normal reboot requirements. No other account should open silently.
5. Install the exact next package using the reviewed owner upgrade procedure.
   Confirm the same containers, accounts, identities and proxy settings remain.
   Restore the backup on a disposable test before claiming rollback/recovery.
6. Activate with a newly issued **web** license on a supported customer test
   installation. Verify the configured device limit. An already licensed owner
   phone does not test this integration.
7. In App updates, check the installed build and manually check the stable
   channel. The current unapproved channel says **No public release is available
   yet**. A newer approved compatible release shows update instructions.

Record failures as failures. Do not publish a candidate whose tests are incomplete.
These checks are a small acceptance battery, not proof of complete isolation or
40 concurrently validated accounts. ADOPT-003 and ADOPT-004 remain authoritative.

## Preparing a release on the Mac

Build with the existing ldid-only candidate builder, pinned to its exact
predecessor. Commit the source first. Keep the package, build report, backup and
restore artifacts privately; do not commit account data or private keys.

With the existing dedicated public Blob credentials and APT GPG signing identity
loaded in the environment:

```sh
python3 scripts/prepare-socialbox-release.py \
  --package /absolute/private/candidate.deb \
  --build-report /absolute/private/build-report.json \
  --notes /absolute/private/release-notes.txt \
  --commit FULL_SOURCE_COMMIT \
  --output /absolute/private/prepared-candidate.json

cd cloud
npx tsx scripts/register-socialbox-release.ts \
  /absolute/private/prepared-candidate.json \
  /absolute/private/candidate.deb \
  /absolute/private/publication-journal.json
```

The preparer verifies package/control/payload hashes and the actual source files
against the stated Git revision, signs Release/InRelease with the existing APT
key and verifies the signatures. Build residuals become immutable engineering
blockers. It cannot clear them. The registration tool uploads the **same bytes**
under the existing shared APT publication lock, verifies the origin SHA-256 and
size, and adds a build-owned candidate to `cloud/src/data/socialbox-releases.json`.
The Blob store must differ from the private license/backup store. Registration
does not change the public app release. An interrupted upload retains the lock
and journal; resume that same journal, never steal the lock.

Commit the candidate catalog. Deploy the existing Vercel project without moving
the production domain, verify staging and both unchanged signed APT repositories,
then promote that checked **website deployment** under the shared publication
lock. Never remove a candidate referenced by the stable state or history. Public
metadata is bundled with the website; historical by-hash files and package URLs
remain served after promotion.

## Publishing in the owner console (retained, currently dormant)

1. Download/install the candidate on the owner's test phone. The artifact hash
   shown in the console must match the package actually installed.
2. Record observed results for all five acceptance categories. These records
   identify the exact candidate/hash, current administrator and time. They are
   operator observations, not automatically measured proofs.
3. Resolve engineering blockers in code and build a new candidate. The web form
   cannot override them. Unprepared or blocked candidates have a disabled Release.
4. Press **Release update**, review the version and confirm. The server rechecks
   admin access, same-origin JSON, artifact identity, acceptance, engineering
   blockers, upgrade compatibility and state revision. A private atomic mutation
   moves the stable pointer; it does not rebuild or run a shell command. A lost
   response can be retried without creating a second release event.

Customers on a supported predecessor receive an in-app notice after their next
eligible foreground check (at most one automatic attempt per six hours), or
immediately after **Check for updates**. The app requests only a fixed HTTPS
manifest, with no license, proxy, account, container or device identifiers. The
server still observes ordinary network connection metadata. Redirects, cookies,
credentials, oversized replies and incompatible manifests are rejected.

When explicitly re-enabled, the public instructions use
<https://redditspoof.vercel.app/updates>. That page currently redirects to the
private console. Only
after an approved release do they show the real source
`https://redditspoof.vercel.app/apt/socialbox/`. Customers choose **Upgrade** in
Sileo. Never instruct them to uninstall, purge or reset as an update step.

## Compatibility and remaining limits

The retained package ID and app identity stay unchanged for an in-place upgrade.
The current candidate is rootless only and accepts exactly its pinned previous
version. Fresh installs, rootful/roothide and `com.redditbox` migrations are not
provided by this lane. Someone several versions behind needs a separately tested
sequential upgrade path; the current stable repository does not automatically
chain intermediate releases. Removing the preflight guard is not a migration.

The private SSH installer backs up app-owned runtime paths before installation;
the public package alone does not implement that complete backup/quiescence
procedure. Export/import and signed package checks do not prove preservation of
all Keychain account sessions. Current `.17` remains a private owner
candidate: unfinished storage transitions, absent measured network isolation,
physical acceptance, and the original licensing integration still block a
customer release. The old public sources remain version `0.1.25`; they do not
distribute this candidate.

The owner Release control and update notice do not claim to close those gaps.
Use `docs/socialbox-private-console-startup-2026-09-28.md` for the latest delivery
receipt; the preceding update-delivery record describes the now-dormant UI.
