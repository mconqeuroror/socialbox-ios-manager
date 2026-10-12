#!/usr/bin/env python3
"""Validate the evidence contract, regenerate its table, and gate changed files."""
import argparse
from collections import Counter
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from enumerate_leak_source import ROOT, enumerate_source, shipped_path

DIRECTORY = ROOT / 'docs/leak-surface'
VERDICTS = {'covered-in-code', 'gap', 'unverified', 'not-used-with-evidence'}
COVERAGE = {'hook', 'sandbox', 'generator', 'blocked', 'none'}

def validate_rows(rows, root=ROOT):
    ids = set()
    for row in rows:
        ident = row.get('id', '')
        if not re.fullmatch(r'[A-Z]+-\d{3}', ident) or ident in ids:
            raise ValueError(f'invalid or duplicate row ID: {ident}')
        ids.add(ident)
        for field in ('category', 'surface', 'mechanism', 'verification', 'fix'):
            if not isinstance(row.get(field), str) or not row[field].strip():
                raise ValueError(f'{ident}: missing {field}')
        if row.get('verdict') not in VERDICTS:
            raise ValueError(f'{ident}: invalid verdict')
        coverage = row.get('coverage')
        if isinstance(coverage, str): coverage = [coverage]
        if not coverage or not set(coverage) <= COVERAGE:
            raise ValueError(f'{ident}: invalid coverage mechanism')
        if not row.get('evidence'):
            raise ValueError(f'{ident}: no evidence')
        for evidence in row['evidence']:
            name, line = evidence.get('path', ''), evidence.get('line')
            if not name or Path(name).is_absolute() or '..' in Path(name).parts:
                raise ValueError(f'{ident}: evidence must be repository-relative')
            path = root / name
            if not path.is_file() or not isinstance(line, int) or line < 1 or not evidence.get('detail'):
                raise ValueError(f'{ident}: missing evidence file/line/detail: {name}')
            if path.suffix != '.gz':
                lines = path.read_text().splitlines()
                if line > len(lines): raise ValueError(f'{ident}: stale line {name}:{line}')
                anchor = evidence.get('anchor')
                if anchor and anchor not in lines[line - 1]:
                    raise ValueError(f'{ident}: stale anchor {name}:{line}')
        if row['verdict'] == 'not-used-with-evidence' and not row.get('absenceProof'):
            raise ValueError(f'{ident}: absence needs an explicit proof, not a missing symbol')
    return ids

def rows_from_disk():
    rows = []
    for path in sorted(DIRECTORY.glob('*inventory.json')):
        for row in json.loads(path.read_text()).get('rows', []):
            rows.append(row)
    validate_rows(rows)
    if len(rows) < 100: raise ValueError('inventory unexpectedly contains fewer than 100 rows')
    return sorted(rows, key=lambda r: r['id'])

def cell(value):
    return str(value).replace('|', '&#124;').replace('\n', '<br>')

def render(rows):
    text = (DIRECTORY / 'method.md').read_text().rstrip() + '\n\n'
    counts = Counter(row['verdict'] for row in rows)
    text += '## Phase 1 — current verdict ledger\n\n'
    text += f'**{len(rows)} rows**: ' + '; '.join(f'{n} {kind}' for kind, n in sorted(counts.items())) + '.\n\n'
    text += '**A green host test is not a clean device/network audit. Every gap and unverified row remains an open acceptance item.**\n\n'
    text += 'This table is generated from the adjacent inventory JSON files. Edit the evidence records, then regenerate; do not hand-edit the generated table.\n\n'
    for category in sorted({row['category'] for row in rows}):
        text += f'### {category}\n\n'
        text += '| Row / surface | Mechanism / covered by | Verdict | Evidence | Verification / next action |\n'
        text += '| --- | --- | --- | --- | --- |\n'
        for row in (r for r in rows if r['category'] == category):
            coverage = row['coverage']
            if isinstance(coverage, list): coverage = ', '.join(coverage)
            evidence = '<br>'.join(f"[{e['path']}:{e['line']}]({e['path']}#L{e['line']}) — {cell(e['detail'])}" for e in row['evidence'])
            text += '| ' + ' | '.join([
                f"<a id=\"{row['id'].lower()}\"></a>**{row['id']}** {cell(row['surface'])}",
                cell(row['mechanism']) + '<br>**' + cell(coverage) + '**',
                cell(row['verdict']), evidence,
                cell(row['verification']) + '<br>**Next/fix:** ' + cell(row['fix'])]) + ' |\n'
        text += '\n'
    return text

def rows_at_revision(revision):
    names = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', revision, '--', 'docs/leak-surface'], cwd=ROOT, text=True).splitlines()
    rows = []
    for name in names:
        if name.endswith('inventory.json') and Path(name).name not in {'binary-inventory.json', 'source-inventory.json'}:
            document = json.loads(subprocess.check_output(['git', 'show', f'{revision}:{name}'], cwd=ROOT, text=True))
            rows.extend(document.get('rows', []))
    return rows


