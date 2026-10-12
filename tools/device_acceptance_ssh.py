#!/usr/bin/env python3
"""Safe acceptance observations over existing SSH; no account actions or gate changes.

Default remote writes: a private temporary observer executable, removed on exit.
--storage-sentinel additionally creates one uniquely named tmp marker and removes it.
Neither operation establishes clone-context keychain or foreign-sandbox denial.
"""
import argparse
import datetime
import hashlib
import getpass
import hmac
import json
import math
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import device_acceptance_canaries

ROOT = Path(__file__).resolve().parents[1]
PREF = '/var/mobile/Library/Preferences/'
DATA = '/var/mobile/Containers/Data/Application'
MAPPING = ROOT / 'docs/leak-surface/device-acceptance-mapping.json'
SAFE_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z')
MAX_BYTES = 4 * 1024 * 1024

class Unavailable(Exception):
    pass

def dictionary(value):
    return value if isinstance(value, dict) else {}

def parse_document(data):
    if len(data) > MAX_BYTES:
        raise Unavailable('observation exceeds size budget')
    try:
        result = plistlib.loads(data)
    except Exception:
        try:
            result = json.loads(data)
        except Exception:
            raise Unavailable('observation is missing or malformed') from None
    if not isinstance(result, dict):
        raise Unavailable('observation is not a dictionary')
    return result

def row(identifier, status, detail, rows, kind='mechanical'):
    return dict(id=identifier, title=identifier.replace('-', ' ').capitalize(), status=status,
                detail=detail, rows=rows, evidence=kind)

def safe_bundle(path):
    if not isinstance(path, str): return False
    p = PurePosixPath(path)
    if '..' in p.parts: return False
    return any(path.startswith(prefix) for prefix in (
        '/var/containers/Bundle/Application/', '/var/mobile/Containers/Bundle/Application/',
        '/private/var/containers/Bundle/Application/', '/private/var/mobile/Containers/Bundle/Application/')) and path.endswith('.app')

def safe_data(path):
    return bool(isinstance(path, str) and re.fullmatch(
        r'/(?:private/)?var/mobile/Containers/Data/Application/[A-Fa-f0-9-]{36}', path))

def fresh(value, now, maximum=2.5):
    return isinstance(value,(float,int)) and not isinstance(value,bool) and math.isfinite(value) and math.isfinite(now) and 0 <= now-value <= maximum

def same_boot_epoch(recorded, current):
    return isinstance(recorded,str) and bool(recorded) and recorded==current

def lease_checks(lease, firewall, now):
    keys=('state','generation','bootEpoch','containerId','bundleIdentifier')
    complete=(lease.get('state') in ('closed','armed','open') and
        all(isinstance(lease.get(k),str) and isinstance(firewall.get(k),str) for k in keys) and
        all(bool(lease.get(k)) for k in ('generation','bootEpoch')) and
        (lease.get('state')=='closed' or all(bool(lease.get(k)) for k in ('containerId','bundleIdentifier'))))
    match=complete and all(lease[k]==firewall[k] for k in keys)
    alive=fresh(lease.get('heartbeatAt'),now) and fresh(firewall.get('heartbeatAt'),now)
    return [row('live-lease-agreement','PASS' if match and alive else 'FAIL',
        'Both captured control files must agree and have fresh heartbeats; this is not a packet capture.', ['NET-036','LIFE-021']),
        row('live-lease-open','PASS' if match and alive and lease.get('state')=='open' else 'NOT_RUN',
        'OPEN is required for active-clone acceptance; CLOSED is expected during setup.', ['LIFE-021']),
        row('live-provider','PASS' if match and alive and firewall.get('enforced') is True and
            firewall.get('scope')=='per-app' and fresh(firewall.get('policyAppliedAt'),now,maximum=now) and firewall['policyAppliedAt']>0 else 'NOT_RUN',
        'Provider self-reports per-app enforcement. OS assignment and real traffic still need capture.', ['NET-034'])]

