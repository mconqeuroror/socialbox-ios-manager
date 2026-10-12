#!/usr/bin/env python3
"""Exercise maintainer flow with synthetic process enumeration and signals."""
import os
from pathlib import Path
import subprocess
import tempfile
source=(Path(__file__).resolve().parents[1]/'layout/DEBIAN/preinst').read_text()
for prefix in ('var/jb', ''):
 with tempfile.TemporaryDirectory() as tmp:
  root=Path(tmp).resolve()/prefix;old=root/'Applications/SocialBox.app/SocialBox';old.parent.mkdir(parents=True)
  old.write_text('preserve existing executable');script=Path(tmp)/'preinst'
  script.write_text(source.replace('/var/jb',str(root)))
  env=dict(os.environ,SCRIPT=str(script));runner='ps() { echo UNEXPECTED_PROCESS_ENUMERATION; return 91; }; set -- install; . "$SCRIPT"'
  r=subprocess.run(['sh','-c',runner],env=env,capture_output=True,text=True)
  assert r.returncode==1 and 'backed-up data migration' in r.stderr and not r.stdout
  assert old.read_text()=='preserve existing executable'
print('PASS incompatible-engine preflight refuses before signals or writes for both variants')
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp).resolve();(root/'Applications/RedditBox.app').mkdir(parents=True);(root/'Applications/RedditBoxFirewall.app').mkdir()
 script=root/'preinst';script.write_text(source.replace('/var/jb',str(root)));killed=root/'killed';closed=root/'closed'
 runner='''ps() { test -f "$CLOSED" || printf '12 %s/Applications/RedditBox.app/RedditBox\\n' "$FIXTURE"; printf '13 /other/RedditBox.app/RedditBox\\n'; }
kill() { test "$1" = -TERM && test "$2" = 12 || return 99; printf '%s' "$2" > "$KILLED"; : > "$CLOSED"; }
sleep() { :; }
set -- upgrade
. "$SCRIPT"
'''
 env=dict(os.environ,FIXTURE=str(root),SCRIPT=str(script),CLOSED=str(closed),KILLED=str(killed))
 r=subprocess.run(['sh','-c',runner],env=env,capture_output=True,text=True);assert r.returncode==0,r.stderr;assert killed.read_text()=='12'
 r=subprocess.run(['sh','-c','ps() { return 1; }; set -- upgrade; . "$SCRIPT"'],env=env,capture_output=True,text=True);assert r.returncode!=0
 r=subprocess.run(['sh','-c','ps() { return 1; }; set -- abort-upgrade; . "$SCRIPT"'],env=env,capture_output=True,text=True);assert r.returncode==0
 print('PASS preinst exact executable selection, process-read failure and irrelevant action; no actual process signaled')

# Exercise retirement of the actual 0.1.26 shortcut, for both package prefixes.
# Other app paths are decoys; no global refresh, original app removal or data
# writes are needed to unregister one obsolete entry icon.
for prefix in ('var/jb', ''):
 with tempfile.TemporaryDirectory() as tmp:
  root=Path(tmp).resolve(); installed=root/prefix
  retired=installed/'Applications/SocialBoxFacebook.app'
  retired.mkdir(parents=True);(retired/'Info.plist').write_text('fixture')
  original=installed/'Applications/Facebook.app';original.mkdir()
  (original/'account').write_text('keep original data')
  script=root/'preinst';script.write_text(source.replace('/var/jb',str(installed)))
  env=dict(os.environ,SCRIPT=str(script),RETIRED=str(retired),CLOSED=str(root/'closed'),CALLED=str(root/'called'))
  runner='''ps() { test -f "$CLOSED" || printf '14 %s/SocialBoxFacebook\\n' "$RETIRED"; printf '15 /other/SocialBoxFacebook.app/SocialBoxFacebook\\n'; }
kill() { test "$1" = -TERM && test "$2" = 14 || return 99; : > "$CLOSED"; }
sleep() { :; }
uicache() { test "$1" = -u && test "$2" = "$RETIRED" && test "$#" = 2 || return 99; test -f "$CLOSED" || return 98; printf '%s' "$2" > "$CALLED"; }
set -- upgrade
. "$SCRIPT"
'''
  r=subprocess.run(['sh','-c',runner],env=env,capture_output=True,text=True)
  assert r.returncode==0,r.stderr
  assert (root/'called').read_text()==str(retired)
  assert (retired/'Info.plist').is_file(),'dpkg, not preinst, owns file removal'
  assert (original/'account').read_text()=='keep original data'
  # A registration failure must fail the upgrade rather than report success.
  r=subprocess.run(['sh','-c','ps() { :; }; uicache() { return 23; }; set -- upgrade; . "$SCRIPT"'],env=env,capture_output=True,text=True)
  assert r.returncode==23,r.stderr
  (retired/'Info.plist').unlink()
  # No retired installation: registration is unnecessary, even if unavailable.
  r=subprocess.run(['sh','-c','ps() { :; }; uicache() { return 99; }; set -- install; . "$SCRIPT"'],env=env,capture_output=True,text=True)
  assert r.returncode==0,r.stderr
print('PASS rootless/rootful shortcut retirement: exact process and icon, failure propagation, absent-bundle no-op, originals preserved')
