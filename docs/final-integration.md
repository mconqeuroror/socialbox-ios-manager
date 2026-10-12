# RedditBox — final integration and device acceptance

Publication follow-up: [0.1.3 release record](release-0.1.3.md). The local artifacts and pre-publication statements below are the historical integration results; use the release record for the published package hashes and Sileo update. Device acceptance remains separate.

Prepared 2026-09-10 on `feat/lifecycle-and-distribution`; the branch remains unmerged. Product binaries were built from [3e6f109](https://github.com/typekpaco2002/redditspoof/commit/3e6f10910dffe7fcbbf2fb78af7d974573c0f80f). Acceptance tooling is verified through [d1d8964](https://github.com/typekpaco2002/redditspoof/commit/d1d8964ece744286ee2790aca32f72a940bd2750); subsequent changes to this report do not change the installed product. All logical units were committed and pushed. The authoritative coverage contract remains [LEAK_SURFACE.md](../LEAK_SURFACE.md); the [machine-readable validation record](leak-surface/integration-validation.json) retains hashes and commits.

## Verified result

- **Both local 0.1.3 packages built successfully**, rootless and rootful, including Xcode archive and Theos arm64/arm64e compile/link/package. Signing uses Procursus ldid, with Apple signing disabled and the existing licensing public key retained.
- Native production-function regressions, Simple UI/readiness fixtures, 8 SSH fixtures and 5 canary fixtures pass. The temporary iOS observer compiles and signs. The contract and source snapshot validate.
- **304 rows: 126 covered in code, 25 gaps, 153 unverified.** The previous 27 gaps decrease by exactly two: WIRE-003 and WIRE-004. New acceptance/UI rows do not erase other gaps.
- **No final-build iPhone acceptance or production deployment was performed.** Local `.deb` files do not update the production APT repository. Accounts, license keys, cloud signer, private stores and production routing remain untouched by this pass.
- Compilation still emits existing nullability/deprecation and obsolete-linker-option warnings. A successful build is not a claim of warning-free code or working device isolation.

Local artifacts (choose the package matching the jailbreak scheme):

- **rootless** — `packages/com.redditbox_0.1.3_iphoneos-arm64.deb`, 1,469,654 bytes. SHA-256: `a49e7bf64ac0dcbbde943d6eaf66c7e0a3af8bdede88536d69b969b0eab5f8b8`.
- **rootful** — `packages/com.redditbox_0.1.3_iphoneos-arm.deb`, 1,463,692 bytes. SHA-256: `8e7a5d92f056c44d6925a3f7111a1b2e32fd934df9bcb1b47e6744693ff9a438`.

Both generated release manifests require MDM re-adoption. Follow the existing deployment procedure for the exact exported clones; package installation alone is not per-app VPN adoption.

## This prepared Mac: environment before the runbook

Run these commands from the existing `work/redditspoof-distribution` checkout. These environment files and the public PEM were already used for both successful builds; do not generate a replacement key.

```bash
source ../build-env.sh
export PATH="/opt/homebrew/bin:$PATH"
export LICENSE_PUBLIC_KEY_FILE="$PWD/../private-release/license/license-public.pem"
export RBX_RELEASE_VERSION=0.1.3
```

The ordered runbook below includes rebuilding. To use the already verified local
artifact on the current rootless phone, set these variables and continue at the
USB/install commands in step 1:

```bash
export RBX_PACKAGE_SCHEME=rootless
export RBX_VERSION=0.1.3
export RBX_DEB="packages/com.redditbox_0.1.3_iphoneos-arm64.deb"
test -f "$RBX_DEB"
shasum -a 256 "$RBX_DEB"
```

For palera1n rootful, select `RBX_PACKAGE_SCHEME=rootful` and
`packages/com.redditbox_0.1.3_iphoneos-arm.deb` instead. Match the hash above.
For another Mac, supply its actual dependency and matching public-key paths
using the build guide. Rebuild if product source changed after the recorded revision.

## Phase 1 — changes and honest row dispositions

- **[a8e61ec](https://github.com/typekpaco2002/redditspoof/commit/a8e61ec53a1eeb188ff326d46eb5e8f8e3c96d52) — Scope payload mutation to Reddit request dispatch.** Removes global JSON/body-assignment rewriting and applies the exact Reddit host classifier at request dispatch, including upload paths. Native production-function fixtures distinguish Reddit, foreign and lookalike hosts and retain opaque nested server-owned trees. **WIRE-003/WIRE-004: covered in code. WIRE-006/WIRE-007/WIRE-009: only partially closed; their Reddit-domain binary and encoding heuristics remain gaps.**
- **[221ab71](https://github.com/typekpaco2002/redditspoof/commit/221ab717dab0d81ff3d920b052e7e7eb2cb4bbe9) — Preserve authenticated request bytes and signature headers.** Recognized Signature, HMAC and digest headers prevent rewriting of the authenticated request. Six case-insensitive signature/digest families have native regressions. **WIRE-005 remains a gap:** passing through signed bytes preserves authentication integrity but cannot establish identity-field coverage inside those bytes; no re-signing path is claimed.
- **[9e692c9](https://github.com/typekpaco2002/redditspoof/commit/9e692c9381cad0922c0e0cd0a89ab9c03abcf7e2) — Defer request header transformation until dispatch.** Preserves native request construction when signatures arrive last or the final URL changes to a foreign host. Builder and production-function fixtures cover those orderings. **WIRE-004 stays covered in code; WIRE-005 remains partial**, including unknown authentication schemes and later session/delegate behavior.
- **[86eaf98](https://github.com/typekpaco2002/redditspoof/commit/86eaf98cbb73d01bb585121541059fe9ca5c4446) — Add opt-in local-only keychain sync policy.** Constrains explicit synchronizable selectors only for a profile that chooses `security.keychainSync=local-only`; missing/unchanged retains existing behavior. Group names and original Security API results are preserved. Shipped wrappers have RED→GREEN synthetic-provider fixtures. **OS-011 remains a gap pending real clone-context Security and login tests.** The launcher does not expose this policy as a normal setup toggle; the readiness group proves the selected policy installed, not that local-only mode is enabled.
- **[94c630c](https://github.com/typekpaco2002/redditspoof/commit/94c630c69462d53299281d5a6f3ff8c7350396d1) — Record bounded shared-state and hardware fingerprint decisions.** Keeps OS-005/OS-038/OS-039 open where a telemetry-specific caller is unproven; preserves lifecycle, accessibility and user settings. Explicitly retains physical disk/capability/rendering/timing fingerprints for OS-036/OS-049/OS-052/OS-066/OS-068 and related rows rather than inventing broad hooks. **These are documented gaps, not closures.** NET-026 separates IP confinement from resolver/destination control; NET-027 remains unverified.
- **[69eefb4](https://github.com/typekpaco2002/redditspoof/commit/69eefb4e3381c67c0dd1180f9a53f559ac6f8420) — Document residual schema and OAuth acceptance limits.** Keeps WIRE-011 timestamp/unit ambiguity open for caller-attributed captures and exact-schema fixtures. **LIFE-007/NET-033 remain gaps:** original OAuth callback schemes are shared. Only one external-browser login may be in progress; the operator must observe which clone receives the callback. Serialized login is a mitigation, not proof of callback ownership.
- **[417cd12](https://github.com/typekpaco2002/redditspoof/commit/417cd121640cdc6ae5868cf49f30527cd6187264) — Match diagnostic receipt timing to the armed-to-open sequence.** Corrects the read-only diagnostic interpretation of existing startup evidence. It does not change launch authorization, lease renewal or the IPC schema. **NET-037 still requires current-device evidence.**

Relevant baseline contract commit: **[15ed486](https://github.com/typekpaco2002/redditspoof/commit/15ed4860817d5337911f0866eb9f5ac5397abcde)**. Earlier audit fixes, already included in that baseline, must not be counted again as new Phase 1 closures.

## Phase 2 — final tools and ordered runbook

`63affd6` introduced the shared read-only evaluator; `7078c5e` added the first SSH/runbook unit; `8a8d230` added opt-in probes inside real clones. `7a19985` corrected license expiry presentation. `d1d8964` adds the full nonce chain, strict freshness and boot binding, safe existing-password sudo transport, and final operator sequence. `3e6f109` wired the acceptance/UI fixture gates into both builds; the final canary collector fixture was added with the companion tooling unit.

The [SSH entry point](../scripts/device-acceptance-ssh.sh) runs the [collector](../tools/device_acceptance_ssh.py) and [nonce orchestrator](../tools/device_acceptance_canaries.py). It never performs Reddit login, posts, votes or launch/gate IPC. Optional challenge preparation writes only its owned test data; Security queries run inside the actual clone. The root observer is a temporary, ldid-signed GET-only kernel/process observer and bounded challenge preparer.

The reviewed false-PASS cases are fixed: expired license, stale/future hook evidence, empty lease identity fields and a deletion baseline from another boot/device cannot establish PASS. The read-only diagnostics also recognize the actual arm → receipt → OPEN time ordering; no authorization, renewal, network transition or IPC schema was changed by that correction.

Record **PASS / FAIL / NOT_RUN**, package/revision, device and jailbreak, time and evidence at every step. Keep raw captures, account data, keys, private proxy settings and the nonce ledger private. A script PASS closes only its named observation and does not automatically change an entire LEAK_SURFACE row.

### Before starting

Use a disposable test account, a test community where your one test post and
one upvote are permitted, the existing device license, your own HTTP proxies and
rotation endpoint, a decrypted Reddit IPA you obtained from your installed app,
and existing phone SSH access. The operator performs all Reddit actions; the
battery never logs in, posts, votes or changes network gates.

A supervised per-app VPN deployment through an existing MDM service is still a
prerequisite for opening managed clones. The launcher can export setup files and
clone IPAs; it cannot grant OS supervision or MDM adoption. Without that service,
stop at the OPEN prerequisite and record subsequent steps NOT_RUN. Do not change
an enforcement flag or use a direct network path to get a green result.

The current creation IPC has **no arbitrary per-container proxy picker**. The
wizard presents the saved proxy/country; the existing cloud assignment and
rotation flow supplies the effective per-container connection. A and B must
have independently verified intended assignments/exits before the “own proxies”
requirement is PASS. Merely picking a country or seeing two cards is insufficient.

### 1. Build on the Mac, install, then verify the daemon and H02

Run from the repository in Bash. Reuse the Mac's existing Xcode, Theos,
Procursus ldid and the public licensing key matching the production signer.
Do not generate replacement licensing keys or set an Apple team. If a dependency
is absent, use the prerequisites in [the build guide](on-device-smoke-checklist.md#mac-build--ldid-only-no-apple-team).

```bash
set -euo pipefail
mkdir -p build/acceptance
export THEOS="${THEOS:-$HOME/theos}"
test -f "$THEOS/makefiles/common.mk"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
command -v xcodegen
export LDID="${LDID:-$(command -v ldid)}"
test -x "$LDID"
test -r "${LICENSE_PUBLIC_KEY_FILE:?Export the existing matching public PEM path}"
unset DEVELOPMENT_TEAM
export RBX_RELEASE_VERSION=0.1.3  # local integration acceptance; not a production publication
export RBX_PACKAGE_SCHEME=rootless  # palera1n/Dopamine rootless; rootful for palera1n rootful
git rev-parse HEAD > build/acceptance/revision.txt
python3 tools/static_check.py
bash tools/test_acceptance_checks.sh
python3 tools/test_device_acceptance_ssh.py
python3 tools/test_device_acceptance_canaries.py
bash scripts/build-mac.sh 2>&1 | tee "build/acceptance/build-$RBX_PACKAGE_SCHEME.log"
RBX_VERSION="$(python3 -c 'import json; print(json.load(open("build/generated/release.json"))["version"])')"
case "$RBX_PACKAGE_SCHEME" in
  rootless) RBX_ARCH=iphoneos-arm64 ;;
  rootful) RBX_ARCH=iphoneos-arm ;;
  *) exit 2 ;;
esac
RBX_DEB="packages/com.redditbox_${RBX_VERSION}_${RBX_ARCH}.deb"
test -f "$RBX_DEB"
shasum -a 256 "$RBX_DEB" > build/acceptance/package.sha256
```

Expected: static/native checks pass; build exits 0 and produces that exact `.deb`.
The local 0.1.3 integration build has not replaced the production 0.1.2
APT package. Build both rootless and rootful if checking both packages, but
install only the variant matching this phone. Install the local artifact rather than assuming Sileo already has it.

The following example uses a USB SSH forward on port 22228. Unlock the phone
and approve its existing trust pairing first. If the forward is not already
running, keep this command open in a separate Mac terminal (syntax verified
against the installed `iproxy --help`):

```bash
iproxy -l -s 127.0.0.1 22228:22
```

For a direct Wi-Fi SSH connection, replace host and port. Keep host-key checking
enabled. Do not start a second forward if port 22228 is already occupied by the
existing USB session.

```bash
export RBX_PHONE=mobile@127.0.0.1
export RBX_SSH_PORT=22228
ssh -p "$RBX_SSH_PORT" "$RBX_PHONE" true
scp -P "$RBX_SSH_PORT" "$RBX_DEB" "$RBX_PHONE:/var/mobile/redditbox-acceptance.deb"
ssh -t -p "$RBX_SSH_PORT" "$RBX_PHONE" \
  'PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin; sudo apt-get install --reinstall /var/mobile/redditbox-acceptance.deb'
```

Expected: installation/dependency resolution completes successfully; RedditBox
opens and publishes state. Do not uninstall the package first or delete recovery
journals. H02 requires **one live daemon**, correct executable binding and explicit
kernel active/inactive memory limits of at least 256 MiB, followed by successful
large source import without daemon death in step 4. A default/unlimited value or
a permission-denied kernel query is NOT_RUN, not evidence of a 256 MiB limit.

The SSH battery uses existing SSH key/control authentication. With the existing
mobile-plus-sudo-password setup, first authenticate an SSH ControlMaster once
from this repository; this does not add a new key or change the phone password:

```bash
mkdir -p build/acceptance
chmod 700 build/acceptance
ssh -M -N -f -o ControlPersist=20m -S build/acceptance/ssh-control \
  -p "$RBX_SSH_PORT" "$RBX_PHONE"
```

Then use `--control-path build/acceptance/ssh-control --sudo-password` as below.
The operator is prompted once per battery invocation for the **existing** sudo
password. It stays only in process memory and travels on SSH stdin to a dedicated
sudo authentication pipe; it is never an argument, environment variable, file or
report. Cached/passwordless sudo cannot accidentally forward that password into
the uploaded observer file. The battery does not edit sudoers, change root access
or disable host-key checks. Alternatively use an existing root alias without
those sudo flags, or existing noninteractive sudo rights with `--sudo`.

The wrapper runs from the repository, so the short control-socket path stays
relative and avoids the macOS Unix socket path limit. If the ControlMaster has
expired, repeat the authentication command. Unavailable rights or SSH access are
NOT_RUN; do not invent a successful privileged observation.

```bash
bash scripts/device-acceptance-ssh.sh --target "$RBX_PHONE" --port "$RBX_SSH_PORT" \
  --control-path build/acceptance/ssh-control --sudo-password \
  --output build/acceptance/01-installed.json
```

Expected at this point: `daemon-process PASS`, `h02-budget PASS`. Missing license,
source or VPN during initial setup is expected to show FAIL/NOT_RUN until the
following steps complete. Exit 1 means a failed observation; exit 2 means an
incomplete run with NOT_RUN items; exit 0 is reserved for all emitted observations
passing and is not an “all clear” claim. Do not suppress individual failures.

The helper is built on this Mac and signed with ldid only, temporarily uploaded
to a private `/tmp/redditbox-acceptance-<UUID>` directory and removed. It only
reads kernel limits (GET command 8), never changes them. Cleanup failure prints
its exact owned directory; remove only that directory once SSH is restored.

Rows: ACCEPT-001/002/003, LIFE-002/010/030, NET-037.

### 2. Activate the existing device license

In RedditBox open **Settings → License** (or the activation card), set the cloud
origin to **https://redditspoof.vercel.app** without `/install`, then enter the
existing device key and activate. Do not replace the cloud signer or generate a
new keypair. An already activated installation may keep its valid activation.

Expected: Device license shows activated/unlocked; refresh and run checks again.
An HTTPS-origin error, signed-entitlement error, expiry, or failed cloud response
is FAIL. Offline signed entitlement is a separate case and does not prove live
cloud activation. Record only state and time, never the plaintext key.

### 3. Configure proxy and rotation through the launcher

Open the gear/Advanced Settings → **Proxy & rotation**. Enter the existing HTTP
proxy URL with an explicit port, HTTPS rotation URL, authorization header/value
if required, and GET/POST method required by your provider. Tap **Save securely**,
then **Save and test connection**. No SSH or plist editing is needed for this step.

Expected: the test completes with a verified exit/country matching the intended
profile region. It deliberately closes the current session, rotates once and
keeps Reddit traffic CLOSED. SOCKS5 and HTTPS proxy URLs are unsupported. Do not
record the private URLs or authorization value in the acceptance report.

Open **Managed VPN → Share Setup Files** and retain the existing deployment's
configuration. Actual MDM association is performed after A and B exist in step 5.
The VPN card is a configuration/provider summary, not packet-routing proof.

Rows: NET-034/035/038; country and assignment evidence also ID-003.

### 4. Import the decrypted Reddit source in the launcher

Use **Import Reddit IPA from Files**, select the decrypted IPA and wait for a
terminal success/failure result. The original visible Reddit app may be retired
by the existing source import flow; retain the source IPA privately first.

Expected: source is reported decrypted/ready. Run the SSH battery again with
output `build/acceptance/04-imported.json`: the daemon must still be live, the
source row PASS and the H02 memory readback valid. Record the completion screen
and whether the daemon restarted unexpectedly. A Jetsam/recovery fence, crash,
spawn failure or unfinished request is FAIL; a progress spinner is not success.

Rows: LIFE-001/002/003, ACCEPT-003. Package installation alone does not close H02.

### 5. Create fresh A and B, review identity, then finish their MDM/proxy setup

Tap **+ New container**. Name the first `Acceptance A`, choose the configured
proxy/country and tap **Generate & review**. This creates the inactive clone,
because the existing preview IPC needs a container ID. Open **Review identity**
to review model/iOS/region/carrier/language, then **Done**. Apply optional edits
only after the existing consistency check succeeds; follow any MDM re-adoption
requirement. Repeat for `Acceptance B`. Keep identities fresh; do not restore a
backup for this experiment. Open Advanced profile details to record the actual
container IDs privately, and use those IDs below, not the display names.

Expected: different generated IDs and two independently installed hidden clones.
Region/carrier/language must be coherent with each intended proxy country.
Identity edits stop once first-use identity is durably frozen. The simplified
review does not change that daemon rule.

Using the existing Settings/profile export actions, export each exact clone IPA
and MDM mapping; deploy/adopt both through your MDM service and associate each
with the intended per-app VPN configuration. Open **Firewall Setup** explicitly.
Do not infer assignment from `isManaged`, a configured bundle list or a scope card.
Verify your own A/B proxy assignments through the existing cloud management and
observed exits. If the current assignment mechanism cannot provide the requested
separate proxies, record this requirement NOT_RUN and do not invent a UI setting.

Before preparing the nonce, perform one normal **Open A → Open B** through the
launcher without logging in to either. iOS may allocate an OS data UUID only on
first launch; there is no safe way for this battery to precreate that container.
Leave B active, so A is inactive when its seed request is staged. Begin the
private capture described in step 11 before this priming pass if collecting
first-run SDK/network evidence. These remain freshly generated, unauthenticated
identities, but their ordinary first-launch state now exists. Do not regenerate
or restore them between priming and the A/B/A experiment.

```bash
export RBX_A='actual-container-id-for-A'
export RBX_B='actual-container-id-for-B'
bash scripts/device-acceptance-ssh.sh --target "$RBX_PHONE" --port "$RBX_SSH_PORT" \
  --control-path build/acceptance/ssh-control --sudo-password \
  --a "$RBX_A" --b "$RBX_B" --storage-sentinel \
  --save-baseline build/acceptance/before-delete-private.json \
  --canary-stage seed --canary-ledger build/acceptance/canary-private.json \
  --output build/acceptance/05-two-clones.json
```

Expected: A/B structure, extension removal, metadata uniqueness and optional
storage-location marker observations PASS. The marker is unique, is written only
to A's validated tmp directory and is removed. **Root observing distinct paths
or access groups cannot prove that B is denied access to A.** The read-only
battery alone leaves clone-context keychain and foreign-path denial NOT_RUN.
The explicit `--canary-stage seed` option above prepares a separate fixed challenge
for the next A launch. It writes a root-owned nonce request and private result
directory; it does not grant a lease or change any IPC action. A must be inactive
while this request is prepared. Use disposable acceptance profiles: the challenge
deliberately gives B A's test namespace/path to exercise denial. No account token
or existing keychain item is copied. Defaults remain unchanged when no request exists.

A performs the actual Security and filesystem calls in its own process after
normal readiness. Each challenge expires in one hour; keep the private ledger
for recovery. A preparation result is NOT_RUN until its bound in-clone receipt
has been collected. Complete the three commands in step 7 before deleting B.

Rows: ID-001/002/005, LIFE-004/005/006/021, OS-001/008/009/026/030/033/035.

### 6. Open A, log in, browse, make one test post and one upvote

Start capture first. Use the approved test account/community and perform actions
manually. Tap A → **Open/switch**, wait for readiness and OPEN, then log in using
the supported in-app flow. Browse a feed and comments, submit one identifiable
disposable test post and perform one upvote. Record exact times, success UI,
permalink and the intended exit privately. The SSH script performs none of these
actions and has no account credentials.

Expected: the correct clone remains foreground, login survives navigation,
the submission completes once and the vote state persists after refresh. A
blocked login, loop, wrong clone, failed signed request, post or vote is FAIL.
Capture the failing endpoint/schema privately for WIRE-003/004/005/006/007/009;
do not respond by disabling body/signature protections or network gates.

**LIFE-007 known limitation:** only one external-browser login may be attempted
at a time on this device. Cancel/finish it before switching. This is an operator
mitigation, **not a guarantee of callback ownership**: Reddit's original shared
callback scheme remains in clones. The clone-specific diagnostic scheme is not
a proven Reddit OAuth redirect. The current external-auth policy may refuse a
browser flow without proven routing. Do not enable a browser flag to bypass it.
A flow that cannot complete, or opens a sibling clone, remains FAIL/NOT_RUN and
must not be counted as successful login.

Rows: AUDIT-001, LIFE-007, NET-032/033/034, WIRE-001 through WIRE-009.

### 7. Switch A → B → A and retain three separate observations

After A's login, collect its seed receipt and prepare B's verification while B
is inactive:

```bash
bash scripts/device-acceptance-ssh.sh --target "$RBX_PHONE" --port "$RBX_SSH_PORT" \
  --control-path build/acceptance/ssh-control --sudo-password \
  --a "$RBX_A" --b "$RBX_B" \
  --canary-stage verify --canary-ledger build/acceptance/canary-private.json \
  --output build/acceptance/07-A-open.json
```

Switch through the launcher to B. Verify B is logged out/fresh and does not show
A's account data. Collect B's denial results and prepare A's cleanup while A is
inactive:

```bash
bash scripts/device-acceptance-ssh.sh --target "$RBX_PHONE" --port "$RBX_SSH_PORT" \
  --control-path build/acceptance/ssh-control --sudo-password \
  --a "$RBX_A" --b "$RBX_B" \
  --canary-stage cleanup --canary-ledger build/acceptance/canary-private.json \
  --output build/acceptance/07-B-open.json
```

Switch back through the launcher to A. Verify A is still logged in, then collect
A's sampled keychain continuity and cleanup receipt:

```bash
bash scripts/device-acceptance-ssh.sh --target "$RBX_PHONE" --port "$RBX_SSH_PORT" \
  --control-path build/acceptance/ssh-control --sudo-password \
  --a "$RBX_A" --b "$RBX_B" \
  --canary-collect --canary-ledger build/acceptance/canary-private.json \
  --output build/acceptance/07-A-return.json
```

Do not switch while a collection is running. Final safety heartbeats and the
lease generation must still agree; a changed/stale capture becomes NOT_RUN.
The hook timestamp follows the actual transition order: arm at 100 → ready at
101 → OPEN at 102. An OPEN receipt is at/before OPEN's timestamp; an ARMED
receipt is at/after arming. Both timestamps must be finite and nonfuture, with
fresh lease heartbeat, live PID/executable, clone, generation and epoch binding.

Expected `canary-A-B-A PASS` is deliberately narrow: A added/read one local
nonsynchronizable generic-password canary; B could not find it in its default
namespace and got `errSecMissingEntitlement` for A's group; B got EACCES/EPERM
for A's known-present nonce file; A still read the original keychain canary on
return and removed only its own nonce item/file. The host independently observes
A's sentinel before and after B's result. ENOENT for A's foreign file is NOT_RUN,
not denial proof. Each stage uses its own current process/generation, and ordered
receipts share one nonce. This does not cover every Security item class, query
form, persisted SDK identifier, filesystem API or arbitrary compromised app.
The UI readiness list does not ingest these private Mac receipts; use the SSH
report for the optional challenge's result.

If interrupted, do not start a new nonce over the existing ledger. Switch away
from A, prepare `--canary-stage cleanup --canary-abort` using the same A/B IDs and
ledger, then open A and run `--canary-collect`. This is cleanup-only recovery and
can never produce an isolation PASS. A daemon restart also requires explicit
abort cleanup rather than reusing evidence across epochs. If a cleanup receipt
reports failure, preserve the ledger for inspection. Explicit abort can retire
only that inactive clone’s exact nonce control/receipt files before asking its
next launch to retry cleanup; no retry erases unknown bytes or another nonce. Successful collection removes exact owned
request/result files; empty diagnostic directories may remain.

Expected: each active receipt binds to that clone's live PID/executable,
generation and per-clone epoch; all required groups and behavior self-reports
PASS, with the corresponding current lease OPEN. B freshness and A session
retention still require watching the screen and, for identifier claims, comparing
sanitized current-binary first-run keys and captured traffic. The optional
keychain-sync-policy READY flag may mean `unchanged`; its configured mode is
reported separately and does not close OS-011.

Rows: ACCEPT-004, LIFE-019/020/021/022, NET-036/037, OS-008/009/011/033/035, ID-001/002, AUDIT-001.

### 8. Open Diagnostics → Run checks

Use the one-tap Diagnostics action and **Run checks**. The UI and SSH battery use
`RBXAcceptanceChecks` for the same published readiness evaluation. Snapshot
publication must be at most ten seconds old; recorded diagnostics must be at
most two minutes old. Run again immediately after a switch. Recorded PASS is
explicitly tied to the last requested inspection, not every later generation.

Expected for active A: current lease OPEN, all required installed groups and
behavior results true, no failed/missing readiness result. INFO/unavailable and
NOT_RUN are displayed as **NOT VERIFIED**, not PASS. The SSH receipt check also
binds the actual live process, which a stale UI summary alone cannot establish.

For the requested “no NOT_READY lines” check, record a short private USB log
covering this exact acceptance interval when the jailbreak has no `log` utility:

```bash
umask 077
idevicesyslog --no-colors --process 'redditboxd|RedditApp' \
  > build/acceptance/device-log-private.txt
# Stop with Ctrl-C after the acceptance interval.
rg -n 'NOT_READY|RBX_SELF_REPORT|readiness denied|hook readiness failed' \
  build/acceptance/device-log-private.txt
```

Expected: matching current-generation self-reports without NOT_READY/FAILED.
A missing log stream or missing interval is NOT_RUN. Absence of the literal
NOT_READY string by itself is not a pass. Do not share the raw log without
reviewing/redacting account, URL and credential material.

### 9. Check the post from a logged-out view

Open the exact post permalink in an independent logged-out browser and confirm
whether the post is visible. Record visible / removed / requires login / unknown,
time and screenshot. The launcher account-status screen is another observation,
not an authority on moderation. A visible post establishes that specific public
visibility at that time; it does not prove absence of an account-wide restriction,
ranking limitation or future moderation. Do not infer a “shadowban” diagnosis
from one unavailable page.

Rows: AUDIT-001. Operator only.

### 10. Delete B and verify retained A, file cleanup and keychain evidence

Close/switch away from B through the launcher, delete **Acceptance B** through its
existing Advanced action, and wait for terminal completion. Keep A. Do not
manually erase a profile directory or keychain database, and do not clear a
recovery fence. Run Diagnostics again.

```bash
bash scripts/device-acceptance-ssh.sh --target "$RBX_PHONE" --port "$RBX_SSH_PORT" \
  --control-path build/acceptance/ssh-control --sudo-password \
  --a "$RBX_A" --after-delete build/acceptance/before-delete-private.json \
  --output build/acceptance/10-B-deleted.json
```

Expected: B disappears after completed deletion; no unfinished deletion/recovery
reason; A still exists and retains its session. `B-deleted-files PASS` means the
exact previously recorded B app bundle, OS data directory and profile return
ENOENT on the same daemon boot epoch as the baseline. A different phone or
restart produces NOT_RUN. It does **not** verify all exports/cloud retirement.
`B-recorded-keychain-cleanup` checks the retained committed deletion journal for
the exact B group and a timestamp after the baseline. This is recorded evidence
that the existing authorized helper completed its canary/erase/verification flow;
the raw temporary helper receipt is not retained by that flow. It is distinct
from directly querying the post-delete group. The A/B canary above tests access
denial and cleans its own test item; it does not alone prove all B keychain data
was erased. An independent post-delete query needs a known prior canary and
appropriate authorization. A root query denied by entitlements, or a query without a
known prior canary, cannot prove cleanup and stays NOT_RUN.

Rows: LIFE-026/027/028/031, OS-008/009/010.

### 11. Fail-closed spot checks: dead rotation URL, then VPN off

Save your working rotation setting privately. In launcher Settings replace only
the rotation URL with `https://127.0.0.1:1/redditbox-acceptance-unreachable`, save,
and try opening A. Do not press a shell command to manipulate the gate.

Expected: bounded connection/rotation failure; A does not reach OPEN and cannot
browse. Record the UI reason and CLOSED state. Restore the exact working URL in
Settings, use **Save and test connection**, and reopen A normally. If the test
unexpectedly reaches a working local endpoint, discard this probe and use an
endpoint you control that definitively refuses connection.

While A is OPEN and capture is running, toggle its managed VPN off in iOS
Settings. Try refreshing once. Expected: provider/lease closes or expires and
traffic stops, including retained connections. Restore the managed VPN using the
normal setup path after capturing the result. UI text alone does not prove that
packets stopped.

Capture instructions (run in a separate Mac terminal, retaining files privately):

```bash
umask 077
export RBX_DEVICE_UDID="$(idevice_id -l | head -n 1)"
test -n "$RBX_DEVICE_UDID"
rvictl -s "$RBX_DEVICE_UDID"
# Use the interface printed by rvictl; this example assumes rvi0.
sudo tcpdump -i rvi0 -nn -s 0 -U -w build/acceptance/acceptance-private.pcap
# Stop with Ctrl-C after the experiment; retain capture-drop counts.
rvictl -x "$RBX_DEVICE_UDID"
```

With multiple connected devices, select the intended UDID rather than the first.
Record clock offsets and independently verify physical egress using your gateway
and proxy logs. RVI alone may include logical tunnel traffic. Direct versus
proxied DNS/DoH/DoT, UDP/QUIC, IPv6, ICMP, DNS brokers and external browser paths
are separate matrix items (NET-008 through NET-039); neither `per-app` scope nor
successful HTTP CONNECT establishes upstream resolver policy.

### What remains after a green readiness battery

1. Critical path: actual login/browse/post/vote and preserved signed request bytes
   on the current Reddit version; per-endpoint JSON/protobuf/timestamp-unit capture.
2. OS routing: effective clone-to-VPN association and packet-level fail-closed
   results, including brokered/background/browser/DNS/IPv6/UDP paths.
3. Isolation: run the prepared in-clone nonce experiment, then collect first-run
   A/B persisted key names/types and API families outside that bounded probe.
   No Android evidence substitution or root shortcut.
4. OAuth callback ownership: sequential use mitigates overlap but leaves LIFE-007
   unverified for a shared redirect scheme.
5. Destructive lifecycle acceptance on disposable B: keychain cleanup, exports,
   cloud retirement, restore and upgrade evidence not covered by a file absence test.
6. Explicit residual surfaces: actual global preference keys, Darwin notification
   names/callers, notification lifecycle, environment key names, runtime memory/CPU
   tuple and interface names. Record names/callers without credential values.
   Shared disk/kernel/IOKit/display/GPU fingerprints remain intentional shared
   fingerprints (OS-036/049/052/066/068), not isolation passes.

Report every unrun step with its blocking prerequisite. Never collapse NOT_RUN
or “covered in code” into device acceptance, and never publish an “all clear”.

## SSH check-to-row mapping

A matching PASS closes only the named observation for this captured device, revision and generation. It never changes a LEAK_SURFACE row automatically or proves all API families in a row.

| Check pattern | Contract rows | Automated observation | Does not establish |
| --- | --- | --- | --- |
| publication | ACCEPT-001, NET-037 | Fresh daemon state publication | Live daemon executable or packet enforcement |
| license | ACCEPT-001 | Published activation state | Offline grace, revocation and real login |
| configuration | NET-038, ACCEPT-001 | Configuration saved/readable | Rotation success, own proxies and country match |
| source | LIFE-001, LIFE-002 | Published source validation | Import stress survival and app login |
| lease-state | LIFE-021, NET-036 | Published OPEN state | Current lease binding or real network route |
| reported-* | LIFE-030, LIFE-010, NET-036, LIFE-021, NET-034, LIFE-005, NET-037 | Existing diagnostics results at their recorded inspection time | Current generation after a switch; actual VPN assignment or cross-clone denial |
| daemon-process | ACCEPT-003, NET-037 | Exactly one PID bound to the installed daemon executable | Long-running service stability |
| h02-budget | ACCEPT-003, LIFE-002 | GET-only kernel memory limit readback, explicit active/inactive >=256 MiB | Import completion, Jetsam survival, default/unlimited kernel limit interpretation |
| live-lease-* | NET-036, LIFE-021 | Captured fresh agreement and OPEN state | Traffic stops on revoke or VPN disconnect |
| live-provider | NET-034 | Provider reports fresh per-app enforcement | OS VPNUUID assignment and packet path |
| *-structure | ID-005, LIFE-005, OS-008, OS-026 | Installed main bundle ID and expected sole keychain entitlement; shared/cloud/push/associated-domain entitlements absent | Security framework access denial, every nested architecture, App Group runtime recreation |
| *-removed-extensions | LIFE-006 | Installed PlugIns/Watch/AppClips directories absent | Other bundled SDK or dynamic code behavior |
| *-data-container | ID-005, OS-030 | OS metadata identifies exactly one clone data container | Foreign sandbox read/write denial |
| A-B-distinct-metadata | ID-005, OS-001, OS-008, OS-030 | Different A/B identifiers, groups and data paths | UserDefaults/keychain values and foreign access denial |
| storage-sentinel-locations | OS-030, ACCEPT-002 | Opt-in marker at A tmp absent at B tmp, with cleanup | B attempting to open A's absolute path in clone context |
| hook-* | NET-037, LIFE-021 | Receipt binds live executable, generation, clone and epoch; required installed groups true; finite/nonfuture receipt ordering follows ARMED-before-OPEN semantics, with fresh control files at final capture | Every hooked selector or downstream SDK data flow |
| behavior-* | NET-037, LIFE-021 | Required in-clone behavior self-reports true under the bound receipt | Cross-clone canary denial; keychain-sync-policy READY may mean unchanged mode |
| *-keychain-sync-policy | OS-011 | Configured mode displayed without claiming sync isolation | Always NOT_RUN until actual iOS query/login evidence |
| B-deleted-files | LIFE-027, ACCEPT-002 | Exact baseline B data directory, installed bundle and profile paths return ENOENT; baseline must match the same nonempty daemon boot epoch | Keychain cleanup, all exports, cloud retirement and backup ownership |
| temporary-observer-cleanup | ACCEPT-002 | Exact temporary observer removed | Any clone state or credential cleanup |
| capture-generation | NET-036, LIFE-021 | Collection detects a lease change and invalidates binding results | A changing capture is NOT_RUN |
| collection | ACCEPT-002 | Collector dependency/transport/format failure recorded | Incomplete collection is NOT_RUN |
| h02 | ACCEPT-003, LIFE-002 | None; explicit operator item | Import completion and post-import daemon survival |
| keychain-canary | OS-008, OS-009, OS-010 | None in the read-only battery | Readiness-only check remains NOT_RUN. Explicit optional canary-* observations provide separate bounded in-clone evidence; never infer it from root metadata. |
| sandbox-denial | OS-033, OS-035 | None in the read-only battery | Readiness-only check remains NOT_RUN. Explicit optional canary-* observations provide separate bounded in-clone evidence; never infer it from root metadata. |
| login-actions | AUDIT-001 | None; no account actions are automated | Login, post, vote, logout/switch state |
| oauth-owner | LIFE-007, NET-032, NET-033 | None; one-at-a-time is a mitigation | Callback-owner correctness and external browser routing |
| packet-routing | NET-034, NET-036 | None; provider self-report is insufficient | Captured VPN association/disconnect and bypass matrix |
| public-visibility | AUDIT-001 | None; operator checks the exact permalink | Moderation/ranking or account-wide restriction claims |
| deletion | LIFE-026, LIFE-027 | None for whole cleanup; B-deleted-files is a bounded subset | Keychain cleanup requires a separately verified canary |
| canary-* | ACCEPT-004, OS-008, OS-009, OS-033, OS-035 | Explicit root-owned challenge staging and per-stage live process/lease-bound in-clone receipts; aggregate requires ordered A seed, B denial, A continuity and cleanup plus source sentinel witnesses. | Prepared/aborted/missing/mismatched/expired results stay NOT_RUN. A full PASS covers the fixed generic-password and filesystem calls only, not every row API or SDK. |
| B-recorded-keychain-cleanup | LIFE-026, LIFE-027 | Same-device-epoch committed deletion journal for exact B group updated after baseline, without recovery evidence. | Recorded helper completion is not a retained raw Security receipt or independently repeated post-delete keychain query. |

The [JSON mapping](leak-surface/device-acceptance-mapping.json) is authoritative for script consumers. Manual screen/packet checks retain NOT_RUN until the operator records independent evidence.

## Phase 3 — what each Simple screen shows

Main UI commit: **[ddbb9b3](https://github.com/typekpaco2002/redditspoof/commit/ddbb9b39f95dd2435609f90fab6ca62d60448623)**. Proven failed-create recovery follow-up: **[c216684](https://github.com/typekpaco2002/redditspoof/commit/c2166843efba8fae5ddd3b2e8c1fd8b7adadd6f4)**. These descriptions come from the UIKit implementation; they are not screenshots or evidence that the screens have been exercised on the phone.

### 1. Simple overview

The top of the screen shows the RedditBox title, Refresh, plus and gear controls. A workspace summary describes setup, the current session or an attention condition. A Device card shows daemon-publication, VPN and license status, followed by a prominent **Run checks** button. VPN wording explicitly describes reported per-app scope.

Below it, each rounded container card shows its name, role tag, Idle/Opening/Ready/Locked label with a reason, proxy-country flag and last-active time. Stale publication changes the summary to **Status not verified** and locks the displayed container status. Tap follows the existing Open/switch confirmation. Ready describes the published open container and is not a whole-device isolation verdict.

The empty view offers **+ New container**. Profile recovery, deletion and replacement states remain visible, with a reason and an Advanced path.

### 2. Gear and Advanced profiles

The gear opens existing settings and diagnostic actions plus **Advanced profiles**. That view retains detailed profile information and existing actions for identity, export, replacement, cleanup and metadata. Native Back returns to the Simple view. The underlying passcode and license gates remain in place.

### 3. New-container wizard

Four numbered sections collect **Name/role**, **Proxy setup**, **Automatic identity** and **Review**. Proxy selection offers the existing configured device connection or opens existing proxy/rotation Settings. It does not assign a profile its own proxy.

**Generate & review creates an inactive container first**, then displays its generated model, iOS, region, carrier and language. This ordering is explicit because the existing preview IPC requires a persisted container. Leaving the screen retains the created container; no automatic Open is sent.

The request ID and nonsecret draft metadata preserve observation across suspension. An unpublished enqueue failure returns to editable fields. A later failed step offers explicit reset only after a matching terminal failed receipt and a newer, fresh inventory prove the container is absent with no recovery warnings. Uncertain work is neither cleared nor automatically retried.

### 4. Simple identity review

Top-level fields show model/iOS/region/carrier/language, with installed-catalog choices. Presentation, expert identifiers and compatibility/security groups start collapsed. Existing private identifier fields remain write-only; blank preserves current private values.

**Check consistency** uses the existing preview request. Apply is disabled until that preview succeeds for exactly the currently displayed choices. Edits, pending checks, missing validation and observed proxy mismatch block Apply. The daemon independently validates again, and identity freeze and MDM re-adoption requirements remain unchanged.

### 5. Diagnostics

Opening Run checks sends the existing diagnostic request. The Simple result list shows **PASS / FAIL / NOT VERIFIED**, a scoped explanation and `LEAK_SURFACE` row references. **Run checks**, **Share Logs** and **Open advanced** retain access to refresh, export and original detailed reports. A read-only timer ages out stale displayed evidence.

NOT VERIFIED is the UI label for the evaluator’s NOT_RUN. Historical diagnostic PASS is labelled as the last recorded inspection, not the current clone’s universal readiness. Actual packet routing, A/B access denial, OAuth ownership and Reddit account actions require their own evidence.

### Precise UI boundaries

- No new daemon, isolation policy, authorization or IPC endpoint is introduced by Simple UI.
- There is **no arbitrary per-profile proxy picker** in current IPC. Device configuration is selectable, but effective cloud assignment and live country are verified during Open. Two profile cards or country selections do not establish distinct A/B proxies.
- Actual OS supervision, per-app VPN association and MDM adoption remain external prerequisites. Launcher exports and status cards cannot perform or prove them.
- Simple does not decrypt an IPA, bypass a failed gate, perform account actions or eliminate the known shared OAuth callback limitation.
- The five UI inventory rows cover presentation and its unit checks. iPhone layout, touch behavior, VoiceOver and interruption/recovery flows remain on-device QA.

## Ranked remaining on-device work

1. **Install and survive the critical startup path.** Install the exact final local artifact, record its SHA-256 and revision, verify one correctly bound daemon and explicit H02 memory limits, activate the existing license and complete a large source import without daemon death or a recovery fence. Previous production-package observations do not validate the final integration artifact.
2. **Establish the required network environment.** Configure proxy/rotation in the launcher, verify intended distinct A/B assignments and live countries, deploy/adopt both clones through MDM, and confirm actual per-app association. If prerequisites are absent, Open and dependent tests remain NOT_RUN.
3. **Verify the Reddit critical path and callback destination.** The operator logs into a test account, browses, makes one permitted test post and one upvote, and confirms the correct clone receives any external login callback. Keep only one external-browser login in progress. Capture relevant authentication/schema behavior privately.
4. **Prove A/B state boundaries in clone context.** A remains logged in after switching to fresh B and back. Run the final opt-in A/B canary sequence and retain complete bound receipts, source-canary proof, foreign-denial result and cleanup evidence. Different root-observed directories or access-group names alone do not prove denial.
5. **Verify fail-closed behavior using actual traffic evidence.** Dead rotation must prevent Open; loss of the managed VPN must stop Reddit traffic. Test direct and proxy-tunneled IPv4/IPv6/UDP/QUIC/DNS paths as prescribed. Authorized proxy traffic containing DoH/DoT is distinct from a real-IP leak; destination policy remains a separate limitation.
6. **Verify deletion and public visibility separately.** Delete B, check its recorded files and canaries are removed, and verify relevant keychain cleanup. Observe the test post from a logged-out view; that observation alone is not a general account-reputation guarantee.
7. **Capture the residual API/schema behavior and UI edge cases.** Attribute timestamp units, unknown binary/encoded fields, global preference/notification/interface/environment reads and physical hardware overlaps to actual callers. Exercise small-screen layout, keyboard, rotation, media, VoiceOver, stale status, failed create/reset and edit-during-preview.

Some remaining gaps need engineering after device evidence, not merely a passing test: unknown request signatures, schema-unaware binary rewriting, timestamp-unit ambiguity and shared OAuth ownership. Physical disk/capability/rendering/timing overlap is an explicit retained boundary. No number of readiness PASS rows converts those into a guarantee that accounts are unlinkable.
