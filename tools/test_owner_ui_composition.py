#!/usr/bin/env python3
"""Actual fixed-source composition and inert archive/lifecycle rejection tests."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build_socialbox_owner_ui as candidate


class OwnerUIComposition(unittest.TestCase):
    def test_actual_pinned_source_preserves_accepted_implementations(self):
        with tempfile.TemporaryDirectory(prefix="socialbox-owner-profile-") as directory:
            journal = candidate.verification.Journal(Path(directory).resolve() / "new")
            try:
                files, proof = candidate.compose(journal)
            finally:
                journal.close()
            self.assertEqual(proof["acceptedTree"], candidate.BASE_TREE)
            self.assertEqual(len(proof["changedFiles"]), 13)
            for name in ("SBBackendAdapter.m", "SBWorkspaceCoordinator.m", "SBSecondaryScreens.m"):
                path = "lucid/Presentation/" + name
                original = subprocess.run(["/usr/bin/git", "-C", str(candidate.ROOT), "show", candidate.BASE + ":" + path],
                                          check=True, capture_output=True).stdout
                self.assertEqual(files[path], original, path)
                self.assertIn(path, proof["preservedFiles"])
            self.assertFalse(any("SBSavedContainer" in name or "/Containers/" in name for name in files))
            self.assertNotIn(b"containers.unavailableApps", files["lucid/Presentation/SBContainersView.m"])
            self.assertIn(b'@"container.switch"', files["lucid/Presentation/SBContainersView.m"])
            self.assertIn(b"SBSwitchProgressInstall();", files["lucid/Presentation/LBXPresentation.m"])
            self.assertEqual(proof["composedGraph"], candidate.graph(files))
            self.assertEqual(proof["reviewedSourcePins"], candidate.SOURCE_PINS)
            self.assertIn(b'@"socialbox.creation.review"', files["lucid/Presentation/SBContainersView.m"])
            copy = files["lucid/Presentation/SBInterfaceCopy.m"]
            for key in candidate.CREATION_KEYS:
                self.assertEqual(copy.count(('"creation.' + key + '"').encode()), 1)
            for key in candidate.CONTAINER_KEYS:
                self.assertEqual(copy.count(('"containers.' + key + '"').encode()), 1)
            for key in ("rename", "delete"):
                self.assertEqual(copy.count(('"container.' + key + '"').encode()), 1)
            self.assertIn(b"not a preview of the final container", copy)
            self.assertIn(b"These settings are shared", copy)
            workspace = "lucid/Presentation/LBXWorkspace.m"
            original = subprocess.run(["/usr/bin/git", "-C", str(candidate.ROOT), "show", candidate.BASE + ":" + workspace],
                                      check=True, capture_output=True).stdout
            start, end = b"    // Begin reviewed update settings entry.\n", b"    // End reviewed update settings entry.\n"
            actual = files[workspace]
            without_entry = actual[:actual.index(start)] + actual[actual.index(end) + len(end):]
            start, end = b"    // Begin reviewed proxy empty-state removal.\n", b"    // End reviewed proxy empty-state removal.\n"
            restored_workspace = without_entry[:without_entry.index(start)] + without_entry[without_entry.index(end) + len(end):]
            start, end = b"// Begin reviewed native proxy context preservation.\n", b"// End reviewed native proxy context preservation.\n"
            restored_workspace = restored_workspace[:restored_workspace.index(start)] + restored_workspace[restored_workspace.index(end) + len(end):]
            start, end = b"    // Begin reviewed native proxy context admission.\n", b"    // End reviewed native proxy context admission.\n"
            old_context = b"""    if(current && (tree || !current.available) && [current.sources isEqual:labels] && [current.controls isEqual:controls] && [current.indicators isEqual:images]) {
        for(LBXViewBinding *binding in current.bindings) binding.update();
        if(!current.available) for(UIView *view in ProxyContent(carrier).subviews) if(view!=current) view.hidden=YES;
        [ProxyContent(carrier) bringSubviewToFront:current];return;
    }
    NSString *role=tree?ProxyRole(carrier,labels,controls,images):nil;
