#!/usr/bin/env python3
"""Compile the isolated addon into a unique inert UIKit simulator app.

Never loads SocialBox or contacts a phone/service. Requires an already booted
simulator; installs/removes only this attempt's random synthetic bundle ID.
Repository source hashes exclude SDK/toolchain/host environment and do not
establish production role, loaded-image, device or installation authority.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
INCLUDES = (HERE.parent, REPO / "lucid/Presentation", REPO / "lucid/HelperSafety")
SOURCES = (HERE / "addon_fixture.m", HERE.parent / "SBBlueProgressAddon.m",
           REPO / "lucid/Presentation/SBSwitchProgress.m", REPO / "lucid/HelperSafety/LBXCallerFile.m")
BINDINGS = HERE.parent / "SBBlueProgressBindings.h"


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def input_snapshot():
    """All four translation units, forced bindings, runner and quoted headers."""
    pending, hashes = [*SOURCES, BINDINGS, Path(__file__).resolve()], {}
    while pending:
        path = Path(os.path.abspath(pending.pop()))
        if path in hashes:
            continue
        require(path.is_relative_to(REPO) and path.resolve() == path,
                "Missing, aliased or escaping fixture source")
        node = path.lstat()
        require(stat.S_ISREG(node.st_mode) and node.st_nlink == 1, "Unsafe fixture source node")
        raw = path.read_bytes()
        hashes[path] = digest(raw)
        if path.suffix in (".m", ".h"):
            for name in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', raw.decode(), re.M):
                candidates = [path.parent / name, *(directory / name for directory in INCLUDES)]
                pending.append(next((item for item in candidates if item.is_file()), candidates[0]))
    return {str(path.relative_to(REPO)): value for path, value in sorted(hashes.items())}


class Attempt:
    def __init__(self, output):
        self.output = Path(os.path.abspath(output))
        require(self.output.parent.resolve() == self.output.parent, "Aliased output parent")
        self.output.mkdir(mode=0o700)  # Every existing node, including dangling links, refuses.
        self.rows = []

    def write(self, name, raw):
        require(re.fullmatch(r"[a-z0-9][a-z0-9._-]*", name), "Invalid attempt filename")
        fd = os.open(self.output / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())

    def document(self, name, value):
        self.write(name, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())

    def run(self, name, command, timeout=90, allow_failure=False):
        require(not any(row["name"] == name for row in self.rows), "Duplicate command journal")
        stdout, stderr, code, status = b"", b"", None, "FAILED_TO_START"
        try:
            process = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"})
            stdout, stderr, code = process.stdout, process.stderr, process.returncode
            status = "PASS" if code == 0 else "EXIT_FAILURE"
        except subprocess.TimeoutExpired as error:
            stdout, stderr, status = error.stdout or b"", error.stderr or b"", "TIMEOUT"
            raise
        finally:
            row = {"name": name, "command": list(map(str, command)), "status": status, "returncode": code,
                   "stdoutSHA256": digest(stdout), "stderrSHA256": digest(stderr),
                   "stdoutBytes": len(stdout), "stderrBytes": len(stderr)}
            self.write(name + ".stdout", stdout)
            self.write(name + ".stderr", stderr)
            self.document(name + ".json", row)
            self.rows.append(row)
        require(code == 0 or allow_failure, "Fixture command failed: " + name)
        return stdout.decode().strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Existing booted simulator UUID only")
    parser.add_argument("--output", type=Path, required=True, help="New private attempt directory")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", args.device),
            "Expected explicit simulator UUID")
    attempt = Attempt(args.output)
    identifier = "com.socialbox.blueprogress.fixture." + uuid.uuid4().hex
    before, error, result, installed = None, None, None, False
    cleanup_errors = []
    try:
        before = input_snapshot()
        attempt.document("inputs-before.json", before)
        attempt.document("invocation.json", {"simulator": args.device, "bundleIdentifier": identifier,
            "testOnlyPinsAndMetadata": True, "phoneActions": False, "productionInstallation": "NOT_RUN"})
        devices = json.loads(attempt.run("simulator-inventory", ["/usr/bin/xcrun", "simctl", "list", "devices", "available", "--json"]))
        matches = [(runtime, device) for runtime, rows in devices["devices"].items() for device in rows
                   if device.get("udid", "").lower() == args.device.lower()]
        require(len(matches) == 1 and matches[0][0].startswith("com.apple.CoreSimulator.SimRuntime.iOS-") and
                matches[0][1].get("isAvailable") is True and matches[0][1].get("state") == "Booted",
                "Select exactly one already booted available iOS simulator")
        app = attempt.output / "AddonFixture.app"
        app.mkdir(mode=0o700)
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "AddonFixture", "CFBundleName": "Synthetic blue progress",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1", "CFBundlePackageType": "APPL",
            "LSRequiresIPhoneOS": True, "MinimumOSVersion": "15.0", "UIDeviceFamily": [1], "UILaunchScreen": {}}))
        sdk = attempt.run("sdk-path", ["/usr/bin/xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        require(Path(sdk).is_absolute() and Path(sdk).is_dir(), "Invalid simulator SDK path")
        attempt.run("compile", ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra",
            "-DSB_BLUE_PROGRESS_TESTING=1", "-DLBX_PRESENTATION_FIXTURE=1", "-include", str(BINDINGS),
            "-target", "arm64-apple-ios15.0-simulator", "-isysroot", sdk,
            *("-I" + str(path) for path in INCLUDES), "-framework", "UIKit", "-framework", "Foundation",
            "-framework", "QuartzCore", "-framework", "CoreGraphics", "-Wl,-export_dynamic",
            *map(str, SOURCES), "-o", str(app / "AddonFixture")])
        attempt.run("sign-synthetic-app", ["/usr/bin/codesign", "--force", "--sign", "-", str(app)])
        # Set before invocation so an interrupted/partly failed install is also cleaned up.
        installed = True
        attempt.run("install-unique-app", ["/usr/bin/xcrun", "simctl", "install", args.device, str(app)])
        data = Path(attempt.run("unique-app-data", ["/usr/bin/xcrun", "simctl", "get_app_container", args.device, identifier, "data"]))
        require(data.is_absolute() and data.is_dir(), "Invalid synthetic app data directory")
        attempt.run("launch-unique-app", ["/usr/bin/xcrun", "simctl", "launch", args.device, identifier])
        document = data / "Documents/addon-result.json"
        deadline = time.monotonic() + 45
        while not document.exists() and time.monotonic() < deadline:
            time.sleep(.2)
        require(document.is_file() and not document.is_symlink(), "Synthetic addon fixture did not complete")
        raw = document.read_bytes()
        require(len(raw) <= 2 * 1024 * 1024, "Oversized synthetic result")
        attempt.write("fixture-result.json", raw)
        preview = data / "Documents/addon-preview.png"
        if preview.is_file() and not preview.is_symlink():
            attempt.write("addon-preview.png", preview.read_bytes())
        result = json.loads(raw)
        require(isinstance(result, dict) and result.get("ok") is True and
                type(result.get("assertions")) is int and result["assertions"] > 0 and result.get("failures") == [],
                "Synthetic addon assertions failed")
    except (RuntimeError, OSError, ValueError, UnicodeError, subprocess.SubprocessError, KeyError, TypeError) as failure:
        error = {"type": type(failure).__name__, "message": str(failure)}
    finally:
        if installed:
            for name, operation in (("terminate-unique-app", "terminate"), ("uninstall-unique-app", "uninstall")):
                try:
                    attempt.run(name, ["/usr/bin/xcrun", "simctl", operation, args.device, identifier],
                                timeout=20, allow_failure=(operation == "terminate"))
                except (RuntimeError, OSError, subprocess.SubprocessError) as failure:
                    cleanup_errors.append({"step": name, "type": type(failure).__name__})
        try:
            after = input_snapshot()
            attempt.document("inputs-after.json", after)
            stable = before is not None and before == after
        except (RuntimeError, OSError, UnicodeError) as failure:
            stable = False
            if error is None:error = {"type": type(failure).__name__, "message": str(failure)}
        passed = error is None and stable and not cleanup_errors and result is not None
        final = {"status": "PASS_SYNTHETIC_UI_ONLY" if passed else "FAIL_RETAINED", "sourceStable": stable,
                 "assertions": result.get("assertions") if isinstance(result, dict) else None,
                 "fixture": result, "sourceInputs": before, "commands": attempt.rows,
                 "error": error, "cleanupErrors": cleanup_errors, "phoneActions": False,
                 "productionInstallation": "NOT_RUN", "customerDeliveryReady": False,
                 "limits": "Synthetic UIKit dispatch/lifecycle and source graph only. Explicit test pin/metadata substitutions. "
                           "No production role/image proof, original switch, account, license, service, phone or owner acceptance. "
                           "SDK/tools/host environment are outside the repository graph."}
        attempt.document("result.json", final)
    print(json.dumps({"status": final["status"], "assertions": final["assertions"], "sourceStable": final["sourceStable"]}))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
