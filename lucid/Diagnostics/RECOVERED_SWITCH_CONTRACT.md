# Recovered original-app switch contract

Status: **static protocol recovered; completed-switch authority unavailable**.
This is the prerequisite investigation for an in-target isolation sentinel on
the supplied SocialBox **3.1.0-1** backend. It does not activate an observer, call a
switch, run the recovered programs, change the phone, or change network gates.
The existing launcher context adapter remains `OBSERVED_CACHED_UI` / `UNBOUND`.

The inspected success callback is a completion *notification*, not an attested
binding between a running application and a successfully committed container.
Two concrete paths prevent interpreting it as that binding: an already-selected
ID can succeed without performing the transition, and the normal path releases
its switch semaphore before queuing the success callback. Per-app operations
also do not propagate a verified process-drain/storage result to that callback.
These are static findings, not reproduced device failures or proof of a leak.

## Evidence identity and limits

Private evidence paths below are relative to
`work/private-socialbox-adoption-2026-09-20/socialbox-3.1.0-1/`.
Addresses refer to the **arm64** slice. Method encodings were checked against
`otool -arch arm64 -ov`; a decompiler prototype is not the Objective-C ABI.
No account data, session tokens, or decoded licensing material is needed here.

Pinned original binary SHA-256 values:

- `compiled/var/jb/Applications/SocialBox.app/SocialBox`:
  `e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0`.
- `compiled/var/jb/Library/MobileSubstrate/DynamicLibraries/SocialBox.dylib`:
  `7172791ab8e102e0330d156eaebba130f9b6d2a5491e0b3cbc5d07bc5965c4ca`.
- `compiled/var/jb/usr/libexec/SocialBoxHelper`:
  `a0455fd7aeb19712d7ebf147fe773788981204710cd2bfa6f5b087191d0888d2`.
- `compiled/var/jb/usr/local/bin/secretsauced`:
  `e21659cbacd5e74399cfcd0d3e370dbbb8dca395a23266577dff25c85d033a25`.

Pinned text evidence SHA-256 values:

- `decompiled/SocialBox.c`:
  `1b5cb98498c37f04cfa7283b1872d46543e822387935afa97fe0a0225e473c48`.
- `decompiled/SocialBox.unresolved.asm`:
  `2c017ada201458b5f4ff08adf5c56ad805c34f7a300987817120c8521528f1ff`.
- `decompiled/SocialBox.dylib.c`:
  `cdebcfa27fdf76389a93646d5053f7711ddcad01540c1a7e85465666f25feaae`.
- `decompiled/SocialBoxHelper.c`:
  `aa75f7c1247181ad9189648b9fe02d9adb89379097a0cc355ff05ed429468009`.
- `decompiled/secretsauced.c`:
  `2a51699ebb6762a00338fef7ab326842423e40755dc1c86b0261aa21b6ffcc92`.

The global worker `0x100236804` was the unresolved entry at
`decompiled/SocialBox.functions.tsv:4012`. The archive retains 12,346 decoded
instructions at `decompiled/SocialBox.unresolved.asm:6`, through `0x1002428e8`.
`disassembly/SocialBox.arm64.asm` additionally retains the exception-cleanup
region `0x1002428ec`–`0x1002429ac`.

On 2026-09-21 a fresh, read-only export using verified official Ghidra 12.1.3
and Temurin 21 **successfully recovered this worker's pseudocode**, without
executing the original app. The separately copied project used normal
decompilation with C output and a syntax tree; the archive's earlier normalized
export had not produced it. New evidence is in the extraction parent's
`local-tools/license-recovery/output/SocialBox-100236804.c`, SHA-256
`bfe4486d98b4a53c81b80487990c2ffabb9f4d723c30e7d78a23499d3a136956`.
This supplement leaves the original archive and its line anchors unchanged.
Below, `recovered-worker.c` abbreviates this exact new output. Its successful
decompilation improves visibility; it does not make inferred variable types or
exception paths authoritative source code. Branch-critical findings were
cross-checked with the retained instructions and adjacent callbacks.

