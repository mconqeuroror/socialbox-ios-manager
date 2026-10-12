#!/usr/bin/env python3
"""Build only; never run or install the private shared-group writer probe."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import build_native_storage_inventory as native

native.SOURCES = ["lucid/Switching/SharedGroupWriterProbe.m"] + [
    path for path in native.SOURCES if path != "lucid/Switching/NativeStorageInventoryProbe.m"
]


def closure():
    sources = native.closure()
    sources[str(Path(__file__).resolve().relative_to(native.ROOT))] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ldid", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.absolute()
    output.mkdir(mode=0o700, exist_ok=False)
    before = closure()
    sdk = native.run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").decode().strip()
    slices = []
    for architecture in ("arm64", "arm64e"):
        binary = output / ("shared-group-writer-inventory-" + architecture)
        native.run("xcrun", "clang", "-target", architecture + "-apple-ios15.0", "-isysroot", sdk,
                   "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations",
                   "-I" + str(native.ROOT / "shared"), "-framework", "Foundation", "-framework", "Security",
                   *[native.ROOT / path for path in native.SOURCES], "-o", binary)
        slices.append(binary)
    binary = output / "shared-group-writer-inventory"
    native.run("xcrun", "lipo", "-create", *slices, "-output", binary)
    identifier = "com.socialbox.shared-group-writer-inventory"
    native.run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier,
               "--requirements", '=designated => identifier "' + identifier + '"', binary)
    native.run("codesign", "--verify", "--strict", "--all-architectures", binary)
    data = binary.read_bytes()
    if native.run(args.ldid, "-e", binary).strip() or re.search(rb"test[A-Za-z0-9_]+:", data):
        raise RuntimeError("Unexpected entitlement or fixture selector")
    if before != closure():
        raise RuntimeError("Source changed during build")
    report = {"status": "PASS", "kind": "read-only-shared-group-writer-inventory", "architectures": ["arm64", "arm64e"],
              "binarySHA256": hashlib.sha256(data).hexdigest(), "binaryBytes": len(data), "sourceSHA256": before,
              "entitlements": {}, "deviceExecution": "NOT_RUN", "accountFileContentsRead": False,
              "completeSharedWriters": False, "safeToGate": False,
              "invocation": "shared-group-writer-inventory PHYSICAL_ROOT_OWNED_0700_OUTPUT_DIRECTORY",
              "outputFilename": "shared-group-writer-inventory.json"}
    target = output / "build-report.json"
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    target.chmod(0o600)
    print("PASS: source-stable signed arm64/arm64e shared-writer probe; device execution NOT_RUN")


if __name__ == "__main__":
    main()
