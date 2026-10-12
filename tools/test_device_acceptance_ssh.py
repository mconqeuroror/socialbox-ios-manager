#!/usr/bin/env python3
"""Behavioral host fixtures: no phone or accounts are touched."""
import hmac
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path
import shlex
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace
sys.path.insert(0,str(Path(__file__).parent))
import device_acceptance_ssh as test

class AcceptanceTests(unittest.TestCase):
    def test_observer_staging_uses_existing_jailbreak_mount(self):
        class FakeRemote:
            status = 0
            def command(self, words, **kwargs):
                self.words = words
                return SimpleNamespace(returncode=self.status)
        remote = FakeRemote()
        self.assertEqual(test.observer_temporary_root(remote), '/var/jb/tmp')
        self.assertEqual(remote.words, ['test', '-d', '/var/jb'])
        remote.status = 1
        self.assertEqual(test.observer_temporary_root(remote), '/tmp')
        remote.status = 255
        with self.assertRaises(test.Unavailable): test.observer_temporary_root(remote)

    def test_native_observer_emits_boolean_evidence(self):
        with tempfile.TemporaryDirectory(prefix='rbx-observer-schema-') as directory:
            root = Path(directory)
            binary = root / 'probe'
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-I'+str(test.ROOT/'daemon'),
                '-framework', 'Foundation', str(test.ROOT/'tools/device_acceptance_probe.m'), '-o', str(binary)], check=True)
            existing = root / 'marker'
            existing.write_text('synthetic')
            for path, expected in ((existing, True), (root/'absent', False)):
                data = json.loads(subprocess.check_output([str(binary), '--exists', str(path)]))
                self.assertIs(data['exists'], expected)
                self.assertIs(data['absent'], not expected)
            data = json.loads(subprocess.check_output([str(binary), '--pid', str(os.getpid())]))
            self.assertIsInstance(data['memoryRead'], bool)

    def test_daemon_listing_is_exact_and_does_not_require_pgrep(self):
        listing = (b' 1 /sbin/launchd\n 42 /var/jb/usr/bin/redditboxd\n'
                   b' 43 /usr/bin/redditboxd-helper\n 44 /bin/sh\n')
        self.assertEqual(test.daemon_candidates(listing), ['42'])
        self.assertEqual(test.daemon_candidates(b'42 /var/jb/usr/bin/redditboxd\n43 /usr/bin/redditboxd\n'), ['42', '43'])
        for bad in (b'bad /usr/bin/redditboxd\n', b'42\n', b'42 /usr/bin/redditboxd\n42 /usr/bin/redditboxd\n', b''):
            with self.assertRaises(test.Unavailable): test.daemon_candidates(bad)

    def test_daemon_readback_binds_installed_path_not_suffix(self):
        installed_path = '/private/preboot/fixture/procursus/usr/bin/redditboxd'
        class FakeRemote:
            process_path = installed_path
            returncode = 0
            listing = b'42 /var/jb/usr/bin/redditboxd\n'
            def command(self, words, **kwargs):
                self.words = words
                return SimpleNamespace(returncode=self.returncode, stdout=self.listing)
            def canonical(self, path):
                if path == '/usr/bin/redditboxd': raise test.Unavailable('missing rootful alias')
                return installed_path if path in ('/var/jb/usr/bin/redditboxd', installed_path) else path
            def observe(self, *args):
                return {'path': self.process_path, 'memoryRead': True, 'activeMiB': 256, 'inactiveMiB': 256}
        remote = FakeRemote()
        check, observer, prefix = test.observe_daemon(remote)
        self.assertEqual(check['status'], 'PASS')
        self.assertEqual(prefix, '/var/jb')
        self.assertEqual(remote.words, ['/bin/ps', '-axo', 'pid=,comm='])
        remote.process_path = '/var/jb/usr/bin/redditboxd'
        self.assertEqual(test.observe_daemon(remote)[0]['status'], 'PASS')
        remote.process_path = '/tmp/unrelated/usr/bin/redditboxd'
        self.assertEqual(test.observe_daemon(remote)[0]['status'], 'FAIL')
        remote.process_path = ''
        self.assertEqual(test.observe_daemon(remote)[0]['status'], 'NOT_RUN')
        remote.returncode = 127
        self.assertEqual(test.observe_daemon(remote)[0]['status'], 'NOT_RUN')
        remote.returncode = 0
        remote.listing = b'1 /sbin/launchd\n'
        self.assertEqual(test.observe_daemon(remote)[0]['status'], 'FAIL')
        remote.listing = b'42 /var/jb/usr/bin/redditboxd\n43 /usr/bin/redditboxd\n'
        self.assertEqual(test.observe_daemon(remote)[0]['status'], 'FAIL')

    def lease(self):
        return dict(state='open',generation='gen',bootEpoch='boot',containerId='A',
                    bundleIdentifier='com.redditbox.clone.A',heartbeatAt=99,openedAt=92)
    def test_unknown_stale_and_mismatched_lease_never_pass(self):
        lease=self.lease(); fw=dict(lease,enforced=True,scope='per-app',policyAppliedAt=90)
        self.assertEqual(test.lease_checks(lease,fw,100)[0]['status'],'PASS')
        self.assertEqual(test.lease_checks(lease,fw,200)[0]['status'],'FAIL')
        self.assertEqual(test.lease_checks({}, {},100)[0]['status'],'FAIL')
        fw['generation']='different'
        self.assertEqual(test.lease_checks(lease,fw,100)[0]['status'],'FAIL')
    def test_bound_receipt_requires_every_actual_group(self):
        lease=self.lease(); groups,behavior=test.required_hooks()
        ready=dict(lease,allHooksInstalled=True,evidenceVersion=1,timestamp=91,
            installedGroups={k:True for k in groups},behaviorChecks={k:True for k in behavior})
        ready['bootEpoch']=hmac.new(b'boot',b'redditbox-clone-epoch-v1:com.redditbox.clone.A',hashlib.sha256).hexdigest()
        checks=test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=100)
        self.assertTrue(all(r['status']=='PASS' for r in checks))
        ready['installedGroups'][groups[0]]=False
        self.assertEqual(test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=100)[1]['status'],'FAIL')
        self.assertTrue(all(r['status']=='FAIL' for r in test.hook_checks(ready,lease,'/b','/a',groups,behavior,now=100)))
        ready['generation']='other'
        self.assertEqual(test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=100)[0]['status'],'FAIL')
    def test_empty_identity_and_future_hook_timestamp_never_pass(self):
        empty={key:'' for key in ('state','generation','bootEpoch','containerId','bundleIdentifier')}
        empty['heartbeatAt']=99
        self.assertEqual(test.lease_checks(empty,empty,100)[0]['status'],'FAIL')
        lease=self.lease(); groups,behavior=test.required_hooks()
        ready=dict(lease,allHooksInstalled=True,evidenceVersion=1,timestamp=9999999999,
            installedGroups={k:True for k in groups},behaviorChecks={k:True for k in behavior})
        ready['bootEpoch']=hmac.new(b'boot',b'redditbox-clone-epoch-v1:com.redditbox.clone.A',hashlib.sha256).hexdigest()
        self.assertTrue(all(r['status']=='FAIL' for r in test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=100)))
        ready['timestamp']=91; lease['heartbeatAt']=1
        self.assertTrue(all(r['status']=='FAIL' for r in test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=100)))
    def test_actual_arm_ready_open_order_and_epoch_provenance(self):
        lease=self.lease(); lease.update(openedAt=102,heartbeatAt=103)
        groups,behavior=test.required_hooks()
        ready=dict(lease,allHooksInstalled=True,evidenceVersion=1,timestamp=101,
            installedGroups={k:True for k in groups},behaviorChecks={k:True for k in behavior})
        ready['bootEpoch']=hmac.new(b'boot',b'redditbox-clone-epoch-v1:com.redditbox.clone.A',hashlib.sha256).hexdigest()
        self.assertTrue(all(r['status']=='PASS' for r in test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=103)))
        lease.update(state='armed',openedAt=100)
        self.assertTrue(all(r['status']=='PASS' for r in test.hook_checks(ready,lease,'/a','/a',groups,behavior,now=103)))
        self.assertTrue(test.same_boot_epoch('same','same'))
        self.assertFalse(test.same_boot_epoch('other-phone','same'))
        self.assertFalse(test.same_boot_epoch('',''))
        self.assertFalse(test.same_boot_epoch(None,None))
    def test_paths_and_malformed_observations(self):
        self.assertTrue(test.safe_data('/var/mobile/Containers/Data/Application/'+'A'*36))
        self.assertFalse(test.safe_data('/var/mobile/Containers/Data/Application/../../Library'))
        self.assertFalse(test.safe_bundle('/var/containers/Bundle/Application/../bad.app'))
        for value in (b'not plist',b'[]',b'{broken'):
            with self.assertRaises(test.Unavailable): test.parse_document(value)
    def test_ssh_quoting_timeout_and_secret_redaction(self):
        args=SimpleNamespace(total_timeout=240,port=22,target='mobile@phone',identity=None,control_path=None,ssh_config=None,sudo=False)
        remote=test.Remote(args)
        malicious="/var/test/quote' $(touch /tmp/bad); suffix"
        result=SimpleNamespace(returncode=0,stdout=b'ok',stderr=b'')
        with patch.object(test.subprocess,'run',return_value=result) as run:
            remote.command(['cat',malicious])
            actual=run.call_args.args[0][-1]
            self.assertEqual(shlex.split(actual),['cat',malicious])
            self.assertLessEqual(run.call_args.kwargs['timeout'],20)
        result.returncode=1; result.stderr=b'SECRET proxy password'
        with patch.object(test.subprocess,'run',return_value=result):
            with self.assertRaises(test.Unavailable) as raised: remote.command(['cat','x'])
            self.assertNotIn('SECRET',str(raised.exception))
    def test_password_stdin_never_enters_command_or_payload(self):
        args=SimpleNamespace(total_timeout=240,port=22,target='mobile@phone',identity=None,control_path=None,ssh_config=None,sudo=False,sudo_password=True)
        secret="fixture-'$(not-a-command)"
        with patch.object(test.getpass,'getpass',return_value=secret): remote=test.Remote(args)
        result=SimpleNamespace(returncode=0,stdout=b'ok',stderr=b'')
        with patch.object(test.subprocess,'run',return_value=result) as run:
            remote.command(['cat'],input=b'BINARY\x00PAYLOAD')
            self.assertNotIn(secret,' '.join(run.call_args.args[0]))
            self.assertEqual(run.call_args.kwargs['input'],secret.encode()+b'\nBINARY\x00PAYLOAD')
        with tempfile.TemporaryDirectory() as directory:
            fake=Path(directory)/'sudo'
            fake.write_text("#!/bin/sh\nif [ \"$1\" = -S ]; then\n  if [ \"$RBX_ACCEPTANCE_TEST_MODE\" = auth ]; then IFS= read -r value || exit 1; fi\n  exit 0\nfi\nshift 2\nexec \"$@\"\n")
            fake.chmod(0o755)
            for mode in ('auth','cached-or-nopasswd'):
                env=dict(os.environ,PATH=directory+os.pathsep+os.environ['PATH'],RBX_ACCEPTANCE_TEST_MODE=mode)
                payload=b'BINARY\x00PAYLOAD\nsecond-line'
                result=subprocess.run(['sh','-c',test.sudo_password_command('cat')],
                    input=secret.encode()+b'\n'+payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,timeout=5,check=True)
                self.assertEqual(result.stdout,payload,mode)
                self.assertNotIn(secret.encode(),result.stderr)
    def test_observer_never_sets_memory_limit_or_keychain(self):
        # Guard the device ABI call, in addition to compiling the actual observer.
        text=(test.ROOT/'tools/device_acceptance_probe.m').read_text()
        self.assertIn('control(8,',text)
        self.assertNotIn('control(7,',text)
        self.assertNotIn('SecItem',text)
        self.assertIn('O_EXCL|O_NOFOLLOW',text)
        self.assertIn('unlinkat(left,name.UTF8String,0)',text)

if __name__=='__main__': unittest.main()
