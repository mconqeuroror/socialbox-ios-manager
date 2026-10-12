# SocialBox manager icon correction — 0.1.27

The user rejected a separate Facebook-branded helper. The manager now displays
**SocialBox** while retaining `com.redditbox.launcher`, its executable and install
path. `SocialBoxFacebook` is excluded from the package build, generated resource
staging and post-install registration. Its source remains historical evidence.

On upgrade, preinst stops only the exact installed helper executable and
unregisters its exact bundle while Info.plist is present. dpkg removes obsolete
package-owned files. Fresh installs with no retired helper skip this migration.
A uicache failure propagates; no broad refresh or deletion of user data occurs.
The exact `-u <path>` operation follows the [Procursus implementation](https://github.com/ProcursusTeam/uikittools-ng/blob/master/uicache.m).

Original Facebook and Reddit applications, clone identities, profile data,
license keys and network admission are unchanged. The ordinary app icons still
open their original applications. **Routing those icons to a selected isolated
container is not implemented by this correction.** Daemon durable selection and
the launcher's exact deep-link admission remain available.

## Verification

- PASS: build-input version/identity tests and pre/post-install/variant tests.
- PASS: mocked rootless and rootful upgrades stop only the exact obsolete helper,
  unregister only its icon, preserve original-app fixture data, propagate failure
  and skip registration when the helper is absent.
- PASS: full rootless and rootful ldid-only builds, all 116 build test entrypoints
  per variant, static and
  leak-register checks. Independent inspection finds seven Mach-O components,
  twelve slices and 1,346 valid CodeDirectory page hashes; no helper bundle,
  SocialBox display name and unchanged manager bundle identifier.
- PASS: both variants preserve the existing deployment licensing public-key pin
  and all twelve remaining effective entitlement payloads (also identical to
  the 0.1.18 baseline). Each has seven components and twelve signed slices.
- PASS: physical rootless upgrade from 0.1.26 to 0.1.27 through USB SSH.
  The retired helper is absent from disk and LaunchServices; SocialBox is
  registered with its original bundle ID. Both original apps remain registered.
  Both container IDs and all six profile files (bytes, mode, owner/group) match
  the pre-upgrade snapshot. License remains unlocked, daemon running, network
  CLOSED, startup recovery successful. Private backups were retained on the Mac
  and temporary phone copies removed.
- NOT_RUN: visual SpringBoard confirmation; registry removal is verified.
- NOT_RUN: normal Facebook/Reddit icon routing or successful Facebook networking.

This correction does not change the scoped 0.1.26 isolation findings, nor imply
that the full forty-container plan has passed acceptance. No production APT
promotion or branch merge is part of this correction.

Package hashes and the exact check list: [release evidence](release-evidence/socialbox-icons-0.1.27.json).
