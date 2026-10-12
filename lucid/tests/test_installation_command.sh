#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ -n "${1:-}" ]]; then
  installation_command_evidence="$1"
  [[ ! -e "$installation_command_evidence" && ! -L "$installation_command_evidence" ]] || { echo 'Use a fresh evidence directory; prior attempts are preserved' >&2; exit 2; }
  mkdir -m 700 "$installation_command_evidence"
else
  installation_command_evidence="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-command-evidence.XXXXXX")"
fi
installation_command_evidence="$(cd "$installation_command_evidence" && pwd -P)"
installation_command_temporary="$(mktemp -d "${TMPDIR:-/tmp}/socialbox-command-build.XXXXXX")"
installation_command_snapshot() {
  python3 - "$installation_command_evidence" "$1" <<'PY'
import hashlib,json,re,sys
from pathlib import Path
root=Path.cwd().resolve(); evidence=Path(sys.argv[1]); stage=sys.argv[2]
pending={'lucid/tests/installation_command.m','lucid/tests/test_installation_command.sh'}; found={}
while pending:
    name=pending.pop(); path=root/name
    if path.is_symlink() or not path.is_file() or path.resolve()!=path: raise ValueError('Aliased or missing quoted input: '+name)
    raw=path.read_bytes(); found[name]=hashlib.sha256(raw).hexdigest()
    destination=evidence/('source-'+stage)/name; destination.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
    destination.write_bytes(raw); destination.chmod(0o600)
    if path.suffix not in ('.m','.h','.def'): continue
    for include in re.findall(rb'^\s*#\s*(?:import|include)\s*"([^"\n]+)"',raw,re.M):
        target=(path.parent/include.decode()).resolve()
        if not target.is_relative_to(root): raise ValueError('Escaping quoted source input')
        relative=str(target.relative_to(root))
        if relative not in found: pending.add(relative)
(evidence/('source-'+stage+'.json')).write_text(json.dumps(dict(sorted(found.items())),indent=2)+'\n')
PY
}
installation_command_finish() {
  installation_command_status=$?
  trap - EXIT
  set +e
  installation_command_snapshot after > "$installation_command_evidence/freeze-after.log" 2>&1
  installation_command_after_status=$?
  python3 - "$installation_command_evidence" "$installation_command_status" "$installation_command_after_status" <<'PY'
import hashlib,json,re,sys
from pathlib import Path
evidence=Path(sys.argv[1]); status=int(sys.argv[2]); after_status=int(sys.argv[3])
before=json.loads((evidence/'source-before.json').read_text()) if (evidence/'source-before.json').exists() else {}
after=json.loads((evidence/'source-after.json').read_text()) if (evidence/'source-after.json').exists() else {}
stable=bool(before) and after_status==0 and before==after
log=evidence/'host.log'; text=log.read_text() if log.exists() else ''
match=re.search(r'(PASS|FAIL): (\d+) command boundary assertions, (\d+) failures, (\d+) inert entry dispatches',text)
result={'status':'PASS' if status==0 and stable and match and match[1]=='PASS' else 'FAIL',
    'exitCode':status,'sourceStable':stable,'sourceSHA256':after,'sourceFileCount':len(before),
    'assertions':int(match[2]) if match else None,'failures':int(match[3]) if match else None,'dispatches':int(match[4]) if match else None,
    'privateLogSHA256':hashlib.sha256(log.read_bytes()).hexdigest() if log.exists() else None,
    'compileLogSHA256':hashlib.sha256((evidence/'host-compile.log').read_bytes()).hexdigest() if (evidence/'host-compile.log').exists() else None,
    'sourceStabilityScope':'Complete quoted repository graph for the actual CLI dispatch translation unit plus this runner. Native factory implementation is deliberately not linked; Foundation/SDK/compiler/OS dependencies are excluded.',
    'acceptanceScope':'Actual CLI entry with fixture-only identity substitutions, inert factory/current results and temporary sentinel preservation. No native preparation/provenance, first-install authority/history, customer/device/network/package/runtime/admission acceptance.'}
(evidence/'result.json').write_text(json.dumps(result,indent=2)+'\n')
for path in evidence.rglob('*'):
    if path.is_file(): path.chmod(0o600)
print(json.dumps(result,indent=2))
sys.exit(0 if result['status']=='PASS' else 1)
PY
  installation_command_result_status=$?
  rm -rf "$installation_command_temporary"
  exit "$installation_command_result_status"
}
trap installation_command_finish EXIT
installation_command_snapshot before > "$installation_command_evidence/freeze-before.log" 2>&1
xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -framework Foundation \
  lucid/tests/installation_command.m -o "$installation_command_temporary/test" > "$installation_command_evidence/host-compile.log" 2>&1
"$installation_command_temporary/test" 2>&1 | tee "$installation_command_evidence/host.log"
