# Switching interposition: concrete boundary

Update, 22 September: the private `.4` candidate connects a checked root Mach
service to the helper and a **specific per-app** stop callsite. The latter now
uses the original worker's verified pre-write timeout cleanup when drain fails;
see [the implemented boundary](../HelperSafety/PER_APP_STOP.md). The global,
batch, deactivation, metadata and target-engine hazards below remain open. The
historical investigation below explains why generic callback suppression is
unsafe; the new per-app adapter is deliberately limited to the one proved
branch, with separate binary/runtime checks for both architectures.

2026-09-21. **No runtime guard installed.** This follow-up investigated whether
a small, source-owned interposition can make the preserved 3.1.0-1 backend
acknowledge failed process stops and avoid false switch success. It cannot do
so safely by wrapping the currently inspected callbacks. No original executable
was run and no phone, storage, hooks, entitlements, licensing or Makefile changed.

This document adds the missing helper semantics and call-site inventory to
`../Diagnostics/RECOVERED_SWITCH_CONTRACT.md`; it does not repeat a broad
isolation audit. `STATIC_ENTRYPOINTS.json` was generated from the pinned arm64
binary's Objective-C method metadata and retained disassembly: **23 registered
manager methods and 131 direct branch references** to their implementations or
selector stubs. Every method has its exact ABI; every reference has an address,
disassembly line and containing index entry. Selector calls still require
receiver validation. Dynamically constructed selectors and other binaries are
explicitly outside that mechanical reference count.

## The helper acknowledgement is not the required acknowledgement

Private references here use the original extraction root documented in the
switch contract. `_Zw5h::killApp:reply:` at `0x100050668` has exact method
encoding `v32@0:8@16@?24`. Its worker `0x1000507bc`
(`decompiled/SocialBoxHelper.c:50225`) resolves a bundle to an executable **name**,
using a cache or an Info.plist scan. If resolution or the first kill fails, it
tries the capitalized and unmodified last component of the bundle identifier.
It invokes `killall -9 <name>` through `0x100050df4` and replies with **one
BOOL argument**, not `(BOOL, NSError *)`. An interposer must not invent a second
reply argument. The reply at `SocialBoxHelper.c:50423` contains no PID, process
start identity, executable path, extension inventory, or post-kill observation.

`0x100050df4` has a further concrete defect. In
`disassembly/SocialBoxHelper.arm64.asm:78750`–`:78758`:

1. `0x100050e6c` initializes the wait status to zero.
2. `0x100050e7c` calls `waitpid(child, &status, 0)`.
3. `0x100050e80` immediately loads the status, ignoring the waitpid return.
4. `0x100050e88`–`0x100050e8c` returns true when its status mask is zero.

Thus an interrupted/failed wait can be reported as success if it leaves the
initial zero status. This is verified instruction behavior, not a device
reproduction. Even after that defect is fixed, a successful name-based killall
exit does not prove that the exact app and all its extensions are gone. A
nonzero killall exit also fails to distinguish an already-stopped app from an
actual kill failure. A wrapper must not classify either case as a verified
process-drain result without an independent observation.

## Entry points a guard must account for

The registered `_Xr4s` switch entry points are:

- `switchApp:toContainer:progress:completion:`, `0x1002296ec`,
  `v48@0:8@16q24@?32@?40`; async worker `0x100229834`.
- `deactivateApp:progress:completion:`, `0x10022af90`,
  `v40@0:8@16@?24@?32`; async worker `0x10022b0d0`.
- `switchToGlobalContainer:progress:completion:`, `0x1002366ec`,
  `v40@0:8q16@?24@?32`; async worker `0x100236804`.
- `deactivateGlobalContainerWithProgress:completion:`, `0x10024307c`,
  `v32@0:8@?16@?24`; async worker `0x100243188`.
- `_performPerAppSwitchForBundleID:fromContainer:toContainer:processedGroupIDs:skipKill:skipCacheFlush:skipKeychain:skipChown:`,
  `0x100232630`, `v64@0:8@16q24q32@40B48B52B56B60`.
- `performPerAppSwitchForBundleID:fromContainer:toContainer:`, `0x100233acc`,
  `v40@0:8@16q24q32`.
- `performBatchPerAppSwitchForBundleIDs:fromContainer:toContainer:`,
  `0x100233b60`, `v40@0:8@16q24q32`.
- `swapGroupContainersForApps:fromContainer:toContainer:`, `0x100233ac8`,
  `v40@0:8@16q24q32`: this distinct four-byte forwarding thunk must not be
  mistaken for the adjacent per-app method. It branches to selector stub
  `0x100346880` for `_swapSharedGroupContainersForApps:fromContainer:toContainer:`;
  that method is at `0x1002366e8` with the same ABI and is a no-op in this base.

