#!/usr/bin/env python3
"""Build a private, read-only arm64/arm64e inventory probe. Never installs it."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "lucid/Switching/NativeStorageInventoryProbe.m",
    "lucid/Switching/LBXNativeStorageInventory.m",
    "lucid/Switching/LBXNativeIsolationJournal.m",
    "lucid/Switching/LBXInstalledApplicationBinding.m",
    "lucid/Switching/LBXDarwinDrainBackend.m",
    "lucid/Switching/LBXProcessDrain.m",
    "lucid/Switching/LBXManagedApplications.m",
    "shared/RBXProcessIdentity.m",
]


def run(*arguments):
    result = subprocess.run(list(map(str, arguments)), cwd=ROOT, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace")[:6000] or "Native build failed")
    return result.stdout


def closure():
    pending, seen = set(SOURCES + [str(Path(__file__).resolve().relative_to(ROOT))]), {}
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
    parser.add_argument("--ldid", required=True, type=Path, help="Existing signer, used only to inspect entitlements")
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink() or not args.ldid.is_file() or not os.access(args.ldid, os.X_OK):
        raise SystemExit("Fresh output and an existing executable ldid are required")
    output.mkdir(mode=0o700)
    before = closure()
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").decode().strip()
    slices = []
    for architecture in ("arm64", "arm64e"):
        binary = output / f"native-storage-inventory-{architecture}"
        run("xcrun", "clang", "-target", architecture + "-apple-ios15.0", "-isysroot", sdk,
            "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
            "-I" + str(ROOT / "shared"), "-framework", "Foundation", "-framework", "Security",
            *[ROOT / name for name in SOURCES], "-o", binary)
        slices.append(binary)
    binary = output / "native-storage-inventory"
    run("xcrun", "lipo", "-create", *slices, "-output", binary)
    identifier = "com.socialbox.native-storage-inventory"
    run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier,
        "--requirements", '=designated => identifier "' + identifier + '"', binary)
    run("codesign", "--verify", "--strict", "--all-architectures", binary)
    if run(args.ldid, "-e", binary).strip():
        raise RuntimeError("Unexpected production probe entitlements")
    data = binary.read_bytes()
    if re.search(rb"test[A-Za-z0-9_]+:", data):
        raise RuntimeError("Fixture selector in production binary")
    if before != closure():
        raise RuntimeError("Sources changed during build")
    report = {"kind": "native-original-instagram-storage-inventory", "status": "PASS",
              "architectures": ["arm64", "arm64e"], "minimumIOS": "15.0", "entitlements": {},
              "binarySHA256": hashlib.sha256(data).hexdigest(), "binaryBytes": len(data),
              "sourceSHA256": before, "deviceExecution": "NOT_RUN", "accountFileContentsRead": False,
              "runtimeAccepted": False, "safeToGate": False,
              "invocation": "native-storage-inventory PHYSICAL_ROOT_OWNED_0700_OUTPUT_DIRECTORY",
              "outputFilename": "native-storage-inventory.json"}
    target = output / "build-report.json"
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    target.chmod(0o600)
    print("PASS: source-stable signed arm64/arm64e inventory probe; device execution NOT_RUN")


if __name__ == "__main__":
    main()
