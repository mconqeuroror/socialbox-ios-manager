# Isolation Sentinel — ACCEPT-005

The sentinel is a diagnostic observer inside each clone. It is **off by default**.
Enable it in Containers → Edit → Show advanced groups → Isolation Sentinel,
then **Save sentinel settings** and reopen the clone. The interval is 1–1440
whole minutes, default 15. Saving these settings does not edit the identity,
rebuild entitlements, replace hooks, or operate the network gate.

The observer registers only after the existing hook readiness receipt belongs
to this process and is at most 60 seconds old at registration. It runs at launch, on return to the foreground, and on a
coalescing periodic timer. iOS suspension delays timers; this is not a background
execution entitlement. At most one probe batch executes at a time. Slow results
are not published as current evidence after 60 seconds. OFF registration creates
no queue, timer, foreground observer or probe thread. Enable requires a relaunch;
disabling is observed at the next scheduled/foreground invocation.

## Probe contract

- **Keychain default/group**: `SecItemCopyMatching` queries only the existing
  `com.redditbox.acceptance.canary.v1` service and a prepared nonce account,
  once with no group and once with the sibling's `RBXCLONE00.<bundle>` group.
  No item is added/deleted by the sentinel, no authentication prompt is allowed,
  and item contents are not requested. Success is LEAK. Item-not-found is
  inconclusive: the historical seed receipt cannot witness current Keychain presence.
  Explicit-group missing-entitlement is bounded access-denial evidence with the existing seed witness. Locked-keychain/provider errors are NOT_RUN.
- **Filesystem**: `NSFileManager attributesOfItemAtPath:` examines the sibling
  home and `NSFileHandle fileHandleForReadingFromURL:` attempts a read-only
  handle to its nonce sentinel (or its known home when unseeded). No bytes are
  read and no sibling file is changed. Visible metadata or an open handle is
  LEAK; denied/NOENT requires the daemon's current path witness to pass.
- **Defaults**: a fresh `NSUserDefaults` object calls `addSuiteNamed:` with the
  sibling's actual bundle domain, reads exactly `RBXAcceptanceCanary.<nonce>`,
  then removes the suite from this object's search list. Any value is LEAK.
  No setting is written by this probe.
- **Pasteboard**: ordinary `UIPasteboard.generalPasteboard` public getters are
  sampled on the main thread. Visible content with the blocked clipboard policy
  is LEAK. Empty content is NOT_RUN without an independent sibling-marker witness; it does
  not prove an A/B marker experiment. Explicit shared-clipboard compatibility
  produces NOT_RUN, never an isolation PASS.

All probes use the same public symbols as the app. They do not call original
IMPs or use the internal control-file path bypass. Descriptor-relative IO is
limited to the observer's own control and report files.

### Optional clipboard write challenge

The separate **Optional clipboard write challenge** switch is off by default.
It attempts one unique local-only marker at first run, expiring after 60 seconds,
through the public setter. With working blocked-clipboard hooks the marker is
discarded. If blocking is broken it can replace clipboard contents: enable this
only for an intentional experiment. Shared-clipboard compatibility skips the
write to preserve user content. Subsequent foreground/periodic reads check the
current view; they do not restore a saved clipboard snapshot. The normal observer
is read-only apart from its own diagnostic receipt/log.

## Reusing the SSH acceptance canaries

Use the existing `scripts/device-acceptance-ssh.sh` seed → verify → cleanup
procedure documented in `docs/on-device-smoke-checklist.md`. The **seed** stage
runs in clone A, not as a privileged Keychain read in the daemon. Its existing
nonce-bound request and receipt are retained. The seed now optionally writes
and verifies one nonce key in A's own defaults domain; cleanup removes only
that exact key after matching its value. It never changes a pre-existing
different value. Ordinary launches without an acceptance request do not seed.

The daemon reads the existing root-owned acceptance request, bounded mobile-owned
seed receipt and exact sentinel file. It checks the bundle/data-container pairing,
nonce, expiry, successful seed checks and the actual defaults plist marker before
supplying a target. It does not invent a successful seed or reuse an expired or
cleanup-stage request. Repeat seed preparation in other clones to test more than
one source. Keep the original private SSH nonce ledger and finish its cleanup.

Sibling target/control witnesses refresh about every 15 seconds and expire after
60 seconds. Keychain evidence additionally expires with its acceptance request
and at most one hour after the seed receipt. A prior successful Keychain seed
plus surviving file witness is time-limited evidence, not proof the item cannot
have been independently deleted since seeding. Defaults/file witnesses are
rechecked by the daemon. Missing sources never become green Keychain/defaults
rows. The fixed batch is bounded to 64 siblings; unavailable or excess siblings
must remain an explicit coverage limitation.