def changed_file_gate(rows, base):
    # The first adoption reviews from the explicit audit baseline, not all
    # unrelated history on a feature branch that predates this contract.
    configuration = json.loads((DIRECTORY / 'audit-inventory.json').read_text())
    adoption = configuration.get('contractBaseline')
    if adoption and not rows_at_revision(base):
        is_ancestor = lambda a, b: subprocess.run(['git', 'merge-base', '--is-ancestor', a, b], cwd=ROOT,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if is_ancestor(base, adoption) and is_ancestor(adoption, 'HEAD'):
            base = adoption
    by_id = {r['id']: r for r in rows}
    previous = rows_at_revision(base)
    previous_ids = {r['id'] for r in previous}
    if previous_ids - set(by_id):
        raise ValueError(f'row IDs cannot be silently removed: {sorted(previous_ids - set(by_id))}')
    history = {ident: set() for ident in by_id}
    for row in previous:
        history[row['id']].update(e['path'] for e in row['evidence'])
    commits = subprocess.check_output(['git', 'rev-list', '--reverse', f'{base}..HEAD'], cwd=ROOT, text=True).splitlines()
    for commit in commits:
        for row in rows_at_revision(commit):
            if row['id'] in history: history[row['id']].update(e['path'] for e in row['evidence'])
        message = subprocess.check_output(['git', 'show', '-s', '--format=%B', commit], cwd=ROOT, text=True)
        mentioned = set()
        for line in message.splitlines():
            if line.startswith('Leak-Surface:'):
                mentioned.update(re.findall(r'\b[A-Z]+-\d{3}\b', line))
        unknown = mentioned - set(by_id)
        if unknown: raise ValueError(f'{commit[:7]}: unknown trailer row IDs: {sorted(unknown)}')
        mappings = {e['path'] for ident in mentioned for e in by_id[ident]['evidence']}
        # Deleted/renamed files use their prior evidence under the retained ID.
        # Current row evidence must still be present and valid (validate_rows).
        mappings.update(name for ident in mentioned for name in history[ident] if not (ROOT / name).exists())
        parents = subprocess.check_output(['git', 'rev-list', '--parents', '-n', '1', commit], cwd=ROOT, text=True).split()[1:]
        diff_command = (['git', 'diff', '--name-only', parents[0], commit] if parents else
                        ['git', 'diff-tree', '--root', '--no-commit-id', '--name-only', '-r', commit])
        names = subprocess.check_output(diff_command, cwd=ROOT, text=True).splitlines()
        missing = [n for n in names if shipped_path(n) and n not in mappings]
        if missing:
            raise ValueError(f'{commit[:7]}: changed files need their own evidenced row trailer: ' + ', '.join(missing))


def validate_binary_residuals(binary):
    if binary['errors']:
        raise ValueError('binary scanner errors require resolution before accepting this snapshot')
    for image in binary['mach_o_files']:
        for part in image['slices']:
            if any(part['unresolved_references'].values()):
                raise ValueError(f"unresolved binary references in {image['path']}; repair enumeration before accepting")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='regenerate Markdown after reviewing JSON rows')
    parser.add_argument('--base', help='also require row references for shipped files changed since this Git ref')
    args = parser.parse_args()
    rows = rows_from_disk()
    binary = json.loads((DIRECTORY / 'binary-inventory.json').read_text())
    detail = binary['full_details']
    compressed = (DIRECTORY / detail['file']).read_bytes()
    if hashlib.sha256(compressed).hexdigest() != detail['gzip_sha256']:
        raise ValueError('binary inventory compressed evidence hash mismatch')
    if hashlib.sha256(gzip.decompress(compressed)).hexdigest() != detail['uncompressed_sha256']:
        raise ValueError('binary inventory decompressed evidence hash mismatch')
    if hashlib.sha256((ROOT / binary['scanner']).read_bytes()).hexdigest() != binary['scanner_sha256']:
        raise ValueError('binary scanner changed; rerun inventory on the private source IPA')
    validate_binary_residuals(binary)
    baseline = json.loads((DIRECTORY / 'source-inventory.json').read_text())
    if baseline != enumerate_source(ROOT):
        raise ValueError('source inventory drift: review changes and regenerate source-inventory.json')
    target = ROOT / 'LEAK_SURFACE.md'
    expected = render(rows)
    if args.write: target.write_text(expected)
    elif not target.exists() or target.read_text() != expected:
        raise ValueError('LEAK_SURFACE.md is stale; run this tool with --write after reviewing rows')
    if args.base: changed_file_gate(rows, args.base)
    print(f'Leak surface contract valid: {len(rows)} rows; source snapshot current. This is not device acceptance.')

if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as exc:
        print(f'FAIL: {exc}', file=sys.stderr)
        sys.exit(1)
