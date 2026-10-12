#!/usr/bin/env python3
"""Run the update UIKit flow with intercepted URL opens and local responses."""
import argparse
import json
from pathlib import Path
import plistlib
import time
import uuid
import verify_socialbox_presentation as review

ROOT = Path(__file__).resolve().parents[1]
NAMES = ("SBUpdateService.m", "SBDesign.m", "SBInterfaceCopy.m", "SBUpdateService.h",
         "SBDesign.h", "SBInterfaceCopy.h", "SBBackendAdapter.h")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Already booted simulator UUID")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, help="Private composed source; never installed as an overlay")
    args = parser.parse_args()
    source = args.candidate / "source" if args.candidate else ROOT
    fixture = ROOT / "lucid/Presentation/Tests/update_ui_fixture.m"
    paths = [source / "lucid/Presentation" / name for name in NAMES]
    paths += [fixture, Path(__file__).resolve(), ROOT / "tools/verify_socialbox_presentation.py"]
    if args.candidate:
        report = review.json_object(review.read_regular(args.candidate / "build-report.json", 2 * 1024 * 1024))
        if report.get("status") != "PASS" or report.get("ownerInstallAccepted") is not False:
            raise ValueError("Not a passing private candidate")
        for name, digest in report["provenance"]["composedGraph"]["sha256"].items():
            if review.digest(review.read_regular(source / name, 2 * 1024 * 1024)) != digest:
                raise ValueError("Candidate graph differs")
            paths.append(source / name)
    def snapshot():
        return {str(path): review.digest(review.read_regular(path, 2 * 1024 * 1024)) for path in paths}
    before = snapshot()
    journal = review.Journal(args.output)
    identifier = "com.socialbox.update.ui." + uuid.uuid4().hex
    installed = False
    try:
        journal.document("inputs-before.json", before)
        app = journal.directory / "UpdateUIFixture.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
            "CFBundleName": "Inert update UI", "CFBundleVersion": "1", "CFBundleShortVersionString": "1",
            "SocialBoxBuild": "3.1.0-1+socialbox.15", "CFBundlePackageType": "APPL", "LSRequiresIPhoneOS": True,
            "MinimumOSVersion": "15.0", "UIDeviceFamily": [1], "UILaunchScreen": {}}))
        sdk, _ = journal.run("sdk", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        journal.run("compile", ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-target", "arm64-apple-ios15.0-simulator", "-isysroot", sdk.decode().strip(),
            "-I" + str(source / "lucid/Presentation"), "-framework", "UIKit", "-framework", "Foundation",
            "-framework", "QuartzCore", "-framework", "CoreGraphics", *map(str, paths[:3]), str(fixture), "-o", str(app / "Fixture")])
        journal.run("sign", ["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
        journal.run("install", ["/usr/bin/xcrun", "simctl", "install", args.device, str(app)])
        installed = True
        container, _ = journal.run("container", ["/usr/bin/xcrun", "simctl", "get_app_container", args.device, identifier, "data"])
        documents = Path(container.decode().strip()) / "Documents"
        journal.run("launch", ["/usr/bin/xcrun", "simctl", "launch", args.device, identifier])
        result = documents / "update-ui-result.json"
        deadline = time.monotonic() + 50
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(.1)
        raw = review.read_regular(result, 2 * 1024 * 1024)
        outcome = review.json_object(raw)
        journal.write("update-ui-result.json", raw)
        journal.write("update-ui.png", review.read_regular(documents / "update-ui.png", 16 * 1024 * 1024))
        after = snapshot()
        journal.document("inputs-after.json", after)
        if after != before or outcome.get("ok") is not True:
            raise ValueError("Update UI fixture/input stability failed")
        journal.run("uninstall", ["/usr/bin/xcrun", "simctl", "uninstall", args.device, identifier])
        installed = False
        journal.document("result.json", {"status": "PASS", "assertions": outcome["assertions"], "inputsStable": True,
            "phoneAction": False, "originalEngineLoaded": False, "externalURLLaunch": False, "productionNetwork": False,
            "scope": "UIKit update screen, manual check, package-manager fallback, closed release gate and alert dismissal."})
        print(json.dumps({"status": "PASS", "assertions": outcome["assertions"]}))
    except BaseException as error:
        journal.document("failure.json", {"status": "FAIL", "error": type(error).__name__ + ": " + str(error)})
        raise
    finally:
        try:
            if installed:
                journal.run("uninstall", ["/usr/bin/xcrun", "simctl", "uninstall", args.device, identifier])
        finally:
            journal.close()


if __name__ == "__main__":
    main()
