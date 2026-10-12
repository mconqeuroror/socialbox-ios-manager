#!/usr/bin/env python3
"""Behavioral packaging tests. No original programs or device commands execute."""
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("candidate", ROOT / "scripts/build-socialbox-recovered.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
sys.path.insert(0, str(ROOT / "scripts"))
from apt_repository import archive_members


def thin(subtype=0, filetype=2, bound=None):
    # Real load-command/superblob layout; test bytes are never executable.
    hash_size, specials, hash_offset = 32, 3, 144
    directory = bytearray(hash_offset)
    struct.pack_into(">9I4B", directory, 0, 0xfade0c02, len(directory), 0x20100, 2,
                     hash_offset, 44, specials, 0, 0, hash_size, 2, 0, 12)
    if bound:
        directory[hash_offset - bound * hash_size] = 1
    blob = struct.pack(">5I", 0xfade0cc0, 20 + len(directory), 1, 0, 20) + directory
    return struct.pack("<8I", 0xfeedfacf, 0x100000c, subtype, filetype, 1, 16, 0, 0) + struct.pack(
        "<4I", 0x1d, 16, 48, len(blob)) + blob


def fat(first=None, second=None):
    one, two = first or thin(), second or thin(2)
    offset = 48
    return (struct.pack(">II", 0xcafebabe, 2)
            + struct.pack(">5I", 0x100000c, 0, offset, len(one), 0)
            + struct.pack(">5I", 0x100000c, 2, offset + len(one), len(two), 0) + one + two)


def baseline():
    info = {"CFBundleIdentifier": "com.socialbox.app", "CFBundleExecutable": "SocialBox",
            "CFBundleShortVersionString": "3.1.0", "CFBundleVersion": "1", "CFBundleDisplayName": "SocialBox",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["socialbox"]}], "CFBundleIconFile": "AppIcon"}
    return {c.INFO: plistlib.dumps(info), c.BINARY: fat(), "var/jb/usr/local/bin/SocialBoxCLI": thin(),
            "var/jb/Library/LaunchDaemons/com.secretsauce.secretsauced.plist": b"original service metadata"}


def overlay():
    return fat(thin(filetype=6), thin(2, 6))


def filters(bundle="com.socialbox.app"):
    return plistlib.dumps({"Filter": {"Bundles": [bundle]}})


def icons():
    return {name: (ROOT / "launcher/Resources" / name).read_bytes() for name in c.ICON_NAMES}


CONTROLS = {"prerm": b"#!/bin/sh\nexit 37\n", "postinst": b"#!/bin/sh\nexit 38\n"}


