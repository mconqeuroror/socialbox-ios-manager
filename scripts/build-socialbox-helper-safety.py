#!/usr/bin/env python3
"""Build the private recovered-base candidate with checked helper stop integration.

No imported program executes. No device is modified. This is not the completed
storage transaction/network-isolation port. The emitted preflight still refuses
coexistence with an unmigrated com.redditbox installation.
"""
import argparse,importlib.util,io,json,os,plistlib,re,subprocess,tarfile,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('recovered_candidate',ROOT/'scripts/build-socialbox-recovered.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
VERSION='3.1.0-1+socialbox.18'
PRIOR_VERSION='3.1.0-1+socialbox.17'
PRIOR_SHA256='5a095ad0c05a6eabfb335ae9be03c15a6be9d443c77f0fc33bdd9ff3bf92bba7'
HELPER_PLIST='var/jb/Library/LaunchDaemons/com.socialboxhelper.plist'
SERVICE_PLIST='var/jb/Library/LaunchDaemons/com.socialbox.processdrain.plist'
LIBRARY='var/jb/Library/MobileSubstrate/DynamicLibraries/LBXHelperSafety.dylib'
HELPER_FILTER=LIBRARY.removesuffix('.dylib')+'.plist'
SERVICE='var/jb/usr/libexec/socialbox-drain-service'
APP_LIBRARY='var/jb/Library/MobileSubstrate/DynamicLibraries/LBXAppSwitchSafety.dylib'
APP_FILTER=APP_LIBRARY.removesuffix('.dylib')+'.plist'
NEW_PATHS={LIBRARY,HELPER_FILTER,SERVICE,SERVICE_PLIST,APP_LIBRARY,APP_FILTER}
LICENSE_SERVICE='var/jb/usr/libexec/socialbox-license-owner'
LICENSE_PLIST='var/jb/Library/LaunchDaemons/com.socialbox.licensing.plist'
LICENSE_INSTALLER='var/jb/usr/libexec/socialbox-prepare-installation'
LICENSE_PATHS={LICENSE_SERVICE,LICENSE_PLIST,LICENSE_INSTALLER}
SOURCE_STATE_PATHS=(
    '/var/jb/var/lib/socialbox-installation',
    '/var/jb/var/lib/socialbox-license-pairing',
    '/var/jb/var/lib/socialbox-container-configurations',
    '/var/jb/var/lib/socialbox-container-pending',
    '/var/jb/var/lib/.socialbox-container-pending.socialbox-root-pending-v1.json')
VARIABLES={'library':'LBXHelperSafety_FILES','app_library':'LBXAppSwitchSafety_FILES','service':'socialbox-drain-service_FILES'}
UNITS={
 'library':['lucid/HelperSafety/LBXHelperSafety.m','lucid/HelperSafety/LBXDrainClient.m','lucid/HelperSafety/LBXDrainProtocol.m','lucid/Switching/LBXManagedApplications.m'],
 'app_library':['lucid/HelperSafety/LBXAppSwitchSafety.m','lucid/HelperSafety/LBXDrainClient.m','lucid/HelperSafety/LBXDrainProtocol.m','lucid/HelperSafety/LBXGlobalMetadata.m','lucid/HelperSafety/LBXGlobalMetadataHook.m','lucid/Switching/LBXManagedApplications.m'],
 'service':['lucid/HelperSafety/Service.m','lucid/HelperSafety/LBXCallerFile.m','lucid/HelperSafety/LBXDrainProtocol.m','lucid/Switching/LBXManagedApplications.m','lucid/Switching/LBXProcessDrain.m','lucid/Switching/LBXDarwinDrainBackend.m','shared/RBXProcessIdentity.m']}

def snapshot(root=ROOT):
    root=root.resolve(); paths=set(sum(UNITS.values(),[]))|{'lucid/HelperSafety/Makefile','lucid/HelperSafety/com.socialbox.processdrain.plist','lucid/HelperSafety/LBXAppSwitchSafety.plist','lucid/HelperSafety/LBXHelperSafety.plist','lucid/Switching/ProcessDrain.entitlements'}
    pending=list(paths); hashes={}
    while pending:
        name=pending.pop();p=root/name
        c.require(p.is_file() and p.resolve()==p and p.is_relative_to(root),'Missing/aliased production input: '+name)
        data=p.read_bytes();hashes[name]=c.sha(data)
        if p.suffix not in ('.h','.m','.def'):continue
        for include in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"',data.decode(),re.M):
            target=Path(os.path.abspath(p.parent/include))
            c.require(target.is_relative_to(root) and target.suffix in ('.h','.def'),'Escaping/non-header dependency')
            relative=str(target.relative_to(root))
            if relative not in paths:paths.add(relative);pending.append(relative)
    make=(root/'lucid/HelperSafety/Makefile').read_text()
    for kind,variable in VARIABLES.items():
        values=re.findall(r'^'+re.escape(variable)+r'\s*=\s*(.*)$',make,re.M)
        expected=' '.join(os.path.relpath(root/name,root/'lucid/HelperSafety') for name in UNITS[kind])
        c.require(values==[expected],'Unreviewed helper source selection: '+variable)
    return {'translation_units':UNITS,'sha256':dict(sorted(hashes.items()))}

def helper_plist(original):
    data=plistlib.loads(original)
    c.require(data.get('Program')=='/var/jb/usr/libexec/SocialBoxHelper' and data.get('Label')=='com.socialboxhelper','Unexpected helper service')
    c.require('EnvironmentVariables' not in data,'Existing helper loader environment needs review')
    return original

def validate_program(raw,filetype):
    slices=[(c.MachO(part),part) for _,part in c.macho_slices(raw)]
    c.require(len(slices)==2 and {m.cpu for m,_ in slices}=={0x100000c} and
              {m.subtype&0xffffff for m,_ in slices}=={0,2},'Both iOS architectures required')
    c.require(all(m.filetype==filetype and sum(cmd['command']=='0x1d' for cmd in m.commands)==1 for m,_ in slices),'Expected signed output kind')
    c.require(not any(marker in part for _,part in slices for marker in [b'ForTest',b'Fixture',b'LBX_HELPER_SAFETY_TEST']), 'Test seam in production output')
    return [{'subtype':m.subtype,'sha256':c.sha(part)} for m,part in slices]

def build(theos,ldid,sdk):
    before=snapshot();command=['make',f'THEOS={theos.resolve()}',f'TARGET_CODESIGN={ldid.resolve()}',
        f'TARGET=iphone:clang:{sdk}:15.0','FINALPACKAGE=1','THEOS_PACKAGE_SCHEME=rootless','ARCHS=arm64 arm64e']
    for kind,variable in VARIABLES.items():
        command.append(variable+'='+' '.join(os.path.relpath(ROOT/name,ROOT/'lucid/HelperSafety') for name in UNITS[kind]))
    subprocess.run(command+['clean'],cwd=ROOT/'lucid/HelperSafety',check=True)
    subprocess.run(command+['all'],cwd=ROOT/'lucid/HelperSafety',check=True)
    # FINALPACKAGE selects the release merge directory; avoid a stale debug file.
    obj=ROOT/'lucid/HelperSafety/.theos/obj'
    binaries={}
    for key,filename,kind in [('library','LBXHelperSafety.dylib',6),('app_library','LBXAppSwitchSafety.dylib',6),('service','socialbox-drain-service',2)]:
        matches=[p for p in obj.rglob(filename) if p.is_file() and 'arm64' not in p.parts and 'arm64e' not in p.parts and '.dSYM' not in str(p)]
        c.require(len(matches)==1,'Ambiguous merged helper output: '+filename)
        path=matches[0];raw=path.read_bytes();validate_program(raw,kind)
        expected=plistlib.loads((ROOT/'lucid/Switching/ProcessDrain.entitlements').read_bytes()) if key=='service' else {}
        # ldid -e on a fat binary emits multiple XML documents. Verify every
        # actual slice independently instead of checking just the first result.
        with tempfile.TemporaryDirectory(prefix='socialbox-entitlements-') as directory:
            for index,(_,part) in enumerate(c.macho_slices(raw)):
                thin=Path(directory)/str(index);thin.write_bytes(part)
                extracted=subprocess.run([str(ldid),'-e',str(thin)],check=True,capture_output=True).stdout
                ent=plistlib.loads(extracted) if extracted.strip() else {}
                c.require(ent==expected,'Unexpected helper entitlements in slice '+str(index))
        c.require(path.read_bytes()==raw,'Binary changed during verification')
        binaries[key]=raw
    c.require(snapshot()==before,'Helper inputs changed during build')
    return binaries,before

def extend_payload(baseline,base_payload,binaries):
    c.validate_payload(baseline,base_payload)
    validate_program(binaries['library'],6);validate_program(binaries['service'],2)
    validate_program(binaries['app_library'],6)
    app_filter=(ROOT/'lucid/HelperSafety/LBXAppSwitchSafety.plist').read_bytes()
    c.require(plistlib.loads(app_filter)=={'Filter':{'Bundles':['com.socialbox.app']}},'App switch guard filter exceeds reviewed manager')
    helper_filter=(ROOT/'lucid/HelperSafety/LBXHelperSafety.plist').read_bytes()
    c.require(plistlib.loads(helper_filter)=={'Filter':{'Executables':['SocialBoxHelper']}},'Helper filter exceeds reviewed executable')
    payload=dict(base_payload)
    payload.update({LIBRARY:binaries['library'],HELPER_FILTER:helper_filter,APP_LIBRARY:binaries['app_library'],APP_FILTER:app_filter,SERVICE:binaries['service'],SERVICE_PLIST:(ROOT/'lucid/HelperSafety/com.socialbox.processdrain.plist').read_bytes(),HELPER_PLIST:helper_plist(baseline[HELPER_PLIST])})
    info=plistlib.loads(payload[c.INFO]);info['SocialBoxBuild']=VERSION;payload[c.INFO]=plistlib.dumps(info,sort_keys=True)
    c.require(set(payload)-set(baseline)==c.ADDED_PATHS|NEW_PATHS,'Unexpected integrated payload path')
    c.require({p for p in baseline if payload[p]!=baseline[p]}==c.presentation_paths(baseline),'Unapproved original file change')
    c.original_code_evidence(baseline,payload)
    return payload

def add_license_service(payload,service,job,installer):
    validate_program(service,2)
    validate_program(installer,2)
    expected={'Label':'com.socialbox.licensing','Program':'/'+LICENSE_SERVICE,
              'MachServices':{'com.socialbox.licensing':True},'UserName':'root','RunAtLoad':True,
              'KeepAlive':True,'ThrottleInterval':10,'ProcessType':'Interactive'}
    c.require(plistlib.loads(job)==expected,'Unreviewed licensing service definition')
    c.require(not set(payload)&LICENSE_PATHS,'License service destination collision')
    return dict(payload,**{LICENSE_SERVICE:service,LICENSE_PLIST:job,LICENSE_INSTALLER:installer})

def source_state_guard():
    # Package replacement changes the fixed image witnesses in prepared state.
    # Until migration is reviewed, refuse every existing/partial source node.
    # Absence permits only this pinned upgrade check, never initialization.
    paths=' '.join(SOURCE_STATE_PATHS)
    return f'''# Preserve source licensing/configuration provenance before unpack.
for source_state in {paths}; do
    verify_parent_chain "$source_state"
done
for source_state in {paths}; do
    [ ! -e "$source_state" ] && [ ! -L "$source_state" ] || fail 'Source installation state exists; reviewed migration is required (nothing was reset)'
done
'''

def before_success(script,marker):
    c.require(script.endswith(marker),'Unknown source preservation guard order')
    return script[:-len(marker)]+source_state_guard().encode()+marker

def license_delivery_scope():
    return {'license_scope':'Source licensing and saved-setup metadata only; retained app startup, daemon session and injected-engine admission are not integrated',
        'freshInstallReady':False,'customerDeliveryReady':False,
        'installerExecution':'NOT_RUN; explicit preparation is not invoked by this upgrade-only package',
        'pairedPendingEstablishment':'Implemented with typed prepared provenance after genuine activation/validation; normal-endpoint customer installation NOT_RUN'}

def service_scripts(baseline,controls,license_owner=False):
    # The old-package rollback script must NOT require the new service: dpkg
    # can call it before any new files exist. Its exact original recovery stays.
    old_scripts,_=c.maintainer_scripts(baseline,controls)
    rollback=old_scripts['postinst']
    old_paths=c.ADDED_PATHS
    try:
        c.ADDED_PATHS=old_paths|NEW_PATHS|(LICENSE_PATHS if license_owner else set())
        scripts,preflight=c.maintainer_scripts(baseline,controls)
    finally:c.ADDED_PATHS=old_paths
    start=b'''if launchctl print system/com.socialbox.processdrain >/dev/null 2>&1; then
    launchctl kickstart -k system/com.socialbox.processdrain
else
    launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.socialbox.processdrain.plist
fi
'''
    marker=b'if launchctl print system/com.socialboxhelper'
    c.require(scripts['postinst'].count(marker)==1,'Unknown original startup order')
    scripts['postinst']=scripts['postinst'].replace(marker,start+marker,1)
    stop=b'''if launchctl print system/com.socialbox.processdrain >/dev/null 2>&1; then
    launchctl bootout system/com.socialbox.processdrain
fi
'''
    marker=b'if [ "${1:-}" = remove ]; then'
    c.require(scripts['prerm'].count(marker)==1,'Unknown original shutdown order')
    scripts['prerm']=scripts['prerm'].replace(marker,stop+marker,1)
    if license_owner:
        start=b'''if launchctl print system/com.socialbox.licensing >/dev/null 2>&1; then
    launchctl kickstart -k system/com.socialbox.licensing
else
    launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.socialbox.licensing.plist
fi
'''
        marker=b'if launchctl print system/com.socialbox.processdrain'
        c.require(scripts['postinst'].count(marker)==1,'Unknown licensing startup order')
        scripts['postinst']=scripts['postinst'].replace(marker,start+marker,1)
        stop=b'''if launchctl print system/com.socialbox.licensing >/dev/null 2>&1; then
    launchctl bootout system/com.socialbox.licensing
fi
'''
        marker=b'if [ "${1:-}" = remove ]; then'
        scripts['prerm']=scripts['prerm'].replace(marker,stop+marker,1)
    scripts['preinst']=before_success(scripts['preinst'],b"echo 'SocialBox exact-base preflight passed; device acceptance remains NOT_RUN'\n")
    preflight=before_success(preflight,b"echo 'PASS: exact reviewed base; runtime acceptance remains NOT_RUN'\n")
    return scripts,preflight,rollback

def pinned_prior(raw):
    # This is an exact locally built predecessor, not a caller-trusted report
    # or permission to accept arbitrary packages/source paths.
    c.require(c.sha(raw)==PRIOR_SHA256,'Only the reviewed predecessor archive is admitted')
    from apt_repository import archive_members
    members=archive_members(raw)
    c.require(set(members)=={'debian-binary','data.tar.gz','control.tar.gz'} and members['debian-binary']==b'2.0\n','Unexpected predecessor archive')
    def files(name):
        with tarfile.open(fileobj=io.BytesIO(members[name]),mode='r:gz') as archive:
            entries=archive.getmembers()
            c.require(len({e.name for e in entries})==len(entries) and all(e.uid==e.gid==0 and (e.isfile() or e.isdir()) for e in entries),'Unexpected predecessor entries')
            return ({e.name:archive.extractfile(e).read() for e in entries if e.isfile()},
                    {e.name:e.mode for e in entries if e.isfile()})
    payload,modes=files('data.tar.gz');controls,_=files('control.tar.gz')
    c.require(set(controls)=={'control','md5sums','preinst','postinst','prerm'} and
              ('Version: '+PRIOR_VERSION+'\n').encode() in controls['control'],'Unexpected predecessor controls')
    return payload,modes,{k:controls[k] for k in ('preinst','postinst','prerm')}

def prior_scripts(scripts,prior,payload,original_controls,rollback):
    old,modes,controls=prior
    def guard(incoming=False):
        return c.shell_guard(old,original_controls,rollback,incoming_preinst=incoming,
            base_version=PRIOR_VERSION,installed_controls=controls,baseline_modes=modes,
            added_paths=set(payload)-set(old))+source_state_guard()
    scripts=dict(scripts)
    scripts['preinst']=('#!/bin/sh\n'+guard(True)+"echo 'Pinned SocialBox predecessor verified'\n").encode()
    preflight=('#!/bin/sh\nset -- upgrade '+PRIOR_VERSION+'\n'+guard()+"echo 'PASS: pinned SocialBox predecessor'\n").encode()
    return scripts,preflight

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('handoff',type=Path);p.add_argument('--theos',type=Path,required=True);p.add_argument('--ldid',type=Path,required=True);p.add_argument('--sdk',default='26.5');p.add_argument('--output',type=Path,required=True);p.add_argument('--upgrade-from-candidate',type=Path)
    p.add_argument('--license-public-key',type=Path,required=True);p.add_argument('--openssl',default='openssl');args=p.parse_args()
    c.require(not args.output.exists() and not args.output.resolve().is_relative_to(ROOT),'Use new private output directory outside repo')
    manifest,files,baseline,modes,fields=c.load_handoff(args.handoff)
    prior=pinned_prior(args.upgrade_from_candidate.read_bytes()) if args.upgrade_from_candidate else None
    overlay,filters,overlay_inputs=c.build_overlay(args.theos,args.ldid,args.sdk)
    icons={n:(ROOT/'launcher/Resources'/n).read_bytes() for n in c.ICON_NAMES}
    base_payload,evidence=c.make_payload(baseline,overlay,filters,icons)
    binaries,helper_inputs=build(args.theos,args.ldid,args.sdk)
    payload=extend_payload(baseline,base_payload,binaries)
    args.output.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with tempfile.TemporaryDirectory(prefix='socialbox-license-build-',dir=args.output.parent) as directory:
        owner_output=Path(directory)/'owner'
        subprocess.run([c.sys.executable,str(ROOT/'scripts/build-socialbox-license-service.py'),
            '--consumer','manager','--public-key',str(args.license_public_key.resolve()),'--ldid',str(args.ldid.resolve()),
            '--openssl',args.openssl,'--output',str(owner_output.resolve())],check=True)
        owner_report=json.loads((owner_output/'build-report.json').read_text())
        owner=(owner_output/'service').read_bytes();job=(owner_output/'service.plist').read_bytes();installer=(owner_output/'installer').read_bytes()
        c.require(owner_report['kind']=='manager-license-owner-candidate' and
                  owner_report['service']['sha256']==c.sha(owner) and owner_report['launchdSHA256']==c.sha(job) and
                  owner_report['installer']['sha256']==c.sha(installer) and owner_report['installerPath']=='/'+LICENSE_INSTALLER,
                  'Licensing build output changed')
        c.require(owner_report['client']['sha256']==c.sha(baseline[c.BINARY]) and owner_report['client']['size']==len(baseline[c.BINARY]) and
                  owner_report['clientPath']=='/'+c.BINARY,'Licensing caller pin differs from packaged manager')
        payload=add_license_service(payload,owner,job,installer)
    controls={n:files['package-control/'+n] for n in ('prerm','postinst')}
    scripts,preflight,rollback=service_scripts(baseline,controls,license_owner=True)
    if prior is not None:scripts,preflight=prior_scripts(scripts,prior,payload,controls,rollback)
    modes.update({c.OVERLAY:0o755,c.FILTER:0o644,**{c.APP+n:0o644 for n in c.ICON_NAMES},LIBRARY:0o755,HELPER_FILTER:0o644,APP_LIBRARY:0o755,APP_FILTER:0o644,SERVICE:0o755,SERVICE_PLIST:0o644,HELPER_PLIST:0o644})
    modes.update({LICENSE_SERVICE:0o755,LICENSE_PLIST:0o644,LICENSE_INSTALLER:0o755})
    # The exact manager is a service client: it may not remain group-writable.
    # Retain original setuid/setgid bits and every original program byte.
    modes[c.BINARY]=0o6755;modes['var/jb/usr/local/bin/SocialBoxCLI']=0o6775
    old_version=c.VERSION
    try:c.VERSION=VERSION;deb=c.build_deb(payload,scripts,modes,fields['Depends'])
    finally:c.VERSION=old_version
    report={'schemaVersion':1,'version':VERSION,'upgrade_from':PRIOR_VERSION if prior is not None else c.BASE_VERSION,'predecessor_sha256':PRIOR_SHA256 if prior is not None else None,'status':'PRIVATE_HELPER_INTEGRATION_NOT_STORAGE_OR_NETWORK_ACCEPTANCE','installed':False,
      'package_sha256':c.sha(deb),'handoff_sha256':c.recovery.HANDOFF_SHA256,'builder_sha256':c.sha(Path(__file__).read_bytes()),
      'overlay_build_inputs':overlay_inputs,'helper_build_inputs':helper_inputs,'helper_sdk':args.sdk,
      'license_owner_build':owner_report,
      **license_delivery_scope(),
      'ldid_sha256':c.sha(args.ldid.read_bytes()),'helper_outputs':{key:{'sha256':c.sha(value),'slices':validate_program(value,2 if key=='service' else 6)} for key,value in binaries.items()},
      'changed_original_modes':{c.BINARY:'06755'},'app_guard_scope':'Exact pinned per-app stop callsite only; original five-second pre-write abort; direct checked service, no old-helper BOOL fallback',
      'changed_original_paths':sorted(c.presentation_paths(baseline)),'added_paths':sorted(c.ADDED_PATHS|NEW_PATHS|LICENSE_PATHS),'original_programs':c.original_code_evidence(baseline,payload),
      'original_programs_resigned':False,'controls_executed':False,'original_controls_backup_required':True,'com_redditbox_migration_required':True,
      'deployment':{'backup_path':c.BACKUP_PATH,'original_postinst_sha256':c.sha(controls['postinst']),'replacement_postinst_sha256':c.sha(rollback)},
      'residuals':['Global/deactivation/batch workers still discard stop failure; checked storage transaction is unfinished.','No launch fence or measured network/isolation acceptance.','Physical original-worker, licence, UI and rollback require device acceptance.'],
      'payload_sha256':{path:c.sha(raw) for path,raw in sorted(payload.items())}}
    args.output.mkdir(parents=True,mode=0o700)
    for name,data,mode in [('socialbox-helper-integration-unvalidated.deb',deb,0o600),('build-report.json',(json.dumps(report,indent=2)+'\n').encode(),0o600),('upgrade-preflight.sh',preflight,0o700),('rollback-postinst.sh',rollback,0o700)]:
        dest=args.output/name;dest.write_bytes(data);dest.chmod(mode)
    print(json.dumps({'output':str(args.output.resolve()),'version':VERSION,'sha256':c.sha(deb),'installed':False},indent=2))
if __name__=='__main__':main()
