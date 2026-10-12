#!/usr/bin/env python3
"""Offline verifier rejection/journal tests; synthetic tools/graphs are explicit."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import verify_socialbox_presentation as verifier


class OfflineVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def journal(self, name="evidence"):
        journal = verifier.Journal(self.root / name)
        self.addCleanup(journal.close)
        return journal

    def file(self, name, raw=b"inert"):
        path = self.root / name
        path.write_bytes(raw)
        return path

    def test_actual_child_success_separate_streams_and_eof_stdin(self):
        journal = self.journal()
        command = [sys.executable, "-c", "import sys; assert not sys.stdin.read(); "
                   "sys.stdout.buffer.write(b'out'); sys.stderr.buffer.write(b'err')"]
        self.assertEqual(journal.run("child", command), (b"out", b"err"))
        row = json.loads((journal.directory / "child.json").read_text())
        self.assertEqual(row["command"], command)
        self.assertEqual(row["status"], "PASS")
        self.assertEqual(row["returncode"], 0)
        self.assertEqual(row["stdoutSHA256"], verifier.digest(b"out"))
        self.assertEqual((journal.directory / "child.stderr").read_bytes(), b"err")
        self.assertEqual((journal.directory / "child.json").stat().st_mode & 0o777, 0o600)

    def test_actual_child_nonzero_retains_both_streams_and_exit(self):
        journal = self.journal()
        with self.assertRaises(ValueError):
            journal.run("failed", [sys.executable, "-c", "import sys; print('before'); "
                        "print('failure',file=sys.stderr); sys.exit(7)"])
        self.assertEqual(journal.rows[0]["status"], "EXIT_FAILURE")
        self.assertEqual(journal.rows[0]["returncode"], 7)
        self.assertEqual((journal.directory / "failed.stdout").read_bytes(), b"before\n")
        self.assertEqual((journal.directory / "failed.stderr").read_bytes(), b"failure\n")
        self.assertFalse((journal.directory / "result.json").exists())

    def test_actual_child_timeout_kills_and_retains(self):
        journal = self.journal()
        with patch.object(verifier, "TOOL_TIMEOUT", .15), self.assertRaises(ValueError):
            journal.run("timeout", [sys.executable, "-c", "import time; time.sleep(10)"])
        self.assertEqual(journal.rows[0]["status"], "TIMEOUT")
        self.assertLess(journal.rows[0]["returncode"], 0)

    def test_closed_stdio_leader_wait_timeout_is_named_and_retained(self):
        journal = self.journal()
        with patch.object(verifier, "TOOL_TIMEOUT", .15), self.assertRaises(subprocess.TimeoutExpired):
            journal.run("wait-timeout", [sys.executable, "-c", "import os,time; "
                        "os.close(1);os.close(2);time.sleep(10)"])
        self.assertEqual(journal.rows[0]["status"], "TIMEOUT")
        self.assertLess(journal.rows[0]["returncode"], 0)

    def test_exited_leader_pipe_holding_child_is_killed_on_timeout(self):
        journal = self.journal()
        with patch.object(verifier, "TOOL_TIMEOUT", .2), self.assertRaises(ValueError):
            journal.run("child-pipe", [sys.executable, "-c", "import subprocess,sys; "
                "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(10)']); "
                "print(p.pid,flush=True)"])
        child = int((journal.directory / "child-pipe.stdout").read_bytes())
        observed = subprocess.run(["/bin/ps", "-p", str(child), "-o", "state="], capture_output=True)
        self.assertTrue(observed.returncode != 0 or observed.stdout.strip().startswith(b"Z"))
        self.assertEqual(journal.rows[0]["status"], "TIMEOUT")
        self.assertEqual(journal.rows[0]["returncode"], 0)

    def test_actual_child_output_is_bounded_before_retention(self):
        journal = self.journal()
        with patch.object(verifier, "MAX_TOOL_OUTPUT", 1024), self.assertRaises(ValueError):
            journal.run("limit", [sys.executable, "-c", "import sys; "
                        "sys.stdout.buffer.write(b'a'*100000);sys.stdout.flush()"])
        self.assertEqual(journal.rows[0]["status"], "OUTPUT_LIMIT")
        self.assertEqual((journal.directory / "limit.stdout").stat().st_size, 1024)

    def test_spawn_failure_and_duplicate_step_never_overwrite(self):
        journal = self.journal()
        with self.assertRaises(OSError):
            journal.run("spawn", [str(self.root / "absent-tool")])
        before = (journal.directory / "spawn.json").read_bytes()
        self.assertEqual(journal.rows[0]["status"], "FAILED_TO_START")
        with self.assertRaises(ValueError):
            journal.run("spawn", [sys.executable, "-c", "raise SystemExit(0)"])
        self.assertEqual((journal.directory / "spawn.json").read_bytes(), before)

    def test_actual_child_does_not_inherit_synthetic_secret(self):
        journal = self.journal()
        with patch.dict(os.environ, {"SOCIALBOX_SYNTHETIC_SECRET": "fixture-only"}):
            raw, _ = journal.run("environment", [sys.executable, "-c", "import os; "
                "assert 'SOCIALBOX_SYNTHETIC_SECRET' not in os.environ; print(os.environ['LC_ALL'])"])
        self.assertEqual(raw, b"C\n")

    def test_output_existing_nodes_refuse_and_preserve(self):
        existing = self.file("existing")
        directory = self.root / "directory"
        directory.mkdir()
        live = self.root / "link"
        live.symlink_to(existing)
        dangling = self.root / "dangling"
        dangling.symlink_to(self.root / "missing")
        for node in (existing, directory, live, dangling):
            with self.subTest(node=node), self.assertRaises(OSError):
                verifier.Journal(node)
        self.assertEqual(existing.read_bytes(), b"inert")
        self.assertTrue(dangling.is_symlink())

    def test_aliased_output_parent_and_invalid_journal_name_refuse(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(ValueError):
            verifier.Journal(alias / "evidence")
        journal = self.journal()
        for name in ("../escape", "/absolute", "mixed/leaf", "", "non ascii ä"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                journal.write(name, b"data")

    def test_single_link_reader_refuses_alias_hardlink_fifo_empty_and_limit(self):
        regular = self.file("regular")
        self.assertEqual(verifier.read_regular(regular, 10), b"inert")
        alias = self.root / "alias"
        alias.symlink_to(regular)
        hardlink = self.root / "hardlink"
        os.link(regular, hardlink)
        empty = self.file("empty", b"")
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        for node in (regular, hardlink, alias, fifo, empty):
            with self.subTest(node=node), self.assertRaises(ValueError):
                verifier.read_regular(node, 10)
        with self.assertRaises(ValueError):
            verifier.read_regular(self.file("oversized", b"abcd"), 3)

    def test_report_duplicate_keys_and_top_level_shapes_refuse(self):
        for raw in (b'{"status":"PASS","status":"FAIL"}', b"[]", b"false", b"null"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                verifier.json_object(raw)

    def test_symbol_inventory_rejects_empty_duplicate_malformed_and_wrong_export(self):
        for raw in (b"", b"header:", b"0001 T _a\n0002 T _a", b"0001 ? _a"):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                verifier.symbols(raw)
        contract = SimpleNamespace(REQUIRED_OVERLAY_EXPORTS={"SBSwitchProgressInstall"})
        valid = {"_SBSwitchProgressInstall": "T", "_OBJC_CLASS_$_LBXContainerRootMutationCoordinator": "D"}
        verifier.validate_symbols(valid, contract)
        for values in ({}, dict(valid, _SBSwitchProgressInstall="D"),
                       dict(valid, _someFixture="T"), dict(valid, _LBXLicenseExchange="T")):
            with self.subTest(values=values), self.assertRaises(ValueError):
                verifier.validate_symbols(values, contract)

    def pipeline(self):
        raw = b"inert synthetic artifact"
        graph = {"translation_units": ["fixture.m"], "project_headers": [],
                 "sha256": {"fixture.m": "f" * 64}}
        hashes = {name: "a" * 64 for name in verifier.CONTRACT_FILES}
        report = {"status": "PASS", "sourceStable": True, "overlaySHA256": verifier.digest(raw),
                  "builderSHA256": hashes["scripts/build-socialbox-recovered.py"], "productionInputs": graph}
        report_raw = json.dumps(report).encode()
        args = SimpleNamespace(overlay=self.file("artifact", raw),
                               build_report=self.file("report", report_raw), ldid=self.file("ldid"),
                               expected_overlay_sha256=verifier.digest(raw),
                               expected_report_sha256=verifier.digest(report_raw))
        args.ldid.chmod(0o700)
        contract = SimpleNamespace(production_input_snapshot=lambda: copy.deepcopy(graph),
            validate_overlay=lambda *values: None,
            macho_slices=lambda value: [(None, b"arm64"), (None, b"arm64e")],
            MachO=lambda part: SimpleNamespace(cpu=0x100000c, subtype=0 if part == b"arm64" else 2),
            PROXY_HOOK_MARKER=b"arm", FORBIDDEN_OVERLAY_SEAMS=("fixture-provider",),
            REQUIRED_OVERLAY_EXPORTS={"SBSwitchProgressInstall"})
        journal = self.journal()
        def synthetic_run(name, command):
            journal.rows.append({"name": name, "status": "SYNTHETIC_SUCCESS"})
            if name == "filter-conversion":
                return b"synthetic converted filter", b""
            if name.endswith("-details"):
                return b"", b"Signature=adhoc\n"
            if name.endswith("-exports"):
                return (b"0001 T _SBSwitchProgressInstall\n"
                        b"0002 D _OBJC_CLASS_$_LBXContainerRootMutationCoordinator\n"), b""
            return b"", b""
        journal.run = synthetic_run  # Explicit synthetic tool results, never host signature acceptance.
        return args, journal, contract, hashes, report

    def execute(self, args, journal, contract, hashes):
        with patch.object(verifier, "snapshot_contract", return_value=hashes), \
             patch.object(verifier, "load_contract", return_value=contract), \
             patch.object(verifier, "ROOT", self.root):
            (self.root / "lucid").mkdir(exist_ok=True)
            (self.root / "lucid/LBXPresentation.plist").write_bytes(b"synthetic filter")
            return verifier.verify(args, journal)

    def test_synthetic_complete_pipeline_has_exact_copies_and_no_device_authority(self):
        args, journal, contract, hashes, _ = self.pipeline()
        result = self.execute(args, journal, contract, hashes)
        self.assertEqual(result["status"], "PASS_OFFLINE_ARTIFACT_ONLY")
        self.assertEqual(len(result["toolSteps"]), 10)
        self.assertFalse(result["deviceInspected"])
        self.assertFalse(result["customerDeliveryReady"])
        self.assertEqual(result["ownerInstallation"], "NOT_RUN")
        self.assertEqual(result["publisherDeviceTrust"], "NOT_RUN")
        self.assertEqual((journal.directory / "overlay.dylib").read_bytes(), args.overlay.read_bytes())
        self.assertEqual((journal.directory / "build-report.json").read_bytes(), args.build_report.read_bytes())

    def test_pin_mismatch_refuses_before_tool_or_artifact_copy(self):
        args, journal, contract, hashes, _ = self.pipeline()
        args.expected_report_sha256 = "b" * 64
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        self.assertEqual(journal.rows, [])
        self.assertFalse((journal.directory / "overlay.dylib").exists())

    def test_relative_tool_uses_same_absolute_path_and_nonexecutable_refuses(self):
        args, journal, contract, hashes, _ = self.pipeline()
        args.ldid = Path(os.path.relpath(args.ldid, Path.cwd()))
        original, executed = journal.run, []
        def record(name, command):
            if name.endswith("-entitlements"):
                executed.append(command[0])
            return original(name, command)
        journal.run = record
        result = self.execute(args, journal, contract, hashes)
        self.assertTrue(args.ldid.is_absolute())
        self.assertEqual(executed, [str(args.ldid), str(args.ldid)])
        self.assertEqual(result["ldidSHA256"], verifier.digest(b"inert"))

    def test_nonexecutable_tool_refuses_before_tools(self):
        args, journal, contract, hashes, _ = self.pipeline()
        args.ldid.chmod(0o600)
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        self.assertFalse(journal.rows)

    def test_builder_and_full_current_graph_mismatch_refuse(self):
        args, journal, contract, hashes, report = self.pipeline()
        report["productionInputs"]["sha256"]["fixture.m"] = "b" * 64
        # Replace with independent current graph so supplied report cannot select authority.
        contract.production_input_snapshot = lambda: {"unrelated": "current"}
        args.build_report.write_text(json.dumps(report))
        args.expected_report_sha256 = verifier.digest(args.build_report.read_bytes())
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        self.assertFalse(journal.rows)

    def test_nonempty_entitlements_refuse_after_signature_tool_success(self):
        args, journal, contract, hashes, _ = self.pipeline()
        original = journal.run
        journal.run = lambda name, command: (b"<plist/>", b"") if name.endswith("-entitlements") else original(name, command)
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        self.assertFalse((journal.directory / "result.json").exists())

    def test_adhoc_output_ambiguity_refuses(self):
        args, journal, contract, hashes, _ = self.pipeline()
        original = journal.run
        journal.run = lambda name, command: (b"", b"Signature=adhoc\nSignature=adhoc\n") if name.endswith("-details") else original(name, command)
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)

    def test_original_artifact_changed_during_tools_refuses_after_observation(self):
        args, journal, contract, hashes, _ = self.pipeline()
        original = journal.run
        def drift(name, command):
            if name == "arm64e-exports":
                args.overlay.write_bytes(b"changed after publication")
            return original(name, command)
        journal.run = drift
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        self.assertFalse((journal.directory / "result.json").exists())

    def test_copied_report_changed_during_tools_refuses(self):
        args, journal, contract, hashes, _ = self.pipeline()
        original = journal.run
        def drift(name, command):
            if name == "arm64e-exports":
                (journal.directory / "build-report.json").write_bytes(b"changed")
            return original(name, command)
        journal.run = drift
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)

    def test_full_current_source_graph_drift_after_tools_is_preserved_and_refused(self):
        args, journal, contract, hashes, report = self.pipeline()
        first = copy.deepcopy(report["productionInputs"])
        after = copy.deepcopy(first)
        after["sha256"]["new-header.h"] = "b" * 64
        contract.production_input_snapshot = unittest.mock.Mock(side_effect=[first, after])
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        observed = json.loads((journal.directory / "inputs-after.json").read_text())
        self.assertEqual(observed["production"], after)
        self.assertFalse((journal.directory / "result.json").exists())

    def test_report_integer_true_cannot_substitute_source_stable_boolean(self):
        args, journal, contract, hashes, report = self.pipeline()
        report["sourceStable"] = 1
        args.build_report.write_text(json.dumps(report))
        args.expected_report_sha256 = verifier.digest(args.build_report.read_bytes())
        with self.assertRaises(ValueError):
            self.execute(args, journal, contract, hashes)
        self.assertFalse(journal.rows)

    def test_actual_cli_refusal_retains_failure_and_no_pass_or_input_change(self):
        artifact, report, ldid = self.file("input"), self.file("json", b"{}"), self.file("tool")
        output = self.root / "cli-output"
        result = subprocess.run([sys.executable, str(Path(verifier.__file__).resolve()),
            "--overlay", str(artifact), "--build-report", str(report), "--ldid", str(ldid),
            "--output", str(output), "--expected-overlay-sha256", "a" * 64,
            "--expected-report-sha256", "b" * 64], capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertFalse((output / "result.json").exists())
        self.assertEqual(json.loads((output / "failure.json").read_text())["status"], "FAIL_RETAINED")
        self.assertEqual(artifact.read_bytes(), b"inert")
        self.assertEqual(report.read_bytes(), b"{}")


if __name__ == "__main__":
    unittest.main()
