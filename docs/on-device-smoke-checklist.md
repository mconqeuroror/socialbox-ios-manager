# RedditBox device acceptance runbook — lifecycle, licensing and distribution

For the current binary inventory and completed versus pending evidence, use
[LEAK_SURFACE.md](../LEAK_SURFACE.md). Record every device probe against its row ID;
the historical acceptance notes below are not a substitute for that ledger.

Review branch: `feat/lifecycle-and-distribution`; prior security review baseline: `916d90d`.
Keep the branch unmerged for review. Record the full checkout SHA for each build
and acceptance run. The security review baseline is a historical reference.
Use the [lifecycle and distribution review](lifecycle-and-distribution-review.md)
for the current commit/evidence ledger and residuals; the
[earlier phase 2/3 review](phase2-phase3-review.md) retains the original findings.
The [signed APT procedure](apt-distribution.md) covers release credentials,
publication recovery, key trust and exact Sileo/APT installation commands.
Select the package using the [jailbreak compatibility matrix](jailbreak-compatibility.md):
palera1n rootless or Dopamine use rootless; palera1n rootful uses rootful.

**Full device acceptance is pending.** Complete Mac builds, native Swift and
Objective-C tests, linking, ldid signing and rootless package installation have
been verified in the versioned [release evidence](release-0.1.13.md). The
[setup and launch-safety update](setup-and-launch-safety.md) adds explicit
unverified setup states. NetworkExtension authorization, effective MDM routing
and real A/B Reddit flows still need target-device acceptance. Instructions below describe
the procedure and expected results, not completed tests. Record each item as
PASS, FAIL or NOT RUN, with evidence; a missing probe is not a PASS.

## Morning order

1. Prepare the Mac/checkout below, deploy the matching cloud code/configuration,
   create a **device** license key, and provide that deployment's public license
   key to the build. Record the checkout SHA and actual phone/jailbreak details.
2. Build with ldid only. For a distributed build, run `bash scripts/release.sh`
   using the APT procedure; it runs the Mac build itself, signs/stages/verifies
   the repository and promotes it. Keep generated signed metadata in Git before
   any later cloud deployment. Install the exact verified version through the
   trusted Sileo/APT source; no Apple team is needed by the build.
3. Open RedditBox, unlock its local passcode if configured, then activate the
   device license. Successful key activation also pairs this installation with
   cloud management. Complete proxy and private-source setup while CLOSED.
4. On disposable data, exercise **create → replace → delete → create** before
   the first Open, following the lifecycle checks below. Create A and B, export
   their exact IPAs and MDM mapping, deploy/adopt/associate them, then start the
   managed firewall and verify effective per-app VPN assignment.
5. Start capture, open A, complete password/login triage and native actions,
   switch A → B → A, and run the failure matrix. Browser callbacks and H08 remain
   open issues; a blocked or misrouted required flow is not a passing login.
6. Exercise role/notes sync, license offline/revocation cases and a second
   published version upgraded over five saved profiles. Retain failed and
   unrun cases, package hashes, logs, IDs, MDM evidence and captures.

## Mac build — ldid only, no Apple team

Use a Mac with full Xcode and its iOS platform/SDK installed, plus Homebrew.
Command Line Tools alone are insufficient. Open Xcode once to finish component
installation and accept its license. The device must run the selected compatible palera1n or Dopamine
jailbreak and physical iOS 15 or later. Record the actual model, iOS build and
jailbreak/version; the synthetic profile catalog does not describe supported
physical phones. A newer Reddit binary can still require a newer physical OS.

Run these blocks in the same Bash session (`/bin/bash` in Terminal). Adjust
the Xcode path if it is installed elsewhere. Run Theos/build commands as your
normal user; only Xcode setup and packet capture below use `sudo`.

```bash
set -euo pipefail
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

brew install xcodegen libarchive ldid-procursus xz python node gnupg
export THEOS="$HOME/theos"
export LDID="$(brew --prefix ldid-procursus)/bin/ldid"
export PATH="$(brew --prefix python)/libexec/bin:$PATH"
test -x "$LDID"
RBX_LDID_USAGE="$("$LDID" 2>&1 || true)"
printf '%s\n' "$RBX_LDID_USAGE"
case "$RBX_LDID_USAGE" in
  *-w*) ;;
  *) echo 'Procursus ldid with -w support is required.' >&2; exit 1 ;;
esac
```

