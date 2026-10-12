# Facebook launch readiness — 0.1.28 UI correction

This is not a Facebook activation or successful-launch release. The requested
end-to-end Facebook container run is still blocked. The 0.1.27 phone publication
reports imported decrypted Facebook 578.1.0 / 1063022819, `networkState=closed`,
`firewallScope=none`, `firewallSetup.ready=false` and zero verified managed clones.

The production descriptor remains inactive and the app-specific defaults/wire
boundary and live clone acceptance remain unfinished. The existing network
provider is an NEAppProxyProvider: its host loads a managed per-app configuration
and does not create one. This repository exports MDM configuration; it does not
supply an MDM service. An import retry or proxy alone cannot satisfy these facts.
No profile, readiness or entitlement flag was changed to make a launch appear
successful. Original-app launch would not be a SocialBox container acceptance.

## Reproduced UI defect and correction

The inactive workspace previously displayed a static source-setup message even
when Facebook was already imported. It now reads its own daemon-published source
and separates three facts: IPA import, implementation admission and verified
network setup. It refreshes on visibility and while displayed, including after
an import modal. The page scrolls on small screens. The import action becomes
**Replace Facebook IPA from Files** when a source exists. Existing source copy,
validation, IPC ownership, passcode and modal boundaries are unchanged.

A shared read-only projection rejects malformed source values and never falls
back to Reddit's singleton source. Device VPN readiness requires a numeric ready
flag, per-app scope and a publication no more than fifteen seconds old. Even a
ready VPN does not change the registered app's execution admission.

## Validation and next dependency

Foundation status/scoping and actual UIKit selector tests pass with both inactive
and synthetic-active registries. The synthetic-active test does not activate the
phone. The actual workspace fixture also passes 155 UIKit checks. The rootless ldid-only
build passes all 116 build test entrypoints and static/register checks. Independent
inspection verifies seven components, twelve slices, 1,354 CodeDirectory page
hashes and unchanged entitlements/license pin versus 0.1.27. Rootful was not built
for this device-specific correction. Physical installation is recorded separately.

A real MDM service and adoption of the exact clone artifacts are needed to test
the current managed network path. Facebook SDK/state, clone launch, identity,
transport and A/B lifecycle acceptance are also unfinished, as detailed in the
[acceptance runbook](facebook-acceptance-runbook.md). Enabling the descriptor alone
would mask those gaps. User account login remains a deliberate operator action.

## Installed candidate

Rootless 0.1.28 is installed over 0.1.27 through USB SSH. Both container IDs,
all six profile-file contents and ownership/modes are unchanged. The license
remains active, both app sources remain imported, startup recovery passes and
traffic remains CLOSED. A URL request opened the manager's Facebook setup path;
physical visual confirmation is not claimed. The rootless package and device
checks are recorded in [release evidence](release-evidence/facebook-setup-0.1.28.json).
No production APT promotion or branch merge occurred.

**Facebook container launch remains BLOCKED**, not PASS. This update corrects
misleading setup presentation; it does not complete Facebook runtime support.
The request for existing MDM service information is still unanswered.
