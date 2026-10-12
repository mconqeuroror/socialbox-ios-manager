# SocialBox authorization exchange

This is a source-owned adapter for **our existing SocialBox cloud protocol**.
It constructs a claim/validation request and verifies one response with the
existing `RBXLicenseToken` implementation and build-time public-key pin. It does
not replace original SocialBox authorization or translate an unverified original
token into a SocialBox grant.

The presentation now links the **client, IPC schema and peer authentication**.
The exchange, transport and vault run only in the separate root service; they
are not injected into the manager. The integrated private builder packages both
the UI client and the service. The [original response and immediate persistence
contracts](../Diagnostics/RECOVERED_LICENSE_CONTRACT.md) have been recovered;
their session, product and engine-consumer interoperability is still unfinished.
An independently valid SocialBox entitlement does not prove
that the unchanged recovered engine accepts or enforces that entitlement.

## Owner-requested permanent single-device issuance (Unit 35)

The website's owner console now issues new device keys with no customer-term
expiry and exactly one installation slot. The form has no duration or device-count
choice. The server refuses duration or expanded-limit requests before issuance;
the unique current owner policy still runs inside the auth-state transaction.
Existing license records, activation history, credentials and revocations are
preserved. This is an issuance policy, not a migration of old keys.

The customer enters the key once. A successful pairing retains the existing
installation credential for subsequent validation. Signed response freshness,
request deadlines, operation admission and revocation checks still apply; those
short validity windows are not a customer subscription term. One installation
and its bearer are the binding, without physical anti-cloning attestation. Lost
pairing state cannot silently create a replacement installation.

This unit changes no native admission, running-session enforcement, installer,
identity or engine contract. Local tests and a synthetic browser acceptance do
not accept a real customer device or the full workflow. Deployment state is
recorded separately. Evidence:
`docs/release-evidence/socialbox-permanent-device-issuance-2026-10-01.json`.

Unit36 deploys that policy to the existing website, source a42799d5ca0f951fcd40244ee304b541bef13a9d,
production dpl_CFFipX7NRt8S3QkFTn3TGL5if1Jr. All20 local suites/typecheck,
exact152-file upload, remote build, immutable CLI/API metadata and public/APT
guards pass. The owned publisher lock is released; client downloads stay closed.
Two initial public-lock/result-shape refusals are retained and separately
reconciled without lock reissue, repeated deployment or weaker source checks.
This is website policy acceptance only: no real key issued, physical hardware
binding, compiled-bundle attestation, installed engine/session integration or
customer installation/runtime acceptance. The private manager backup is separate
and does not prove account storage/isolation. Evidence:
`docs/release-evidence/socialbox-website-permanent-license-deployment-2026-10-01.json`.

## Final native universal signing (Unit 31)

The builder now signs the final arm64/arm64e program before calculating its
digest/size or pinning an acceptance client. Fixed role identifiers and explicit
requirements, strict verification of both architectures and per-slice empty
entitlements are required. Every failure stops before an accepted report;
partially written private output remains and cannot be retried as fresh.

PASS9 focused methods with46 stable repository inputs: actual wrong-ID, altered
code, missing architecture and arm64e-only entitlement counterexamples, plus
explicitly synthetic before-sign/post-real-sign failures. The final failure test
builds/signs the real client, preserves it, publishes no pin/report and refuses
repeat output. It does not prove rollback after arbitrary real signer failure.
PASS new manager and acceptance builds:5 programs/10 signed slices,45 stable
quoted native inputs, exact final client pin and unchanged reviewed manager pin.

This corrects strict macOS verification for new ad-hoc builds only. Earlier
arm64e signature FAIL remains historical; no Apple/Meta publisher, device trust
or launch acceptance follows. New bytes cannot replace established prepared
image policy; migration and existing package refusal remain unchanged. Phone SSH
authentication denied before effects; fresh root inspection, actual retirement,
default installation and client/runtime acceptance remain NOT_RUN. No license,
owner program/state, website or customer package changed.

Evidence: docs/release-evidence/socialbox-native-universal-signing-2026-10-01.json.

## Own HTTPS client and acceptance tool

`LBXLicenseTransport` now owns an ephemeral NSURLSession around this exchange.
It disables cookies, URL cache and credential storage, refuses all redirects,
bounds both declared and streamed replies to 64 KiB, and verifies the exact
endpoint and current configuration before returning a signed receipt. Completion
is serialized and one-shot; cancellation cannot return a valid receipt. HTTP
errors preserve a numeric status only, not arbitrary remote messages. Platform
TLS verification is unchanged. A signed denial remains a denial.

The source-owned `Probe.m` executable exercises that actual client on a phone.
It reads a private request from stdin and requires an exclusively created 0600
output file for the private receipt. Nothing containing credentials is printed.
It only contacts the fixed production SocialBox HTTPS origin. It does not read
or change the retained app's license, set an engine flag, or write its token
store. Run only with a disposable test key: a successful claim consumes its
activation slot. Losing the private result requires explicit recovery.

Build both iOS architectures through `scripts/build-socialbox-license-probe.py`
using the existing public PEM and Procursus ldid. No private signer, new trust
key or additional entitlement is required. On the tested rootless phone, the
ad-hoc executable was killed when launched from the mobile data tree; the same
tool ran from the existing private `/var/jb/var/lib/socialbox-acceptance/` lane.
Do not disable system signature checks to run it.

`bash lucid/tests/test_license_transport.sh` exercises the real Foundation
session with a mock URLProtocol and real RSA signatures. These are transport
boundary tests, not TLS wire measurements or retained-engine admission tests.
Production test seams are compiled out.

