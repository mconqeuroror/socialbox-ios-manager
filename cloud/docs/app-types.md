# SocialBox Phase 1: cloud app identity

The canonical registry is `src/config/app-registry.json`. Native descriptors are
generated from this same file by `tools/generate_app_registry.py`; the cloud
imports the JSON directly. Adding a descriptor does not activate its runtime.
Reddit is active. Facebook is registered and inactive pending its binary and
identifier audit. Instagram is not registered in Phase 1.

## Additive profile migration

`ProfileRecord.appType` is an immutable app identity. A missing legacy field means
`reddit`; explicit null, malformed values, and unregistered names are rejected.
Reads normalize the field in memory without rewriting the inventory document.
The next successful existing inventory CAS mutation persists the additive field.
No license, key, proxy credential, device binding, profile ID, or migration backup
is replaced. The dedicated migration test compares the complete stored document
before and after this operation.

App type does not form part of profile uniqueness: profile IDs and retirement
tombstones remain globally unique within their existing owner scope. The same ID
cannot be reused for Facebook after Reddit retirement. Publication and generic
inventory writers cannot retag an existing profile. Missing appType on an update
to an existing Facebook profile is rejected, rather than treated as a transfer.

## Requests and console

`GET /api/profiles` and `GET /api/profile-proxies` accept `?appType=reddit` or
`?appType=facebook`. User-authenticated requests without a filter can list all
owned apps. Device-authenticated requests without a filter return only Reddit
to protect old device clients; explicit filters still preserve device ownership.
Unknown, empty, and duplicate filters are rejected. Tombstone receipts remain
global because the ID retirement contract is global.

Profile POST, metadata PATCH, DELETE, reconciliation, assignment POST, and
rotation-auth PUT accept an `appType` assertion in their JSON body. A missing
assertion preserves the old Reddit request format. Assignment DELETE and
rotation-auth GET use the query parameter, also defaulting to Reddit. Assertions
are checked against the existing profile inside the existing inventory
transaction before mutation. They do not grant access or change the app type.

The existing console route stays `/apps/reddit`. Its profile section filters by
the canonical registry and defaults to Reddit. The Facebook selection explains
that support is pending and hides the runnable-profile creation form. Existing
licenses, devices, the shared proxy library, and backups retain their existing
scope and behavior. Publishing Facebook inventory metadata through the API is
supported; it does not import an IPA, build a clone, or activate Facebook.

## Phase 2 activation blockers

Before enabling Facebook, supply a lawfully obtained decrypted Facebook IPA for
the exact version to be supported. Audit its binary, identifiers, entitlements,
SDKs, and process/bootstrap requirements, and perform device isolation and
network acceptance. Backup payloads and restore APIs still use the legacy
profile-ID contract; add and verify app identity handling before Facebook
backups or restores are enabled. Phase 1 deliberately does not activate that
untested path or alter Reddit backup behavior.

## Validation

- `npx tsx scripts/app-registry-test.ts`: actual local storage and authenticated
  routes, legacy migration bytes, unknown types, immutable app identity, global
  tombstones, device and owner scope, and explicit mutation assertions.
- `npm test`: all existing suites plus the registry suite. Existing metadata and
  device-scope fixtures still omit appType; three equality assertions explicitly
  account for the new additive `appType: reddit` field.
- `npx tsc --noEmit` and `npm run build`: typecheck and production compilation.

These tests use synthetic local data. This branch does not deploy a cloud
migration or alter the production license signer.
