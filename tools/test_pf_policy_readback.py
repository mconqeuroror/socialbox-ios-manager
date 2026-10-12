#!/usr/bin/env python3
"""Run the real CLI on macOS: input failures and device-only refusal, no PF open."""
import json
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import unittest

binary = Path(sys.argv.pop(1)).resolve()


class ReadbackCommandTests(unittest.TestCase):
    def invoke(self, *args, code):
        result = subprocess.run([str(binary), *map(str, args)], text=True, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        report = json.loads(result.stdout)
        self.assertEqual(report["result"], code)
        self.assertTrue(report["readOnly"])
        self.assertFalse(report["enforcementVerified"])
        self.assertFalse(report["applicationAdmissionAllowed"])
        self.assertNotIn("observation", report)

    def test_arguments(self):
        for args in ([], ["--enable"], ["--empty", "--proxy"],
                     ["--closed"], ["--empty", "--creator-pid", "42"]):
            with self.subTest(args=args):
                self.invoke(*args, code="PF_ARGUMENTS_INVALID")

    def test_pid_bounds(self):
        for pid in ("", "0", "-1", "+1", "1x", " 1", "1.5", "2147483648", "99999999999"):
            with self.subTest(pid=pid):
                self.invoke("--closed", "--plan", "not-opened", "--creator-pid", pid, code="PF_ARGUMENTS_INVALID")

    def test_empty_never_opens_pf_on_host(self):
        self.invoke("--empty", code="PF_KERNEL_NOT_REVIEWED")

    def test_bad_files(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            for i, value in enumerate((b"", b"{" , b"[]", b"null", b"x" * 65537)):
                path = directory / str(i)
                path.write_bytes(value)
                self.invoke("--closed", "--plan", path, "--creator-pid", "42", code="PF_PLAN_FILE_INVALID")
            fifo = directory / "fifo"
            os.mkfifo(fifo)
            link = directory / "link"
            link.symlink_to(directory / "0")
            for path in (directory, fifo, link, directory / "missing"):
                self.invoke("--closed", "--plan", path, "--creator-pid", "42", code="PF_PLAN_FILE_INVALID")

    def test_invalid_plan(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "plan.json"
            path.write_text('{"password":"DO_NOT_ECHO"}')
            self.invoke("--closed", "--plan", path, "--creator-pid", "42", code="PF_PLAN_INVALID")

    def test_valid_policy_still_refuses_host(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "plan.json"
            path.write_text(json.dumps({"bootEpoch": "11000000-0000-4000-8000-000000000001",
                "generation": "22000000-0000-4000-8000-000000000002", "containerId": "fixture",
                "scope": "device-wide-proxy-only", "transport": "http", "proxyIPs": ["8.8.8.8"],
                "proxyPort": 3128, "recoveryMode": "out-of-band"}))
            for mode in ("--closed", "--proxy"):
                self.invoke(mode, "--plan", path, "--creator-pid", "42", code="PF_KERNEL_NOT_REVIEWED")


if __name__ == "__main__":
    unittest.main()