class BuildProvenance(unittest.TestCase):
    def source_tree(self, root):
        files = {
            "lucid/Makefile": "LBXPresentation_FILES = " + c.PRODUCTION_SOURCE_EXPRESSION + "\n",
            "lucid/LBXPresentation.plist": "filter",
            "lucid/Presentation/Main.m": '#import "Main.h"\n',
            "lucid/Presentation/Main.h": '#import "../../shared/Common.h"\n',
            "lucid/Diagnostics/Context.m": '#import <Foundation/Foundation.h>\n',
            "lucid/ProxyInput/Proxy.m": '#import "../../shared/RBXHTTPProxy.h"\n',
            "shared/RBXHTTPProxy.m": '#import "RBXHTTPProxy.h"\n',
            "shared/RBXHTTPProxy.h": "parser declaration",
            "shared/Common.h": "transitive project header",
            "lucid/Authorization/LBXLicenseExchange.m": "unlinked authorization",
            "lucid/Presentation/Tests/fixture.m": "unlinked fixture",
        }
        files.update({name: "linked client unit" for name in c.LICENSE_CLIENT_SOURCES})
        for name, content in files.items():
            path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content)

    def test_exact_production_inputs_exclude_unlinked_and_capture_transitive_headers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_tree(root)
            snapshot = c.production_input_snapshot(root)
            self.assertEqual(snapshot["translation_units"], sorted(["lucid/Diagnostics/Context.m", "lucid/Presentation/Main.m",
                             "lucid/ProxyInput/Proxy.m", "shared/RBXHTTPProxy.m"] + c.LICENSE_CLIENT_SOURCES))
            self.assertEqual(snapshot["project_headers"], ["lucid/Presentation/Main.h", "shared/Common.h", "shared/RBXHTTPProxy.h"])
            self.assertEqual(len(snapshot["sha256"]), 9 + len(c.LICENSE_CLIENT_SOURCES))
            self.assertNotIn("lucid/Authorization/LBXLicenseExchange.m", snapshot["sha256"])
            self.assertNotIn("lucid/Presentation/Tests/fixture.m", snapshot["sha256"])
            self.assertEqual(c.require_unchanged_inputs(snapshot, root), snapshot)

    def test_modified_added_removed_inputs_and_makefile_changes_reject_build(self):
        for mutation in ("header", "source", "filter", "makefile", "added", "removed"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = Path(directory); self.source_tree(root)
                before = c.production_input_snapshot(root)
                if mutation == "added": (root / "lucid/ProxyInput/Unexpected.m").write_text("new source")
                elif mutation == "removed": (root / "lucid/Diagnostics/Context.m").unlink()
                else:
                    relative = {"header": "shared/Common.h", "source": "shared/RBXHTTPProxy.m",
                                "filter": "lucid/LBXPresentation.plist", "makefile": "lucid/Makefile"}[mutation]
                    with (root / relative).open("a") as stream: stream.write("\n// changed during compilation\n")
                with self.assertRaisesRegex(ValueError, "changed during build"):
                    c.require_unchanged_inputs(before, root)

    def test_unreviewed_source_assignment_or_escaping_header_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); self.source_tree(root)
            makefile = root / "lucid/Makefile"; original = makefile.read_text()
            for extra in ("\nLBXPresentation_FILES += Authorization/LBXLicenseExchange.m\n",
                          "\noverride LBXPresentation_FILES = Presentation/Tests/fixture.m\n"):
                makefile.write_text(original + extra)
                with self.assertRaisesRegex(ValueError, "source assignment"):
                    c.production_input_snapshot(root)
            makefile.write_text(original)
            (root / "shared/Common.h").write_text('#include "../../outside.h"\n')
            with self.assertRaisesRegex(ValueError, "header"):
                c.production_input_snapshot(root)

    def linked_bytes(self, markers=(True, True)):
        marker = b"LBX_PROXY_INPUT unsupported host/method; original handler retained\0"
        return fat(thin(filetype=6) + (marker if markers[0] else b""),
                   thin(2, 6) + (marker if markers[1] else b""))

    def symbol_output(self):
        return "\n".join("0000000000001234 T _" + name for name in (
            "LBXPlanProxyInput", "LBXDispatchProxyInput", "RBXParseHTTPProxyURL", "LBXPresentationInstall",
            "LBXPresentationStatus", "LBXPresentationMetadataSupported", "LBXRecoveredContextSnapshot",
            "SBSwitchProgressInstall",
            "LBXIsolationAssessment", "LBXIsolationPublicReport", "LBXWorkspaceApply", "LBXWorkspaceRefresh", "LBXWorkspaceStatus", "LBXDisplayCopy",
            "SBPresentSavedContainerSetups", "SBSavedContainerSetupEntryTitle",
            "LBXSendContainerMutationRequest", "LBXContainerMutationIPCValidateRequest",
            "LBXContainerMutationIPCValidateReply")) + "\n0000000000002345 S _OBJC_CLASS_$_LBXContainerRootMutationCoordinator\n"

    def test_linked_output_checks_both_architectures_without_executing_overlay(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "overlay.dylib"; raw = self.linked_bytes(); path.write_bytes(raw)
            def nm(command, **kwargs):
                self.assertEqual(command[:3], ["xcrun", "nm", "-arch"])
                self.assertEqual(command[4:], ["-gU", str(path)])
                self.assertTrue(kwargs["check"]); self.assertTrue(kwargs["capture_output"])
                return subprocess.CompletedProcess(command, 0, self.symbol_output(), "")
            with mock.patch.object(c.subprocess, "run", side_effect=nm) as tool:
                evidence = c.validate_linked_overlay(path, raw)
            self.assertEqual([call.args[0][3] for call in tool.call_args_list], ["arm64", "arm64e"])
            self.assertEqual([entry["architecture"] for entry in evidence], ["arm64", "arm64e"])
            self.assertTrue(all(entry["proxy_hook_marker_present"] for entry in evidence))

    def test_each_architecture_rejects_missing_symbols_or_test_and_authorization_exports(self):
        for architecture in ("arm64", "arm64e"):
            for issue in ("LBXPlanProxyInput", "LBXDispatchProxyInput", "RBXParseHTTPProxyURL", "LBXPresentationInstall",
                          "LBXRecoveredContextSnapshot", "LBXWorkspaceApply", "LBXWorkspaceRefresh", "LBXWorkspaceStatus", "LBXDisplayCopy",
                          "SBSwitchProgressInstall", "SBSwitchProgressFixtureReduceMotion",
                          "SBPresentSavedContainerSetups", "SBSavedContainerSetupEntryTitle", "LBXSendContainerMutationRequest",
                          "LBXContainerMutationIPCValidateRequest", "LBXContainerMutationIPCValidateReply",
                          "OBJC_CLASS_$_LBXContainerRootMutationCoordinator", "LBXInstallProxyInputFixture", "LBXRecoveredContextSnapshotForTesting",
                          "OBJC_CLASS_$_LBXLicenseExchange"):
                with self.subTest(architecture=architecture, issue=issue), tempfile.TemporaryDirectory() as directory:
                    path = Path(directory) / "overlay.dylib"; raw = self.linked_bytes(); path.write_bytes(raw)
                    def nm(command, **kwargs):
                        output = self.symbol_output()
                        if command[3] == architecture:
                            line = ("0000000000002345 S _" if issue == "OBJC_CLASS_$_LBXContainerRootMutationCoordinator"
                                    else "0000000000001234 T _") + issue + "\n"
                            output = output.replace(line, "") if line in output else output + line
                        return subprocess.CompletedProcess(command, 0, output, "")
                    with mock.patch.object(c.subprocess, "run", side_effect=nm), self.assertRaises(ValueError):
                        c.validate_linked_overlay(path, raw)

    def test_each_slice_requires_hook_marker_and_rejects_hidden_test_or_auth_seams(self):
        for index in (0, 1):
            for seam in (None, b"LBXInstallProxyInputFixture\0", b"LBXLicenseExchange\0",
                         b"SBSwitchProgressFixtureReduceMotion\0",
                         b"testUseHomeDirectory:clientExecutable:\0", b"testStopAfterBoundary:\0",
                         b"testUseLicenseSender:containerSender:\0", b"testStopJournalAfterBoundary:\0",
                         b"testUseLicenseSender:mutationSender:\0", b"testUseStepBudget:\0"):
                with self.subTest(index=index, seam=seam), tempfile.TemporaryDirectory() as directory:
                    markers = [True, True]
                    if seam is None: markers[index] = False
                    raw = self.linked_bytes(markers)
                    if seam:
                        parts = [part for _, part in c.macho_slices(raw)]; parts[index] += seam
                        raw = fat(*parts)
                    path = Path(directory) / "overlay.dylib"; path.write_bytes(raw)
                    with mock.patch.object(c.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, self.symbol_output(), "")), self.assertRaises(ValueError):
                        c.validate_linked_overlay(path, raw)

    def test_build_wires_exact_inputs_and_discards_output_after_concurrent_source_edit(self):
        for change in (False, True):
            with self.subTest(concurrent_edit=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve(); self.source_tree(root)
                theos = root / "toolchain"; (theos / "makefiles").mkdir(parents=True)
                (theos / "makefiles/common.mk").touch()
                ldid = root / "ldid"; ldid.touch(); ldid.chmod(0o755)
                stage = root / "lucid/.theos/_/Library/MobileSubstrate/DynamicLibraries"
                stage.mkdir(parents=True)
                raw = self.linked_bytes(); (stage / "LBXPresentation.dylib").write_bytes(raw)
                (stage / "LBXPresentation.plist").write_bytes(filters())
                calls = []
                def inert_tools(command, **kwargs):
                    calls.append(command)
                    if command[0] == "make":
                        self.assertIn("LBXPresentation_FILES=Authorization/LBXLicenseClient.m Authorization/LBXLicenseIPC.m Authorization/LBXLicensePeer.m Containers/LBXContainerClient.m Containers/LBXContainerConfiguration.m Containers/LBXContainerIPC.m Containers/LBXContainerMutationClient.m Containers/LBXContainerMutationCoordinator.m Containers/LBXContainerMutationIPC.m Containers/LBXContainerPendingMutation.m Containers/LBXContainerRootMutationCoordinator.m Diagnostics/Context.m HelperSafety/LBXCallerFile.m Presentation/Main.m ProxyInput/Proxy.m ../shared/RBXHTTPProxy.m", command)
                        if change and command[-1] == "stage":
                            (root / "shared/RBXHTTPProxy.h").write_text("edited while compiler runs")
                        return subprocess.CompletedProcess(command, 0)
                    if command[0] == "/usr/bin/plutil":
                        return subprocess.CompletedProcess(command, 0, filters(), b"")
                    self.assertEqual(command[:3], ["xcrun", "nm", "-arch"])
                    return subprocess.CompletedProcess(command, 0, self.symbol_output(), "")
                with mock.patch.object(c, "ROOT", root), mock.patch.object(c.subprocess, "run", side_effect=inert_tools):
                    if change:
                        with self.assertRaisesRegex(ValueError, "changed during build"):
                            c.build_overlay(theos, ldid)
                    else:
                        built, filter_data, evidence = c.build_overlay(theos, ldid)
                        self.assertEqual(built, raw); self.assertEqual(filter_data, filters())
                        self.assertTrue(evidence["captured_before_make"])
                        self.assertTrue(evidence["unchanged_after_build"])
                        self.assertEqual(len(evidence["linked_output"]), 2)
                self.assertEqual([command[-1] for command in calls if command[0] == "make"], ["clean", "stage"])
                self.assertEqual([command[3] for command in calls if command[0] == "xcrun"], ["arm64", "arm64e"])

    def test_output_replaced_during_symbol_inspection_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "overlay.dylib"; raw = self.linked_bytes(); path.write_bytes(raw)
            def replace_output(command, **kwargs):
                path.write_bytes(b"different output during validation")
                return subprocess.CompletedProcess(command, 0, self.symbol_output(), "")
            with mock.patch.object(c.subprocess, "run", side_effect=replace_output), self.assertRaisesRegex(ValueError, "Overlay changed during"):
                c.validate_linked_overlay(path, raw)


class Packaging(unittest.TestCase):
    def test_reject_unpinned_zip_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.zip"
            path.write_bytes(b"not the authorized handoff")
            with self.assertRaisesRegex(ValueError, "hash differs"):
                c.load_handoff(path)
            symlink = path.with_name("symlink.zip")
            symlink.symlink_to(path)
            with self.assertRaisesRegex(ValueError, "regular"):
                c.load_handoff(symlink)

    def test_resource_bindings_all_slices_and_directories(self):
        self.assertEqual(len(c.resource_bindings(fat())), 2)
        for slot in (1, 3):
            for first in (True, False):
                with self.subTest(slot=slot, first=first), self.assertRaisesRegex(ValueError, "signature-bound"):
                    c.resource_bindings(fat(thin(bound=slot) if first else None,
                                           thin(2, bound=slot) if not first else None))

    def test_signature_bounds_and_missing_directory_rejected(self):
        raw = bytearray(thin())
        struct.pack_into(">I", raw, 48 + 8, 10000)
        with self.assertRaises(ValueError):
            c.resource_bindings(bytes(raw))
        raw = bytearray(thin())
        struct.pack_into(">I", raw, 48 + 16, 99999)
        with self.assertRaises(ValueError):
            c.resource_bindings(bytes(raw))

    def test_exact_original_bytes_and_abi_preserved(self):
        old = baseline()
        payload, report = c.make_payload(old, overlay(), filters(), icons())
        for path in old:
            if path != c.INFO:
                self.assertEqual(old[path], payload[path])
        before, after = plistlib.loads(old[c.INFO]), plistlib.loads(payload[c.INFO])
        for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "CFBundleURLTypes"):
            self.assertEqual(before[key], after[key])
        self.assertEqual(after["CFBundleDisplayName"], "SocialBox")
        self.assertEqual(after["SocialBoxBuild"], c.VERSION)
        self.assertEqual(set(payload) - set(old), c.ADDED_PATHS)
        self.assertEqual(len(report["original_programs"]), 2)
        self.assertTrue(all(v["byte_identical_including_signature"] for v in report["original_programs"]))

    def test_system_prompts_rebrand_without_protocol_changes(self):
        old = baseline()
        info = plistlib.loads(old[c.INFO])
        info.update(CFBundleName="SocialBox", NSCameraUsageDescription="SocialBox needs camera access to scan proxy QR codes.",
                    NSBonjourServices=["_socialbox._tcp"],
                    CFBundleDocumentTypes=[{"CFBundleTypeName":"SocialBox Container", "LSItemContentTypes":["com.socialbox"]}])
        old[c.INFO] = plistlib.dumps(info)
        good, _ = c.make_payload(old, overlay(), filters(), icons())
        result = plistlib.loads(good[c.INFO])
        self.assertEqual(result["CFBundleName"], "SocialBox")
        self.assertNotIn("SocialBox", result["NSCameraUsageDescription"])
        self.assertEqual(result["CFBundleDocumentTypes"][0]["CFBundleTypeName"], "SocialBox Container")
        self.assertEqual(result["CFBundleDocumentTypes"][0]["LSItemContentTypes"], ["com.socialbox"])
        self.assertEqual(result["NSBonjourServices"], info["NSBonjourServices"])
        for field, value in [("CFBundleDocumentTypes", [{"CFBundleTypeName":"SocialBox Container", "LSItemContentTypes":["other"]}]),
                             ("NSCameraUsageDescription", "Unreviewed request"), ("NSBonjourServices", ["_other._tcp"])]:
            bad = dict(good); changed = dict(result); changed[field] = value; bad[c.INFO] = plistlib.dumps(changed)
            with self.assertRaises(ValueError): c.validate_payload(old, bad)

    def test_extension_display_names_preserve_routing_and_signatures(self):
        old = baseline()
        cases = [("SocialBoxFilesProvider", "SocialBox Exports", "SocialBox Exports"),
                 ("SocialBoxPacketTunnel", "SocialBoxPacketTunnel", "SocialBox VPN")]
        for name, label, expected in cases:
            directory = c.APP + "PlugIns/" + name + ".appex/"
            old[directory + "Info.plist"] = plistlib.dumps({"CFBundleName": name, "CFBundleDisplayName": label,
                "CFBundleExecutable": name, "CFBundleIdentifier": "com.socialbox.app." + name,
                "NSExtension": {"NSExtensionPointIdentifier": "original-point", "NSExtensionPrincipalClass": "OriginalClass"}})
            old[directory + name] = thin()
        good, _ = c.make_payload(old, overlay(), filters(), icons())
        for name, _, expected in cases:
            directory = c.APP + "PlugIns/" + name + ".appex/"; path = directory + "Info.plist"
            before, after = plistlib.loads(old[path]), plistlib.loads(good[path])
            self.assertEqual(after["CFBundleDisplayName"], expected)
            self.assertEqual(after["CFBundleName"], expected)
            self.assertEqual({k: v for k, v in after.items() if k not in ("CFBundleName", "CFBundleDisplayName")},
                             {k: v for k, v in before.items() if k not in ("CFBundleName", "CFBundleDisplayName")})
            self.assertEqual(good[directory + name], old[directory + name])
            for key in ("CFBundleIdentifier", "NSExtension", "CFBundleDisplayName"):
                bad = dict(good); bad[path] = plistlib.dumps({**after, key: "unexpected"})
                with self.assertRaises(ValueError): c.validate_payload(old, bad)
            sealed = dict(old); sealed[directory + name] = thin(bound=1)
            with self.assertRaises(ValueError): c.make_payload(sealed, overlay(), filters(), icons())

    def test_archive_type_descriptions_are_owned_but_format_routing_is_preserved(self):
        old = baseline()
        info = plistlib.loads(old[c.INFO])
        declarations = [
            {"UTTypeIdentifier": "com.socialbox.container", "UTTypeDescription": "SocialBox Container Archive",
             "UTTypeConformsTo": ["public.data"], "UTTypeTagSpecification": {"public.filename-extension": ["socialbox", "socialboxpack"]}},
            {"UTTypeIdentifier": "com.socialbox.legacy", "UTTypeDescription": "SocialBox Container Archive (legacy)",
             "UTTypeTagSpecification": {"public.filename-extension": "socialbox"}},
            {"UTTypeIdentifier": "example.custom", "UTTypeDescription": "User archive"},
        ]
        info["UTExportedTypeDeclarations"] = declarations
        old[c.INFO] = plistlib.dumps(info)
        good, _ = c.make_payload(old, overlay(), filters(), icons())
        result = plistlib.loads(good[c.INFO])
        actual = result["UTExportedTypeDeclarations"]
        self.assertEqual([item["UTTypeDescription"] for item in actual],
                         ["SocialBox Container Archive", "SocialBox Container Archive (legacy)", "User archive"])
        for before, after in zip(declarations, actual):
            self.assertEqual({k:v for k,v in before.items() if k != "UTTypeDescription"},
                             {k:v for k,v in after.items() if k != "UTTypeDescription"})
        self.assertEqual(info["UTExportedTypeDeclarations"], declarations)
        for key, value in [("UTTypeIdentifier", "changed"), ("UTTypeTagSpecification", {}),
                           ("UTTypeDescription", "Unreviewed description")]:
            changed = plistlib.loads(good[c.INFO]); changed["UTExportedTypeDeclarations"][0][key] = value
            with self.assertRaises(ValueError): c.validate_payload(old, {**good, c.INFO: plistlib.dumps(changed)})

    def test_payload_mutations_and_abi_changes_are_rejected(self):
        old = baseline()
        good, _ = c.make_payload(old, overlay(), filters(), icons())
        changes = [{"var/mobile/Library/new": b"forbidden data"}, {c.BINARY: b"patched"},
                   {"var/jb/usr/local/bin/SocialBoxCLI": b"patched"}]
        for change in changes:
            bad = {**good, **change}
            with self.subTest(change=list(change)), self.assertRaises(ValueError):
                c.validate_payload(old, bad)
        for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleExecutable"):
            bad = dict(good)
            info = plistlib.loads(bad[c.INFO]); info[key] = "changed"
            bad[c.INFO] = plistlib.dumps(info)
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "Non-presentation"):
                c.validate_payload(old, bad)
        bad = dict(good); del bad[c.BINARY]
        with self.assertRaises(ValueError):
            c.validate_payload(old, bad)

    def test_signed_resources_and_wrong_filter_or_arch_rejected(self):
        old = baseline(); old[c.APP + "_CodeSignature/CodeResources"] = b"sealed"
        with self.assertRaisesRegex(ValueError, "resource envelope"):
            c.make_payload(old, overlay(), filters(), icons())
        for bundle in ("com.apple.springboard", "com.redditbox", "*"):
            with self.subTest(bundle=bundle), self.assertRaisesRegex(ValueError, "ONLY"):
                c.validate_overlay(overlay(), filters(bundle))
        for binary in (thin(filetype=6), fat(), fat(thin(filetype=6), thin(filetype=6))):
            with self.assertRaises(ValueError):
                c.validate_overlay(binary, filters())

    def test_package_contents_and_no_installer_side_effects(self):
        old = baseline(); payload, _ = c.make_payload(old, overlay(), filters(), icons())
        scripts, preflight = c.maintainer_scripts(old, CONTROLS)
        modes = {c.BINARY: 0o6775, "var/jb/usr/local/bin/SocialBoxCLI": 0o6775, c.OVERLAY: 0o755}
        result = c.build_deb(payload, scripts, modes, "firmware (>= 15.0), ellekit")
        self.assertEqual(result, c.build_deb(payload, scripts, modes, "firmware (>= 15.0), ellekit"))
        members = archive_members(result)
        with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"])) as archive:
            regular = {f.name: archive.extractfile(f).read() for f in archive if f.isfile()}
            self.assertEqual(regular, payload)
            self.assertEqual(archive.getmember(c.BINARY).mode, 0o6775)
            self.assertEqual(archive.getmember(c.OVERLAY).mode, 0o755)
            self.assertFalse(any(n.startswith(("var/mobile", "private/var")) for n in regular))
        with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"])) as archive:
            control = archive.extractfile("control").read().decode()
            self.assertIn("firmware (>= 16.0)", control)
            self.assertIn("Version: " + c.VERSION + "\n", control)
            self.assertEqual(plistlib.loads(payload[c.INFO])["SocialBoxBuild"], c.VERSION)
            self.assertNotIn("Conflicts: com.redditbox", control)
            self.assertNotIn("Replaces: com.redditbox", control)
            self.assertIn("UNVALIDATED", control)
            for name, content in scripts.items():
                self.assertEqual(archive.extractfile(name).read(), content)
                self.assertEqual(archive.getmember(name).mode, 0o755)
                self.assertNotIn(content, CONTROLS.values())
        for raw in [*scripts.values(), preflight]:
            subprocess.run(["/bin/sh", "-n"], input=raw, check=True, capture_output=True)
            for forbidden in (b"killall", b"pkill", b"sbreload", b"apt-get", b"securityd", b"installd", b"rm -rf"):
                self.assertNotIn(forbidden, raw)