def hook_checks(ready, lease, process_path, expected_path, required_groups, required_behavior, now=None):
    now=time.time() if now is None else now
    epoch=hmac.new(str(lease.get('bootEpoch','')).encode(),
        ('redditbox-clone-epoch-v1:'+str(lease.get('bundleIdentifier',''))).encode(),hashlib.sha256).hexdigest()
    bound=(lease.get('state') in ('armed','open') and fresh(lease.get('heartbeatAt'),now) and
        fresh(ready.get('timestamp'),now,maximum=now) and fresh(lease.get('openedAt'),now,maximum=now) and
        bool(process_path) and process_path==expected_path and
        all(ready.get(k)==lease.get(k) and bool(lease.get(k)) for k in ('containerId','bundleIdentifier','generation')) and
        ready.get('bootEpoch')==epoch and ready.get('evidenceVersion')==1 and ready.get('allHooksInstalled') is True and
        isinstance(ready.get('timestamp'),(int,float)) and isinstance(lease.get('openedAt'),(int,float)) and
        (ready['timestamp']<=lease['openedAt'] if lease.get('state')=='open' else ready['timestamp']>=lease['openedAt']))
    groups=dictionary(ready.get('installedGroups')); behavior=dictionary(ready.get('behaviorChecks'))
    checks=[row('hook-receipt-binding','PASS' if bound else 'FAIL',
        'Receipt must bind to the live executable, current clone, boot epoch and lease generation.', ['NET-037','LIFE-021'])]
    for family,names,values in [('hook',required_groups,groups),('behavior',required_behavior,behavior)]:
        for name in names:
            checks.append(row(f'{family}-{name}','PASS' if bound and values.get(name) is True else 'FAIL',
                'Current bound clone self-report; runtime packet coverage is a separate test.', ['NET-037','LIFE-021'],'clone-self-report'))
    return checks

def required_hooks():
    text=(ROOT/'shared/RBXHookReadiness.h').read_text()
    sections=[]
    for function in ('RBXRequiredHookGroups','RBXRequiredBehaviorChecks'):
        match=re.search(re.escape(function)+r'\(void\)\s*\{\s*return @\[(.*?)\];',text,re.S)
        if not match: raise Unavailable('required-hook contract cannot be parsed')
        sections.append(re.findall(r'@"([^"]+)"',match[1]))
    return sections

def sudo_password_command(command):
    # Always consume the dedicated first line ourselves. A cached/NOPASSWD sudo
    # may not read -S input; its unused password pipe must never reach a file or
    # observer stdin. Authentication and the command share this shell parent.
    script=("IFS= read -r rbx_acceptance_password || exit 1; "
        "if ! printf '%s\\n' \"$rbx_acceptance_password\" | sudo -S -p '' -v; then "
        "unset rbx_acceptance_password; exit 1; fi; "
        "unset rbx_acceptance_password; sudo -n -- "+command+"; rbx_acceptance_status=$?; exit \"$rbx_acceptance_status\"")
    return 'sh -c '+shlex.quote(script)

class Remote:
    def __init__(self,args):
        self.args=args
        self.deadline=time.monotonic()+args.total_timeout
        self.base=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','ServerAliveInterval=5','-o','ServerAliveCountMax=2',
            '-p',str(args.port)]
        if args.identity: self.base+=['-i',str(Path(args.identity).expanduser())]
        if args.control_path: self.base+=['-S',args.control_path]
        if args.ssh_config: self.base+=['-F',args.ssh_config]
        self.base+=['--',args.target]
        self.probe=None
        self.password=getpass.getpass('Existing phone sudo password (memory only): ') if getattr(args,'sudo_password',False) else None
        if self.password is not None and ('\n' in self.password or '\r' in self.password): raise Unavailable('password must be a single line')
    def command(self,words,input=None,allow_failure=False,timeout=20):
        remaining=self.deadline-time.monotonic()
        if remaining<=0: raise Unavailable('total acceptance timeout reached')
        command=' '.join(shlex.quote(str(w)) for w in words)
        if self.password is not None:
            command=sudo_password_command(command)
            input=self.password.encode()+b'\n'+(input or b'')
        elif self.args.sudo: command='sudo -n -- '+command
        try:
            result=subprocess.run(self.base+[command],input=input,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                timeout=min(timeout,remaining),check=False)
        except (subprocess.TimeoutExpired,OSError):
            raise Unavailable('SSH command timed out or could not start') from None
        if len(result.stdout)>MAX_BYTES: raise Unavailable('remote output exceeds size budget')
        if result.returncode and not allow_failure:
            # Never echo remote stderr: it can include private URLs or profile values.
            raise Unavailable('SSH observation failed (access, missing dependency or connection)')
        return result
    def read(self,path): return self.command(['cat',path]).stdout
    def document(self,path): return parse_document(self.read(path))
    def observe(self,*arguments): return parse_document(self.command([self.probe,*arguments]).stdout)
    def canonical(self,path): return self.observe('--realpath',path).get('path','')

