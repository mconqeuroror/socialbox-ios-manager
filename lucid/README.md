# SocialBox recovered-base candidate

This is a binary-preserving derivative of the owner's recovered SocialBox 3.1.0-1,
with new, buildable presentation, diagnostics and proxy-input layers. It is **not a reconstructed
source tree for the original suite** or a verified replacement for all SocialBox
isolation mechanisms. The existing SocialBox implementation stays in this repo.

The original five tabs remain in their original order: **Home → Containers →
LocSim → Proxy → Settings**. The overlay preserves their action targets,
delegates, state and data. It changes the known main-screen backgrounds, cards,
navigation/tab appearance and inert Home branding, and adds a Settings entry for
isolation evidence. Original location simulation, container, identity, Cloud and licence
implementations remain in the preserved programs.
[Proxy input normalization](ProxyInput/README.md) now routes recognized proxy
addresses into the original typed add methods; persistence/transport behavior
stays in the original backend. Their
continued runtime operation is a device acceptance item, not a host-test result.

The app retains its original bundle ID, executable name, app group, extension
IDs, service labels, paths, URL scheme and base version (3.1.0/build 1).
`CFBundleDisplayName` is SocialBox and its existing SocialBox icon is installed.
The package version identifies this derivative independently:
`3.1.0-1+socialbox.2`. Eighteen mapped screens are styled; the exact inert
licence heading is now SocialBox License. Other unmapped branding remains.
See [the screen map](Presentation/RECOVERED_SCREENS.md).

## Build

Load the existing local build environment, then run:

```sh
python3 scripts/build-socialbox-recovered.py /private/path/to/socialbox-3.1.0-1-developer-handoff.zip \
  --theos "$THEOS" --ldid "$LDID" --output /private/path/to/new-candidate-output
```

The builder requires the reviewed ZIP's SHA-256. It validates the entire input
manifest, compiles the arm64/arm64e overlay using Theos/ldid without an Apple
Development Team, and retains every original executable byte and signature.
It verifies all original CodeDirectories leave the changed Info.plist/resources
unsealed; a different input fails instead of being silently re-signed.

Outputs are a private `.deb`, a **read-only preflight**, a narrow rollback
postinst, a deployment-preparation manifest, and a build receipt.
No original maintainer script or binary is executed on the Mac. No service is
contacted and no device installation occurs during the build.

## Deployment boundary

This candidate supports a reviewed **upgrade of the exact installed rootless
3.1.0-1 base on iOS 16+**. It refuses fresh installations, rootful/roothide,
modified originals, unknown old maintainer scripts, and coexistence with the
separate `com.redditbox` package pending a tested migration. It never removes
that package or its data. The current test phone previously had both packages;
its migration is therefore an explicit outstanding step.
The old SocialBox removal scripts stop its daemon and unregister apps; they do
not prove clone/tunnel shutdown or migrate accounts. Removing that package alone
is not a migration. Preserve its sources, containers, licence and Cloud state.

Run the emitted preflight before invoking dpkg: dpkg may execute the installed
old `prerm` before the incoming package's `preinst`. A successful package build
is not permission to bypass that ordering check. Any installed old `preinst` or
`postrm` missing from the handoff must first be recovered and reviewed.

The original postinst has no top-level action guard, so an aborted upgrade could
run its broad cleanup. **Deployment remains blocked until its narrow replacement
is applied separately.** The output manifest gives the exact original/replacement
hashes and backup requirements. Both preflight and incoming preinst require the
reviewed replacement already installed and the exact original backed up in a
root-owned mode-0700 directory, with mode-0600 backup. The builder makes no such
control edits. Foreign parent-directory aliases, writable/non-root parents,
foreign CLI aliases and collisions at new destinations also fail preflight.
Only the rootless bootstrap symlink and the exact supported TweakInject alias
are admitted. This is a strict known-base migration, not a generic installer.

The new maintainer scripts operate only on the three original owned launchd
labels, their original CLI alias, and the exact app path. They do not replay
the original postinst's broad system-daemon kills or cleanup. No account,
keychain, source IPA, container, proxy or licence data is deliberately changed.
Configure and abort-upgrade/remove/deconfigure use the same narrow service
recovery. The inert test harness exercises error-unwind actions as well as the
normal upgrade. These host tests do not establish launchd recovery on iOS.

If presentation alone causes a runtime issue, the added filter/dylib are a
separate reversible layer. Disabling only that filter and relaunching the exact
app restores original presentation; do not remove the original suite, reset
containers, or kill unrelated services. The actual disable/rollback procedure
must be verified against the connected phone's process and package state.
The generated rollback postinst handles dpkg error unwinding only. It is not a
complete post-install rollback. Do not automatically reinstall the original
recovery `.deb`: that archive still contains the original broad maintainer
scripts. Verify a targeted presentation-disable recovery on the phone first.

## What the extra evidence layer means

`LBXRecoveredContextAdapter` reads only already-existing cached UI metadata on
the main thread. It checks the exact host version, classes, getter signatures,
method implementation images, row shapes and a stable selection sample. It
does not call a singleton factory, `loadData`, mutation, RPC or secret getters.

`LBXIsolationViewController` distinguishes unavailable metadata, an observed
empty list, and a cached selection. Refresh does not run an in-app probe. Its
eight runtime evidence families remain **NOT_RUN**. Its support export uses a
fixed whitelist and omits names, IDs, identity values, account/session data,
proxy credentials and licence keys. No launcher observation becomes PASS.

The recovered target-app manager changes its active ID before its path is fully
updated. It has no recovered generation/completed-switch receipt. Therefore
the earlier clone-only sentinel control and receipts cannot be reused as if
they described this app-data-switching architecture. There is **no newly
installed runtime sentinel or added network enforcement** in this candidate.
The original SocialBox sentinel, acceptance tooling and network policies remain
in source and their existing regression suites continue to run.

## Tests

```sh
python3 tools/test_socialbox_recovered.py
python3 lucid/tests/test_recovered_context_adapter.py
bash tools/test_lucid_isolation_assessment.sh
bash lucid/tests/test_proxy_input.sh
python3 tools/static_check.py
python3 tools/test_leak_surface.py
python3 lucid/Presentation/Tests/run_simulator.py --device SIMULATOR_UUID --output NEW_PRIVATE_DIRECTORY
```

The simulator runs the actual overlay and diagnostic view against a synthetic
UIKit host. It cannot execute the original arm64 jailbreak suite, its daemon,
server, target-app hooks or tunnel. Its screenshots are fixture evidence only.

See [the adoption handoff](../docs/socialbox-adoption-handoff.md) for the recovered
feature map, exact static findings and open isolation/network issues. Packaging
the original behavior does not close those issues.
