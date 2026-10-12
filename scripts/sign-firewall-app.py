#!/usr/bin/env python3
"""Sign the unsigned iOS firewall product using Procursus ldid only."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
from typing import Optional


class SigningError(RuntimeError):
    pass


THIN = {b"\xce\xfa\xed\xfe": "<", b"\xcf\xfa\xed\xfe": "<",
        b"\xfe\xed\xfa\xce": ">", b"\xfe\xed\xfa\xcf": ">"}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
       b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}


def macho_architectures(path):
    """Read each slice's CPU/subtype/file type; inspect every signed slice later."""
    size = path.stat().st_size
    with path.open("rb") as source:
        header = source.read(32)
        magic = header[:4]
        if magic not in THIN and magic not in FAT:
            return []

        def thin_at(offset, length):
            if length < 28 or offset < 0 or offset + length > size:
                raise SigningError("Invalid Mach-O slice: %s" % path)
            source.seek(offset)
            value = source.read(28)
            endian = THIN.get(value[:4])
            if not endian or len(value) != 28:
                raise SigningError("Invalid Mach-O header: %s" % path)
            return struct.unpack(endian + "III", value[4:16])

        if magic in THIN:
            return [thin_at(0, size)]
        endian, fat64 = FAT[magic]
        if len(header) < 8:
            raise SigningError("Truncated universal Mach-O: %s" % path)
        count = struct.unpack(endian + "I", header[4:8])[0]
        if not 1 <= count <= 32:
            raise SigningError("Invalid universal architecture count: %s" % path)
        entry_size = 32 if fat64 else 20
        source.seek(8)
        table = source.read(count * entry_size)
        if len(table) != count * entry_size:
            raise SigningError("Truncated universal architecture table: %s" % path)
        result = []
        for index in range(count):
            entry = table[index * entry_size:(index + 1) * entry_size]
            if fat64:
                cpu, subtype, offset, length, _, _ = struct.unpack(endian + "IIQQII", entry)
            else:
                cpu, subtype, offset, length, _ = struct.unpack(endian + "IIIII", entry)
            actual = thin_at(offset, length)
            if actual[:2] != (cpu, subtype) or actual[:2] in [item[:2] for item in result]:
                raise SigningError("Inconsistent universal architecture table: %s" % path)
            result.append(actual)
        return result


def read_plist(path):
    try:
        with path.open("rb") as source:
            value = plistlib.load(source)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise SigningError("Cannot read plist %s: %s" % (path, error)) from error
    if not isinstance(value, dict):
        raise SigningError("Expected a dictionary plist: %s" % path)
    return value


@dataclass
class Target:
    path: Path
    binary: Path
    entitlements: Optional[Path]
    expected: dict
    architectures: list
    bundle: bool


