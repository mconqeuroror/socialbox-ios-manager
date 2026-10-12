# Private customer package candidate

`scripts/build-socialbox-customer-candidate.py` composes a separate private
`3.1.0-1+socialbox.customer.1` profile. It does not turn the pinned upgrade
builder into a first-install initializer. `freshInstallReady` and
`customerDeliveryReady` remain false. This candidate must not enter the public
download/repository flow.

## Unpack boundary

Both the external preflight and incoming `preinst` require real/effective root,
the fixed rootless bootstrap, supported architecture/firmware and a complete
successful package inventory. Recorded manager, RedditBox or Roothide history
requires migration; even config-files/not-installed records are refused.
Incoming `preinst install` with no prior-version argument admits only this
version's exact `iphoneos-arm64` half-installed row, reflecting dpkg's new
package transition. External preflight always refuses that row. Duplicate,
malformed, failed and partial inventories are refused.

Inventory rows now retain literal tab boundaries: exactly four nonempty fields
are required, rather than allowing whitespace splitting to collapse an empty
column. C locale fixes the package/architecture/version character checks.
Only the eight documented [dpkg package states](https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html)
are admitted. An optional package architecture qualifier must match the separate
architecture field; duplicate base-package/architecture pairs refuse, while
distinct architectures retain the existing conflict rules. Matching qualified
manager records still have the same exact incoming-only boundary.

These are structural/character checks, not complete Debian version semantics,
an atomic inventory lease or detection of successfully omitted rows. Shell
command substitution strips trailing newlines, so it cannot distinguish trailing
blank rows or newline-only output from a zero-record observation. Empty output
supplies no pristine-history or preparation authority. No firmware-row
requirement or initializer is added.

Every existing payload destination, including a dangling link, is refused.
Existing parents must be safe; missing payload parents may remain absent.
All five source-state parents must exist safely before their nodes are tested
for absence. Any present source installation, pairing, configuration, pending
or marker node is preserved and refused. Passing these observations authorizes
unpack only. It neither proves pristine history nor permits preparation.

## Configuration and removal boundary

Configuration, repeated configuration and supported abort-recovery branches
verify every exact installed payload file, mode, ownership, single link and
safe parent. Only then do they execute the pinned native
`socialbox-prepare-installation check`. This opens and verifies existing
prepared state; no lifecycle script invokes the initializer. Failed checks
leave missing, partial, consumed or unknown source state unchanged and prevent
licensing startup and app registration. Successful checks precede the fixed
licensing job and app registration. No original helper or engine job is
explicitly started by these controls.

Removal/deconfiguration stops only the licensing job and preserves source
data. Upgrade refuses before stopping services or changing data; image-policy
migration is unsupported. There is no `postrm`, reset, adoption or cleanup.
The archive builder admits only its regenerated canonical lifecycle controls,
and rejects source-state payloads, escaping paths and writable payload modes.

## Remaining acceptance

An independently trusted external first-preparation transaction and its
authority/history are not supplied by this profile. Complete disappearance of
anchors, a failed existing-only check, ordinary dpkg configuration, or a
reinstall cannot supply that authority. The current fixed native initializer
remains a separate explicit trusted operation; this package never calls it.

The native command grammar now requires an exact `prepare` or `check` command.
No arguments, unknown commands and extra arguments refuse before either factory
is called. The unchanged real/effective UID 0 and effective GID 0 guard precedes
command dispatch; the actual owner manager with real UID 501 cannot initialize.
`prepare` expresses deliberate intent only. The existing fixed-executable,
image/path and exclusive-state factory policy still applies, and independent
trusted first-install provenance/history must come from outside this command.
`check` remains existing-only and cannot fall back to preparation. This grammar
change supplies no authority after total provenance loss, issuer, migration,
reset or client readiness.

Rebuilding the installer changes an image bound into existing prepared policy.
Do not replace that image in an established installation without reviewed
migration. The package source-state refusal remains in place; the new artifact
is private and has no owner installation acceptance.

Shell guards are cooperative, instantaneous observations, without a lock
across dpkg. The existing-only native check has its source provenance contract;
a successful shell result is not a transferable license/runtime grant.
Loaded launchd-job ownership/lifetime and actual package installation have not
been accepted. Synthetic inert-provider tests prove ordering and preservation,
not native prepared-state validity, jailbreak injection or a usable fresh
install. Exact artifacts must pass the normal endpoint/original locked page
flow and real runtime/account/proxy/switching/isolation acceptance before any
customer release. The upgrade-only release gate remains unchanged.
