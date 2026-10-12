#!/usr/bin/env python3
"""Lexical inventory of shipped hook/API references; not proof of runtime coverage."""
import argparse, hashlib, json, re, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = ('tweak/', 'daemon/', 'shared/', 'launcher/', 'entry/', 'network-extension/', 'layout/', 'cloud/', 'scripts/', 'prefs/', 'sbhook/', 'profiles/', 'lucid/')
EXTENSIONS = {'.def', '.h', '.m', '.mm', '.xm', '.x', '.c', '.swift', '.plist', '.entitlements', '.ts', '.tsx', '.js', '.mjs', '.py', '.sh', '.yml', '.json'}

def shipped_path(name):
    if name.startswith('lucid/') and ('/Tests/' in name or '/tests/' in name):
        return False
    return (name.startswith(PREFIXES) and (Path(name).suffix in EXTENSIONS or Path(name).name == 'Makefile' or name.startswith('layout/DEBIAN/'))) or name in {'Makefile', 'build-scheme.mk', 'control', 'vercel.json', 'tools/leak_audit.py', 'tools/check_leak_surface.py', 'tools/enumerate_leak_binary.py', 'tools/enumerate_leak_source.py', '.github/workflows/leak-surface.yml'}

def enumerate_source(root):
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root).decode().split('\0')
    files, records = [], []
    for name in sorted(set(n for n in names if shipped_path(n) and (root / n).is_file())):
        data = (root / name).read_bytes()
        try: text = data.decode('utf-8')
        except UnicodeDecodeError: continue
        files.append({'path': name, 'sha256': hashlib.sha256(data).hexdigest()})
        for kind, expression in [
            ('objc-hook-class', r'^%hook\s+(\w+)'),
            ('framework-import', r'^\s*#(?:import|include)\s+<([^>]+)>'),
            ('dynamic-symbol', r'\bdlsym\s*\([^,]+,\s*"([^"\n]+)"'),
            ('dynamic-class', r'\b(?:NSClassFromString|objc_getClass)\s*\(\s*@?"([^"\n]+)"'),
            ('dynamic-selector', r'\bNSSelectorFromString\s*\(\s*@"([^"\n]+)"'),
            ('sysctl-key', r'\bsysctlbyname\s*\(\s*"([^"\n]+)"'),
            ('hook-installer-call', r'\b(RBXInstall\w+)\s*\('),
            ('c-hook-target', r'\bMSHookFunction\s*\(\s*(?:\([^)]*\)\s*)?([\w.]+)'),
        ]:
            for match in re.finditer(expression, text, re.M):
                records.append({'kind':kind,'name':match.group(1),'path':name,'line':text.count('\n',0,match.start())+1})
        # Keep method signatures per Logos block. A declaration is separate from
        # constructor installation: the coverage map must verify the installer.
        for block in re.finditer(r'^%hook\s+(\w+)(.*?)(?=^%end)',text,re.M|re.S):
            for method in re.finditer(r'^\s*([+-]\s*\([^\n]+?\)[^{;]+)\{',block.group(2),re.M):
                pos=block.start(2)+method.start()
                records.append({'kind':'objc-hook-method','name':' '.join(method.group(1).split()),'class':block.group(1),'path':name,'line':text.count('\n',0,pos)+1})
    records.sort(key=lambda x:(x['path'],x['line'],x['kind'],x['name']))
    return {'formatVersion':1,'scope':'versioned and new non-ignored shipped source; lexical references, not runtime reachability',
            'files':files,'counts':{k:sum(r['kind']==k for r in records) for k in sorted({r['kind'] for r in records})},'references':records}

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args=parser.parse_args(); result=enumerate_source(ROOT)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'files':len(result['files']),'counts':result['counts']}))
