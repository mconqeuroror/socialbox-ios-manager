#!/usr/bin/env python3
"""Build only the private capture-only native storage fence probe; never execute it."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import build_native_storage_inventory as native

ENTRY = "lucid/Switching/NativeStorageFenceProbe.m"
native.SOURCES = [ENTRY, "lucid/Switching/LBXNativeStorageLayout.m",
                  "lucid/Switching/LBXNativeStorageFence.m", "lucid/Switching/LBXNativeApplicationGate.m"] + [
    path for path in native.SOURCES if path != "lucid/Switching/NativeStorageInventoryProbe.m"
]
FORBIDDEN_SELECTORS = (
    b"closeAllBeforeDeadline:", b"openContainerID:", b"restoreExecutionBeforeDeadline:",
    b"closeExecutionBeforeDeadline:", b"closeAndDrainBeforeDeadline:", b"recoverFromJournal:",
    b"compareRecord:", b"restoreOriginalExecutionForUnstartedProbe:",
)


def closure():
    inputs = native.closure()
    inputs[str(Path(__file__).resolve().relative_to(native.ROOT))] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    return inputs


def verify_entry(binary: Path):
    data = binary.read_bytes()
    if any(selector in data for selector in FORBIDDEN_SELECTORS):
        raise RuntimeError("Capture entry references a transaction mutation selector")
    undefined = native.run("xcrun", "nm", "-u", binary).decode()
    forbidden = r"_(?:chmod|fchmod|chown|fchown|chflags|fchflags|kill|posix_spawn|fork|system|dlopen|dlsym|NSSelectorFromString)$"
    if any(re.search(forbidden, line.strip()) for line in undefined.splitlines()):
        raise RuntimeError("Capture entry references a forbidden direct effect or dynamic lookup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ldid", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink() or not args.ldid.is_file():
        raise SystemExit("Fresh output and existing ldid required")
    output.mkdir(mode=0o700)
    before = closure()
    sdk = native.run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").decode().strip()
    flags = ["-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations"]
    slices = []
    for arch in ("arm64", "arm64e"):
        common = ["xcrun", "clang", "-target", arch + "-apple-ios15.0", "-isysroot", sdk, *flags]
        entry = output / ("capture-entry-" + arch + ".o")
        native.run(*common, "-c", native.ROOT / ENTRY, "-o", entry)
        verify_entry(entry)
        binary = output / ("native-storage-fence-probe-" + arch)
        native.run(*common, "-I" + str(native.ROOT / "shared"), "-framework", "Foundation", "-framework", "Security",
                   *[native.ROOT / path for path in native.SOURCES], "-o", binary)
        slices.append(binary)
    binary = output / "native-storage-fence-probe"
    native.run("xcrun", "lipo", "-create", *slices, "-output", binary)
    identifier = "com.socialbox.native-storage-fence-capture-probe"
    native.run("codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier,
               "--requirements", '=designated => identifier "' + identifier + '"', binary)
    native.run("codesign", "--verify", "--strict", "--all-architectures", binary)
    for arch in ("arm64", "arm64e"):
        thin = output / ("signed-" + arch)
        native.run("xcrun", "lipo", binary, "-thin", arch, "-output", thin)
        if native.run(args.ldid, "-e", thin).strip():
            raise RuntimeError("Unexpected capture-probe entitlement")
        native.run("codesign", "--verify", "--strict", thin)
    data = binary.read_bytes()
    if re.search(rb"test[A-Za-z0-9_]+:", data) or b"restoreOriginalExecutionForUnstartedProbe:" in data:
        raise RuntimeError("Fixture or private recovery selector in production probe")
    if before != closure():
        raise RuntimeError("Source changed during capture-probe build")
    report = {"kind": "native-storage-fence-capture-only", "status": "PASS", "architectures": ["arm64", "arm64e"],
              "binarySHA256": hashlib.sha256(data).hexdigest(), "binaryBytes": len(data), "sourceSHA256": before,
              "entitlements": {}, "entryMutationSelectorsAbsent": True, "deviceExecution": "NOT_RUN",
              "codePermissionsChanged": False, "storagePermissionsChanged": False, "selectionChanged": False,
              "processesTerminated": 0, "accountFileContentsRead": False, "accountNamesExported": False,
              "journalPublicationInvoked": False, "runtimeAccepted": False, "safeToGate": False,
              "fixedSessionScope": "/private/var/root/socialbox-native-storage-capture-probes/<lowercase UUID>",
              "invocation": "native-storage-fence-probe FRESH_EXISTING_0700_ROOT_SESSION_DIRECTORY",
              "outputFilename": "capture-status.json", "journalChild": "journal", "retainedJournalRecord": False}
    target = output / "build-report.json"
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    target.chmod(0o600)
    print("PASS: signed arm64/arm64e capture-only probe; entry mutation selectors absent; device NOT_RUN")


if __name__ == "__main__":
    main()
