#!/usr/bin/env python3
"""Inert tool-failure tests of the actual sourced production-object guard."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
GUARD = HERE / 'production_selector_guard.sh'


class InspectionFailures(unittest.TestCase):
    def test_actual_tools_named_patterns(self):
        search = shutil.which('rg')
        self.assertIsNotNone(search, 'The real-tool positive control requires rg')
        for text, accepted in [('ordinarySelector', True), ('testUseStepBudget:', False),
                               ('testUseLicenseSender:mutationSender:', False)]:
            with self.subTest(text=text), tempfile.TemporaryDirectory(prefix='socialbox-real-selector-') as tmp:
                root = Path(tmp)
                obj = root / 'inert-object'
                obj.write_text(text + '\n')
                script = 'set -euo pipefail\nsource "$1"\ncheck_production_selectors "$2" arm64 "$3"\n'
                result = subprocess.run(['/bin/bash', '-c', script, 'fixture', str(GUARD), str(obj), str(root / 'listing')],
                                        env={'PATH': str(Path(search).parent) + ':/usr/bin:/bin', 'LC_ALL': 'C'},
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
                self.assertEqual('PASS:' in result.stdout, accepted)

    def invoke(self, extraction, search, expected, contains_pass=False):
        with tempfile.TemporaryDirectory(prefix='socialbox-selector-guard-') as tmp:
            root = Path(tmp)
            for name, body in [('strings', extraction), ('rg', search)]:
                if body is not None:
                    path = root / name
                    path.write_text('#!/bin/bash\n' + body + '\n')
                    path.chmod(0o700)
            obj = root / 'inert-object'
            obj.write_bytes(b'inert synthetic text, never executed')
            script = 'set -euo pipefail\nsource "$1"\ncheck_production_selectors "$2" arm64 "$3"\n'
            result = subprocess.run(['/bin/bash', '-c', script, 'fixture', str(GUARD), str(obj), str(root / 'listing')],
                                    env={'PATH': str(root), 'LC_ALL': 'C'}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, expected, result.stderr)
            self.assertEqual('PASS:' in result.stdout, contains_pass)
            return result

    def test_successful_absence(self):
        self.invoke("printf 'ordinarySelector\\n'", 'exit 1', True, True)

    def test_present_provider(self):
        result = self.invoke("printf 'testUseStepBudget:\\n'", 'exit 0', False)
        self.assertIn('contains a test selector', result.stderr)

    def test_missing_search(self):
        result = self.invoke("printf 'ordinarySelector\\n'", None, False)
        self.assertIn('search failed (127)', result.stderr)

    def test_search_error(self):
        for status in [2, 126, 130, 137]:
            with self.subTest(status=status):
                self.invoke("printf 'ordinarySelector\\n'", f'exit {status}', False)

    def test_missing_extractor(self):
        result = self.invoke(None, 'exit 1', False)
        self.assertIn('extraction failed', result.stderr)

    def test_failed_extractor_with_partial_output(self):
        self.invoke("printf 'ordinarySelector\\n'; exit 2", 'exit 1', False)

    def test_failed_extractor_cannot_hide_present_provider(self):
        self.invoke("printf 'testUseStepBudget:\\n'; exit 137", 'exit 1', False)


if __name__ == '__main__':
    unittest.main()
