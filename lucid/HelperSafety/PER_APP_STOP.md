# Per-app stop failure propagation

The `.4` private candidate adds `LBXAppSwitchSafety.dylib` to the exact manager
filter. It does not apply to target apps, global switching, batch creation,
deactivation, the CLI or other metadata writers. This is part of **ADOPT-003**;
the overall isolation/transaction row remains a gap.

The recovered per-app worker captures the `killApp:reply:` BOOL, but branches
only on `dispatch_semaphore_wait`. Calling its reply with `NO` therefore allows
writes. Unlike the global worker, it has an existing timeout branch that clears
its busy byte, releases its shared semaphore, schedules completion with `NO`,
and skips the success path before active metadata/storage work. GPS draft edits
and the cfprefsd readiness helper occur earlier; this guard does not undo them.

The source adapter intercepts only the `helperProxy` getter reached from that
specific stop callsite. It returns a narrow object supporting the one stop
method. It never obtains the old proxy or trusts an old helper BOOL: the new
object requests a receipt directly from the checked Mach service. A validated
success signals the original worker. Failure does not signal it; its existing
five-second timeout performs the known cleanup. The source client's 3.5-second
absolute deadline rejects late/duplicate responses. The two different deadlines
are intentional. Unrelated getter calls and exact-class mismatches retain the
original proxy object and behavior.

The adapter pins the original executable SHA/size/path/ownership, exact method
ABI/implementation offsets, and in-memory worker, selector-stub and failure
completion hashes. The two slices have separate addresses. The checked return
PC is `0x100229c44` on arm64 and `0x10022f4c8` on arm64e; PAC is stripped for
comparison on arm64e. It reads return addresses, never patches instructions,
blocks, the stack, or any licensing code. An unsupported host does not install
the guard and is not claimed protected. No exception or process crash is used
to escape the original worker.

The service admits only the exact root-owned, non-writable helper or manager
paths after kernel audit-token/PID-version validation. Only the exact manager
may call as mobile; other UIDs/paths remain rejected. Packaging tightens the
manager mode from 06775 to 06755, retaining its original setuid/setgid bits and
all program/signature bytes. This is a new explicit packaging delta.

## Validation

`bash tools/test_helper_safety.sh` runs the actual Objective-C replacement with
an assembly callsite and synthetic manager. It reproduces the false-stop bug,
then verifies unchanged metadata and reusable lock on failure, correct selection
on success, exact receiver/callsite scope and unchanged unrelated lookups across
40 repetitions. It has 175 checks. The existing client tests independently cover
transport failure, timeout and late/duplicate responses. Service authentication
now has 30 checks, including rejected writable manager and unrelated root.

`python3 tools/verify_recovered_switch_site.py /private/path/to/SocialBox`
mechanically resolves manager methods in both original slices, decodes the
getter call and wait/abort branch destinations, and verifies failure completion
receives false. It never executes the original programs.

The 175-check synthetic executable also passed on the connected iPhone X,
iOS 16.7.16, from the root-owned jailbreak acceptance directory. The first
mobile-directory launch was killed before producing test output; it is not a
PASS. The production `.4` service booted, refused an unrelated root caller, then
was stopped and unregistered. The original manager worker has **not** executed
this guard in an installed package. Arm64e was built and statically verified;
this A11 phone cannot execute that slice.

This does not turn a momentary absence observation into a launch fence, make
later writes transactional, validate the same-ID fast-success path, close a
network gate, or fix unchecked global/batch/deactivation workers. Those paths
must not be adapted by merely suppressing their callbacks: they ignore timeout.
See `../Switching/INTERPOSITION_BOUNDARY.md` for the remaining writer boundary.
