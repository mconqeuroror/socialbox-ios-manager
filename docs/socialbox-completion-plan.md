# SocialBox: one product, one release acceptance plan

Status on 2026-09-30: **NOT READY FOR CUSTOMER RELEASE**.

Actual installed `.17` Instagram A/B/A testing on the owner’s iPhone now
reproduces an isolation failure: B can read A’s witnessed test file through
both `open()` and a direct syscall. Ordinary file/preferences/test Keychain
separation and distinct/stable local IDFV pass. The original/default signed-in
state resumed and temporary instrumentation was removed. A subsequent
manual directory-permission experiment denies that canary in Instagram through
both entry points, but automatic switch/recovery integration remains unfinished. This does not test
two signed-in accounts, network isolation, website licensing or fresh client
installation. See the [sanitized physical-device receipt](release-evidence/socialbox-instagram-owner-trial-2026-09-30.json).

This is the active implementation plan for replacing the installed recovered
engine with the independent SocialBox source stack. It consolidates the earlier
licensing, UI, migration, networking and app-acceptance work. Completion of a
component is not completion of this plan. Work stays on `feat/lucid-base`, with
logical tested commits pushed without merging.

## Why earlier milestones did not produce a usable replacement

There are two implementations. The installed `.17` package has the newer
presentation but still relies on the recovered engine. The private source
`0.2.0` packages use our working signed license verification, launcher, daemon
and tweak. The source launcher now has Containers, Connection and Settings,
but Facebook remains inactive,
and their online launch path requires managed per-app VPN configuration. The
new UI and independent admission have not been integrated into one accepted
installed product. Installing a different package or relabeling its status
cannot close those gaps.

The current phone has no MDM. The PF work establishes read-only capability,
a host-tested policy model and compiled-rule readback, not working network enforcement. Migration of the
recovered data is also different from upgrading the existing source schema.

Evidence: [source candidate](source-socialbox-candidate-checklist.md),
[licensing](socialbox-source-licensing.md), [network feasibility](no-mdm-network-feasibility-2026-09-20.md),
[PF model](../experimental/pf/README.md), [physical storage results](storage-lifecycle-0.1.35.md).

## The release contract

The exact package to publish must complete this workflow on a real supported
phone, with the recovered engine and its injected helpers absent from the
running path:

1. Fresh installation opens the English SocialBox license screen only.
2. A valid license unlocks through our existing server and signing key; an
   invalid/revoked/expired grant remains locked. A second physical phone cannot
   claim a one-device license. Reopening the original installation still works.
3. Import a supported decrypted source IPA; select a proxy; automatically
   prepare a consistent identity; review/edit/cancel; create a container.
4. Select container A, open its app, retain its own data, switch to B, then
   return to A. Never regenerate an existing identity during a switch.
5. Network failure, stale authority, interrupted switching and unverified
   protection prevent online launch. Restarts do not silently reopen an account.
6. Edit, rename, organize, back up and restore through the new UI. An upgrade
   preserves containers, identities, proxy assignments and license binding.
7. The owner tests a candidate, then explicitly promotes those exact hashes.
   Customers see the available update and can upgrade without a purge.

Reddit and Facebook are required. Instagram, X and other requested reference
features remain in the completion backlog until their actual implementations
and inputs are verified; they are not silently counted as supported or dropped
because the registry lacks them. No recovered-license patch or always-valid
grant is part of the independent implementation.

## Implementation units, in dependency order

### 1. Protect and map existing state

Implement bounded, read-only backup inventory first. Verify the saved archive
against its manifest, count records inside metadata rather than directories,
compare global/per-app indexes by stable ID, and retain unknown memberships or
fields as explicit unresolved items. Never treat a profile reference as a
complete identity or infer a logged-in account from a record count.

Next capture a fresh, quiescent device inventory and backup including each
actual target app's account storage and a reviewed Keychain recovery strategy.
Map old records to the source schema on a private copy. Preserve IDs, identities
and bytes; define a reversible representation when one old multi-app record
maps to several source app profiles. Unsupported system apps remain untouched.
Do not turn them into Reddit profiles or invent a replacement identity.

