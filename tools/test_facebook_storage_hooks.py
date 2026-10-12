#!/usr/bin/env python3
"""Compile actual Logos storage hooks; real Foundation/CFPreferences, inert C patcher.

Objective-C methods are really swizzled. C wrappers invoke native originals,
without patching macOS dyld. Temporary enabled registry is fixture-only.
"""
from pathlib import Path
import os, subprocess, tempfile, shutil
ROOT=Path(__file__).resolve().parents[1]
THEOS=Path(os.environ['THEOS'])
source=ROOT/'tweak/Container/RBXFacebookStorageHooks.xm'
with tempfile.TemporaryDirectory(prefix='fb-storage-hooks-') as temp:
 p=Path(temp);shared=p/'shared';shutil.copytree(ROOT/'shared',shared)
 generated=subprocess.check_output(['perl',str(THEOS/'bin/logos.pl'),str(source)],text=True)
 lines=[line for line in generated.splitlines() if not (line.startswith('#import "RBX') or line=='#include <substrate.h>' or line.startswith('__asm__(".linker_option'))]
 body='\n'.join(lines)
 fixture=(ROOT/'tools/test_facebook_storage_hooks.mm').read_text().replace('// ACTUAL_GENERATED_HOOKS',body)
 (p/'test.mm').write_text(fixture)
 cmd=['xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks','-Wall','-Wextra','-Werror','-Wno-unused-parameter','-Wno-nullability-completeness','-I'+str(shared),'-framework','Foundation','-framework','Security',str(p/'test.mm'),'-o',str(p/'test')]
 subprocess.run(cmd,check=True);subprocess.run([str(p/'test'),'inactive'],check=True)
 data=(shared/'RBXAppRegistryData.h').read_text();assert data.count('@"runnable": @NO')==1
 (shared/'RBXAppRegistryData.h').write_text(data.replace('@"runnable": @NO','@"runnable": @YES'))
 subprocess.run(cmd,check=True)
 for mode in ['active','unvalidated','foreign-container','foreign-bundle','original','groups','reddit','source-version','source-build','runtime-version','runtime-build','hook-failure']:
  subprocess.run([str(p/'test'),mode],check=True)
 entry=(ROOT/'tweak/RedditBox.xm').read_text()
 assert 'installed[@"defaults-wire"] = @NO;' in entry
 assert 'installed[@"facebook-storage"] = @(RBXInstallFacebookStorageHooks(mgr));' in entry
 print('PASS production Facebook remains inactive and total wire readiness withheld')