## SW-01 — Actual request and completion shape

`_Xr4s::switchToGlobalContainer:progress:completion:` at `0x1002366ec`
(`decompiled/SocialBox.c:189807`) has encoding
`v40@0:8q16@?24@?32`: a numeric target and two blocks, returning void. It submits
worker `0x100236804` to a global dispatch queue. The worker capture contains the
manager at `+0x20`, completion at `+0x28`, progress at `+0x30`, and target ID at
`+0x38`. The decompilation's extra scalar parameters are not a usable ABI.

The recovered callbacks establish the practical completion shape:

- `0x1002429b0`: failure with an already-switching message.
- `0x100242abc` (`SocialBox.c:399373`): completion `(true, nil)`.
- `0x100242ad0` (`:399386`): failure with a missing-container message.
- `0x100242b34` (`:399406`): failure with a no-assigned-apps message.
- `0x100242bd0` (`:399472`): emits a Darwin notification, then an in-process
  notification containing **exactly** `containerID` and `containerName`, then
  completion `(true, nil)` (`:399625`–`:399639`).

There is no path, app bundle, process identity, generation, switch nonce, boot
epoch, canary manifest, or network result in these success payloads. A Darwin
notification is a signal without a per-switch payload; the in-process
notification contains a captured ID/name, not an authenticated target-process
observation. A consumer must not reinterpret either as a sentinel proof.

## SW-02 — Same-ID success does not revalidate the transition

The worker acquires the global semaphore through
`dispatch_semaphore_wait` at `0x100236878`. It reads global metadata at
`0x10023693c`, gets `activeContainer`, and compares it with the requested ID at
`0x1002369b4`–`0x1002369c0` (`SocialBox.unresolved.asm:84`–`:137`).

When they match, it signals the semaphore at `0x1002369cc` and asynchronously
queues `0x100242abc` at `0x100236a10`, which calls `(true, nil)`. This path
bypasses the later process-kill, per-app update, and normal cleanup sequence.
Therefore a repeated successful request cannot be used as a read-only
"verify current container" operation. It would also invoke a mutating API.

## SW-03 — The completion can already be stale when delivered

On the normal final path (`SocialBox.unresolved.asm:11979`–`:12053`):

1. `0x100242340` calls `flushCacheDaemons`.
2. `0x100242374` posts a notification; `0x100242378`–`0x100242388` performs
   a randomized 80,000–119,999 microsecond sleep. A delay is not a receiver ACK.
3. `0x10024238c`–`0x100242398` brackets clearing a process-global byte with
   memory barriers. This is not a durable, generation-bearing transaction.
4. `0x1002423b0` posts another notification, and progress is set to `1.0`.
5. **`0x1002423d4` signals the global switch semaphore.**
6. **Only at `0x100242440` is `0x100242bd0` queued on the main queue**, with
   the captured target ID/object and original completion block.

A subsequent switch can acquire the semaphore before that queued completion
runs. This is a concrete ordering window; no claim is made that it has been
triggered on the phone. Waiting for this callback and then reading the cached
ID twice does not close the window or distinguish an A→B→A cycle.
`recovered-worker.c:8232`–`:8240` independently exposes this same order.

## SW-04 — Process and storage results are not carried to completion

The worker submits helper `killApp:reply:` at `0x100237160` with callback
`0x100242b4c`. That callback only calls `dispatch_group_leave`
(`SocialBox.c:399420`); it does not inspect a kill success/error result. The
worker waits five seconds at `0x1002371d4`, then immediately overwrites `x0`
and continues, without checking the wait result
(`SocialBox.unresolved.asm:627`–`:636`). This is insufficient evidence that
all prior target processes have exited. The fresh output confirms this at
`recovered-worker.c:629`–`:644`.

