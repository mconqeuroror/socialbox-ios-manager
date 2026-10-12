#!/usr/bin/env python3
"""Private-backup migration regression tests; no phone, writes or account access."""
import copy
import datetime
import hashlib
import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest

import source_transition_inventory as subject

ROOT = "var/jb/var/mobile/Library/SocialBox/Containers"
APP = "com.reddit.Reddit"


def documents(count=107, app=APP):
    rows = [{"id": i + 1, "name": "PRIVATE name " + str(i), "apps": [app],
             "created": datetime.datetime(2026, 9, 27),
             "spoofProfile": hashlib.sha256(str(i).encode()).hexdigest()}
            for i in range(count)]
    return {"activeContainer": 1, "containers": rows, "defaultSeed": "PRIVATE seed",
            "nextContainerID": count + 1, "version": 2}, {
        "activeContainer": 1, "bundleID": app, "containers": copy.deepcopy(rows)}


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def fixture(self, global_doc=None, app_doc=None, additions=(), omit_global=False):
        if global_doc is None: global_doc, app_doc = documents()
        files = [(ROOT + "/global_metadata.plist", plistlib.dumps(global_doc)),
                 (ROOT + "/" + app_doc["bundleID"] + "/metadata.plist", plistlib.dumps(app_doc)),
                 (ROOT + "/global_metadata.plist.lock", b"")]
        if omit_global: files = files[1:]
        files += list(additions)
        entries = []
        archive = self.root / "state.tar.gz"
        with tarfile.open(archive, "w:gz") as handle:
            for name, raw in files:
                info = tarfile.TarInfo(name); info.size = len(raw); info.mode = 0o600
                handle.addfile(info, io.BytesIO(raw))
                entries.append({"path": name, "type": "0", "mode": info.mode,
                                "uid": 0, "gid": 0, "size": len(raw), "mtime": 0,
                                "link": "", "pax": {}, "sha256": hashlib.sha256(raw).hexdigest()})
        manifest = self.root / "manifest.json"
        manifest.write_text(json.dumps({"schemaVersion": 1, "entries": entries,
                                       "paths": ["/" + ROOT], "scope": "private fixture"}))
        return archive, manifest

    def inspect(self, *args, **kwargs):
        return subject.inspect_backup(*self.fixture(*args, **kwargs))

    def test_counts_records_not_directories_or_duplicate_indexes(self):
        # The real saved backup has 107 records inside only two metadata files.
        value = self.inspect()
        self.assertEqual(value["containerRecords"], 107)
        self.assertEqual(value["perAppIndexRecords"], 107)
        self.assertEqual(value["knownAppMemberships"], {"reddit": 107, "facebook": 0,
                                                     "instagram": 0, "twitter": 0})
        self.assertTrue(value["archiveVerifiedAgainstManifest"])
        self.assertTrue(value["metadataConsistent"])
        self.assertFalse(value["readyForInstallation"])
        self.assertFalse(value["accountDataRecoveryProven"])
        self.assertFalse(value["freshDeviceSnapshot"])

    def test_summary_never_exports_private_values(self):
        g, a = documents()
        g["containers"][0]["name"] = "SocialBox PRIVATE name must not be rewritten"
        a["containers"][0]["name"] = g["containers"][0]["name"]
        a["containers"][0]["proxyPassword"] = "PRIVATE secret"
        g["containers"][0]["proxyPassword"] = "PRIVATE secret"
        paths = self.fixture(g, a)
        before = [p.read_bytes() for p in paths]
        value = subject.inspect_backup(*paths)
        serialized = json.dumps(value)
        self.assertNotIn("PRIVATE", serialized)
        self.assertNotIn(g["containers"][0]["spoofProfile"], serialized)
        self.assertEqual(before, [p.read_bytes() for p in paths])
        self.assertIn("UNREVIEWED_RECORD_FIELDS", value["issues"])

    def test_system_app_is_not_silently_reclassified_as_reddit(self):
        g, a = documents(app="in.palera.loader")
        paths = self.fixture(g, a)
        value = subject.inspect_backup(*paths)
        self.assertEqual(value["unknownAppMemberships"], 107)
        self.assertEqual(sum(value["knownAppMemberships"].values()), 0)
        self.assertIn("UNSUPPORTED_APP_MEMBERSHIP", value["issues"])

    def test_many_containers_and_stable_id_correspondence(self):
        for count in (1, 40, 107):
            with self.subTest(count=count):
                g, a = documents(count)
                a["containers"].reverse()
                value = self.inspect(g, a)
                self.assertTrue(value["metadataConsistent"])
                self.assertEqual(value["containerRecords"], count)

    def test_changed_index_metadata_does_not_pass_on_ids_alone(self):
        for key, changed in (("name", "different"), ("spoofProfile", "different"),
                             ("apps", ["com.facebook.Facebook"]), ("gpsEnabled", True)):
            with self.subTest(key=key):
                g, a = documents()
                a["containers"][0][key] = changed
                value = self.inspect(g, a)
                self.assertFalse(value["metadataConsistent"])
                self.assertIn("APP_INDEX_RECORD_MISMATCH", value["issues"])

    def test_missing_app_index_is_explicit(self):
        g, a = documents()
        g["containers"][0]["apps"].append("com.facebook.Facebook")
        a["containers"][0]["apps"] = list(g["containers"][0]["apps"])
        value = self.inspect(g, a)
        self.assertFalse(value["metadataConsistent"])
        self.assertIn("APP_INDEX_MISSING", value["issues"])

    def test_invalid_metadata_and_unknown_versions_are_not_empty(self):
        mutations = [
            lambda g: g.update(version=3),
            lambda g: g.update(version=True),
            lambda g: g.update(containers="not a list"),
            lambda g: g["containers"][0].update(id=True),
            lambda g: g["containers"][1].update(id=1),
            lambda g: g.update(nextContainerID=1),
            lambda g: g.update(activeContainer=999999),
            lambda g: g["containers"][0].update(apps=["../../escape"]),
            lambda g: g["containers"][0].update(apps=[APP, APP]),
            lambda g: g["containers"][0].update(spoofProfile=""),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                g, a = documents(); mutate(g)
                with self.assertRaises(subject.InventoryError): self.inspect(g, a)
        with self.assertRaises(subject.InventoryError): self.inspect(omit_global=True)

    def test_manifest_content_and_metadata_must_match(self):
        for key, changed in (("sha256", "0" * 64), ("size", 1), ("mode", 0o777),
                             ("uid", 501), ("pax", {"xattr": "different"})):
            with self.subTest(key=key):
                archive, manifest = self.fixture()
                data = json.loads(manifest.read_text()); data["entries"][0][key] = changed
                manifest.write_text(json.dumps(data))
                with self.assertRaises(subject.InventoryError): subject.inspect_backup(archive, manifest)

    def test_unsafe_and_duplicate_paths_are_rejected_without_extraction(self):
        for path in ("../escape", "/absolute", "./../escape", ROOT + "/../escape",
                     ROOT + "/global_metadata.plist", "bad\nname"):
            with self.subTest(path=path):
                with self.assertRaises(subject.InventoryError): self.inspect(additions=[(path, b"x")])
        self.assertFalse((self.root.parent / "escape").exists())

    def test_truncated_archive_and_resource_bounds(self):
        archive, manifest = self.fixture()
        with self.assertRaises(subject.InventoryError):
            subject.inspect_backup(archive, manifest, max_entries=2)
        with self.assertRaises(subject.InventoryError):
            subject.inspect_backup(archive, manifest, max_bytes=10)
        raw = archive.read_bytes(); archive.write_bytes(raw[:len(raw)//2])
        with self.assertRaises(subject.InventoryError): subject.inspect_backup(archive, manifest)

    def test_missing_or_extra_manifest_member(self):
        for add in (False, True):
            archive, manifest = self.fixture()
            data = json.loads(manifest.read_text())
            if add:
                item = dict(data["entries"][0]); item["path"] = ROOT + "/unrecorded"
                data["entries"].append(item)
            else: data["entries"].pop()
            manifest.write_text(json.dumps(data))
            with self.assertRaises(subject.InventoryError): subject.inspect_backup(archive, manifest)

    def test_corrupt_plist_returns_a_fixed_error_without_input_content(self):
        for raw in (b'<?xml version="1.0"?><plist><PRIVATE-secret>', b'bplist00broken'):
            with self.subTest(raw=raw):
                with self.assertRaises(subject.InventoryError) as failure:
                    self.inspect(omit_global=True, additions=[(ROOT + "/global_metadata.plist", raw)])
                self.assertNotIn("PRIVATE", str(failure.exception))

    def test_corrupt_gzip_is_not_an_unhandled_decompressor_error(self):
        archive, manifest = self.fixture()
        raw = bytearray(archive.read_bytes()); raw[15:25] = b'\xff' * 10
        archive.write_bytes(raw)
        with self.assertRaises(subject.InventoryError): subject.inspect_backup(archive, manifest)

    def test_multiple_namespaces_are_preserved_not_deduplicated(self):
        g, a = documents(1)
        rootful = "var/mobile/Library/SocialBox/Containers"
        value = self.inspect(g, a, additions=[
            (rootful + "/global_metadata.plist", plistlib.dumps(g)),
            (rootful + "/" + APP + "/metadata.plist", plistlib.dumps(a))])
        self.assertEqual(value["containerRecords"], 2)
        self.assertIn("MULTIPLE_NAMESPACES_REQUIRE_RECONCILIATION", value["issues"])
        self.assertFalse(value["readyForInstallation"])

    def test_empty_metadata_never_proves_safe_replacement(self):
        g, a = documents(0); g["activeContainer"] = a["activeContainer"] = 0
        value = self.inspect(g, a)
        self.assertEqual(value["containerRecords"], 0)
        self.assertFalse(value["readyForInstallation"])
        self.assertFalse(value["accountDataRecoveryProven"])

    def test_existing_source_data_is_not_treated_as_an_empty_destination(self):
        value = self.inspect(additions=[
            ("var/mobile/Library/Preferences/com.redditbox.profiles/saved.json", b'PRIVATE source profile'),
            ("var/mobile/Library/Preferences/com.redditbox.store.json", b'PRIVATE source store')])
        self.assertEqual(value["existingSourceProfileEntries"], 1)
        self.assertEqual(value["existingSourceStoreEntries"], 1)
        self.assertIn("EXISTING_SOURCE_STATE_REQUIRES_RECONCILIATION", value["issues"])
        self.assertNotIn("PRIVATE", json.dumps(value))

    def test_metadata_links_are_never_followed(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
            with self.subTest(kind=kind):
                archive, manifest = self.fixture()
                with tarfile.open(archive) as source:
                    members = [(m, source.extractfile(m).read()) for m in source]
                data = json.loads(manifest.read_text())
                first = members[0][0]
                first.type = kind; first.linkname = "../../PRIVATE-target"; first.size = 0
                row = data["entries"][0]; row.pop("sha256")
                row.update(type=kind.decode(), link=first.linkname, size=0)
                manifest.write_text(json.dumps(data))
                with tarfile.open(archive, "w:gz") as target:
                    for m, raw in members:
                        target.addfile(m, io.BytesIO(raw) if m.isfile() else None)
                with self.assertRaises(subject.InventoryError) as error:
                    subject.inspect_backup(archive, manifest)
                self.assertEqual(str(error.exception), "METADATA_SIZE_OR_TYPE_INVALID")


if __name__ == "__main__": unittest.main()
