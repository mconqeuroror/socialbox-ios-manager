#!/usr/bin/env python3
"""Focused synthetic UIKit secondary-renderer checks; never loads the backend."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent


def run(*args):
    completed = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if completed.returncode:
        raise RuntimeError(completed.stderr or completed.stdout)
    return completed.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a new output directory; evidence is not overwritten')
    identifier = 'com.socialbox.secondary.fixture.' + uuid.uuid4().hex
    installed = False
    try:
        with tempfile.TemporaryDirectory(prefix='socialbox-secondary-fixture-') as directory:
            app = Path(directory) / 'SecondaryFixture.app'
            app.mkdir()
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'SecondaryFixture',
                'CFBundleName': 'Synthetic secondary fixture', 'CFBundleVersion': '1',
                'CFBundleShortVersionString': '1', 'CFBundlePackageType': 'APPL',
                'LSRequiresIPhoneOS': True, 'MinimumOSVersion': '15.0',
                'UIDeviceFamily': [1], 'UILaunchScreen': {}}))
            sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
            run('xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra',
                '-target', 'arm64-apple-ios15.0-simulator', '-isysroot', sdk,
                '-I' + str(HERE.parent), '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreGraphics',
                str(HERE.parent / 'SBSecondaryScreens.m'), str(HERE.parent / 'SBDesign.m'), str(HERE.parent / 'SBInterfaceCopy.m'),
                str(HERE.parent / 'LBXDisplayCopy.m'), str(HERE.parent / 'SBLegacyDisplayCatalog.m'),
                str(HERE / 'secondary_fixture.m'), '-o', str(app / 'SecondaryFixture'))
            run('codesign', '--force', '--sign', '-', str(app))
            run('xcrun', 'simctl', 'install', args.device, str(app))
            installed = True
            container = Path(run('xcrun', 'simctl', 'get_app_container', args.device, identifier, 'data'))
            run('xcrun', 'simctl', 'launch', args.device, identifier)
            result = container / 'Documents/secondary-result.json'
            deadline = time.monotonic() + 45
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(.2)
            if not result.exists():
                raise RuntimeError('Secondary fixture did not complete')
            args.output.mkdir(parents=True)
            for item in (container / 'Documents').iterdir():
                shutil.copy2(item, args.output / item.name)
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
