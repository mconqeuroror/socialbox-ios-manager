# Rootless RedditBox 0.1.8 — troubleshooting history

Branch: `feat/lifecycle-and-distribution`, not merged.
Rows: UI-003, LIFE-029. This is the earlier rootless test history, not acceptance of the later rootful 0.1.8 build.

The identity editor loads saved identifiers into the editable form through a
bounded, request-bound private Keychain draft. Random fill creates a draft;
Check consistency and Save changes remain explicit. Used identities retain
their existing freeze rules. Public launcher state and action receipts do not
carry the raw identifiers.

The first existing profile exposed a startup bug: fingerprint refresh called
`deletionStateForContainer:` inside a central-store update; that method reads
the same serial store queue. The regression fixture now reproduces that read
and failed before the fix. Retirement inspection now happens before the update;
new rows wait for a later inspection. Cloud retirement in the current document
remains excluded. A redundant post-install `kickstart -k` was also removed:
RunAtLoad starts the bootstrapped service once. The startup crash reproduced
without the redundant restart, so that script change alone was not the fix.

## Earlier device results and recovery history

After the original 0.1.6 report, USB/SSH reconnected. The failed test container
was deleted through the normal daemon and a new `Test container` was created
with a hidden clone. Imported Reddit source reported 2026.36.0. Managed VPN/MDM
adoption and clone login were not performed.

0.1.7 was installed, but startup with the existing profile terminated with
SIGTRAP. One exact task-owned active marker was archived after stopping the
service and checking process enumeration, CLOSED local lease, empty pending
IPC, valid store/profile schemas, committed journals and absence of unproven
helper-exit fences. A single bootstrap still trapped and left a new marker.
This was a manual evidence-bound recovery intervention, not an automatic
recovery feature or a passed isolation test. Original marker evidence was kept.

## Acceptance limits

No claim of 100% isolation. Visible UI taps/rendering, managed VPN routing,
MDM association, clone login, cross-container canaries and rootful-device
acceptance are separate outstanding tests. Saved proxies currently share one
selected connection proxy; the list does not assign one proxy per container.

## Rootless device verification

Exact rootless 0.1.8 package bytes were transferred with SHA-256 comparison
and installed on the connected iPhone 8 / iOS 16.7.7. After the fixed build was
installed, the second exact crash marker was archived using the same stopped
service, process, helper-fence, CLOSED-lease and read-only schema checks.
Startup then returned `Startup recovery completed`; recovery state was empty.

Real daemon/private-Keychain requests passed: saved-value load for all ten
identifier fields, changed random draft, UUID format checks, exact-draft
consistency preview, reload proving Random fill did not mutate saved values,
and absence of raw identifiers from public status and receipts. These exercise
the editor's backend actions, not touchscreen rendering.

A subsequent real Save changes test did **not** pass: the daemon was terminated
by OS_REASON_JETSAM while the clone transaction was still `prepared`. Kernel
readback after restart reported 256 MiB active/inactive limits (the launchctl
plist display alone reported 6 MiB and was not used as the actual limit).
The operation receipt reports interrupted execution. Store/profile and the
staged rollback files remain present; Save changes is not accepted on 0.1.8.
The later bounded-resource-reader build must establish that separately.
