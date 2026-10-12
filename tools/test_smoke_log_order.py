"""Run the shipped AWK checker against mixed-generation synthetic system logs."""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
awk = shutil.which('awk')
if not awk:
    candidate = Path(r'C:\Program Files\Git\usr\bin\awk.exe')
    if candidate.is_file():
        awk = str(candidate)
if not awk:
    raise SystemExit('AWK is required to execute the actual smoke log checker')
request, generation = '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'
suffix = f'request={request} generation={generation}'
ready = f'redditboxd: HOOK READINESS VERIFIED {suffix} pid=123\n'
ack = f'redditboxd: SYSTEM FIREWALL ACK state=open {suffix}\n'
opened = f'redditboxd: NETWORK OPEN {suffix}\n'
old = 'redditboxd: RBX_SELF_REPORT NOT_READY request=old generation=old pid=99\n'
cases = [
    ('matching final evidence', ready + ack + opened, True),
    ('unrelated earlier failure', old + ready + ack + opened, True),
    ('startup wait followed by verified final evidence', f'RBX_SELF_REPORT NOT_READY {suffix} pid=123\n' + ready + ack + opened, True),
    ('open precedes provider ACK', ready + opened + ack, False),
    ('missing final readiness', ack + opened, False),
    ('wrong clone PID', ready.replace('pid=123', 'pid=124') + ack + opened, False),
    ('different request same generation', (ready + ack + opened).replace(request, 'old'), False),
    ('different generation same request', (ready + ack + opened).replace(generation, 'old'), False),
    ('missing OPEN', ready + ack, False),
]
for name, log, expected in cases:
    result = subprocess.run([awk, '-v', f'request={request}', '-v', f'generation={generation}',
        '-v', 'clonePID=123', '-f', str(root / 'scripts/smoke-log-order.awk')],
        input=log, text=True, capture_output=True)
    assert (result.returncode == 0) == expected, (name, result.stdout, result.stderr)
    print(f'PASS {name}')
print(f'{len(cases)} smoke log ordering cases passed')
