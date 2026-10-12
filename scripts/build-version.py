#!/usr/bin/env python3
"""Prepare versioned build inputs without modifying tracked source resources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_variant import variant


def version(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]{0,3})", value):
        raise ValueError("Version must be canonical X.Y.Z with components from 0 through 9999")
    return value


def prepare(root, requested=None, previous=None, scheme="rootless"):
    package = variant(scheme)
    control = (root / "control").read_text(encoding="utf-8")
    release_version = version(requested or re.search(r"^Version: (.+)$", control, re.M)[1].strip())
    if previous and not re.fullmatch(r"[0-9a-f]{64}", previous):
        raise ValueError("Previous signing contract must be an authenticated SHA-256 digest")
    inputs = ["daemon/RBXCloneManager.m", "shared/RBXAppRegistry.h",
              "shared/RBXAppRegistryData.h", "cloud/src/config/app-registry.json", "shared/RBXAppBundlePolicy.h", "shared/RBXAppKeychainPolicy.h",
              "shared/RBXAppLifecycle.h",
              "shared/RBXCloneSupportDirectory.h", "shared/RBXStagedExecutable.h",
              "scripts/provision-profile.sh",
              "daemon/RBXKeychainCleaner.entitlements", "shared/RBXProfileIdentifier.h",
              "shared/RBXInstallPaths.h", "build-scheme.mk"]
    digest = hashlib.sha256(b"redditbox-clone-signing-contract-v1\0")
    digest.update(scheme.encode() + b"\0")
    for relative in inputs:
        data = (root / relative).read_bytes()
        digest.update(relative.encode() + b"\0" + str(len(data)).encode() + b"\0" + data)
    contract = digest.hexdigest()
    output = root / "build/generated"
    output.mkdir(parents=True, exist_ok=True)
    resources = output / "launcher-resources"
    shutil.copytree(root / "launcher/Resources", resources, dirs_exist_ok=True)
    info = plistlib.loads((resources / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.redditbox.launcher":
        raise ValueError("Launcher bundle ID changed; preserve the installed identity")
    info.update(CFBundleShortVersionString=release_version, CFBundleVersion=release_version)
    (resources / "Info.plist").write_bytes(plistlib.dumps(info))
    document = {"version": release_version, "schemaVersion": 2,
                "signingContractHash": contract, "requiresMDMReadoption": previous != contract,
                "packageScheme": scheme, "packageArchitecture": package["architecture"], "installPrefix": package["prefix"]}
    (output / "release.json").write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--version", default=os.environ.get("RBX_RELEASE_VERSION"))
    args = parser.parse_args()
    result = prepare(args.root.resolve(), args.version, os.environ.get("RBX_PREVIOUS_SIGNING_CONTRACT_HASH"),
                     os.environ.get("RBX_PACKAGE_SCHEME", "rootless"))
    print(result["version"])


if __name__ == "__main__":
    main()
