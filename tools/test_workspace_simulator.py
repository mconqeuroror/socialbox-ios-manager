#!/usr/bin/env python3
"""Run actual workspace UIKit with inert service fixtures; retain review screenshots."""
import argparse,json,plistlib,shutil,signal,subprocess,tempfile,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def run(*args):
    p=subprocess.run(args,text=True,capture_output=True,timeout=90)
    if p.returncode: raise RuntimeError(p.stderr or p.stdout)
    return p.stdout.strip()
p=argparse.ArgumentParser();p.add_argument('--device',required=True);p.add_argument('--output',type=Path,required=True)
p.add_argument('--record',type=Path,help='Record this synthetic UIKit fixture run; not physical-device isolation evidence')
a=p.parse_args()
if a.record and a.record.exists():p.error('Recording output already exists; choose a new path')
identifier='com.redditbox.workspace-test.'+uuid.uuid4().hex
installed=False;recording=None;record_log=None
try:
    with tempfile.TemporaryDirectory(prefix='rbx-workspace-ui-') as temp:
        app=Path(temp)/'WorkspaceTest.app';app.mkdir()
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier,'CFBundleExecutable':'WorkspaceTest','CFBundleName':'UI fixture','CFBundleVersion':'1','CFBundleShortVersionString':'1','CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'MinimumOSVersion':'15.0','UIDeviceFamily':[1],'UILaunchScreen':{}}))
        sources=[x for x in (ROOT/'launcher').glob('*.m') if x.name not in ('main.m','RBXLauncherIPC.m','RBXPasscodeStore.m')]
        sources += [ROOT/'shared/RBXAcceptanceChecks.m',ROOT/'shared/RBXHTTPProxy.m',ROOT/'tools/test_workspace_fixture.m']
        sdk=run('xcrun','--sdk','iphonesimulator','--show-sdk-path')
        run('xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness','-Wno-incomplete-implementation','-Wno-deprecated-declarations','-target','arm64-apple-ios15.0-simulator','-isysroot',sdk,'-I'+str(ROOT/'launcher'),'-I'+str(ROOT/'shared'),'-framework','UIKit','-framework','Foundation','-framework','CFNetwork','-framework','Security','-framework','WebKit','-framework','CoreGraphics','-framework','QuartzCore','-framework','MapKit','-framework','CoreLocation',*[str(x) for x in sources],'-o',str(app/'WorkspaceTest'))
        run('codesign','--force','--sign','-',str(app));run('xcrun','simctl','install',a.device,str(app));installed=True
        data=Path(run('xcrun','simctl','get_app_container',a.device,identifier,'data'))
        if a.record:
            a.record.parent.mkdir(parents=True,exist_ok=True)
            record_log=tempfile.TemporaryFile(mode='w+')
            recording=subprocess.Popen(['xcrun','simctl','io',a.device,'recordVideo','--codec=h264',str(a.record)],stdout=record_log,stderr=record_log)
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                record_log.seek(0)
                if 'Recording started' in record_log.read():break
                if recording.poll() is not None:raise RuntimeError('Simulator recording stopped before launch')
                time.sleep(.1)
            else:raise RuntimeError('Simulator did not start recording within 10 seconds')
        run('xcrun','simctl','launch',a.device,identifier)
        result=data/'Documents/workspace-result.json';deadline=time.monotonic()+60
        while not result.exists() and time.monotonic()<deadline:time.sleep(.25)
        if not result.exists():raise RuntimeError('Workspace fixture did not finish; inspect simulator crash log.')
        a.output.mkdir(parents=True,exist_ok=True)
        for file in (data/'Documents').iterdir():shutil.copy2(file,a.output/file.name)
        content=json.loads(result.read_text());print(json.dumps(content))
        if not content['ok']:raise SystemExit(1)
finally:
    if recording is not None:
        if recording.poll() is None:recording.send_signal(signal.SIGINT)
        try:recording.wait(timeout=15)
        except subprocess.TimeoutExpired:
            recording.kill();recording.wait(timeout=5)
        if record_log is not None:record_log.close()
    if installed:
        subprocess.run(['xcrun','simctl','terminate',a.device,identifier],capture_output=True,timeout=15)
        run('xcrun','simctl','uninstall',a.device,identifier)