The server now requires the saved bearer before reusing an existing installation
record. A copied UUID and license key cannot retrieve or replace that bearer.
Authenticated retries still work. If the first claim committed but its reply
was lost, do not invent a new installation UUID to evade the limit; recovery is
explicit. This strengthens installation binding, not hardware attestation.

## Durable pairing owner

`LBXLicenseVault` implements the private installation record needed before
consumer integration. Production access requires root, a trusted parent and a
0700 leaf directory, with 0600 single-link regular files. It opens relative to
directory descriptors, rejects symlinks/FIFOs/unsafe ownership and permissions,
and bounds record size. A cross-process file lock protects reserve/commit;
atomic rename, file/directory fsync and readback check each saved record.

The vault creates its own stable UUID exactly once during explicit setup. A
missing established record or lock, malformed schema or failed write is a
recovery error. No failed request silently changes installation identity. A
reserved generation is durable before HTTPS starts; commit requires that exact
configuration still be current and increments it again. Duplicate/stale
responses cannot replace a newer record. The exchange includes its verified
request nonce so the vault can independently recheck the pinned signature,
installation/key/device binding and signed status before storing a pairing.
Only the trusted request owner may submit a receipt to this internal API;
never expose a client-supplied receipt-write RPC.

The pairing credential is retained after signed revocation so a subsequent
online check uses the same installation. Neither `paired` nor the descriptive
last status grants access. The vault stores **no offline authorization token**
and `engineAuthorized` is always false. It is owned by the source-owned root
service; app callers use authenticated IPC without filesystem access to pairing
credentials. These root-owned files are not hardware attestation or protection from
an attacker who already controls root. Keep them outside container exports.

Build `VaultProbe.m` with the same builder and `--entrypoint vault`. Its private
stdin accepts a key for a claim, or `{}` for revalidation from the existing
vault. It does not accept a caller-selected installation UUID or imported
bearer. The [vault receipt](../../docs/release-evidence/socialbox-license-vault-2026-09-29.json)
records activation, a separate process recovering and validating the exact
pair, signed revocation, denied mobile reads and a reversible missing-record
fault on the physical phone. This is a process restart, not an iPhone reboot.
All tests use a disposable revoked test key and a separate acceptance folder.

`bash lucid/tests/test_license_vault.sh` runs 58 native assertions with actual
filesystem operations and RSA signatures, including two independent processes,
concurrent reservations, stale replies, malformed records and unsafe paths.
The Boolean schema-version test was observed failing before the strict numeric
type check was added. All original exchange/transport assertions still pass.

## Exchange contract

The caller supplies a trusted configuration snapshot: canonical HTTPS origin,
stable installation UUID, optional existing access key, device ID and bearer,
plus an integer configuration `revision`. The owner must increase that revision
on every configuration change, including a change back to a former value.
The adapter copies and validates those fields, normalizes the key/UUID, and
creates a fresh unpredictable nonce. It does not create a licence or alter an
existing signer. Production verification cannot take a key from a reply or
runtime configuration; temporary test keys exist only in test builds.

The request goes to `/api/devices/claim` or `/api/licenses/validate`, with the
same request fields as the existing service. `LBXLicenseExchange` itself does
not open a socket or persist a credential. `LBXLicenseTransport` supplies the
ephemeral HTTPS session described above; an integrating caller still owns its
lifetime and the durable credential/admission transaction.

A response consumes the exchange once. Cancellation, changed configuration or
revision, an elapsed request window, wrong endpoint, non-200 response, malformed
JSON and invalid signature/binding/nonce reject it. Signed revocation and expiry
remain denial results; an unsigned `valid` flag and unrelated server metadata
cannot authorize anything. Only an authentic active claim can yield proposed
pairing credentials for the existing owner to validate and store privately.

The result is a **receipt-time assessment**, not a reusable admission lease or
offline cache. The caller must recheck operation ownership/configuration before
durable pairing or publication, and use the existing expiry, revocation,
monotonic lease and fail-closed coordination for any actual admission. Recovered
engine readiness remains false. No result from this adapter opens its network
gate or bypasses an original check.

Requests and verified results contain credentials. Do not log/share them.
`safeStatus` and the object's `description` omit credentials and device IDs.
The in-app isolation report never exports this private exchange payload.

## Native checks

Run `bash lucid/tests/test_license_exchange.sh`. The tests generate an ephemeral
RSA test key and exercise actual signatures, the exact existing verifier,
denials, replay, response/device/origin binding, cancellation, configuration
changes and pairing validation. They make no real server or device calls.
Production compilation is separate from test-key injection. Passing these tests
does not make the original engine's authorization contract compatible.

The [2026-09-29 acceptance receipt](../../docs/release-evidence/socialbox-own-licensing-2026-09-29.json)
records first-phone production claim, revalidation, duplicate-installation
denial and signed revocation. Both the bare ldid fat binary and its phone copy
were hash-verified. The test license was revoked; other licenses, users and
device records were unchanged by cleanup. A second UUID on that same phone
tests the server's installation limit, not two physical phones. The arm64e
slice was built but not executed. No retained app update was installed.

## Remaining consumer work

The owner has confirmed that the original hosted licensing service is not
available. Continue with source-owned verification, not a request for its
private key or an always-valid compatibility flag. There are three integration
boundaries: app startup and periodic checks; daemon local grant versus separate
hosted-session state; injected-engine grant plus config reload and initialization.
The source-owned activation form consumes a sanitized IPC assessment, but none
of these three retained admission consumers currently accepts our grant. The
new private configuration consumer below uses source-owned licensing; it does
not supply those runtime integrations. A deployable app requires buildable
runtime consumers, their storage/launch/network coordination and recovery
workflow, and expiry/revocation/restart tests at each boundary. Keep the current owner's installation intact
until that replacement candidate is tested. This transport's real-device PASS
does not change those remaining results to PASS.

