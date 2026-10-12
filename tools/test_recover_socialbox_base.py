#!/usr/bin/env python3
"""Recovery must preserve surviving bytes and never execute imported scripts."""
import hashlib
import io
import json
from pathlib import Path
import stat
import sys
import tarfile
import unittest
import zipfile

import recover_socialbox_base as recovery

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from apt_repository import archive_members


def fixture(changes=None, extra=None):
    files = {"compiled/var/jb/Applications/SocialBox.app/SocialBox": b"surviving binary",
             "package-control/postinst": b"#!/bin/sh\nexit 37\n",
             "package-control/prerm": b"#!/bin/sh\nexit 38\n"}
    manifest = {"package": "com.socialbox", "version": "3.1.0-1", "files": [
        {"path": p, "size": len(b), "sha256": hashlib.sha256(b).hexdigest()}
        for p, b in files.items()]}
    files.update(changes or {})
    files["manifest.json"] = json.dumps(manifest).encode()
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        for p, data in files.items():
            z.writestr(recovery.PREFIX + p, data)
        if extra:
            z.writestr(*extra)
    return out.getvalue()


class RecoveryTests(unittest.TestCase):
    def test_manifest_integrity(self):
        with zipfile.ZipFile(io.BytesIO(fixture())) as z:
            manifest, files = recovery.verify_layout(z)
        self.assertEqual(len(files), 3)
        self.assertEqual(manifest["version"], "3.1.0-1")

    def test_rejects_changed_payload(self):
        raw = fixture({"compiled/var/jb/Applications/SocialBox.app/SocialBox": b"modified"})
        with zipfile.ZipFile(io.BytesIO(raw)) as z, self.assertRaisesRegex(ValueError, "mismatch"):
            recovery.verify_layout(z)

    def test_rejects_path_aliases_and_unlisted_code(self):
        for name in ["../escape", "/absolute", recovery.PREFIX + "compiled/../escape",
                     recovery.PREFIX + "compiled//duplicate", recovery.PREFIX + "compiled/var/jb/extra"]:
            with self.subTest(name=name), zipfile.ZipFile(io.BytesIO(fixture(extra=(name, b"x")))) as z:
                with self.assertRaises(ValueError):
                    recovery.verify_layout(z)

    def test_rejects_symlink(self):
        info = zipfile.ZipInfo(recovery.PREFIX + "link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(io.BytesIO(fixture(extra=(info, b"/tmp/target")))) as z:
            with self.assertRaisesRegex(ValueError, "special"):
                recovery.verify_layout(z)

    def test_deterministic_deb_preserves_scripts_without_running_them(self):
        payload = {"var/jb/example": b"original\x00bytes"}
        scripts = {"postinst": b"#!/bin/sh\nexit 37\n", "prerm": b"#!/bin/sh\nexit 38\n"}
        first = recovery.recovery_deb(payload, scripts, {"var/jb/example": 0o755}, "fixture")
        self.assertEqual(first, recovery.recovery_deb(payload, scripts, {"var/jb/example": 0o755}, "fixture"))
        members = archive_members(first)
        with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"])) as t:
            self.assertEqual(t.extractfile("var/jb/example").read(), payload["var/jb/example"])
        with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"])) as t:
            self.assertEqual(t.extractfile("postinst").read(), scripts["postinst"])
            self.assertEqual(t.getmember("postinst").mode, 0o755)
            control = t.extractfile("control").read().decode()
            self.assertIn("Package: com.socialbox\n", control)
            self.assertIn("UNVALIDATED", control)
            self.assertIn("firmware (>= 16.0)", control)
            self.assertNotIn("com.redditbox", control)

    def test_ipa_identity_mismatch_is_rejected(self):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as z:
            z.writestr("Payload/SocialBox.app/SocialBox", b"different")
        with zipfile.ZipFile(io.BytesIO(out.getvalue())) as z:
            with self.assertRaisesRegex(ValueError, "different"):
                recovery.compare_ipa(z, {"compiled/var/jb/Applications/SocialBox.app/SocialBox": b"original"})


if __name__ == "__main__":
    unittest.main()