Add a journaled transition with full preflight before any mutation, rollback
of package and data, and interruption tests at every publication step. Keep
the existing pre-install mixed-engine rejection until this transition exists.

**Done when:** the private migration and rollback round trip preserves all
in-scope data, unknown records fail without writes, and the same transition
passes on the phone. A manager-state backup alone does not prove account recovery.

### 2. Establish working networking without MDM

Treat this as the principal architecture gate before polishing or shipping.
The present app-proxy backend cannot satisfy the user's no-MDM setup.

The independently written PF candidate needs a real kernel rule adapter,
serialized ownership/fencing, complete readback, retained-state removal,
independent expiry/recovery enforcement and boot handling. Test it with
disposable clients and out-of-band recovery before integrating it. Do not load
experimental deny rules when SSH is the only recovery path.

PF destination rules apply to the device, not an individual clone. They must
be labeled accordingly and cannot replace selected-container authorization.
Prove that inactive/background clones and brokered requests cannot use the
selected proxy. If the architecture cannot satisfy that requirement, reject it
and implement a different independent transport; do not turn a failed gate green.

**Done when:** independent traffic measurements cover IPv4, IPv6, DNS, UDP/QUIC,
existing sockets, proxy loss, interface changes, daemon/guardian death, reboot
and rapid switching, in synthetic clients and actual apps. Required management
and recovery traffic must work without broad escape exceptions. Record any
unavoidable system traffic separately from app traffic.

### 3. Close storage and app lifecycle defects

Repeat the real in-process A/B probes, including direct syscalls, against
known-present sibling canaries. Resolve the recorded directory-metadata
visibility failures and app defaults/Keychain/shared-data gaps, or define a
different enforceable boundary before making an isolation claim. A successful
root helper or hook-readiness report is not an app-process test.

Finish Facebook's defaults/SDK/wire paths and stable foreground/background
operation before changing its runnable flag. Verify both Reddit and Facebook
source import, create, selection, close, replace, delete, restore and upgrade.
Add IG/X descriptors only alongside their source inputs, app-specific review
and acceptance; app naming alone is not implementation.

**Done when:** actual apps retain their own data and cannot read sibling
control values through the enumerated APIs; all reproduced defects have
regressions; the isolation ledger links every verdict to current evidence.
Server-side correlation or resistance to a fully privileged attacker is not
promised by this product.

### 4. Finish one independent English interface and feature set

Use source-owned operations and typed results behind the custom UI. Retain
the agreed **Containers / Connection / Settings** navigation, license-only
locked root, graphite/teal styling and original local assets. Remove the
presentation's dependencies on recovered controller classes rather than
forwarding to them or falling back to the old UI.

Complete automatic identity preparation, model/iOS/screen consistency,
proxy-region suggestions, manual review, proxy normalization, optional rotation,
map/search/coordinates/saved places/history, and understandable setup errors.
Unknown region or proxy results remain unknown; no direct-network fallback.

Reconcile each item in the existing reference/UI inventory: container menus,
folders/order/import/export, identity editing/rules, Cloud, diagnostics, guide,
contact and maintenance. Each item needs a source operation, an explicit
acceptance case and a supported result. Preserve account/token privacy and
destructive confirmations. Keep the private web focused on owner licensing;
do not restore the old shop or checkout.

**Done when:** every agreed navigation path works on the source build, including
empty/error/cancel/locked/late-response states, keyboard and long text; 40 items
retain their stable action targets; a phone recording shows the full workflow.

### 5. Prove installed licensing, Cloud and recovery together

The native verifier and production service tests already pass, but the installed
UI → request queue → daemon → server path still needs acceptance. Test exact
device binding on two physical phones, revocation, restart, offline expiry and
recovery without replacing the existing cloud signer or customer keys.

Test Cloud backup/restore with the real supported account data, ownership and
license checks, interrupted uploads/downloads and exact restore identity rules.
A local metadata export is not cross-device session restoration. The user
performs account sign-ins when required; tests must not invent that evidence.

