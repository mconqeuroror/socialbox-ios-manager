# Process identity before termination

21 September 2026. Leak surface: APP-002. This unit changes the source-owned
SocialBox daemon, not the preserved SocialBox helper. No phone was connected and
no package was installed or published. The recovered `.2` candidate is unchanged.

The registered-app classifier previously returned numeric PIDs which were later
passed directly to `kill(pid, SIGKILL)`. A process could exit and its PID could be
reused between those operations. Exact app-name/path classification at the first
snapshot did not eliminate that race.

`RBXProcessIdentity` captures executable path between two equal kernel birth
observations. The controller captures the entire selected batch, refreshes exact
registered membership, and only then requests termination. The primitive checks
birth/path, obtains a Mach task right, checks the task PID and birth/path again,
then uses `task_terminate` on the held right. PID reuse after the final check does
not retarget that right to the replacement process. Gone/changed/denied results
are distinct. Failed observation, authorization or task acquisition never falls
back to a process name or numeric kill. EINTR retries are bounded to four calls.

A successful termination request is deliberately **not** a stopped receipt.
The existing `killAllAndWait` still requires process absence, its clean interval,
socket verification and durable binding revocation. Its outer deadline bounds
retries; this code does not add a launch fence or a network enforcement mechanism.
The stable task represents process identity, not a frozen executable image; an
exec transition or later relaunch still needs the existing lifecycle authority.

## Verification

- PASS: actual primitive, 221 mocked-kernel/task checks; no real processes
  signalled. Includes reuse during capture/acquisition, reuse after final check,
  permission denial, unexpected/invalid/self ports, rights cleanup, changed
  executable, malformed responses and bounded EINTR. The unbounded EINTR case
  failed first and was corrected.
- PASS: actual app controller fixture. The added capture/reauthorization test
  failed against the old numeric-kill implementation. Corrected tests retain
  Reddit/Facebook source/main/extension selection and reject lost membership,
  denied refresh/capture, and late PID reuse without fallback.
- PASS: native app coordinator, 518 actual main launch-flow assertions,
  replacement architecture and three package-variant tests; static checks.
- PASS: daemon and keychain-cleaner arm64/arm64e Theos build, existing pinned
  public key and Procursus ldid, no Apple Development Team. The first standalone
  subproject invocation omitted the root Makefile's existing compatibility
  warning flags; the corrected invocation uses those same flags. No warning
  policy was changed in source.

## Device acceptance still required

Task-port access depends on jailbreak/kernel/signing policy. Existing entitlements
have not been broadened; a successful host mock/build cannot prove that access.
Before deploying, verify the exact signed daemon can acquire and terminate a
disposable owned app and its extension, preserves an unrelated same-name app,
and observes their actual exit. Also exercise denied access, rapid relaunch and
switch cancellation. If access is denied, the current implementation remains
closed and may prevent switching; do not deploy it as a working compatibility
fix until this is resolved and retested. No kernel, sandbox or entitlement
changes are implied by this unit.

The preserved SocialBox callers still discard stop outcomes. Putting this
primitive in that helper without replacing those callers could let a denied
stop precede data writes. That integration is deliberately not performed here;
ADOPT-003 remains a gap. Complete acknowledged transaction workers and their
write/recovery boundaries before linking a recovered helper replacement.

## Follow-up: active process birth and launch admission

A second failing-first regression found that the existing observer accepted an
unchanged executable/PID with a different kernel birth under the old lease. The
coordinator also compared only six identity fields and discarded birth fields.

The actual controller now captures birth after launch and before publishing
active authority. Failed/changed capture or cancellation fences the operation,
revokes the provisional launch binding and returns failure. The coordinator
requires integral, valid seconds/microseconds and preserves both in its eight
identity fields. Delayed callbacks must match those fields too. Each observer
sample checks birth before accepting its open/armed lease. Unknown or changed
birth uses the existing synchronous close callback before binding revocation
and termination. Executable aliases use the same canonical-path comparison as
registered launch validation; an added alias fixture failed first and now passes.

Additional PASS results:

- Actual controller observer: unchanged birth accepted; same PID/path with new
  birth rejected; denied birth and incomplete identity rejected; close callback
  precedes revocation; canonical path aliases do not cause a false alert.
- Actual controller launch body: observed birth published on success; denied
  capture, changed capture and cancellation publish no authority, retain a
  recovery fence and revoke the provisional binding. Only external I/O seams
  are mocked; fixture files remain in a unique temporary directory.
- Actual coordinator: all eight callback fields enforced; missing, nonnumeric,
  fractional, negative, out-of-range and NaN birth values rejected. Existing
  concurrency tests pass under Thread Sanitizer, with no reported data race.
- The 518 main launch-flow assertions, replacement contracts and static checks
  pass with the complete receipt. Both iOS daemon architectures build again.

This observer samples on its existing 100 ms timer. It is detection and
revocation, **not proof of zero network traffic between a process replacement
and its next sample**. Independent network enforcement, actual syscall behavior
and on-device timing remain separate acceptance requirements. No new network
authority, runtime spoofing hook, entitlement or recovered-backend port is
claimed by this follow-up.
