#!/usr/bin/env python3
"""Build a PRIVATE visual-only addon for the exact previously accepted owner UI.

Never installs or replaces the full overlay. Only the existing progress source,
narrow isolated bindings and renamed read-only file observer are linked. Fresh
owner inspection/quiescence/backup/relaunch and device acceptance remain required.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))
from verify_socialbox_presentation import Journal, read_regular, digest, symbols, require
from enumerate_leak_binary import MachO, macho_slices

SOURCES = ("lucid/ProgressAddon/SBBlueProgressAddon.m",
           "lucid/Presentation/SBSwitchProgress.m", "lucid/HelperSafety/LBXCallerFile.m")
BINDINGS = "lucid/ProgressAddon/SBBlueProgressBindings.h"
PYTHON_INPUTS = ("scripts/build-socialbox-progress-addon.py",
                 "tools/verify_socialbox_presentation.py", "tools/enumerate_leak_binary.py")
IDENTIFIER = "com.socialbox.progress.blue"
REQUIRED = {"SBBlueProgressAddonInstall", "SBBlueProgressInstallCore", "SBBlueProgressAppMetadata",
            "SBBlueProgressMetadataSupported", "SBBlueProgressScreen", "SBBlueProgressPanel",
            "SBBlueProgressVerifyFile"}
FORBIDDEN = (b"SBBlueProgressFixture", b"SBSwitchProgressFixture", b"LBXLicense", b"SBActivationView",
             b"LBXContainerRootMutationCoordinator")


def snapshot():
    pending = [ROOT / name for name in (*SOURCES, BINDINGS, *PYTHON_INPUTS)]
    hashes = {}
    while pending:
        path = Path(os.path.abspath(pending.pop()))
        require(path.is_relative_to(ROOT), "Escaping addon source")
        name = str(path.relative_to(ROOT))
        if name in hashes:
            continue
        raw = read_regular(path, 2 * 1024 * 1024)
        hashes[name] = digest(raw)
        if path.suffix in (".m", ".h"):
            for target in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', raw.decode(), re.M):
                pending.append(path.parent / target)
    return dict(sorted(hashes.items()))


def validate_exports(values):
    require(all(values.get("_" + name) == "T" for name in REQUIRED), "Missing isolated addon export")
    require(values.get("_OBJC_CLASS_$_SBBlueProgressGlyph") in ("D", "S"), "Missing isolated glyph class")
    require(all(name.startswith(("_SBBlueProgress", "_OBJC_CLASS_$_SBBlueProgressGlyph",
                                "_OBJC_METACLASS_$_SBBlueProgressGlyph",
                                "_OBJC_IVAR_$_SBBlueProgressGlyph.")) for name in values),
            "Unexpected full-presentation or foreign export")
    require(not any("fixture" in name.lower() or "testing" in name.lower() for name in values),
            "Synthetic provider export")


def build(args, journal):
    before = snapshot()
    ldid = Path(os.path.abspath(args.ldid))
    ldid_raw = read_regular(ldid, 32 * 1024 * 1024)
    require(ldid.stat().st_mode & 0o111, "Entitlement tool is not executable")
    journal.document("inputs-before.json", before)
    sdk_raw, _ = journal.run("sdk", ["/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
    sdk = sdk_raw.decode("utf-8").strip()
    require(sdk.startswith("/") and "\n" not in sdk and Path(sdk).is_dir(), "Invalid SDK path")
    thin_paths = []
    for arch in ("arm64", "arm64e"):
        output = journal.directory / ("build-" + arch + ".dylib")
        journal.run(arch + "-compile", ["/usr/bin/xcrun", "--sdk", "iphoneos", "clang",
            "-arch", arch, "-miphoneos-version-min=15.0", "-isysroot", sdk,
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-dynamiclib",
            "-include", str(ROOT / BINDINGS), "-framework", "UIKit", "-framework", "Foundation",
            "-framework", "QuartzCore", "-framework", "CoreGraphics",
            *[str(ROOT / name) for name in SOURCES], "-o", str(output)])
        thin_paths.append(output)
    overlay = journal.directory / "SBBlueProgress.dylib"
    journal.run("universal", ["/usr/bin/xcrun", "lipo", "-create", *map(str, thin_paths), "-output", str(overlay)])
    requirement = '=identifier "' + IDENTIFIER + '"'
    journal.run("sign-final", ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
        "--identifier", IDENTIFIER, "--requirements", '=designated => identifier "' + IDENTIFIER + '"', str(overlay)])
    journal.run("fat-strict", ["/usr/bin/codesign", "--verify", "--strict", "--all-architectures",
                              "--test-requirement", requirement, str(overlay)])
    raw = read_regular(overlay, 32 * 1024 * 1024)
    slices = {}
    for _, part in macho_slices(raw):
        macho = MachO(part)
        arch = {0: "arm64", 2: "arm64e"}.get(macho.subtype & 0xffffff)
        require(macho.cpu == 0x100000c and arch and arch not in slices, "Unexpected addon slice")
        require(macho.filetype == 6 and sum(c["command"] == "0x1d" for c in macho.commands) == 1,
                "Addon must be an embedded-signed dylib")
        # LBXPresentationInstall is an intentional dlsym NAME for old loaded-image
        # observation, never a linked implementation/export or invoked callback.
        require(not any(marker in part for marker in FORBIDDEN),
                "Full UI/licensing/testing implementation marker")
        slices[arch] = part
    require(set(slices) == {"arm64", "arm64e"}, "Expected exactly two addon slices")
    results = []
    for arch, part in sorted(slices.items()):
        name = "signed-" + arch + ".dylib"
        journal.write(name, part)
        thin = journal.directory / name
        journal.run(arch + "-strict", ["/usr/bin/codesign", "--verify", "--strict",
                                      "--test-requirement", requirement, str(thin)])
        _, details = journal.run(arch + "-details", ["/usr/bin/codesign", "--display", "--verbose=4", str(thin)])
        require(details.decode().splitlines().count("Signature=adhoc") == 1, "Ad-hoc observation missing")
        entitlements, _ = journal.run(arch + "-entitlements", [str(ldid), "-e", str(thin)])
        require(not entitlements.strip(), "Unexpected addon entitlements")
        exported, _ = journal.run(arch + "-exports", ["/usr/bin/xcrun", "nm", "-gU", str(thin)])
        values = symbols(exported)
        validate_exports(values)
        results.append({"architecture": arch, "sliceSHA256": digest(part), "exportedSymbols": values})
    after = snapshot()
    journal.document("inputs-after.json", after)
    require(before == after and read_regular(overlay, 32 * 1024 * 1024) == raw and
            read_regular(ldid, 32 * 1024 * 1024) == ldid_raw and
            all(read_regular(journal.directory / ("signed-" + arch + ".dylib"), 32 * 1024 * 1024) == part
                for arch, part in slices.items()), "Addon source/tool/artifact drift")
    # Exact same fixed manager filter, new allowlisted filenames only. No scripts,
    # initializer, package, automatic installer or replacement owner payload.
    filters = plistlib.dumps({"Filter": {"Bundles": ["com.socialbox.app"]}})
    journal.write("SBBlueProgress.plist", filters)
    return {"schemaVersion": 1, "status": "PASS_PRIVATE_ADDON_NOT_INSTALLED",
        "sourceSHA256": before, "linkedTranslationUnits": list(SOURCES),
        "overlaySHA256": digest(raw), "overlaySize": len(raw), "filterSHA256": digest(filters),
        "identifier": IDENTIFIER, "slices": results, "ldidSHA256": digest(ldid_raw), "toolSteps": journal.rows,
        "requiredOwnerProfile": {"managerSHA256": "e230dab07690e30c292962a3c0a3ea8301f9532aaa583a7209fdf33142552dd0",
            "managerSize": 9490320, "existingOverlaySHA256": "a0423c7c92dbbe49b700bce7605fa7a9edb9e1d2cf5d70bb9d658137f78972d8",
            "existingOverlaySize": 1145968, "realUID": 501, "effectiveUID": 0},
        "ownerInstallation": "NOT_RUN", "deviceTrust": "NOT_RUN", "customerDeliveryReady": False,
        "scope": "Isolated namespaced visual artwork hook only. Current disk/role/loaded image-path checks; "
                 "no mapped-byte attestation. Full new overlay presence refuses. Fresh quiescence/backup/witnessed "
                 "relaunch and actual owner acceptance required. No package or first-install/runtime grant.",
        "excludedInputs": "macOS/SDK/compiler/Xcode/ldid execution trust and environment; ldid bytes recorded only"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ldid", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    journal = None
    try:
        journal = Journal(args.output)
        report = build(args, journal)
        journal.document("result.json", report)
        print(json.dumps({"status": report["status"], "overlaySHA256": report["overlaySHA256"],
                          "ownerInstallation": "NOT_RUN"}))
        return 0
    except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        if journal:
            journal.document("failure.json", {"status": "FAIL_RETAINED", "error": str(error), "toolSteps": journal.rows})
        print("Private visual addon build refused; no device or owner replacement.", file=sys.stderr)
        return 1
    finally:
        if journal:
            journal.close()


if __name__ == "__main__":
    raise SystemExit(main())
