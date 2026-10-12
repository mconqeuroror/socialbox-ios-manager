#!/usr/bin/env python3
"""Run source-owned responsive layouts with synthetic records and no backend operations."""
import argparse
import hashlib
import os
import re
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]


def input_snapshot(sources):
    """Pin exact translation units, quoted project headers and this runner."""
    pending, hashes = list(sources) + [Path(__file__).resolve()], {}
    includes = [HERE.parent, HERE.parent.parent / 'Diagnostics']
    while pending:
        path = Path(os.path.abspath(pending.pop()))
        if path in hashes:
            continue
        if not path.is_relative_to(REPO) or path.resolve() != path or not path.is_file():
            raise RuntimeError('Missing, aliased or escaping layout fixture input')
        raw = path.read_bytes()
        hashes[path] = hashlib.sha256(raw).hexdigest()
        if path.suffix in ('.m', '.h'):
            for name in re.findall(r'^\s*#\s*(?:import|include)\s*"([^"\n]+)"', raw.decode(), re.M):
                candidates = [path.parent / name, *(directory / name for directory in includes)]
                pending.append(next((candidate for candidate in candidates if candidate.is_file()), candidates[0]))
    return {str(path.relative_to(REPO)): digest for path, digest in sorted(hashes.items())}


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Already booted simulator; omitted for --compile-only')
    parser.add_argument('--compile-only', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not args.compile_only and not args.device:
        parser.error('--device is required unless --compile-only is used')
    if args.output.exists():
        parser.error('Use a fresh output directory; evidence is not overwritten')
    identifier = 'com.socialbox.layout.fixture.' + uuid.uuid4().hex
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix='socialbox-layout-fixture-') as directory:
            app = Path(directory) / 'LayoutFixture.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'LayoutFixture',
                'CFBundleName': 'Synthetic layout fixture', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1', 'CFBundlePackageType': 'APPL',
                'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '15.0',
                'UIDeviceFamily': [1], 'UILaunchScreen': {}}))
            sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
            sources = ['SBContainersView.m', 'SBSavedContainerSetup.m', 'SBWorkspaceCoordinator.m', 'SBBackendAdapter.m', 'SBDesign.m', 'SBInterfaceCopy.m']
            saved_sources = ['LBXContainerConfiguration.m', 'LBXContainerIPC.m', 'LBXContainerMutationIPC.m', 'LBXContainerRootMutationCoordinator.m']
            translation_units = [*[HERE.parent/name for name in sources], HERE/'layout_fixture.m',
                HERE/'activation_transport_fixture.m', HERE/'saved_setup_transport_fixture.m',
                HERE.parent.parent/'Authorization/LBXLicenseIPC.m',
                *[HERE.parent.parent/'Containers'/name for name in saved_sources]]
            before = input_snapshot(translation_units)
            run('xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                '-DSB_BACKEND_ADAPTER_TESTING=1', '-target', 'arm64-apple-ios15.0-simulator',
                '-isysroot', sdk, '-I' + str(HERE.parent), '-I' + str(HERE.parent.parent / 'Diagnostics'), '-framework', 'UIKit',
                '-framework', 'Foundation', '-framework', 'QuartzCore', '-framework', 'CoreGraphics',
                *map(str, translation_units),
                '-o', str(app / 'LayoutFixture'))
            if input_snapshot(translation_units) != before:
                raise RuntimeError('Layout fixture inputs changed during compilation; retain attempt and rerun')
            if args.compile_only:
                args.output.mkdir(parents=True)
                shutil.copytree(app, args.output / app.name)
                (args.output/'compile-result.json').write_text(json.dumps({'ok': True, 'sourceStable': True, 'buildInputsSHA256': before}, indent=2)+'\n')
                print('Layout fixture compiled with warnings as errors; no simulator used.')
                return
            run('codesign', '--force', '--sign', '-', str(app))
            run('xcrun', 'simctl', 'install', args.device, str(app))
            installed = True
            container = Path(run('xcrun', 'simctl', 'get_app_container', args.device, identifier, 'data'))
            run('xcrun', 'simctl', 'launch', args.device, identifier)
            result = container / 'Documents/layout-result.json'
            deadline = time.monotonic() + 45
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(.2)
            if not result.exists():
                raise RuntimeError('Layout fixture did not complete')
            args.output.mkdir(parents=True)
            for item in (container / 'Documents').iterdir():
                shutil.copy2(item, args.output / item.name)
            report = json.loads(result.read_text())
            if input_snapshot(translation_units) != before:
                raise RuntimeError('Layout fixture inputs changed during compilation/execution; retain attempt and rerun')
            report['buildInputsSHA256'] = before
            report['sourceStable'] = True
            (args.output/'layout-result.json').write_text(json.dumps(report, indent=2)+'\n')
            print(json.dumps(report, indent=2))
            if not report['ok']:
                raise SystemExit(1)
    finally:
        if installed:
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, identifier], capture_output=True, timeout=15)
            run('xcrun', 'simctl', 'uninstall', args.device, identifier)


if __name__ == '__main__':
    main()