def compile_helpers(temp,args):
    cli=temp/'evaluate'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-I'+str(ROOT/'shared'),'-framework','Foundation',
        str(ROOT/'shared/RBXAcceptanceChecks.m'),str(ROOT/'tools/device_acceptance_cli.m'),'-o',str(cli)],check=True,stdout=subprocess.DEVNULL)
    probe=temp/'probe'
    sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
    subprocess.run(['xcrun','--sdk','iphoneos','clang','-arch','arm64','-miphoneos-version-min=15.0','-isysroot',sdk,
        '-fobjc-arc','-I'+str(ROOT/'daemon'),'-framework','Foundation',str(ROOT/'tools/device_acceptance_probe.m'),'-o',str(probe)],
        check=True,stdout=subprocess.DEVNULL)
    signer=args.ldid or os.environ.get('LDID') or shutil.which('ldid')
    if not signer: raise Unavailable('set LDID to the existing Procursus ldid executable')
    subprocess.run([signer,'-S',str(probe)],check=True,stdout=subprocess.DEVNULL)
    return cli,probe

def daemon_candidates(output):
    """Parse executable names, never command arguments or a substring match."""
    try:
        lines = output.decode('utf-8').splitlines()
    except UnicodeDecodeError:
        raise Unavailable('process listing could not be decoded') from None
    seen = set()
    candidates = []
    for line in lines:
        if not line.strip(): continue
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) <= 0 or fields[0] in seen:
            raise Unavailable('process listing is malformed or inconsistent')
        seen.add(fields[0])
        if PurePosixPath(fields[1]).name == 'redditboxd':
            candidates.append(fields[0])
    if not seen: raise Unavailable('process listing is empty')
    return candidates

def observe_daemon(remote):
    rows = ['ACCEPT-003', 'NET-037']
    def result(status, detail, observer=None, prefix=None):
        return row('daemon-process', status, detail, rows), observer, prefix
    try:
        # /bin/ps is part of this phone's bootstrap. pgrep is optional and its
        # absence must not be reported as a stopped daemon.
        listing = remote.command(['/bin/ps', '-axo', 'pid=,comm='], allow_failure=True)
        if listing.returncode:
            return result('NOT_RUN', 'Process enumeration is unavailable; daemon liveness was not established.')
        pids = daemon_candidates(listing.stdout)
        if len(pids) != 1:
            return result('FAIL', 'Exactly one live redditboxd process is required.')
        observer = remote.observe('--pid', pids[0])
        actual = observer.get('path')
        if not isinstance(actual, str) or not actual:
            return result('NOT_RUN', 'The candidate process disappeared or its executable could not be read.')
        if not actual.startswith('/'):
            return result('NOT_RUN', 'The observed process path is not absolute.')
        # proc_pidpath can retain the /var/jb symlink spelling on iOS.
        actual = remote.canonical(actual)
        if not actual:
            return result('NOT_RUN', 'The observed executable could not be resolved.')
        resolved_installation = False
        for prefix in ('/var/jb', ''):
            try: installed = remote.canonical(prefix + '/usr/bin/redditboxd')
            except Unavailable: continue
            resolved_installation = resolved_installation or bool(installed)
            if installed and actual == installed:
                return result('PASS', 'One process is bound to the canonical installed daemon executable; this is a current snapshot.', observer, prefix)
        if not resolved_installation:
            return result('NOT_RUN', 'Installed daemon paths could not be resolved; no executable binding claim.')
        return result('FAIL', 'The named process is not the installed daemon executable.')
    except Unavailable:
        return result('NOT_RUN', 'Process enumeration or executable binding is unavailable; no liveness claim.')

def observer_temporary_root(remote):
    # Rootless bootstrap execution can reject an otherwise identical ldid
    # observer from /tmp. Use its existing executable mount; never alter trust,
    # entitlements or the application's sandbox to make an observation run.
    status = remote.command(['test', '-d', '/var/jb'], allow_failure=True).returncode
    if status not in (0, 1): raise Unavailable('cannot identify the installed bootstrap mount')
    return '/var/jb/tmp' if status == 0 else '/tmp'

