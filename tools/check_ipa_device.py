#!/usr/bin/env python3
"""Read-only IPA/device metadata preflight. Never edit thinning restrictions.

Use the PHYSICAL device and OS, not a container's generated identity. Passing
this check is not binary, resource, signature, launch or isolation acceptance.
"""
import argparse
import json
from pathlib import PurePosixPath
import plistlib
import re
import zipfile


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid physical/minimum OS version")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def inspect(ipa, device, os_version):
    if not re.fullmatch(r"(?:iPhone|iPad|iPod)\d+,\d+", device):
        raise ValueError("Supply the physical Apple device model identifier")
    physical_os = version(os_version)
    issues = []
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or any(
                PurePosixPath(n).is_absolute() or ".." in PurePosixPath(n).parts or "\\" in n
                for n in names):
            raise ValueError("Ambiguous or escaping ZIP paths")
        roots = [n for n in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
        if len(roots) != 1:
            raise ValueError("Exactly one main application is required")
        root = roots[0].removesuffix("Info.plist")
        targets = [roots[0]] + sorted(n for n in names if n.startswith(root + "PlugIns/")
                                     and re.fullmatch(re.escape(root) + r"PlugIns/[^/]+\.appex/Info\.plist", n))
        main = None
        for name in targets:
            if archive.getinfo(name).file_size > 4 * 1024 * 1024:
                raise ValueError("Unreasonably large bundle metadata")
            info = plistlib.loads(archive.read(name))
            if not isinstance(info, dict) or not isinstance(info.get("CFBundleIdentifier"), str):
                raise ValueError("Bundle identifier metadata is missing")
            if main is None:
                main = info
            supported = info.get("UISupportedDevices")
            if supported is not None:
                if not isinstance(supported, list) or not supported or any(not isinstance(x, str) for x in supported):
                    raise ValueError("Malformed UISupportedDevices restriction")
                if device not in supported:
                    issues.append({"bundleID": info["CFBundleIdentifier"], "reason": "device_variant_mismatch"})
            if "MinimumOSVersion" in info and version(info["MinimumOSVersion"]) > physical_os:
                issues.append({"bundleID": info["CFBundleIdentifier"], "reason": "physical_os_too_old"})
    return {"status": "BLOCKED" if issues else "METADATA_COMPATIBLE",
            "bundleID": main["CFBundleIdentifier"], "physicalDevice": device,
            "physicalOS": os_version, "bundlesChecked": len(targets), "issues": issues,
            "remediation": "Obtain this app for the current physical device; do not erase device restrictions to claim compatibility." if issues else None,
            "runtimeAndIsolation": "NOT_VERIFIED", "archiveModified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa")
    parser.add_argument("--device", required=True)
    parser.add_argument("--ios", required=True)
    args = parser.parse_args()
    try:
        result = inspect(args.ipa, args.device, args.ios)
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        print(json.dumps({"status": "INVALID", "reason": str(error), "archiveModified": False}))
        return 2
    print(json.dumps(result, indent=2))
    return 1 if result["issues"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