Other write boundaries cannot be ignored: `writeMetadata:forBundleID:`
(`0x100228ce0`, `B32@0:8@16@24`), `writeGlobalMetadata:` (`0x10023023c`,
`B24@0:8@16`), `mutateGlobalMetadataLocked:` (`0x10023037c`, `B24@0:8@?16`),
and both `syncPerAppMetadataForBundleID:fromGlobal:` and
`syncAllPerAppMetadataFromGlobal:` (void). Their BOOL results, where present,
are not automatically consumed by existing callers.

The mechanical call inventory finds concrete alternative callers:

- Global switching through worker `0x100111610`, with a preceding direct global
  metadata write at `0x100112ae4`, then switch submission at `0x100112bec`.
- Default/deactivation through `_Xc9m::performDeactivate`, call `0x1001159b0`.
- Home creation and batch-creation workers `0x10006037c` and `0x100062038`
  call the **batch per-app** method at `0x100061028` / `0x1000631e8`, then
  write and synchronize global metadata. They do not enter the global switch
  method intercepted by a simple switch-button guard.
- App membership editing, deletion, import worker `0x1001246f0`, automation,
  proxy association and even `_Xc9m::loadData` can directly write or mutate
  metadata. Some writes only edit labels/proxy configuration; a safe guard
  must inspect the operation rather than globally block every metadata write.
- The separate CLI has a real direct writer: `container reap-orphans`,
  `FUN_1001b35ec` (`decompiled/SocialBoxCLI.c:281827`), which invokes metadata
  mutator `0x1001b40b8` (`:282115`) to clear an orphan `activeContainer`.
  The application-only presentation dylib cannot fence another process.
- In-target `_Xk2n::_sD1:` / `_sD2` are additional local translation writers,
  already documented in the switch contract. An app-only mutex cannot
  serialize them with a global metadata transition.

These are known bypass paths, not a claim that the original app executes all
of them during one switch. No-observed-direct-caller is not proof that a
registered method is unreachable through Objective-C dispatch or automation.

## Why the tempting small guards are unsafe

**Intercept `helperProxy` and withhold a failed reply:** the global worker waits
five seconds and ignores the timeout before continuing to mutate. The global
deactivation worker does the same (`SocialBox.c:399870`–`:399878`). A delayed
or suppressed callback therefore does not abort either operation.

**Turn a false reply into a callback error:** the original helper callback has
only one BOOL. The per-app worker captures that BOOL in `0x10022aa08`
(`SocialBox.c:397112`–`:397116`) but its controlling branch checks the
semaphore wait result, not that value (`:396671`–`:396674`). The global reply
only leaves a dispatch group. An NSError cannot be retrofitted into these ABIs.

**Throw an exception from the callback:** the callback runs independently of the
worker; throwing there does not unwind the switching transaction. Throwing
synchronously from a forwarded message has no proved rollback/unlock contract
and can leave the original semaphore or partial writes behind.

**Pre-kill in an outer wrapper, then call the original:** this adds duplicate
name-based kills and leaves a race before the original worker acquires its
semaphore. It cannot prevent relaunch, alternative writers, or a later helper
failure. Holding the original semaphore while invoking the original worker
instead makes the worker wait for the lock held by its caller.

**Override only final success:** this can cosmetically replace a callback after
data and notifications have already changed. It cannot undo failed process
drain or partial storage switching and must not advertise a completed safe
transaction. Holding an app-local admission lock until that callback only
serializes cooperating wrappers; it does not fence the bypasses above.

## The next necessary production unit

The smallest useful backend change starts **below the current reply**, at a
source-owned privileged drain operation replacing or supplementing
`_Zw5h::killApp:reply:` and `0x100050df4`. It needs exact registered app and
extension executable paths, protected-process exclusions, PID plus birth
identity, explicit enumeration errors, and a bounded verified exit result.
Already-stopped must be a successful observed absence; inaccessible/unknown
must fail. An EINTR-safe child wait is required if any subprocess remains, but
name-based killall is not an adequate identity boundary.

That receipt must then be consumed **before writes** by source-owned versions
of the four async workers and the synchronous batch/per-app path. The workers
must check every required helper/persistence result and publish completion
before releasing a transaction fence, with safe failure recovery. The BOOL
write methods offer useful result sources, but direct plist/symlink writes in
the per-app implementations still need explicit outcomes. The existing worker
cannot be reused wholesale while claiming that it consumes results it discards.

This is a bounded implementation boundary, not a request to bypass licensing
or replace the full product. It requires a privileged source component and a
transaction owner; the currently approved app-only filter and preserved helper
bytes do not provide either. Merely adding `Switching/*.m` to the app's build
would leave the core requirement unmet, so no unattached state-machine or
pretend passing guard was added.

The new operation's first regression cases must be: already absent; exact app
and extensions exit; same-name unrelated app preserved; PID reuse; enumeration
denied; timeout; waitpid EINTR/error; helper death; duplicate/late receipt; write
failure after drain; and alternate writer invalidation. These are requirements
for the source-owned implementation, **not tests claimed PASS here**. Current
validation is binary ABI/disassembly cross-check plus a complete direct-reference
scan within the stated scope. Device execution remains **NOT_RUN**.
