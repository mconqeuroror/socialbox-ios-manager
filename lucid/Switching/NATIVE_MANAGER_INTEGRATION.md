# Native Instagram manager integration

3 October 2026. **Implementation route; not connected to the installed manager.**
The root journal, executable gate, storage inventory/layout and storage fence are
source components. They do not yet make an original manager operation safe.
Current process-drain acceptance and a checked keychain transition are required
before enabling this route. Existing UI and proxy inputs remain in place.

## Earliest confirmed action

Keep the original confirmation alerts. Interpose the following **confirmed**
methods, before invoking their original implementation. These addresses and ABIs
were read from both slices of the pinned original manager, SHA-256
`e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0`.
Addresses are unslid virtual addresses, not callable constants in a new image.

| Class and selector | arm64 | arm64e | Encoding |
| --- | --- | --- | --- |
| `_Xc9m performSwitchToContainer:` | `0x100111358` | `0x1001151d0` | `v24@0:8@16` |
| `_Xc9m performDeactivate` | `0x100115914` | `0x100119bb8` | `v16@0:8` |
| `_Xc9m doDeleteContainer:` | `0x100116930` | `0x10011acb8` | `v24@0:8@16` |
| `_Xc9m saveApps:forContainer:` | `0x100116210` | `0x10011a55c` | `v32@0:8@16@24` |
| `HomeViewController performCreateContainerWithApps:` | `0x10005fedc` | `0x10005eff4` | `v24@0:8@16` |
| `HomeViewController performBatchCreateContainers:withApps:` | `0x100061f1c` | `0x1000611bc` | `v32@0:8Q16@24` |

The switch action retains the existing `_Xt2w requestSwitchContainer:completion:`
request and its authorization/profile result. Do not synthesize its success.
Its callback writes the selected record's `spoofProfile` to global metadata
**before** calling `_Xr4s switchToGlobalContainer:progress:completion:`. Therefore
a hook on that final manager method alone starts too late.

Re-resolve the current model by numeric ID and verify its current app membership
at dispatch. A name, table index or cached selected ID is insufficient.

## Smallest source change

Add a `LBXNativeSwitchCoordinator` in the existing root Mach service and a narrow
`LBXNativeManagerBridge` in the existing manager-only safety library. Reuse the
service's kernel audit-token, process-version and exact caller-file checks.
The setuid manager is not a real-UID-root journal owner. Do not change its process
credentials or give the UI direct access to root-only APIs.

Use a separate strict transaction message schema: operation, numeric CID,
expected per-app selection, request nonce, generation and deadline. Accept no
caller-supplied paths, PIDs or shell commands. Preserve the existing check/drain
protocol; its 3.5/4-second BOOL exchange is not a switch transaction.

The service owns one synchronous, serialized durable transaction. The UI waits
asynchronously and keeps the existing progress view responsive:

1. Read and pin the current native control state, exact target membership,
   registered writers and original storage/code. Persist intent before effects.
2. Close execution for every writer of affected shared groups, then verify drain.
   Close storage using the existing fence. Failure stays closed and records the
   failed stage; it does not select the target or report success.
3. Run the unchanged authorized profile request. Route its metadata update through
   a checked source writer under this generation. The old callback may continue
   to the manager entrypoint, but **do not run the old switch worker wholesale**.
4. Replace that writing boundary with source-owned selection, checked keychain
   transition and native-control persistence. Require an explicit result from
   each operation; the old worker's completion cannot reconstruct discarded
   helper/write failures. Persist the committed control identities and generation.
5. Re-read the exact committed per-app controls; open only that CID's observed
   roots with the fence's authorization callback. Revalidate before restoring
   execution. Only then forward one success to the original UI completion.

The first supported transaction should switch between **existing, inventoried
Instagram profiles** and default. Reject an unsupported mixed-app transition or
missing profile before effects. Creation, deletion and membership changes must
enter this owner too; initially refuse them for the protected scope while their
allocation/retirement transaction is unfinished. Preserve unrelated records and
ordinary label/proxy edits through conditional metadata merges.

## Control state that must join the fence

These native paths were identified independently of Instagram's data homes.
Resolve only the trusted jailbreak root alias, then use physical descriptor
walks. The current data-home inventory does **not** protect these trees:

- `/var/jb/var/mobile/Library/SocialBox/Containers/global_metadata.plist`
- `/var/jb/var/mobile/Library/SocialBox/Containers/com.burbn.instagram/metadata.plist`
- `/var/jb/var/mobile/Library/SocialBox/Containers/com.burbn.instagram/containers/<CID>`
- `/private/var/tmp/socialbox_containers/com.burbn.instagram.plist`
- `/private/var/tmp/_dh_com.burbn.instagram`, the exact reviewed symlink into the
  preceding per-app identity tree.

The runtime plist was mobile-owned and mode0666, and native code replaces it
atomically. Protect both leaf and containing namespace; locking one old inode
does not cover rename. Capture identity-tree nodes and directory membership
without exporting identity/account contents. Journal structural identities,
selection, hashes and generations, not credential or account bytes.

Per-app selection is authoritative for this transaction. The observed global
selection7 and Instagram selection0 were legitimate different values. Do not
repair one from the other or call `syncAllPerAppMetadataFromGlobal:` as validation.

App-only hooks cannot fence the CLI, helper or target-engine writers. Persistently
protect the native control files/namespaces, and route admitted updates through
the root owner. Guard the four async switch/deactivate methods, synchronous
per-app/batch methods, and metadata/synchronization writers listed in
[the existing boundary](INTERPOSITION_BOUNDARY.md). A refused BOOL does not stop
old callers that ignore it; filesystem protection and closed execution remain
necessary. Import/restore and CLI writes need the same contract before admission.

## Concrete remaining limits

- The phone's shared-group inventory found Instagram and Facebook. Facebook's
  family-group registration points to observed profile109 under the same physical
  group root. Both apps cannot independently admit different CIDs in that group
  under the same UID without restoring the sibling-read problem. Preserve
  Facebook's state: reject a conflicting transition or keep its execution closed;
  never silently select another Facebook profile.
- Five Instagram extension homes have no numbered profile roots. Their default
  state must stay closed for nonzero CIDs until actual per-CID routing exists.
- Root-controlled application files do not prove broker, retained-descriptor,
  preferences, keychain or proxy isolation. A checked keychain operation is still
  required; metadata-only selection is not an acceptable substitute.
- Crash recovery must close/drain and reconcile the durable journal before any
  launch admission. A UI timeout, same-ID callback, absent process or matching
  global label is not a commit receipt.

The next bounded code unit is the native control-state store plus coordinator
protocol and inert bridge tests. Required cases include stale/ABA requests,
same-ID revalidation, duplicate/late replies, unsupported writers, interrupted
multi-file commit, metadata rename, and blocked create/delete/import bypasses.
Connect production only after the real drain and keychain prerequisites pass.