The current form also requires authenticated existing saved-setup readiness
before clearing the key and offering that metadata browser. A successful code
check alone does not imply storage exists. Missing state keeps the code and a
retry/support message; it never triggers setup or reset. Fresh validation and
root status use the fixed production clients, and per-attempt/phase guards close
late UI completion. The actual form component passed 39 native assertions inside
the unchanged owner manager with a fresh production website license, temporary
private endpoint and explicitly established fixture storage. Signed revocation
and service absence close the handoff. This is not normal-endpoint installation,
trusted first-unpaired customer setup, the original locked-page flow or retained
runtime admission. See the [form receipt](../../docs/release-evidence/socialbox-license-form-readiness-2026-10-01.json).

## Source-owned root service and mobile IPC client

`LicenseService.m` now owns the transport and durable vault in a real launchd
process. `LBXLicenseClient` is the asynchronous client intended for our UIKit
screens. A physical uid-501 acceptance caller exercised this exact client API,
including activation, root-service restart/revalidation and signed revocation.
This is an installed private acceptance service, **not a recovered-app update**;
the service was unloaded after the test and its private vault was preserved.

The service admits only the build-pinned executable path, size and SHA-256,
bound to this message's kernel audit token and checked again after hashing.
The client requests the privileged Mach service and checks its reply's root
audit identity and fixed executable path. Both binaries/paths must be installed
under root-controlled directories. These are process/path checks, not code
attestation against an attacker controlling root or injecting the admitted app.
An identical client copied to another root-owned path was rejected on-device.

The licensing IPC family accepts only `status`, `activate` (key only) and
`validate`. The separate typed configuration family is described below. The
service generates pairing UUIDs/nonces and owns the production origin and
pinned signer; a licensing client cannot submit a bearer, receipt, path, origin
or installation identity. Every online operation
reserves/commits through the vault. Concurrent mutations return `busy`; entering
a different key on an already paired installation does not overwrite the
existing pair. Recovery/key replacement needs an explicit future workflow.

Requests/replies are bounded and linked by a fresh request UUID and deadline.
The licensing reply contains only operation, request ID, enum result, pairing presence,
schema and `engineAuthorized: false`. A read-only status call never does a
network request or reports cached `active`. An active online result requires
a committed pairing. Signed receipts, bearer, installation ID, input key and
raw remote errors never cross back to the UI client. Disconnecting a UI does
not discard an in-flight successful server claim; its owner completes the
private commit, while the client rejects late replies. The next caller can
revalidate the saved pairing instead of generating a different UUID.

Run `bash lucid/tests/test_license_owner.sh` for 171 native assertions using the
actual transport, filesystem vault and RSA verifier with mocked HTTP. Build the
isolated rootless service/client pair using
`scripts/build-socialbox-license-service.py`; each build gets fixed private
paths and a unique launchd endpoint. It snapshots recursive inputs, signs and
checks both arm64/arm64e slices, excludes test seams and adds no entitlement.
The [IPC device receipt](../../docs/release-evidence/socialbox-license-owner-ipc-2026-09-29.json)
records the actual tests and separate NOT_RUN items.

`SBActivationView` now owns its key field and submit action. It sends only our
`activate` IPC request, never copies the key into the original form, and never
calls the original activation target/delegate. Return and tap share the same
pending guard. Known results use the central English catalog; unknown results
show a neutral service error. Rejected requests preserve the input for retry;
verified active clears it and explicitly reports that container access is not
implemented by this preview. Drawing a form makes no request. Late original
status/error labels cannot replace the source-owned result.

This deliberately invokes no original success callback or `showMainApp` and
does not write original token storage. Original app startup/periodic checks,
daemon hosted sessions and injected-engine admission still use their original
contract. There is no `unlockEngine`, arbitrary callback, receipt-write or
flag-setting operation. The app is **not ready for customer release**.

The service builder's `--consumer manager` uses reviewed compile-time endpoint,
vault and caller pins from `LBXLicenseEndpoints.h`; it emits no acceptance CLI.
The integrated builder requires `--license-public-key`, checks the service's
caller hash/size against the unchanged packaged app, adds only its own service
and launchd job, and preserves pairing state on upgrade/removal. Both iOS slices
are signed with ldid without additional entitlements. The original helper and
UI-only builders remain historical components, not a complete licensed product.

## Bounded source-consumer admission — 1 October 2026

The vault now returns an immutable `LBXLicenseVerifiedCommit` only after it
independently verifies the signed receipt and durably commits the exact reserved
generation. Its status and expiry come from signed claims, never unsigned
receipt hints. Its private configuration binding is not exported. A signed
denial cannot be turned into an active commit by changing descriptive metadata.

The root owner consumes that commit through `sourceAuthorizationCurrent`.
Fresh active verification grants at most 60 seconds, bounded further by signed
expiry. The check uses wall time and `mach_continuous_time`, rejects invalid or
backward clocks, and rechecks the private vault generation on every call.
Accepted online revalidation closes the previous assessment before transport
starts; failure, revocation or state loss leaves it closed. A new owner starts
closed even when pairing and `lastStatus` persist. A late successful reply may
preserve pairing, but an expired request cannot open source admission.

This is an instantaneous internal admission check. Source-owned operation
consumers must call it under their own launch/write fence before each protected
effect and enforce closure while running. The Boolean is not a transferable
permit or a complete storage/process/network transaction. No new admission
operation is exposed to mobile IPC, whose `engineAuthorized` remains false.
The unchanged recovered app, daemon and injected engine are still unconnected.

