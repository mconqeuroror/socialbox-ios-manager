#!/usr/bin/env python3
"""Native production copy boundaries and adversarial source/binary guard checks."""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("branding", ROOT / "tools/check_socialbox_branding.py")
branding = importlib.util.module_from_spec(spec)
spec.loader.exec_module(branding)

# Reviewed regressions in authored copy, not a Unicode ban or a runtime user-
# data filter. Compatibility inputs and synthetic/user values are not translated.
SLOVAK_COPY = re.compile(
    r"\b(?:kontajnery|nastavenia|pripojenie|nedostupné|zálohy|zálohu|žiadne|ulož|"
    r"spustiť|zastaviť|údržba|priečinok|priečinky|aplikácií|licenčný|aktuálna|"
    r"používať|vyberte|zachovať|načítavam|vybraný|zavrieť|podrobnosti|sprievodca)\b"
    r"|\bstav nie je\b", re.IGNORECASE)


def non_english_authored_literals(source, compatibility=False):
    inputs = [(match.start(1), match.end(1)) for match in branding.INPUT.finditer(source)] if compatibility else []
    return [(source.count("\n", 0, match.start()) + 1, json.loads(match[2]))
            for match in branding.OBJC_STRING.finditer(source)
            if match[1] == "@" and not any(start <= match.start(2) < end for start, end in inputs)
            and SLOVAK_COPY.search(json.loads(match[2]))]


class EnglishCopyTests(unittest.TestCase):
    def test_production_authored_copy_has_no_known_slovak_leakage(self):
        violations = []
        for path in sorted((ROOT / "lucid/Presentation").glob("*")):
            if path.suffix in {".h", ".m"}:
                violations.extend((path.name, line, value) for line, value in non_english_authored_literals(
                    path.read_text(), compatibility=path.name == "SBLegacyDisplayCatalog.m"))
        self.assertEqual(violations, [])

    def test_language_check_scopes_inputs_and_allows_unicode(self):
        source = 'SB_LEGACY(@"Zálohy") : @"Backups"; @"Archive → Backups"; @"Renée 東京 📦";'
        self.assertEqual(non_english_authored_literals(source, compatibility=True), [])
        self.assertEqual(len(non_english_authored_literals(source)), 1)
        self.assertEqual(len(non_english_authored_literals(source + '@"Pripojenie";', compatibility=True)), 1)


