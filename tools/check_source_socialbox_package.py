#!/usr/bin/env python3
"""Verify the source-built package's identities, binaries and license pin.

This is an artifact boundary check, not proof of device isolation or a claim
that repository history is unrelated to earlier compatibility work.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import apt_repository as apt

MACH_MAGICS = {bytes.fromhex(value) for value in (
    "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    "feedface", "cefaedfe", "feedfacf", "cffaedfe",
)}


def slices(data):
    if data[:4] == b"\xcf\xfa\xed\xfe":
        return [data]
    apt.require(data[:4] == b"\xca\xfe\xba\xbe", "Expected a compiled Mach-O")
    count = struct.unpack_from(">I", data, 4)[0]
    apt.require(1 <= count <= 8 and 8 + count * 20 <= len(data), "Invalid fat header")
    result = []
    for index in range(count):
        _, _, offset, length, _ = struct.unpack_from(">IIIII", data, 8 + index * 20)
        apt.require(length >= 32 and offset >= 8 + count * 20 and offset + length <= len(data), "Invalid slice extent")
        part = data[offset:offset + length]
        apt.require(part[:4] == b"\xcf\xfa\xed\xfe", "Expected a 64-bit slice")
        result.append(part)
    return result


def inspect(path, version, pin_header, scheme="rootless"):
    result = apt.inspect_package(path, version, ROOT / "layout/DEBIAN", scheme)
    prefix = "var/jb/" if scheme == "rootless" else ""
    expected = {
        "Applications/RedditBox.app/RedditBox": b"RBXLauncherAppDelegate",
        "Applications/RedditBoxFirewall.app/RedditBoxFirewall": None,
        "Applications/RedditBoxFirewall.app/PlugIns/PacketTunnel.appex/PacketTunnel": None,
        "Library/MobileSubstrate/DynamicLibraries/RedditBox.dylib": b"RBXDeviceProfile",
        "Library/PreferenceBundles/RedditBoxPrefs.bundle/RedditBoxPrefs": b"RBXRootListController",
        "usr/bin/redditboxd": b"RBXLicenseGuard",
        "usr/libexec/redditbox-keychain-cleaner": None,
    }
    pin = re.search(r'^#define RBX_LICENSE_KEY_ID "([a-f0-9]{64})"$', pin_header.read_text(), re.M)
    apt.require(pin is not None, "Missing generated public pin")
    _, payload, _, _ = apt.package_control(path)
    found = {}
    for name, member, archive in apt.tar_entries(payload):
        if not member.isfile():
            continue
        data = apt.read_member(archive, member, apt.MAX_PACKAGE)
        if data[:4] not in MACH_MAGICS:
            continue
        relative = name.removeprefix(prefix)
        apt.require(relative in expected and relative not in found, "Unexpected executable payload: " + name)
        parts = slices(data)
        architectures = []
        for part in parts:
            cpu, subtype = struct.unpack_from("<II", part, 4)
            apt.require(cpu == 0x100000C, "Unexpected CPU")
            apt.require((subtype & 0xFFFFFF) in (0, 2), "Unexpected ARM subtype")
            architecture = "arm64e" if (subtype & 0xFFFFFF) == 2 else "arm64"
            apt.require(architecture not in architectures, "Duplicate architecture slice")
            architectures.append(architecture)
            marker = expected[relative]
            apt.require(not marker or marker in part, "Missing source-owned implementation marker: " + name)
            for foreign in (b"SocialBoxEngine", b"SocialBoxLicense", b"SecretSauce", b"LBXWorkspace", b"SBBackendAdapter", b"socialbox.example.com"):
                apt.require(foreign not in part, "Recovered engine/adapter reference in " + name)
            if relative == "usr/bin/redditboxd":
                apt.require(pin.group(1).encode() in part, "Daemon does not contain the deployment public pin")
                apt.require(b"https://redditspoof.vercel.app" in part, "Own cloud origin missing")
        if not relative.startswith("Applications/RedditBoxFirewall.app/"):
            apt.require(set(architectures) == {"arm64", "arm64e"}, "Both supported source architectures are required: " + name)
        found[relative] = {"sha256": hashlib.sha256(data).hexdigest(), "architectures": architectures}
    apt.require(set(found) == set(expected), "Missing source-built executable")
    return {"packageSHA256": result["sha256"], "version": version, "scheme": scheme,
            "implementation": "source-owned launcher, daemon and tweak; no recovered binaries",
            "licenseKeyID": pin.group(1), "executables": found, "deviceAcceptance": "NOT_RUN"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--pin-header", type=Path, required=True)
    parser.add_argument("--scheme", choices=("rootless", "rootful"), default="rootless")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = inspect(args.package, args.version, args.pin_header, args.scheme)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + "\n")
        print("PASS: seven source-built components, deployment pin and package boundary; device acceptance is separate")
    except (ValueError, OSError, struct.error) as error:
        parser.exit(1, str(error) + "\n")
