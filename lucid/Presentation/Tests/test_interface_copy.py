#!/usr/bin/env python3
"""Validate semantic UI references and run the Foundation-only copy fixture."""
from pathlib import Path
import json
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PRESENTATION = HERE.parent
SOURCES = ['LBXWorkspace', 'SBContainersView', 'SBSecondaryScreens',
           'SBIdentityForm', 'SBDesign', 'SBWorkspaceCoordinator', 'SBUpdateService', 'SBActivationView']


def main():
    source = (PRESENTATION / 'SBInterfaceCopy.m').read_text()
    entries = re.findall(r'^\s+@"([^"\n]+)":@"((?:[^"\\]|\\.)*)",$', source, re.M)
    catalog = dict(entries)
    assert len(entries) == len(catalog), 'Duplicate catalog key'
    references = []
    for name in SOURCES:
        content = (PRESENTATION / (name + '.m')).read_text()
        keys = re.findall(r'SBUIText\(@"([^"\n]+)"\)', content)
        assert keys, f'No semantic copy references in {name}'
        for key in keys:
            assert key in catalog, f'Unknown key in {name}: {key}'
        references.extend(keys)
        # Creation review passes these declared keys through its row loop.
        if name == 'SBContainersView':
            references.extend(re.findall(r'@"(creation\.(?:model|system|deviceName))"', content))
        for value in catalog.values():
            assert '@"' + value + '"' not in content, f'Authored copy remains inline in {name}: {value}'
    assert set(catalog) == set(references), 'Unreferenced authored copy keys'
    with tempfile.TemporaryDirectory(prefix='socialbox-interface-copy-') as directory:
        executable = Path(directory) / 'InterfaceCopyFixture'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
                        '-DDEBUG=1', '-framework', 'Foundation', '-I' + str(PRESENTATION),
                        str(PRESENTATION / 'SBInterfaceCopy.m'), str(HERE / 'interface_copy_fixture.m'),
                        '-o', str(executable)], check=True)
        result = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
        report = json.loads(result.stdout)
        assert 'missing authored interface key' in result.stderr, 'Debug missing-key diagnostic absent'
        report['referenceChecks'] = len(references)
        report['sourceFiles'] = len(SOURCES)
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
