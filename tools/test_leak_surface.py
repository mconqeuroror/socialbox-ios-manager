#!/usr/bin/env python3
"""Acceptance boundaries for the inventory contract (not coverage proofs)."""
from copy import deepcopy
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import check_leak_surface as contract
from check_leak_surface import validate_rows, validate_binary_residuals
from enumerate_leak_source import shipped_path

class ContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'proof.m').write_text('checked boundary\n')
        self.row = dict(id='TEST-001', category='test', surface='boundary', mechanism='specific guard',
                        coverage=['blocked'], verdict='covered-in-code', verification='native regression', fix='retain guard',
                        evidence=[dict(path='proof.m', line=1, anchor='checked boundary', detail='direct check')])

    def test_accepts_complete_evidence(self):
        self.assertEqual(validate_rows([self.row], self.root), {'TEST-001'})

    def test_rejects_duplicate_or_missing_evidence(self):
        with self.assertRaises(ValueError): validate_rows([self.row, self.row], self.root)
        for field in ('mechanism', 'verification', 'fix', 'evidence'):
            row = deepcopy(self.row); row[field] = ''
            with self.subTest(field=field), self.assertRaises(ValueError): validate_rows([row], self.root)

    def test_rejects_stale_or_external_evidence(self):
        for patch in ({'line': 2}, {'anchor': 'removed guard'}, {'path': '../private'}, {'path': '/tmp/private'}):
            row = deepcopy(self.row); row['evidence'][0].update(patch)
            with self.subTest(patch=patch), self.assertRaises(ValueError): validate_rows([row], self.root)

    def test_absence_is_not_inferred_from_no_symbol(self):
        row = deepcopy(self.row); row['verdict'] = 'not-used-with-evidence'
        with self.assertRaises(ValueError): validate_rows([row], self.root)

    def test_inventory_includes_packaging_and_other_processes(self):
        for name in ('sbhook/RedditBoxSB.xm', 'prefs/Makefile', 'profiles/catalog.json', 'layout/DEBIAN/postinst', 'cloud/app/api/x/route.ts', 'scripts/build-mac.sh',
                     'daemon/redditboxd.entitlements', 'daemon/RBXKeychainCleaner.entitlements', 'launcher/RedditBox.entitlements',
                     'network-extension/FirewallHost/RedditBoxFirewall.entitlements', 'network-extension/PacketTunnel/PacketTunnel.entitlements', '.github/workflows/leak-surface.yml',
                     'lucid/Diagnostics/LBXIsolationAssessment.m', 'lucid/Presentation/LBXPresentation.h', 'lucid/LBXPresentation.plist', 'lucid/Makefile'):
            with self.subTest(name=name): self.assertTrue(shipped_path(name))
        self.assertFalse(shipped_path('docs/leak-surface/binary-inventory.json'))
        self.assertFalse(shipped_path('lucid/Presentation/Tests/fixture.m'))
        self.assertFalse(shipped_path('lucid/tests/recovered_context_adapter.m'))

    def test_unresolved_binary_references_fail_without_top_level_error(self):
        for family in ('selectors', 'classes', 'class_definitions', 'swift_contexts'):
            binary = dict(errors=[], mach_o_files=[dict(path='Reddit', slices=[dict(unresolved_references={family:['bad pointer']})])])
            with self.subTest(family=family), self.assertRaises(ValueError): validate_binary_residuals(binary)

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.STDOUT).strip()

    def prepare_repository(self):
        self.git('init', '-q'); self.git('config', 'user.name', 'Contract Fixture'); self.git('config', 'user.email', 'fixture@example.invalid')
        (self.root / 'daemon').mkdir()
        (self.root / 'daemon/old.m').write_text('checked boundary\n')
        directory = self.root / 'docs/leak-surface'; directory.mkdir(parents=True)
        row = deepcopy(self.row); row['evidence'][0]['path'] = 'daemon/old.m'
        (directory / 'audit-inventory.json').write_text(json.dumps({'rows':[row]}))
        self.git('add', '.'); self.git('commit', '-qm', 'Baseline')
        return row, directory, self.git('rev-parse', 'HEAD')

    def test_deletion_uses_retained_row_history_and_replacement_evidence(self):
        row, directory, base = self.prepare_repository()
        (self.root / 'daemon/old.m').rename(self.root / 'daemon/new.m')
        row['evidence'][0]['path'] = 'daemon/new.m'
        (directory / 'audit-inventory.json').write_text(json.dumps({'rows':[row]}))
        self.git('add', '-A'); self.git('commit', '-qm', 'Replace implementation\n\nLeak-Surface: TEST-001')
        validate_rows([row], self.root)
        with patch.object(contract, 'ROOT', self.root), patch.object(contract, 'DIRECTORY', directory):
            contract.changed_file_gate([row], base)
            with self.assertRaisesRegex(ValueError, 'cannot be silently removed'):
                contract.changed_file_gate([], base)

    def test_referenced_commit_cannot_mask_later_unreferenced_change(self):
        row, directory, base = self.prepare_repository()
        (self.root / 'daemon/old.m').write_text('checked boundary\nfirst change\n')
        self.git('add', '.'); self.git('commit', '-qm', 'First change\n\nLeak-Surface: TEST-001')
        (self.root / 'daemon/old.m').write_text('checked boundary\nsecond change\n')
        self.git('add', '.'); self.git('commit', '-qm', 'Unreferenced second change')
        with patch.object(contract, 'ROOT', self.root), patch.object(contract, 'DIRECTORY', directory):
            with self.assertRaisesRegex(ValueError, 'own evidenced row trailer'):
                contract.changed_file_gate([row], base)

if __name__ == '__main__': unittest.main()
