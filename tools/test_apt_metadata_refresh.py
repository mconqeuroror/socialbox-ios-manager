#!/usr/bin/env python3
"""Exercise the shared-lock two-repository metadata repair and its recovery."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from test_apt_release import ROOT, FakePublisher, apt, ar_bytes, entry, HOST, tar_bytes

spec = importlib.util.spec_from_file_location('refresh', ROOT / 'scripts/refresh-apt-metadata.py')
refresh = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refresh)


class MetadataRefresh(unittest.TestCase):
    def scenario(self, failure=None, dependencies=False, stage_only=False, restage=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = {'failure': failure, 'promotions': 0, 'deployments': 0}
            live = {}
            for scheme in ('rootless', 'rootful'):
                _, files = apt.generate_repository(entry(scheme=scheme), None, HOST, 'now')
                files['Release'] = apt.release_bytes(files, 'Wed, 09 Sep 2026 00:00:00 GMT', apt.variant(scheme)['architecture']).replace(b'Components: main\n', b'')
                files.update({key: b'fixture signature or key' for key in ('Release.gpg', 'public-key.asc', 'redditbox-archive-keyring.gpg')})
                files['InRelease'] = files['Release']
                live[scheme] = files
            original = copy.deepcopy(live)
            stage = {}
            dependency_path = None
            if dependencies:
                inventory = {}
                for scheme in live:
                    inventory[scheme] = []
                    for package, version in [('ai.akemi.appinst', '2.1.1-redditbox1'), ('ai.akemi.appsyncunified', '116.0')]:
                        control = f"Package: {package}\nVersion: {version}\nArchitecture: {apt.variant(scheme)['architecture']}\n"
                        data = ar_bytes({'debian-binary': b'2.0\n', 'control.tar.gz': tar_bytes({'control': control.encode()}), 'data.tar.gz': tar_bytes({'usr/bin/fixture': b'fixture'})})
                        path = root / (package + '-' + scheme + '.deb'); path.write_bytes(data)
                        inventory[scheme].append({'file': str(path), 'sha256': apt.sha256(data)})
                dependency_path = root / 'dependencies.json'; dependency_path.write_text(json.dumps(inventory))

            class Publisher(FakePublisher):
                def __init__(self, root, environment):
                    super().__init__(root, state, environment['RBX_PACKAGE_SCHEME'])
                    self.directory.mkdir(parents=True, exist_ok=True)
                def published(self, base, **kwargs):
                    if base.startswith('https://stage.'):
                        self.fault('stage-verify')
                        files = stage[self.scheme]
                    else:
                        if state['promotions']: self.fault('production-verify')
                        files = live[self.scheme]
                    return json.loads(files['repository.json']), {k: v for k, v in files.items() if k.startswith('by-hash/')}
                def verify_inrelease(self, data):
                    return data
                def sign(self, files):
                    return dict(files, InRelease=files['Release'], **{'Release.gpg': b'new fixture signature', 'public-key.asc': b'fixture signature or key', 'redditbox-archive-keyring.gpg': b'fixture signature or key'})

            def fetch(url, maximum, **kwargs):
                scheme = 'rootful' if '/redditbox-rootful/' in url else 'rootless'
                name = url.split('/apt/' + apt.variant(scheme)['repository'] + '/')[1]
                return (stage if url.startswith('https://stage.') else live)[scheme][name]

            def command(args, **kwargs):
                self.assertEqual(kwargs['cwd'], root)
                if args[1] == 'deploy':
                    state['deployments'] += 1
                    for scheme in ('rootless', 'rootful'):
                        folder = root / 'cloud/public/apt' / apt.variant(scheme)['repository']
                        stage[scheme] = {str(p.relative_to(folder)): p.read_bytes() for p in folder.rglob('*') if p.is_file()}
                    return 'https://stage.vercel.app\n'
                self.assertEqual(args[1], 'promote')
                state['promotions'] += 1
                live.update(copy.deepcopy(stage))
                if state['failure'] == 'promote-ack':
                    state['failure'] = None
                    raise ValueError('Injected uncertain promotion acknowledgment')
                return ''

            environment = {'APT_REPOSITORY_URL': 'https://fixture.example/apt/redditbox/', 'VERCEL_TOKEN': 'fixture-token'}
            with mock.patch.object(refresh, 'ROOT', root), mock.patch.object(refresh, 'Publisher', Publisher), mock.patch.object(refresh, 'fetch', side_effect=fetch), mock.patch.object(refresh, 'command', side_effect=command), mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
                journal_path = root / 'build/release/metadata-refresh.json'
                if failure:
                    with self.assertRaises(ValueError): refresh.run(dependencies_path=dependency_path)
                    first = json.loads(journal_path.read_text())
                    self.assertNotEqual(first['phase'], 'complete')
                    with self.assertRaises(ValueError): refresh.run()
                    refresh.run(resume=True)
                    self.assertEqual(first['owner'], json.loads(journal_path.read_text())['owner'])
                elif stage_only:
                    refresh.run(dependencies_path=dependency_path, stage_only=True)
                    first = json.loads(journal_path.read_text())
                    self.assertEqual(first['phase'], 'verified')
                    self.assertEqual(state['promotions'], 0)
                    self.assertEqual(live, original)
                    self.assertEqual(state['owner'], first['owner'])
                    if restage:
                        refresh.run(resume=True, stage_only=True, restage=True)
                        self.assertEqual(state['promotions'], 0)
                        self.assertEqual(state['owner'], first['owner'])
                        self.assertEqual(live, original)
                    refresh.run(resume=True)
                    self.assertEqual(first['owner'], json.loads(journal_path.read_text())['owner'])
                else:
                    refresh.run(dependencies_path=dependency_path)
            journal = json.loads(journal_path.read_text())
            self.assertEqual(journal['phase'], 'complete')
            self.assertEqual(state['promotions'], 1)
            self.assertEqual(state['deployments'], 2 if restage else 1)
            self.assertIsNone(state['owner'])
            for scheme in live:
                self.assertIn(b'Components: main\n', live[scheme]['Release'])
                for key in original[scheme]:
                    if key not in {'Release', 'Release.gpg', 'InRelease'} and not dependencies:
                        self.assertEqual(live[scheme][key], original[scheme][key])
                if dependencies:
                    result = json.loads(live[scheme]['repository.json'])
                    self.assertEqual(result['versions'], json.loads(original[scheme]['repository.json'])['versions'])
                    self.assertEqual(len(result['dependencies']), 2)
                    for package in ('ai.akemi.appinst', 'ai.akemi.appsyncunified'):
                        self.assertIn(('Package: ' + package).encode(), live[scheme]['Packages'])
            # Even a journal with a self-consistent new package index is refused.
            corrupted = copy.deepcopy(journal)
            files = corrupted['snapshots']['rootless']['after']
            files['Packages'] = b'changed package'.hex()
            decoded = {key: bytes.fromhex(value) for key, value in files.items()}
            files['Release'] = apt.release_bytes(decoded, 'Wed, 09 Sep 2026 00:00:00 GMT').hex()
            with self.assertRaises(ValueError):
                refresh.validate(corrupted, journal['configuration'])

    def test_complete_refresh_preserves_both_packages(self):
        self.scenario()

    def test_staging_checkpoint_preserves_production_and_lock_until_resume(self):
        self.scenario(stage_only=True)

    def test_failed_cloud_check_can_restage_before_promotion(self):
        self.scenario(stage_only=True, restage=True)

    def test_resume_retains_lock_owner_without_double_promotion(self):
        for failure in ('stage-verify', 'lock-check', 'promote-ack', 'production-verify', 'unlock-ack'):
            with self.subTest(failure=failure): self.scenario(failure)

    def test_dependencies_preserve_redditbox_and_resume(self):
        for failure in (None, 'upload', 'stage-verify', 'promote-ack', 'production-verify', 'unlock-ack'):
            with self.subTest(failure=failure): self.scenario(failure, dependencies=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
