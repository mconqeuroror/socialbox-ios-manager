#!/usr/bin/env python3
"""Actual composition and rollback scripts against synthetic, nonexecutable inputs."""
import importlib.util,os,plistlib,stat,unittest,tempfile,subprocess
from contextlib import contextmanager
from unittest.mock import patch
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
s=load('safety',ROOT/'scripts/build-socialbox-helper-safety.py')
f=load('fixtures',ROOT/'tools/test_socialbox_recovered.py')
class Integrated(unittest.TestCase):
    def test_manager_license_service_is_packaged_with_exact_endpoint_and_no_original_changes(self):
        baseline,base,binaries=self.inputs();payload=s.extend_payload(baseline,base,binaries)
        service=f.fat();installer=f.fat()
        job={'Label':'com.socialbox.licensing','Program':'/var/jb/usr/libexec/socialbox-license-owner',
             'MachServices':{'com.socialbox.licensing':True},'UserName':'root','RunAtLoad':True,
             'KeepAlive':True,'ThrottleInterval':10,'ProcessType':'Interactive'}
        licensed=s.add_license_service(payload,service,plistlib.dumps(job),installer)
        self.assertEqual(set(licensed)-set(payload),s.LICENSE_PATHS)
        self.assertTrue(all(licensed[path]==data for path,data in payload.items()))
        self.assertEqual(licensed[s.LICENSE_SERVICE],service)
        self.assertEqual(licensed[s.LICENSE_INSTALLER],installer)
        with self.assertRaises(ValueError):s.add_license_service(payload,service,plistlib.dumps(job),b"invalid installer")
        for key,value in [('UserName','mobile'),('Program','/tmp/foreign'),('EnvironmentVariables',{'INJECT':'yes'}),('MachServices',{'foreign':True})]:
            with self.assertRaises(ValueError):s.add_license_service(payload,service,plistlib.dumps(dict(job,**{key:value})),installer)
        with self.assertRaises(ValueError):s.add_license_service(licensed,service,plistlib.dumps(job),installer)
        scripts,preflight,rollback=s.service_scripts(baseline,f.CONTROLS,license_owner=True)
        self.assertNotIn(b'com.socialbox.licensing',rollback)
        self.assertLess(scripts['postinst'].index(b'bootstrap system /var/jb/Library/LaunchDaemons/com.socialbox.licensing'),scripts['postinst'].index(b'bootstrap system /var/jb/Library/LaunchDaemons/com.socialboxhelper'))
        self.assertIn(b'bootout system/com.socialbox.licensing',scripts['prerm'])
        self.assertNotIn(b'socialbox-license-pairing',scripts['postinst']+scripts['prerm']+rollback)
        self.assertNotIn(b'\n/'+s.LICENSE_INSTALLER.encode(),b''.join(scripts.values()))
        for path in s.LICENSE_PATHS:self.assertIn(('/'+path).encode(),preflight)
        for script in scripts.values():subprocess.run(['/bin/sh','-n'],input=script,check=True,capture_output=True)
    def test_prior_archive_is_hash_pinned_before_reading_or_trusting_controls(self):
        with self.assertRaisesRegex(ValueError,'reviewed predecessor'):
            s.pinned_prior(b'not a trusted archive')
        baseline,_,_=self.inputs()
        scripts,_,_=s.service_scripts(baseline,f.CONTROLS)
        with patch.object(s.c,'VERSION',s.PRIOR_VERSION):
            archive=s.c.build_deb(baseline,scripts,{k:0o644 for k in baseline},'mobilesubstrate')
        # Synthetic predecessor has no executable content; only the trusted
        # digest seam changes in this isolated fixture.
        with patch.object(s,'PRIOR_SHA256',s.c.sha(archive)):
            payload,modes,controls=s.pinned_prior(archive)
            self.assertEqual(payload,baseline)
            self.assertEqual(set(modes),set(baseline))
            self.assertEqual(controls,scripts)
            with self.assertRaises(ValueError):s.pinned_prior(archive+b'changed')

    def test_helper_uses_exact_executable_filter_without_launchd_dyld_environment(self):
        baseline,base,binaries=self.inputs();p=s.extend_payload(baseline,base,binaries)
        self.assertEqual(p[s.HELPER_PLIST],baseline[s.HELPER_PLIST])
        self.assertEqual(plistlib.loads(p[s.HELPER_FILTER]),{'Filter':{'Executables':['SocialBoxHelper']}})
        self.assertTrue(s.LIBRARY.startswith('var/jb/Library/MobileSubstrate/DynamicLibraries/'))
        self.assertNotIn('EnvironmentVariables',plistlib.loads(p[s.HELPER_PLIST]))

    def inputs(self):
        baseline=f.baseline();baseline[s.HELPER_PLIST]=plistlib.dumps({'Program':'/var/jb/usr/libexec/SocialBoxHelper','Label':'com.socialboxhelper','MachServices':{'com.socialboxhelper.xpc':True},'KeepAlive':True})
        for path in s.c.EXTENSION_COPY:
            directory=path.removesuffix('Info.plist');name=Path(directory.rstrip('/')).stem
            baseline[path]=plistlib.dumps({'CFBundleName':name,'CFBundleDisplayName':name,'CFBundleExecutable':name,
                'CFBundleIdentifier':'original.extension','NSExtension':{'NSExtensionPointIdentifier':'original'}})
            baseline[directory+name]=f.thin()
        base,_=s.c.make_payload(baseline,f.overlay(),f.filters(),f.icons())
        return baseline,base,{'library':f.overlay(),'app_library':f.overlay(),'service':f.fat()}
    def test_only_reviewed_delta_preserves_programs_and_licensing(self):
        baseline,base,binaries=self.inputs();p=s.extend_payload(baseline,base,binaries)
        self.assertEqual({k for k in baseline if baseline[k]!=p[k]},s.c.presentation_paths(baseline))
        self.assertEqual(p[s.c.BINARY],baseline[s.c.BINARY])
        self.assertEqual(p[s.HELPER_PLIST],baseline[s.HELPER_PLIST])
        self.assertEqual(plistlib.loads(p[s.c.INFO])['SocialBoxBuild'],s.VERSION)
        self.assertEqual(set(p)-set(baseline),s.c.ADDED_PATHS|s.NEW_PATHS)
        self.assertEqual(plistlib.loads(p[s.APP_FILTER]),{'Filter':{'Bundles':['com.socialbox.app']}})
    def test_rejects_unreviewed_host_environment_and_host_target(self):
        for key,value in [('EnvironmentVariables',{'DYLD_INSERT_LIBRARIES':'/unreviewed.dylib'}),('Program','/usr/bin/other'),('Label','other')]:
            data={'Program':'/var/jb/usr/libexec/SocialBoxHelper','Label':'com.socialboxhelper',key:value}
            with self.assertRaises(ValueError):s.helper_plist(plistlib.dumps(data))
    def test_wrong_architecture_kind_and_test_artifact_rejected(self):
        for raw,kind in [(f.thin(),2),(f.overlay(),2),(f.fat(),6),(f.fat(first=f.thin()+b'Fixture'),2)]:
            with self.assertRaises(ValueError):s.validate_program(raw,kind)
    def test_upgrade_and_unwind_order_are_independent(self):
        baseline,_,_=self.inputs();scripts,preflight,rollback=s.service_scripts(baseline,f.CONTROLS)
        self.assertNotIn(b'com.socialbox.processdrain',rollback)
        self.assertEqual(rollback,s.c.maintainer_scripts(baseline,f.CONTROLS)[0]['postinst'])
        post=scripts['postinst'];pre=scripts['prerm']
        self.assertLess(post.index(b'launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.socialbox.processdrain'),post.index(b'launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.socialboxhelper'))
        self.assertLess(pre.index(b'bootout system/com.socialboxhelper'),pre.index(b'bootout system/com.socialbox.processdrain'))
        for path in s.NEW_PATHS:self.assertIn(('/'+path).encode(),preflight)
        self.assertIn(s.c.sha(rollback).encode(),preflight)
        self.assertIn(b'Separate com.redditbox exists',preflight)
        for script in [*scripts.values(),preflight,rollback]:
            subprocess.run(['/bin/sh','-n'],input=script,check=True,capture_output=True)
    def test_build_source_manifest_includes_transitive_registry(self):
        before=s.snapshot();self.assertIn('lucid/Switching/LBXManagedApplications.def',before['sha256'])
        self.assertIn('lucid/HelperSafety/LBXCallerFile.m',before['translation_units']['service'])
        self.assertIn('lucid/HelperSafety/LBXCallerFile.h',before['sha256'])
        self.assertIn('shared/RBXProc.h',before['sha256']);self.assertIn('lucid/HelperSafety/LBXXPC.h',before['sha256'])
        self.assertNotIn('lucid/Authorization/LBXLicenseExchange.m',before['sha256'])
        self.assertIn('lucid/HelperSafety/LBXAppSwitchSafety.m',before['translation_units']['app_library'])

    def test_license_report_distinguishes_implemented_establishment_from_unrun_delivery(self):
        scope=s.license_delivery_scope()
        self.assertFalse(scope['freshInstallReady'])
        self.assertFalse(scope['customerDeliveryReady'])
        self.assertIn('Source licensing and saved-setup metadata only',scope['license_scope'])
        self.assertIn('retained app startup, daemon session and injected-engine admission are not integrated',scope['license_scope'])
        self.assertIn('NOT_RUN',scope['installerExecution'])
        self.assertIn('not invoked',scope['installerExecution'])
        self.assertIn('Implemented with typed prepared provenance',scope['pairedPendingEstablishment'])
        self.assertIn('normal-endpoint customer installation NOT_RUN',scope['pairedPendingEstablishment'])
        self.assertNotIn('unfinished',str(scope))