The next helper `0x100313904` (`SocialBox.c:218392`,
`recovered-worker.c:657`) is **not** a process-exit recheck: it edits a CoreDuet
database. Therefore the switch API must not be invoked as a harmless diagnostic
refresh. The later `rewriteLsdIdentifiersForBundles:targetCid:reply:` call
(`recovered-worker.c:660`) uses the no-op callback `0x100242b54`; it supplies no
verified receipt either.

Per-app switching is delegated at `0x100237bb8` to
`_performPerAppSwitchForBundleID:fromContainer:toContainer:processedGroupIDs:skipKill:skipCacheFlush:skipKeychain:skipChown:`
at `0x100232630` (`SocialBox.c:187526`). Its verified ABI is
`v64@0:8@16q24q32@40B48B52B56B60`: **void**, not a success receipt. The call
passes the already-handled kill/cache-flush flags as true. The worker does not
test a return result (`SocialBox.unresolved.asm:1258`–`:1269`).

Within that per-app method:

- Helper waits at `SocialBox.c:187716`, `:187812`, `:187829`, and `:188005`
  do not propagate their timeout result.
- `activeContainer` is assigned at `:188016`; the first `writeToFile` result
  at `:188017` is ignored.
- A later `.tmp`/rename/fallback-write sequence at `:188121`–`:188145` can
  fall through without a success result reaching the caller. The subsequent
  symlink operation at `:188249` also has no propagated result.

After iterating the per-app calls, the global worker invokes
`mutateGlobalMetadataLocked:` at `0x100237c48`. Its block `0x100242b60`
sets `activeContainer` (`SocialBox.c:399452`–`:399467`). The worker next reads
that metadata and calls `syncAllPerAppMetadataFromGlobal:` at `0x100237c68`.
The existence of this metadata lock does not repair unobserved helper failures
or turn the later callback into a verified per-app commit. Fresh pseudocode
shows the per-app loop and metadata transition together at
`recovered-worker.c:899`–`:934`; its ownership-helper wait at `:897`–`:898`
also does not propagate a timeout/failure result.

## SW-05 — Helper and cloud-daemon IPC do not supply the missing receipt

The tempting helper selector
`_Zw5h::switchToContainer:forBundleID:reply:` at `0x100055c34`
(`SocialBoxHelper.c:53574`) is a stub: it returns failure with NSError code
**501**, with the `cf_Notimplemented_Phase2_` description constant
(`:53688`–`:53692`). Do not
implement the observer by calling this selector.

The helper inventory includes operations for kill, filesystem copies/swaps,
keychain movement, sandbox-extension issuance, tree bootstrap/teardown and
identifier rewriting (`SocialBoxHelper.functions.tsv:105`–`:174`). Those are
separate operations, mostly mutating; their presence is not a unified
completed-switch query. `resolveRealSandboxForBundleID:reply:` answers a
bundle's real sandbox, not which completed logical context owns a process.

The inspected `secretsauced` Objective-C IPC entries include
`currentWSStateWithReply:` (`0x100089630`, `secretsauced.c:19448`) and
`pingWithReply:` (`0x1000896dc`, `:19484`). These report transport/liveness,
not a switch generation or process-bound storage commit. No qualifying
completed-switch receipt was established in these inspected paths. This is a
bounded negative finding, not proof that every unnamed branch in every binary
has been exhaustively ruled out.

## SW-06 — A local translation barrier is not global completion

Inside an injected target, `_Xk2n::_sD1:` at `0x00250f4c`
(`SocialBox.dylib.c:46805`) returns BOOL (`B24@0:8q16`). It uses an existing
translation queue and `dispatch_barrier_sync` at `:47016`, invoking block
`0x00251b78`. That block:

- sets `activeContainerID` first (`:366842`);
- sets `activeContainerPath` later (`:366915`);
- frees and replaces an owned path buffer (`:366916`–`:366927`);
- clears the mutable app-group path map (`:366929`).