def signing_plan(app, root):
    """Validate the complete product before letting any signer mutate it."""
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise SigningError("Expected a real unsigned .app directory")
    app = app.resolve()
    contents = sorted(app.rglob("*"))
    # Xcode iOS products have flat bundles. Do not traverse external code or
    # silently sign a versioned/symlinked bundle using an ambiguous executable.
    if any(path.is_symlink() for path in contents):
        raise SigningError("Symlinks are not supported in this iOS signing product")
    policies = {
        "com.redditbox.firewall": root / "network-extension/FirewallHost/RedditBoxFirewall.entitlements",
        "com.redditbox.firewall.PacketTunnel": root / "network-extension/PacketTunnel/PacketTunnel.entitlements",
    }
    targets = []
    binaries = set()
    provider_count = 0
    bundles = [app] + [path for path in contents if path.is_dir() and
        (path.suffix in (".app", ".appex", ".framework", ".xpc", ".bundle") or
         (path / "Info.plist").is_file())]
    for bundle in bundles:
        info_path = bundle / "Info.plist"
        if not info_path.is_file():
            raise SigningError("Bundle has no Info.plist: %s" % bundle)
        info = read_plist(info_path)
        executable = info.get("CFBundleExecutable")
        if not executable and bundle.suffix == ".bundle":
            continue  # A resource-only bundle needs no executable signature.
        if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in (".", ".."):
            raise SigningError("Invalid CFBundleExecutable: %s" % bundle)
        binary = bundle / executable
        if not binary.is_file():
            raise SigningError("Bundle executable is missing: %s" % binary)
        identifier = info.get("CFBundleIdentifier")
        entitlements = None
        if bundle == app:
            if identifier != "com.redditbox.firewall":
                raise SigningError("Unexpected firewall host bundle identifier")
            entitlements = policies[identifier]
        elif bundle.suffix == ".appex":
            if (bundle.parent != app / "PlugIns" or
                identifier != "com.redditbox.firewall.PacketTunnel" or
                info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.networkextension.app-proxy"):
                raise SigningError("Unknown extension entitlement policy: %s" % bundle)
            provider_count += 1
            entitlements = policies[identifier]
        elif bundle.suffix != ".framework":
            raise SigningError("Unknown code bundle entitlement policy: %s" % bundle)
        architectures = macho_architectures(binary)
        expected_type = 6 if bundle.suffix == ".framework" else 2
        if not architectures or any(item[2] != expected_type for item in architectures):
            raise SigningError("Unexpected bundle Mach-O type: %s" % binary)
        expected = read_plist(entitlements) if entitlements else {}
        if entitlements:
            required = {
                "application-identifier": "RBXBOXCFG." + identifier,
                "com.apple.developer.team-identifier": "RBXBOXCFG",
                "com.apple.developer.networking.networkextension": ["app-proxy-provider"],
                "com.apple.security.application-groups": ["group.com.redditbox.firewall"],
            }
            if any(expected.get(key) != value for key, value in required.items()):
                raise SigningError("Missing or changed required firewall entitlement policy: %s" % entitlements)
        targets.append(Target(bundle, binary, entitlements, expected, architectures, True))
        binaries.add(binary)
    if provider_count != 1:
        raise SigningError("The firewall host must embed exactly one known provider")
    for path in contents:
        if not path.is_file() or path in binaries:
            continue
        architectures = macho_architectures(path)
        if not architectures:
            continue
        if path.suffix != ".dylib" or any(item[2] != 6 for item in architectures):
            raise SigningError("Unknown standalone Mach-O entitlement policy: %s" % path)
        targets.append(Target(path, path, None, {}, architectures, False))
    # A library inside a framework/extension sorts ahead of its enclosing bundle;
    # all nested bundle seals are finalized before the host is signed last.
    return sorted(targets, key=lambda target: (-len(target.path.parts), str(target.path)))


def sign_app(app, root, ldid, runner=subprocess.run):
    plan = signing_plan(Path(app), Path(root))

    def run(arguments):
        try:
            return runner([str(ldid)] + arguments, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except subprocess.CalledProcessError as error:
            detail = (error.stderr or b"").decode("utf-8", errors="replace").strip()
            raise SigningError("ldid failed: %s" % detail) from error

    usage = run([])
    help_text = (usage.stdout + usage.stderr).decode("utf-8", errors="replace")
    if not re.search(r"(?m)^\s*-w\b", help_text):
        raise SigningError("Procursus ldid with shallow bundle signing (-w) is required")
    for target in plan:
        arguments = ["-w"] if target.bundle else []
        arguments.append("-S" + (str(target.entitlements) if target.entitlements else ""))
        run(arguments + [str(target.path)])
        if target.bundle:
            read_plist(target.path / "_CodeSignature/CodeResources")
        for cpu, subtype, _ in target.architectures:
            effective = run(["-A%d:%d" % (cpu, subtype), "-e", str(target.binary)]).stdout
            try:
                actual = plistlib.loads(effective) if effective.strip() else {}
            except (ValueError, plistlib.InvalidFileException) as error:
                raise SigningError("Cannot decode effective entitlements: %s" % target.binary) from error
            if actual != target.expected:
                raise SigningError("Effective entitlements differ for %s (CPU %d:%d)" %
                                   (target.binary, cpu, subtype))
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--ldid", default="ldid")
    arguments = parser.parse_args()
    try:
        plan = sign_app(arguments.app, Path(__file__).resolve().parents[1], arguments.ldid)
    except (OSError, SigningError) as error:
        parser.exit(1, "Firewall signing failed: %s\n" % error)
    print("Signed and inspected %d code targets using ldid." % len(plan))


if __name__ == "__main__":
    main()
