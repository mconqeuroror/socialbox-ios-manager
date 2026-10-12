#!/usr/bin/env python3
"""Exercise the actual proxy-import UI on an explicitly selected booted simulator.

Private storage and daemon IPC are inert fixtures. This does not touch a phone,
real proxy, clipboard, license, container, or production account.
"""
import argparse
import json
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()


parser = argparse.ArgumentParser()
parser.add_argument("--device", required=True)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
booted = json.loads(run("xcrun", "simctl", "list", "devices", "booted", "-j"))
if not any(device["udid"] == args.device for group in booted["devices"].values() for device in group):
    raise SystemExit("The selected simulator must already be booted.")
identifier = "com.socialbox.proxy-import-fixture." + uuid.uuid4().hex
installed = False
try:
    with tempfile.TemporaryDirectory(prefix="socialbox-proxy-ui-") as temporary:
        app = Path(temporary) / "ProxyImportFixture.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "ProxyImportFixture",
            "CFBundleName": "Proxy UI fixture", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL",
            "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0", "UIDeviceFamily": [1],
            "UILaunchScreen": {},
        }))
        sdk = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
        run("xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wno-nullability-completeness",
            "-Wno-incomplete-implementation", "-target", "arm64-apple-ios15.0-simulator",
            "-isysroot", sdk, "-I" + str(ROOT / "launcher"), "-I" + str(ROOT / "shared"),
            "-framework", "UIKit", "-framework", "Foundation", "-framework", "CFNetwork", "-framework", "QuartzCore",
            str(ROOT / "launcher/RBXProxiesViewController.m"),
            str(ROOT / "shared/RBXProxyLibrary.m"), str(ROOT / "shared/RBXHTTPProxy.m"),
            str(ROOT / "tools/test_proxy_import_ui.m"), "-o", str(app / "ProxyImportFixture"))
        run("codesign", "--force", "--sign", "-", str(app))
        run("xcrun", "simctl", "install", args.device, str(app))
        installed = True
        data = Path(run("xcrun", "simctl", "get_app_container", args.device, identifier, "data"))
        run("xcrun", "simctl", "launch", args.device, identifier)
        result = data / "Documents/proxy-import-result.json"
        deadline = time.monotonic() + 40
        while not result.exists() and time.monotonic() < deadline:
            time.sleep(0.25)
        if not result.exists():
            raise RuntimeError("Proxy UI fixture did not finish; inspect simulator crash output.")
        args.output.mkdir(parents=True, exist_ok=True)
        for artifact in (data / "Documents").iterdir():
            shutil.copy2(artifact, args.output / artifact.name)
        report = json.loads(result.read_text())
        print(json.dumps(report))
        if not report["ok"]:
            raise SystemExit(1)
finally:
    if installed:
        subprocess.run(["xcrun", "simctl", "terminate", args.device, identifier], capture_output=True, timeout=15)
        run("xcrun", "simctl", "uninstall", args.device, identifier)