`tools/license_owner_admission_probe.m` is an unshipped root acceptance consumer
of the actual owner, transport, vault and production signature pin. It performs
only its own checked, disposable file write in a build-pinned private directory.
Its bounded stdin does not accept an origin, UUID, bearer, receipt or runtime
path. It emits only result and Boolean projections. It neither injects into
Instagram nor changes owner app/container files. Private credentials, original
failed test attempts and pairing records stay outside Git.

The [exact device receipt](../../docs/release-evidence/socialbox-license-source-admission-2026-10-01.json) records the final fresh-license run, preserved first-attempt failures and all NOT_RUN boundaries. The final private probe, service and client use native ad-hoc signing with explicit identifier requirements; independent strict verification passes without added entitlements. These are acceptance artifacts, not a fresh customer package.

## Serialized protected source operations — 1 October 2026

`performSourceOperation:beforeDeadline:error:` executes one trusted, short
synchronous consumer step on the same owner queue as validation. It checks the
current signed, committed admission and an absolute operation deadline before
calling the handler and before reporting success. Queue wait consumes the
original deadline; handlers cannot recursively enter this or another owner's
fence, or request a license mutation on their own owner while performing an effect.
The fence itself is not exposed as a mobile IPC operation or transferable
permit, and it sets no original-engine success flag. The typed configuration
consumer below calls it internally.

A failed handler, exception, or failed final assessment closes admission and
requires online validation before retry. Handler errors are private in-process
data; IPC and public evidence must project fixed safe fields. The fence does not
cancel a blocked handler or impose a hard queue-wait watchdog. A completed write
cannot be undone by a failed final check. Integrating consumers retain responsibility
for journaling, rollback, launch coordination and ongoing process/network closure.

The owner/IPC suite passes 220 assertions, including real signed fixture
transport/commit, a protected file write, queued expiry/revocation, held network,
nested calls, generation replacement and restart. The same private synthetic
fixture passes 220 checks on the iPhone X / iOS 16.7.16, with six installed owner
payload hashes unchanged and its exact temporary executable removed. Production
arm64 and arm64e compilation excludes test seams. These results are source-fence
evidence, not new website-license acceptance or an installed customer runtime.
See `docs/release-evidence/socialbox-license-operation-fence-2026-10-01.json`.

## Authenticated private configuration consumer — 1 October 2026

The root service now connects `LBXContainerOwner` and its private store to the
same `LBXLicenseOwner` used for production activation and revalidation.
`LBXSendContainerRequest` is the native mobile API for the separate
`container-configuration` family: `prepare`, `create`, `update`, `read` and
`list`. It uses the existing privileged Mach endpoint and exact pinned-client
peer checks. The client authenticates the root reply and validates its schema,
operation, request UUID, deadline and relation to the requested document.
The recovered owner creation/editor screens do not yet call this API.

Every configuration operation, including private reads and exact duplicate
retries, requires a current signed and durably committed source assessment
under the owner's serialized fence. Restart preserves pairing but closes
admission; online revalidation reopens it only after a new valid commit.
Signed revocation closes it. The at-most-60-second source assessment remains
bounded by signed expiry. Clients cannot supply a receipt, bearer, grant,
storage path, origin or signer to authorize an operation. The service opens
existing configuration storage without creating or repairing it; explicit
first-install private directory/lock setup is still required.

Preparation returns an immutable private document without persisting it.
Creation saves that exact document; an edit includes the complete expected
prior document and exactly one revision increment. An already saved identical
create/edit confirms the same bytes and revision without rewriting. A different
stale edit conflicts. A lost, invalid or late reply is `unconfirmed`, not proof
of success or absence. For every create/update result other than `saved`, retain
the full original candidate and UUID, including `authorization_required` after
a failed final fence check. Revalidate and reconcile an exact durable read of
that UUID before deciding whether to resend the candidate in a fresh envelope.
Do not regenerate identity choices
to retry an uncertain save. A failure after publication can close source
admission without undoing the write; journaling and power-loss recovery remain
separate work.

Configuration requests are bounded to 16 KiB and replies to 64 KiB; the service
also caps incoming wire payloads before decoding. Each request has a fresh UUID
and a 24-second deadline. Listing returns at most 40 ordered entries containing
only configuration UUID, revision, name and requested app membership, with
an exact continuation cursor; the store inventory is bounded to 4,096 records.
Prepared/read/saved records contain private identity choices and must never be
logged or exported as diagnostics. Pairing credentials remain root-private.
`runtimeAccepted` and licensing `engineAuthorized` remain false.

PASS — The focused host suites run 390 IPC, 296 container-owner, 79 store and
703 model checks. The production arm64/arm64e build includes the consumer and
excludes synthetic test seams. The earlier 73-check physical store fixture used
synthetic signing keys; it is separate from the new production acceptance.

PASS — A genuine disposable one-device website license was exercised through
the actual uid-501 client and temporary root Mach service on iPhone X /
iOS 16.7.16. All 29 acceptance checks passed: denied preparation before
activation; fresh production activation; random preparation without persistence;
exact create and retry; ten exact manual inputs on update/reload; identical
update retry without rewrite; stale conflict; bounded list/read; restart closing
access until revalidation; identical client rejection at the wrong path; and
signed revocation denying even an exact saved retry without changing record
bytes. Mobile reads of root pairing credentials were denied. The test license
was revoked, the temporary service and private device directories were removed,
and six installed owner payload hashes remained unchanged.