This explains why unsynchronized getter reads are unsafe as a coherent
binding. Borrowed C path pointers must not be retained or dereferenced across
the replacement. The factory `+sharedManager` may create state and is not a
read-only discovery API.

The caller continues *after* the barrier with `saveMetadata` (`:47017`),
model-file bootstrapping (`:47141`), and keychain operations
`SecItemDelete`/`SecItemAdd` (`:47243`–`:47244`). Calling `_sD1:` to obtain its
BOOL would itself switch and write state; it is not an observer. Even a
properly synchronized snapshot of the local queue would only establish a
local translation snapshot. It would not attest helper process termination,
global metadata durability, keychain state, or tunnel enforcement.

Relevant direct getter ABI, checked in the original arm64 metadata:

- `activeContainerID`, `0x00257668`: `q16@0:8`.
- `activeContainerPath`, `0x002576c0`: `@16@0:8`.
- `isInitialized`, `0x002576e4`: `B16@0:8`.
- `translationQueue`, `0x00257730`: `@16@0:8`.

No tested queue-entry/deadlock contract, already-existing singleton acquisition
API, or monotonic local generation has been recovered for a read-only adapter.

## Required binding inputs before a sentinel can label its results

A safe adapter cannot currently be implemented solely from the inspected
getters and callbacks. The following is an acceptance contract for a future
source-owned transaction/observation bridge, **not a claim that the original
backend already produces these fields**:

1. **Verified producer and scope:** pinned backend ABI/image, already-existing
   manager, exact supported app bundle and process identity including process
   birth/boot identity. A PID or mutable selected-ID file alone is insufficient.
2. **Transaction fence:** a monotonic generation/nonce held across every writer
   of this app's active binding, including global switch, default/deactivation,
   import/restore and any direct per-app switch. No new writer may bypass it.
3. **Completed result:** requested and committed context match; process drain,
   per-app storage/path change and metadata persistence have explicit successful
   acknowledgements. Timeout/failure yields unavailable, not completion.
4. **Coherent target snapshot:** immutable copied bundle, context, canonical
   storage identity and generation read under a verified synchronization
   contract. Source-owned code must not read freed C buffers or assume a
   matching pathname proves which backing storage the target sees.
5. **Witnessed canary manifest:** exact known sibling markers bound to that
   backend/app/context generation, with an owner witness that the marker
   exists. The separate-clone backend's manifest and entitlements cannot be
   reused for original-app data switching. Do not read arbitrary account data.
6. **Result lifetime:** verify the same process/generation before and after
   each probe; invalidate on switch, interruption, process death, restore,
   background/foreground uncertainty or backend change. ABA and late callbacks
   must not revive an expired result. Probe PASS describes only the witnessed
   surface and execution; it is never a network-isolation or 100% isolation claim.

The current safe output is `bindingStatus: UNAVAILABLE` and
`probeStatus: NOT_RUN`, with the reason `NO_COMPLETED_SWITCH_RECEIPT`.
An observed ID may still appear separately as cached management metadata.
Network admission and the existing app-only presentation filter stay unchanged.

## Smallest next implementation and device evidence

Do not port the clone sentinel by renaming its bundle filter. First create a
source-owned switch transaction boundary that can interpose on **all** relevant
writers and collect explicit operation acknowledgements, or obtain the owner's
original source for that boundary. An outer wrapper around the current BOOL
completion cannot reconstruct results that the worker discarded. A read-only
observer may honestly report local observations, but cannot manufacture global
completion authority.

Before enabling a target observer, its producer/consumer needs host tests for
same-ID fast success, late completion after a later switch, ABA, kill timeout,
per-app write failure, missing canary witness, mismatched process birth, queue
re-entry, and interrupted/default/restore paths. Device acceptance must then
measure two contexts with owner-created markers, a rapid A→B→A sequence, killed
or interrupted switching, and relaunch/default recovery. All such device
acceptance is **NOT_RUN in this investigation**. Network enforcement requires
separate measured evidence; none of the switch notifications establish it.
