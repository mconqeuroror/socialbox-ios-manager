#!/usr/bin/env python3
"""Receipt/lifecycle fixtures for the real host orchestration (no phone writes)."""
import hashlib
import hmac
import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parent))
import device_acceptance_canaries as canary
import device_acceptance_ssh as common

class FakeRemote:
    def __init__(self,selected):
        self.selected=selected; self.probe='/tmp/private-probe'; self.clock=100; self.active='B'
        self.requests={}; self.sentinel=True; self.epoch='boot'; self.missing_foreign=False
    def lease(self):
        clone=self.selected[self.active]
        return dict(state='open',containerId=clone['id'],bundleIdentifier=clone['bundle'],bootEpoch=self.epoch,
            generation='generation-'+self.active+str(self.clock),heartbeatAt=self.clock,openedAt=self.clock-7)
    def ready(self):
        lease=self.lease(); groups,behavior=common.required_hooks()
        return dict(containerId=lease['containerId'],bundleIdentifier=lease['bundleIdentifier'],generation=lease['generation'],
            bootEpoch=hmac.new(self.epoch.encode(),('redditbox-clone-epoch-v1:'+lease['bundleIdentifier']).encode(),hashlib.sha256).hexdigest(),
            pid=101 if self.active=='A' else 102,timestamp=self.clock-8,evidenceVersion=1,allHooksInstalled=True,
            installedGroups={key:True for key in groups},behaviorChecks={key:True for key in behavior})
    def command(self,words,input=None):
        request=json.loads(input); self.requests[request['operation']]=request
        return SimpleNamespace(stdout=b'{"prepared":true}')
    def document(self,path):
        return self.ready() if 'hook-ready' in path else self.lease()
    def canonical(self,path): return path
    def observe(self,*args):
        if args[0]=='--pid': return {'path':self.selected[self.active]['executable']}
        if args[0]=='--remove-canary-controls': return {'cleaned':True}
        operation=args[-1]
        if operation=='sentinel': return dict(matches=self.sentinel,observedAt=self.clock)
        request=self.requests[operation]; ready=self.ready()
        entries=[]
        for ident in canary.IDS[operation]:
            code=next(iter(canary.EXPECTED_CODES.get(ident,{0})))
            if ident=='storage-foreign-denied' and self.missing_foreign: code=2
            entries.append(dict(id=ident,status='PASS',surfaceRows=['OS-009' if 'keychain' in ident else 'OS-033'],detail='PRIVATE ignored',statusCode=code))
        return dict(schemaVersion=1,nonce=request['nonce'],operation=operation,bundleIdentifier=request['targetBundleId'],
            pid=ready['pid'],uid=501,timestamp=self.clock-5,generation=ready['generation'],bootEpoch=ready['bootEpoch'],checks=entries)

class CanaryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.ledger=Path(self.temp.name)/'private.json'; self.checks=[]
        self.selected={}
        for label in ('A','B'):
            bundle='com.redditbox.profile.p'+label*30
            self.selected[label]=dict(id=label,bundle=bundle,group='RBXCLONE00.'+bundle,
                data='/private/var/mobile/Containers/Data/Application/'+label*8+'-'+label*4+'-'+label*4+'-'+label*4+'-'+label*12,
                executable='/var/containers/Bundle/Application/'+label+'/App.app/App')
        self.remote=FakeRemote(self.selected)
    def stage(self,operation=None,collect=False,abort=False):
        args=SimpleNamespace(canary_stage=operation,canary_collect=collect,canary_abort=abort,canary_ledger=self.ledger)
        with patch.object(canary.time,'time',return_value=self.remote.clock):
            canary.run(self.remote,args,self.selected,self.remote.lease(),self.checks,common.row)
    def seed_and_verify_prepare(self):
        self.stage('seed'); self.remote.active='A'; self.remote.clock=110; self.stage('verify')
    def test_ordered_actual_orchestration(self):
        self.seed_and_verify_prepare()
        self.remote.active='B'; self.remote.clock=120; self.stage('cleanup')
        self.remote.active='A'; self.remote.clock=130; self.stage(collect=True)
        self.assertTrue(canary.read_ledger(self.ledger)['finished'])
        verdict=next(row for row in self.checks if row['id']=='canary-A-B-A')
        self.assertEqual(verdict['status'],'PASS')
        self.assertNotIn('PRIVATE',json.dumps(self.checks))
    def test_missing_seed_and_foreign_enoent_cannot_pass(self):
        self.stage('seed'); self.remote.active='A'; self.remote.clock=110; self.remote.sentinel=False
        with self.assertRaises(canary.CanaryUnavailable): self.stage('verify')
        self.remote.sentinel=True; self.stage('verify'); self.remote.active='B'; self.remote.clock=120; self.remote.missing_foreign=True
        with self.assertRaises(canary.CanaryUnavailable): self.stage('cleanup')
    def test_cross_device_epoch_and_replayed_nonce_rejected(self):
        self.seed_and_verify_prepare(); self.remote.active='B'; self.remote.clock=120; self.remote.epoch='other-device'
        with self.assertRaises(canary.CanaryUnavailable): self.stage('cleanup')
        self.remote.epoch='boot'; self.remote.requests['verify']['nonce']='00000000-0000-0000-0000-000000000000'
        with self.assertRaises(canary.CanaryUnavailable): self.stage('cleanup')
    def test_active_target_and_foreign_ledger_not_overwritten(self):
        self.remote.active='A'
        with self.assertRaises(canary.CanaryUnavailable): self.stage('seed')
        self.assertFalse(self.remote.requests)
        with self.assertRaises(canary.CanaryUnavailable): self.stage('seed')
    def test_ledger_permissions_and_symlinks(self):
        self.stage('seed'); self.ledger.chmod(0o644)
        with self.assertRaises(canary.CanaryUnavailable): canary.read_ledger(self.ledger)
        link=self.ledger.with_name('link.json'); link.symlink_to(self.ledger)
        with self.assertRaises(canary.CanaryUnavailable): canary.read_ledger(link)

if __name__=='__main__': unittest.main()
