# Setup and launch-safety update

Published rootless **0.1.14** and rootful **0.1.12** on the existing production
[installation page](https://redditspoof.vercel.app/install).
`feat/lifecycle-and-distribution` remains unmerged.
[Distribution evidence](release-evidence/0.1.14-distribution.json) verifies both
signed repositories, retained downloads, staging license health and web versions.

- Settings has an actionable red/green preparation checklist. A configured
  provider, managed installation and verified routing are distinct observations.
- Both proxy entry screens normalize common copied formats, including labelled
  HTTP and bracketed IPv6. Existing credentials and license keys are preserved.
- Connection results expire and are bound to the configuration actually tested.
  Every Open still runs a new proxy validation. Actual network metrics must
  match the selected proxy's numeric peer and port; direct/unverifiable health
  connections cannot authorize opening.
- A retained isolation-sentinel alert now blocks the next Open even with the
  observer switched off. The observer does not terminate active sessions.

See [implementation and evidence limits](setup-and-launch-safety.md) and
[sentinel behavior](isolation-sentinel.md). These changes do not establish 100%
isolation or substitute for the [ordered device acceptance](device-acceptance-final.md).

## Host validation

Both complete ldid-only builds passed, including the existing native
firewall, readiness, lifecycle, license, storage and proxy checks. The new
normalization regression failed before the fix and passed afterward. Mocked
admission/checklist tests and actual Foundation loopback transport tests passed.
A separate Mac HTTPS CONNECT test through the existing user-provided proxy
returned HTTP 200 and passed the new peer validation. No proxy credentials or
response IP are included in this report.

## Device status

The iPhone is currently absent from USB. The last verified installed version was
rootless 0.1.13. Installation of this update, touch interaction, actual clone
launch, managed routing/provider-failure tests and two-container A/B denial are
**NOT_RUN** for this release. The last device observation had only one clone and
deferred managed per-app VPN. MDM access and reconnection were requested; no
supervision, enrolment, new license keys or bypass state was invented.

Rows: UI-001, UI-004, NET-034, NET-036, NET-038, LIFE-021, ACCEPT-005.

## Rootless publication

Rootless 0.1.14 completed signed staging and production verification. Its package
SHA-256 is `518575121e319cee3531d87c9a5c0d54877aa976644627767ff0cc5630e0c2e4`.
[Host and staging evidence](release-evidence/0.1.14-host.json) records the
completed checks and the missing iPhone acceptance. Rootful 0.1.12 completed the
same release process afterward; the rootless repository was retained and
reverified. Production still uses the existing license signer/public key.
