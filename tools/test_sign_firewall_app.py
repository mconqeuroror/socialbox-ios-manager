#!/usr/bin/env python3
"""Exercise the real signing planner/runner using temporary Mach-O products."""

import importlib.util
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("firewall_signing", ROOT / "scripts/sign-firewall-app.py")
SIGNING = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SIGNING
SPEC.loader.exec_module(SIGNING)


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def thin(kind=2, subtype=0):
    return struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, subtype, kind, 0, 0, 0, 0)


def universal(kind=2):
    header = struct.pack(">II", 0xCAFEBABE, 2)
    table = (struct.pack(">IIIII", 0x0100000C, 0, 48, 32, 0) +
             struct.pack(">IIIII", 0x0100000C, 2, 80, 32, 0))
    return header + table + thin(kind, 0) + thin(kind, 2)


def bundle(path, identifier, executable, kind=2, extension=False):
    info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": executable}
    if extension:
        info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.networkextension.app-proxy"}
    write_plist(path / "Info.plist", info)
    binary = path / executable
    binary.write_bytes(thin(kind))
    return binary


class MockLDID:
    """Models per-binary entitlements and bundle envelopes, recording real calls."""
    def __init__(self):
        self.calls = []
        self.entitlements = {}
        self.mismatch = None
        self.fail_target = None
        self.missing_envelope = None
        self.shallow = True

    def __call__(self, argv, **kwargs):
        self.calls.append(argv)
        if not kwargs.get("check"):
            raise AssertionError("Signer errors must be checked")
        arguments = argv[1:]
        output = b""
        if not arguments:
            output = b"Usage: ldid\n   -w Shallow sign\n" if self.shallow else b"Old ldid\n"
        elif "-e" in arguments:
            architecture, _, binary = arguments
            expected = self.entitlements[Path(binary)]
            if self.mismatch and self.mismatch(Path(binary), architecture):
                expected = {"unexpected": True}
            output = plistlib.dumps(expected) if expected else b""
        else:
            path = Path(arguments[-1])
            if path == self.fail_target:
                raise subprocess.CalledProcessError(1, argv, stderr=b"injected signer failure")
            entitlement_arg = next(arg for arg in arguments if arg.startswith("-S"))
            expected = SIGNING.read_plist(Path(entitlement_arg[2:])) if len(entitlement_arg) > 2 else {}
            if path.is_dir():
                if "-w" not in arguments:
                    raise AssertionError("Bundle signing must preserve its already-signed children")
                executable = SIGNING.read_plist(path / "Info.plist")["CFBundleExecutable"]
                binary = path / executable
                if path != self.missing_envelope:
                    write_plist(path / "_CodeSignature/CodeResources", {"files": {}, "files2": {}})
            else:
                binary = path
            self.entitlements[binary] = expected
        return subprocess.CompletedProcess(argv, 0, stdout=output, stderr=b"")

    @property
    def signed_paths(self):
        return [Path(call[-1]) for call in self.calls if any(arg.startswith("-S") for arg in call[1:])]


class SignFirewallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name).resolve() / "Firewall.app"
        self.host = bundle(self.app, "com.redditbox.firewall", "HostFromInfo")
        self.provider = self.app / "PlugIns/PacketTunnel.appex"
        self.provider_binary = bundle(self.provider, "com.redditbox.firewall.PacketTunnel",
                                      "ProviderFromInfo", extension=True)
        self.mock = MockLDID()

    def sign(self):
        return SIGNING.sign_app(self.app, ROOT, "/chosen/ldid", runner=self.mock)

    def test_nested_code_is_signed_inside_out_with_distinct_entitlements(self):
        framework = self.provider / "Frameworks/Transport.framework"
        framework_binary = bundle(framework, "com.example.transport", "Transport", kind=6)
        runtime = framework / "Libraries/libRuntime.dylib"
        runtime.parent.mkdir()
        runtime.write_bytes(thin(6))
        app_runtime = self.app / "Frameworks/libswiftCore.dylib"
        app_runtime.parent.mkdir()
        app_runtime.write_bytes(thin(6))
        plan = self.sign()
        paths = self.mock.signed_paths
        self.assertLess(paths.index(runtime), paths.index(framework))
        self.assertLess(paths.index(framework), paths.index(self.provider))
        self.assertLess(paths.index(self.provider), paths.index(self.app))
        self.assertLess(paths.index(app_runtime), paths.index(self.app))
        self.assertEqual(paths[-1], self.app)
        self.assertEqual(len(paths), len(plan))
        self.assertEqual(self.mock.entitlements[framework_binary], {})
        self.assertEqual(self.mock.entitlements[runtime], {})
        self.assertEqual(self.mock.entitlements[self.host]["application-identifier"],
                         "RBXBOXCFG.com.redditbox.firewall")
        self.assertEqual(self.mock.entitlements[self.provider_binary]["application-identifier"],
                         "RBXBOXCFG.com.redditbox.firewall.PacketTunnel")
        self.assertTrue(all(call[0] == "/chosen/ldid" for call in self.mock.calls))

    def test_empty_generated_entitlements_are_rejected_before_signing(self):
        policy_root = Path(self.temp.name) / "policy-root"
        for relative in ("network-extension/FirewallHost/RedditBoxFirewall.entitlements",
                         "network-extension/PacketTunnel/PacketTunnel.entitlements"):
            write_plist(policy_root / relative, {})
        with self.assertRaisesRegex(SIGNING.SigningError, "required firewall entitlement"):
            SIGNING.sign_app(self.app, policy_root, "/chosen/ldid", runner=self.mock)
        self.assertEqual(self.mock.calls, [])

    def test_every_universal_architecture_is_inspected(self):
        self.provider_binary.write_bytes(universal())
        self.sign()
        inspected = [call[1] for call in self.mock.calls if "-e" in call and Path(call[-1]) == self.provider_binary]
        self.assertEqual(inspected, ["-A16777228:0", "-A16777228:2"])

    def test_mismatching_second_slice_prevents_host_signing(self):
        self.provider_binary.write_bytes(universal())
        self.mock.mismatch = lambda binary, arch: binary == self.provider_binary and arch.endswith(":2")
        with self.assertRaisesRegex(SIGNING.SigningError, "Effective entitlements differ"):
            self.sign()
        self.assertNotIn(self.app, self.mock.signed_paths)

    def test_unknown_extension_is_rejected_before_signer_runs(self):
        bundle(self.app / "PlugIns/Unknown.appex", "com.example.unknown", "Unknown", extension=True)
        with self.assertRaisesRegex(SIGNING.SigningError, "Unknown extension"):
            self.sign()
        self.assertEqual(self.mock.calls, [])

    def test_unknown_nested_app_is_rejected_before_signer_runs(self):
        bundle(self.app / "Watch/Other.app", "com.example.other", "Other")
        with self.assertRaisesRegex(SIGNING.SigningError, "Unknown code bundle"):
            self.sign()
        self.assertEqual(self.mock.calls, [])

    def test_unclassified_macho_is_rejected(self):
        (self.app / "UndeclaredHelper").write_bytes(thin())
        with self.assertRaisesRegex(SIGNING.SigningError, "Unknown standalone Mach-O"):
            self.sign()
        self.assertEqual(self.mock.calls, [])

    def test_executable_cannot_escape_bundle(self):
        info = SIGNING.read_plist(self.app / "Info.plist")
        info["CFBundleExecutable"] = "../ExternalBinary"
        write_plist(self.app / "Info.plist", info)
        with self.assertRaisesRegex(SIGNING.SigningError, "Invalid CFBundleExecutable"):
            self.sign()
        self.assertEqual(self.mock.calls, [])

    def test_missing_envelope_is_failure(self):
        self.mock.missing_envelope = self.provider
        with self.assertRaisesRegex(SIGNING.SigningError, "Cannot read plist"):
            self.sign()
        self.assertNotIn(self.app, self.mock.signed_paths)

    def test_signer_failure_stops_before_outer_bundle(self):
        self.mock.fail_target = self.provider
        with self.assertRaisesRegex(SIGNING.SigningError, "injected signer failure"):
            self.sign()
        self.assertNotIn(self.app, self.mock.signed_paths)

    def test_requires_shallow_signing_capability(self):
        self.mock.shallow = False
        with self.assertRaisesRegex(SIGNING.SigningError, "Procursus ldid"):
            self.sign()
        self.assertEqual(self.mock.signed_paths, [])

    def test_corrupt_universal_slice_is_rejected_before_signing(self):
        data = bytearray(universal())
        data[80:84] = b"bad!"
        self.provider_binary.write_bytes(data)
        with self.assertRaisesRegex(SIGNING.SigningError, "Invalid Mach-O header"):
            self.sign()
        self.assertEqual(self.mock.calls, [])

    def test_resource_only_bundle_does_not_inherit_provider_entitlements(self):
        resources = self.provider / "Assets.bundle"
        write_plist(resources / "Info.plist", {"CFBundleIdentifier": "com.example.resources"})
        (resources / "asset.txt").write_text("resource")
        self.sign()
        self.assertNotIn(resources, self.mock.signed_paths)


if __name__ == "__main__":
    unittest.main()
