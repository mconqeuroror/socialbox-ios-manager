#!/usr/bin/env python3
"""Prepare an immutable signed candidate; never publish, install, or clear build residuals.

The original RedditBox release.py pipeline and its two repositories are unchanged.
Run cloud/scripts/register-socialbox-release.ts to upload under the shared APT lock.
"""
import argparse, base64, datetime, gzip, hashlib, io, json, os, re, subprocess, tarfile, tempfile
from pathlib import Path
from apt_repository import package_control, packages_bytes, require

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.socialbox'  # Retained dpkg identity, required for an in-place upgrade.
def digest(data): return hashlib.sha256(data).hexdigest()

def verify_build_commit(report, commit, root=ROOT):
    require(re.fullmatch(r'[a-f0-9]{40}', commit) is not None, 'Exact source commit required')
    inputs = {'scripts/build-socialbox-helper-safety.py': report.get('builder_sha256')}
    for kind in ('overlay_build_inputs', 'helper_build_inputs'):
        hashes = report.get(kind, {}).get('sha256')
        require(isinstance(hashes, dict) and bool(hashes), 'Missing recorded build inputs: '+kind)
        for name, value in hashes.items():
            require(name not in inputs or inputs[name] == value, 'Conflicting input hash')
            inputs[name] = value
    for name, expected in inputs.items():
        require(isinstance(name, str) and not Path(name).is_absolute() and '..' not in Path(name).parts
                and isinstance(expected, str) and re.fullmatch(r'[a-f0-9]{64}', expected) is not None, 'Invalid recorded build input')
        raw = subprocess.check_output(['git', 'show', commit+':'+name], cwd=root, stderr=subprocess.PIPE)
        require(digest(raw) == expected, 'Build input differs from source commit: '+name)