def collect(remote,args,cli,probe,checks):
    temporary=observer_temporary_root(remote)+'/redditbox-acceptance-'+str(uuid.uuid4())
    remote.probe=temporary+'/probe'
    created=False
    try:
        remote.command(['sh','-c','umask 077; mkdir '+shlex.quote(temporary)])
        created=True
        remote.command(['sh','-c','cat > '+shlex.quote(remote.probe)],input=probe.read_bytes())
        remote.command(['chmod','700',remote.probe])
        state=remote.document(PREF+'com.redditbox.launcher-state.plist')
        now=time.time()
        # State remains private in memory; the evaluator emits only fixed explanatory text.
        result=subprocess.run([str(cli),str(now)],input=plistlib.dumps(state),stdout=subprocess.PIPE,check=True)
        checks+=json.loads(result.stdout)
        daemon_check,observer,prefix=observe_daemon(remote)
        checks.append(daemon_check)
        if daemon_check['status']!='PASS': return checks
        daemon_ok=True
        values=[observer.get(k) for k in ('activeMiB','inactiveMiB')]
        budget=daemon_ok and observer.get('memoryRead') is True and all(isinstance(v,int) and v>=256 for v in values)
        undersized=daemon_ok and observer.get('memoryRead') is True and any(isinstance(v,int) and 0<v<256 for v in values)
        checks.append(row('h02-budget','PASS' if budget else ('FAIL' if undersized else 'NOT_RUN'),
            'GET-only kernel query: explicit active and inactive limits must both be at least 256 MiB; defaults/unlimited or denied queries need separate evidence.', ['ACCEPT-003','LIFE-002']))
        ldid=prefix+'/usr/bin/ldid'
        lease=remote.document(PREF+'com.redditbox.network-lease.plist')
        firewall=remote.document(PREF+'com.redditbox.firewall-status.plist')
        checks+=lease_checks(lease,firewall,time.time())
        inventory=dictionary({str(item.get('id')):item for item in state.get('containers',[]) if isinstance(item,dict)})
        requested=[('A',args.a),('B',args.b)]
        selected={}
        if not args.a and lease.get('containerId'): requested[0]=('A',lease['containerId'])
        if any(value for _,value in requested):
            listing=remote.command(['sh','-c','for f in '+DATA+'/*/.com.apple.mobile_container_manager.metadata.plist; do [ -f "$f" ] && printf "%s\\n" "$f"; done'],allow_failure=True).stdout.decode().splitlines()
            if len(listing)>256: raise Unavailable('more than 256 data containers; explicit metadata discovery budget exceeded')
            data_by_id={}; unreadable_metadata=0
            for path in listing:
                parent=str(PurePosixPath(path).parent)
                if not safe_data(parent): continue
                try: metadata=remote.document(path)
                except Unavailable:
                    unreadable_metadata+=1
                    continue
                ident=metadata.get('MCMMetadataIdentifier')
                if isinstance(ident,str): data_by_id.setdefault(ident,[]).append(parent)
            for label,ident in requested:
                if not ident:
                    checks.append(row(label+'-structure','NOT_RUN','Pass --a and --b with the actual container IDs.',['ID-005','LIFE-005']))
                    continue
                if not SAFE_ID.fullmatch(ident): raise Unavailable('unsafe container identifier rejected')
                if ident not in inventory:
                    checks.append(row(label+'-structure','NOT_RUN','Selected ID is not in the published inventory.',['ID-005']))
                    continue
                profile=remote.document(PREF+'com.redditbox.profiles/'+ident+'.json')
                sync_mode=dictionary(profile.get('security')).get('keychainSync','unchanged')
                checks.append(row(label+'-keychain-sync-policy','NOT_RUN',
                    'Configured sync policy is local-only; iOS query/login proof is pending.' if sync_mode=='local-only' else
                    'Default keychain sync behavior is unchanged; READY does not establish sync isolation.', ['OS-011']))
                app=dictionary(profile.get('app'))
                bundle_id=app.get('bundleIdentifier'); bundle_path=app.get('bundlePath'); group=app.get('keychainAccessGroup')
                if not safe_bundle(bundle_path) or not isinstance(bundle_id,str) or not isinstance(group,str):
                    checks.append(row(label+'-structure','FAIL','Clone metadata is incomplete or outside installed application paths.',['ID-005','LIFE-005']))
                    continue
                info=remote.document(bundle_path+'/Info.plist')
                executable=info.get('CFBundleExecutable')
                if not isinstance(executable,str) or '/' in executable or executable in ('.','..'):
                    raise Unavailable('unsafe main executable name rejected')
                executable_path=bundle_path+'/'+executable
                entitlements=parse_document(remote.command([ldid,'-e',executable_path]).stdout)
                forbidden=any(any(word in key.lower() for word in ('application-groups','aps-environment','ubiquity','icloud','associated-domains')) for key in entitlements)
                valid=(info.get('CFBundleIdentifier')==bundle_id and app.get('architecture')=='clonedApp-v2' and
                    entitlements.get('keychain-access-groups')==[group] and entitlements.get('application-identifier')==group and
                    'get-task-allow' not in entitlements and not forbidden)
                checks.append(row(label+'-structure','PASS' if valid else 'FAIL',
                    'Installed main bundle ID and one expected keychain group; shared/cloud/push/associated-domain entitlements absent. No claim about clone access denial.', ['ID-005','LIFE-005','OS-008','OS-026']))
                nested=remote.command(['sh','-c','for n in PlugIns Watch AppClips; do if [ -e '+shlex.quote(bundle_path)+'/$n ]; then printf "%s\\n" "$n"; fi; done']).stdout
                checks.append(row(label+'-removed-extensions','FAIL' if nested.strip() else 'PASS','PlugIns, Watch and AppClips are absent from the installed clone.',['LIFE-006']))
                paths=data_by_id.get(bundle_id,[])
                if len(paths)!=1:
                    checks.append(row(label+'-data-container','FAIL' if len(paths)>1 else 'NOT_RUN','Expected one OS data container. Missing storage may need first launcher Open; unreadable metadata cannot establish absence.',['ID-005','OS-030']))
                    continue
                canonical=remote.canonical(paths[0])
                if not safe_data(canonical): raise Unavailable('data container realpath escaped the approved directory')
                selected[label]=dict(id=ident,bundle=bundle_id,group=group,data=canonical,executable=executable_path,bundlePath=bundle_path)
                checks.append(row(label+'-data-container','PASS','One OS metadata record matches the selected clone bundle.',['ID-005','OS-030']))
                if ident==lease.get('containerId') and lease.get('state') in ('armed','open'):
                    ready=remote.document(paths[0]+'/Library/Preferences/com.redditbox.hook-ready.plist')
                    pid=ready.get('pid')
                    if not isinstance(pid,int) or pid<=1: raise Unavailable('hook receipt has no valid PID')
                    actual=remote.observe('--pid',str(pid)).get('path','')
                    expected=remote.canonical(executable_path)
                    groups,behavior=required_hooks()
                    receipt_lease=remote.document(PREF+'com.redditbox.network-lease.plist')
                    checks+=hook_checks(ready,receipt_lease,actual,expected,groups,behavior)
        if len(selected)==2:
            a,b=selected['A'],selected['B']
            separate=all(a[key]!=b[key] for key in ('id','bundle','group','data'))
            checks.append(row('A-B-distinct-metadata','PASS' if separate else 'FAIL',
                'A and B have distinct container IDs, bundle IDs, expected keychain groups and OS data paths; root observation is not access-denial proof.', ['ID-005','OS-001','OS-008','OS-030']))
            if args.storage_sentinel:
                observed=remote.observe('--storage-sentinel',a['data']+'/tmp',b['data']+'/tmp')
                passed=all(observed.get(key) is True for key in ('created','absentInB','cleaned','safePaths'))
                checks.append(row('storage-sentinel-locations','PASS' if passed else 'FAIL',
                    'Opt-in marker created in A tmp, absent at B tmp and removed. This proves location separation only; foreign sandbox denial remains NOT_RUN.', ['OS-030','ACCEPT-002']))
        elif args.storage_sentinel:
            checks.append(row('storage-sentinel-locations','NOT_RUN','Two validated distinct clone directories are required.',['ACCEPT-002']))
        if args.save_baseline:
            if len(selected)!=2: raise Unavailable('two selected clones are required to save a deletion baseline')
            args.save_baseline.parent.mkdir(parents=True,exist_ok=True)
            with args.save_baseline.open('w') as file:
                os.chmod(args.save_baseline,0o600)
                json.dump({'schemaVersion':1,'bootEpoch':lease.get('bootEpoch'),'capturedAt':time.time(),'B':selected['B']},file,indent=2)
        if args.after_delete:
            baseline_document=parse_document(args.after_delete.read_bytes())
            same_device_epoch=same_boot_epoch(baseline_document.get('bootEpoch'),lease.get('bootEpoch'))
            baseline=dictionary(baseline_document.get('B'))
            ident=baseline.get('id'); data=baseline.get('data'); bundle=baseline.get('bundlePath')
            if not isinstance(ident,str) or not SAFE_ID.fullmatch(ident) or not safe_data(data) or not safe_bundle(bundle):
                raise Unavailable('deletion baseline contains invalid observation paths')
            observations=[remote.observe('--exists',path) for path in
                (data,bundle,PREF+'com.redditbox.profiles/'+ident+'.json')]
            absent=same_device_epoch and all(item.get('absent') is True for item in observations)
            exists=same_device_epoch and any(item.get('exists') is True for item in observations)
            checks.append(row('B-deleted-files','PASS' if absent else ('FAIL' if exists else 'NOT_RUN'),
                'B file absence requires the same daemon boot epoch as its private baseline; other devices/restarts are NOT_RUN. Keychain cleanup is separate.', ['LIFE-027','ACCEPT-002']))
            summary=remote.observe('--deletion-summary',ident)
            recorded=(same_device_epoch and summary.get('valid') is True and summary.get('phase')=='committed' and
                summary.get('bundleIdentifier')==baseline.get('bundle') and summary.get('accessGroup')==baseline.get('group') and
                summary.get('recoveryEvidence') is False and
                fresh(summary.get('updatedAt'),time.time(),maximum=time.time()) and
                isinstance(baseline_document.get('capturedAt'),(int,float)) and summary['updatedAt']>=baseline_document['capturedAt'])
            checks.append(row('B-recorded-keychain-cleanup','PASS' if recorded else 'NOT_RUN',
                'Retained committed deletion journal records successful authorized cleanup of the expected group. Raw helper receipt and a direct post-delete query were not collected.', ['LIFE-026','LIFE-027'],'daemon-report'))
        if args.canary_stage or args.canary_collect:
            try:
                device_acceptance_canaries.run(remote,args,selected,lease,checks,row)
            except device_acceptance_canaries.CanaryUnavailable as error:
                checks.append(row('canary-collection','NOT_RUN',str(error),device_acceptance_canaries.ROWS))
        # A switch or lease change during collection invalidates binding claims.
        final_lease=remote.document(PREF+'com.redditbox.network-lease.plist')
        final_firewall=remote.document(PREF+'com.redditbox.firewall-status.plist')
        final_agreement=lease_checks(final_lease,final_firewall,time.time())[0]['status']=='PASS'
        stable=final_agreement and all(final_lease.get(k)==lease.get(k) for k in ('state','generation','bootEpoch','containerId','bundleIdentifier'))
        if not stable:
            for check in checks:
                if check['id'].startswith(('live-','hook-','behavior-','canary-')): check['status']='NOT_RUN'
            checks.append(row('capture-generation','NOT_RUN','Lease changed or final safety heartbeat was stale; rerun without switching.',['NET-036','LIFE-021']))
        return checks
    finally:
        if created:
            # Delete only the two exact temporary artifacts owned by this invocation.
            old_deadline=remote.deadline; remote.deadline=max(old_deadline,time.monotonic()+15)
            try:
                remote.command(['rm','-f',remote.probe],timeout=5)
                remote.command(['rmdir',temporary],timeout=5)
                checks.append(row('temporary-observer-cleanup','PASS','Temporary observer removed.',['ACCEPT-002']))
            except Unavailable:
                checks.append(row('temporary-observer-cleanup','FAIL','Connection prevented cleanup; remove the recorded temporary observer directory.',['ACCEPT-002']))
                print('Cleanup needed: '+temporary,file=sys.stderr)
            remote.deadline=old_deadline

