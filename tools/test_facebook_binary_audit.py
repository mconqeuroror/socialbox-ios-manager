#!/usr/bin/env python3
"""Check bounded signature parsing and committed Facebook evidence invariants."""
import json
from pathlib import Path
import plistlib
import struct
import unittest

from enumerate_facebook_binary import signature_declarations
from enumerate_leak_binary import InvalidBinary, sha
from check_leak_surface import validate_rows

ROOT = Path(__file__).resolve().parents[1]


class FakeMachO:
    commands = [{"command": "0x1d", "offset": "0x0", "size": 16}]


def encoded(payload):
    child = struct.pack(">II", 0xfade7171, 8 + len(payload)) + payload
    blob = struct.pack(">IIIII", 0xfade0cc0, 20 + len(child), 1, 5, 20) + child
    return struct.pack("<IIII", 0x1d, 16, 16, len(blob)) + blob


class AuditTests(unittest.TestCase):
    def test_exact_xml_declaration_and_offset(self):
        value = {"keychain-access-groups": ["EXAMPLE.app"], "aps-environment": "production"}
        data = encoded(plistlib.dumps(value))
        actual = signature_declarations(data, FakeMachO())
        self.assertEqual(actual[0]["xml_entitlements"], value)
        self.assertEqual(actual[0]["offset"], "0x24")
        self.assertEqual(actual[0]["sha256"], sha(data[36:]))

    def test_truncated_blob_rejected(self):
        data = encoded(plistlib.dumps({"value": True}))
        with self.assertRaises(InvalidBinary):
            signature_declarations(data[:-1], FakeMachO())

    def test_child_outside_superblob_rejected(self):
        data = bytearray(encoded(plistlib.dumps({"value": True})))
        struct.pack_into(">I", data, 32, len(data) + 1)
        with self.assertRaises(InvalidBinary):
            signature_declarations(bytes(data), FakeMachO())

    def test_excessive_child_count_rejected(self):
        data = bytearray(encoded(plistlib.dumps({"value": True})))
        struct.pack_into(">I", data, 24, 0xffffffff)
        with self.assertRaises(InvalidBinary):
            signature_declarations(bytes(data), FakeMachO())

    def test_inventory_hashes_bounds_and_runtime_honesty(self):
        evidence = json.loads((ROOT / "docs/leak-surface/facebook-binary-evidence.json").read_text())
        self.assertEqual(evidence["ipa_sha256"], "2cdaab3bd8bd0238660ea23b566b7bd7713121d996032bbc045d4066d2233e8a")
        self.assertEqual(len(evidence["mach_o_files"]), 20)
        self.assertEqual(len(evidence["bundles"]), 10)
        for name in ("scanner", "supplement_scanner"):
            self.assertEqual(sha((ROOT / evidence[name]).read_bytes()), evidence[name + "_sha256"])
        cap = evidence["selection"]["max_examples_per_image_kind"]
        for entries in evidence["topics"].values():
            for entry in entries:
                self.assertEqual(len(entry["examples"]), min(cap, entry["match_count"]))
        for image in evidence["mach_o_files"]:
            for part in image["slices"]:
                self.assertFalse(any(part["unresolved_references"].values()))
                self.assertTrue(all(c["cryptid"] == 0 for c in part["encryption"]))
        rows = json.loads((ROOT / "docs/leak-surface/facebook-inventory.json").read_text())["rows"]
        self.assertEqual(validate_rows(rows), {f"FB-{n:03d}" for n in range(1, 17)})
        self.assertTrue(all(r["verdict"] == "unverified" for r in rows if r["id"] != "FB-001"))


if __name__ == "__main__":
    unittest.main()
