# Facebook launch metadata observations — FBRUN-001

Facebook remains inactive. Two 20-second launches of the existing original Facebook app establish real shared-storage and attestation callers, but do not establish safe clone identity, restore behavior, or working Facebook accounts. The multi-group keychain policy is an explicit implementation blocker under the instruction to stop changes that risk the existing Reddit flow beyond test coverage.

## Capture boundary

The root agent ran the private Frida 17.18.0 probe over USB on 2026-09-13, starting its runners at 21:30:35 and 21:37:28 UTC. The fixed process was `com.facebook.Facebook`; no login or UI action was automated, and that same app was stopped after each run. The operator identified the installed build as Facebook 578.1.0 (1063022819), matching the [audited IPA](facebook-binary-audit.md). The probe did not independently read the app version, iOS build or device identity.

[Selected redacted records and capture hashes](facebook-runtime-evidence.json) retain exact original event numbers and module-relative caller offsets. The first capture emitted 430 records: 21 keychain, 14 identity API, 349 preference, eight defaults-suite, one HTTP metadata, 36 hook-registration and one readiness record. The second emitted 448: 31 keychain, 16 identity API, 354 preference, six defaults-suite, one HTTP, 39 registration and one readiness record. Neither contained a probe-error record. Counts describe emitted records: identical metadata/caller records were limited to three, and each run was capped at 5000 events.

No identifier return values, account fields, keychain data, key material, persistent-reference bytes, tokens, HTTP values, full URLs, query strings or bodies were requested. Only allowlisted static names were emitted; unknown names were redacted. These observations cannot compare identifier values or prove their downstream wire semantics.

## Observed keychain groups and item classes

Both captures successfully queried three distinct access groups: `T84QZS65DQ.platformFamily`, `group.com.facebook.family`, and `group.com.facebook.Facebook`. In capture two, platformFamily produced 11 successful and ten not-found operation records; family produced six successful and two not-found records; Facebook produced a successful read and update. Status `0` denotes success; `-25300` denotes item not found. No observed `-34018` entitlement failure occurred in these original-app captures.

Capture two event 402 reads the exact service `group.com.facebook.family.securefamilydeviceid` as class `genp` in access group `group.com.facebook.family`, returning success at `FBSharedFramework+0x176a7b4`. This establishes a successful read of a named generic-password item; it does not establish the item's content, format, generation source, or request usage. The service name is not a separate access group.

Capture one event 407 and capture two event 423 successfully query class `keys` in `group.com.facebook.family` at `FBSharedFramework+0x35d9f80`. A generic-password-only implementation would therefore miss an observed item class. The probe did not inspect key attributes or returned references and cannot identify whether this was a Secure Enclave key, its purpose, or its relation to the named family identifier.

Most other services remain redacted. Successes in different groups are not evidence that the returned contents match. Collapsing all observed groups into one namespace could create item collisions or change fallback/migration behavior.

## Defaults receiver correction and platform identity

Capture one events 75–76 observe a read of `com.facebook.familydeviceid.backup.vendordeviceid` at `FBSharedFramework+0x3a6dd8`. Its original `<current-app>` label was a probe placeholder, not evidence of a storage domain. The selected JSON corrects that label to `<unresolved-receiver-suite>` and preserves the qualification.

Capture two events 74–75 observe the same key through a receiver previously returned by `standardUserDefaults`. The revised probe uses zeroing weak receiver tracking, with offline deallocation/address-reuse checks. This establishes the receiver's observed origin, not which domain supplied a value from its search list. These two events can describe one nested string/object lookup. Named `initWithSuiteName:` calls also construct `group.com.facebook.family` and `group.com.facebook.Facebook` defaults receivers. Returned values and physical backing plists were not examined.

Both captures observe `UIDevice.identifierForVendor` and the instance methods `FBFamilyDeviceID.familyDeviceIDWithConfiguration:SourceFile:SourceLine:` and `cachedFamilyDeviceIDWithConfiguration:SourceFile:SourceLine:`. Their calls establish runtime usage, without establishing equality, transformation or copying of returned identifiers. No `advertisingIdentifier` invocation was recorded during these intervals; its static references remain relevant and this is not evidence that Facebook never calls it.

## Attestation and request metadata

Both captures observe `DCAppAttestService.isSupported`. Capture two additionally observes `generateKeyWithCompletionHandler:` and `attestKey:clientDataHash:completionHandler:`. Invocation does not establish a successful completion or server acceptance; completion values were not inspected.

Capture two records platformFamily service `group.com.facebook.family.appattestation.reinstallationflagalreadyset` as not found, then successfully added (event 410), then successfully read (event 412). Service `group.com.facebook.family.appattestation` is queried as not found and successfully added at event 429. These are observed persistence operations for attestation-named generic-password services. Their payloads and relation to generated keys remain unobserved. They must not be rewritten as arbitrary device UUIDs or carried across a changed identity without a defined policy.

Each capture records one NSURLSession request with host `www.facebook.com` and header names `content-length` and `content-type`. It does not prove all Facebook requests were intercepted, that a request completed, that its UA reflects the profile, or that MQTT/custom Meta transports follow the proxy. No wire mutation is justified by these records.

## Proposed mitigation and reason it is stopped

An Info.plist keychain-group hint rewrite is useful but cannot cover these three observed query groups by itself. A possible follow-up would derive one distinct clone group for each registered source group: canonical primary group first for platformFamily/default behavior, plus separate clone groups for family and Facebook. Unknown explicit groups would stay denied. Source groups and source App Group entitlements would never be granted. Services, accounts and item payloads would keep their native semantics.

This is not a four-function patch. Signing and effective-entitlement checks currently expect exactly one group. The keychain cleaner, deletion journals, profile/bootstrap metadata, acceptance probes, source replacement and backup/restore contracts must accept only the same exact derived group set and verify every group/class. Omitted-group queries must retain native behavior; forcing them all to the primary group could change searches across entitled groups. SecItem update attributes, returned attributes, reference-only queries and persistent references also need defined behavior. The observed `keys` class requires examining SecKey creation and its nested public/private key attribute groups. Enabling the old generic keychain/path hooks or merging namespaces would evade these requirements rather than resolve them.

A single-group clone that strips foreign groups can enforce denial, but Facebook may fail to read or create its required identity state. That is a compatibility gap, not permission to widen access to original groups. Neither the required group-set implementation nor paired clone/restore and MDM acceptance was verified in these captures. The current descriptor stays inactive and app-specific defaults/wire readiness stays failed.

## Evidence needed to resume

A further targeted metadata probe could identify SecKey creation entry points, nested access-group attributes, safe constant key class/type/token identifiers, and keychain match/return flag presence, without reading key bytes or result objects. Exact caller disassembly could resolve static service literals and local generation branches. It must avoid nearest-string attribution. Explicit receiver-to-suite observation helps locate defaults, while a fresh clone's own known paths are needed to establish its actual backing domain.

After the group policy is implemented, synthetic canaries must cover each group and item class, omitted-group behavior, forbidden source/foreign groups, deletion failure recovery, interrupted create, import and same/changed-identity restore. Paired first-run clones under the complete network/MDM gate must establish distinct storage boundaries before login or account acceptance. No additional original-app observation alone can prove that package behavior. Value-free metadata also cannot prove equality or server/local provenance of unknown identifiers; any comparison method would require separately scoped evidence collection.

The Meta family storage and attestation findings are reused for Instagram phase later, while Instagram itself remains unregistered and unverified.
