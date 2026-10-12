# Rootless and rootful build and installation

Two package variants are implemented on `feat/lifecycle-and-distribution`.
The branch remains unmerged. Both Mac builds have been published; see
[release evidence](release-0.1.13.md) and the [setup/launch-safety update](setup-and-launch-safety.md). A [partial iPhone 8 rootless import check](device-import-2026-09-10.md)
now passes; **full device acceptance remains unconfirmed for all three targets.** Passing portable tests is not proof of installation,
entitlement authorization, hook injection or successful Reddit login on a phone.

| Target jailbreak | Build selection | Debian architecture | Installed tools/app prefix | APT source path | Device result |
| --- | --- | --- | --- | --- | --- |
| palera1n rootless | `rootless` | `iphoneos-arm64` | `/var/jb` | `/apt/redditbox/` | Install/license/source import passed on iPhone 8; full acceptance NOT RUN |
| palera1n rootful | `rootful` | `iphoneos-arm` | empty (e.g. `/Applications`) | `/apt/redditbox-rootful/` | NOT RUN |
| Dopamine | `rootless` | `iphoneos-arm64` | `/var/jb` | `/apt/redditbox/` | NOT RUN |

[Dopamine is rootless](https://github.com/opa334/Dopamine/); there is no separate
rootful Dopamine build. palera1n exposes rootless and rootful modes in its
[official manual](https://github.com/palera1n/palera1n/blob/main/docs/palera1n.1).
The Debian architecture names and prefixes follow
[Theos packaging conventions](https://theos.dev/docs/rootless).
Both builds still compile native `arm64` and `arm64e` slices with an iOS 15
deployment target. `iphoneos-arm` is a package-manager name, not a request to
build a 32-bit executable. The synthetic device catalog does not determine
physical phone/jailbreak support; the actual Reddit binary may require a newer OS.

## Build on the Mac

Complete the [Mac prerequisites and license-public-key setup](on-device-smoke-checklist.md)
first: full Xcode, Theos with submodules/patched SDK, Procursus ldid, and the
matching deployment's public license key. Use **ldid only, no Apple team**.
Then select the variant explicitly:

```bash
# palera1n rootless OR Dopamine
RBX_PACKAGE_SCHEME=rootless bash scripts/build-mac.sh

# palera1n rootful
RBX_PACKAGE_SCHEME=rootful bash scripts/build-mac.sh
```

Run these sequentially if building both. The script cleans Theos outputs before
packaging each variant, generates its launchd/maintainer/helper paths, and prints
the exact resulting `.deb`. It defaults to rootless when no selection is set.
For version `X.Y.Z`, the filenames are:

```text
packages/com.redditbox_X.Y.Z_iphoneos-arm64.deb  (rootless)
packages/com.redditbox_X.Y.Z_iphoneos-arm.deb    (rootful)
```

Do not select the newest file from a directory containing both architectures.
On the jailbroken phone, `dpkg --print-architecture` must match the package.
Transfer that exact file and install through a dependency-resolving package
manager; an optional root-shell installation is:

```sh
dpkg --print-architecture
apt install /ABSOLUTE/PATH/TO/com.redditbox_X.Y.Z_MATCHING-ARCH.deb
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' com.redditbox
```

Replace the placeholder path with the actual transferred filename. Do not force
the architecture or relabel/repack the other variant. These share one package ID
and stable app/profile IDs: install only the variant matching the active bootstrap.
This is not a procedure for migrating a phone between jailbreak modes.

## Publish and install through Sileo/APT

Use the [signed APT procedure](apt-distribution.md) for credentials, key trust
and first-publication `APT_BOOTSTRAP=1`. Select both the scheme and matching URL:

```bash
# Rootless repository (also used by Dopamine)
export RBX_PACKAGE_SCHEME=rootless
export APT_REPOSITORY_URL="https://YOUR-CLOUD-HOST/apt/redditbox/"
bash scripts/release.sh

# Rootful repository: run only after the first command completes successfully.
export RBX_PACKAGE_SCHEME=rootful
export APT_REPOSITORY_URL="https://YOUR-CLOUD-HOST/apt/redditbox-rootful/"
bash scripts/release.sh
```

Each repository retains its own three versions. Both use the same cloud project,
dedicated public Blob host and GPG signing key, and share one publisher lock.
The rootless journal remains `build/release/publish.json`; rootful uses
`build/release/rootful/publish.json`. Resume with the same scheme, URL, credentials
and checkout using `bash scripts/release.sh --resume` before releasing the other
variant. Never delete the shared lock to bypass an interrupted release.

Commit/push generated metadata under **both** `cloud/public/apt/redditbox/` and
`cloud/public/apt/redditbox-rootful/` whenever present. Before staging, the release
driver requires the companion repository in the checkout to match its live
signed version, or both to be absent. It verifies that staging and promotion
preserve that companion. A stale checkout therefore stops instead of erasing the
other variant. Ordinary cloud deploys must also retain both metadata directories;
keep automatic production Git deploys disabled until their commits are present.

The APT guide selects the phone's source/keyring paths from its actual Debian
architecture: rootless uses `/var/jb/etc/apt`, rootful uses `/etc/apt`.
After the archive key fingerprint is independently verified and the matching
source is installed, refresh Sileo and install **RedditBox**. Both `.deb` variants are published. The first Sileo source parsing failure was
corrected; the next device attempt exposed missing appinst. The signed repositories
now carry both appinst and AppSync Unified for automatic dependency resolution.
Rootless installation, license activation and source import subsequently passed on
the connected iPhone 8; the remaining acceptance checks below are still open.

## Required device acceptance

Run the [complete acceptance runbook](on-device-smoke-checklist.md) separately on
palera1n rootless, palera1n rootful and Dopamine, retaining model, physical OS,
jailbreak version, checkout SHA, package hash and the following evidence:

1. Dependencies resolve; launchd starts the daemon from the selected prefix;
   Diagnostics reports the matching variant. No stale installation from the
   other prefix supplies the catalog or keychain-cleaner executable.
2. Activate the device license while CLOSED. Import the decrypted source;
   create, replace and delete a disposable clone, checking its app/data/keychain
   isolation and injection of the identity hooks.
3. Export the exact clone IPA and MDM mapping; prove managed per-app VPN
   association for every clone. Confirm host/provider entitlements are accepted.
4. Use an **HTTP proxy URL**, e.g. `http://user:password@host:port`.
   SOCKS5 support was removed in H15. Follow the capture checklist for A → B → A,
   proxy failure, provider/daemon restart and license revocation; require CLOSED
   until readiness is proved and no direct traffic during transitions.
5. Test first browser login and return to the correct clone. Callback ownership
   remains open: expected failure is no return, return to the source/wrong clone,
   or a stuck login. The runbook records logs and candidate callback changes.
6. Upgrade the same variant over five existing profiles. Verify saved profile
   IDs, data, Keychain, license and MDM association, including re-adoption when
   the signing-contract flag requires it. Repeat the A/B capture after upgrade.

For iPhone 8, 8 Plus and X on iOS 16.7.7, palera1n is the applicable target; see
[its official device/OS guidance](https://docs.palera.in/installing-palera1n/).
Select the rootless or rootful package matching the active bootstrap. This is
not a claim that every jailbreak or older iOS release is supported.

AppSync Unified, appinst, ldid and the other declared dependencies still need to
work on the selected device. Use the
[official AppSync source/repository instructions](https://github.com/akemin-dayo/AppSync/).
Successful package resolution alone does not prove clone signature acceptance.
ElleKit provides the Substrate compatibility dependency in its
[package metadata](https://raw.githubusercontent.com/tealbathingsuit/ellekit/main/packaging/control);
actual hook loading still needs device evidence. The MDM H08 gap and browser-login
issue are not resolved by changing a package prefix. RootHide forks or additional
Debian architectures are outside these two variants.

## Implementation evidence

- `a24ed2d`: variant build configuration, generated package paths, libroot-aware
  native path selection and release metadata. Portable package/build tests and
  the seven changed native implementation files passed syntax checks, including
  both rootless and rootful compiler branches. Mac linking remains NOT RUN.
- `cfcf6b8`: separate APT repositories and routes, shared publication locking,
  companion-repository preservation and matching package inspection. Twelve
  portable APT test groups passed, including real GPG corruption checks and
  eight interrupted-publication boundaries exercised for each variant. Cloud
  type checks, nine TypeScript suites and the APT publication suite passed.
  The local Next.js production build also passed, including both download routes
  and all 25 static pages. This did not deploy the cloud or publish packages.
