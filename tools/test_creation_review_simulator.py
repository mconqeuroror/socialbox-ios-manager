#!/usr/bin/env python3
"""Test the pre-create presentation with inert original-shaped UIKit entries.

No original engine, account, phone, license or identity writer is loaded. A
unique simulator fixture is uninstalled before a passing result is published.
"""
import argparse
import json
from pathlib import Path
import plistlib
import time
import uuid
import verify_socialbox_presentation as review

ROOT = Path(__file__).resolve().parents[1]
NAMES = ("SBContainersView.m", "SBWorkspaceCoordinator.m", "SBBackendAdapter.m", "SBDesign.m", "SBInterfaceCopy.m",
         "SBContainersView.h", "SBWorkspaceCoordinator.h", "SBBackendAdapter.h", "SBDesign.h", "SBInterfaceCopy.h")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Already booted simulator UUID")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, help="Private composed source; never installed as an overlay")
    args = parser.parse_args()
    source = args.candidate / "source" if args.candidate else ROOT
    paths = [source / "lucid/Presentation" / name for name in NAMES]
    paths += [ROOT / "lucid/Presentation/Tests/creation_review_fixture.m", ROOT / "lucid/Diagnostics/LBXIsolationViewController.h",
              Path(__file__).resolve(), ROOT / "tools/verify_socialbox_presentation.py"]
    def snapshot():
        return {str(path): review.digest(review.read_regular(path, 2 * 1024 * 1024)) for path in paths}
    before = snapshot()
    if args.candidate:
        report = review.json_object(review.read_regular(args.candidate / "build-report.json", 2 * 1024 * 1024))
        if report.get("status") != "PASS" or report.get("ownerInstallAccepted") is not False:
            raise ValueError("Not a passing private candidate")
        for name, digest in report["provenance"]["composedGraph"]["sha256"].items():
            if review.digest(review.read_regular(source / name, 2 * 1024 * 1024)) != digest:
                raise ValueError("Candidate graph differs")
            paths.append(source / name)
        before = snapshot()
    journal = review.Journal(args.output)
    identifier = "com.socialbox.creation.review." + uuid.uuid4().hex
    installed = False
    try:
        journal.document("inputs-before.json", before)
        app = journal.directory / "CreationReviewFixture.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
            "CFBundleName": "Inert creation review", "CFBundleVersion": "1", "CFBundleShortVersionString": "1",
            "CFBundlePackageType": "APPL", "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0", "UIDeviceFamily": [1], "UILaunchScreen": {}}))
        sdk, _ = journal.run("sdk", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        journal.run("compile", ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-DSB_BACKEND_ADAPTER_TESTING=1", "-target", "arm64-apple-ios15.0-simulator", "-isysroot", sdk.decode().strip(),
            "-I" + str(source / "lucid/Presentation"), "-I" + str(ROOT / "lucid/Diagnostics"),
            "-framework", "UIKit", "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "CoreGraphics",
            *map(str, paths[:5]), str(ROOT / "lucid/Presentation/Tests/creation_review_fixture.m"), "-o", str(app / "Fixture")])
        journal.run("sign", ["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
        journal.run("install", ["/usr/bin/xcrun", "simctl", "install", args.device, str(app)])
        installed = True
        container, _ = journal.run("container", ["/usr/bin/xcrun", "simctl", "get_app_container", args.device, identifier, "data"])
        documents = Path(container.decode().strip()) / "Documents"
        journal.run("launch", ["/usr/bin/xcrun", "simctl", "launch", args.device, identifier])
        result = documents / "creation-review-result.json"
        deadline = time.monotonic() + 40
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(.1)
        raw = review.read_regular(result, 2 * 1024 * 1024)
        outcome = review.json_object(raw)
        journal.write("creation-review-result.json", raw)
        for name in ("creation-review.png", "creation-review-actions.png", "creation-review-large-text.png"):
            journal.write(name, review.read_regular(documents / name, 16 * 1024 * 1024))
        journal.document("inputs-after.json", snapshot())
        if snapshot() != before or outcome.get("ok") is not True:
            raise ValueError("Creation review fixture/input stability failed")
        installed = False
        journal.run("uninstall", ["/usr/bin/xcrun", "simctl", "uninstall", args.device, identifier])
        journal.document("result.json", {"status": "PASS", "assertions": outcome["assertions"], "inputsStable": True,
            "phoneAction": False, "originalEngineLoaded": False, "scope": "Pre-create current-value review, cancel, existing settings entry and explicit creation entry, with inert original-shaped controls."})
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
