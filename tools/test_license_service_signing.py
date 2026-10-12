#!/usr/bin/env python3
"""Actual host signing boundaries; never executes iOS programs or uses licenses."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("license_service_builder", REPO / "scripts/build-socialbox-license-service.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class SigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.command_index = 0
        cls.before = builder.snapshot()
        cls.before["tools/test_license_service_signing.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        cls.patch = patch.object(builder, "run", cls.command)
        cls.patch.start()
        cls.addClassCleanup(cls.patch.stop)

    @classmethod
    def command(cls, *args):
        cls.command_index += 1
        result = subprocess.run([str(value) for value in args], cwd=REPO, capture_output=True, timeout=45)
        (OUTPUT / (str(cls.command_index).zfill(3) + ".log")).write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(result.stderr.decode(errors="replace"))
        return result.stdout

    def fixture(self):
        directory = OUTPUT / self._testMethodName
        directory.mkdir()
        source = directory / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        slices = []
        for arch in ("arm64", "arm64e"):
            thin = directory / arch
            self.command("xcrun", "--sdk", "iphoneos", "clang", "-target", arch + "-apple-ios15.0", source, "-o", thin)
            self.command(LDID, "-S", thin)
            slices.append(thin)
        binary = directory / "universal"
        self.command("xcrun", "lipo", "-create", *slices, "-output", binary)
        return directory, binary

    def sign_as(self, binary, identity, entitlements=None):
        command = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                   "--identifier", identity, "--requirements", '=designated => identifier "' + identity + '"']
        if entitlements is not None:
            command += ["--entitlements", entitlements]
        self.command(*command, binary)

    def test_repairs_actual_ldid_fat_signature_before_acceptance(self):
        _, binary = self.fixture()
        old = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", str(binary)], capture_output=True)
        (OUTPUT / "counterfactual-ldid-only.log").write_bytes(old.stdout + old.stderr)
        self.assertNotEqual(old.returncode, 0)
        self.assertIn(b"arm64e", old.stderr)
        before = hashlib.sha256(binary.read_bytes()).hexdigest()
        builder.sign_program(binary, "service", LDID)
        self.assertNotEqual(hashlib.sha256(binary.read_bytes()).hexdigest(), before)
        builder.verify_program_signature(binary, "service", LDID)

    def test_each_fixed_program_role_verifies(self):
        directory, binary = self.fixture()
        for name in ("client", "service", "installer"):
            with self.subTest(role=name):
                program = directory / name
                shutil.copyfile(binary, program)
                builder.sign_program(program, name, LDID)
                builder.verify_program_signature(program, name, LDID)
                for other in set(builder.PROGRAM_IDENTIFIERS) - {name}:
                    with self.assertRaises(RuntimeError):
                        builder.verify_program_signature(program, other, LDID)

    def test_valid_wrong_identifier_is_refused(self):
        _, binary = self.fixture()
        self.sign_as(binary, "com.example.wrong-role")
        self.command("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", binary)
        with self.assertRaises(RuntimeError):
            builder.verify_program_signature(binary, "service", LDID)

    def test_missing_architecture_is_refused(self):
        directory, binary = self.fixture()
        builder.sign_program(binary, "service", LDID)
        thin = directory / "missing-arm64e"
        self.command("xcrun", "lipo", binary, "-thin", "arm64", "-output", thin)
        with self.assertRaisesRegex(RuntimeError, "exactly arm64 and arm64e"):
            builder.verify_program_signature(thin, "service", LDID)

    def test_tampered_signed_code_is_refused(self):
        directory, binary = self.fixture()
        builder.sign_program(binary, "service", LDID)
        thin = directory / "changed-arm64"
        other = directory / "unchanged-arm64e"
        self.command("xcrun", "lipo", binary, "-thin", "arm64", "-output", thin)
        self.command("xcrun", "lipo", binary, "-thin", "arm64e", "-output", other)
        data = bytearray(thin.read_bytes())
        self.assertEqual(struct.unpack_from("<I", data)[0], 0xfeedfacf)
        offset = 32
        text = None
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            command, size = struct.unpack_from("<II", data, offset)
            if command == 0x19:
                for index in range(struct.unpack_from("<I", data, offset + 64)[0]):
                    section = offset + 72 + index * 80
                    if data[section:section + 16].rstrip(b"\0") == b"__text":
                        text = struct.unpack_from("<I", data, section + 48)[0]
            offset += size
        self.assertIsNotNone(text)
        data[text] ^= 1
        thin.write_bytes(data)
        changed = directory / "tampered"
        self.command("xcrun", "lipo", "-create", thin, other, "-output", changed)
        with self.assertRaises(RuntimeError):
            builder.verify_program_signature(changed, "service", LDID)

    def test_only_arm64e_entitlement_is_refused(self):
        directory, binary = self.fixture()
        builder.sign_program(binary, "service", LDID)
        thin = directory / "entitled-arm64e"
        other = directory / "empty-arm64"
        self.command("xcrun", "lipo", binary, "-thin", "arm64e", "-output", thin)
        self.command("xcrun", "lipo", binary, "-thin", "arm64", "-output", other)
        entitlements = directory / "fixture-entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.example.fixture": True}))
        self.sign_as(thin, builder.PROGRAM_IDENTIFIERS["service"], entitlements)
        combined = directory / "one-entitled-slice"
        self.command("xcrun", "lipo", "-create", other, thin, "-output", combined)
        self.command("/usr/bin/codesign", "--verify", "--strict", "--all-architectures", combined)
        with self.assertRaisesRegex(RuntimeError, "Unexpected signed program entitlement: arm64e"):
            builder.verify_program_signature(combined, "service", LDID)

    def test_signing_failure_has_no_verification_fallback(self):
        _, binary = self.fixture()
        before = binary.read_bytes()
        calls = []
        def refuse(*args):
            calls.append(args)
            raise RuntimeError("synthetic signer process failure")
        with patch.object(builder, "run", refuse), self.assertRaisesRegex(RuntimeError, "signer process failure"):
            builder.sign_program(binary, "service", LDID)
        self.assertEqual(len(calls), 1)
        self.assertIn("--sign", calls[0])
        self.assertEqual(binary.read_bytes(), before)

    def test_unknown_role_is_refused_before_signer(self):
        _, binary = self.fixture()
        with patch.object(builder, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "Unknown fixed program signing role"):
                builder.sign_program(binary, "unknown", LDID)
            with self.assertRaisesRegex(RuntimeError, "Unknown fixed program signing role"):
                builder.verify_program_signature(binary, "unknown", LDID)
            run.assert_not_called()

    def test_post_sign_failure_preserves_output_without_report_or_retry(self):
        directory = OUTPUT / self._testMethodName
        original = builder.sign_program
        calls = []
        def fail_after_sign(binary, name, ldid):
            original(binary, name, ldid)
            calls.append(name)
            raise RuntimeError("synthetic final failure after real signed bytes")
        arguments = [str(REPO / "scripts/build-socialbox-license-service.py"), "--consumer", "acceptance",
                     "--public-key", str(PUBLIC_KEY), "--output", str(directory), "--ldid", str(LDID)]
        with patch.object(sys, "argv", arguments), patch.object(builder, "sign_program", fail_after_sign):
            with self.assertRaisesRegex(RuntimeError, "synthetic final failure after real signed bytes"):
                builder.main()
        self.assertEqual(calls, ["client"])
        client = directory / "client"
        self.assertTrue(client.is_file())
        builder.verify_program_signature(client, "client", LDID)
        self.assertFalse((directory / "build-report.json").exists())
        self.assertFalse((directory / "service").exists())
        self.assertFalse((directory / "installer").exists())
        self.assertNotIn("#define LBX_LICENSE_CLIENT_SHA256", (directory / "owner-config.h").read_text())
        before = client.read_bytes()
        with patch.object(sys, "argv", arguments), self.assertRaises(FileExistsError):
            builder.main()
        self.assertEqual(client.read_bytes(), before)
        self.assertFalse((directory / "build-report.json").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ldid", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True, help="Public build input only; no license or private key")
    args = parser.parse_args()
    OUTPUT, LDID = args.output.resolve(), args.ldid.resolve()
    PUBLIC_KEY = args.public_key.resolve()
    if sys.platform != "darwin" or not LDID.is_file() or not Path("/usr/bin/codesign").is_file():
        print("NOT_RUN: actual macOS signing tools required")
        raise SystemExit(77)
    if OUTPUT.is_relative_to(REPO):
        raise RuntimeError("Private test output must be outside Git")
    OUTPUT.mkdir(mode=0o700, parents=True, exist_ok=False)
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SigningTests))
    after = {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in SigningTests.before}
    report = {"status": "PASS" if result.wasSuccessful() and after == SigningTests.before else "FAIL",
              "methods": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
              "quotedInputs": SigningTests.before, "sourceStable": after == SigningTests.before,
              "scope": "Fresh inert Mach-O and unexecuted production client builds with actual host tools. Explicitly synthetic before-sign and post-real-sign failures; no rollback claim for arbitrary real signer partial failure. Existing output refuses retry, with no report or pin publication after failure. No iOS execution/live license/device/publisher trust.46 repository inputs; SDK/compiler/OS/tools/public pin excluded.",
              "phoneEffects": False, "customerReady": False}
    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if report["status"] == "PASS" else 1)
