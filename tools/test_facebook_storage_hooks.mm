#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "RBXFacebookStoragePolicy.h"
#import "RBXFacebookPrivateGroupStore.h"
#import "RBXAppRuntime.h"
static NSString *ActualBundle,*Version=@"578.1.0",*Build=@"1063022819";
static unsigned Checks,FunctionHooks,MessageHooks;
static BOOL HookSucceeds=YES;
static void Check(BOOL ok,NSString *why){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(1);}}
@interface FixtureProfile : NSObject
@property NSDictionary *rawProfile;
@end
@implementation FixtureProfile @end
@interface RBXContainerManager : NSObject
@property FixtureProfile *currentProfile;
@property NSString *containerId;
@property BOOL validatedProfileLoaded;
@end
@implementation RBXContainerManager @end
@interface FixtureBundle : NSObject
+ (instancetype)mainBundle;
- (NSString *)bundleIdentifier;
- (id)objectForInfoDictionaryKey:(NSString *)key;
@end
@implementation FixtureBundle
+ (instancetype)mainBundle{return [self new];}
- (NSString *)bundleIdentifier{return ActualBundle;}
- (id)objectForInfoDictionaryKey:(NSString *)key{return [key isEqual:@"CFBundleVersion"]?Build:Version;}
@end
static void MSHookFunction(void *target,void *replacement,void **original){FunctionHooks++;Check(target&&replacement&&original,@"valid C hook registration");*original=HookSucceeds?target:NULL;}
static void MSHookMessageEx(Class target,SEL selector,IMP replacement,IMP *original){MessageHooks++;Method m=class_getInstanceMethod(target,selector);Check(m&&replacement&&original,@"Foundation selector exists");*original=method_getImplementation(m);method_setImplementation(m,replacement);}
static BOOL RBXHookInstallationPassed(void){return HookSucceeds&&FunctionHooks==14&&MessageHooks==10;}
#define NSBundle FixtureBundle
#define RBXLog(...) ((void)0)
// ACTUAL_GENERATED_HOOKS
#undef NSBundle
#define CF(x) ((__bridge CFStringRef)(x))
static id Copied(CFTypeRef value){return CFBridgingRelease(value);}
static CFStringRef LastApp,LastSuite;
static unsigned SuiteCalls;
static void SuiteSpy(CFStringRef app,CFStringRef suite){LastApp=app;LastSuite=suite;SuiteCalls++;}
// Snapshot strings in observers rather than keeping borrowed pointers alive.
static NSString *ObservedApp,*ObservedSuite;
static void SuiteObserver(CFStringRef app,CFStringRef suite){SuiteSpy(app,suite);ObservedApp=[(__bridge NSString *)app copy];ObservedSuite=[(__bridge NSString *)suite copy];}
int main(int argc,char **argv){@autoreleasepool{
 Check(argc==2,@"fixture mode supplied");NSString *mode=@(argv[1]);
 NSString *cid=[@"storage-native-" stringByAppendingString:NSUUID.UUID.UUIDString];
 NSDictionary *descriptor=RBXAppDescriptorForType(@"facebook");ActualBundle=RBXAppBundleIdentifier(descriptor,cid);
 NSString *foreign=RBXAppBundleIdentifier(descriptor,[cid stringByAppendingString:@"-B"]);
 NSMutableDictionary *app=[@{@"bundleIdentifier":ActualBundle,@"keychainAccessGroup":RBXAppKeychainGroup(descriptor,ActualBundle),@"sourceVersion":Version,@"sourceBuild":Build} mutableCopy];[app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor,ActualBundle)];
 NSMutableDictionary *raw=[@{@"containerId":cid,@"appType":@"facebook",@"app":app} mutableCopy];
 RBXContainerManager *m=[RBXContainerManager new];m.currentProfile=[FixtureProfile new];m.currentProfile.rawProfile=raw;m.containerId=cid;m.validatedProfileLoaded=YES;
 if([mode isEqual:@"unvalidated"])m.validatedProfileLoaded=NO;
 if([mode isEqual:@"foreign-container"])m.containerId=@"sibling";
 if([mode isEqual:@"foreign-bundle"])ActualBundle=foreign;
 if([mode isEqual:@"original"])ActualBundle=@"com.facebook.Facebook";
 if([mode isEqual:@"groups"])[app removeObjectForKey:@"keychainAccessGroups"];
 if([mode isEqual:@"reddit"])raw[@"appType"]=@"reddit";
 if([mode isEqual:@"source-version"])app[@"sourceVersion"]=@"unknown";
 if([mode isEqual:@"source-build"])app[@"sourceBuild"]=@"unknown";
 if([mode isEqual:@"runtime-version"])Version=@"unknown";
 if([mode isEqual:@"runtime-build"])Build=@"unknown";
 if([mode isEqual:@"hook-failure"])HookSucceeds=NO;
 BOOL active=[mode isEqual:@"active"],attempt=active||!HookSucceeds;
 Check(RBXInstallFacebookStorageHooks(m)==active,@"installer verifies exact clone, profile, source and active registry");
 Check(FunctionHooks==(attempt?14:0)&&MessageHooks==(attempt?10:0),@"unsupported profile installs nothing");
 if(!active){Check(!RBXInstallFacebookStorageHooks(m),@"invalid/failed installation cannot report ready on retry");Check(!fbstore_CopyAppValue(CFSTR("canary"),CFSTR("group.com.facebook.family")),@"disabled wrapper withholds storage");printf("PASS FB storage installer %s: %u assertions\n",argv[1],Checks);return 0;}
 Check(RBXInstallFacebookStorageHooks(m)&&FunctionHooks==14,@"idempotent immutable installation");
 NSData *opaque=[NSData dataWithBytes:"\0\xff\x01\x7f" length:4];
 NSDictionary *payload=@{@"bytes":opaque,@"string":@"synthetic-token-not-a-uuid",@"number":@42,@"array":@[@1,@"two"],@"date":[NSDate dateWithTimeIntervalSince1970:12345]};
 NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:nil];Check(defaults!=nil,@"standard defaults initializer remains native");
 for(NSString *source in RBXFacebookSharedStorageDomains()) {
  NSString *own=fbstore_domain(source,YES);CFStringRef src=CF(source);NSString *key=[@"canary-" stringByAppendingString:source];
  fbstore_SetAppValue(CF(key),(__bridge CFPropertyListRef)payload,src);
  Check(fbstore_AppSynchronize(src),@"mapped domain synchronizes");
  Check([Copied(fbstore_CopyAppValue(CF(key),src)) isEqual:payload],@"CF copy preserves nested types and exact opaque bytes");
  Check([Copied(CFPreferencesCopyAppValue(CF(key),CF(own))) isEqual:payload],@"native provider received own mapped domain");
  Check(!Copied(CFPreferencesCopyAppValue(CF(key),src)),@"original source group remains untouched");
  fbstore_SetAppValue(CFSTR("boolean"),kCFBooleanTrue,src);Boolean valid=false;
  Check(fbstore_GetAppBooleanValue(CFSTR("boolean"),src,&valid)&&valid,@"boolean validity preserved");
  fbstore_SetAppValue(CFSTR("integer"),(__bridge CFNumberRef)@73,src);
  Check(fbstore_GetAppIntegerValue(CFSTR("integer"),src,&valid)==73&&valid,@"integer semantics preserved");
  fbstore_SetValue(CFSTR("direct"),(__bridge CFPropertyListRef)payload,src,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
  Check([Copied(fbstore_CopyValue(CFSTR("direct"),src,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)) isEqual:payload],@"explicit owner/host value roundtrip");
  fbstore_SetMultiple((__bridge CFDictionaryRef)@{@"multi":opaque},(__bridge CFArrayRef)@[@"direct"],src,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
  Check([Copied(fbstore_CopyMultiple((__bridge CFArrayRef)@[@"multi",@"direct"],src,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)) isEqual:@{@"multi":opaque}],@"bulk writes and removals preserve values");
  Check([Copied(fbstore_CopyKeyList(src,kCFPreferencesCurrentUser,kCFPreferencesAnyHost)) containsObject:@"multi"],@"key list uses mapped domain");
  Check(fbstore_Synchronize(src,kCFPreferencesCurrentUser,kCFPreferencesAnyHost),@"explicit sync mapped");
  Check(!fbstore_AppValueIsForced(CFSTR("multi"),src),@"native nonmanaged forced flag");
  NSUserDefaults *suite=[[NSUserDefaults alloc] initWithSuiteName:source];Check(suite!=nil,@"native suite object returned");
  [suite setObject:payload forKey:@"native"];
  Check([[suite objectForKey:@"native"] isEqual:payload],@"native typed Foundation suite roundtrip");
  Check([[defaults persistentDomainForName:source][@"native"] isEqual:payload],@"persistent domain reads same private suite");
  [defaults addSuiteNamed:source];Check([[defaults objectForKey:@"native"] isEqual:payload],@"suite search list sees own private values");
  [defaults removeSuiteNamed:source];Check(![defaults objectForKey:@"native"],@"suite removal semantics preserved");
  [defaults setPersistentDomain:@{@"replace":opaque} forName:source];Check([[defaults persistentDomainForName:source] isEqual:@{@"replace":opaque}],@"whole domain replacement");
  [defaults removePersistentDomainForName:source];Check(![defaults persistentDomainForName:source].count,@"whole domain removal");
  [defaults setVolatileDomain:@{@"volatile":payload} forName:source];Check([[defaults volatileDomainForName:source] isEqual:@{@"volatile":payload}],@"volatile search domains retain data types");
  [defaults removeVolatileDomainForName:source];Check(![defaults volatileDomainForName:source].count,@"volatile removal");
 }
 Check(![[NSUserDefaults alloc] initWithSuiteName:@"com.apple.UIKit"],@"platform read domains cannot become writable suite objects");
 // Canary belongs to B; A must never receive it, even though this unsandboxed
 // fixture's raw OS provider can read it. This tests wrappers, not OS sandboxing.
 CFPreferencesSetAppValue(CFSTR("foreign-canary"),CFSTR("B-only"),CF(foreign));CFPreferencesAppSynchronize(CF(foreign));
 Check([Copied(CFPreferencesCopyAppValue(CFSTR("foreign-canary"),CF(foreign))) isEqual:@"B-only"],@"negative probe targets real foreign data");
 for(NSString *denied in @[foreign,@"group.com.facebook.unknown",@"group.com.facebook.family.evil"]){
  CFStringRef dom=CF(denied);Boolean valid=true;
  Check(!fbstore_CopyAppValue(CFSTR("foreign-canary"),dom),@"foreign app value denied");
  Check(!fbstore_CopyValue(CFSTR("foreign-canary"),dom,kCFPreferencesCurrentUser,kCFPreferencesAnyHost),@"foreign explicit value denied");
  Check(!fbstore_CopyMultiple(NULL,dom,kCFPreferencesCurrentUser,kCFPreferencesAnyHost),@"foreign bulk read denied");
  Check(!fbstore_CopyKeyList(dom,kCFPreferencesCurrentUser,kCFPreferencesAnyHost),@"foreign key enumeration denied");
  Check(!fbstore_GetAppBooleanValue(CFSTR("x"),dom,&valid)&&!valid,@"denied boolean invalidates output");valid=true;
  Check(!fbstore_GetAppIntegerValue(CFSTR("x"),dom,&valid)&&!valid,@"denied integer invalidates output");
  Check(!fbstore_AppSynchronize(dom)&&!fbstore_Synchronize(dom,kCFPreferencesCurrentUser,kCFPreferencesAnyHost),@"denied domain cannot synchronize");
  fbstore_SetAppValue(CFSTR("foreign-canary"),CFSTR("overwrite"),dom);fbstore_SetValue(CFSTR("foreign-canary"),CFSTR("overwrite"),dom,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
  fbstore_SetMultiple((__bridge CFDictionaryRef)@{@"foreign-canary":@"overwrite"},NULL,dom,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
  Check(![[NSUserDefaults alloc] initWithSuiteName:denied],@"foreign suite cannot be initialized");
  Check(![defaults persistentDomainForName:denied],@"foreign persistent domain withheld");
  [defaults setPersistentDomain:@{@"foreign-canary":@"overwrite"} forName:denied];[defaults removePersistentDomainForName:denied];
  [defaults addSuiteNamed:denied];Check(![defaults objectForKey:@"foreign-canary"],@"foreign suite cannot enter search list");[defaults removeSuiteNamed:denied];
  [defaults setVolatileDomain:@{@"foreign-canary":@"overwrite"} forName:denied];Check(![defaults volatileDomainForName:denied].count,@"foreign volatile domain withheld");[defaults removeVolatileDomainForName:denied];
 }
 Check([Copied(CFPreferencesCopyAppValue(CFSTR("foreign-canary"),CF(foreign))) isEqual:@"B-only"],@"foreign canary unchanged after denied mutations");
 Check(!fbstore_CopyValue(CFSTR("x"),CFSTR("group.com.facebook.family"),kCFPreferencesAnyUser,kCFPreferencesAnyHost),@"AnyUser cannot escape owner boundary");
 Check(!fbstore_cfDomain(CFSTR("com.apple.UIKit"),YES)&&fbstore_cfDomain(CFSTR("com.apple.UIKit"),NO),@"platform settings are read only native data");
 Check(!fbstore_cfDomain(kCFPreferencesAnyApplication,YES)&&fbstore_cfDomain(kCFPreferencesAnyApplication,NO),@"global preferences cannot be persisted by adapter");
 Check([fbstore_cfDomain(kCFPreferencesCurrentApplication,YES) isEqual:ActualBundle],@"current application maps to clone");
 Check(!fbstore_CopyAppValue(CFSTR("x"),NULL),@"null domain denied");
 fbstore_orig_AddSuitePreferencesToApp=SuiteObserver;fbstore_orig_RemoveSuitePreferencesFromApp=SuiteObserver;
 NSString *expected=fbstore_domain(@"group.com.facebook.family",NO);
 fbstore_AddSuitePreferencesToApp(kCFPreferencesCurrentApplication,CFSTR("group.com.facebook.family"));
 Check(SuiteCalls==1&&[ObservedApp isEqual:ActualBundle]&&[ObservedSuite isEqual:expected],@"C addSuite maps both domains");
 fbstore_RemoveSuitePreferencesFromApp(kCFPreferencesCurrentApplication,CFSTR("group.com.facebook.family"));Check(SuiteCalls==2,@"C removeSuite maps both domains");
 fbstore_AddSuitePreferencesToApp(kCFPreferencesCurrentApplication,CF(foreign));fbstore_RemoveSuitePreferencesFromApp(CF(foreign),CFSTR("group.com.facebook.family"));Check(SuiteCalls==2,@"foreign parent/child never reaches original suite function");
 CFPreferencesSetAppValue(CFSTR("foreign-canary"),NULL,CF(foreign));CFPreferencesAppSynchronize(CF(foreign));
 for(NSString *source in RBXFacebookSharedStorageDomains()){NSString *own=fbstore_domain(source,YES);CFPreferencesSetMultiple(NULL,(__bridge CFArrayRef)Copied(CFPreferencesCopyKeyList(CF(own),kCFPreferencesCurrentUser,kCFPreferencesAnyHost)),CF(own),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);CFPreferencesAppSynchronize(CF(own));}
 m.containerId=@"different";Check(!RBXInstallFacebookStorageHooks(m)&&FunctionHooks==14,@"installed storage cannot be rebound to different container");
 printf("PASS actual Facebook native storage adapters: %u assertions\n",Checks);return 0;
}}