**Done when:** both hardware licensing and cross-device restore receipts pass
for the stated supported apps, with secrets retained only in private evidence.

### 6. Candidate → safe update → customer release

Connect the source build lane to the existing signed APT release workflow,
separate public Blob store and shared publication lock. Preserve both rootless
and rootful repositories. Bind owner acceptance to exact package hashes and
tests; changing the artifact invalidates approval. Provide the requested owner
promotion control without reopening unrelated public console features.

Test clean install, upgrade, interrupted upgrade, full disk and rollback.
Update notifications must identify the available version and preserve data
during a normal Sileo upgrade; never instruct customers to purge first.
Do not promise silent automatic installation where only an update prompt exists.

Create 40 disposable containers if device capacity allows and verify routing,
own markers and sibling denial for each; a capacity failure must preserve the
ones already created. Repeat outage/reboot/switch stress on the final candidate.
Rootful support needs its own acceptance evidence before advertising it.

**Done when:** all required release cases pass on the final artifact, existing
Reddit regressions and build/ledger checks pass, staging and production files
verify, both repository histories survive publication, and rollback is proven.

## Reporting and completion rules

- Use `PASS`, `FAIL` or `NOT_RUN` per acceptance case with app/version/device,
  source revision and exact package hash. Distinguish host fixtures from hardware.
- A fixed bug updates its row and regression; it does not reset the audit to
  “all clear.” Preserve unresolved rows and counterexamples.
- Offline unit checks can pass while device acceptance is blocked. Publish
  neither a customer-ready status nor a package promotion from that situation.
- No time promise replaces the gates. If a necessary design is infeasible,
  record the failed requirement and concrete alternatives, not an enabled bypass.

## First implementation result

`tools/source_transition_inventory.py` now verifies a private gzip/tar backup
against its saved manifest without extracting or writing data. It reports
aggregate counts and fixed error codes, not names, IDs, seed values, tokens or
credentials. Run it with `--archive <private-state.tar.gz> --manifest <manifest.json>`.
Exit zero means a completed, consistent metadata inspection only;
`readyForInstallation` remains false.

The saved `.17` backup verifies **17,472 entries**, **107 global container
records** and **107 matching per-app index records**. Those are the same 107
records, not 214 containers. Their memberships are all outside the supported
social-app map; read-only schema inspection identifies the jailbreak loader.
No Reddit/Facebook/IG/X account is inferred from them. Original data is unchanged.
An existing source-store entry is also present and explicitly requires
reconciliation; the destination must not be assumed empty. Seventeen inventory
test methods, the existing native backup-snapshot test, update-startup regression,
static checks and the isolation-ledger check pass.
The receipt is [here](release-evidence/source-transition-inventory-2026-09-29.json).

On this turn the USB device list is empty and the saved SSH endpoint resets
the connection. Fresh phone capture, mutation, installation and on-device
acceptance have not occurred. This observation does not stop local development.

## Networking implementation result — 2026-09-29

The non-shipping PF compiler now emits closed/proxy rule images and validates
readback of full rules, root families, tickets, creator identity, address pools
and PF interface flags. Skip-filtering flags, hidden pools and unconstructed
policy objects fail verification. The private read-only CLI is built and signed
for arm64/arm64e with verified empty entitlements; it refuses unreviewed kernels.
Native compiler/readback tests: **1,365 assertions PASS**; command tests: **6
methods PASS**; existing policy model: **596 PASS**; prior read-only inventory:
**132 PASS**. Additional pinned ABI checks: **86 per host/arm64/arm64e PASS**,
alongside the previous 112 host/arm64 assertions. These do not prove enforcement.

Apple's transaction commit validates an inactive ticket, not a CAS of active
policy. An ownership/coexistence design must resolve that before implementing
the model's writer contract. Loader, independent revocation, boot handling,
attribution and measured packet acceptance remain open. USB enumeration is still
empty; no new code was installed or firewall state changed on the phone.
