"""Exercise both generated installation layouts, preserving user data and IDs."""
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from package_variant import prepare, variant


class PackageVariants(unittest.TestCase):
    def test_both_generated_installations(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("layout", "daemon", "scripts"):
                shutil.copytree(ROOT / name, root / name)
            originals = {path: path.read_bytes() for path in (root / "layout/DEBIAN").iterdir() if path.is_file()}
            for scheme in ("rootless", "rootful"):
                output = prepare(root, scheme)
                prefix = variant(scheme)["prefix"]
                launch = plistlib.loads((output / "com.redditbox.daemon.plist").read_bytes())
                self.assertEqual(launch["Program"], prefix + "/usr/bin/redditboxd")
                self.assertEqual(launch["Label"], "com.redditbox.daemon")
                for name in ("postinst", "prerm", "postrm"):
                    script = (output / "layout/DEBIAN" / name).read_text(encoding="utf-8")
                    self.assertNotIn("/var/mobile/", script)
                    self.assertNotIn("uicache -a", script)
                    if scheme == "rootful": self.assertNotIn("/var/jb", script)
                self.assertIn('PLIST=' + prefix + '/Library/LaunchDaemons/$SERVICE.plist',
                              (output / "layout/DEBIAN/postinst").read_text(encoding="utf-8"))
                self.assertIn(prefix + '/Applications/RedditBox.app', (output / 'on-device-smoke.sh').read_text(encoding="utf-8"))
                self.assertIn('/var/mobile/Library/Preferences/com.redditbox.profiles',
                              (output / 'on-device-smoke.sh').read_text(encoding="utf-8"))
            self.assertTrue(all(path.read_bytes() == data for path, data in originals.items()))

    def test_invalid_scheme_has_no_output(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with self.assertRaises(ValueError): prepare(root, "rootful;command")
            self.assertEqual(list(root.iterdir()), [])

    def test_build_and_runtime_select_same_variant(self):
        build = (ROOT / 'scripts/build-mac.sh').read_text(encoding="utf-8")
        for token in ('THEOS_PACKAGE_ARCH="$PACKAGE_ARCH"', 'THEOS_LAYOUT_DIR="$VARIANT_INPUTS/layout"',
                      'RBX_PACKAGE_SCHEME="$RBX_PACKAGE_SCHEME"', 'RBX_VARIANT_INPUTS="$VARIANT_INPUTS"'):
            self.assertIn(token, build)
        paths = (ROOT / 'shared/RBXInstallPaths.h').read_text(encoding="utf-8")
        self.assertIn('ROOT_PATH_NS_VAR(rootfulPath)', paths)
        self.assertIn('return rootfulPath;', paths)
        self.assertNotIn('fileExistsAtPath', paths)
        for source in ('main.m', 'RBXCloneManager.m', 'RBXCloudSync.m', 'RBXProcessController.m', 'RBXDeviceCatalog.m'):
            self.assertIn('RBXInstalledPath(', (ROOT / 'daemon' / source).read_text(encoding="utf-8"))


if __name__ == '__main__':
    unittest.main()