## Results and limits

Settings → Diagnostics → **Isolation Sentinels** shows per-container last-run
time and individual probe verdicts. `RBX_SENTINEL` logs include the current
container, probe, ordinal sibling label, status and numeric error only. No
credentials, marker contents, sibling filesystem UUIDs or access-group strings
are copied into public launcher state or logs.

A LEAK is shown as FAIL and **Isolation alert** in the launcher. From rootless
0.1.14 / rootful 0.1.12, the daemon refuses a subsequent Open while that finding
is retained. Admission rechecks before starting a switch and immediately before
OPEN; unreadable safety state also blocks. Disabling the sentinel or a later
empty probe does not clear the finding. There is no unconditional UI reset.
Review the evidence and repair the affected isolation before returning the
profile to service. The observer itself still does **not** close/open the gate,
stop an already-running app, change hooks or grant an exemption. Existing
lease/transport failures continue to revoke traffic through their own enforcement.

Observed foreign values, metadata or read handles remain LEAK even when a later
probe or cleanup throws. Structurally valid older reports retain LEAK rows while
unsupported PASS classifications are normalized to NOT_RUN. See
[the storage review](isolation-storage-audit.md).

The daemon validates report schema, required rows, control revision, bundle,
container, PID/executable, current generation, clone-scoped boot epoch and
freshness. Current results also require the coordinator's daemon-owned active
identity and a fresh kernel process-birth observation (seconds and microseconds).
The observer rechecks that authority after validating the report; a reused PID,
closed lease, changed selection or missing provider cannot reuse an old result.
Readiness must postdate process birth and follow the ARMED/OPEN receipt ordering. Stale or closed-process reports are not presented as current PASS.
This is evidence from code inside the app process, **not tamper-resistant
attestation** against a fully compromised clone. It covers these named API calls
and known targets only; no result establishes 100% isolation or exhausts
`LEAK_SURFACE.md`.

## Validation

`tools/test_isolation_sentinel.sh` runs mocked Security/Foundation/defaults/
pasteboard cases, including unexpected success, denied/not-found, provider
errors, exceptions, stale witnesses, self/traversal targets, replayed receipts,
empty reports and OFF/ON registration. `tools/test_clone_architecture.py` checks
the production registration after readiness and public-API/no-gate plumbing.
Existing acceptance/readiness tests must still pass with sentinel OFF.

Rootless 0.1.13 was installed on the attached iPhone. The real launcher IPC accepted valid settings, rejected malformed settings, delivered the root-owned clone control, and restored OFF. Profile bytes, other container metadata, the network state/generation and the active license were preserved. This did not execute probes inside a launched Reddit clone.

Actual iPhone acceptance needs two installed, separately seeded clones and the
existing managed per-app routing setup. Verify A → B → A, closed/suspended report
staleness, optional challenge OFF, compatibility NOT_RUN, and injected failures
in a controlled test build. Root SSH observations and host mocks alone cannot
close these on-device acceptance rows.

The actual daemon observer is also exercised by `tools/test_sentinel_controller.sh`: 98 native assertions cover its process binding, stale/foreign receipts, lease ordering, OFF and retained-alert publication. These execute mocked kernel/storage boundaries, not an iPhone or the recovered SocialBox runtime.

## Checked report retention — 21 September 2026

Before reading a process-bound report, the daemon now establishes durable
operation ownership. A LEAK flag and its alert are published together through
the checked central-store API and read back. A failed write, false success,
interrupted processing or missing profile cannot silently leave future launch
admission clear. The observer never recreates a deleted profile.

A retention failure sets the existing recovery fence and keeps the preceding
active-operation journal. That surviving journal also blocks a later daemon
boot if the secondary unsafe-file write failed. Successful publication retires
its operation ownership and leaves the per-profile quarantine in the store.
If the initial journal cannot be established, the report is not consumed and
current-process admission is fenced. No new clear/reset control is exposed.
The launcher distinguishes failed persistence from an ordinary probe result.

This is a persistence guarantee within the existing operation-journal trust
boundary, not tamper-proof storage or a guarantee that every clone report is
received. A clone can terminate before any eligible observation. The observer
still makes no network or process-control calls. The existing operation fence
prevents new mutations/admission and is honored by in-flight operation checks;
a normal retained LEAK blocks that profile's subsequent Open. Probe execution
on iOS, app-specific Keychain behavior and network enforcement remain separate
device acceptance requirements. This implementation is not linked into the
recovered SocialBox data-switching backend.
