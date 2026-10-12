#!/usr/bin/env python3
"""Run the actual identity editor on an already booted simulator.
Optional --output retains synthetic picker screenshots for visual review.

IPC and private draft storage are inert fixtures; UIKit editor code is unchanged.
No daemon, catalog freshness, jailbreak or Facebook activation proof.
"""
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args, env=None):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60,env=env)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", help="An already booted simulator UDID")
    parser.add_argument("--output", type=Path, help="Retain synthetic picker screenshots and results")
    parser.add_argument("--keyboard", action="store_true", help="Require visible Simulator software keyboard and capture its actual layout; does not change host preferences")
    args = parser.parse_args()
    booted = [device for devices in json.loads(run("xcrun", "simctl", "list", "devices", "booted", "-j"))["devices"].values() for device in devices]
    candidates = [device for device in booted if not args.device or device["udid"] == args.device]
    if len(candidates) != 1:
        raise SystemExit("Specify --device for exactly one already booted simulator; this test does not boot or erase devices.")
    device = candidates[0]["udid"]
    identifier = "com.redditbox.identity-test." + uuid.uuid4().hex
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix="rbx-identity-test-") as directory:
            app = Path(directory) / "IdentityTest.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "IdentityTest",
                "CFBundleName": "Identity Test", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL",
                "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0",
                "UIDeviceFamily": [1], "UILaunchScreen": {},
            }))
            sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            run("xcrun", "--sdk", "iphonesimulator", "clang", "-fobjc-arc", "-fblocks",
                "-target", "arm64-apple-ios15.0-simulator", "-isysroot", sdk,
                "-I" + str(ROOT / "launcher"), "-I" + str(ROOT / "shared"),
                "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "QuartzCore", "-framework", "MapKit", "-framework", "CoreLocation",
                str(ROOT / "launcher/RBXIdentityViewController.m"),
                str(ROOT / "launcher/RBXCatalogPickerViewController.m"),
                str(ROOT / "launcher/RBXLocationPickerViewController.m"),
                str(ROOT / "tools/test_identity_editor_fixture.m"), "-o", str(app / "IdentityTest"))
            run("codesign", "--force", "--sign", "-", str(app))
            run("xcrun", "simctl", "install", device, str(app))
            installed = True
            data = Path(run("xcrun", "simctl", "get_app_container", device, identifier, "data"))
            launch_env=os.environ.copy()
            if args.keyboard: launch_env["SIMCTL_CHILD_RBX_TEST_KEYBOARD"]="1"
            run("xcrun", "simctl", "launch", device, identifier,env=launch_env)
            result_file = data / "Documents/identity-result.json"
            deadline = time.monotonic() + 75
            while not result_file.exists() and time.monotonic() < deadline:
                keyboard_ready=data / "Documents/keyboard-ready"
                keyboard_captured=data / "Documents/keyboard-captured"
                if args.keyboard and keyboard_ready.exists() and not keyboard_captured.exists():
                    run("xcrun","simctl","io",device,"screenshot",str(data / "Documents/05a-location-system-keyboard.png"))
                    keyboard_captured.write_text("captured")
                time.sleep(0.25)
            if not result_file.exists():
                raise SystemExit("UIKit identity fixture did not produce a result within 75 seconds.")
            result = json.loads(result_file.read_text())
            print(json.dumps(result, sort_keys=True))
            if args.output:
                args.output.mkdir(parents=True,exist_ok=True)
                for artifact in (data / "Documents").iterdir():
                    if artifact.suffix in (".png", ".json"):
                        shutil.copy2(artifact,args.output / artifact.name)
            if not result.get("ok"):
                raise SystemExit(1)
    finally:
        if installed:
            subprocess.run(["xcrun", "simctl", "terminate", device, identifier], capture_output=True, timeout=15)
            run("xcrun", "simctl", "uninstall", device, identifier)


if __name__ == "__main__":
    main()
