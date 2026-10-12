# Native Instagram isolation work — 3 October 2026

**Implementation checkpoint; native switching is not yet isolated.** These
components build separately from the installed presentation overlay. They are
not connected to the recovered switch workers or included in a customer release.
The original Instagram account and container selection are preserved during the
private probes. Source tests are not evidence of an isolated installed app.

## Implemented components

- `LBXNativeStorageInventory` resolves the installed Instagram application,
  extensions and registered shared groups. It observes storage metadata without
  reading account files. An unavailable extension needs an exact non-executable
  binding; its absence from registration alone is insufficient.
  Repeated ancestors share a descriptor only for the same canonical path and
  held parent. Every reuse checks the original identity, ownership, permissions
  and ACL again; the final complete membership check remains required.
- `LBXNativeStorageLayout` includes numbered profile directories and ordinary
  default-profile entries. Five observed extension homes have no numbered store;
  their default data cannot be opened for a numbered profile.
- `LBXNativeApplicationGate` records executable identities and original modes,
  closes execution, verifies process exit and restores execution only after
  fresh absence and caller authorization. Recovery reopens the exact durable
  record in a fresh process. It loads LaunchServices independently.
- `RBXStorageGateImmutableNodeSetTransition` seals inactive files/directories
  with root ownership, restrictive permissions and `UF_IMMUTABLE`. Namespace
  directories stay searchable but immutable. Existing recursive ownership
  changes cannot reopen sealed nodes without removing their flags.
- `LBXNativeIsolationJournal` provides a root-owned, locked, atomic transaction
  record. It checks the live file and generation before replacement. Unknown
  orphan staging files cause a recovery refusal; automatic reconciliation for
  that case remains unfinished.
- `LBXNativeStorageFence` combines the above. It freezes the complete observed
  layout before opening only the selected profile. Restart recovery closes
  access; it never infers permission to open a profile from a saved phase.
  A failed partial execution restore requires another process drain.
- The Darwin process observer retries a failed identity observation using at
  most three entirely new process tables. It discards all partial rows. A
  persistently unreadable process still fails the operation, and elapsed retry
  time counts against the request deadline.
- `LBXNativeBrokerAuthority` implements the drafted admission/epoch contract
  for official Instagram and Facebook only. Restart always closes admission and
  tombstones prior process assignments. Leases are explicit; dropping a lease
  does not satisfy the close barrier. Host tests cover IG CID 0, FB CID 109,
  relabel refusal and restart tombstones. Production kernel observation still
  fail-closes until a verified audit-token observer is wired.
- `LBXNativeControlStore` records per-app selected CIDs plus shared-group
  device/inode identity. Instagram and Facebook cannot admit different CIDs on
  the same physical family group. Distinct groups may differ. No control-plist
  or account bytes are read or written. This is not yet connected to the
  installed Switch worker.

The shared writer observation on the owner phone identifies Instagram and
Facebook as users of the same physical family group. The observed Facebook
registration is routed to profile 109. Opening different profile directories
for the two apps simultaneously would expose sibling data to their shared UID.
The root coordinator must preserve this shared-group constraint.

## Build

Use macOS with the configured Xcode iPhoneOS SDK and a working Procursus `ldid`.
Run from the repository root. Output directories must be fresh; builders refuse
to overwrite a previous attempt.

```sh
python3 tools/build_native_storage_inventory.py \
  --output /absolute/private/work/inventory-build \
  --ldid /absolute/path/to/ldid

python3 tools/build_shared_group_writer_inventory.py \
  --output /absolute/private/work/writers-build \
  --ldid /absolute/path/to/ldid

python3 tools/build_native_application_gate_probe.py \
  --output /absolute/private/work/gate-build \
  --ldid /absolute/path/to/ldid

python3 tools/build_native_storage_fence_probe.py \
  --output /absolute/private/work/capture-build \
  --ldid /absolute/path/to/ldid
```

Builders compile arm64 and arm64e, sign and verify the final universal binary,
check entitlements and record hashes for every local source dependency. They do
not install or run the programs. The ordinary gate build excludes the private
unstarted-probe abort restoration entry point.

