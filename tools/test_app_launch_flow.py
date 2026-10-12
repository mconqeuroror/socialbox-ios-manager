#!/usr/bin/env python3
"""Actual main launch sequence; synthetic app services, real all-app coordinator.

No process is launched or signalled and no network/production path is accessed.
The fixture permits the registered future Facebook descriptor only in the test
coordinator; production registry/admission stays unchanged.
"""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'daemon/main.m').read_text()
start=source.index('static void handleLaunchContainer(')
method=source[start:source.index('\n}\n',start)+3]
proc_decl=next(l for l in source.splitlines() if l.startswith('static ') and '*sProc;' in l)
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
#import "RBXContainerRegistry.h"
#import "RBXCloneManager.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXOperationContext.h"
#import "RBXNetworkGate.h"
#import "RBXCentralStore.h"
#import "RBXProxyManager.h"
#import "RBXReplacement.h"
#import "RBXLauncherState.h"
#import "RBXCloudSync.h"
#import "RBXLicenseGuard.h"
#import "__COORDINATOR__"
static NSMutableArray *Events;
static NSMutableDictionary *Doc;
static NSDictionary *Profile,*Receipt;
static NSString *Fail,*LeaseState,*ArmedBundle;
static NSUInteger Checks,Reads,Refreshes;
static BOOL ChangeOwner;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
static BOOL Step(NSString *name){[Events addObject:name];return ![Fail isEqual:name];}
@implementation RBXStorageAccess
+ (BOOL)closeAll:(NSError **)error{return Step(@"storage-close");}
+ (BOOL)openProfile:(NSDictionary *)profile authorized:(BOOL (^)(void))authorized error:(NSError **)error{return Step(@"storage-open")&&authorized&&authorized();}
@end
static BOOL Owner(NSDictionary *d,NSDictionary *p){return d && [d isEqual:RBXAppDescriptorForProfile(p)] && [p[@"app"][@"bundleIdentifier"] isEqual:RBXAppBundleIdentifier(d,p[@"containerId"])];}
static RBXContainerRegistry *sRegistry;
__PROC_DECL__
static RBXProxyManager *sProxies;
static void completeRequest(NSDictionary *pending,BOOL ok,NSString *message,NSDictionary *values){Check(!Receipt,@"one terminal result");Receipt=@{@"ok":@(ok),@"stage":values[@"stage"]?:@"",@"message":message?:@""};}
static void dispatchRequest(NSDictionary *pending,void (^block)(void)){block();}
static NSDictionary *waitForCloudOperation(void (^block)(void (^)(BOOL,NSString *))){__block id result;block(^(BOOL ok,NSString *message){result=@{@"ok":@(ok),@"message":message?:@""};});return result;}
static NSDictionary *waitForOperationReply(void (^block)(void (^)(NSDictionary *))){__block id result;block(^(NSDictionary *r){result=r;});return result;}
static NSString *RBXIsolationLaunchBlock(NSDictionary *doc,NSString *container){return [Fail isEqual:(Refreshes>1?@"late-alert":@"alert")]?@"fixture alert":nil;}
static BOOL RBXFreezeIdentityBeforeLaunch(id store,NSString *container,NSError **error){return Step(@"freeze");}
@implementation RBXOperationContext
+ (instancetype)currentContext{static id c;if(!c)c=[self new];return c;}
- (NSTimeInterval)remainingTime{return 0;}
- (NSTimeInterval)deadlineMonotonic{return NSProcessInfo.processInfo.systemUptime+30;}
- (BOOL)isCancelled{return NO;}
- (BOOL)check:(NSError **)error{return YES;}
@end
@implementation RBXContainerRegistry
- (NSDictionary *)validatedProfileForContainer:(NSString *)container error:(NSError **)error{Reads++;if(!Step(@"profile"))return nil;if(ChangeOwner && Reads>=3){NSDictionary *d=RBXAppDescriptorForType([Profile[@"appType"] isEqual:@"facebook"]?@"reddit":@"facebook");return @{@"containerId":container,@"appType":d[@"appType"],@"app":@{@"bundleIdentifier":RBXAppBundleIdentifier(d,container)},@"proxy":Profile[@"proxy"]};}return Profile;}
- (BOOL)ensureAppCloneForContainer:(NSString *)container error:(NSError **)error{return Step(@"provision");}
@end
@implementation RBXCloneManager
- (instancetype)init{return [self initWithAppType:@"reddit" operationContext:RBXOperationContext.currentContext];}
- (instancetype)initWithAppType:(NSString *)type operationContext:(RBXOperationContext *)context{Check(context==RBXOperationContext.currentContext,@"operation context propagated");self=[super init];if(self)_appDescriptor=RBXAppDescriptorForType(type);return self;}
- (BOOL)validateCloneForProfile:(NSDictionary *)p error:(NSError **)error{return Owner(self.appDescriptor,p)&&Step(@"validate");}
- (BOOL)verifyManagedInstallationForProfile:(NSDictionary *)p error:(NSError **)error{return Owner(self.appDescriptor,p)&&Step(@"mdm");}
- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundle{return RBXAppOwnsCloneBundleIdentifier(self.appDescriptor,bundle)?@"/fixture/data":nil;}
- (BOOL)syncProfile:(NSDictionary *)p error:(NSError **)error{return Owner(self.appDescriptor,p)&&Step([LeaseState isEqual:@"closed"]?@"sync-before":@"sync-after");}
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore{static id s;if(!s)s=[self new];return s;}
- (NSDictionary *)dictionary{return Doc;}
- (void)update:(void (^)(NSMutableDictionary *))block{block(Doc);}
@end
@implementation RBXReplacement
+ (BOOL)launchAllowedForContainer:(NSString *)container error:(NSError **)error{return Step(@"replacement");}
@end
@implementation RBXLauncherState
+ (BOOL)refreshBeforeLaunchWithRegistry:(id)registry{Refreshes++;return Step(Refreshes>1?@"late-refresh":@"refresh");}
+ (void)publishWithRegistry:(id)registry{}
@end
@implementation RBXLicenseGuard
+ (instancetype)sharedGuard{static id s;if(!s)s=[self new];return s;}
- (void)validateWithContext:(id)c completion:(void (^)(BOOL,NSString *))done{done(Step(@"license"),@"license fixture");}
@end
@implementation RBXCloudSync
+ (instancetype)sharedSync{static id s;if(!s)s=[self new];return s;}
- (void)syncRotationAuthForContainer:(NSString *)container context:(id)c completion:(void (^)(BOOL,NSString *))done{done(Step(@"auth"),@"auth fixture");}
@end
@implementation RBXProxyManager
- (void)rotateAndActivateProfile:(NSDictionary *)p previousExitIP:(NSString *)ip generation:(NSString *)g context:(id)c completion:(void (^)(BOOL,NSString *,NSString *))done{Check([LeaseState isEqual:@"closed"],@"proxy changes only after CLOSED");done(Step(@"rotate"),@"192.0.2.1",@"rotation fixture");}
@end
@implementation RBXNetworkGate
+ (NSString *)lastExitIP{return @"192.0.2.2";}
+ (NSString *)closeTrafficWithReason:(NSString *)reason{if(!Step(@"close"))return nil;LeaseState=@"closed";return @"closed-generation";}
+ (BOOL)waitForSystemFirewallState:(NSString *)state container:(NSString *)container generation:(NSString *)g timeout:(NSTimeInterval)t{return Step([state isEqual:@"closed"]?@"closed-ack":@"armed-ack");}
+ (BOOL)armTrafficForContainer:(NSString *)container bundleIdentifier:(NSString *)bundle proxyURL:(NSString *)proxy exitIP:(NSString *)ip generation:(NSString *)g error:(NSError **)error{Check([Events containsObject:@"freeze"],@"identity frozen before ARM");if(!Step(@"arm"))return NO;LeaseState=@"armed";ArmedBundle=bundle;return YES;}
+ (BOOL)openTrafficForContainer:(NSString *)container bundleIdentifier:(NSString *)bundle proxyURL:(NSString *)proxy exitIP:(NSString *)ip generation:(NSString *)g error:(NSError **)error{Check([Events containsObject:@"hook-ready"]&&[Events containsObject:@"late-refresh"],@"readiness and refresh before OPEN");if(!Step(@"open"))return NO;LeaseState=@"open";return YES;}
+ (BOOL)syncCurrentLeaseToProfile:(NSDictionary *)p error:(NSError **)error{return Step([LeaseState isEqual:@"open"]?@"open-control":@"control");}
+ (BOOL)syncFirewallStatusToProfile:(NSDictionary *)p error:(NSError **)error{return Step([LeaseState isEqual:@"open"]?@"open-status":@"status");}
+ (BOOL)waitForHookReadinessForProfile:(NSDictionary *)p expectedPID:(pid_t)pid generation:(NSString *)g timeout:(NSTimeInterval)t{Check(pid>1,@"readiness bound to actual selected PID");return Step(@"hook-ready");}
@end
@interface FakeProcess : RBXProcessController <RBXAppProcessControlling>
@property NSDictionary *identity;
@end
// Inert implementation satisfies the actual coordinator's default initializer
// linkage. Test construction uses exact canonical descriptors for both apps.
@implementation RBXProcessController
- (instancetype)initWithAppDescriptor:(NSDictionary *)d{self=[super init];if(self)_appDescriptor=d;return self;}
@end
@implementation FakeProcess
- (void)killAppProcesses{Check([LeaseState isEqual:@"closed"] || ([LeaseState isEqual:@"armed"] && [Events containsObject:@"launch"]),@"stop occurs under CLOSED or failed-launch ARMED denial");Step([@"kill:" stringByAppendingString:self.appDescriptor[@"appType"]]);}
- (BOOL)killAllAndWait:(NSTimeInterval)t{return Step([@"drain:" stringByAppendingString:self.appDescriptor[@"appType"]]);}
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)i deadline:(NSTimeInterval)d error:(NSError **)e{return Step([@"sockets:" stringByAppendingString:self.appDescriptor[@"appType"]]);}
- (BOOL)launchCloneForProfile:(NSDictionary *)p error:(NSError **)e{Check([LeaseState isEqual:@"armed"]&&[ArmedBundle isEqual:p[@"app"][@"bundleIdentifier"]],@"selected app launched only under its own ARMED identity");if(!Step(@"launch"))return NO;self.identity=@{@"containerId":p[@"containerId"],@"bundleIdentifier":p[@"app"][@"bundleIdentifier"],@"executable":@"/fixture/Main",@"pid":@123,@"generation":@"fixture-generation",@"bootEpoch":@"fixture-boot",@"processStartSeconds":@1000,@"processStartMicroseconds":@123};return YES;}
- (NSDictionary *)activeCloneIdentity{return self.identity;}
- (pid_t)activeClonePID{return [self.identity[@"pid"] intValue];}
- (NSUInteger)terminationObservationInFlight{return 0;}
- (BOOL)isProfileStopped:(NSDictionary *)p error:(NSError **)e{return YES;}
- (void)stopWatchingAppTermination{}
- (void)watchAppTerminationOnQueue:(dispatch_queue_t)q onExit:(void (^)(NSDictionary *,NSString *))b{}
@end
__METHOD__
static void Setup(NSString *app){Events=[NSMutableArray array];Receipt=nil;Reads=Refreshes=0;LeaseState=@"closed";ArmedBundle=nil;NSString *cid=@"launch-fixture";NSDictionary *d=RBXAppDescriptorForType(app);Profile=@{@"appType":app,@"containerId":cid,@"app":@{@"bundleIdentifier":RBXAppBundleIdentifier(d,cid)},@"proxy":@{@"url":@"http://127.0.0.1:9999"}};Doc=[@{@"containers":[@{cid:[NSMutableDictionary dictionary]} mutableCopy]} mutableCopy];NSMutableArray *controllers=[NSMutableArray array];for(NSDictionary *a in RBXRegisteredAppDescriptors())[controllers addObject:[[FakeProcess alloc] initWithAppDescriptor:a]];sProc=(id)[[RBXAppProcessCoordinator alloc] initWithControllers:controllers runnableAppTypes:[NSSet setWithArray:@[@"reddit",@"facebook"]] monotonicClock:^NSTimeInterval{return NSProcessInfo.processInfo.systemUptime;}];[(id)sProc watchAppTerminationOnQueue:dispatch_get_main_queue() onExit:^(NSDictionary *i,NSString *r){}];sRegistry=[RBXContainerRegistry new];sProxies=[RBXProxyManager new];}
int main(){@autoreleasepool{
for(NSString *app in @[@"reddit",@"facebook"]){Fail=nil;ChangeOwner=NO;Setup(app);handleLaunchContainer(@{@"action":@"launchContainer",@"container":@"launch-fixture",@"appType":app});Check([Receipt[@"ok"] boolValue]&&[LeaseState isEqual:@"open"],@"both app flows reach OPEN through selected manager and global coordinator");Check([Events indexOfObject:@"drain:reddit"]<[Events indexOfObject:@"rotate"]&&[Events indexOfObject:@"drain:facebook"]<[Events indexOfObject:@"rotate"],@"both process families drain before rotation");
for(NSString *failure in @[@"storage-close",@"storage-open",@"replacement",@"refresh",@"alert",@"close",@"drain:reddit",@"drain:facebook",@"closed-ack",@"license",@"auth",@"profile",@"provision",@"validate",@"mdm",@"rotate",@"sync-before",@"sockets:reddit",@"sockets:facebook",@"freeze",@"arm",@"armed-ack",@"launch",@"sync-after",@"control",@"status",@"hook-ready",@"late-refresh",@"late-alert",@"open",@"open-control",@"open-status"]){Fail=failure;Setup(app);handleLaunchContainer(@{@"action":@"launchContainer",@"container":@"launch-fixture",@"appType":app});Check(![Receipt[@"ok"] boolValue],[@"failure must deny OPEN: " stringByAppendingString:failure]);Check(![LeaseState isEqual:@"open"],@"failed flow retains/reestablishes CLOSED");}
Fail=nil;ChangeOwner=YES;Setup(app);handleLaunchContainer(@{@"action":@"launchContainer",@"container":@"launch-fixture",@"appType":app});Check(![Receipt[@"ok"] boolValue]&&![Events containsObject:@"arm"],@"changed app ownership after rotation rejected before ARM");}
printf("PASS: %lu actual main multi-app launch/coordinator assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__COORDINATOR__',str(ROOT/'daemon/RBXAppProcessCoordinator.m')).replace('__METHOD__',method).replace('__PROC_DECL__',proc_decl)
with tempfile.TemporaryDirectory(prefix='socialbox-launch-flow-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-DRBX_APP_PROCESS_COORDINATOR_TESTING=1','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation','-framework','Security',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
