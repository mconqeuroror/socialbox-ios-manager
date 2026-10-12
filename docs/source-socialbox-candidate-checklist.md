# Independent source candidate: acceptance boundary

Candidate version: 0.2.0. Branch: `feat/lucid-base`. This is a private source
build, not a released update of the recovered engine.

## What has changed

The launcher, daemon, tweak and firewall are compiled from this repository's
source stack. Activation uses the existing SocialBox deployment and public
signing pin. No original-engine licensing server, recovered verifier or patched
always-valid result is involved. Existing customer licenses and signer keys are
unchanged. Historical data names and documented compatibility identifiers are
not evidence of a runtime licensing dependency.

The whole window stays on the English activation screen until a valid daemon
grant exists. The daemon also rejects protected requests while locked, even if
a caller bypasses that screen. Invalid, expired or revoked grants cannot open
container traffic. A valid license does not substitute for network readiness.

## Verified for this change

- Actual native verifier: activation, process restart, saved-credential
  validation, second-installation rejection and signed revocation against the
  existing production service, including an isolated probe on the iPhone.
- Own launcher: 52 license-root and 258 workspace UIKit assertions using
  synthetic publications and inert IPC; these are not real device activation.
- Actual queue dispatcher with mocked authority: 166 assertions covering
  protected actions, unknown actions, locked local refresh, recovery and CLI.
- Existing cloud device-license suite: 23 checks, including concurrent claims.
- Package boundary: source implementation markers, architecture slices, fixed
  public pin and unexpected executable rejection. The pre-install test refuses
  mixed engines before stopping processes or modifying installed files.

See `release-evidence/source-socialbox-licensing-2026-09-29.json` for package
hashes and explicit PASS/NOT_RUN results. Acceptance licenses were revoked and
phone probe storage/Keychain identities removed after testing.

The source navigation now has Containers, Connection and Settings, with Overview
under Containers and Proxy/Location under Connection. See
`release-evidence/source-three-sections-2026-09-30.json`; this launcher-only build
has not replaced the installed app or published a new customer package.

## Before replacing the currently installed app

1. Capture a restorable backup of the installed package, container inventory,
   app data, identity metadata and proxy/Cloud configuration. Do not export
   plaintext account credentials into a public evidence report.
2. Implement and test the recovered-to-source data conversion on a private copy.
   Preserve existing IDs/data; reject unsupported records without partial writes.
   The existing source schema migrations cover source upgrades, not this conversion.
3. Verify required application support in the source registry. Facebook is still
   inactive in this implementation; successful license activation does not enable it.
4. Complete verified network enforcement for the actual no-MDM setup. The
   current source mode still requires managed per-app VPN; the independent PF
   candidate has host-tested compilation/readback but no accepted rule writer or device packet proof. Follow the [completion plan](socialbox-completion-plan.md)
   for implementation and physical acceptance. Keep online launch blocked until
   enforcement is demonstrated; do not label device-wide rules as per-app protection.
5. Perform a backed-up device transition and test the actual installed
   UI → request queue → daemon → server flow, locked/unlocked/revoked states,
   restart, container data preservation and rollback.
6. Only after those checks pass should the candidate be promoted into the signed
   customer update repository. Neither this build lane nor this document publishes it.

The current phone retains the recovered `.17` app unchanged. Do not uninstall it
or bypass the candidate's compatibility preflight to make installation appear
successful. No full-isolation, Facebook-parity or sale-readiness claim follows
from these licensing results.