The gate exercise changes executable permissions and stops Instagram. It is a
private acceptance operation with a durable journal and explicit recovery,
not an app installer. Keep its original-code record until restoration has been
independently checked. Do not treat a recovery success as a passed launch test.

## Focused validation

```sh
bash tools/test_storage_directory_gate.sh
bash tools/test_native_storage_inventory.sh
bash tools/test_native_storage_layout.sh
bash tools/test_native_isolation_journal.sh
bash tools/test_native_storage_fence.sh
bash tools/test_shared_group_writer_inventory.sh
bash tools/test_native_storage_fence_probe.sh
bash tools/test_recovered_process_drain.sh
bash lucid/tests/test_native_application_gate.sh
bash lucid/tests/test_native_application_gate_probe.sh
bash tools/test_native_broker_authority.sh
bash tools/test_native_control_store.sh
bash tools/test_native_switch_coordinator.sh
bash tools/test_native_family_storage_layout.sh
bash tools/test_native_manager_bridge.sh
```

The fence tests use real temporary filesystem objects, flags and journal files,
with fixture process/registration authority. They cover interrupted transactions
and the case where execution opens, restoration fails and subsequent process
absence cannot be verified. That case remains recovery-required and cannot
commit an active profile.

## Physical checks completed on 3 October

- The ordinary launch-gate exercise passed after verified process exit. A child
  with real/effective UID/GID 501 and no foreign or root supplementary group
  could not launch the exact Instagram executable: EACCES (13).
- All eight original executable entries were independently verified after
  restoration, including hashes and attributes. Instagram reopened normally.
- The read-only fence capture passed for 94 protected nodes, 25 namespaces,
  ten roots and eight executable entries. Final storage inventory and original
  code were unchanged; no process was terminated and no data permissions or
  selected container were changed by this capture.
- The previous second-inventory refusal was reproduced under a descriptor
  limit of 256 with 96 slots available. The corrected scanner completed eight
  identical full observations under that limit. Inventory tests pass 589
  assertions; capture tests pass 42. Replaced or changed cached ancestors are
  still rejected.

These checks establish the component behavior above. No actual data fence has
been enabled in installed switching. They do not establish broker isolation,
every possible application launch route, or a completed account/proxy workflow.

## Required integration

1. Connect the confirmed UI action to an authenticated root transaction before
   the original worker writes metadata. Cover creation, deletion, deactivation,
   batch operations and CLI writers as well as the Switch button.
2. Protect the native control plists, runtime selection and identity trees
   outside Instagram's OS-issued data homes. Preserve the distinction between
   the global UI selection and Instagram's per-app selection.
3. Bind Keychain and preferences requests to their authenticated process and an
   immutable container generation. Wait for old requests and retained sources
   before admitting the next generation.
4. Coordinate all actual shared-group writers, then perform physical A/B/A
   tests of sibling paths, default roots, groups, Keychain and preferences,
   followed by account and proxy workflow checks.

The existing observer requires the original executable binding to be executable.
A closed-gate observation therefore needs a separately validated typed binding
before integration. Five default-only extension homes also need explicit profile
placement; opening their defaults for another profile is not permitted.

## Current continuation limit

`LBXNativeControlStore` and `LBXNativeBrokerAuthority` now have host
implementations and tests. They are not connected to installed switching, do
not hook Keychain/preferences brokers, and do not make the customer app ready.
Do not infer phone isolation from these fixtures.

The existing heartbeat is active every 30 minutes for the current chat. It
resumes the durable checkpoint after interruption, preserves completed recovery,
and must not treat host fixtures as an installed switch. Independent
validation of earlier gates remains complete; unchanged phone state does not
justify repeated device tests.

Exact recovered entry points and the proposed integration are documented in
[NATIVE_MANAGER_INTEGRATION.md](NATIVE_MANAGER_INTEGRATION.md) and
[NATIVE_BROKER_BOUNDARY.md](NATIVE_BROKER_BOUNDARY.md).

This repository's active app is Objective-C/Logos with a recovered native
backend. A new `AppDelegate.swift` or `ViewController.swift` would not connect
these components to that backend. The installed UI and proxy input code are
unchanged by this isolation checkpoint.