NOT_RUN — Existing owner configuration UI integration, retained app/daemon/
engine admission, actual Instagram/Facebook/Twitter account acceptance, proxy
ownership and traffic enforcement, automatic switching/recovery, power-loss
acceptance and the fresh customer package/download/license flow. Twitter still
has no accepted injected runtime in the retained engine. This private licensed
configuration result is not customer delivery or device-isolation acceptance.
See the [consumer acceptance receipt](../../docs/release-evidence/socialbox-container-consumer-2026-10-01.json)
and [container component contract](../Containers/README.md).

## Root-only closed allocation consumer

The same licensed configuration store and source owner now assemble
`LBXContainerClosedAllocation`, a direct root-only library consumer. It checks
the exact saved document, captures fresh physical context, reserves aliases and
journals fresh empty closed namespaces under the serialized source fence.
Activation, revalidation, restart closure and signed revocation were exercised
with a genuine production fixture. No transferable grant or mobile allocation
IPC was added. Final failure may follow durable effects; the exact candidate
requires revalidation/reconciliation. A closed namespace never admits a target
process or authorizes its lifetime.

PASS — 157 identity and 359 allocation host checks; production arm64/arm64e
without test seams; 95 root physical fixture assertions and four actual UID501
ordinary/direct known-present read denials on iPhone X / iOS 16.7.16. Exact
fixture revocation/cleanup and six unchanged owner payload hashes pass. Physical
crash/reboot/power-loss, runtime identity/registration/hooks, ongoing process
closure, current UI and customer delivery remain NOT_RUN. See the
[closed-allocation receipt](../../docs/release-evidence/socialbox-closed-allocation-2026-10-01.json)
and [container contract](../Containers/README.md) for precise limits.

## Explicit unpaired installation preparation (Unit 18)

`socialbox-prepare-installation` is a separate fixed root-only executable. Its
no-argument invocation exclusively prepares a pristine unpaired vault and
configuration namespace. `check` only opens and reobserves complete prepared
state. Neither invocation establishes paired pending state, accepts caller
paths, resets storage or grants source/runtime admission. Ordinary service
startup now requires `LBXLicenseInstallationEstablishment`; it has no old
factory fallback or initializer. Missing preparation returns unavailable.

The source-owned class writes exclusive immutable intent and prepared records
in a separate private anchor directory. Records bind exact ancestor/leaf/file
witnesses, the stable server and installation identity, namespace locks and
the observed fixed installer/service/client files. Preparation refuses every
preexisting vault, configuration or pending leaf, old pending marker or anchor.
Vault seed publication is exclusive. A failed preparation can leave durable
resources: preserve them, never adopt/delete/reset them or remint the identity.
Only a fully published prepared result can reconcile through existing-only
observation after a failed final return.

Reobservation checks canonical documents, current fixed image policy and stable
vault/namespace facts, then repeats exact anchor inventory and full file reads.
This last read rejects replacements during the earlier, longer observations.
The service checks provenance before dispatch and before projecting a result.
Signed pairing and validation still use the genuine source owner and existing
request deadline; provenance is independent of license status and stays current
after revocation. Every non-success may follow durable effects. Pending state
remains absent after genuine activation; the form must keep reporting unavailable
saved setups until that separate establishment boundary is implemented.

The build emits signed arm64/arm64e service and preparation programs. The private
package composition includes the installer but never invokes it automatically;
the existing package remains an upgrade candidate, not a customer installer.
Both `freshInstallReady` and `customerDeliveryReady` remain false. No owner
installation, customer artifact or access code is released.

This is a cooperative bounded filesystem observation, not cancellation of a
blocked syscall, publisher/signature attestation, an atomic lifetime lease or
authority against arbitrary root mutation. The immutable records pin specified
current files; replacing those images for an upgrade needs a reviewed migration
policy. Complete disappearance of all anchors cannot establish first-install
authority from absence: explicit trusted installer invocation is still required.
Missing/partial/replaced/mixed state has no reset/adoption path.

Next, bind the typed prepared witness into paired pending context under the same
source owner and original deadline. Move the owner completion to a trusted setup
queue before entering its fence. Validate proof inside the pending store's
existing held-empty-namespace callback using its passed namespace facts; do not
nest a configuration lock or call the ordinary observation API recursively.
No caller Boolean, active-license reply or checksum alone supplies establishment
authority. Default endpoint/locked-page installation, runtime licensing,
automatic switching/isolation, accounts/proxies and client delivery remain open.

Evidence: [preparation acceptance](../../docs/release-evidence/socialbox-pristine-installation-preparation-2026-10-01.json).

## Typed paired establishment and one-shot recovery boundary (Unit 19)

Genuine activation or validation now establishes saved-setup pending storage
from the exact typed prepared installation on a separate trusted queue, under
the same source owner and original request deadline. The proof is checked
inside the existing held-empty namespace callback using its original object;
no nested configuration lock, caller Boolean or bootstrap RPC is accepted.

Explicit preparation now seeds a fixed one-shot file inside the anchor. The
immutable prepared document binds its original node, full pristine file witness
and digest. Initial setup consumes that original inode before creating pending
storage. Complete durable state can reconcile; a consumed attempt with missing
or partial pending state stays closed, including loss of both leaf and external
marker after restart. Stale pristine restoration and same-byte replacement are
refused. Old no-seed prepared schema and image upgrades have no migration path.
Created root and held lock are checked before and after longer observations and
before further fresh effects. Failed setup may already have consumed/published;
retain exact state and use fresh licensed reconciliation, never reset/remint.

PASS:200 focused proof,163 paired establishment and129 updated preparation
host assertions; Store494 and RootPending581 regressions; eight package tests.
Source-stable signed arm64/arm64e builds exclude providers. Actual host-file
counterexamples cover complete loss with staged candidate/empty configuration,
interruption, unsafe nodes, stale restoration and fresh-root/lock drift.
Physical crash/process kill/reboot/power-loss remains NOT_RUN.

