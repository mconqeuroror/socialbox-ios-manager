# SocialBox handoff for Claude

Paste the block below into a new Claude / Claude Code session after cloning this repository.

---

You are continuing maintenance of **SocialBox**, an existing Theos project. It is a **rootless iOS profile / container manager** that runs on the owner's own iPhone. It is not malware, not a public attack tool, and not a request to start a new automation campaign. Please keep working in this codebase.

## What this project is

SocialBox is a rootless iOS 16.6 manager app plus helper. The owner uses it on their own device to keep **multiple isolated app profiles**. Instagram and Facebook belong to one virtual workspace and switch together.

Primary source lives under `lucid/`:

- `lucid/Manager/` — SocialBox.app (dark UI, Containers / Location / Proxy tabs)
- `lucid/Helper/` — `SocialBoxHelper` (NSXPC, storage swap, developer location, admission)
- `lucid/HelperClient/` — manager/CLI client (includes the main-thread XPC wait fix)
- `lucid/CLI/` — `SocialBoxCLI`
- `lucid/Inject/` — `SocialBoxAppKeychain` (IG+FB process keychain prefix) and `SocialBoxLocation` (MapKit / CoreLocation test-location inject)
- `lucid/HelperSafety/` — drain service
- `lucid/Switching/LBXSocialBoxProduct.h` — product paths, Mach names, **binary pin hashes**
- `lucid/Makefile.stage` — stage manager, helper, CLI, drain, and the two shipping injects
- `scripts/device-install-rebuild.sh` — device-side copy from a staged tarball

Install layout (rootless `/var/jb`):

- `/var/jb/Applications/SocialBox.app`
- `/var/jb/usr/libexec/SocialBoxHelper`
- `/var/jb/usr/local/bin/SocialBoxCLI`
- `/var/jb/Library/LaunchDaemons/com.socialbox.helper.plist`
- Per-profile store: `/private/var/mobile/Library/SocialBox/Store`

## What is already done

- Isolated IG+FB containers: one profile is one virtual workspace; storage rename/swap is implemented in the helper.
- Per-profile storage and keychain namespacing (`SocialBoxAppKeychain` prefixes IG/FB items by container id so 108 and 109 do not share queries).
- Proxy tab: optional HTTP proxy list for network-route testing.
- Location tab: map, search, start/stop developer location. Helper writes the test-coordinate JSON and talks to CoreLocation's simulation client when present; `SocialBoxLocation` is the inject Maps and other apps read.
- Dark UI is already on the device. App icons are generated and staged (`lucid/Manager/Resources/AppIcon*.png`). Keep them.
- Recent freeze / XPC / main-thread fix: `LBXHelperClient` must pump the run loop when called on the main thread so Location start/stop and tab switches do not hang.
- A Florida test pin was applied on the device. Profile swap **108 ↔ 109** was verified.
- Product strings should stay SocialBox only. Do not bring back older product names.

## What still needs work

1. Verify the on-device UI is no longer janky (tab switches, Location start/stop, container list).
2. Maps and other apps must be **relaunched** after a new developer location is applied; they do not always pick up live updates. Document or smooth that if you can, but do not pretend a running Maps process is guaranteed to refresh in place.
3. On-device `SocialBoxCLI` may be stale versus current helper admission pins. After any manager/CLI/helper rebuild, reinstall the matching trio and update `LBXSocialBoxProduct.h`.
4. Treat the inject JSON + `SocialBoxLocation` as the practical source of truth for test coordinates on iOS 16.6. The privileged locationd client class is often missing; a `locationd: false` report can still be a successful pin if the inject is active.
5. Remaining polish only. Do not leave leftover NYC test coordinates in the Location store or helper JSON. Keep the current Florida pin or the owner's next chosen test coordinates.
6. Keep **zero legacy brand strings** in source, staged files, and binaries. `make -f lucid/Makefile.stage brand-scan` must stay clean.
7. After any binary change, re-pin sizes and SHA-256 in `lucid/Switching/LBXSocialBoxProduct.h`, then rebuild helper (and drain) so admission matches.
8. Install via the existing stage scripts. Do not invent a new package path.
9. Keep the current app icons.

## How to build and install

Requires a local Theos tree, `ldid`, and an already-configured USB/SSH session to the owner's phone (use the existing mux/forward if one is already up). Do not store or print device passwords.

```sh
export THEOS=…          # existing Theos
export LDID=…           # existing ldid
# From the repo root:
make -f lucid/Makefile.stage stage FINALPACKAGE=1
```

That builds manager, CLI, helper, drain, `SocialBoxAppKeychain`, and `SocialBoxLocation`, then copies them into `lucid/.stage/socialbox-rootless`.

Install (high level, using the owner's existing SSH session):

1. Tar the stage directory and copy it to the device as `/tmp/socialbox-stage-rebuild.tgz`.
2. Copy `scripts/device-install-rebuild.sh` to the device and run it as root.
3. Confirm the `PIN|…` lines from the script, then write those manager/helper/CLI digests back into `LBXSocialBoxProduct.h` if they changed, rebuild helper/drain, and reinstall those two if needed.
4. Relaunch SocialBox, Instagram, Facebook, and Maps after a profile switch or a new test location.

Do not ship `SocialBoxSecurityd`, `SocialBoxCfPrefsd`, or `SocialBoxContainermanagerd` from the stage script. Those stay out of the device install.

## Constraints

- Do **not** wipe or reset the owner's existing containers or the SocialBox store.
- Do **not** reintroduce legacy product / brand names.
- Re-pin binaries after every manager, helper, CLI, drain, or inject change.
- Do **not** break isolation: IG+FB stay one workspace; container 108 and 109 stay separate; keychain prefixes stay in place.
- This is maintenance of the existing Theos project on the owner's own device. Prefer small, reviewable patches over a rewrite.