class ScriptBehavior(unittest.TestCase):
    """Rewrite fixed paths into a temp tree, with inert command providers.

    This rewrite happens in TESTS ONLY; production scripts expose no override.
    The journal proves all invoked launch targets stay within the exact allowlist.
    """
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bootstrap = self.root / "jb"
        self.bin = self.root / "commands"; self.bin.mkdir()
        self.state = {"arch": "iphoneos-arm64", "status": "installed", "version": "3.1.0-1",
                      "firmware": "16.7.16", "other": "", "roothide": "", "unknown_control": "", "loaded": False}
        self.original = baseline()
        for name, raw in self.original.items():
            path = self.root / "jb" / name.removeprefix("var/jb/")
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(raw)
        controls = self.bootstrap / "Library/dpkg/info"; controls.mkdir(parents=True)
        self.controls = controls
        for name, raw in CONTROLS.items():
            (controls / name).write_bytes(raw)
            (controls / name).chmod(0o755)
        (controls / "preinst").write_text("unknown old preinst")
        (controls / "postrm").write_text("unknown old postrm")
        self.journal = self.root / "journal"
        dispatcher = f"#!{sys.executable}\n" + r'''
import hashlib,json,os,pathlib,sys
base=pathlib.Path(os.environ['FIXTURE_ROOT']); s=json.loads((base/'state.json').read_text())
name=pathlib.Path(sys.argv[0]).name; args=sys.argv[1:]
with (base/'journal').open('a') as f: f.write(json.dumps([name,*args])+'\n')
if name=='id': print(0)
elif name=='sha256sum': print(hashlib.sha256(pathlib.Path(args[0]).read_bytes()).hexdigest()+'  '+args[0])
elif name=='stat':
    p=pathlib.Path(args[-1]); mode=oct(p.stat().st_mode & 0o7777)[2:]
    print(('0:0:'+mode) if '%u:%g:%a' in args else s.get('parent_uid',0) if '%u' in args else mode)
elif name=='dpkg':
    if args==['--print-architecture']: print(s['arch'])
    elif args[0]=='--compare-versions': sys.exit(0 if int(args[1].split('.')[0])>=16 else 1)
    else: sys.exit(29)
elif name=='dpkg-query':
    if args[0]=='--control-path':
        control=args[-1]
        if control in ['prerm','postinst'] or control==s['unknown_control']: print(base/'jb/Library/dpkg/info'/control)
        else: sys.exit(1)
    elif args[-1]=='com.socialbox': print(s['version'] if args[1]=='-f=${Version}' else s['status'])
    elif args[-1]=='firmware': print(s['firmware'])
    elif args[-1]=='com.redditbox': print(s['other'])
    elif args[-1]=='com.socialbox.roothide': print(s['roothide'])
    else: sys.exit(28)
elif name=='launchctl':
    if args[0]=='print': sys.exit(0 if s['loaded'] else 1)
    if s.get('service_failure'): sys.exit(27)
elif name=='uicache': pass
else: sys.exit(26)
'''
        for name in ("id", "sha256sum", "stat", "dpkg", "dpkg-query", "launchctl", "uicache"):
            path = self.bin / name; path.write_text(dispatcher); path.chmod(0o755)
        for name in ("dpkg", "dpkg-query"):
            path = self.bootstrap / "usr/bin" / name
            path.parent.mkdir(parents=True, exist_ok=True); path.symlink_to(self.bin / name)
        self.scripts, self.preflight = c.maintainer_scripts(self.original, CONTROLS)
        (controls / 'postinst').write_bytes(self.scripts['postinst'])
        backup = self.bootstrap / c.BACKUP_PATH.removeprefix('/var/jb/')
        backup.parent.mkdir(mode=0o700, parents=True); backup.parent.chmod(0o700)
        backup.write_bytes(CONTROLS['postinst']); backup.chmod(0o600)
        self.backup = backup
        for added in c.ADDED_PATHS:
            (self.bootstrap / added.removeprefix('var/jb/')).parent.mkdir(parents=True, exist_ok=True)
        self.shim = self.bootstrap / 'Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate'
        self.shim.parent.mkdir(parents=True); self.shim.write_bytes(b'inert test shim, never loaded')

    def tearDown(self):
        self.temp.cleanup()

    def run_script(self, name="preinst", args=("upgrade", "3.1.0-1")):
        (self.root / "state.json").write_text(json.dumps(self.state))
        raw = self.preflight if name == "preflight" else self.scripts[name]
        source = raw.decode().replace("/var/jb", str(self.bootstrap))
        source = source.replace("PATH=" + str(self.bootstrap) + "/usr/bin:" + str(self.bootstrap) + "/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                "PATH=" + str(self.bin) + ":/usr/bin:/bin")
        path = self.root / (name + ".sh"); path.write_text(source)
        return subprocess.run(["/bin/sh", str(path), *args], capture_output=True, text=True,
                              env={**os.environ, "FIXTURE_ROOT": str(self.root), "THEOS_PACKAGE_INSTALL_PREFIX": str(self.bootstrap)})

    def calls(self):
        return [json.loads(line) for line in self.journal.read_text().splitlines()] if self.journal.exists() else []

    def test_pinned_prior_payload_controls_and_modes_are_checked(self):
        self.state['version']='3.1.0-1+socialbox.6'
        self.state['unknown_control']='preinst'
        (self.controls/'preinst').chmod(0o755)
        installed={n:(self.controls/n).read_bytes() for n in ('preinst','postinst','prerm')}
        modes={name:(self.bootstrap/name.removeprefix('var/jb/')).stat().st_mode & 0o7777 for name in self.original}
        kwargs=dict(base_version=self.state['version'],installed_controls=installed,baseline_modes=modes,added_paths=set())
        self.scripts['preinst']=('#!/bin/sh\n'+c.shell_guard(self.original,CONTROLS,installed['postinst'],incoming_preinst=True,**kwargs)).encode()
        self.preflight=('#!/bin/sh\nset -- upgrade '+self.state['version']+'\n'+c.shell_guard(self.original,CONTROLS,installed['postinst'],**kwargs)).encode()
        for state in ('installed','half-installed','half-configured','unpacked'):
            self.state['status']=state
            r=self.run_script(args=('upgrade',self.state['version']));self.assertEqual(r.returncode,0,r.stderr)
            r=self.run_script('preflight');self.assertEqual(r.returncode==0,state=='installed',r.stderr)
        self.state['status']='installed'
        self.assertNotEqual(self.run_script(args=('upgrade','3.1.0-1')).returncode,0)
        path=self.bootstrap/next(iter(self.original)).removeprefix('var/jb/')
        mode=path.stat().st_mode & 0o7777;path.chmod(mode ^ 0o020)
        self.assertNotEqual(self.run_script('preflight').returncode,0);path.chmod(mode)
        for control in installed:
            (self.controls/control).write_bytes(b'changed control')
            self.assertNotEqual(self.run_script('preflight').returncode,0)
            (self.controls/control).write_bytes(installed[control])
        self.state['unknown_control']='postrm'
        self.assertNotEqual(self.run_script('preflight').returncode,0)
        self.assertFalse(any(row[0] in ('launchctl','uicache') for row in self.calls()))

    def test_exact_base_preflight_is_read_only(self):
        before = {str(p.relative_to(self.bootstrap)): p.read_bytes() for p in self.bootstrap.rglob("*") if p.is_file()}
        for name in ("preinst", "preflight"):
            r = self.run_script(name)
            self.assertEqual(r.returncode, 0, r.stderr)
        after = {str(p.relative_to(self.bootstrap)): p.read_bytes() for p in self.bootstrap.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.assertFalse(any(row[0] in ("launchctl", "uicache") for row in self.calls()))

    def test_dpkg_inflight_state_only_admitted_by_incoming_preinst(self):
        # Real dpkg marks the OLD version half-installed before new preinst.
        # The external check must still refuse an interrupted installation.
        self.state['status'] = 'half-installed'
        self.assertEqual(self.run_script('preinst').returncode, 0)
        for state in ('half-installed', 'half-configured', 'unpacked'):
            self.state['status'] = state
            self.assertNotEqual(self.run_script('preflight').returncode, 0)
        self.state['status'] = 'half-installed'
        self.state['version'] = '3.1.1'
        self.assertNotEqual(self.run_script('preinst').returncode, 0)
        self.state['version'] = '3.1.0-1'
        path = self.bootstrap / 'Applications/SocialBox.app/SocialBox'
        path.write_bytes(path.read_bytes() + b'changed')
        self.assertNotEqual(self.run_script('preinst').returncode, 0)
        self.assertFalse(any(row[0] in ('launchctl', 'uicache') for row in self.calls()))

    def test_fresh_wrong_version_rootful_old_os_coexistence_and_controls_block(self):
        for args in (("install",), ("upgrade", "3.0.0"), ("upgrade", c.VERSION)):
            with self.subTest(args=args):
                self.assertNotEqual(self.run_script(args=args).returncode, 0)
        for key, value in (("version", "3.1.1"), ("arch", "iphoneos-arm"), ("firmware", "15.8"),
                           ("status", "config-files"), ("other", "installed"), ("other", "unpacked"),
                           ("roothide", "installed"), ("unknown_control", "preinst"), ("unknown_control", "postrm")):
            old = self.state[key]; self.state[key] = value
            with self.subTest(key=key, value=value):
                self.assertNotEqual(self.run_script().returncode, 0)
            self.state[key] = old
        self.assertFalse(any(row[0] in ("launchctl", "uicache") for row in self.calls()))

    def test_baseline_and_old_control_tampering_blocked(self):
        for name in (self.bootstrap / "Applications/SocialBox.app/SocialBox", self.controls / "prerm"):
            raw = name.read_bytes(); name.write_bytes(raw + b"changed")
            self.assertNotEqual(self.run_script().returncode, 0)
            name.write_bytes(raw)
        name = self.bootstrap / "Applications/SocialBox.app/SocialBox"
        target = self.root / "alias"; target.write_bytes(name.read_bytes()); name.unlink(); name.symlink_to(target)
        self.assertNotEqual(self.run_script().returncode, 0)

    def test_foreign_parent_symlink_is_rejected_before_upgrade(self):
        original = self.bootstrap / 'Applications/SocialBox.app'
        foreign = self.root / 'foreign.app'
        original.rename(foreign); original.symlink_to(foreign, target_is_directory=True)
        self.assertNotEqual(self.run_script('preflight').returncode, 0)

    def test_writable_or_nonroot_parent_rejected(self):
        parent = self.bootstrap / 'Applications'
        parent.chmod(0o777)
        self.assertNotEqual(self.run_script('preflight').returncode, 0)
        parent.chmod(0o755); self.state['parent_uid'] = 501
        self.assertNotEqual(self.run_script('preflight').returncode, 0)

    def test_rootless_bootstrap_link_allowed(self):
        real = self.root / 'real-bootstrap'
        self.bootstrap.rename(real); self.bootstrap.symlink_to(real, target_is_directory=True)
        r = self.run_script('preflight')
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_only_exact_injection_alias_allowed(self):
        path = self.bootstrap / 'Library/MobileSubstrate/DynamicLibraries'
        path.rmdir()
        real = self.bootstrap / 'usr/lib/TweakInject'; real.mkdir(parents=True)
        for target in (str(real), '../../usr/lib/TweakInject'):
            path.symlink_to(target, target_is_directory=True)
            r=self.run_script('preflight'); self.assertEqual(r.returncode, 0, r.stderr)
            path.unlink()
        foreign = self.root / 'foreign-injection'; foreign.mkdir()
        path.symlink_to(foreign, target_is_directory=True)
        self.assertNotEqual(self.run_script('preflight').returncode, 0)

    def test_original_unsafe_postinst_without_reviewed_replacement_is_blocked(self):
        (self.controls/'postinst').write_bytes(CONTROLS['postinst'])
        self.assertNotEqual(self.run_script('preflight').returncode, 0)

    def test_nonexecutable_controls_are_rejected(self):
        for control in ('postinst', 'prerm'):
            for mode in (0o600, 0o644):
                path=self.controls/control; path.chmod(mode)
                with self.subTest(control=control, mode=oct(mode)):
                    self.assertNotEqual(self.run_script('preflight').returncode, 0)
                path.chmod(0o755)

    def test_linked_shim_presence_at_exact_rootless_rpaths(self):
        self.shim.unlink()
        self.assertNotEqual(self.run_script('preflight').returncode, 0)
        self.shim.mkdir()
        self.assertNotEqual(self.run_script('preflight').returncode, 0)
        self.shim.rmdir()
        alternate = self.bootstrap / 'usr/lib/CydiaSubstrate.framework/CydiaSubstrate'
        alternate.parent.mkdir(parents=True); alternate.write_bytes(b'inert supported-rpath fixture')
        r=self.run_script('preflight'); self.assertEqual(r.returncode, 0, r.stderr)

    def test_rollback_backup_required_private_original_bytes(self):
        raw=self.backup.read_bytes(); self.backup.write_bytes(b'changed')
        self.assertNotEqual(self.run_script('preflight').returncode, 0)
        self.backup.write_bytes(raw); self.backup.chmod(0o644)
        self.assertNotEqual(self.run_script('preflight').returncode, 0)
        self.backup.chmod(0o600); self.backup.parent.chmod(0o755)
        self.assertNotEqual(self.run_script('preflight').returncode, 0)
        self.backup.parent.chmod(0o700); self.backup.unlink()
        self.assertNotEqual(self.run_script('preflight').returncode, 0)

    def test_foreign_cli_alias_and_added_destinations_block_in_external_preflight(self):
        alias = self.bootstrap / 'usr/bin/socialbox'
        for kind in ('file', 'foreignlink', 'dangling'):
            if kind == 'file': alias.write_text('foreign private file')
            else: alias.symlink_to(self.root / ('foreign' if kind == 'foreignlink' else 'missing'))
            self.assertNotEqual(self.run_script('preflight').returncode, 0, kind)
            alias.unlink()
        alias.symlink_to(self.bootstrap / 'usr/local/bin/SocialBoxCLI')
        self.assertEqual(self.run_script('preflight').returncode, 0)
        for path in c.ADDED_PATHS:
            target = self.bootstrap / path.removeprefix('var/jb/')
            target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(b'preexisting foreign data')
            self.assertNotEqual(self.run_script('preflight').returncode, 0, path)
            self.assertEqual(target.read_bytes(), b'preexisting foreign data'); target.unlink()

    def test_postinst_only_owned_services_and_app(self):
        for loaded in (False, True):
            self.state['loaded'] = loaded
            r = self.run_script("postinst", ("configure",))
            self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.calls()
        launch = [row for row in calls if row[0] == "launchctl"]
        self.assertEqual(len(launch), 12)
        for row in launch:
            self.assertTrue(any(service in row[-1] for service in c.SERVICES), row)
        self.assertEqual([row for row in calls if row[0] == "uicache"], [
            ["uicache", "-p", str(self.bootstrap / "Applications/SocialBox.app")]] * 2)
        self.assertEqual(os.readlink(self.bootstrap / "usr/bin/socialbox"), str(self.bootstrap / "usr/local/bin/SocialBoxCLI"))

    def test_foreign_cli_alias_and_service_failure_not_ignored(self):
        path = self.bootstrap / "usr/bin/socialbox"; path.write_text("foreign")
        r = self.run_script("postinst", ("configure",))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(path.read_text(), "foreign")
        self.assertFalse(any(row[0] == "launchctl" for row in self.calls()))
        path.unlink(); self.state['service_failure'] = True
        self.assertNotEqual(self.run_script("postinst", ("configure",)).returncode, 0)

    def test_prerm_preserves_storage_stops_monitor_first_and_ignores_abort(self):
        private = self.bootstrap / "var/mobile/account.db"
        private.parent.mkdir(parents=True); private.write_bytes(b"private state")
        self.state['loaded'] = True
        r = self.run_script("prerm", ("upgrade",))
        self.assertEqual(r.returncode, 0, r.stderr)
        stops = [row[-1] for row in self.calls() if row[:2] == ['launchctl','bootout']]
        self.assertEqual(stops, ['system/' + n for n in reversed(c.SERVICES)])
        self.assertEqual(private.read_bytes(), b"private state")
        before = self.calls()
        self.assertEqual(self.run_script("prerm", ("failed-upgrade",)).returncode, 0)
        self.assertEqual(before, self.calls())

    def test_abort_upgrade_recovers_only_owned_services(self):
        self.state['loaded'] = False
        r = self.run_script('postinst', ('abort-upgrade', 'future-candidate'))
        self.assertEqual(r.returncode, 0, r.stderr)
        starts = [row[-1] for row in self.calls() if row[:2] == ['launchctl', 'bootstrap']]
        self.assertEqual(starts, [str(self.bootstrap / 'Library/LaunchDaemons' / (n+'.plist')) for n in c.SERVICES])


if __name__ == "__main__":
    unittest.main()