PASS:41 final iPhone X/iOS16.7.16 checks with a NEW genuine website key, fixed
private endpoint and independent pinned real501 native client: first activation
automatically establishes authenticated empty metadata; exact staging/retry,
creation/read/edit, validation, restart and signed revocation pass. Consumed-file
replacement denies cached/reopened/restarted service. Both private attempts'
keys are revoked and jobs/directories removed; six owner programs and18 stored
setup files match, no overlay changed, fresh quiesced backups stay private and
the original manager is relaunched. Dynamic config/license/audit files are
explicitly excluded from static equality. First phone attempt passed before
additional fresh-root/lock guards; a new second attempt accepts final source.

Default production endpoint, original locked-page owner form, fresh customer
installer/download and runtime/account/proxy acceptance remain NOT_RUN. No
permanent owner update, customer package/code or new website release occurred.
Client release remains NOT_READY. Prior actual Instagram sibling read FAIL,
Facebook launch FAIL and unaccepted Twitter runtime are unchanged.

Evidence: docs/release-evidence/socialbox-prepared-paired-establishment-2026-10-01.json.

## Loaded activation screen and package-state preservation (Unit 20)

Late presentation installation now adopts the already-loaded registered locked
license page through the same host/getter/ABI guards. It retains the root,
original controls, delegates, actions and load count. Repeated installation
preserves one source form and entered code; rendering sends no license/readiness
or metadata request and creates no admitted navigation shell.

PASS:242 synthetic presentation and86 activation checks. A private source copy
with startup-only adoption fails exactly three focused checks; working sources
remain unchanged. Source-stable arm64/arm64e production overlay,815 copy checks
and36 recovered-builder tests pass. This overlay is not installed on the owner
phone; real locked-page injection timing/default transport remain NOT_RUN.

Package preflight and incoming preinst now refuse any present fixed source
installation, pairing, configuration, pending or external-marker node, including
dangling links, after fixed parent checks. They preserve established/partial
state before image replacement while migration is unsupported. All-absent state
does not authorize preparation or a fresh customer install. Preparation remains
explicit; no initializer runs in package/abort branches. This read-only check
does not hold an atomic lock across dpkg. Focused synthetic package shell tests
are recorded in the receipt; no owner package is installed or released.

PASS read-only owner-phone inventory: new service/installer/job and five source
state nodes absent, original manager image pinned. No account/credential contents
were read, no device change or new key occurred, and absence was not used as
first-install authority. Current package remains an upgrade candidate. Corrected
report copy acknowledges implemented paired establishment without claiming a
customer installer or runtime readiness. Client release remains NOT_READY.

Next: implement the explicit trusted first-install package transaction and
normal endpoint/original locked-page acceptance, preserving all existing state
and keeping preparation out of abort or failed-check fallbacks. Runtime,
switching/isolation, actual accounts and proxy acceptance remain separate gaps.

Evidence: docs/release-evidence/socialbox-loaded-activation-preservation-2026-10-01.json.

## Separate check-only customer package profile (Unit 21)

A separate private customer candidate now keeps unpack, existing-state checks
and licensing startup distinct from the pinned upgrade profile. Complete package
inventory and safe fixed parents precede all-absent source/payload checks. Only
the exact new-version/architecture half-installed incoming transition is admitted;
external preflight refuses every recorded manager history. Passing authorizes
unpack only, never preparation. Existing or partial state remains untouched.

Configure, repeat and supported abort branches verify every installed payload
file/mode/parent/single link, then call only the fixed native existing-only check.
Failure preserves missing/consumed/unknown state and prevents startup/registration.
Removal stops licensing only; upgrade refuses before effects. The archive builder
admits only its canonical controls and cannot package source-state resources.
No initializer, reset, adoption, cleanup or original helper/engine startup occurs.

PASS20 tests and200 isolated shell lifecycle executions, frozen132 Python inputs.
Actual temporary filesystem preservation and inert command providers exercise
ordering/refusal; they do not prove native preparation validity or actual dpkg.
PASS exact private arm64/arm64e composition:56 payload files,15 unchanged original
programs including signatures; overlay69 and licensing45 source inputs stable.
The single generated configuration-header digest is recorded at build report
time; it is not a64-file frozen graph. SDK/Theos/toolchain are outside these freezes. First static test
false positive/source drift and private verifier import failure are retained.

The independently trusted external first-preparation authority/transaction is
NOT_IMPLEMENTED by this profile. No lifecycle path infers it from absent leaves,
failed checks, a reinstall or disappeared anchors. Shell checks do not lock dpkg
or establish loaded-job lifetime ownership. The candidate stays private:
freshInstallReady/customerDeliveryReady false and release gate unchanged. No
phone effect, new license, owner update, website/APT release or client code.

Next: implement/review the separate explicitly trusted preparation step and
accept exact normal endpoint/original locked page/package. Runtime/account/proxy
and safe switching/isolation/recovery remain unaccepted; prior failures unchanged.
Client release remains NOT_READY.

Contract: docs/socialbox-customer-package-contract.md.
Evidence: docs/release-evidence/socialbox-customer-check-only-package-2026-10-01.json.

## Explicit root setup command and evidence correction (Unit 22)

The fixed installer now accepts only exact `prepare` or `check` commands.
No arguments, unknown/empty/case/whitespace variants and extra arguments refuse
before a factory call. The unchanged real/effective UID0/effective GID0 guard
precedes dispatch; the actual owner role real501/effective0 remains denied.
`prepare` selects the existing exclusive factory; `check` stays existing-only.
Failure never switches routes, retries, adopts or resets. Public output keeps
private errors/paths/seeds out and carries no runtime/customer readiness.

