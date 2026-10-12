# Recovered context adapter contract

This adapter targets the supplied **compiled** SocialBox 3.1.0-1 base. The recovered
Ghidra C is evidence, not its original source or a new implementation of its
storage isolation. No archived executable is run by the native tests.

`LBXRecoveredContextSnapshot(existingContainersController)` accepts only an
already-created `_Xc9m` instance, on the main thread. The caller may find that
instance among existing navigation roots; it must not load/create the controller
or call `loadData` merely to populate diagnostics. A missing or unsupported
controller returns `UNAVAILABLE`. The production host must retain the pinned
bundle identifier `com.socialbox.app`, version `3.1.0`, and build `1`.
The class image and each getter implementation must belong to the actual main
executable. These compatibility checks are not a cryptographic integrity check.

The result contains only canonical positive decimal-string context IDs, names,
and app bundle membership. `nil` membership remains unavailable; an observed
empty array is distinguished from that state. Duplicate IDs, malformed fields,
wrong signatures, unexpected images, unsupported versions, or a selection that
changes during the read produce no guessed active context. A zero/default ID or
an ID absent from the list is not presented as a verified active context.

The bounded projection accepts up to 4,096 contexts, 256 app memberships per
context, 512 characters per context name, and 255 characters per bundle ID.
Bounds protect the diagnostic screen; they neither limit nor mutate the base
app's containers. An out-of-contract value makes diagnostics unavailable.

`AVAILABLE` means management metadata was observed. `OBSERVED_CACHED_UI` means a
stable selected ID was present in that cached list. It does **not** establish
freshness, process binding, completed switching, filesystem/keychain isolation,
proxy routing, or safety. `freshnessStatus` stays `UNKNOWN`,
`processBindingStatus` stays `UNBOUND`, `identityStatus` stays `UNKNOWN`, and
`isolationStatus` / `networkStatus` stay `NOT_RUN`. The assessment and public
report retain unavailable-list status rather than relabeling it as zero observed
containers. The public report excludes names, IDs, app membership and arbitrary
input text.

## Static evidence

Evidence paths below are relative to the private reference extraction
`work/private-socialbox-adoption-2026-09-20/socialbox-3.1.0-1`. Addresses refer to the
**arm64** slice, verified against `otool -arch arm64 -ov`, not the archive's first
architecture. Source line references refer to that exact supplied decompilation.

- `decompiled/SocialBox.c:91041`, `_Xc9m::containers`, `0x1001295dc`: direct
  `_containers` object getter; encoding `@16@0:8`.
- `decompiled/SocialBox.c:91069`, `_Xc9m::activeContainerID`, `0x100129600`:
  direct signed 64-bit scalar getter; encoding `q16@0:8`. It must not be invoked
  through an object-returning message-send cast.
- `decompiled/SocialBox.c:213463`, `_Xv8i::containerID`, `0x1003065a8`:
  `q16@0:8`; `:213490`, `name`, `0x1003065b8`: `@16@0:8`;
  `:213711`, `apps`, `0x10030664c`: `@16@0:8`.
- `decompiled/SocialBox.c:213292`, `_Xv8i::initWithDictionary:`,
  `0x100305f34`: fields originate from `id`, `name`, and `apps`. Other fields
  include identity/proxy/GPS values and are deliberately never accessed.
- `decompiled/SocialBox.c:79458`, `_Xc9m::loadData`, `0x10010199c`: obtains
  cached manager metadata, deduplicates rows and can persist repairs. It is not
  a read-only refresh and is never called by this adapter.
- `decompiled/SocialBox.c:213374`, `_Xv8i::toDictionary`, `0x1003061fc`:
  includes `spoofProfile`, proxy and GPS fields; never called here.

## In-target binding discovery: not sufficient to install probes

The supplied `SocialBox.dylib` contains `_Xk2n` with the following instance getters:

- `decompiled/SocialBox.dylib.c:51902`, `currentBundleID`, `0x00257654`, `@16@0:8`.
- `decompiled/SocialBox.dylib.c:51930`, `activeContainerID`, `0x00257668`, `q16@0:8`.
- `decompiled/SocialBox.dylib.c:52122`, `isInitialized`, `0x002576e4`, `B16@0:8`.

These directly read ivars. `+sharedManager` (`0x0024de24`, `:40677`,
`@16@0:8`) may construct a singleton and a dispatch queue. Its `init` starts
with active ID zero and `isInitialized` false. The adapter does not invoke this
factory or `initializeForBundleID:dataPath:` / `loadMetadata`.

Crucially, recovered block `FUN_00251b78` (`:366810`; assignment at `:366842`)
sets activeContainerID **before** updating activeContainerPath and the owned path
buffer. The inspected getters expose no transaction generation/completion receipt.
Even reading the same ID twice cannot prove path switching completed. No safe
existing-manager acquisition plus completed-switch contract was established in
this unit. No runtime observer is installed, and no sidecar last-selected ID is
substituted for authority.

Future in-target probes need an independently established completed-switch
binding and a witnessed, context-bound canary manifest. Candidate probe APIs are
ordinary `SecItemCopyMatching`, `NSFileManager`, named preference suites, and
clipboard reads through the same hooked paths as the target application. The
clone architecture's SSH canary manifest is not valid for this data-switching
backend. This unit neither reads account data nor creates canaries, and an empty
read without a witnessed canary must remain inconclusive.

## Validation

- `python3 lucid/tests/test_recovered_context_adapter.py`: **185 assertions**
  across real Objective-C runtime mocks, including deliberately wrong scalar and
  object method encodings. Production compilation excludes the test seam.
- `bash tools/test_lucid_isolation_assessment.sh`: **204 assertions**. The new
  unavailable-versus-empty regression failed before the fix. Malformed report
  input, oversized/duplicate/noncanonical IDs, and runtime-proof escalation are
  rejected.
- Adapter, assessment and real diagnostics controller compile for arm64 iOS15
  with `-Wall -Wextra -Werror`.
- Physical device behavior, original-controller cached contents, runtime
  isolation, proxy enforcement and switch acceptance: **NOT_RUN in this unit**.
