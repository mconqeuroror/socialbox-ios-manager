#!/usr/bin/env python3
"""Actual FB UA hook installer/wrapper with inert substrate, bundle and resolver."""
from pathlib import Path
import subprocess,tempfile,shutil
ROOT=Path(__file__).resolve().parents[1]
path=ROOT/'tweak/Network/RBXFacebookUserAgentHooks.xm'
entry=(ROOT/'tweak/RedditBox.xm').read_text()
assert 'installed[@"defaults-wire"] = @NO;' in entry
assert entry.index('if ([app[@"appType"] isEqual:@"facebook"])') < entry.index('RBXInstallFacebookUserAgentHooks(mgr.currentProfile)')
assert 'return RBXAppDescriptorIsRegistered(descriptor) && [descriptor[@"appType"] isEqual:@"reddit"];' in (ROOT/'shared/RBXAppRuntime.h').read_text()
body=path.read_text().split('static NSString *(*fbua_original)',1)[1] if path.exists() else None
body='static NSString *(*fbua_original)'+body if body else '''
static NSString *fbua_userAgent(uintptr_t flavor){return nil;}
static BOOL RBXInstallFacebookUserAgentHooks(id profile){return NO;}
'''
fixture=r'''
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import "RBXAppRuntime.h"
#import "RBXFacebookUserAgent.h"
static NSString *ActualBundle,*BundlePath,*Version=@"578.1.0",*Build=@"1063022819",*ImagePath;
static BOOL SymbolExists=YES,AddressKnown=YES,HookSucceeds=YES,BadTrampoline=NO;
static NSUInteger Checks,HookCalls,ProviderCalls,Warnings;
static uintptr_t LastFlavor;
static NSString *Reply;
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
@interface RBXDeviceProfile : NSObject
@property NSDictionary *rawProfile;
@end
@implementation RBXDeviceProfile @end
@interface RBXContainerManager : NSObject
@property RBXDeviceProfile *currentProfile;
@property NSString *containerId;
@property BOOL validatedProfileLoaded;
+ (instancetype)sharedManager;
@end
@implementation RBXContainerManager
+ (instancetype)sharedManager{static id m;if(!m)m=[self new];return m;}
@end
@interface FixtureBundle : NSObject
+ (instancetype)mainBundle;
- (NSString *)bundleIdentifier;
- (NSString *)bundlePath;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@implementation FixtureBundle
+ (instancetype)mainBundle{return [self new];}
- (NSString *)bundleIdentifier{return ActualBundle;}
- (NSString *)bundlePath{return BundlePath;}
- (id)objectForInfoDictionaryKey:(NSString *)key{return [key isEqual:@"CFBundleVersion"]?Build:Version;}
@end
static NSString *Original(uintptr_t flavor){ProviderCalls++;LastFlavor=flavor;return Reply;}
static NSString *Target(uintptr_t flavor){ProviderCalls++;return nil;}
static void FixtureHook(void *symbol,void *replacement,void **original){HookCalls++;Check(symbol==(void *)Target&&replacement,@"only resolved producer is hooked");*original=HookSucceeds?(BadTrampoline?(void *)Target:(void *)Original):NULL;}
static void *FixtureDlsym(void *handle,const char *name){Check(handle==RTLD_DEFAULT&&!strcmp(name,"FBUserAgent"),@"exact exported producer resolved");return SymbolExists?(void *)Target:NULL;}
static int FixtureDladdr(const void *pointer,Dl_info *info){if(!AddressKnown)return 0;info->dli_fname=ImagePath.UTF8String;return 1;}
#define MSHookFunction FixtureHook
static BOOL RBXHookInstallationPassed(void){return HookSucceeds&&!BadTrampoline&&HookCalls==1;}
#define NSBundle FixtureBundle
#define dlsym FixtureDlsym
#define dladdr FixtureDladdr
#define RBXLogErr(...) ((void)++Warnings)
#define RBXLog(...) ((void)0)
__BODY__
#undef NSBundle
#undef dlsym
#undef dladdr
int main(int argc,char **argv){@autoreleasepool{
 NSString *mode=@(argv[1]);NSDictionary *descriptor=RBXAppDescriptorForType(@"facebook");ActualBundle=RBXAppBundleIdentifier(descriptor,@"fixture");BundlePath=@"/fixture/Facebook.app";ImagePath=[BundlePath stringByAppendingPathComponent:@"Frameworks/FBSharedFramework.framework/FBSharedFramework"];
 NSMutableDictionary *app=[@{@"bundleIdentifier":ActualBundle,@"keychainAccessGroup":RBXAppKeychainGroup(descriptor,ActualBundle),@"sourceVersion":Version,@"sourceBuild":Build} mutableCopy];[app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,ActualBundle)];
 NSMutableDictionary *raw=[@{@"containerId":@"fixture",@"appType":@"facebook",@"app":app,@"device":@{@"productType":@"iPhone17,1",@"iosVersion":@"18.0",@"buildVersion":@"22A3354",@"locale":@"en_US",@"screen":@{@"scale":@"3"}}} mutableCopy];
 RBXDeviceProfile *profile=[RBXDeviceProfile new];profile.rawProfile=raw;RBXContainerManager *m=RBXContainerManager.sharedManager;m.currentProfile=profile;m.containerId=@"fixture";m.validatedProfileLoaded=YES;
 if([mode isEqual:@"unvalidated"])m.validatedProfileLoaded=NO;
 if([mode isEqual:@"foreign-container"])m.containerId=@"sibling";
 if([mode isEqual:@"foreign-bundle"])ActualBundle=RBXAppBundleIdentifier(descriptor,@"sibling");
 if([mode isEqual:@"foreign-profile"]){m.currentProfile=[RBXDeviceProfile new];m.currentProfile.rawProfile=raw;}
 if([mode isEqual:@"groups"]) [app removeObjectForKey:@"keychainAccessGroups"];
 if([mode isEqual:@"reddit"])raw[@"appType"]=@"reddit";
 if([mode isEqual:@"source-version"])app[@"sourceVersion"]=@"unknown";
 if([mode isEqual:@"source-build"])app[@"sourceBuild"]=@"unknown";
 if([mode isEqual:@"runtime-version"])Version=@"unknown";
 if([mode isEqual:@"runtime-build"])Build=@"unknown";
 if([mode isEqual:@"bad-profile"])raw[@"device"]=@{};
 if([mode isEqual:@"no-symbol"])SymbolExists=NO;
 if([mode isEqual:@"no-image"])AddressKnown=NO;
 if([mode isEqual:@"foreign-image"])ImagePath=@"/fixture/Sibling.app/Frameworks/FBSharedFramework.framework/FBSharedFramework";
 if([mode isEqual:@"image-suffix"])ImagePath=[ImagePath stringByAppendingString:@".foreign"];
 if([mode isEqual:@"hook-failure"])HookSucceeds=NO;
 if([mode isEqual:@"bad-trampoline"])BadTrampoline=YES;
 BOOL expected=[mode isEqual:@"active"];
 Check(RBXInstallFacebookUserAgentHooks(profile)==expected,@"actual installer admits only supported validated app/bundle/image");
 Check(HookCalls==(expected||[mode isEqual:@"hook-failure"]||BadTrampoline?1:0),@"unsupported and foreign states install no hook");
 if([mode isEqual:@"hook-failure"]||BadTrampoline){Check(!RBXInstallFacebookUserAgentHooks(profile)&&HookCalls==1,@"failed installation is not layered or retried");Check(!fbua_userAgent(0)&&!ProviderCalls,@"unverified trampoline cannot invoke original producer");}
 if(expected){Check(RBXInstallFacebookUserAgentHooks(profile)&&HookCalls==1,@"same immutable profile does not install twice");
 Reply=@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_7_16 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/20H392 [FBAN/FBIOS;FBAV/578.1.0.71.72;FBBV/1063022819;FBDV/iPhone10,4;FBMD/iPhone;FBSN/iOS;FBSV/16.7.16;FBSS/2;FBLC/en_GB;FBID/phone;FBOP/5;]";
 for(NSNumber *v in @[@0,@1,@2,@(UINTPTR_MAX)]){NSString *rewritten=fbua_userAgent(v.unsignedLongLongValue);Check([rewritten containsString:@"CPU iPhone OS 18_0"]&&[rewritten containsString:@"FBDV/iPhone17,1;"],@"actual wrapper applies both prefix and block policy");Check(LastFlavor==v.unsignedLongLongValue,@"producer flavor bits forwarded without reinterpretation");}
 Check(ProviderCalls==4&&!Warnings,@"provider called once per wrapper call without spurious diagnostics");
 Reply=nil;Check(!fbua_userAgent(0)&&ProviderCalls==5,@"nil producer return preserved");Reply=@"unsupported-private-value";Check(!fbua_userAgent(1)&&Warnings==1,@"unsupported producer output cannot fall back to physical UA");Check(!fbua_userAgent(1)&&Warnings==1,@"unsupported output warning is bounded");
 NSMutableDictionary *changed=[raw mutableCopy];NSMutableDictionary *device=[changed[@"device"] mutableCopy];device[@"locale"]=@"sk_SK";changed[@"device"]=device;profile.rawProfile=changed;Check(!RBXInstallFacebookUserAgentHooks(profile)&&HookCalls==1,@"installed producer cannot switch profile identity in place");
 }
 printf("PASS: actual Facebook UA installer %s (%lu assertions)\n",argv[1],(unsigned long)Checks);return 0;}}
'''.replace('__BODY__',body)
with tempfile.TemporaryDirectory(prefix='socialbox-fb-ua-hooks-') as tmp:
 p=Path(tmp);shared=p/'shared';shutil.copytree(ROOT/'shared',shared);(p/'test.mm').write_text(fixture)
 cmd=['xcrun','clang++','-std=c++17','-fobjc-arc','-fblocks','-Wno-nullability-completeness','-I'+str(shared),'-framework','Foundation','-framework','Security',str(p/'test.mm'),'-o',str(p/'test')]
 subprocess.run(cmd,check=True);subprocess.run([str(p/'test'),'inactive'],check=True)
 data=(shared/'RBXAppRegistryData.h').read_text();assert data.count('@"runnable": @NO')==1;(shared/'RBXAppRegistryData.h').write_text(data.replace('@"runnable": @NO','@"runnable": @YES'))
 subprocess.run(cmd,check=True)
 for mode in ['active','unvalidated','foreign-container','foreign-bundle','foreign-profile','groups','reddit','source-version','source-build','runtime-version','runtime-build','bad-profile','no-symbol','no-image','foreign-image','image-suffix','hook-failure','bad-trampoline']:
  subprocess.run([str(p/'test'),mode],check=True)
