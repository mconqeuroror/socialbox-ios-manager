"""Opt-in orchestration for fixed in-clone diagnostics; no injected code or credentials.

Stages follow the operator's existing A -> B -> A launches. The temporary helper
owns only the nonce request/control files; Security calls execute inside clones.
"""
import json
import os
import stat
from pathlib import Path
import time
import uuid

ROWS = ['OS-008','OS-009','OS-033','OS-035','ACCEPT-004']
IDS = {
    'seed': ['keychain-seed-default','keychain-seed-own-group','storage-seed'],
    'verify': ['keychain-default-absent','keychain-foreign-group-denied','storage-own-absent','storage-foreign-denied'],
    'cleanup': ['keychain-before-cleanup','keychain-cleanup','storage-cleanup'],
}
EXPECTED_CODES = {'keychain-default-absent': {-25300}, 'keychain-foreign-group-denied': {-34018},
                  'storage-foreign-denied': {1,13}, 'storage-own-absent': {2},
                  'keychain-seed-default': {0}, 'keychain-seed-own-group': {0}, 'storage-seed': {0},
                  'keychain-before-cleanup': {0}, 'keychain-cleanup': {-25300}, 'storage-cleanup': {0,2}}

class CanaryUnavailable(Exception): pass

def write_private(path,document):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_name(path.name+'.'+uuid.uuid4().hex+'.tmp')
    try:
        with temporary.open('x') as file:
            os.chmod(temporary,0o600); json.dump(document,file,indent=2); file.write('\n')
            file.flush(); os.fsync(file.fileno())
        os.replace(temporary,path)
    finally:
        if temporary.exists(): temporary.unlink()

def read_ledger(path):
    info=Path(path).lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_nlink!=1 or stat.S_IMODE(info.st_mode)!=0o600:
        raise CanaryUnavailable('canary ledger must be an owned private regular file')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,'rb') as file: raw=file.read(65537)
    if len(raw)>65536: raise CanaryUnavailable('canary ledger is too large')
    document=json.loads(raw)
    if not isinstance(document,dict) or document.get('schemaVersion')!=1:
        raise CanaryUnavailable('canary ledger schema is invalid')
    nonce=document.get('nonce','')
    try:
        if str(uuid.UUID(nonce)).upper()!=nonce: raise ValueError()
    except (ValueError,TypeError,AttributeError): raise CanaryUnavailable('canary nonce is not canonical') from None
    return document

def result_rows(result, make_row):
    return [make_row('canary-'+check['id'],check['status'],
        'Nonce-bound in-clone probe: '+check['detail'],check['surfaceRows'],'clone-canary') for check in result['checks']]

def validate_result(result,request,ready,lease,pid_path,expected_path,now):
    """Validate the actual receipt fields, not root's ability to query Security."""
    import device_acceptance_ssh as common
    if not isinstance(result,dict): raise CanaryUnavailable('canary result is missing')
    expected={'schemaVersion':1,'nonce':request['nonce'],'operation':request['operation'],
              'bundleIdentifier':request['targetBundleId'],'uid':501}
    if any(result.get(key)!=value for key,value in expected.items()):
        raise CanaryUnavailable('canary result belongs to another request or process identity')
    if result.get('pid')!=ready.get('pid') or result.get('generation')!=ready.get('generation') or result.get('bootEpoch')!=ready.get('bootEpoch'):
        raise CanaryUnavailable('canary result does not match the live hook receipt')
    timestamp=result.get('timestamp')
    if (not isinstance(timestamp,(int,float)) or isinstance(timestamp,bool) or
        not request['preparedAt']<=timestamp<=min(now,request['expiresAt'])):
        raise CanaryUnavailable('canary result timestamp is outside its stage lifetime')
    groups,behavior=common.required_hooks()
    if not all(check['status']=='PASS' for check in common.hook_checks(ready,lease,pid_path,expected_path,groups,behavior,now=now)):
        raise CanaryUnavailable('current executable, lease or hook binding failed')
    checks=result.get('checks')
    if not isinstance(checks,list) or len(checks)!=len(IDS[request['operation']]):
        raise CanaryUnavailable('canary checks are incomplete')
    by_id={check.get('id'):check for check in checks if isinstance(check,dict)}
    if set(by_id)!=set(IDS[request['operation']]): raise CanaryUnavailable('canary check IDs are unexpected or duplicated')
    for ident,check in by_id.items():
        if check.get('status') not in ('PASS','FAIL','NOT_RUN') or not isinstance(check.get('detail'),str):
            raise CanaryUnavailable('canary check format is invalid')
        if check.get('status')=='PASS' and ident in EXPECTED_CODES and check.get('statusCode') not in EXPECTED_CODES[ident]:
            raise CanaryUnavailable('canary denied-access status code does not support PASS')
        if not isinstance(check.get('surfaceRows'),list) or not check['surfaceRows'] or not set(check['surfaceRows'])<=set(ROWS):
            raise CanaryUnavailable('canary row mapping is invalid')
    # Discard arbitrary extra result/detail fields before retaining a report.
    clean=dict(expected,pid=result['pid'],generation=result['generation'],bootEpoch=result['bootEpoch'],timestamp=timestamp)
    clean['checks']=[dict(id=ident,status=by_id[ident]['status'],surfaceRows=by_id[ident]['surfaceRows'],
        detail={'seed':'Own clone canary write/read result.','verify':'Sibling clone access result.',
                'cleanup':'Removal of this nonce only.'}[request['operation']],
        **({'statusCode':by_id[ident]['statusCode']} if 'statusCode' in by_id[ident] else {})) for ident in IDS[request['operation']]]
    return clean

