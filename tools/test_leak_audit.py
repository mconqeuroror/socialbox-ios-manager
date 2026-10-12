#!/usr/bin/env python3
"""AUDIT-001: behavior of the shipped capture analyzer, without mitmproxy."""
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest

SPEC = importlib.util.spec_from_file_location("leak_audit", Path(__file__).with_name("leak_audit.py"))
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


class LeakAuditTests(unittest.TestCase):
    def recorder(self):
        return audit.AuditRecorder(key=b"test-only-key" * 3)

    def observe(self, recorder, container, value="shared", headers=None):
        snapshot = recorder.snapshot("oauth.reddit.com", headers or {"client-vendor-id": value}, container)
        recorder.record(snapshot)
        return snapshot

    def test_same_identifier_in_two_containers_is_reuse(self):
        recorder = self.recorder()
        self.observe(recorder, "A")
        self.observe(recorder, "B")
        result = audit.analyze(recorder.document)
        self.assertEqual(result["status"], "REUSE_DETECTED")
        self.assertEqual(result["reused_fields"]["client-vendor-id"][0]["containers"], ["A", "B"])

    def test_repeated_requests_in_one_container_are_not_cross_container_reuse(self):
        recorder = self.recorder()
        self.observe(recorder, "A")
        self.observe(recorder, "A")
        result = audit.analyze(recorder.document)
        self.assertEqual(result["status"], "NOT_VERIFIED")
        self.assertEqual(result["reused_fields"], {})

    def test_empty_unlabelled_and_missing_common_fields_are_not_verified(self):
        recorder = self.recorder()
        self.assertEqual(audit.analyze(recorder.document)["status"], "NOT_VERIFIED")
        self.observe(recorder, None)
        self.observe(recorder, "A", "a")
        self.observe(recorder, "B", "b")
        self.assertEqual(audit.analyze(recorder.document)["status"], "NOT_VERIFIED")
        recorder = self.recorder()
        self.observe(recorder, "A", headers={"client-vendor-id": "a"})
        self.observe(recorder, "B", headers={"x-reddit-device-id": "b"})
        self.assertEqual(audit.analyze(recorder.document)["status"], "NOT_VERIFIED")

    def test_no_reuse_claim_is_scoped_to_comparable_observed_fields(self):
        recorder = self.recorder()
        self.observe(recorder, "A", "a")
        self.observe(recorder, "B", "b")
        result = audit.analyze(recorder.document)
        self.assertEqual(result["status"], "NO_REUSE_OBSERVED")
        self.assertEqual(result["coverage_status"], "NOT_VERIFIED")
        self.assertIn("authorization", result["unverified_fields"])
        self.assertIn("not a leak-free verdict", result["scope"])

    def test_request_label_bound_before_response_and_never_added_to_headers(self):
        recorder = self.recorder()
        addon = audit.LeakAuditAddon()
        addon.recorder = recorder
        addon.persist = lambda: None
        options = types.SimpleNamespace(rbx_audit_container="A", rbx_audit_output="unused")
        addon.options = lambda: options
        flow = types.SimpleNamespace(request=types.SimpleNamespace(host="oauth.reddit.com", headers={"client-vendor-id": "secret"}), metadata={})
        original = dict(flow.request.headers)
        addon.requestheaders(flow)
        options.rbx_audit_container = "B"
        addon.request(flow)
        addon.response(flow)
        addon.response(flow)  # Duplicate response callback cannot add observations.
        self.assertEqual(list(recorder.document["containers"]), ["A"])
        self.assertEqual(recorder.document["containers"]["A"]["requests"], 1)
        self.assertEqual(flow.request.headers, original)
        self.assertNotIn("secret", json.dumps(flow.metadata))

    def test_duplicate_header_values_do_not_hide_shared_identifiers(self):
        class Headers:
            def items(self, multi=False):
                self.assert_multi = multi
                return [("client-vendor-id", "shared"), ("client-vendor-id", "unique-A")]
        recorder = self.recorder()
        headers = Headers()
        self.observe(recorder, "A", headers=headers)
        self.observe(recorder, "B")
        self.assertTrue(headers.assert_multi)
        self.assertEqual(audit.analyze(recorder.document)["status"], "REUSE_DETECTED")

    def test_requests_without_responses_are_not_silently_omitted(self):
        addon = audit.LeakAuditAddon()
        addon.persist = lambda: None
        options = types.SimpleNamespace(rbx_audit_container="A", rbx_audit_output="unused")
        addon.options = lambda: options
        for label in ["A", "B"]:
            options.rbx_audit_container = label
            flow = types.SimpleNamespace(request=types.SimpleNamespace(host="oauth.reddit.com", headers={"client-vendor-id": "shared"}), metadata={})
            addon.requestheaders(flow)
        result = audit.analyze(addon.recorder.document)
        self.assertEqual(result["status"], "REUSE_DETECTED")
        self.assertEqual(result["containers"], ["A", "B"])

    def test_no_request_snapshot_is_unlabelled_not_current_label(self):
        addon = audit.LeakAuditAddon()
        addon.recorder = self.recorder()
        addon.persist = lambda: None
        addon.options = lambda: types.SimpleNamespace(rbx_audit_container="B", rbx_audit_output="unused")
        flow = types.SimpleNamespace(request=types.SimpleNamespace(host="oauth.reddit.com", headers={"authorization": "Bearer secret"}), metadata={})
        addon.response(flow)
        self.assertEqual(addon.recorder.document["unlabelled_requests"], 1)
        self.assertFalse(addon.recorder.document["containers"])

    def test_raw_identifiers_auth_and_tokens_are_not_persisted(self):
        recorder = self.recorder()
        self.observe(recorder, "A", headers={"authorization": "Bearer secret-token", "x-reddit-session": "session-secret"})
        text = json.dumps(recorder.document)
        self.assertNotIn("secret-token", text)
        self.assertNotIn("session-secret", text)
        self.assertNotIn("test-only-key", text)
        other = audit.AuditRecorder(key=b"different-key" * 3)
        self.observe(other, "A", headers={"authorization": "Bearer secret-token"})
        self.assertNotEqual(recorder.document["containers"]["A"]["headers"]["authorization"], other.document["containers"]["A"]["headers"]["authorization"])

    def test_legacy_and_malformed_capture_documents_are_rejected(self):
        for document in ({"captures": {"authorization": ["token"]}}, {}, {"schema_version": 2, "containers": {}}):
            with self.assertRaises(ValueError):
                audit.analyze(document)

    def test_output_is_private_and_cannot_append_another_run(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.json"
            recorder = self.recorder()
            self.observe(recorder, "A")
            audit.save_audit(recorder.document, path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            audit.save_audit(recorder.document, path)
            with self.assertRaises(ValueError):
                audit.save_audit(self.recorder().document, path)
            path.write_text(json.dumps({"captures": {"authorization": ["legacy"]}}))
            with self.assertRaises(ValueError):
                audit.save_audit(recorder.document, path)

    def test_unrelated_domain_is_not_captured(self):
        recorder = self.recorder()
        self.assertIsNone(recorder.snapshot("reddit.com.attacker.invalid", {"authorization": "secret"}, "A"))


if __name__ == "__main__":
    unittest.main()
