#!/usr/bin/env python3
"""The actual postinst must bootstrap once without killing the new service."""
from pathlib import Path
import os,subprocess,tempfile
source=(Path(__file__).resolve().parents[1]/'layout/DEBIAN/postinst').read_text()
with tempfile.TemporaryDirectory() as tmp:
 root=Path(tmp).resolve();plist=root/'Library/LaunchDaemons/com.redditbox.daemon.plist';plist.parent.mkdir(parents=True);plist.write_text('fixture')
 script=root/'postinst';script.write_text(source.replace('/var/jb',str(root)))
 shell='''launchctl() { case "$1" in
print) test -f "$BOOTED" && printf 'pid = 123\\n';;
bootstrap) test ! -f "$BOOTED" || return 98; : > "$BOOTED";;
kickstart) echo 'redundant restart' >&2; return 99;;
*) return 97;; esac; }
chown() { :; }
uicache() { :; }
sleep() { :; }
set -- configure
. "$SCRIPT"
'''
 r=subprocess.run(['sh','-c',shell],env=dict(os.environ,SCRIPT=str(script),BOOTED=str(root/'booted')),capture_output=True,text=True)
 assert r.returncode==0,r.stderr
 assert (root/'booted').exists()
 print('PASS actual postinst performs one bootstrap with no destructive second kickstart; mocked service only')