class SourceStatePreservation(unittest.TestCase):
    """Full emitted guards in a temporary tree with inert command providers."""
    @contextmanager
    def fixture(self,prior=False):
        host=f.ScriptBehavior('test_exact_base_preflight_is_read_only')
        host.setUp()
        try:
            for path in s.c.ADDED_PATHS|s.NEW_PATHS|s.LICENSE_PATHS:
                (host.bootstrap/path.removeprefix('var/jb/')).parent.mkdir(parents=True,exist_ok=True)
            (host.bootstrap/'var/lib').mkdir(parents=True,mode=0o755,exist_ok=True)
            scripts,preflight,rollback=s.service_scripts(host.original,f.CONTROLS,license_owner=True)
            if prior:
                old=dict(host.original)
                for path in s.c.ADDED_PATHS|s.NEW_PATHS|s.LICENSE_PATHS:
                    raw=('inert prior payload '+path).encode()
                    node=host.bootstrap/path.removeprefix('var/jb/')
                    node.write_bytes(raw);node.chmod(0o644)
                    old[path]=raw
                controls={name:scripts[name] for name in ('preinst','postinst','prerm')}
                for name,raw in controls.items():
                    (host.controls/name).write_bytes(raw);(host.controls/name).chmod(0o755)
                modes={path:(host.bootstrap/path.removeprefix('var/jb/')).stat().st_mode&0o7777 for path in old}
                scripts,preflight=s.prior_scripts(scripts,(old,modes,controls),dict(old),f.CONTROLS,rollback)
                host.state['version']=s.PRIOR_VERSION;host.state['unknown_control']='preinst'
            host.scripts=scripts;host.preflight=preflight
            yield host
        finally:
            host.tearDown()

    @staticmethod
    def witness(root):
        nodes=[root,*root.rglob('*')] if root.is_dir() and not root.is_symlink() else [root]
        result={}
        for node in nodes:
            info=node.lstat()
            value=(info.st_dev,info.st_ino,info.st_mode,info.st_uid,info.st_gid,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
            if stat.S_ISLNK(info.st_mode):value+=(os.readlink(node),)
            elif stat.S_ISREG(info.st_mode):value+=(node.read_bytes(),)
            result[str(node.relative_to(root))]=value
        return result

    def check_guard(self,host,name,success):
        result=host.run_script(name,args=('upgrade',host.state['version']))
        self.assertEqual(result.returncode==0,success,result.stderr)
        self.assertFalse(any(call[0] in ('launchctl','uicache') for call in host.calls()))
        self.assertFalse(any(call[0]=='socialbox-prepare-installation' for call in host.calls()))
        return result

    def test_all_absent_paths_allow_only_pinned_upgrade_and_preserve_tree(self):
        for prior in (False,True):
            with self.subTest(prior=prior),self.fixture(prior) as host:
                before=self.witness(host.bootstrap)
                for name in ('preflight','preinst'):
                    self.check_guard(host,name,True)
                    self.assertEqual(self.witness(host.bootstrap),before)
                for path in s.SOURCE_STATE_PATHS:
                    node=host.bootstrap/path.removeprefix('/var/jb/')
                    self.assertFalse(node.exists() or node.is_symlink())
                result=host.run_script('preinst',args=('install',))
                self.assertNotEqual(result.returncode,0)
                self.assertIn('no fresh installation',result.stderr)

    def test_each_existing_node_type_refuses_both_guards_without_changing_state(self):
        for prior in (False,True):
            with self.fixture(prior) as host:
                for path in s.SOURCE_STATE_PATHS:
                    node=host.bootstrap/path.removeprefix('/var/jb/')
                    for kind in ('directory','file','symlink','dangling-symlink','fifo'):
                        with self.subTest(prior=prior,path=path,kind=kind):
                            target=host.root/'synthetic-target'
                            if kind=='directory':
                                node.mkdir(mode=0o700);(node/'sentinel').write_bytes(b'preserve synthetic owner state')
                            elif kind=='file':node.write_bytes(b'preserve synthetic partial state')
                            elif kind=='fifo':os.mkfifo(node,0o600)
                            else:
                                if kind=='symlink':target.write_bytes(b'preserve synthetic link target')
                                node.symlink_to(target)
                            before=self.witness(host.bootstrap)
                            target_before=self.witness(target) if target.exists() else None
                            for name in ('preflight','preinst'):
                                result=self.check_guard(host,name,False)
                                self.assertIn('Source installation state exists',result.stderr)
                                self.assertNotIn('PASS:',result.stdout)
                                self.assertEqual(self.witness(host.bootstrap),before)
                                if target_before:self.assertEqual(self.witness(target),target_before)
                            if kind=='directory':(node/'sentinel').unlink();node.rmdir()
                            else:node.unlink()
                            if target.exists():target.unlink()

    def test_unsafe_source_parents_refuse_before_absence_is_interpreted(self):
        for prior in (False,True):
            for relative,kind in (('var','alias'),('var/lib','alias'),('var/lib','dangling-alias'),('var/lib','file'),('var/lib','missing'),('var/lib','writable')):
                with self.subTest(prior=prior,parent=relative,kind=kind),self.fixture(prior) as host:
                    parent=host.bootstrap/relative
                    target=host.root/'synthetic-parent'
                    if kind=='writable':parent.chmod(0o777)
                    else:
                        parent.rename(target)
                        if kind in ('alias','dangling-alias'):
                            parent.symlink_to(target if kind=='alias' else host.root/'missing-parent',target_is_directory=True)
                        elif kind=='file':parent.write_bytes(b'synthetic parent is not a directory')
                    before=self.witness(host.bootstrap)
                    target_before=self.witness(target) if target.exists() else None
                    for name in ('preflight','preinst'):
                        result=self.check_guard(host,name,False)
                        self.assertIn('parent',result.stderr.lower())
                        self.assertNotIn('Source installation state exists',result.stderr)
                        self.assertEqual(self.witness(host.bootstrap),before)
                        if target_before:self.assertEqual(self.witness(target),target_before)

    def test_baseline_and_prior_compose_guard_before_success_without_mutating_scripts(self):
        for prior in (False,True):
            with self.subTest(prior=prior),self.fixture(prior) as host:
                for raw in (host.preflight,host.scripts['preinst']):
                    self.assertEqual(raw.count(s.source_state_guard().encode()),1)
                    self.assertLess(raw.index(b'verify_parent_chain "$source_state"'),raw.index(b'[ ! -e "$source_state" ]'))
                    self.assertLess(raw.index(b'[ ! -L "$source_state" ]'),raw.rindex(b'echo '))
                    self.assertIn(b'no fresh installation',raw)
                    subprocess.run(['/bin/sh','-n'],input=raw,check=True,capture_output=True)
                for raw in (host.scripts['postinst'],host.scripts['prerm']):
                    self.assertNotIn(s.source_state_guard().encode(),raw)
                    self.assertNotIn(b'\n/'+s.LICENSE_INSTALLER.encode(),raw)
if __name__=='__main__':unittest.main()
