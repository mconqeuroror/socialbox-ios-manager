#!/usr/bin/env python3
"""Refresh both signed APT indexes without rebuilding RedditBox.

Uses the package publisher's shared local/Blob locks and a resumable journal.
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import json
import os
from pathlib import Path
import sys
import uuid

from release import (ROOT, MAX_METADATA, METADATA_NAMES, Publisher, atomic_json,
                     command, deployment_url, fetch, local_publication_lock, require)
from apt_repository import (dependency_repository, package_control, packages_bytes, parse_fields, release_bytes, repository_entries,
                            sha256, signed_checksums, validate_dependencies, validate_manifest)


def exact_files(base, expected, bypass=None):
    return all(fetch(base + name, MAX_METADATA, bypass=bypass) == bytes.fromhex(expected[name])
               for name in sorted(METADATA_NAMES))


def verify_snapshot(publishers, journal, origin=None, bypass=None):
    for name, publisher in publishers.items():
        base = origin.rstrip('/') + '/apt/' + publisher.package['repository'] + '/' if origin else publisher.repo
        manifest, _ = publisher.published(base, packages=True, bypass=bypass)
        require(manifest == journal['snapshots'][name]['manifest'], 'Package manifest changed during metadata refresh')
        require(exact_files(base, journal['snapshots'][name]['after'], bypass), 'Release metadata has not reached the expected snapshot')


def validate(journal, configurations):
    require(journal.get('configuration') == configurations and journal.get('formatVersion') == 1, 'Metadata refresh configuration changed')
    require(str(uuid.UUID(journal.get('owner', ''))) == journal['owner'], 'Invalid journal owner')
    require(journal.get('phase') in {'prepared', 'indexed', 'deployed', 'verified', 'promoting', 'promoted', 'complete'}, 'Invalid refresh phase')
    dependencies = journal.get('dependencyInput')
    if dependencies is not None:
        require(isinstance(dependencies, dict) and set(dependencies) == set(configurations), 'Both dependency variants are required')
    if journal['phase'] == 'prepared': return
    require(set(journal.get('snapshots', {})) == set(configurations), 'Missing repository snapshot')
    for name, snapshot in journal['snapshots'].items():
        architecture = 'iphoneos-arm64' if name == 'rootless' else 'iphoneos-arm'
        validate_manifest(snapshot['manifest'], configurations[name]['blobHost'], architecture)
        baseline = snapshot.get('beforeManifest', snapshot['manifest'])
        validate_manifest(baseline, configurations[name]['blobHost'], architecture)
        for label in ('before', 'after'):
            files = snapshot[label]
            require(METADATA_NAMES.issubset(files), 'Missing metadata file')
            for filename, data in files.items():
                require(filename in METADATA_NAMES or (filename.startswith('by-hash/SHA256/') and len(filename) == 79 and all(c in '0123456789abcdef' for c in filename[15:])), 'Unsafe metadata path')
                require(isinstance(data, str) and 0 < len(data) <= MAX_METADATA * 2, 'Invalid metadata size')
                bytes.fromhex(data)
            require(json.loads(bytes.fromhex(files['repository.json'])) == (baseline if label == 'before' else snapshot['manifest']), 'Snapshot manifest differs from metadata')
            require(bytes.fromhex(files['Packages']) == packages_bytes(repository_entries(baseline if label == 'before' else snapshot['manifest'])), 'Snapshot package index differs from manifest')
            for filename, expected in signed_checksums(bytes.fromhex(files['Release']), architecture).items():
                data = bytes.fromhex(files[filename])
                require(len(data) == expected['size'] and sha256(data) == expected['sha256'], 'Snapshot signed index mismatch')
        before, after = snapshot['before'], snapshot['after']
        if dependencies is None:
            require(set(before) == set(after), 'Metadata refresh must preserve every repository file')
            require(all(before[key] == after[key] for key in before if key not in {'Release', 'InRelease', 'Release.gpg'}), 'Metadata refresh must preserve packages, indexes and archive keys')
        else:
            ignored = {'dependencies', 'previousIndexes'}
            require({k:v for k,v in baseline.items() if k not in ignored} == {k:v for k,v in snapshot['manifest'].items() if k not in ignored}, 'Dependency publication must preserve RedditBox versions and metadata')
            require(all(before[key] == after[key] for key in ('public-key.asc', 'redditbox-archive-keyring.gpg')), 'Dependency publication must preserve archive keys')
        require(parse_fields(bytes.fromhex(after['Release']).decode()).get('Components') == 'main', 'Sileo requires the Components field')
    if journal['phase'] not in {'indexed'}:
        require(deployment_url(journal['deploymentURL']) == journal['deploymentURL'], 'Invalid staging URL')


def run(resume=False, dependencies_path=None, stage_only=False, restage=False):
    env = dict(os.environ)
    origin = env['APT_REPOSITORY_URL'].split('/apt/')[0]
    publishers = {}
    for scheme, repository in [('rootless', 'redditbox'), ('rootful', 'redditbox-rootful')]:
        publishers[scheme] = Publisher(ROOT, dict(env, RBX_PACKAGE_SCHEME=scheme, APT_REPOSITORY_URL=origin + '/apt/' + repository + '/'))
    primary = publishers['rootless']
    configurations = {name: p.config for name, p in publishers.items()}
    supplied = None
    if dependencies_path:
        input_path = Path(dependencies_path)
        require(input_path.stat().st_size <= MAX_METADATA, 'Oversized dependency input')
        supplied = json.loads(input_path.read_text())
        require(isinstance(supplied, dict) and set(supplied) == set(publishers), 'Supply dependency files for both variants')
    directory = ROOT / 'build/release'
    with local_publication_lock(directory):
        for p in publishers.values():
            if p.journal_path.exists():
                require(json.loads(p.journal_path.read_text()).get('phase') == 'complete', 'Finish the active package release before refreshing metadata')
        path = directory / 'metadata-refresh.json'
        journal = None
        if path.exists():
            require(path.stat().st_size <= 128 * 1024 * 1024, 'Oversized refresh journal')
            previous = json.loads(path.read_text()); validate(previous, configurations)
            if previous['phase'] != 'complete':
                require(resume, 'An interrupted metadata refresh exists; use --resume')
                journal = previous
                require(supplied is None or supplied == journal.get('dependencyInput'), 'Dependency input changed during resume')
            else:
                require(not resume, 'Metadata refresh is already complete')
                path.rename(directory / ('metadata-refresh-' + previous['owner'] + '.json'))
        else: require(not resume, 'No metadata refresh journal exists')
        if journal is None:
            journal = {'formatVersion': 1, 'configuration': configurations, 'owner': str(uuid.uuid4()), 'phase': 'prepared'}
            if supplied is not None: journal['dependencyInput'] = supplied
        def save(**values):
            journal.update(values); atomic_json(path, journal)
        save()
        receipt = primary.blob('lock', owner=journal['owner']); save(etag=receipt['etag'])
        if restage:
            require(resume and journal['phase'] == 'verified', 'Restaging requires --resume and an unpromoted verified deployment')
            require(all(exact_files(p.repo, journal['snapshots'][name]['before']) for name, p in publishers.items()), 'Production changed before restaging')
            save(phase='indexed', previousDeploymentURL=journal['deploymentURL'])
        if journal['phase'] == 'prepared':
            snapshots = {}
            for name, p in publishers.items():
                manifest, indexes = p.published(p.repo, packages=True)
                p.check_peer(local=True)
                files = {filename: fetch(p.repo + filename, MAX_METADATA) for filename in METADATA_NAMES}
                signed = p.verify_inrelease(files['InRelease'])
                require(files['Release'] == signed, 'Live Release differs from its valid signature')
                for filename, expected in signed_checksums(signed, p.package['architecture']).items():
                    require(len(files[filename]) == expected['size'] and sha256(files[filename]) == expected['sha256'], 'Live signed index changed')
                require(json.loads(files['repository.json']) == manifest, 'Live manifest changed while taking snapshot')
                files.update(indexes)
                before = {filename: data.hex() for filename, data in files.items()}
                baseline = manifest
                if journal.get('dependencyInput') is not None:
                    entries = []
                    inputs = journal['dependencyInput'][name]
                    require(isinstance(inputs, list) and len(inputs) == 2, 'Supply appinst and AppSync Unified for each variant')
                    for item in inputs:
                        artifact = Path(item['file'])
                        require(artifact.is_file() and not artifact.is_symlink() and artifact.stat().st_size <= 512 * 1024 * 1024, 'Invalid dependency file')
                        data, _, control, _ = package_control(artifact)
                        digest = sha256(data)
                        require(digest == item['sha256'], 'Dependency bytes differ from inspected input')
                        filename = f"{control['Package']}_{control['Version']}_{p.package['architecture']}.deb"
                        pathname = f"apt/{p.package['repository']}/debs/{digest}/{filename}"
                        entry = {'version': control['Version'], 'filename': 'debs/' + filename, 'sha256': digest, 'size': len(data), 'control': control, 'blobURL': f'https://{p.host}/{pathname}'}
                        validate_dependencies(entries + [entry], p.host, p.package['architecture'])
                        receipt = p.blob('upload', owner=journal['owner'], etag=journal['etag'], file=str(artifact), pathname=pathname)
                        require(receipt['url'] == entry['blobURL'] and receipt['sha256'] == digest and receipt['size'] == len(data), 'Dependency upload receipt mismatch')
                        entries.append(entry)
                    manifest, files = dependency_repository(baseline, entries, p.host, indexes)
                files['Release'] = release_bytes(files, format_datetime(datetime.now(timezone.utc), usegmt=True), p.package['architecture'])
                files = p.sign(files)
                snapshots[name] = {'manifest': manifest, 'beforeManifest': baseline, 'before': before, 'after': {filename: data.hex() for filename, data in files.items()}}
            save(phase='indexed', snapshots=snapshots)
            validate(journal, configurations)
        if journal['phase'] == 'indexed':
            for name, p in publishers.items():
                require(exact_files(p.repo, journal['snapshots'][name]['before']), 'Production changed before staging')
                p.materialize({filename: bytes.fromhex(data) for filename, data in journal['snapshots'][name]['after'].items()})
            print('Staging both corrected signed repositories', flush=True)
            output = command(['vercel', 'deploy', '--prod', '--skip-domain', '--yes', '--token', env['VERCEL_TOKEN']], cwd=ROOT, env=env, timeout=1800)
            save(phase='deployed', deploymentURL=deployment_url(output))
        if journal['phase'] == 'deployed':
            verify_snapshot(publishers, journal, journal['deploymentURL'], env.get('VERCEL_AUTOMATION_BYPASS_SECRET'))
            save(phase='verified')
        if stage_only:
            require(journal['phase'] == 'verified', 'Staging checkpoint requires an unpromoted verified deployment')
            print('Staging verified; publication lock retained. Check the cloud service, then use --resume to promote.', flush=True)
            return
        if journal['phase'] in {'verified', 'promoting'}:
            if not all(exact_files(p.repo, journal['snapshots'][name]['after']) for name, p in publishers.items()):
                require(all(exact_files(p.repo, journal['snapshots'][name]['before']) for name, p in publishers.items()), 'Production changed outside this refresh')
                primary.blob('check', owner=journal['owner'], etag=journal['etag'])
                save(phase='promoting')
                print('Promoting verified metadata correction', flush=True)
                command(['vercel', 'promote', journal['deploymentURL'], '--yes', '--token', env['VERCEL_TOKEN']], cwd=ROOT, env=env, timeout=600)
            save(phase='promoted')
        if journal['phase'] == 'promoted':
            verify_snapshot(publishers, journal)
            primary.blob('unlock', owner=journal['owner'], etag=journal['etag'])
            save(phase='complete')
        print('Published signed indexes for both repositories; RedditBox package versions and bytes unchanged.', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--dependencies', help='JSON inventory of inspected local dependency files and SHA256 hashes for both variants')
    parser.add_argument('--stage-only', action='store_true', help='Stop after staging verification, retaining the lock for service checks before --resume')
    parser.add_argument('--restage', action='store_true', help='With --resume, rebuild an unpromoted staging deployment after fixing its cloud code')
    args = parser.parse_args()
    try: run(args.resume, args.dependencies, args.stage_only, args.restage)
    except Exception as error:
        print(str(error) if isinstance(error, ValueError) else type(error).__name__ + ': metadata refresh failed', file=sys.stderr)
        print('Journal and lock retained; fix the cause and use --resume. Never delete or steal the lock.', file=sys.stderr)
        sys.exit(1)