Command intent is not independent first-install history or authority. The same
fixed process/image/path/state policy still applies; no issuer, reset, migration
or customer initializer has been added. Rebuilding changes a prepared-policy
image, so existing established installations cannot receive this replacement
without reviewed migration. All package source-state guards remain unchanged.

PASS492 assertions/35 inert actual-entry dispatches with four quoted test graph
files stable. Tests use fixture identities/factories and actual temporary output
and sentinel preservation; source factories are not linked or initialized.
PASS signed production arm64/arm64e service/installer:45 quoted native source
inputs stable, fixture providers absent. SDK/compiler/OS/public-pin input is
outside this source freeze. One generated configuration-header digest is checked
after build, not a64-file graph. The initial fixture-only Apple Boolean typedef
collision is retained; a renamed helper passes without changing production.

Unit21 evidence previously counted the64 characters of configSHA256 as64 input
files. Corrected receipt/plan: one generated configuration-header digest observed
at report time. The132 Python/69 overlay/45 native source dictionary counts and
original Unit21 package/source/test hashes are unchanged. This is a reporting
correction, not new native initialization or broader acceptance.

No phone effect, new license, owner update or public package/code/download.
External trusted first preparation, actual normal activation/installation,
runtime/accounts/proxy/safe switching/isolation remain unaccepted. Earlier
Instagram sibling read FAIL and Facebook launch FAIL remain. Client NOT_READY.

Evidence: docs/release-evidence/socialbox-explicit-installation-command-2026-10-01.json.

## Strict customer unpack inventory parsing (Unit 23)

The private customer guards now parse exactly four literal tab-separated,
nonempty fields. Whitespace splitting previously collapsed empty columns and
accepted malformed rows, unknown unrelated state words, duplicate identities
and padded manager names. C character checks, matching optional architecture
qualifiers, known states and canonical base-package/architecture keys now refuse
those observations without effects. Distinct architectures retain existing
history rules; exact incoming manager qualification retains its narrow boundary.

PASS25 tests/278 inert lifecycle executions with132 stable Python inputs.
FAIL48 expected counterexamples against the old parser are preserved. Review
corrected a now-invalid prior-version fixture so valid numeric history cases
reach and assert the migration rule; final frozen evidence uses3.0-1, matching
qualified variants and an explicit positive incoming qualifier case.

PASS exact new private composition:56 files/15 preserved original programs and
signatures, arm64/arm64e overlay69 and native45 source inputs current. One generated
configuration-header digest is reported after build and matches expected text;
the temporary file is removed, with no independent same-file reobservation or
64-file graph. SDK/Theos/compiler/OS/public-pin inputs remain outside freezes.
Initial private verifier mode-string/list-count errors are preserved and fixed
without production changes. No phone effect, license or customer artifact/code.

This is row/character validation, not full Debian version semantics, a lease or
detection of successfully omitted output. Command substitution strips trailing
newlines; a zero-record observation provides no history/preparation authority.
No firmware-row requirement, initializer, ordinary lifecycle or migration change.

Independent first-provisioning review identifies the missing issuer/verifier,
target/prior-history binding and durable one-shot backend outside the five source
nodes. A separate fixed-profile post-unpack coordinator may consume that typed
authorization before fixed prepare once/check, but no such real authority is
available or fabricated. Root intent, package records, license UUIDs and absent
anchors cannot supply it. A genuinely fresh test target is needed; the connected
owner has manager history and remains intact. Actual normal activation/package
installation and runtime/account/proxy flow stay NOT_RUN or retain earlier FAIL.
Client release remains NOT_READY; freshInstallReady/customerDeliveryReady false.

Evidence: docs/release-evidence/socialbox-customer-inventory-parser-2026-10-01.json.

## Console license authority inside each transaction (Unit 24)

Generation, edit/enable/delete and revocation now require one current console
owner inside every auth-state mutation callback before record lookup or changes.
Previously an authorized request could wait while its actor was demoted, renamed,
removed or made ambiguous, then still change a key. The existing configured-email
and admin-role policy is unchanged. Typed denial returns403 with no issued key,
auth-document rewrite or separate audit append. The production revoke route uses
a required-actor API; the old core utility remains trusted internal code, never
a request-selected fallback.

PASS42 focused real-handler groups:7 valid-owner controls,28 paused local
transactions with committed actor drift and7 explicitly synthetic callback replays.
Exact auth-document and audit bytes remain equal on denial. The old source fails
35 denied-actor cases while passing all7 controls; those counterexamples are kept.
PASS selected regressions:23 device,10 owner console,11 auth concurrency and18
legacy license groups, plus typecheck.116 cloud source/config inputs are frozen
before/after tests. A separate private synthetic-environment production build
passes with150 exact copied/current inputs; dependencies/toolchain/OS are excluded.

This proves current server-source mutation behavior, not an actual Blob conflict,
post-commit lifetime authority or deployment. No phone, real license, UI, source
installation policy, installer or client publication changed. Independent review
passes with those limits. The first-preparation issuer/history contracts and fresh
device acceptance remain open; the pending device question is not repeated.
Client release remains NOT_READY, with earlier runtime/account/proxy failures and
NOT_RUN evidence intact.

Evidence: docs/release-evidence/socialbox-console-license-authority-2026-10-01.json.

## Website license fix deployed (Unit 25)

The tested Unit24 console transaction authorization is now deployed to the existing
RedditSpoof Vercel project, from source7f1d88092aac4fc0825f4c503f7553031c72b81e.
The new immutable deployment is dpl_H7CgNzAtQo51hW27iqA2LY9KNJAZ. An unaliased
production build passed before promotion; the canonical production ID is verified
after promotion. Existing production environment is inherited without exporting,
rotating or uploading secrets. No license/account mutation or phone effect occurred.

