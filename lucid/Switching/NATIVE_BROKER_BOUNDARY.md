# Native broker isolation: integration boundary

2026-10-03. **Source and static review; broker repair not installed.** This
assessment covers the official Instagram bundle with numeric native container
IDs. It does not apply the clone backend's signed identity as if the native
backend already had it. No original binary or phone data was changed for this
review. The earlier unrelated product's runtime approval restriction is not a
SocialBox architecture constraint.

## Decision

Keep the native architecture as a possible repair path. It already intercepts
both `securityd` and `cfprefsd`, so direct broker IPC is not automatically an
unhandled path. The missing piece is a source-owned authorization contract
binding each broker request to an immutable process/container generation.
Directory gates and application-side `SecItem` rewriting do not provide that
contract.

The smallest meaningful broker repair replaces caller attribution, request
context and namespace authorization at these two services, and connects them
to the same root switch transaction as the execution and storage fences.
Adding another application-side prefix hook would leave the authority gap.
This is bounded service integration work, not a requirement to replace the
whole UI or immediately adopt clones. A fully working, isolated native switch
cannot be claimed until that integration is exercised on the actual device.

## What the inspected implementation actually does

Private references use the pinned 3.1.0-1 extraction documented in
[the recovered switch contract](../Diagnostics/RECOVERED_SWITCH_CONTRACT.md).
Addresses and lines below identify the inspected arm64 pseudocode; they are
not an arm64e ABI specification.

| Boundary | Concrete evidence | Missing authority |
| --- | --- | --- |
| Target local activation | `SocialBox.dylib.c:46805`, `_Xk2n::_sD1:` at `0x00250f4c`, enters a translation-queue barrier. Block `0x00251b78` at `:366810` sets ID before path, replaces the owned C path, then clears the app-group map. Caller saves metadata and later invokes `SecItemDelete`/`SecItemAdd` at `:47243`–`:47244`. | This mutates local state; its BOOL does not attest broker admission, process absence, or a durable switch generation. |
| Target deactivation | `_Xk2n::_sD2` at `0x00252a7c`, `:47322`; calls at `:47593` onward clear active ID/path, free the owned path, clear the mutable group map and save metadata. Selector stubs at `:66829`, `:67530`, `:67738`, `:67848` and `:68371` confirm those operations. | No OS task identity or signed access-group change is established by this operation. |
| Security broker installation | `SocialBoxSecurityd.dylib.c:2033`–`:2047` resolves private `__SecItem*`/`_SecItem*` names. `:3615`–`:3622` installs the connection handler, CopyMatching/Add/Delete/Update handlers and a `SecTaskCopyValueForEntitlement` wrapper. | Presence of all four hooks does not establish their exact coverage, calling convention or authorization behavior on the installed OS. |
| Security caller classification | `FUN_0000ce10`, `:5911`; connection type and connection-derived numeric caller at `:5970` onward, cache lookup on a dispatch queue, then `proc_pidpath` on a miss at `:6005`. The cache block `FUN_00016870` at `:11637` indexes `DAT_0002c3c8` with an NSNumber made from the numeric PID. | This inspected cache key has no process-birth or switch epoch. A path/name classification does not identify the owning native CID. No complete audit-token/lifecycle contract was recovered here. |
| Security CID lookup | `FUN_00016414` at `:11433` reads cached state, otherwise reads a plist's `activeContainer`, then asynchronously caches it. The connection handler calls it at `:6321`. | A late request can observe a mutable selected ID rather than the CID under which its process was admitted. Cache invalidation must be established; the existence of a queue is insufficient. |
| Security thread context and entitlement rewrite | The connection handler writes request context into a thread dictionary and removes keys after calling the original (`:6321` onward, `:6386` onward). `FUN_00014514` at `0x00014514`, around `:10463`–`:10555`, branches on keychain groups, application groups, application identifier and associated application identifier, using thread context and an application-identifier fallback. | No request-owned, immutable CID/epoch is established. Async callbacks and nested calls need explicit context ownership. Falling back from missing managed context to current selection is not an authorization rule. |
| Preferences broker installation | `SocialBoxCfPrefsd.dylib.c:23060`, `FUN_00029bd0`, hooks `__CFPrefsGetPathForTriplet`, `-[CFPrefsDaemon handleSourceMessage:replyHandler:]`, and `withSourceForDomain:inContainer:user:byHost:managed:managedUsesContainer:cloudStoreEntitlement:cloudConfigurationPath:performWithSourceLock:afterReleasingSourceLock:`. | Path redirection alone does not partition cached source objects, observers or requests already queued by the broker. |
| Preferences request context | `FUN_0002a6ec`, around `:23338`–`:23482`, checks dictionary/connection shapes, reads the request's `CFPreferencesHostBundleIdentifier`, obtains a numeric caller from the connection, and stores bundle/caller thread context before invoking the original. | The supplied bundle must be checked against authenticated caller identity. This inspected wrapper has no visible context restoration after the original call; an invalid request must not inherit a previous managed request's context. This is a static review lead, not a reproduced leak. |
| Helper Keychain move | `SocialBoxHelper.c:52863`, `moveKeychainFromContainer:toContainer:forBundleID:reply:`, ends at `:52976`–`:52982` with NSError **501**, `Notimplemented_Phase2_`. | This selector cannot supply a completed Keychain switch receipt. |

