#!/usr/bin/env python3
"""Exercise the artifact gate with real archive readers and adversarial payloads."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import check_source_socialbox_package as gate

spec = importlib.util.spec_from_file_location("apt_fixture", Path(__file__).with_name("test_apt_release.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
PIN = "a" * 64


def binary(marker=b"", subtypes=(0, 2)):
    parts = [struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, subtype, 2, 0, 0, 0, 0) + marker for subtype in subtypes]
    offset = 8 + 20 * len(parts)
    result = b"\xca\xfe\xba\xbe" + struct.pack(">I", len(parts))
    for subtype, part in zip(subtypes, parts):
        result += struct.pack(">IIIII", 0x100000C, subtype, offset, len(part), 0)
        offset += len(part)
    return result + b"".join(parts)


class SourcePackageTests(unittest.TestCase):
    def test_rejects_wrong_engine_architecture_pin_and_extra_binary(self):
        files = {
            "Applications/RedditBox.app/RedditBox": binary(b"RBXLauncherAppDelegate"),
            "Applications/RedditBoxFirewall.app/RedditBoxFirewall": binary(subtypes=(0,)),
            "Applications/RedditBoxFirewall.app/PlugIns/PacketTunnel.appex/PacketTunnel": binary(subtypes=(0,)),
            "Library/MobileSubstrate/DynamicLibraries/RedditBox.dylib": binary(b"RBXDeviceProfile"),
            "Library/PreferenceBundles/RedditBoxPrefs.bundle/RedditBoxPrefs": binary(b"RBXRootListController"),
            "usr/bin/redditboxd": binary(b"RBXLicenseGuard\0https://redditspoof.vercel.app\0" + PIN.encode()),
            "usr/libexec/redditbox-keychain-cleaner": binary(),
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); pin = root / "pin.h"; pin.write_text('#define RBX_LICENSE_KEY_ID "' + PIN + '"\n')
            package = root / "test.deb"
            for scheme in ("rootless", "rootful"):
                prefix = "var/jb/" if scheme == "rootless" else ""
                original = {prefix + key: value for key, value in files.items()}
                fixture.package_fixture(package, additions=original, scheme=scheme)
                self.assertEqual(len(gate.inspect(package, "1.2.3", pin, scheme)["executables"]), 7)
                faults = [
                    {prefix + "Applications/RedditBox.app/RedditBox": binary(b"SocialBoxEngine")},
                    {prefix + "usr/bin/redditboxd": binary(b"RBXLicenseGuard", (0,))},
                    {prefix + "usr/bin/redditboxd": binary(b"RBXLicenseGuard\0https://redditspoof.vercel.app\0" + b"b" * 64)},
                    {prefix + "Applications/RedditBox.app/extra": binary()},
                    # Unsupported Mach-O variants must not disappear from inventory.
                    *[{prefix + "Applications/RedditBox.app/extra": magic + b"\0" * 64}
                      for magic in (b"\xca\xfe\xba\xbf", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf")],
                    {prefix + "Applications/RedditBox.app/RedditBox": binary(b"RBXLauncherAppDelegate", (0, 0, 2))},
                    {prefix + "Applications/RedditBox.app/RedditBox": binary(b"RBXLauncherAppDelegate\0SBBackendAdapter")},
                ]
                for fault in faults:
                    fixture.package_fixture(package, additions={**original, **fault}, scheme=scheme)
                    with self.assertRaises(ValueError): gate.inspect(package, "1.2.3", pin, scheme)

    def test_truncated_slices_fail_closed(self):
        value = binary(b"fixture")
        for size in (0, 4, 8, 27, len(value) - 1):
            with self.assertRaises((ValueError, struct.error)): gate.slices(value[:size])


if __name__ == "__main__": unittest.main()