def prepare(package, report, notes, fingerprint, host, commit):
    raw, payload, control, scripts = package_control(package)
    require(digest(raw) == report.get('package_sha256'), 'Package differs from build report')
    version = report.get('version', '')
    match = re.fullmatch(r'3\.1\.0-1\+socialbox\.([1-9][0-9]{0,5})', version)
    require(bool(match), 'Unsupported package version')
    sequence = int(match[1])
    require(report.get('upgrade_from') == f'3.1.0-1+socialbox.{sequence-1}', 'Exactly one pinned predecessor required')
    require(control.get('Package') == PACKAGE and control.get('Architecture') == 'iphoneos-arm64' and control.get('Version') == version, 'Wrong package identity')
    require(not scripts.get('conffiles', b'').strip(), 'Candidate may not own user configuration')
    require(set(scripts) == {'control', 'md5sums', 'preinst', 'postinst', 'prerm'}, 'Unexpected upgrade controls; the reviewed package has no postrm')
    # package_sha256 above pins every final control byte. The historical report's
    # replacement_postinst_sha256 names rollback-postinst.sh (before helper
    # startup wrapping), so it must not be mistaken for the packaged postinst.
    require(report.get('original_controls_backup_required') is True, 'Original-control backup guard required')
    require(isinstance(report.get('residuals'), list), 'Build report must explicitly enumerate release residuals')
    require(re.fullmatch(r'[0-9A-F]{40}|[0-9A-F]{64}', fingerprint) is not None, 'Explicit full APT signing fingerprint required')
    require(re.fullmatch(r'[a-z0-9][a-z0-9-]*\.public\.blob\.vercel-storage\.com', host) is not None, 'Dedicated public Blob host required')
    require(re.fullmatch(r'[a-f0-9]{40}', commit) is not None, 'Exact source commit required')
    require(0 < len(notes) <= 2000, 'Release notes must be 1–2000 characters')
    found = {}; expanded = 0
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:*') as archive:
        for entry in archive:
            name = entry.name.removeprefix('./').rstrip('/')
            require(not name.startswith('/') and '..' not in Path(name).parts and '\\' not in name, 'Unsafe payload path')
            if entry.isdir(): continue
            require(entry.isfile() and name not in found and entry.size <= 512*1024*1024, 'Unsafe payload entry')
            expanded += entry.size
            require(expanded <= 512*1024*1024 and len(found) < 50000, 'Expanded payload exceeds safety bounds')
            found[name] = digest(archive.extractfile(entry).read())
    require(found == report.get('payload_sha256'), 'Payload differs from reviewed build manifest')
    package_hash = digest(raw)
    entry = {'control': control, 'filename': f'pool/{package_hash}/socialbox_{sequence}_iphoneos-arm64.deb', 'size': len(raw), 'sha256': package_hash}
    packages = packages_bytes([entry])
    files = {'Packages': packages, 'Packages.gz': gzip.compress(packages, mtime=0)}
    date = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')
    release = ('Origin: SocialBox\nLabel: SocialBox\nSuite: stable\nCodename: socialbox\nArchitectures: iphoneos-arm64\nComponents: main\n'
               f'Description: SocialBox tested rootless upgrades\nDate: {date}\nAcquire-By-Hash: yes\nSHA256:\n')
    release += ''.join(f' {digest(data)} {len(data)} {name}\n' for name, data in files.items())
    files['Release'] = release.encode()
    with tempfile.TemporaryDirectory(prefix='socialbox-sign-') as scratch:
        directory = Path(scratch); (directory/'Release').write_bytes(files['Release'])
        def gpg(*args):
            return subprocess.run(['gpg', '--batch', '--yes', *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout
        gpg('--local-user', fingerprint, '--armor', '--output', str(directory/'InRelease'), '--clearsign', str(directory/'Release'))
        gpg('--local-user', fingerprint, '--armor', '--output', str(directory/'Release.gpg'), '--detach-sign', str(directory/'Release'))
        files['key.asc'] = gpg('--armor', '--export', fingerprint)
        require(bool(files['key.asc']), 'Signing public key not exported')
        for name in ('InRelease', 'Release.gpg'): files[name] = (directory/name).read_bytes()
        for args in [('--verify', str(directory/'Release.gpg'), str(directory/'Release')),
                     ('--output', str(directory/'verified'), '--decrypt', str(directory/'InRelease'))]:
            status = gpg('--status-fd', '1', *args).decode()
            require(any(line.startswith('[GNUPG:] VALIDSIG ') and fingerprint in line.split() for line in status.splitlines()), 'APT signing identity mismatch')
        require((directory/'verified').read_bytes() == files['Release'], 'InRelease body mismatch')
    for name in ('Packages', 'Packages.gz'): files['by-hash/SHA256/'+digest(files[name])] = files[name]
    return {'id': f'socialbox-{sequence}', 'sequence': sequence, 'packageVersion': version, 'sha256': package_hash, 'size': len(raw),
        'architecture': 'iphoneos-arm64', 'minimumIOS': '16.0', 'supportedFrom': [report['upgrade_from']], 'notes': notes, 'commit': commit,
        'blockers': list(report['residuals']),
        'artifactURL': f'https://{host}/apt/socialbox/artifacts/{package_hash}/socialbox_{sequence}_iphoneos-arm64.deb',
        'files': {name: {'base64': base64.b64encode(data).decode(), 'sha256': digest(data)} for name, data in files.items()}}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', required=True, type=Path); parser.add_argument('--build-report', required=True, type=Path)
    parser.add_argument('--notes', required=True, type=Path); parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    require(not args.output.exists(), 'Output already exists; retain immutable prepared candidates')
    report = json.loads(args.build_report.read_text())
    verify_build_commit(report, args.commit)
    candidate = prepare(args.package, report, args.notes.read_text().strip(),
        os.environ.get('APT_SIGNING_KEY_FINGERPRINT', '').replace(' ', '').upper(), os.environ.get('APT_BLOB_HOST', ''), args.commit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream: json.dump(candidate, stream, indent=2); stream.write('\n')
    print(f"Prepared {candidate['id']}; {len(candidate['blockers'])} engineering release blockers remain. Not published.")

if __name__ == '__main__': main()
