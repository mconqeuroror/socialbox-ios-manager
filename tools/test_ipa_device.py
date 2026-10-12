import io
import plistlib
import unittest
import zipfile
from check_ipa_device import inspect


def archive(main, extension=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as z:
        z.writestr("Payload/Example.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "test.example", **main}))
        if extension is not None:
            z.writestr("Payload/Example.app/PlugIns/Share.appex/Info.plist", plistlib.dumps({"CFBundleIdentifier": "test.example.share", **extension}))
    output.seek(0)
    return output


class Compatibility(unittest.TestCase):
    def test_actual_failure_shape_blocks_foreign_device_and_preserves_archive(self):
        data = archive({"UISupportedDevices": ["iPhone10,1", "iPhone10,4"], "MinimumOSVersion": "15.1"})
        before = data.getvalue()
        result = inspect(data, "iPhone10,6", "16.7.16")
        self.assertEqual(result["status"], "BLOCKED")
        self.assertEqual(result["issues"][0]["reason"], "device_variant_mismatch")
        self.assertEqual(data.getvalue(), before)

    def test_original_physical_device_passes_only_metadata(self):
        result = inspect(archive({"UISupportedDevices": ["iPhone10,1"]}), "iPhone10,1", "16.7.7")
        self.assertEqual(result["status"], "METADATA_COMPATIBLE")
        self.assertEqual(result["runtimeAndIsolation"], "NOT_VERIFIED")

    def test_numeric_version_and_extension_restriction(self):
        result = inspect(archive({"MinimumOSVersion": "16.10"}, {"UISupportedDevices": ["iPhone10,1"]}), "iPhone10,6", "16.7.16")
        self.assertEqual({r["reason"] for r in result["issues"]}, {"physical_os_too_old", "device_variant_mismatch"})
        self.assertEqual(result["bundlesChecked"], 2)

    def test_absent_restriction_is_not_an_isolation_claim(self):
        self.assertEqual(inspect(archive({}), "iPhone10,6", "16.7")["status"], "METADATA_COMPATIBLE")

    def test_malformed_inputs_fail(self):
        for value in ["iPhone10,6", [], [123]]:
            with self.assertRaises(ValueError):
                inspect(archive({"UISupportedDevices": value}), "iPhone10,6", "16.7.16")
        with self.assertRaises(ValueError):
            inspect(archive({}), "iPhone X", "16.7.16")
        with self.assertRaises(ValueError):
            inspect(archive({"MinimumOSVersion": "future"}), "iPhone10,6", "16.7.16")


if __name__ == "__main__":
    unittest.main()