Require `-w` (shallow bundle signing) in ldid's usage. The supported implementation
is Procursus 2.1.5-procursus7 or later. Homebrew's `ldid` and `ldid-procursus`
formulae conflict; if installation reports that conflict, unlink the ordinary
`ldid` with `brew unlink ldid`, then rerun the install block. The explicit `LDID`
path prevents accidentally selecting another signer. See the
[Homebrew formula](https://formulae.brew.sh/formula/ldid-procursus).

For a new Theos installation, clone its submodules and install its patched SDK.
This avoids the generic installer selecting ordinary Homebrew `ldid`. An existing
installation must have `makefiles/common.mk`, initialized submodules and an iOS
SDK; do not overwrite it. Xcode supplies the compiler; Theos supplies jailbreak
headers/libraries. See [Theos Mac prerequisites](https://theos.dev/docs/installation-macos)
and the [SDK installer](https://github.com/theos/theos/blob/master/bin/install-sdk).

```bash
if [ ! -e "$THEOS" ]; then
  git clone --recursive https://github.com/theos/theos.git "$THEOS"
  "$THEOS/bin/install-sdk" latest
fi
test -f "$THEOS/makefiles/common.mk"
git -C "$THEOS" submodule status
ls -d "$THEOS"/sdks/iPhoneOS*.sdk
```

Clone a fresh review checkout into a new directory (or use your existing clean
checkout after `git fetch origin` and `git switch feat/lifecycle-and-distribution`). Do not
merge into `master` or use `sudo make`.

```bash
git clone --branch feat/lifecycle-and-distribution --single-branch \
  https://github.com/typekpaco2002/redditspoof.git redditspoof-acceptance
cd redditspoof-acceptance
git status --short --branch
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/feat/lifecycle-and-distribution)"
git rev-parse HEAD
mkdir -p build/acceptance
git rev-parse HEAD > build/acceptance/revision.txt
git -C "$THEOS" rev-parse HEAD > build/acceptance/theos-revision.txt
git -C "$THEOS" submodule status > build/acceptance/theos-submodules.txt
xcodebuild -version > build/acceptance/xcode-version.txt
xcrun --sdk iphoneos --show-sdk-version > build/acceptance/xcode-sdk.txt
ls -d "$THEOS"/sdks/iPhoneOS*.sdk > build/acceptance/theos-sdks.txt
brew list --versions xcodegen libarchive ldid-procursus xz python node gnupg \
  > build/acceptance/brew-versions.txt
```

### Cloud and public license pin prerequisite

Node.js 20 or later is required for the cloud/Blob tooling. Install the locked
dependencies and run the actual cloud suites from the review checkout:

```bash
node --version
npm --prefix cloud ci
npm --prefix cloud test
```

Deploy this checkout's `cloud/` application with its production authentication
and private-storage settings from [cloud/README.md](../cloud/README.md). Keep
existing auth/storage data and allow its frozen licensing migration to finish;
do not seed a new database over working devices. Set `APP_URL` to the phone's
canonical HTTPS origin, for example `https://console.example.net` without a path.

For a **new** deployment, generate the license keypair once outside the checkout:

```bash
python3 scripts/license-key.py generate \
  --directory "$HOME/.config/redditbox-signing"
```

For an existing deployment, reuse its matching public PEM; do not generate a
different pair merely to build an update. Configure the generated **private**
PEM as cloud `LICENSE_SIGNING_PRIVATE_KEY` through the deployment's secret
settings. Keep it out of the repository, deployment public files and test logs.
The phone build receives only the public PEM:

```bash
export LICENSE_PUBLIC_KEY_FILE="$HOME/.config/redditbox-signing/license-public.pem"
test -r "$LICENSE_PUBLIC_KEY_FILE"
```

The build derives its pinned RSA public key and key ID from this file. A missing
pin stops the build; a pin/private-key mismatch causes phone activation to fail
with an invalid signed-token/deployment-pin error even when the cloud responds.
An unsigned `valid=true` response cannot unlock the app. The separate GPG key in
the APT procedure signs package indexes and cannot substitute for this RSA key.

Log into the deployed cloud admin console, use **Create keys** to issue a device
license, record owner/label/expiry and leave maximum activations at 1 for a
single-phone test. Store its one-time plaintext key privately. A legacy website
access key is not automatically a new device key. The pre-existing token-paired
devices belonging to an admin at the frozen migration receive the implicit
admin entitlement; later pairings do not. A new deployment with no such devices
requires a device key.

### Build and retain evidence

For a local build acceptance attempt, run:

```bash
python3 tools/static_check.py | tee build/acceptance/static-check.log
unset DEVELOPMENT_TEAM
export RBX_PACKAGE_SCHEME=rootless  # Dopamine / palera1n rootless; use rootful for palera1n rootful
bash scripts/build-mac.sh 2>&1 | tee "build/acceptance/build-$RBX_PACKAGE_SCHEME.log"
```

`set -o pipefail` makes a failed build fail even with `tee`. Do not install a
previous `.deb` if this command fails. `scripts/build-mac.sh` runs its native
tests and SDK pasteboard check, generates
`build/network-extension/RedditBoxFirewall.xcodeproj`, archives it, signs it,
then packages with Theos. XcodeGen's `--project` takes the output directory;
`xcodebuild -project` uses that actual `.xcodeproj` inside the directory (C01).
The archive uses these settings already supplied by the script:

```text
SWIFT_VERSION=5.0 (project.yml; iOS deployment target 15.0)
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY=""
CODE_SIGN_STYLE=Manual
```

No Apple Development Team, signing certificate, provisioning-profile download,
Xcode automatic signing or `-allowProvisioningUpdates` is used. After the unsigned
archive, `scripts/sign-firewall-app.py` signs nested code, provider and host with
ldid, checks resource-envelope plists and reads back each slice's entitlements.
Theos receives `TARGET_CODESIGN="$LDID" TARGET_CODESIGN_FLAGS=-S` for the rest
of the package. This inspection does not prove that iOS will authorize the
`app-proxy-provider` and `group.com.redditbox.firewall` entitlements.

After successful completion, retain the package named by the build's final
output together with its hash and the logs:

```bash
RBX_VERSION="$(python3 -c 'import json; print(json.load(open("build/generated/release.json"))["version"])')"
case "$RBX_PACKAGE_SCHEME" in
  rootless) RBX_ARCH=iphoneos-arm64 ;;
  rootful) RBX_ARCH=iphoneos-arm ;;
  *) echo 'Select rootless or rootful first' >&2; exit 1 ;;
esac
RBX_DEB="packages/com.redditbox_${RBX_VERSION}_${RBX_ARCH}.deb"
test -f "$RBX_DEB"
printf '%s\n' "$RBX_DEB" > build/acceptance/package.txt
shasum -a 256 "$RBX_DEB" > build/acceptance/package.sha256
```

**UNVERIFIED build assumption:** there is no certified Xcode/Theos/SDK combination
yet. Preserve actual versions and the first failing test/compiler/signer output.
Do not skip a failing test, remove entitlements or switch to an Apple team to
turn this acceptance attempt into a different build path.

Transfer that `.deb` to the device and install with a dependency-resolving
package manager. Required packages from `control` are `mobilesubstrate`,
`ldid`, `ai.akemi.appinst (>= 2.1.1)`, `zip`, `ai.akemi.appsyncunified`, and
`uikittools (>= 2.1.6)`, plus firmware >= 15.0. Availability and operation on
the chosen jailbreak are **UNVERIFIED**; a dependency or entitlement failure
stops acceptance. The build does not require an Apple team; the separate MDM
service still needs its own enrollment and app-deployment infrastructure.

### Signed release and Sileo installation

For the distribution acceptance path, follow [APT distribution](apt-distribution.md)
to configure the dedicated public Blob store, Vercel project/token and separate
GPG signing key. `bash scripts/release.sh [X.Y.Z]` runs a fresh build itself;
the manual build above is an optional earlier build-only check. The release
script verifies the old signed repository before choosing a newer version,
uploads/inspects the new artifact, verifies a staged deployment, promotes it,
then verifies the public URL. Require its final `Published` output; a partial
upload or staged deployment is not publication. Resume failures with the retained
journal and `bash scripts/release.sh --resume`, never by deleting its lock.

Retain generated metadata for both `cloud/public/apt/redditbox/` (rootless) and
`cloud/public/apt/redditbox-rootful/` (rootful), whenever published, on the branch
used for future deployment, without merging this review branch into `master`.
Compare the exported GPG key's full fingerprint with the release Mac's trusted
fingerprint and install the `signed-by` key/source using the exact APT procedure.
Refresh Sileo, require the intended version in its package page and
`apt-cache policy com.redditbox`, then install/upgrade. `dpkg-query` and Diagnostics
must agree with the published version. Sileo handling of this signed flat source
and the chosen jailbreak's package dependencies remain **NOT RUN** until tested;
do not suppress signature checks with `trusted=yes` to make them pass.

## Deferred setup checks

Fresh install must show the license gate and local CLOSED state before proxy,
source or VPN configuration exists. **Diagnostics** and **Setup and maintenance**
remain reachable from that gate. The profile list/create/open flow requires a
current signed entitlement; no source or VPN is needed merely to activate it.
The optional smoke modes `setup`, `launcher`,
`profiles` and `clones` run local checks without requiring a provider status file.
`source` checks the imported private source separately. Only `status`,
`production` and `logs` require a configured, running provider. A missing source
is a setup prerequisite to display, not a reason for an empty launcher to fail.

## First-run device license

1. Open RedditBox and unlock its local passcode if one is configured. With no
   current entitlement, expect the **Device access** / **License key** screen,
   with profile content hidden and a clear activation reason. Diagnostics/setup
   must remain accessible even when the server is unavailable.
2. Enter the exact HTTPS **origin** configured as cloud `APP_URL`, without a
   path/query/login credentials, and the issued device key. Tap **Activate key**
   once. The key is saved in Keychain; the daemon verifies the RSA signature,
   installation UUID binding, key fingerprint, issuer, nonce and signed lifetime.
3. PASS requires the current daemon snapshot to become unlocked, the profile
   list to appear, and exactly one bound device/activation in **Manage device
   keys**. Activation already creates and saves the cloud device pairing. Do
   **not** create a second pairing code or overwrite the saved key/server in
   Settings as an additional activation step. Retry a lost response using the
   same key/device and require the same binding and activation count.
4. A pre-existing paired admin device in the frozen migration can instead tap
   **Validate paired device** using its saved server/token. The first validation
   binds its Keychain installation UUID before issuing a signed entitlement.
   This exemption does not grant permanent access to later paired devices.
5. Record the license state/deadline and cloud device ID privately. No raw token
   or key may appear in the launcher state snapshot, IPC request or shared logs.
   A wrong key, second device beyond `maxActivations=1`, mismatched signing pin,
   malformed response or missing private signer must not unlock traffic.

License validation is due daily and before each Open. Active sessions additionally
check on a nominal 60-second schedule, subject to the daemon's 10-second scheduler,
request completion and queue latency; measure actual closure on the phone.
This is periodic revocation, not a promise of zero-latency server push. A transient
network/429/5xx failure can use a previously verified signed entitlement until
its deadline, at most 72 hours from issue and never beyond license expiry.
An explicit signed denial locks access immediately after verification. An
unactivated device has no offline grace.

| License case | Required result and evidence |
| --- | --- |
| First launch without network/token | Activation reason visible; no profiles/open; diagnostics/setup available; CLOSED retained |
| Same-device retry/restart | Same Keychain installation binding and one activation slot; no duplicate cloud device |
| Offline after successful activation | Show grace/deadline; use only still-valid signed access; no deadline extension on retry |
| Signed expiry/grace deadline | Gate returns, active clone is closed/stopped, files retained; stale launcher snapshot cannot keep profiles unlocked |
| Revoke or delete a device key online | Next completed validation closes/stops the active clone and shows the reason; record server action, validation and CLOSED timestamps plus capture |
| Re-enable a revoked key | Revalidation may restore access if it is still unexpired; permanently deleted keys cannot be re-enabled |
| Restart during outage/revocation | Establish CLOSED before renewal/validation; never reuse the previous daemon epoch to reopen |

The native Mac license tests exercise clock/grace boundaries with fixtures.
A physical 72-hour outage is **NOT RUN** until that time-based acceptance test
is actually performed. Changing the phone clock is not equivalent evidence;
clock rollback is separately refused. Keep disposable profile IDs/data sentinels
across revoke/re-enable/restart to prove the gate did not delete them.

## First-run setup and HTTP proxy contract (H15)

1. After license activation, open the first-run wizard or **Settings** and enter
   the **HTTP** proxy URL, HTTPS rotation URL, authorization header/value and
   GET/POST method. Keep the already activated access key and HTTPS server.
2. Tap **Save and test connection**. The test intentionally performs one
   rotation and proxy exit check while Reddit traffic remains denied.
3. Pull to refresh/sync the device already paired by activation. If the cloud
   has an assigned proxy/rotation configuration, its encrypted rotation settings
   can replace/fill the Keychain fields. Recheck the effective URL/country after
   sync. The legacy **Pair and sync cloud settings** controls are for an explicit
   legacy pairing workflow, not a required second step after license activation.
4. Check the source indicator. If it says no source or encrypted source, place
   a legally obtained decrypted Reddit IPA in Files and choose
   **Settings → Import Reddit IPA from Files**. This validates and privately
   caches it without installing a visible source app. Its `MinimumOSVersion`
   must fit the physical phone; import cannot make a newer executable compatible.
5. Create A and B as described below, then complete MDM deployment before
   choosing **Settings → Open firewall setup**. Local setup can run while CLOSED.
6. Optional: set the latest known Reddit version and check interval under
   **Reddit update monitoring**. Changes hot-reload the daemon timer.

Saving configuration takes effect immediately. The daemon reads the shared
Keychain on every operation and closes any old lease when configuration
changes; no manual daemon restart is needed.

**H15 deliberately removed SOCKS5 support.** The upstream proxy must speak HTTP
proxy protocol at an explicit port. It forwards HTTP and uses CONNECT for HTTPS
destinations. The URL describes the connection to the proxy, so an HTTPS Reddit
destination still uses an `http://` proxy URL. There is no TLS-to-proxy transport.

| Field | Format / example (replace placeholders) |
| --- | --- |
| Proxy URL | `http://proxy.example.net:8080` |
| Authenticated proxy URL | `http://user:password@proxy.example.net:8080`; percent-encode reserved credential characters once, e.g. `@` as `%40` |
| Proxy endpoint rules | Explicit port 1–65535; no path except optional `/`, query or fragment; HTTP Basic/Digest support still needs a real endpoint test |
| Unsupported proxy input | `socks5://`, `socks5h://`, `https://`, a bare `host:port`, or a URL without a port are rejected |
| Rotation URL | `https://…` API endpoint, separate from the HTTP proxy; its own authorization header/value and GET/POST method |
| License/cloud URL | Canonical `https://HOST` origin from activation, separate from proxy and rotation URLs |

Do not merely change a SOCKS endpoint's scheme: obtain the provider's actual
HTTP/CONNECT endpoint and credentials. Legacy unsupported records may remain
visible but cannot launch; replace them in local/cloud settings and each affected
profile assignment. Cloud sync may replace local settings, so verify the effective
configuration after refreshing. Require both a successful rotation test and a
changed exit IP in the intended country; a successful control API alone is not
proof of a working proxy. An ordinary HTTP proxy also does not encrypt the hop
to the proxy or its authentication headers; capture files can contain secrets.

Try a valid HTTP endpoint and invalid credentials, then confirm that SOCKS5 and
HTTPS-proxy inputs are rejected. Restore the valid endpoint before proceeding.

## Launcher and clone provisioning

The package manager resolves declared dependencies for `ldid`, `appinst`,
`zip`, and AppSync Unified; ensure their repositories are configured before
installing the `.deb`. Supply a legally obtained decrypted Reddit build as the clean source.
A normal encrypted App Store binary cannot be cloned by `ldid`. For daily
operation, open **RedditBox**, tap `+`, choose a name/country, and wait for the
container to appear. The daemon generates the identity, transactionally builds
the hidden clone, and leaves it inactive with network denied.

This builds a transaction-staged IPA, assigns a deterministic
bundle/keychain identity, removes embedded extensions, provisioning, shared
services and push capability, signs every nested Mach-O inside-out, verifies
effective entitlements, and installs through `appinst`/`installd`. A failed
upgrade attempts to restore the prior IPA; failed recovery must retain its
journal/backup for inspection. Clones contain signed `SBAppTags=hidden` and
`RBXLauncherOnly` markers; the daemon refuses a clone missing either marker.

Swipe right on the container and choose **Share IPA**. Save or upload that exact
IPA to MDM, then install/adopt it with the generated `VPNUUID`. A locally
installed AppSync clone is not automatically a managed app. Existing profiles
migrate at daemon startup; **UNVERIFIED:** migration, rollback and retention of
existing user data/login still require device acceptance. Do not infer success
from profile rows alone.

## Lifecycle, roles and anonymous account status

Use disposable profiles for the first **create → replace → delete → create →
open → login** sequence. Replacement intentionally deletes the old profile's
app data and credentials after its prerequisite steps succeed.

1. After license, proxy test and source import, create `Lifecycle test` with
   role `warmup`. Keep it inactive; do not Open or enter Reddit credentials yet.
   Record its profile/bundle IDs and generated persistent identity values.
2. Choose **Replace with new**. Require a successful proxy rotation before
   the old profile is deleted. The replacement must have the same name and
   role, a new profile/bundle identity, fresh persistent identifiers, and empty
   notes/login. A catalog model/iOS tuple may repeat; nonzero persistent
   identifiers must not reuse those reserved by previous profiles. A blocked
   all-zero IDFA is a shared privacy sentinel, not a unique identifier. The action ends CLOSED
   and the new clone requires fresh MDM export/adoption before Open.
3. Delete that unused replacement through its explicit confirmation. Require
   its clone data and Keychain cleanup to complete and its old ID to remain
   retired. Cloud refresh must not resurrect it. On failed cleanup, keep the
   visible recovery row/journal; do not mistake partial disappearance for success.
4. Create A and B and record their IDs. Complete the MDM steps below, then
   Open A under capture and run the login checks. Each Open performs its own
   protected rotation even if a prior Replace already rotated.

For replacement failure coverage, create another inactive disposable profile,
record its data sentinels, then make the rotation fail or return an unchanged
exit. Require the original profile/data to remain intact and the candidate to
stay blocked from Open. Restore configuration and use **Resume Replace**;
require the same journaled candidate and a single committed replacement. Pending
replacement rows must not expose an independent Delete that strands the journal.
Record interruption at each durable phase in the Mac fixture tests; repeat
representative interruption/restart cases on the phone. Failed recovery retains
its journal/backup and must remain visible.

Replacement of an active profile is disabled. Later in acceptance, switch to B
before replacing A. To close the last active session, force-quit its clone and
wait for the termination watcher/CLOSED evidence, or use **Settings → Save and
test connection**, which deliberately closes the session and performs an extra
rotation. There is no dedicated Close session button in this revision. A
backgrounded Reddit app is still potentially active; confirm actual process
termination/CLOSED before expecting Replace to become available.

Test **Role & notes** on the launcher and corresponding cloud profile row:

- All four roles, `signup`, `warmup`, `spam`, `default`, are organizational
  labels only. Switch role filters/grouping and change the default role for new
  profiles in Settings. These values must not change identity, proxy assignment,
  activation, VPN policy or dispatch behavior.
- Save notes up to 200 Unicode scalar values; reject an over-limit edit without
  truncation or damage. Include emoji/non-ASCII text. Pull to refresh and require
  the same role/notes and existing immutable profile ID on both sides.
- Make competing local/cloud edits: preserve the unsynchronized local version
  visibly until conflict resolution. **Use cloud role & notes** explicitly
  chooses the cloud version. Retry a lost successful response and require its
  acknowledged revision to clear the pending marker rather than conflict forever.

Choose **Check account status**, enter the intended username if needed, and
explicitly load its public page. Require a fresh anonymous snapshot through the
configured HTTP proxy, with no profile cookies, account credentials, cache reuse
or page subrequests. This viewer uses the currently configured proxy; it does
not rotate for each view. Show URL/HTTP status and interpret the page manually.
A 404 is **inconclusive**, not proof of a shadowban. Capture the viewer's traffic
and test failure/redirect cases; proxy behavior and WebKit rendering still need
real-device acceptance.

## MDM export and per-app VPN association — H08 remains open

Use a test device enrolled with an MDM service capable of deploying
this app-proxy payload and adopting these exact clone IPAs. The repository does
not supply that service. **UNVERIFIED prerequisite:** an MDM server may reject
ldid-signed/AppSync-installed apps or fail to adopt them on the chosen jailbreak.
Successful local installation is not successful managed installation. Stop and
record that failure; do not substitute a re-signed app with different identifiers
or entitlements and count it as this build's acceptance.

The iOS AppLayerVPN payload does not itself require supervision. Confirm the
service's enrollment/adoption requirements before changing device management;
do not erase the phone as a default setup step. Manual payload installation
does not establish the effective managed-app VPN association. With no MDM
service, online acceptance in this build remains NOT_RUN. See the
[transport constraints](firewall-transport.md#without-an-mdm-service).

1. After package installation, require one **RedditBox** icon and a running
   `redditboxd`. The hidden firewall host and individual clones must not appear
   as daily launcher icons. Create two disposable profiles A and B while clone
   traffic is CLOSED, after license activation and source/proxy setup;
   keep identity changes before first use. Export each exact signed IPA using
   the container's **Share IPA** action and record profile ID, bundle ID, version
   and IPA SHA-256. Never guess the deterministic bundle IDs from profile names.
2. Choose **Settings → Share MDM/VPN setup files**. Save both
   `redditbox-per-app-vpn.mobileconfig` and `redditbox-mdm-app-mapping.json`.
   The JSON is instructions/data for the administrator, not an installable MDM
   payload. It contains `vpnUUID` and `assignments[]` entries with `profileId`,
   `bundleIdentifier`, and `Attributes.VPNUUID`.
3. Inspect and deploy the `.mobileconfig` through MDM. Match these exact fields
   from [RBXMDMExporter.m](../launcher/RBXMDMExporter.m):

   | Field | Required value |
   | --- | --- |
   | VPN payload type | `com.apple.vpn.managed.applayer` |
   | `VPNType` / `VPNSubType` | `VPN` / `com.redditbox.firewall` |
   | `VPN.ProviderType` | `app-proxy` |
   | `VPN.ProviderBundleIdentifier` | `com.redditbox.firewall.PacketTunnel` (name retained; implementation is `NEAppProxyProvider`) |
   | VPN payload `VPNUUID` | Same UUID as JSON `vpnUUID` and every assignment's `Attributes.VPNUUID`; **not** a `PayloadUUID` |
   | On Demand | `VPN.OnDemandEnabled=1`, `VPN.OnDemandRules=[{"Action":"Connect"}]`, `OnDemandMatchAppEnabled=1`; no Disconnect rule |
   | `VendorConfig` | `policyVersion=2`, `scope=per-app`, nonempty `managedBundleIdentifiers` containing A, B and `com.reddit.Reddit` |
   | Browser flag | `outOfProcessAuthCovered=false`; exported `SafariDomains` are requests, not proof of browser coverage |

4. In the MDM's managed-app deployment workflow, install/adopt each exported IPA
   and associate it with that VPN UUID. For an already managed app, the classic
   Apple MDM `Settings` command carries the association as `ApplicationAttributes`,
   not as an app configuration key. The command dictionary below illustrates one
   entry; replace both placeholders with the export's values, repeat for B, and
   retain any other required existing app attributes through the MDM's workflow:

   ```json
   {
     "RequestType": "Settings",
     "Settings": [{
       "Item": "ApplicationAttributes",
       "Identifier": "<exact-clone-bundleIdentifier>",
       "Attributes": {"VPNUUID": "<exported-vpnUUID>"}
     }]
   }
   ```

   Let the MDM server construct/send the enclosing command and retain its device
   response. If the service uses declarative app management, use its equivalent
   supported workflow; the classic command is not applicable to declaratively
   managed apps. See Apple's [ApplicationAttributes schema](https://github.com/apple/device-management/blob/release/mdm/commands/settings.yaml)
   and [AppLayerVPN guidance](https://support.apple.com/en-gb/guide/deployment/dep0323d652d/web).
   MDM console labels and adoption support are vendor-specific and unverified.
5. Also associate `com.reddit.Reddit` while it remains installed/registered; the
   exporter marks it `__original_reddit_deny_only__`. It is never an authorized
   active clone. Record it as absent if using only the private unregistered source
   cache. Do not assign the launcher, daemon or firewall host as target clones.
6. Retain deployment acknowledgements and effective app attributes for A/B and
   the original, not just screenshots of a queued MDM action. Re-export/update
   the provider bundle list for added/deleted profiles. After any local clone
   rebuild/identity apply/source upgrade, re-share, re-adopt and recheck the exact
   installation: `appinst` may clear managed state. The VPN UUID is stored in
   launcher defaults, so after a launcher reset compare it again instead of
   assuming that a fresh export reused the old UUID.
   Also repeat adoption for a replacement's new bundle ID and whenever an
   installed update reports `requiresMDMReadoption=true`.
7. Choose **Settings → Open firewall setup**. Expected host result: managed app
   proxy started, traffic remains closed until a clone lease is authorized.
   A message that managed per-app VPN is not configured means the host could not
   find its expected managed configuration. A start/entitlement error is a FAIL.
8. Run **Diagnostics**: require fresh daemon/provider heartbeats, lease/provider
   state and generation agreement, per-app scope and valid managed clones.
   `transport` must be `app-proxy`. The UI/smoke script may still call this a
   “packet firewall”; that wording is not a packet-tunnel implementation.

**H08 — OPEN implementation gap:** LaunchServices `isManaged`,
`managedBundleIdentifiers`, `scope=per-app`, and a green diagnostic result do not
prove that iOS actually associated this installation with the intended VPNUUID.
“Managed routing verification” remains informational. The daemon rejects missing
managed status, but a managed app with a missing/wrong VPN UUID can pass the
weaker checks. Require effective OS app-rule evidence where available and the
captures below. Deliberately missing/wrong association must fail acceptance even
if Diagnostics stays green. A future fix must verify the effective per-app rules
against the clone identity and intended VPN before admission; not implemented.

Provider stop/crash/disable and mapping removal are also **UNVERIFIED** on-device
denial cases. Connect-only On Demand is not an established device-wide Always On
guarantee. This project supplies no independent always-on gateway. See
[firewall transport and disconnect tests](firewall-transport.md); do not claim
protection for an unassigned app or a provider that iOS fails to enforce.

### Identity editor

Before opening a new container, tap it and choose **Identity & Cloaking**:

1. Run **Check consistency** in Coherent Random mode; require a green result.
2. In Advanced Manual mode, change country away from the displayed proxy
   country. Require an immediate red warning and daemon rejection.
3. Restore the proxy country. Try a device/iOS/build tuple outside the validated
   synthetic catalog; require rejection. A coherent catalog tuple may differ
   from the physical phone: C05 removed physical-equality validation. Separately
   check the source executable's real OS/architecture compatibility.
4. Test a valid locale, timezone, carrier MCC-MNC, city, IDFA posture and
   security-policy combination, then apply it.
5. Re-share/re-adopt the rebuilt clone in MDM.
6. After first use, verify identity controls are frozen. Only compatibility
   policy switches should remain editable.

After confirming that required source-app data has been migrated or backed up,
choose **RedditBox → Settings → Hide source Reddit app**. Confirm the warning:
the daemon copies the decrypted source to
`/var/mobile/Library/RedditBox/Source/Reddit.app` with root-only permissions,
then uninstalls `com.reddit.Reddit` and its old data container. Do not use this
action until losing the source app's data is acceptable.

Run the launcher Diagnostics screen. Confirm there is one launcher icon, no
legacy long-press/SpringBoard integration, and every clone reports isolated,
hidden, signed, and MDM-managed.

The launcher must list name, country/identity, proxy state, last-active time,
last authenticated Reddit API activity, hook readiness, VPN state, and health.
Pull to refresh after creating a profile
in the cloud console; the profile must appear locally, be cloned, and remain
offline until opened. Set a launcher passcode, background/reopen the app, and
verify the list and actions stay blurred until the correct passcode is entered.

## Launcher appearance and accessibility

The launcher now uses profile cards, a setup/session overview, grouped form
sections and a shared light/dark palette. These are UIKit presentation changes;
the daemon still controls every operation. **Device rendering is unverified.**
Open [the browser design preview](launcher-preview.html) locally on a PC or Mac
to review the palette and spacing with sample data. It is not an iOS screenshot
or a substitute for the checks below.

- Check an empty inventory, unavailable inventory, inactive/active/switching
  profiles, failed profile load and incomplete deletion. Long names and warning
  messages must wrap instead of disappearing. An unavailable inventory must not
  suggest that it is safely empty.
- Check light and dark appearance on the smallest supported phone, default text
  size and the largest accessibility text sizes. Verify every action remains
  reachable, including consistency/apply and all compatibility switches.
- Open the keyboard on fields near the bottom of Settings and Identity; scroll
  to the field and dismiss the keyboard. Keep error and pending-result messages
  readable after returning to the app.
- With VoiceOver, confirm fields/switches have meaningful names and profile cards
  announce name, state and metadata. Locked profile content must not be readable
  through VoiceOver or actionable behind the passcode prompt.
- Retest the existing create/open/share/delete confirmations and recovery rows.
  Diagnostics must still distinguish PASS, FAIL and INFO in text, not color alone.
  The overview is a state summary, not a new claim of verified VPN routing.
- Repeat activation/retry, key entry with the keyboard visible, expired/revoked
  state, role filters, long notes and pending replacement rows. The local passcode
  and license gate both hide profile content; stale daemon state must return to
  a locked view without covering the available diagnostics/setup actions.

## Hook startup

Open **RedditBox → Settings → Diagnostics** while the selected container is
running. Use **Share Logs** when support needs the detailed redacted report.

Use the final `HOOK READINESS VERIFIED` evidence for the tested full request ID,
generation and clone PID. Installation self-reports can precede the bounded
clone-local control-state wait; an earlier NOT_READY from another process or
generation is not the final result. Missing/failed final mandatory installation
or behavior evidence blocks launch. Require the same generation's provider OPEN
acknowledgement before NETWORK OPEN.

For optional developer shell verification, run as root on the phone:

```sh
# Set the prefix from the active package-manager architecture on the phone.
case "$(dpkg --print-architecture)" in
  iphoneos-arm64) RBX_PREFIX=/var/jb ;;
  iphoneos-arm) RBX_PREFIX= ;;
  *) echo 'Unsupported package architecture' >&2; exit 1 ;;
esac
"$RBX_PREFIX/usr/share/redditbox/on-device-smoke.sh" logs REQUEST_UUID GENERATION_UUID CLONE_PID
```

Use full UUIDs from the correlated operation/log records and the tested live
clone's PID. The checker scopes to that operation and verifies the final three
authorization events, not all historical self-reports in a broad log window.
The launcher Diagnostics/Share Logs flow remains the daily workflow.

## Critical Reddit path

Create and open a fresh container from RedditBox:

1. Password login.
2. Browser/OAuth login, if used: **OPEN ISSUE**, not a supported/proven path in
   this revision. Use the triage table below; a blocked required login is a FAIL,
   even if that denial is the intended safety behavior. Record whether password
   login itself invokes browser authentication in this Reddit version.
3. Browse home and subreddit feeds.
4. Vote and confirm the vote persists.
5. Create then delete one comment.
6. Create then delete one test post.
7. Close Reddit and reopen the same container; native login must persist only
   in that container.
8. Open another clone; it must have a different bundle ID, OS data-container
   UUID and keychain access group, and must not inherit account, cookies,
   drafts, cache, WebKit state, or keychain data.

### First-login triage — browser coverage and callback ownership

| Open issue / assumption | Expected symptom and evidence | Candidate fix (not implemented) |
| --- | --- | --- |
| Separate browser process has no verified VPN coverage | Login sheet never appears, login button returns/cancels or stalls. `ASWebAuthenticationSession.start` returns `NO`; look for `blocked ASWebAuthenticationSession without managed SafariDomains VPN coverage`. Provider publishes `outOfProcessAuthCovered=false` regardless of exported SafariDomains. | Prove browser/service process routing and cookie separation, then implement narrowly scoped flow admission tied to the initiating clone/session. The current provider only admits the active clone's signing identifier; adding SafariDomains or changing a flag alone cannot fix this. |
| Shared callback ownership across clones | If another login API reaches a browser, redirect may open the original/wrong clone, which the watchdog should terminate; initiating clone stays logged out, spinner persists or login repeats. A wrong-clone kill is containment, not a successful login. | Inspect the actual OAuth client/redirect contract. If the service accepts it, coordinate a clone-specific redirect URI in both the auth request and callback registration/handler. For a fixed shared redirect, design an authenticated callback broker bound to the initiating session/clone. Either approach requires redirect/state validation and multi-clone routing tests before removing shared schemes. |

Relevant sources: [web-auth hook](../tweak/Container/RBXWebStorageHooks.xm),
[provider admission/status](../network-extension/PacketTunnel/PacketTunnelProvider.swift),
and [clone URL registration](../daemon/RBXCloneManager.m). Clones keep the source's
`CFBundleURLTypes` (including `reddit://` when present) and add a diagnostic scheme
`reddit-<bundle-id-last-component>`. The extra scheme does **not** rewrite Reddit's
OAuth `redirect_uri`. Associated-domain entitlements are removed, so universal
links are also unverified.

For each attempt record initiating profile/bundle/PID, request/generation,
auth API, redirect scheme/host, foreground recipient bundle/PID, watchdog result,
and whether a cookie/account appears in B. Retain a redacted timeline; exclude
authorization codes, tokens, password fields and query secrets from shared logs.
Repeat after swapping install order and with the original installed/absent.
Do not disable the watchdog, remove the browser guard or set the coverage flag
to make login pass. Both coverage and callback ownership must be resolved for
browser login acceptance.

Clipboard is blocked by default; inability to paste a password may be the
`security.systemClipboard` policy, not a failed callback. Type manually first.
Only enable the explicit per-profile clipboard compatibility switch if needed,
recording that it exposes the shared system clipboard. App Attest/DeviceCheck
exceptions have a separate test below; neither repairs browser routing.

## Switch and rotation ordering

Select B in RedditBox while A is loading a feed. Logs must occur in this order:

1. `NETWORK CLOSED`
2. `KERNEL SOCKET TABLE CLEAN`
3. `SYSTEM FIREWALL ACK state=closed`
4. `ROTATION CALLED`
5. `ROTATION ACKNOWLEDGED`
6. `FRESH IP APPLIED`
7. `NETWORK ARMED`
8. `SYSTEM FIREWALL ACK state=armed`
9. `HOOK READINESS VERIFIED`
10. `SYSTEM FIREWALL ACK state=open`
11. `NETWORK OPEN`

There may be additional validation, license, cloud and socket-drain records
between these events. CLOSED uses a separate revocation generation; ARMED,
readiness and OPEN must agree on B's full generation. Capture the full request
UUID and B PID from the correlated records rather than the shortened initial
open-request line. The smoke `logs` mode checks only the final readiness → OPEN
ACK → NETWORK OPEN subsequence, not the whole switch or any packet behavior.
P314 deliberately scopes the boot token per clone: compare A/B against their own
receipts, not for raw epoch equality across clones or with the root daemon file.

### Traffic-capture checklist for A → B → A

**UNVERIFIED acceptance gate:** logs alone cannot establish traffic denial.
Capture before opening A and continue through the switch, failures and at least
10 seconds after the last transition. Use disposable accounts/test content.

- [ ] Record checkout/package hash, actual device/jailbreak, Reddit version,
  A/B bundle IDs/PIDs, MDM VPN UUID, active interface, proxy host/port/resolved
  IPv4/IPv6 addresses, exit IP before/after each rotation, and proxy country.
  The proxy's ingress address may stay unchanged while its public exit rotates.
- [ ] Synchronize capture/proxy/log clocks or measure their offsets. Record the
  time of the tap, CLOSED ACK, rotation, final hook readiness, OPEN ACK and OPEN.
- [ ] Use Mac USB RVI for device-wide capture and an independently controlled
  Wi-Fi gateway/AP uplink capture plus proxy access/connection logs where
  available. For the Wi-Fi run disable cellular fallback; repeat cellular-only
  and Wi-Fi/cellular handoff with capture covering those paths. An AP capture
  alone cannot certify cellular traffic. RVI includes logical/local traffic;
  distinguish physical egress using interface metadata and the external capture.
- [ ] Capture all traffic, not only the expected proxy IP or TCP/443. Check capture
  drop counters and a known test request to prove the interfaces are visible.
  Missing traffic, missing interface coverage or unexplained drops means NOT RUN
  or an inconclusive result, never proof of denial.

Optional Mac RVI commands (USB-connected, unlocked/trusted phone; find UDID in
Xcode **Window → Devices and Simulators**):

```bash
export RBX_DEVICE_UDID='replace-with-device-UDID'
rvictl -s "$RBX_DEVICE_UDID"
# Read the reported interface; substitute it below if it is not rvi0.
export RBX_RVI='rvi0'
sudo tcpdump -i "$RBX_RVI" -nn -s 0 -U -w rbx-ab-switch.pcap
# Stop tcpdump with Ctrl-C only after completing the test; record drop counts.
rvictl -x "$RBX_DEVICE_UDID"
```

If `rvictl` is not on PATH, check `/Library/Apple/usr/bin/rvictl`. If Xcode cannot
pair/capture this jailbreak/OS, record the limitation and use verified external
capture coverage; do not infer that there is no traffic. Apple's
[packet trace procedure](https://developer.apple.com/documentation/network/recording-a-packet-trace)
describes RVI setup and interface metadata. On your controlled gateway/proxy,
use its actual interface names and preserve full packet timestamps. PCAPs can
include proxy authentication and unrelated device traffic; retain originals
privately and share redacted evidence.

- [ ] With A OPEN, demonstrate a real bidirectional Reddit request through the
  configured HTTP proxy. Record long-lived connection/flow IDs using proxy logs
  and, where available, app/process metadata. A device IP or exit IP alone cannot
  distinguish A from B. Put A into a feed/video load, pending upload or WebSocket
  transfer that the tested client actually supports; mark unavailable cases NOT RUN.
- [ ] Tap B while A is active. Verify A's exact process exits and RedditBox stays
  alive. After the CLOSED ACK, require no new A application payload at physical
  egress via either old or new exit, and no old A flow resuming in B's generation.
  Record teardown ACK/FIN/RST separately from payload. Investigate any apparent
  late payload with timestamps/sequence numbers at both capture points; a packet
  already in transit is not evidence of newly emitted A data, but must be accounted
  for before a PASS.
- [ ] During CLOSED/ARMED require no clone TCP payload. ARMED permits only local
  DNS answers for the proxy hostname; it must not send DNS upstream. The daemon's
  HTTPS license/cloud/rotation calls, control DNS resolution and proxy exit-health
  probes can occur before B OPEN. Attribute those by process/connection/timing;
  do not whitelist all proxy/control traffic merely because the destination fits.
- [ ] Require B's final matching readiness, provider OPEN ACK and NETWORK OPEN
  before B emits application payload. Its physical provider connections may target
  only the authorized numeric proxy address and port. Confirm the observed exit
  changed and matches B's configured country; confirm no A login/cookies in B.
- [ ] Inspect IPv4 and IPv6 for direct Reddit/CDN/identity-provider destinations,
  UDP/TCP DNS (53), DoT (853), QUIC/UDP 443, STUN/WebRTC and unexpected listeners
  or flows. DoH can look like HTTPS: destination/flow attribution and controlled
  probes are needed; a port-53 filter is not a complete DNS-leak test.
- [ ] Repeat B → A, rapid alternating taps and relaunch of the same profile.
  Repeat with pending background requests, WebKit and uploads if reachable.
  Test direct TCP, IPv6, UDP/QUIC and DNS from a clone-context probe if available;
  an unrelated shell `curl` is not covered by the clone's per-app assignment and
  cannot validate it. Missing clone probes remain NOT RUN.
- [ ] Repeat under the failure matrix below: proxy/rotation failure, daemon
  heartbeat expiry/restart, provider crash/stop/disable, wrong/missing VPN mapping,
  and disabled tweak injection. No direct fallback is acceptable. Restore and
  re-verify MDM/configuration between cases; never reuse an old generation as proof.

Attach a result row per run: direction/fault, request UUID, CLOSED generation,
new generation, clone PID, event timestamps, proxy flow IDs, old/new exit,
PCAP filenames/clock offsets/drop counts, observed direct bytes, PASS/FAIL/NOT RUN.
If encrypted streams cannot be attributed to A/B, label that part inconclusive
and obtain correlated proxy/process evidence before acceptance.

## Fail-closed tests

Perform each test, then restore configuration:

- In a configured production test, Diagnostics must fail if the app-proxy
  provider is absent or unenforced. Fresh offline setup can instead report deferred.
- Diagnostics must fail if the daemon/provider heartbeat is older than 2.5
  seconds. Verify closure with capture within the 2.5-second freshness bound plus
  polling/scheduling latency (provider polls every 100 ms); record measured timing.
  Kill/restart each service separately with a live transfer. Old epochs/readiness
  must not reopen; daemon startup must establish CLOSED before lease renewal.
- Use an unreachable proxy: rotation validation must fail and Reddit must stay closed.
- Use a rotation endpoint returning HTTP 500: no launch and no open lease.
- Make rotation return the previous exit IP: launch must be refused.
- Remove/corrupt the profile JSON: daemon must refuse launch.
- Launch original Reddit directly with no selected container: watchdog must kill
  it and the assigned app-proxy provider must deny its flows. Mark NOT RUN if the
  original is absent. Also test a wrong clone and require the launcher to survive.
- Temporarily disable tweak injection: Reddit must still have no direct
  connectivity through the managed app proxy. Failure to launch due to missing
  readiness is necessary but does not alone prove OS traffic interception.
- Force an unresolved proxy hostname: firewall arming must fail.
- Change a clone's `CFBundleIdentifier`, remove its metadata, or alter its
  profile `app.bundleIdentifier`: daemon must refuse launch.
- Remove `SBAppTags=hidden` or `RBXLauncherOnly` from a clone and re-sign it:
  daemon validation must refuse launch and the lease must remain closed.
- Inject a forged/malformed request into the durable
  `/var/mobile/Library/RedditBox/IPC/Inbox` using a disposable queue-test fixture
  (the legacy singleton pending plist is retired). Darwin notifications only
  wake the queue; they must not bypass clone/profile/MDM eligibility/license
  validation. Inspect the correlated rejection receipt and confirm CLOSED.
  H08's effective VPN-assignment gap remains separate from request validation.
- Remove/change the clone's MDM `VPNUUID` association while leaving it managed:
  H08 means Diagnostics/`scope=per-app` may still pass. Require actual routing
  evidence/capture to expose the missing protection and mark acceptance FAIL.
  Restore the intended UUID and verify it again before any other run.
- Stop/kill the provider and separately disable VPN during transfer; verify no
  assigned clone falls back to direct egress while the provider is unavailable
  or restarting. If MDM prohibits the disable action, record that enforcement
  and test provider crash separately. Expected OS behavior is unverified.

## Upgrade acceptance with five profiles

Use five profiles that have completed the source/MDM setup; include distinct
roles/notes and disposable login/data sentinels. Record all profile IDs, clone
bundle IDs, OS data-container UUIDs, identity values, effective VPN UUIDs,
Keychain/account state, installed package version and signed repository version.
Close the active clone and retain a diagnostic/support snapshot before upgrading.

1. Publish a strictly newer version with the same license public pin and stable
   launcher/host/provider IDs using `scripts/release.sh`. Keep the newest three
   indexed versions according to the release procedure. An unchanged signing
   contract can retain its value; changed clone signing/entitlement behavior
   must carry `requiresMDMReadoption=true` rather than silently promising reuse.
2. Refresh the trusted source and upgrade through Sileo/APT. Require maintainer
   scripts to stop/restart the daemon and register only the launcher/host, with
   no global clone unregister and no user-store/profile/Keychain removal.
3. Require startup to establish CLOSED before migrations or renewal. Diagnostics
   must report the actual installed version and the five retained containers in
   **Installed update**, with **Data schema and startup** successful. Compare all
   five IDs, identities, role/notes and data sentinels with the saved record.
4. The current central store/profile schema is version 2. Older supported
   documents migrate sequentially and retain unknown fields. A corrupt document,
   unknown newer schema or unsafe recovery journal must preserve the original
   bytes and block startup/traffic with a recovery error. Use the isolated Mac
   schema fixtures for those fault cases; do not edit the only copy of live data.
5. Recheck every managed per-app VPN association. If re-adoption is required,
   export/adopt the exact current clone IPAs and new mapping before opening.
   Open each profile individually and verify its own login/data only, then repeat
   A/B capture, revocation and browser callback triage. Row count alone cannot
   prove session or Keychain retention.

Record package/version/hash before and after, migration receipt, all five profile
IDs, effective MDM evidence and login/capture outcomes. Full Sileo upgrade,
Keychain/session retention and the interrupted-upgrade recovery path remain
**NOT RUN** until those phone checks complete. Downgrading to a binary that does
not understand version 2 is not a recovery procedure; do not delete its refusal
marker, central store or journals to force it to start.

## Recovery assumptions to record

- **H12 OPEN:** a persistent unsafe-operation fence can block subsequent actions
  with an Operation recovery failure. Safe in-app fence recovery is missing.
  Preserve the diagnostic, journal and backup; do not blindly delete the marker
  or retry destructive work. Recovery needs proof that timed-out external work
  is quiescent before reconciliation; no supported button/command is claimed here.
- **Export recovery OPEN:** interrupted share delivery can leave a pending daemon
  IPA export; legacy temporary copies also need verified ownership/cleanup.
  Record a refused retry and retained files, not a successful recovery. New share
  directory cleanup does not establish recovery from a lost receipt.
- **Storage/login UNVERIFIED:** device-scoped snapshot restore is not portable
  keychain/account transfer. Test same-device restore with data sentinels and
  actual login, installer rollback with an existing working clone, and explicit
  active/last-profile deletion on disposable data. Preserve failed journals and
  backups. Use measured results rather than assuming all prior logins survive.

## 30-profile storage/resource test

Create 30 empty profiles with the launcher `+` button and run Diagnostics. Only
one clone process may exist at a time. Review capacity in iOS
**Settings → General → iPhone Storage**.

`installd` owns each bundle and data container, so plan conservatively for:

`30 × (full installed app + profile data)`, plus one staging/rollback IPA.

For a typical 300–500 MB Reddit bundle and 100–500 MB of warmed profile data,
30 profiles need roughly 12–30 GB. Keep at least 20% free space and enough
temporary room for the source, new IPA, and rollback IPA. Record actual
`du`/`df` output; these are estimates, not a guarantee for every release.

## App Attest / DeviceCheck A/B

Both are `blocked` by default. First complete the critical path while blocked.
If login fails, enable only App Attest for one disposable profile and repeat.
If still required, separately enable DeviceCheck. Enabling either exposes a
physical-device Apple signal and weakens cross-profile unlinkability; never
enable globally or silently.

Record the profile, policy, login result, Reddit version, iOS version, exit IP,
and relevant error before deciding to retain an exception.

## Final leak-hunt probes

Static checks cannot prove these; repeat them on every supported iOS/Reddit build:

- Compare `kern.boottime`, `NSProcessInfo.systemUptime`, `mach_absolute_time`,
  and `clock_gettime(CLOCK_MONOTONIC)` across two relaunches per profile.
- Exercise `getaddrinfo`, `gethostbyname`, `res_query`,
  `DNSServiceGetAddrInfo`, `CFHost`, and Network.framework under packet capture.
- Attempt TCP, UDP/443, raw ICMP, IPv6, loopback/listener sockets, CFStream,
  WebSocket, WebRTC/STUN, and a manually encoded HTTP CONNECT.
- Probe jailbreak paths, `fork`, dyld APIs, `dladdr`,
  `sysctl(KERN_PROC_ALL)`, and `proc_listallpids`.
- Query every CoreMotion class, proximity, thermal state, UIScreen, Metal
  `registryID`, Wi-Fi SSID/BSSID/interfaces, and CTTelephonyNetworkInfo.
- Write unique A/B sentinels through SecItem (with and without access groups),
  defaults, CFPreferences, cookies, URL cache, WK storage, named pasteboards,
  app groups, tmp, hard links, symlinks, and `copyfile`.
- Leave WebSocket, upload, WKWebView, DNS, and background work pending in A;
  switch to B and prove no A bytes leave after firewall CLOSED acknowledgement.
- Repeat with tweak injection disabled, daemon killed, app-proxy provider killed, VPN
  manually disabled, and an unmanaged device. Record observed behavior rather
  than inferring enforcement from logs.

Device acceptance must retain failed and unrun cases alongside successful ones.
H08, browser coverage/callback ownership and safe recovery remain open issues;
this runbook does not mark them fixed or authorize merging the review branch.