PASS all18 cloud suites in a new local synthetic copy with151 frozen inputs
(150cloud plus1 tracked profile-ID fixture). Initial runner count and missing-fixture
preparation failures remain privately preserved; the final suite passes without
production changes. PASS exact150-file dry upload manifest (149tracked files and
root ignore; cloud/.gitignore ignored), remote Next14.2.35 build and30 static pages.
No private customer .deb/.ipa, environment files or state is uploaded.

PASS before/stage/final16 APT metadata byte comparisons across both published
repositories. The owned conditional publisher lock is released; it serializes
cooperating publishers only. Anonymous sign-in/install pages pass, admin returns403,
latest release remains unavailable and SocialBox Release returns404. Redirects are
refused before following them; an inert302 test proves no second-server request.
Exact deployment/project/source metadata is checked independently through Vercel.
This is upload/provenance/public gate acceptance, not independent compiled-bundle
bytes, actual Blob actor contention, owner login or production signing readiness.

Client NOT_READY. Check-only customer artifacts remain private/unusable for fresh
configure; no access code or app download is issued. First-preparation issuer/history
contracts and the already pending clean-device question remain open. Actual normal
native installation/default locked-page activation and runtime/account/proxy flow
remain NOT_RUN or retain earlier FAIL. Instagram sibling reads still fail isolation;
Facebook launch fails and Twitter runtime is unaccepted. Owner UI/accounts are intact.

Evidence: docs/release-evidence/socialbox-website-license-deployment-2026-10-01.json.

## Console read authority and coherent projections (Unit 26)

Private license/user GET endpoints now require one unique current owner in the
final auth-state snapshot they project. License reads finish the separate audit
read before that snapshot and check; user rows and device counts use one shared
snapshot. No later await follows the guard. Typed owner-policy denial returns403;
other storage/audit failures propagate. No write transaction is used to authorize.

PASS20 focused groups:2 normal controls,2 preexisting duplicate-ID denials,
12 actual-handler/local-commit actor drifts,1 coherent user/device snapshot and
3 exact non-policy error propagations. PASS104 selected licensing/console/auth
regression groups and typecheck.151 copied/current cloud inputs remain stable.
The exact final typed fixture against a fresh old-source archive passes5 controls
and fails15 privacy/coherence cases;150 original committed inputs and151 current
inputs are separately verified. Initial narrower fixture attempts and the test-only
NextResponse union inference failure remain retained; common Response typing fixes
compilation without changing production policy or behavioral checks.

PASS separate synthetic-environment Next14.2.35 production build with151 frozen
copied/current inputs and30 static pages. No deployment, live account/license,
phone/native UI/installer or customer artifact/code effect in this unit. Existing
Unit25 website deployment still serves mutation-source7f1d880; this read fix is
source-only until a new accepted cloud deployment. Independent review passes.

Authority is limited to the observed snapshot, with no post-read lifetime claim.
Audit remains a separate collection. Existing readAuthState/session resolution
can initialize/migrate legacy auth; byte equality is established-fixture evidence,
not a new global no-write read contract. Other admin domains remain outside this
unit. Client NOT_READY: first-preparation/history authority and fresh-device input
remain open, alongside native/default installation and earlier runtime/account/
proxy failures and NOT_RUN. Source setup removal needs new retirement/IPC policy;
no deletion/discard/thaw or numeric-CID/runtime action is added here.

Evidence: docs/release-evidence/socialbox-console-read-authority-2026-10-01.json.

## Console read correction deployed (Unit 27)

Unit26's private console read correction is live on the existing RedditSpoof
project from source 1e614087fda954ebd1753e804528279bb2e3cbf3. The exact new immutable deployment is
dpl_8gVkfngk8PvzQun2UhY2JzppNCfz, verified at the canonical production alias after promotion.
Existing production environment is inherited without secret export/rotation.
No phone, native UI/installer, account or genuine license changed.

PASS all19 website suites in a NEW synthetic/local copy with152 frozen inputs
(151 cloud plus1 tracked profile-ID fixture). PASS exact151-file dry upload:
150 tracked cloud files and1 root ignore; no environment/state/native package.
Remote Next14.2.35 build compiles/types/prerenders30 pages and is READY before
promotion. Exact immutable CLI/API project/id/URL/production/source metadata is
reconciled; observed response digest and retained sanitized summary hash remain
distinct. Neither verifies independent compiled-bundle bytes or publisher.

PASS fresh before/stage/final comparisons for16 APT metadata files in both
existing repositories. The owned conditional publication lock is released.
Anonymous admin remains403, latest release available:false and SocialBox
Release404; install retains sctweaks and blocked-client messaging. Prior alias
is checked before upload/promotion and the final alias matches the accepted ID.

The first private reconciliation parser assumed a top-level CLI id; actual
status:ok has a nested deployment object. Failure precedes API/journal changes.
NEW corrected reconciliation requires that shape/READY/production plus unchanged
independent API guards. Original result/owned operation remain; no redeploy or
regenerated outcome. Independent prepublication/API/corrected-source review
and final receipt/log/hash/count/journal review pass with limits; a transient
reviewer completion capacity error is scoped.

Client NOT_READY. Website metadata/public behavior is not actual owner-read race,
Blob contention, signing, first-install or runtime acceptance. First-preparation
issuer/history contracts and pending clean-phone input remain open. Instagram
sibling read FAIL, Facebook launch FAIL, unaccepted Twitter and actual account/
proxy/safe switching/recovery gaps remain. No app artifact/code/download issued.

Evidence: docs/release-evidence/socialbox-website-read-deployment-2026-10-01.json.
