#!/usr/bin/env python3
"""Offline catalog provenance/applicability and saved-template compatibility checks.

Uses the reviewed Apple Software Lookup evidence snapshot. No live website is
needed for a build, and a changing upstream feed cannot silently change choices.
"""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / 'profiles/catalog.json').read_text())
evidence = json.loads((ROOT / 'docs/device-catalog-evidence.json').read_text())
lookup = evidence['softwareLookup']
baseline = evidence['compatibilityBaseline']


def version(value):
    assert re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', value), value
    parts = tuple(map(int, value.split('.')))
    return parts + (0,) * (3 - len(parts))


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


assert lookup['url'] == 'https://gdmf.apple.com/v2/pmv'
assert re.fullmatch(r'[0-9a-f]{64}', lookup['responseSHA256'])
assert set(catalog['models']) == set(baseline['models']), 'No invented or removed hardware templates'
for section in ('iosBuilds', 'darwinReleases'):
    for os, value in baseline[section].items():
        assert catalog[section][os] == value, f'Existing tuple changed: {os} {section}'
for product, saved in baseline['models'].items():
    model = catalog['models'][product]
    assert digest({key: model[key] for key in saved['fields']}) == saved['fieldSHA256'], product
    assert set(saved['iosVersions']) <= set(model['iosVersions']), f'Existing choices removed: {product}'
    assert len(model['iosVersions']) == len(set(model['iosVersions']))
    assert model['iosVersions'] == sorted(model['iosVersions'], key=version, reverse=True)
    minimum = evidence['minimumRuntimeEvidence'][product]
    assert model['minimumIOS'] == minimum['minimumRuntime']
    assert re.fullmatch(r'[0-9a-f]{64}', minimum['profileSHA256'])
    for os in model['iosVersions']:
        assert version(os) >= version(model['minimumIOS']), (product, os)
        assert catalog['iosBuilds'].get(os) and catalog['darwinReleases'].get(os), (product, os)
        assert version(os) < (27, 0, 0), 'RC/beta must not become a stable choice'

expected = {
    '18.7.8': ('22H352', '24.6.0'), '26.5': ('23F77', '25.5.0'),
    '26.5.1': ('23F81', '25.5.0'), '26.5.2': ('23F84', '25.5.0'),
    '26.6': ('23G71', '25.6.0'), '26.6.1': ('23G83', '25.6.0'),
}
assert set(lookup['newVersions']) == set(expected)
for os, (build, darwin) in expected.items():
    entry = lookup['releases'][os]
    assert entry['classification'] == 'public-release'
    assert entry['sourceSection'] == 'AssetSets.iOS'
    assert entry['build'] == catalog['iosBuilds'][os] == build
    assert entry['darwinRelease'] == catalog['darwinReleases'][os] == darwin
    assert 'inference' in entry['darwinEvidence'], 'Do not mislabel a template as a measured kernel'
    supported = set(entry['supportedDevices']) & set(catalog['models'])
    assert set(entry['supportedCatalogModels']) == supported
    actual = {product for product, model in catalog['models'].items() if os in model['iosVersions']}
    assert actual == supported, f'Choice membership differs from Apple evidence: {os}'

# The model-specific maintenance branch must not be offered to every iPhone.
family17 = {'iPhone18,1', 'iPhone18,2', 'iPhone18,3', 'iPhone18,4', 'iPhone18,5'}
assert set(lookup['releases']['26.5.1']['supportedCatalogModels']) == family17
assert not family17.intersection(lookup['releases']['18.7.8']['supportedCatalogModels'])
for product in family17:
    assert len(catalog['models'][product]['iosVersions']) == 5, 'New models need the evidenced OS choices'
assert any(row.get('status') == 'release-candidate' for row in evidence['deferredChoices'])
assert evidence['legacyDiscrepancies'][0]['preservedCatalogValue'] == catalog['models']['iPhone14,8']['hwModelStr']
print(f"PASS: {len(catalog['models'])} preserved model templates, {sum(len(m['iosVersions']) for m in catalog['models'].values())} coherent choices, six primary-evidenced releases and explicit unknowns")
