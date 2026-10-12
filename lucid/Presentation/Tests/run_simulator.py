#!/usr/bin/env python3
"""Actual overlay + synthetic UIKit host; never loads SocialBox or contacts services."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def input_snapshot(sources, compiled_root=REPO):
    """Freeze exact fixture translation units and quoted project dependencies."""
    pending, hashes = list(sources) + [Path(__file__).resolve()], {}
    includes = [compiled_root/'lucid/Presentation', compiled_root/'lucid/Diagnostics']
    while pending:
        path = Path(os.path.abspath(pending.pop()))
        if path in hashes:
            continue
        if not (path.is_relative_to(REPO) or path.is_relative_to(compiled_root)) or path.resolve() != path or not path.is_file():
            raise RuntimeError('Missing, aliased or escaping synthetic fixture input')
        raw = path.read_bytes()
        hashes[path] = hashlib.sha256(raw).hexdigest()
        if path.suffix in ('.m', '.h'):
            for name in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', raw.decode(), re.M):
                candidates = [path.parent / name, *(directory / name for directory in includes)]
                pending.append(next((candidate for candidate in candidates if candidate.is_file()), candidates[0]))
    return {('candidate/'+str(path.relative_to(compiled_root)) if compiled_root!=REPO and path.is_relative_to(compiled_root)
             else str(path.relative_to(REPO))): digest for path, digest in sorted(hashes.items())}


def run(*args):
    process = subprocess.run(args, text=True, capture_output=True, timeout=90)
    if process.returncode:
        raise RuntimeError(process.stderr or process.stdout)
    return process.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--workspace', action='store_true', help='Test the source-owned workspace with synthetic backend actions')
    parser.add_argument('--saved-setups', action='store_true', help='Test source saved-setup UI with synthetic authenticated-shaped replies; no live service')
    parser.add_argument('--retirement', action='store_true', help='Test explicit saved-settings removal UI with synthetic typed replies; no live service')
    parser.add_argument('--activation', action='store_true', help='Test the license form and existing saved-setup readiness handoff with synthetic replies')
    parser.add_argument('--switch-progress', action='store_true', help='Test Containers progress decoration only; synthetic loader, no switch or live service')
    parser.add_argument('--alerts', action='store_true', help='Test original-shaped Switch popup tint only; no container operation')
    parser.add_argument('--candidate', type=Path, help='Use a passing composed owner candidate for --alerts or --workspace; validate its exact source graph')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if sum((args.workspace, args.saved_setups, args.retirement, args.activation, args.switch_progress, args.alerts)) > 1:
        parser.error('Choose one fixture entry point')
    if args.candidate and not (args.alerts or args.workspace):
        parser.error('--candidate is supported for the bounded --alerts or --workspace fixture')
    if args.output.exists():
        parser.error('Choose a new output directory; existing evidence is never overwritten')
    identifier = 'com.socialbox.presentation.fixture.' + uuid.uuid4().hex
    compiled_root=REPO
    candidate_graph=None
    def candidate_snapshot():
        result={}
        for name in candidate_graph['sha256']:
            path=Path(os.path.abspath(compiled_root/name))
            if not path.is_relative_to(compiled_root) or path.resolve()!=path or not path.is_file():
                raise RuntimeError('Missing, aliased or escaping candidate input')
            result[name]=hashlib.sha256(path.read_bytes()).hexdigest()
        return result
    if args.candidate:
        candidate=Path(os.path.abspath(args.candidate))
        report=json.loads((candidate/'build-report.json').read_text())
        if report.get('status')!='PASS' or report.get('ownerInstallAccepted') is not False:
            raise RuntimeError('Not a private passing owner candidate')
        compiled_root=candidate/'source'
        candidate_graph=report['provenance']['composedGraph']
        if candidate_snapshot()!=candidate_graph['sha256']:
            raise RuntimeError('Candidate source graph differs from signed build evidence')
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix='socialbox-presentation-') as temp:
            app = Path(temp) / 'PresentationFixture.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'PresentationFixture',
                'CFBundleName': 'Synthetic UI fixture', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1', 'CFBundlePackageType': 'APPL',
                'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '15.0',
                'UIDeviceFamily': [1], 'UILaunchScreen': {}}))
            sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
            saved_sources = ['LBXContainerConfiguration.m', 'LBXContainerIPC.m', 'LBXContainerMutationIPC.m', 'LBXContainerRootMutationCoordinator.m']
            sources = [*sorted((compiled_root/'lucid/Presentation').glob('*.m')), HERE/'activation_transport_fixture.m',
                HERE.parent.parent/'Authorization/LBXLicenseIPC.m', HERE/'saved_setup_transport_fixture.m',
                *[HERE.parent.parent/'Containers'/name for name in saved_sources],
                HERE/('switch_progress_fixture.m' if args.switch_progress else 'activation_fixture.m' if args.activation else 'retirement_fixture.m' if args.retirement else 'saved_setup_fixture.m' if args.saved_setups else 'workspace_fixture.m' if args.workspace else 'fixture.m'),
                *sorted((compiled_root/'lucid/Diagnostics').glob('*.m')),
                *sorted((compiled_root/'lucid/ProxyInput').glob('*.m')), compiled_root/'shared/RBXHTTPProxy.m']
            before = input_snapshot(sources,compiled_root)
            run('xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
                '-DLBX_PRESENTATION_FIXTURE=1', '-DLBX_PROXY_INPUT_FIXTURE=1', '-target', 'arm64-apple-ios15.0-simulator',
                *(['-DLBX_CONTAINER_ROOT_COORDINATOR_TESTING=1'] if args.saved_setups or args.retirement else []),
                *(['-DLBX_ALERT_TINT_FIXTURE=1'] if args.alerts else []),
                '-isysroot', sdk, '-I'+str(compiled_root/'lucid/Presentation'), '-I'+str(compiled_root/'lucid/Diagnostics'), '-framework', 'UIKit',
                '-framework', 'MapKit', '-framework', 'Foundation', '-framework', 'QuartzCore', '-framework', 'CoreGraphics', '-framework', 'CFNetwork',
                '-Wl,-export_dynamic', *map(str, sources), '-o', str(app/'PresentationFixture'))
            run('codesign', '--force', '--sign', '-', str(app))
            run('xcrun', 'simctl', 'install', args.device, str(app))
            installed = True
            data = Path(run('xcrun', 'simctl', 'get_app_container', args.device, identifier, 'data'))
            run('xcrun', 'simctl', 'launch', args.device, identifier)
            result = data/'Documents/presentation-result.json'
            deadline = time.monotonic()+45
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(.2)
            if not result.exists():
                raise RuntimeError('Synthetic presentation fixture did not complete')
            args.output.mkdir(parents=True)
            for item in (data/'Documents').iterdir():
                shutil.copy2(item, args.output/item.name)
            report = json.loads(result.read_text())
            if input_snapshot(sources,compiled_root) != before or (candidate_graph and candidate_snapshot()!=candidate_graph['sha256']):
                raise RuntimeError('Synthetic fixture inputs changed during compilation/execution; keep attempt and rerun')
            report['buildInputsSHA256'] = before
            report['sourceStable'] = True
            if candidate_graph:
                report['candidateGraph']=candidate_graph
            (args.output/'presentation-result.json').write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps(report, indent=2))
            if not report['ok']:
                raise SystemExit(1)
    finally:
        if installed:
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, identifier], capture_output=True, timeout=15)
            run('xcrun', 'simctl', 'uninstall', args.device, identifier)


if __name__ == '__main__':
    main()
