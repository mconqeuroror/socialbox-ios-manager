#!/usr/bin/env python3
"""Run the synthetic adapter ABI and stable-ID checks without recovered binaries."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='An already booted iOS Simulator UDID')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a fresh output directory; evidence is not overwritten')
    identifier = 'com.socialbox.backend.fixture.' + uuid.uuid4().hex
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix='socialbox-backend-fixture-') as directory:
            app = Path(directory) / 'BackendFixture.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'BackendFixture',
                'CFBundleName': 'Synthetic backend fixture', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1', 'CFBundlePackageType': 'APPL',
                'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '15.0',
                'UIDeviceFamily': [1], 'UILaunchScreen': {}}))
            sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
            run('xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                '-DSB_BACKEND_ADAPTER_TESTING=1', '-target', 'arm64-apple-ios15.0-simulator',
                '-isysroot', sdk, '-I' + str(HERE.parent), '-framework', 'UIKit',
                '-framework', 'Foundation', '-framework', 'QuartzCore',
                str(HERE.parent / 'SBBackendAdapter.m'), str(HERE / 'backend_adapter_fixture.m'),
                '-o', str(app / 'BackendFixture'))
            run('codesign', '--force', '--sign', '-', str(app))
            run('xcrun', 'simctl', 'install', args.device, str(app))
            installed = True
            container = Path(run('xcrun', 'simctl', 'get_app_container', args.device, identifier, 'data'))
            run('xcrun', 'simctl', 'launch', args.device, identifier)
            result = container / 'Documents/backend-adapter-result.json'
            deadline = time.monotonic() + 45
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(.2)
            if not result.exists():
                raise RuntimeError('Backend fixture did not complete')
            args.output.mkdir(parents=True)
            (args.output / result.name).write_bytes(result.read_bytes())
            report = json.loads(result.read_text())
            print(json.dumps(report, indent=2))
            if not report['ok']:
                raise SystemExit(1)
    finally:
        if installed:
            subprocess.run(['xcrun', 'simctl', 'terminate', args.device, identifier], capture_output=True, timeout=15)
            run('xcrun', 'simctl', 'uninstall', args.device, identifier)


if __name__ == '__main__':
    main()