class BrandingGuardTests(unittest.TestCase):
    def test_exact_literals_are_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "lucid/Presentation"
            folder.mkdir(parents=True)
            (folder / "LBXPresentation.m").write_text('@"DoritosApp"; @"DoritosApp is ready";')
            report = branding.guard(root)
            self.assertEqual(len(report["approvedReferences"]), 0)
            self.assertEqual(len(report["violations"]), 2)
            (folder / "AnotherScreen.m").write_text('@"DoritosApp";')
            self.assertEqual(len(branding.guard(root)["violations"]), 3)

    def test_only_marked_catalog_inputs_are_exempt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "lucid/Presentation"
            folder.mkdir(parents=True)
            (folder / "SBLegacyDisplayCatalog.m").write_text('SB_LEGACY(@"Doritos") : @"SocialBox"; @"Doritos output";')
            report = branding.guard(root)
            self.assertEqual(len(report["approvedReferences"]), 1)
            self.assertEqual(len(report["violations"]), 1)

    def test_all_new_ui_files_are_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "lucid/Presentation"
            folder.mkdir(parents=True)
            (folder / "NewPanel.m").write_text('@"Contact SecretSauce support";')
            self.assertEqual(branding.guard(root)["status"], "FAIL")

    def test_c_format_string_does_not_hide_later_literals(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "lucid/Presentation"
            folder.mkdir(parents=True)
            (folder / "LBXPresentation.m").write_text('log("%@", value); @"ok"; @"Doritos visible";')
            report = branding.guard(root)
            self.assertEqual(len(report["approvedReferences"]), 0)
            self.assertEqual(len(report["violations"]), 1)

    def test_empty_scan_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(branding.guard(Path(directory))["status"], "FAIL")

    def test_static_binary_scan_handles_unicode_and_keeps_raw_content_private(self):
        message = "No .socialbox or .socialboxpack files found. Downloads → archive."
        raw = b"\0DoritosApp\0" + b"\0\0" + message.encode("utf-16-le") + b"\0\0"
        strings = branding.legacy_binary_strings(raw)
        self.assertIn(("utf8", "DoritosApp"), strings.values())
        self.assertEqual(len([v for v in strings.values() if v[0]=="utf16le"]), 0)
        planted = "legacy Doritos marker"
        raw = b"\0DoritosApp\0" + b"\0\0" + planted.encode("utf-16-le") + b"\0\0"
        strings = branding.legacy_binary_strings(raw)
        self.assertIn(("utf16le", planted), strings.values())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.data"
            path.write_bytes(raw)
            before = path.read_bytes()
            report = branding.binary_inventory(path, {planted})
            self.assertEqual(report["uniqueMarkerStringCount"], 2)
            self.assertFalse(report["executed"])
            self.assertNotIn(planted, json.dumps(report))
            self.assertEqual(path.read_bytes(), before)


class NativeCopyTests(unittest.TestCase):
    def test_production_mapper_and_role_boundaries(self):
        folder = ROOT / "lucid/Presentation"
        source = (folder / "LBXDisplayCopy.m").read_text()
        # Compile the exact shipped Foundation functions without UIKit wrappers.
        self.assertEqual(source.count("NSString *LBXDisplayCopy("), 1)
        self.assertEqual(source.count("static char DisplayRoleKey;"), 1)
        wrappers = '#import "LBXDisplayCopy.h"\n#import "SBLegacyDisplayCatalog.h"\n' + source[
            source.index("NSString *LBXDisplayCopy("):source.index("static char DisplayRoleKey;")]
        code = wrappers + '#import "SBInterfaceCopy.h"\n' + r'''
static NSUInteger checks;
static void Check(BOOL value, NSString *message) {
    checks++; if(!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    Check([SBUIText(@"nav.containers") isEqual:@"Containers"] && [SBUIText(@"nav.connection") isEqual:@"Connection"] && [SBUIText(@"nav.settings") isEqual:@"Settings"],@"three primary navigation labels are English");
    Check([SBUIText(@"settings.device") isEqual:@"Device"],@"simplified Settings device section is English");
    Check([SBUIAppCount(1) isEqual:@"Apps: 1"] && [SBUIAppCount(2) isEqual:@"Apps: 2"],@"app counts use the English catalog format");
    NSString *empty=@"No importable container archives found. Save an archive to Downloads in Files, then try again.";
    Check([LBXDisplayCopy(empty) isEqual:empty],@"SocialBox import copy is authored directly");
    Check([LBXDisplayText(empty,LBXDisplayTextRoleUserData) isEqual:empty],@"user data matching fixed prose is unchanged");
    Check([LBXDisplayText(@"Harbor",LBXDisplayTextRoleUserData) isEqual:@"Harbor"],@"user container name remains unchanged");
    NSString *unicodeUser=@"Žofia — 私の Harbor zálohy 📦";
    Check([LBXDisplayText(unicodeUser,LBXDisplayTextRoleUserData) isEqual:unicodeUser],@"English authored copy leaves Unicode user data byte-for-byte unchanged");
    Check([LBXDisplayActionTitle(@"Activate SocialBox") isEqual:@"Activate SocialBox"],@"source-created action title");
    Check([LBXDisplayActionTitle(@"my-Harbor.socialbox") isEqual:@"my-Harbor.socialbox"],@"archive action filename remains unchanged");
    NSString *private=@"Harbor-user:password@https://socialbox.example/key-Harbor-123";
    Check([LBXDisplayText(private,LBXDisplayTextRoleUserData) isEqual:private],@"credentials URLs inputs are untouched");
    Check([LBXDisplayCopy(private) isEqual:private],@"fixed mapper does not replace substrings");
    NSString *diagnostic=LBXDisplayText(private,LBXDisplayTextRoleDiagnostic);
    Check([diagnostic hasPrefix:@"The operation could not be completed. Reference: SB-"],@"unknown diagnostic has neutral copy and stable reference");
    Check(![diagnostic containsString:@"password"] && ![diagnostic containsString:@"Harbor"],@"diagnostic does not reflect raw credentials");
    Check([diagnostic isEqual:LBXDisplayText(private,LBXDisplayTextRoleDiagnostic)],@"reference deterministic");
    Check([diagnostic isEqual:LBXDisplayText(diagnostic,LBXDisplayTextRoleDiagnostic)],@"diagnostic projection idempotent across layout passes");
    Check(![diagnostic isEqual:LBXDisplayText([private stringByAppendingString:@"x"],LBXDisplayTextRoleDiagnostic)],@"distinct diagnostic references");
    Check([LBXDisplayText(@"Unexpected validation state",LBXDisplayTextRoleStatus) isEqual:@"Unexpected validation state"],@"ordinary unreviewed status retained");
    Check([LBXDisplayCopy(@"Start Simulation") isEqual:@"Start simulation"]&&[LBXDisplayCopy(@"Stop simulation") isEqual:@"Stop simulation"],@"simulation status uses owned English copy");
    Check([LBXDisplayText(@"Connected",LBXDisplayTextRoleStatus) isEqual:@"Connected"],@"ordinary status retained");
    NSString *path=@"source .socialbox missing: /tmp/my Harbor.socialbox";
    Check([SBLegacyReviewedDisplayText(path) isEqual:@"Source archive missing: /tmp/my Harbor.socialbox"],@"reviewed path template retains exact filename");
    Check([LBXDisplayText(path,LBXDisplayTextRoleDiagnostic) isEqual:@"The source container archive could not be found."],@"diagnostic role does not reflect arbitrary path");
    NSString *cloud=@"Removing \"my \"Harbor\" profile\" from SocialBox Cloud.";
    Check([LBXDisplayText(cloud,LBXDisplayTextRoleStatus) isEqual:@"Removing \"my \"Harbor\" profile\" from Cloud."],@"formatted name including embedded quotes preserved");
    Check([LBXDisplayText(@"Couldn't reach SocialBoxHelper: timeout",LBXDisplayTextRoleDiagnostic) isEqual:@"Couldn't reach the background service: timeout"],@"reviewed safe diagnostic cause");
    Check([LBXDisplayText(@"Couldn't reach the background service: timeout",LBXDisplayTextRoleDiagnostic) isEqual:@"Couldn't reach the background service: timeout"],@"safe diagnostic remains stable after projection");
    Check([LBXDisplayText(@"Couldn't reach SocialBoxHelper: password=secret",LBXDisplayTextRoleDiagnostic) hasPrefix:@"The operation could not be completed. Reference: SB-"],@"unknown helper suffix not reflected");
    NSString *exported=@"my Harbor.socialbox (12 KB)\n\n• SAME DEVICE — tap Import (top-left in Containers). This export is already listed there.\n\n• ANOTHER DEVICE — tap Open Files below. In Files, tap the .socialbox file, then AirDrop it. The receiving device will offer 'Open in SocialBox' automatically.";
    NSString *share=SBLegacyReviewedDisplayText(exported);
    Check([share hasPrefix:@"my Harbor.socialbox (12 KB)\n\n"] && [share hasSuffix:@"Open the received archive in SocialBox."],@"export instructions replace only fixed suffix and preserve filename");
    Check([SBLegacyReviewedDisplayText(@"Removing \"my Harbor\" from unrelated Cloud.") isEqual:@"Removing \"my Harbor\" from unrelated Cloud."],@"near-match confirmation is not rewritten");
    Check([SBLegacyReviewedDisplayText(@"Delete Harbor-user?") isEqual:@"Delete Harbor-user?"],@"unknown confirmation preserves user name");
    Check(LBXDisplayCopy(nil)==nil && LBXDisplayText(nil,LBXDisplayTextRoleDiagnostic)==nil,@"nil safe");
    Check([LBXDisplayText(@"bad or corrupt .socialboxpack",LBXDisplayTextRoleDiagnostic) hasPrefix:@"The operation could not be completed. Reference: SB-"],@"unknown archive diagnostic is not reflected");
    Check([LBXDisplayCopy(@"The background service is not responding. Containers cannot be switched safely. Try again or restart the device.") containsString:@"cannot be switched safely"],@"safety meaning retained");
    printf("PASS: %lu native production display-copy assertions\n",(unsigned long)checks);
} return 0; }
'''
        with tempfile.TemporaryDirectory(prefix="socialbox-copy-") as directory:
            path = Path(directory)
            (path / "test.m").write_text(code)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
                            "-I" + str(folder), "-framework", "Foundation", str(path / "test.m"),
                            str(folder / "SBLegacyDisplayCatalog.m"), str(folder / "SBInterfaceCopy.m"), "-o", str(path / "test")], check=True)
            subprocess.run([str(path / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