def run(remote,args,selected,lease,checks,make_row):
    import device_acceptance_ssh as common
    if not args.canary_stage and not args.canary_collect: return
    ledger_path=args.canary_ledger
    if not ledger_path: raise CanaryUnavailable('--canary-ledger is required')
    stage=args.canary_stage
    if stage=='seed':
        if Path(ledger_path).exists(): raise CanaryUnavailable('ledger already exists; finish or abort its nonce before a fresh run')
        if set(selected)!= {'A','B'}: raise CanaryUnavailable('canary seed requires two selected clones')
        if any(selected['A'][key]==selected['B'][key] for key in ('id','bundle','group','data')):
            raise CanaryUnavailable('canary seed requires distinct clone identities and storage')
        ledger={'schemaVersion':1,'nonce':str(uuid.uuid4()).upper(),'clones':selected,'bootEpoch':lease.get('bootEpoch'),'requests':{},'results':{}}
        # Persist recovery identity before any remote write.
        write_private(ledger_path,ledger)
    else:
        ledger=read_ledger(ledger_path)
        if not ledger.get('bootEpoch') or ledger['bootEpoch']!=lease.get('bootEpoch'):
            if not args.canary_abort: raise CanaryUnavailable('daemon/device epoch changed; only explicit abort cleanup is eligible')
            ledger['aborted']=True; ledger['bootEpoch']=lease.get('bootEpoch')
        prior=ledger.get('clones',{})
        for label in ('A','B'):
            if label not in selected or any(prior.get(label,{}).get(key)!=selected[label].get(key) for key in ('id','bundle','group','data')):
                raise CanaryUnavailable('current selected clone metadata differs from the nonce ledger')
    if not isinstance(lease.get('bootEpoch'),str) or not lease['bootEpoch']: raise CanaryUnavailable('current boot epoch is missing')
    nonce=ledger['nonce']; a=selected['A']; b=selected['B']
    if a['group']!='RBXCLONE00.'+a['bundle']:
        raise CanaryUnavailable('source keychain group does not match the fixed canary protocol')

    def collect(operation):
        request=ledger.get('requests',{}).get(operation)
        if not request: raise CanaryUnavailable('required earlier canary stage was not prepared')
        target=b if operation=='verify' else a
        if lease.get('containerId')!=target['id'] or lease.get('state')!='open':
            raise CanaryUnavailable('open the expected clone through the launcher before collecting this stage')
        before=remote.observe('--observe-canary',a['data'],nonce,'sentinel') if operation=='verify' else None
        observed=remote.observe('--observe-canary',target['data'],nonce,operation)
        ready=remote.document(target['data']+'/Library/Preferences/com.redditbox.hook-ready.plist')
        pid=ready.get('pid')
        if not isinstance(pid,int) or pid<=1: raise CanaryUnavailable('current hook receipt PID is unavailable')
        executable=remote.observe('--pid',str(pid)).get('path','')
        canonical=remote.canonical(target['executable'])
        current_lease=remote.document(common.PREF+'com.redditbox.network-lease.plist')
        result=validate_result(observed,request,ready,current_lease,executable,canonical,time.time())
        if operation=='verify':
            after=remote.observe('--observe-canary',a['data'],nonce,'sentinel')
            initial=ledger.get('sentinelBeforeVerify',{})
            if (before.get('matches') is not True or after.get('matches') is not True or initial.get('matches') is not True or
                not isinstance(initial.get('observedAt'),(int,float)) or not isinstance(after.get('observedAt'),(int,float)) or
                not initial['observedAt']<=result['timestamp']<=after['observedAt']):
                raise CanaryUnavailable('A sentinel existence was not established before and after B verification')
            if not all(item['status']=='PASS' for item in ledger.get('results',{}).get('seed',{}).get('checks',[])) or not ledger.get('results',{}).get('seed'):
                raise CanaryUnavailable('a successful seed receipt is required before interpreting B absence')
        ledger.setdefault('results',{})[operation]=result
        write_private(ledger_path,ledger)
        checks.extend(result_rows(result,make_row))
        return result

    if stage=='verify':
        seed=collect('seed')
        if not all(item['status']=='PASS' for item in seed['checks']):
            raise CanaryUnavailable('seed failed; use explicit abort cleanup before retrying')
        witness=remote.observe('--observe-canary',a['data'],nonce,'sentinel')
        if witness.get('matches') is not True: raise CanaryUnavailable('source canary is not present before B launch')
        ledger['sentinelBeforeVerify']=witness
    elif stage=='cleanup' and not args.canary_abort:
        collect('verify')
    elif args.canary_collect:
        cleanup=collect('cleanup')
        successful_removal=all(item['status']=='PASS' for item in cleanup['checks'] if item['id'] in ('keychain-cleanup','storage-cleanup'))
        if not successful_removal: raise CanaryUnavailable('canary cleanup did not complete; retain the exact nonce for recovery')
        complete=all(ledger.get('results',{}).get(step) for step in ('seed','verify','cleanup'))
        ordered=complete and ledger['results']['seed']['timestamp']<=ledger['results']['verify']['timestamp']<=cleanup['timestamp']
        all_pass=ordered and not ledger.get('aborted') and all(item['status']=='PASS' for step in ('seed','verify','cleanup') for item in ledger['results'][step]['checks'])
        any_failure=any(item['status']=='FAIL' for result in ledger.get('results',{}).values() for item in result['checks'])
        checks.append(make_row('canary-A-B-A','PASS' if all_pass else ('FAIL' if any_failure else 'NOT_RUN'),
            'One nonce: A seeded; B default/foreign access checked; A continuity confirmed and exact canaries removed. This covers only these specific API calls.',ROWS,'clone-canary'))
        for label,target in (('A',a),('B',b)):
            result=remote.observe('--remove-canary-controls',target['data'],nonce)
            checks.append(make_row('canary-'+label+'-control-cleanup','PASS' if result.get('cleaned') is True else 'FAIL',
                'Remove only this nonce request/results; retain the private evidence ledger.', ['ACCEPT-004'],'mechanical'))
        ledger['finished']=True; write_private(ledger_path,ledger)
        return
    if args.canary_abort:
        ledger['aborted']=True
        checks.append(make_row('canary-aborted','NOT_RUN','Interrupted experiment: cleanup is recovery, not isolation evidence.',ROWS))
    target=b if stage=='verify' else a
    current_lease=remote.document(common.PREF+'com.redditbox.network-lease.plist')
    if current_lease.get('containerId')==target['id'] and current_lease.get('state') in ('armed','open'):
        raise CanaryUnavailable('target clone must be inactive while its next-launch request is prepared')
    if args.canary_abort and 'cleanup' in ledger.get('requests',{}):
        # An interrupted prior cleanup may have an immutable receipt for the old
        # epoch. Remove only this inactive clone's owned nonce control/results;
        # never touch its canary item/file here, then request a fresh cleanup.
        reset=remote.observe('--remove-canary-controls',a['data'],nonce)
        if reset.get('cleaned') is not True: raise CanaryUnavailable('prior cleanup controls could not be safely retired; retain ledger for inspection')
    prepared=time.time()
    source_uuid=Path(a['data']).name.upper()
    request=dict(schemaVersion=1,nonce=nonce,operation=stage,targetBundleId=target['bundle'],
                 sourceBundleId=a['bundle'],sourceDataUUID=source_uuid,expiresAt=prepared+3600)
    # preparedAt is a ledger field; the fixed on-device request schema excludes it.
    ledger.setdefault('requests',{})[stage]=dict(request,preparedAt=prepared)
    write_private(ledger_path,ledger)
    response=common.parse_document(remote.command([remote.probe,'--prepare-canary',target['data']],
        input=json.dumps(request,separators=(',',':')).encode()).stdout)
    if response.get('prepared') is not True: raise CanaryUnavailable('root-owned request preparation failed; no existing challenge was overwritten')
    write_private(ledger_path,ledger)
    checks.append(make_row('canary-'+stage+'-prepared','NOT_RUN',
        'Fixed nonce request prepared. Open the intended clone through the launcher, then collect the actual result.',ROWS,'operator'))
