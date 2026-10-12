#!/usr/bin/env python3
"""Run shipped selector containment on an already booted simulator, no screenshots.

Only workspace controller bodies are inert fixtures; RBXLauncherAppDelegate.m,
registry and selector code compile unchanged. No daemon, jailbreak or MDM proof.
"""
import argparse
import json
import plistlib
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", help="An already booted simulator UDID")
    parser.add_argument("--facebook-capability", choices=("current", "active", "inactive"), default="current", help="Use an isolated registry copy to exercise either capability state")
    args = parser.parse_args()
    booted = [device for devices in json.loads(run("xcrun", "simctl", "list", "devices", "booted", "-j"))["devices"].values() for device in devices]
    candidates = [device for device in booted if not args.device or device["udid"] == args.device]
    if len(candidates) != 1:
        raise SystemExit("Specify --device for exactly one already booted simulator; this test does not boot or erase devices.")
    device = candidates[0]["udid"]
    identifier = "com.redditbox.selector-test." + uuid.uuid4().hex
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix="rbx-selector-test-") as directory:
            app = Path(directory) / "SelectorTest.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": "SelectorTest",
                "CFBundleName": "Selector Test", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL",
                "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0",
                "UIDeviceFamily": [1], "UILaunchScreen": {},
            }))
            fixture_shared = Path(directory) / "shared"
            fixture_shared.mkdir()
            for name in ("RBXAppRegistry.h", "RBXAppRegistryData.h"):
                (fixture_shared / name).write_bytes((ROOT / "shared" / name).read_bytes())
            if args.facebook_capability != "current":
                import re
                registry = fixture_shared / "RBXAppRegistryData.h"
                before, facebook = registry.read_text().split('@"appType": @"facebook",', 1)
                facebook, count = re.subn(r'@"runnable": @(YES|NO),', '@"runnable": @' + ("YES" if args.facebook_capability == "active" else "NO") + ',', facebook, count=1)
                assert count == 1
                registry.write_text(before + '@"appType": @"facebook",' + facebook)
            sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            run("xcrun", "--sdk", "iphonesimulator", "clang", "-fobjc-arc", "-fblocks",
                "-target", "arm64-apple-ios15.0-simulator", "-isysroot", sdk,
                "-I" + str(ROOT / "launcher"), "-I" + str(fixture_shared),
                "-framework", "UIKit", "-framework", "Foundation", "-framework", "CoreGraphics",
                str(ROOT / "launcher/RBXLauncherAppDelegate.m"),
                str(ROOT / "tools/test_launcher_selector_fixture.m"), "-o", str(app / "SelectorTest"))
            run("codesign", "--force", "--sign", "-", str(app))
            run("xcrun", "simctl", "install", device, str(app))
            installed = True
            data = Path(run("xcrun", "simctl", "get_app_container", device, identifier, "data"))
            run("xcrun", "simctl", "launch", device, identifier)
            result_file = data / "Documents/selector-result.json"
            deadline = time.monotonic() + 30
            while not result_file.exists() and time.monotonic() < deadline:
                time.sleep(0.25)
            if not result_file.exists():
                raise SystemExit("UIKit selector fixture did not produce a result within 30 seconds.")
            result = json.loads(result_file.read_text())
            print(json.dumps(result, sort_keys=True))
            if not result.get("ok"):
                raise SystemExit(1)
    finally:
        if installed:
            subprocess.run(["xcrun", "simctl", "terminate", device, identifier], capture_output=True, timeout=15)
            run("xcrun", "simctl", "uninstall", device, identifier)


if __name__ == "__main__":
    main()
