# Multi-app process coordinator

Host implementation and regression evidence are ready for review. This unit has
not wired `daemon/main.m`, the build, or a device package, and does not activate
Facebook. Caller integration and device acceptance remain separate work.

## Global stop and descriptor routing

`RBXAppProcessCoordinator` constructs one controller per canonical runnable
app descriptor. Profiles without `appType` still resolve to Reddit. Unknown,
inactive or mismatched profile identities fail before launch dispatch. The
original per-app classifier and Reddit compatibility entry points keep their
scope; infrastructure exclusions remain in that classifier.

Stop cancels all old observation producers and requests every app's termination
before waiting for any app. Each drain receives only the remaining portion of
one monotonic budget. Failure in either app, late success, a regressing/nonfinite
clock or an exhausted owner cannot produce global success. An expired owner
still gets all initial stop requests. An already cancelled owner retains the
original controller's explicit bounded cleanup allowance.

The caller still owns the one global network lease: close traffic before stop,
then arm the selected profile before launch. Launch requires a completed global
drain and registered termination observation, rechecks all app families, and
uses the selected controller's existing ARMED lease and exact registered-clone
validation. No kill or binding revocation occurs during this final preflight.

## Overlapping cancellation and launch

The daemon can call emergency stop on `sDeadlineQueue` while ordinary launch
runs on `sSwitchQueue`. A first serial prototype failed deterministic overlap
regressions: stop returned success while launch was blocked, and the late launch
subsequently returned success with an active identity. A second failing fixture
showed a successful stop while an old observation producer was still executing.
Both failures were observed before the concurrency fix; neither result was
accepted as daemon concurrency evidence.

The coordinator now uses a short state lock for ownership epochs, immutable
snapshots and in-flight launch/stop counts. It holds no such lock during process
inspection, kernel waits, launch I/O, binding writes or consumer callbacks. Timer
registration and cancellation only take the controller's short state lock and
never wait for a handler.

Each admitted launch advances the ownership epoch. A deterministic read-only
inspection fixture first reproduced a stale stopped result after a concurrent
launch had completed; advancing the launch epoch rejects that old observation.

An emergency stop invalidates the epoch immediately. It requests all stops
outside the lock and cannot report global drain while an earlier launch, another
stop or an old observation handler can still perform effects. A late launch
rechecks its epoch; if superseded, it requests cleanup for every app and remains
counted until that cleanup returns. It publishes no active identity. A successful
launch publishes identity, installs its observer and ends its reservation at one
locked commit point. A later stop is ordered after that commit.

A stop that reports unresolved overlap stays a failure even if the earlier work
finishes afterward. A new explicit drain is required. Concurrent read-only
profile inspection also refuses to prove stopped state during an in-flight or
superseding transition.

## Actual controller observation lifecycle

The existing controller exposes an active identity snapshot, an absolute
monotonic socket-verification deadline, observer cancellation, and an executing
observer count. Identity and timer/token state are protected by short locks.
The classifier, process-kill selection and registered launch validation remain
in their existing paths.

Cancelling a dispatch source does not join an executing handler. An observer
also performs global binding revocation itself, after notifying its consumer;
ignoring only the callback cannot suppress those later producer effects.

The actual timer handler now captures a token and identity under its state lock
and stays counted through process inspection, consumer notification, global
binding revocation and its kill request. Token/identity checks discard invalidated
samples before notification and again before revocation. A stop racing after
that last check may still overlap an already-entered binding operation, but the
producer remains counted until its effects finish. Global drain and subsequent
launch admission cannot succeed during that interval. No state lock spans those
I/O or callback operations.

The coordinator compares all six active identity fields: container, bundle,
executable, PID, generation and boot epoch. A queued callback from an older
launch, including the same container/PID with a new generation, cannot revoke
the current identity. Consumer notification runs outside both state locks.

## Validation

Run:

```sh
bash tools/test_app_process_coordinator.sh
RBX_TEST_THREAD_SANITIZER=1 bash tools/test_app_process_coordinator.sh
bash tools/test_app_process.sh
```

The new suite compiles the actual coordinator and controller. Fake process I/O
covers both Reddit/Facebook switch orders, failure in either app, all-kills-before-
wait ordering, aggregate deadlines, invalid/expired/cancelled budgets, final
preflight failure, inactive/mismatched profiles, stale callbacks and PID reuse.

Deterministic semaphore barriers cover a blocked launch overtaken by emergency
stop, launch admission while stop is blocked, two overlapping stops and late
launch completion. Emergency stop must finish without waiting on the other
operation's held backend barrier; no overlapping operation may claim early drain.

Separate fixtures run the **actual production dispatch-source handler**, with
only its process/lease/binding/kill I/O substituted. They block it during process
inspection, inside the consumer callback, and after entering binding revocation.
Each proves immediate cancellation, a nonzero in-flight count until the old
effect finishes, rejected drain/admission during that interval, token rejection
before binding where possible, and successful new drain only after quiescence.
No real process is signalled, launched or watched; no real binding is written.

The ordinary suite and Thread Sanitizer run pass, with no sanitizer report.
The existing per-app regression suite passes unchanged. Production syntax
checking without the test-only fake-app initializer also passes.

These tests establish host ownership/observation mechanics. Kernel/LaunchServices
behavior, device process/socket observation and actual cross-app lifecycle remain
on-device acceptance. A monotonic deadline never gives permission to report
success after a late backend result, but it cannot preempt a kernel/service call
that has not returned; the daemon's independent operation-context fencing must
remain intact. Ambiguous helpers already queued in SpringBoard still use the
existing launch fencing rather than a fabricated stopped result.
