"""Actual OpenSSL key generation/public-pin tests. No production secrets touched."""
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("license_key", ROOT / "scripts/license-key.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
OPENSSL = os.environ.get("OPENSSL") or shutil.which("openssl")
if not OPENSSL and os.name == "nt":
    candidate = Path("C:/Program Files/Git/usr/bin/openssl.exe")
    if candidate.exists():
        OPENSSL = str(candidate)


class SigningSetup(unittest.TestCase):
    def test_public_only_roundtrip_and_no_overwrite(self):
        self.assertTrue(OPENSSL, "OpenSSL is required for actual key tests")
        with tempfile.TemporaryDirectory() as folder:
            private, public = module.generate(Path(folder) / "keys", OPENSSL)
            before = private.read_bytes()
            output = Path(folder) / "generated/pin.h"
            kid = module.pin(public, output, OPENSSL)
            self.assertEqual(len(kid), 64)
            self.assertNotIn("PRIVATE KEY", output.read_text())
            self.assertIn(kid, output.read_text())
            self.assertEqual(module.pin(public, output, OPENSSL), kid)
            with self.assertRaises(ValueError):
                module.generate(private.parent, OPENSSL)
            self.assertEqual(private.read_bytes(), before)
            pin_before = output.read_bytes()
            with self.assertRaises(ValueError):
                module.pin(private, output, OPENSSL)
            self.assertEqual(output.read_bytes(), pin_before)

    def test_invalid_key_does_not_replace_previous_pin(self):
        with tempfile.TemporaryDirectory() as folder:
            key, output = Path(folder) / "bad.pem", Path(folder) / "pin.h"
            key.write_text("not a public key")
            output.write_text("previous pin")
            with self.assertRaises(ValueError):
                module.pin(key, output, OPENSSL)
            self.assertEqual(output.read_text(), "previous pin")


if __name__ == "__main__":
    unittest.main()
