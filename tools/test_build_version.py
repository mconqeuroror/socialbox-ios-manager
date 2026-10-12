"""Exercise generated build inputs and package upgrade boundaries."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_version", ROOT / "scripts/build-version.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildVersionTests(unittest.TestCase):
    def test_releases_stamp_generated_resources_and_preserve_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ["control", "launcher/Resources/Info.plist", "daemon/RBXCloneManager.m",
                         "scripts/provision-profile.sh", "daemon/RBXKeychainCleaner.entitlements",
                         "shared/RBXProfileIdentifier.h", "shared/RBXInstallPaths.h", "build-scheme.mk",
                         "shared/RBXAppRegistry.h", "shared/RBXAppRegistryData.h", "cloud/src/config/app-registry.json", "shared/RBXAppBundlePolicy.h", "shared/RBXAppKeychainPolicy.h", "shared/RBXAppLifecycle.h", "shared/RBXCloneSupportDirectory.h", "shared/RBXStagedExecutable.h"]:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes((ROOT / name).read_bytes())
            original = (root / "launcher/Resources/Info.plist").read_bytes()
            first = module.prepare(root, "1.2.3")
            self.assertTrue(first["requiresMDMReadoption"])
            second = module.prepare(root, "1.2.4", first["signingContractHash"])
            self.assertFalse(second["requiresMDMReadoption"])
            info = plistlib.loads((root / "build/generated/launcher-resources/Info.plist").read_bytes())
            self.assertEqual(info["CFBundleVersion"], "1.2.4")
            self.assertEqual(info["CFBundleShortVersionString"], "1.2.4")
            self.assertEqual(info["CFBundleIdentifier"], "com.redditbox.launcher")
            self.assertEqual(info["CFBundleDisplayName"], "SocialBox")
            self.assertEqual((root / "launcher/Resources/Info.plist").read_bytes(), original)
            # Signing inputs moved into descriptors; changing any source of
            # those values must invalidate a previously authenticated contract.
            for name in ["shared/RBXAppRegistry.h", "shared/RBXAppRegistryData.h", "cloud/src/config/app-registry.json", "shared/RBXAppBundlePolicy.h", "shared/RBXAppKeychainPolicy.h", "shared/RBXAppLifecycle.h", "shared/RBXCloneSupportDirectory.h", "shared/RBXStagedExecutable.h"]:
                before = (root / name).read_bytes()
                (root / name).write_bytes(before + b"\n ")
                with self.subTest(signing_input=name):
                    self.assertTrue(module.prepare(root, "1.2.5", first["signingContractHash"])["requiresMDMReadoption"])
                (root / name).write_bytes(before)
            with (root / "scripts/provision-profile.sh").open("ab") as output:
                output.write(b"\n# signing contract changed\n")
            self.assertTrue(module.prepare(root, "1.2.5", first["signingContractHash"])["requiresMDMReadoption"])

    def test_version_rejects_unsafe_or_noncanonical_values(self):
        for value in ["1.2", "01.2.3", "1.2.3\n", "1.2.3;touch file", "1.2.3-beta", "-1.0.0", "10000.0.0"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.version(value)

    def test_upgrade_scripts_never_clean_container_data_or_refresh_all_icons(self):
        for path in ["layout/DEBIAN/postinst", "layout/DEBIAN/prerm", "layout/DEBIAN/postrm", "launcher/Makefile"]:
            source = (ROOT / path).read_text()
            for forbidden in ["uicache -a", "/var/mobile/Library/RedditBox", "com.redditbox.profiles", "com.redditbox.profile."]:
                self.assertNotIn(forbidden, source, path)
        postinst = (ROOT / "layout/DEBIAN/postinst").read_text()
        self.assertLess(postinst.index('bootout "system/$SERVICE"'), postinst.index('bootstrap system "$PLIST"'))
        self.assertNotIn('kickstart -k "system/$SERVICE"', postinst)
        self.assertIn("daemon did not stay running", postinst)


if __name__ == "__main__":
    unittest.main()