See also rows DS-11 and the security/prefs entries in
[the static identity/storage findings](../../docs/socialbox-adoption/identity-storage-findings.json).
Those findings are inspection records, not additional runtime acceptance.

## Why the small alternatives do not create a boundary

iOS Keychain access is mediated by `securityd`; the normal database is shared
and access is selected by the caller's entitlements. A new service/account
prefix is query data. `kSecAttrAccessible` controls lock/passcode availability,
not a SocialBox CID. [Apple's Keychain architecture](https://support.apple.com/guide/security/keychain-data-protection-secb0694df1a/web)
describes those separate mechanisms.

Giving one process every CID access group allows it to search every granted
group. Omitting the query's group searches the caller's accessible groups;
the application identifier and application groups contribute to that set too.
Removing only entries from `keychain-access-groups` does not remove those
other grants. [Apple's access-group contract](https://developer.apple.com/documentation/security/ksecattraccessgroup)
is the relevant boundary.

There is no supported app-selected per-CID iOS Keychain database behind
ordinary `SecItem` calls. A custom vault owned by a separate service could
isolate newly stored secrets, but an application hook would still need full
compatibility for existing items, persistent references, keys, access control
and synchronizable behavior. Original accessible stores would remain reachable
through direct stock broker calls. It is not a drop-in fix for the preserved
native account state.

Filesystem sandbox-extension issuance does not subtract signed Keychain
authority or revoke a broker's existing file descriptors. A per-launch change
of effective signed application/access-group identity would be a different
installation/signing authority contract; none is supplied by `_sD1:`/`_sD2`.
It also invalidates the current code gate's pinned original-code binding.

## Required root authority and switch order

Introduce one source-owned broker admission authority, consumed by both
service adapters. Its process record must contain boot identity, kernel
audit token including PID generation, independently observed process birth
and exact registered executable binding, supported bundle/extension identity,
native CID, switch epoch and admission state. The root coordinator owns the
record. An app-provided CID, path, PID, bundle string, environment variable or
copied dictionary is not a permit.

A process receives an immutable CID/epoch for its lifetime. A broker may ask
the root authority to resolve an authenticated new caller while that epoch
is admitted; it must never relabel an existing process because the global
selected CID changed. Unknown managed callers, missing authority and stale
epochs are rejected. Unmanaged callers retain their original system behavior.

Connect this to `LBXNativeIsolationJournal`, `LBXNativeApplicationGate` and
`LBXNativeStorageFence` as follows:

1. Persist switch intent and close broker admission for the old epoch. Receive
   service acknowledgements after prior authorized requests have finished or
   been cancelled. Keep code launch admission closed during this barrier.
2. Close and drain the exact Instagram and extension executions. Stop any
   separately registered shared-group writers that belong to the supported
   operation. Broker acknowledgement and process absence are separate facts.
3. Freeze the inventoried data and namespace roots. Commit and independently
   validate the selected CID/profile in durable native metadata; the old
   worker's callback is not sufficient authority.
4. Prepare the target broker namespaces while admission stays closed. Open
   only the selected data roots. Publish the new admitted epoch to both
   brokers, then restore execution, main executable last. Each first request
   must resolve its authenticated process to this epoch before accessing data.
5. A failure closes broker admission, code and data again. A partial execution
   restore requires another fresh drain before storage rollback. Recovery
   does not infer successful broker admission from a journal phase alone.

No synchronous broker call should wait on a coordinator that is itself
waiting for that broker to drain. Use bounded barriers, request counters and
explicit acknowledgements. The old metadata/default/deactivation/creation
writers listed in [the interposition inventory](INTERPOSITION_BOUNDARY.md)
must obey this transaction, or the operation must remain unsupported.

## Source-owned replacement work

The following are proposed production components, **not existing files or
implemented guarantees**:

- `LBXNativeBrokerAuthority`: root-owned process admission and epoch state,
  authenticated IPC, in-flight request accounting, restart/recovery handshake.
- `LBXNativeSecuritydAdapter`: build-specific request boundary and caller
  context. Derive an exact per-CID access-group set in the broker and restrict
  every supported operation to it. Translate only known original aliases;
  reject explicit foreign/CID groups. Default-group queries, broad deletion,
  updates and persistent references must retain the same restriction.
  Request-supplied flags must not enable wildcard/system/network-extension
  grants. Preserve original class, access-control, return-value and error
  semantics; unsupported routes fail explicitly for the managed caller.
- `LBXNativeCFPrefsAdapter`: derive bundle/domain/container from authenticated
  context; validate requested suites against that caller's mapping. Key source
  objects, caches and observers by CID and domain. Retain request context
  across deferred work and restore nested context on every return. At an epoch
  barrier, close or retire old sources only after their writes/observers have
  drained. New requests cannot inherit an old source or thread dictionary.

Prefer a request-local Security client context at the lowest verified common
authorization boundary over a global entitlement-return override. Apple's
published `SecItemServer.c` shows CopyMatching/Add consuming
`SecurityClient.accessGroups`, validating explicit groups and applying the
result to database operations. This is an architectural lead only: its current
source is **not** the ABI contract for iOS 16.7.16.
[Apple's Security source](https://github.com/apple-oss-distributions/Security/blob/main/keychain/securityd/SecItemServer.c)

The preserved securityd adapter must not remain a later hook that broadens
the new adapter's grants. Establish the original implementation chain for
each entry point, then replace the managed-app branch deliberately. Stacking
an outer prefix wrapper over unknown entitlement rewrites is insufficient.
Likewise, CFPreferences source caches must use the new scope, not merely a
new pathname supplied after selecting an already cached source.

## Retained descriptors: concrete counterexample

An owned host-only temporary tree was exercised on 2026-10-03. The test opened
a file and a descendant-directory FD, then set the ancestor gate to mode
`0000` plus `UF_IMMUTABLE`. Results were:

| Attempt after sealing | Observed result |
| --- | --- |
| Fresh full-path file open | EACCES (13) |
| `openat` relative to the gated root FD | EACCES (13) |
| Read through the preopened file FD | Succeeded |
| Write through the preopened file FD | Succeeded |
| `openat` through a preopened descendant-directory FD | Succeeded |

The immutable flag remained set. All flags, modes and owned temporary files
were restored/removed after the experiment. This was a local capability
counterexample, not a phone broker test or an assertion that cfprefsd actually
retained these descriptors. No account content was involved.

The gate prevents fresh traversal through the sealed ancestor. It cannot
revoke existing descendant handles or data already cached in a service.
Terminating a proven set of app processes closes their own handles; it does
not prove that system brokers released theirs. Source retirement and
epoch-scoped request completion therefore belong in the broker barrier.

## Acceptance: existing evidence and missing focused checks

[The 2026-09-30 Instagram owner trial](../../docs/release-evidence/socialbox-instagram-owner-trial-2026-09-30.json)
reported normal file/preferences separation and an owned Keychain canary
passing, while normal and direct-syscall sibling file reads failed isolation.
Those sampled `SecItem`/preferences results do not establish direct broker
request authorization. The new fences are prerequisites; they do not close
the broker rows below.

| Check | Current evidence | Required acceptance |
| --- | --- | --- |
| Normal native Keychain canary A/B/A | Sampled PASS in owner trial | Repeat against the source-owned broker adapter with witnessed values. |
| Direct broker access without client rewrite | NOT_RUN | Owned A/B canaries through the actual broker boundary: default group, known alias, explicit foreign group and persistent reference; read/add/update/delete must remain CID-scoped. The test must prove the application hook was bypassed. |
| Late request and PID reuse | NOT_RUN | Hold an A request across the switch barrier; it must finish under A before acknowledgement or be rejected. Reused PID/new birth and forged bundle/CID cannot obtain A authority. |
| Preferences cache/source lifetime | NOT_RUN | Same-key A/B/A reads and deferred writes through actual cfprefsd, including a forged host-bundle field, invalid request after a managed request, nested dispatch and existing source/observer reuse. |
| Broker restart during switching | NOT_RUN | Restart/reconnect loses admission until exact root epoch is recovered; no fallback to mutable selected CID. |
| Fresh sibling pathname access | Owner trial FAIL; new gate not integrated | Repeat witnessed normal/direct reads for main, every observed group and default roots after an accepted switch. |
| Retained descendant capability | Owned host counterexample above | An owned helper holding the capability must be included in the barrier or remain an explicit unsupported writer. Do not use a failed fresh-path open as proof of revocation. |

The first native launch-gate phone exercise on 2026-10-03 failed at
`process-drain:enumeration_failed` before the spawn check. Its private
probe-only abort restored all eight original executable entries. Later,
three exactly attributed stale acceptance services were retired, complete
process observation was restored, and the normal gate exercise passed:
fresh drain, mobile launch denied with EACCES (13), and independent restoration
verification for all eight entries. No account content, storage permissions or
selection changed. The later launch-gate PASS does not establish broker isolation.

The read-only fence capture also now passes with final identical inventory
after fixing duplicated ancestor descriptors. It makes no storage permission
changes and does not resolve the broker checks in the table.

Host implementations of `LBXNativeBrokerAuthority` and `LBXNativeControlStore`
now exist with fixture tests. They are not installed, do not hook `securityd`
or `cfprefsd`, and do not claim complete native account isolation.

## Build and runtime checks before enabling the adapters

- Pin the exact iOS/securityd/cfprefsd image UUIDs and instruction-level
  signatures for each supported arm64/arm64e entry point. Recover every
  parameter, ownership rule, result/error ABI and async lifetime. Do not copy
  decompiler `void` prototypes or assume similarly named private symbols are
  interchangeable.
- For Objective-C boundaries validate selector encodings and image ownership;
  for C/private boundaries validate the exact symbol/offset and original
  implementation chain. Missing or changed ABI disables managed admission.
- Host fixtures must exercise the production namespace/authority core with
  forged identities, revoked epochs, nested/concurrent requests, delayed
  completion and crash/reconnect. Build both slices with strict diagnostics
  and verify installed filters contain only the intended broker processes.
- Before real account use, run the small owned-canary matrix above on the
  pinned device build and verify the original application's unrelated
  callers retain normal behavior. Keep raw broker payloads and Keychain data
  out of logs; publish only bound outcomes/counts.

Until then the defensible storage claim is: **inactive roots can deny fresh
pathname access after a verified process restart**. It is not yet a claim of
complete native account, broker, network or app-instance isolation.
