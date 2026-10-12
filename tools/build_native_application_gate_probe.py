#!/usr/bin/env python3
"""Build the private root application-gate probe; never installs or executes it."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "lucid/Switching/NativeApplicationGateProbe.m",
    "lucid/Switching/LBXNativeApplicationGate.m",
    "lucid/Switching/LBXNativeIsolationJournal.m",
    "lucid/Switching/LBXInstalledApplicationBinding.m",
    "lucid/Switching/LBXDarwinDrainBackend.m",
    "lucid/Switching/LBXProcessDrain.m",
    "lucid/Switching/LBXManagedApplications.m",
    "shared/RBXProcessIdentity.m",
]
ENTITLEMENTS = "lucid/Switching/ProcessDrain.entitlements"
EXPECTED_ENTITLEMENTS = {"platform-application": True, "com.apple.runningboard.terminateprocess": True}


def run(*arguments):
    result = subprocess.run(list(map(str, arguments)), cwd=ROOT, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:6000] or "Native build failed")
    return result.stdout


def closure():
    pending = set(SOURCES + [ENTITLEMENTS, str(Path(__file__).resolve().relative_to(ROOT))])
    seen = {}
    while pending:
        name = pending.pop()
        path = ROOT / name
        if not path.is_file() or path.resolve() != path:
            raise RuntimeError("Missing or aliased source")
        data = path.read_bytes()
        seen[name] = hashlib.sha256(data).hexdigest()
        for target in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', data.decode(), re.M):
            candidates = [path.parent / target, ROOT / "shared" / target, ROOT / "daemon" / target]
            dependency = next((Path(os.path.abspath(p)) for p in candidates if p.is_file()), None)
            if dependency is None or not dependency.is_relative_to(ROOT):
                raise RuntimeError("Missing or escaping dependency")
            relative = str(dependency.relative_to(ROOT))
            if relative not in seen:
                pending.add(relative)
    return dict(sorted(seen.items()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="Fresh private build directory")
    parser.add_argument("--ldid", required=True, type=Path, help="Existing signer used to inspect final entitlements")
    parser.add_argument("--enable-unstarted-abort-recovery", action="store_true",
                        help="Private emergency build: restore only journal-proven unstarted probe original code")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink() or not args.ldid.is_file() or not os.access(args.ldid, os.X_OK):
        raise SystemExit("Fresh output and an existing executable ldid are required")
    if plistlib.loads((ROOT / ENTITLEMENTS).read_bytes()) != EXPECTED_ENTITLEMENTS:
        raise SystemExit("Unexpected entitlement scope")
    output.mkdir(mode=0o700)
    before = closure()
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").decode().strip()
    slices = []
    for architecture in ("arm64", "arm64e"):
        binary = output / f"native-application-gate-probe-{architecture}"
        run("xcrun", "clang", "-target", architecture + "-apple-ios15.0", "-isysroot", sdk,
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
            *(["-DLBX_PRIVATE_GATE_ABORT_RECOVERY=1"] if args.enable_unstarted_abort_recovery else []),
            "-I" + str(ROOT / "shared"), "-framework", "Foundation", "-framework", "Security",
            *[ROOT / name for name in SOURCES], "-o", binary)
        slices.append(binary)
    binary = output / "native-application-gate-probe"
    run("xcrun", "lipo", "-create", *slices, "-output", binary)
    identifier = "com.socialbox.native-application-gate-probe"
    run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier,
        "--entitlements", ROOT / ENTITLEMENTS,
        "--requirements", '=designated => identifier "' + identifier + '"', binary)
    run("codesign", "--verify", "--strict", "--all-architectures", binary)
    for architecture in ("arm64", "arm64e"):
        thin = output / f"signed-{architecture}"
        run("xcrun", "lipo", binary, "-thin", architecture, "-output", thin)
        if plistlib.loads(run(args.ldid, "-e", thin)) != EXPECTED_ENTITLEMENTS:
            raise RuntimeError("Signed entitlement scope mismatch")
        run("codesign", "--verify", "--strict", thin)
    data = binary.read_bytes()
    if re.search(rb"test[A-Za-z0-9_]+:", data):
        raise RuntimeError("Fixture selector in production binary")
    if before != closure():
        raise RuntimeError("Sources changed during build")
    report = {"kind": "native-original-instagram-execution-gate-probe", "status": "PASS",
              "architectures": ["arm64", "arm64e"], "minimumIOS": "15.0", "entitlements": EXPECTED_ENTITLEMENTS,
              "binarySHA256": hashlib.sha256(data).hexdigest(), "binaryBytes": len(data),
              "sourceSHA256": before, "deviceExecution": "NOT_RUN", "probeAccountFileContentsRead": False,
              "storagePermissionsChanged": False, "selectionChanged": False, "runtimeIsolationAccepted": False,
              "fixedJournalScope": "/private/var/root/socialbox-native-gate-probes/<lowercase UUID>",
              "exercise": "native-application-gate-probe exercise FRESH_EXISTING_0700_ROOT_JOURNAL_DIRECTORY",
              "recover": "native-application-gate-probe recover SAME_EXACT_JOURNAL_DIRECTORY",
              "journalRetained": True, "unexpectedSpawn": "suspended child cleanup plus fresh captured root drain"}
    report["privateUnstartedAbortRecoveryEnabled"] = args.enable_unstarted_abort_recovery
    if args.enable_unstarted_abort_recovery:
        report["abortUnstarted"] = "native-application-gate-probe abort-unstarted SAME_EXACT_PREPARED_PROBE_JOURNAL_DIRECTORY"
    target = output / "build-report.json"
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    target.chmod(0o600)
    print("PASS: source-stable signed arm64/arm64e execution gate probe; device execution NOT_RUN")


if __name__ == "__main__":
    main()