def main():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--target',required=True,help='Existing SSH user@host or SSH config alias; key/control authentication only')
    parser.add_argument('--port',type=int,default=22)
    parser.add_argument('--identity',help='Existing SSH identity file (never copied to the phone)')
    parser.add_argument('--control-path',help='Existing SSH master socket; relative paths remain relative to this checkout')
    parser.add_argument('--ssh-config',help='Optional SSH config file; host key checks remain enabled')
    privilege=parser.add_mutually_exclusive_group()
    privilege.add_argument('--sudo',action='store_true',help='Use existing sudo -n rights; never asks for or stores a password')
    privilege.add_argument('--sudo-password',action='store_true',help='Operator opt-in: ask once for the existing phone sudo password, keep only in memory, send on SSH stdin (never argv/file/report)')
    parser.add_argument('--a',help='A container ID, not its display name; defaults to active container')
    parser.add_argument('--b',help='B container ID, not its display name')
    parser.add_argument('--storage-sentinel',action='store_true',help='Opt in to one temporary marker in A tmp with B-location check and cleanup')
    parser.add_argument('--save-baseline',type=Path,help='Save selected B paths/IDs privately for a later read-only deletion check')
    parser.add_argument('--after-delete',type=Path,help='Read a prior B baseline and check its exact files are absent; never deletes files or queries keychain')
    canary=parser.add_mutually_exclusive_group()
    canary.add_argument('--canary-stage',choices=['seed','verify','cleanup'],help='Opt in: prepare a fixed next-launch in-clone nonce stage; verify collects A seed, cleanup collects B verification')
    canary.add_argument('--canary-collect',action='store_true',help='Collect A final cleanup and the bounded A/B/A canary verdict; remove only owned request/results')
    parser.add_argument('--canary-ledger',type=Path,help='Private nonce/stage ledger; required for canary operations, retained for recovery')
    parser.add_argument('--canary-abort',action='store_true',help='Prepare cleanup without successful previous stages; records NOT_RUN, never an isolation pass')
    parser.add_argument('--ldid',help='Procursus ldid on the Mac; defaults to LDID or PATH')
    parser.add_argument('--total-timeout',type=int,default=240)
    parser.add_argument('--output',type=Path,default=ROOT/'build/acceptance/ssh-report.json')
    args=parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_.@:\[\]-]+',args.target) or args.target.startswith('-'): parser.error('invalid SSH target')
    if not 1<=args.port<=65535 or not 30<=args.total_timeout<=900: parser.error('port or timeout outside supported range')
    if (args.canary_stage or args.canary_collect) and (not args.canary_ledger or not args.a or not args.b): parser.error('canary operations require --canary-ledger, --a and --b')
    if args.canary_abort and args.canary_stage!='cleanup': parser.error('--canary-abort requires --canary-stage cleanup')
    if args.storage_sentinel and (not args.a or not args.b): parser.error('--storage-sentinel requires explicit --a and --b')
    checks=[]; timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat()
    try:
        with tempfile.TemporaryDirectory(prefix='redditbox-acceptance-') as temp:
            cli,probe=compile_helpers(Path(temp),args)
            collect(Remote(args),args,cli,probe,checks)
    except (Unavailable,subprocess.CalledProcessError,OSError,ValueError,TypeError) as error:
        checks.append(row('collection','NOT_RUN','Collection incomplete: '+str(error) if isinstance(error,Unavailable) else 'Host dependency or observation format failed; no acceptance claim.',['ACCEPT-002']))
    revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    report={'schemaVersion':1,'revision':revision,'capturedAt':timestamp,'completedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checks':checks,
        'scope':'Observed readiness/structure and optional fixed in-clone nonce probes only. No automatic post, vote, authentication or gate mutation.',
        'remaining':'NOT_RUN is not PASS. Follow docs/device-acceptance-final.md.'}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with args.output.open('w') as file:
        os.chmod(args.output,0o600); json.dump(report,file,indent=2); file.write('\n')
    print(f'{"STATUS":<8} {"CHECK":<43} ROWS')
    for check in checks: print(f'{check["status"]:<8} {check["id"]:<43} {",".join(check["rows"])}')
    print('Report: '+str(args.output))
    print('PASS is scoped to each observation. Screen actions, packet routing and clone-context access denial remain separate.')
    return 1 if any(c['status']=='FAIL' for c in checks) else (2 if any(c['status']=='NOT_RUN' for c in checks) else 0)

if __name__=='__main__': sys.exit(main())
