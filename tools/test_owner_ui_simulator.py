#!/usr/bin/env python3
"""Accept the composed owner profile's layout or loader with an inert UIKit host.

Only the simulator is used. The exact candidate graph is observed before and
after; the real overlay is never loaded, and no phone/engine/account is touched.
"""
import argparse
import json
from pathlib import Path
import plistlib
import time
import uuid

import build_socialbox_owner_ui as owner


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--device", required=True, help="Already booted simulator UUID")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--progress", action="store_true", help="Test the original-shaped loader only, never a switch")
    args = parser.parse_args()
    report = owner.verification.json_object(owner.read(args.candidate / "build-report.json", 2 * 1024 * 1024))
    owner.require(report.get("status") == "PASS" and report.get("ownerInstallAccepted") is False, "Not a private passing composition")
    source = args.candidate / "source"
    expected = report["provenance"]["composedGraph"]
    def snapshot():
        files = {name: owner.read(source / name, 2 * 1024 * 1024) for name in expected["sha256"]}
        return owner.graph(files)
    owner.require(snapshot() == expected, "Candidate graph no longer matches report")
    fixture = owner.ROOT / "lucid/Presentation/Tests" / ("switch_progress_fixture.m" if args.progress else "layout_fixture.m")
    controls = {str(fixture.relative_to(owner.ROOT)): owner.digest(owner.read(fixture, 2 * 1024 * 1024)),
                "tools/test_owner_ui_simulator.py": owner.digest(owner.read(Path(__file__).resolve(), 2 * 1024 * 1024)),
                **owner.contracts()}
    if args.progress:
        for name in ("lucid/Presentation/Tests/activation_transport_fixture.h", "lucid/Presentation/Tests/saved_setup_transport_fixture.h",
                     "tools/owner_progress_transport_fixture.m"):
            controls[name] = owner.digest(owner.read(owner.ROOT / name, 2 * 1024 * 1024))
    journal = owner.verification.Journal(args.output)
    identifier = "com.socialbox.owner.layout." + uuid.uuid4().hex
    installed = False
    try:
        journal.document("inputs-before.json", {"candidate": expected, "controls": controls})
        app = journal.directory / "OwnerLayoutFixture.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
            "CFBundleName": "Inert owner UI fixture", "CFBundleVersion": "1", "CFBundleShortVersionString": "1",
            "CFBundlePackageType": "APPL", "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0",
            "UIDeviceFamily": [1], "UILaunchScreen": {}}))
        sdk, _ = journal.run("sdk", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        names = (("SBSwitchProgress.m", "SBBackendAdapter.m", "SBDesign.m", "SBInterfaceCopy.m") if args.progress else
                 ("SBContainersView.m", "SBWorkspaceCoordinator.m", "SBBackendAdapter.m", "SBDesign.m", "SBInterfaceCopy.m"))
        sources = [source / "lucid/Presentation" / name for name in names]
        if args.progress:
            sources.append(owner.ROOT / "tools/owner_progress_transport_fixture.m")
        journal.run("compile", ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-DSB_BACKEND_ADAPTER_TESTING=1", *(["-DLBX_PRESENTATION_FIXTURE=1", "-Wl,-export_dynamic"] if args.progress else []),
            "-target", "arm64-apple-ios15.0-simulator", "-isysroot", sdk.decode().strip(),
            "-I" + str(source / "lucid/Presentation"), "-I" + str(source / "lucid/Diagnostics"),
            "-framework", "UIKit", "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "CoreGraphics",
            *map(str, sources), str(fixture), "-o", str(app / "Fixture")])
        journal.run("sign", ["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
        journal.run("install", ["/usr/bin/xcrun", "simctl", "install", args.device, str(app)])
        installed = True
        container, _ = journal.run("container", ["/usr/bin/xcrun", "simctl", "get_app_container", args.device, identifier, "data"])
        documents = Path(container.decode().strip()) / "Documents"
        journal.run("launch", ["/usr/bin/xcrun", "simctl", "launch", args.device, identifier])
        deadline = time.monotonic() + 30
        result_name = "presentation-result.json" if args.progress else "layout-result.json"
        result = documents / result_name
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(.1)
        outcome = owner.verification.json_object(owner.read(result, 2 * 1024 * 1024))
        journal.write(result_name, owner.read(result, 2 * 1024 * 1024))
        screenshots = ["switch-progress-preview.png"] if args.progress else [case["name"] + ".png" for case in outcome["cases"]]
        for name in screenshots:
            owner.require("/" not in name and ".." not in name, "Unexpected screenshot name")
            journal.write(name, owner.read(documents / name, 16 * 1024 * 1024))
        owner.require(snapshot() == expected and all(owner.digest(owner.read(owner.ROOT / name, 2 * 1024 * 1024)) == value
                       for name, value in controls.items()), "Fixture/candidate inputs changed")
        owner.require(outcome.get("ok") is True and (args.progress or outcome.get("backendOperations") == 0), "Composed owner UIKit failed")
        # Complete cleanup before publishing PASS. A failed uninstall is not a
        # passing acceptance, and an uncertain cleanup is never retried here.
        installed = False
        journal.run("uninstall", ["/usr/bin/xcrun", "simctl", "uninstall", args.device, identifier])
        journal.document("result.json", {"status": "PASS", "assertions": outcome["assertions"], "cases": len(screenshots),
            "sourceStable": True, "candidateGraph": expected, "controls": controls, "phoneAction": False,
            "scope": "Actual composed UI and accepted adapter with inert UIKit host: loader only" if args.progress else
                "Actual composed Containers/accepted adapter/workspace UIKit; seven synthetic viewports, no original engine action or phone acceptance."})
        print(json.dumps({"status": "PASS", "assertions": outcome["assertions"], "cases": len(screenshots)}))
    except BaseException as error:
        journal.document("failure.json", {"status": "FAIL", "error": type(error).__name__ + ": " + str(error)})
        raise
    finally:
        try:
            if installed:
                # Uninstall our unique inert simulator fixture; never an owner app.
                journal.run("uninstall", ["/usr/bin/xcrun", "simctl", "uninstall", args.device, identifier])
        finally:
            journal.close()


if __name__ == "__main__":
    main()
