# Per-app launch and gate integration — FBLIFE-003

Facebook remains inactive. This unit connects the already tested app process coordinator to the daemon launch/cancellation/startup/maintenance callers and makes clone-local gate publication select the exact app owner. It does not enable Facebook's unaudited defaults/wire policy or claim live Facebook/MDM acceptance.

The daemon retains one coordinator for its active process identity and termination observer. Every runnable family is stopped and drained before rotation; socket checks, selected-app launch and PID-bound readiness use that coordinator. The system firewall helper still uses its separate exact registered launch method. Command cancellation and maintenance use all-app stop attempts. The gate's emergency path attempts to stop each exact runnable family without waiting while holding its own lock; that attempt is not proof of quiescence.

Launch validation, managed-app validation, profile synchronization, login-status lookup and source archival select the profile/request app descriptor. A profile re-read after proxy rotation must still identify the same app, container and bundle before ARM. A clone-local CLOSED mirror can use the previous exact bundle even if no full profile remains. Full profile sync and readiness reject a conflicting app owner. Source/system/loose-prefix bundles cannot become clone-control targets. The original Reddit bundle/group derivation and device-wide lease format are unchanged.

The actual readiness waiter also rejected a newly reproduced defect: it previously accepted a receipt with a future timestamp. It now uses the existing typed timestamp policy and requires the current lease to remain ARMED for the same container, bundle, generation and boot epoch. Replacing or closing the lease cannot make an earlier receipt satisfy this stage. The final OPEN gate remains independently responsible for authorization.

## Executable evidence

- `tools/test_app_launch_flow.py`: actual `handleLaunchContainer` with the actual coordinator and inert process/device/network providers. 492 assertions cover both future registered app flows, both families drained before rotation, every failure stage, no successful OPEN on failure, current operation-context propagation and post-rotation ownership changes. No real app is launched or signalled.
- `tools/test_app_gate_control.py`: actual publication and sync functions. 34 assertions with the production registry and 34 in a temporary copied registry with Facebook runnable. Both apps retain app-bound writes; cancellation permits CLOSED only; foreign identities, stale binding and write failures fail. The emergency stop targets only the applicable runnable registry. The production registry is unchanged.
- `tools/test_app_gate_readiness.py`: actual waiter with real temporary Info.plist/receipt files and synthetic PID lookup. 71 assertions cover both app owners, every required hook/behavior group, cancellation, foreign/stale/future receipts and lease replacement. Synthetic successful hook receipts do not prove actual hook installation.
- Existing actual request deadline/cancellation fixtures and ordinary/ThreadSanitizer coordinator fixtures remain required. Complete build/package validation is recorded with the unit's package evidence.

Remaining lifecycle work includes all-app installation recovery dispatch, app-bound replacement and restored app-state semantics. Actual Facebook caller compatibility, early hook ordering, request metadata/transport enforcement and paired clone/MDM acceptance are still required before activation.
