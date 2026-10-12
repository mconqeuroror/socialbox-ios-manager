#!/usr/bin/env python3
"""Build a synthetic iOS storage probe using actual Logos and Substrate hooks.

Usage: THEOS=... python3 tools/build_facebook_storage_device_probe.py OUTPUT_DIR
Sign the result with ldid. Run seed/verify/clean with one fresh 32-hex nonce.
This CLI helper is NOT an actual sandboxed Facebook app acceptance test.
"""
from pathlib import Path
import os,subprocess,shutil,sys,plistlib
root=Path(__file__).resolve().parents[1];out=Path(sys.argv[1]).resolve();out.mkdir(exist_ok=True,parents=True)
shutil.copytree(root/'shared',out/'shared',dirs_exist_ok=True)
h=out/'shared/RBXAppRegistryData.h';h.write_text(h.read_text().replace('@"runnable": @NO','@"runnable": @YES'))
src=root/'tweak/Container/RBXFacebookStorageHooks.xm'
generated=subprocess.check_output(['perl',os.environ['THEOS']+'/bin/logos.pl',str(src)],text=True)
body='\n'.join(l for l in generated.splitlines() if not(l.startswith('#import "RBX') or l=='#include <substrate.h>' or l.startswith('__asm__(".linker_option')))
prefix=(root/'tools/test_facebook_storage_hooks.mm').read_text().split('// ACTUAL_GENERATED_HOOKS')[0]
a=prefix.index('static void MSHookFunction(');b=prefix.index('#define NSBundle',a)
prefix=prefix[:a]+r'''
#import <dlfcn.h>
static void *Substrate;
static NSString *FixtureHome;
static NSString *ProbeHome(void){return FixtureHome;}
#define NSHomeDirectory ProbeHome
static void MSHookFunction(void *target,void *replacement,void **original){
 FunctionHooks++;auto hook=(void (*)(void *,void *,void **))dlsym(Substrate,"MSHookFunction");
 Check(hook!=NULL,@"Substrate function hook available");hook(target,replacement,original);
 Check(*original && *original!=target,@"real C trampoline installed");
}
static void MSHookMessageEx(Class target,SEL selector,IMP replacement,IMP *original){
 MessageHooks++;auto hook=(void (*)(Class,SEL,IMP,IMP *))dlsym(Substrate,"MSHookMessageEx");
 Check(hook!=NULL,@"Substrate message hook available");hook(target,selector,replacement,original);
 Check(*original && method_getImplementation(class_getInstanceMethod(target,selector))==replacement,@"real Foundation method installed");
}
static BOOL RBXHookInstallationPassed(void){return FunctionHooks==14&&MessageHooks==10;}
''' + prefix[b:]
main=(root/'tools/facebook_storage_device_probe_main.inc').read_text()
(out/'probe.mm').write_text(prefix+body+'\n#undef NSBundle\n'+main)
sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
subprocess.run(['xcrun','clang++','-isysroot',sdk,'-arch','arm64','-miphoneos-version-min=15.0','-std=c++17','-fobjc-arc','-fblocks','-Wno-nullability-completeness','-I'+str(out/'shared'),'-framework','Foundation','-framework','Security',str(out/'probe.mm'),'-o',str(out/'probe')],check=True)
(out/'entitlements.plist').write_bytes(plistlib.dumps({'application-identifier':'SBXFBCLN00.com.socialbox.storage-diagnostic','com.apple.developer.team-identifier':'SBXFBCLN00'}))
print(out/'probe')