"""
            restored_workspace = restored_workspace[:restored_workspace.index(start)] + old_context + restored_workspace[restored_workspace.index(end) + len(end):]
            start, end = b"    // Begin reviewed native proxy visibility recovery.\n", b"    // End reviewed native proxy visibility recovery.\n"
            old_visibility = b"""    for(UIView *view in content.subviews) {
        if([view isKindOfClass:UILabel.class]) {view.alpha=0;view.accessibilityElementsHidden=YES;}
        else view.hidden=YES;
    }
"""
            restored_workspace = restored_workspace[:restored_workspace.index(start)] + old_visibility + restored_workspace[restored_workspace.index(end) + len(end):]
            self.assertEqual(restored_workspace, original, "Workspace changes beyond Settings, empty-card removal and native context preservation")
            activation = "lucid/Presentation/SBActivationView.m"
            original = subprocess.run(["/usr/bin/git", "-C", str(candidate.ROOT), "show", candidate.BASE + ":" + activation],
                                      check=True, capture_output=True).stdout
            restored_color = files[activation].replace(b"colorWithRed:0 green:122.0/255.0 blue:1 alpha:1",
                                                       b"colorWithRed:.2 green:.86 blue:.76 alpha:1")
            self.assertEqual(restored_color, original, "Activation behavior changed beyond the button color")
            hook = "lucid/Presentation/LBXPresentation.m"
            original = subprocess.run(["/usr/bin/git", "-C", str(candidate.ROOT), "show", candidate.BASE + ":" + hook],
                                      check=True, capture_output=True).stdout
            start = b"        // Begin reviewed native alert tint.\n"
            end = b"        // End reviewed native alert tint.\n"
            old_start = b"        SEL present = @selector(presentViewController:animated:completion:);\n"
            old_end = b"            hook(cls, present, replacement, &original);\n        }\n"
            old_block = original[original.index(old_start):original.index(old_end) + len(old_end)]
            actual = files[hook]
            restored = actual[:actual.index(start)] + old_block + actual[actual.index(end) + len(end):]
            restored = restored.replace(b'#import "SBSwitchProgress.h"\n', b'').replace(
                b"    SBSwitchProgressInstall(); // Optional Containers artwork; original operation stays authoritative.\n", b'')
            self.assertEqual(restored, original, "Hook changes beyond the reviewed alert tint and loader")

    def test_copy_source_drift_refuses(self):
        with tempfile.TemporaryDirectory(prefix="socialbox-owner-copy-drift-") as directory:
            journal = candidate.verification.Journal(Path(directory).resolve() / "new")
            actual = candidate.read
            def changed(path, bound):
                raw = actual(path, bound)
                return raw + b"\n// synthetic copy drift\n" if str(path).endswith("SBInterfaceCopy.m") else raw
            try:
                with patch.object(candidate, "read", changed), self.assertRaisesRegex(ValueError, "Reviewed UI source differs"):
                    candidate.compose(journal)
            finally:
                journal.close()

    def test_working_edit_drift_refuses_before_build(self):
        with tempfile.TemporaryDirectory(prefix="socialbox-owner-drift-") as directory:
            journal = candidate.verification.Journal(Path(directory).resolve() / "new")
            actual = candidate.read
            def changed(path, bound):
                raw = actual(path, bound)
                return raw + b"\n// synthetic drift\n" if str(path).endswith("SBContainersView.m") else raw
            try:
                with patch.object(candidate, "read", changed), self.assertRaisesRegex(ValueError, "Reviewed UI source differs"):
                    candidate.compose(journal)
            finally:
                journal.close()

    def test_exact_two_file_archive(self):
        raw = candidate.package(b"INERT-OVERLAY", b"INERT-FILTER")
        report = candidate.validate_package(raw, b"INERT-OVERLAY", b"INERT-FILTER")
        self.assertEqual(set(report["payload"]), {candidate.OVERLAY, candidate.FILTER})
        self.assertEqual(set(report["control"]), {"control", "preinst", "postinst"})
        self.assertFalse(report["installable"] or report["customerDeliveryReady"])

    def altered_archive(self, transform):
        original = candidate.tar_bytes
        def replacement(files, modes):
            files, modes = dict(files), dict(modes)
            transform(files, modes)
            return original(files, modes)
        with patch.object(candidate, "tar_bytes", replacement):
            return candidate.package(b"INERT-OVERLAY", b"INERT-FILTER")

    def test_altered_lifecycle_control_refuses(self):
        raw = self.altered_archive(lambda files, modes: files.update(preinst=b"#!/bin/sh\nexit 0\n") if "preinst" in files else None)
        with self.assertRaises(ValueError):
            candidate.validate_package(raw, b"INERT-OVERLAY", b"INERT-FILTER")

    def test_source_state_payload_refuses(self):
        def change(files, modes):
            if candidate.OVERLAY in files:
                files["var/jb/var/lib/socialbox-license/prepared.json"] = b"synthetic"
                modes["var/jb/var/lib/socialbox-license/prepared.json"] = 0o600
        raw = self.altered_archive(change)
        with self.assertRaises(ValueError):
            candidate.validate_package(raw, b"INERT-OVERLAY", b"INERT-FILTER")

    def test_writable_payload_refuses(self):
        raw = self.altered_archive(lambda files, modes: modes.update({candidate.OVERLAY: 0o777}) if candidate.OVERLAY in files else None)
        with self.assertRaises(ValueError):
            candidate.validate_package(raw, b"INERT-OVERLAY", b"INERT-FILTER")

    def test_symlink_node_refuses(self):
        original = candidate.tar_bytes
        def linked(files, modes):
            if candidate.OVERLAY not in files:
                return original(files, modes)
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for name, raw in files.items():
                    item = tarfile.TarInfo(name)
                    item.mode = modes[name]
                    if name == candidate.OVERLAY:
                        item.type, item.linkname = tarfile.SYMTYPE, "/synthetic/target"
                        archive.addfile(item)
                    else:
                        item.size = len(raw)
                        archive.addfile(item, io.BytesIO(raw))
            return candidate.gzip.compress(output.getvalue(), mtime=0)
        with patch.object(candidate, "tar_bytes", linked):
            raw = candidate.package(b"INERT-OVERLAY", b"INERT-FILTER")
        with self.assertRaises(ValueError):
            candidate.validate_package(raw, b"INERT-OVERLAY", b"INERT-FILTER")

    def test_truncation_extra_member_and_ar_metadata_refuse(self):
        raw = candidate.package(b"INERT-OVERLAY", b"INERT-FILTER")
        altered = bytearray(raw)
        altered[24:36] = b"1           "
        for changed in [raw[:-1], raw + b"unexpected", bytes(altered)]:
            with self.subTest(size=len(changed)), self.assertRaises((ValueError, OSError, EOFError)):
                candidate.validate_package(changed, b"INERT-OVERLAY", b"INERT-FILTER")

    def test_escaping_path_refuses(self):
        for name in ("../state", "/var/state", "var/../state", "var\\state"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                candidate.tar_bytes({name: b"inert"}, {name: 0o644})

    def test_actual_inert_controls_refuse_all_lifecycle_arguments(self):
        with tempfile.TemporaryDirectory(prefix="socialbox-control-only-") as directory:
            root = Path(directory)
            sentinel = root / "sentinel"
            sentinel.write_bytes(b"preserved")
            before = sentinel.stat()
            for control in ("preinst", "postinst"):
                path = root / control
                path.write_bytes(candidate.REFUSE)
                path.chmod(0o700)
                for args in [[], ["install"], ["install", "old"], ["upgrade", "old"], ["configure"], ["configure", "old"],
                             ["abort-upgrade"], ["abort-remove"], ["deconfigure"], ["remove"], ["unknown"]]:
                    result = subprocess.run([str(path), *args], cwd=root, env={"PATH": "/usr/bin:/bin"}, capture_output=True, timeout=5)
                    self.assertEqual(result.returncode, 78)
                    self.assertEqual(result.stdout, b"")
                    self.assertIn(b"installation is unavailable", result.stderr)
            self.assertEqual(sentinel.read_bytes(), b"preserved")
            self.assertEqual((sentinel.stat().st_ino, sentinel.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
            self.assertEqual({path.name for path in root.iterdir()}, {"sentinel", "preinst", "postinst"})


if __name__ == "__main__":
    unittest.main()
