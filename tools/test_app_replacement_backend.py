#!/usr/bin/env python3
"""Actual replacement engine/backend with real journal store and inert services."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];source=(ROOT/'daemon/RBXReplacement.m').read_text()
def code(sig):
 i=source.index(sig);return source[i:source.index('\n}\n',i)+3]
start=source.index('@interface RBXDeviceReplacementBackend');end=source.index('\n@end',source.index('@implementation RBXDeviceReplacementBackend'))+5
backend=source[start:end]
helpers='\n'.join(code(sig) for sig in ['static NSDictionary *RBXReplacementStore(', 'static NSDictionary *RBXReplacementJournals(', 'static NSDictionary *RBXReplacementWait('])
fixture=r'''
#import <Foundation/Foundation.h>
#define RBX_REPLACEMENT_TESTING 1
#import "__SOURCE__"
#import "RBXContainerRegistry.h"
#import "RBXProxyManager.h"
#import "RBXCloudSync.h"
#import "RBXOperationContext.h"
#import "RBXCentralStore.h"
#import "RBXProfileIO.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXNetworkGate.h"
#import "RBXProfileMetadata.h"
#import <sys/stat.h>
#import <errno.h>
static NSString *StorePath,*LeasePath,*Fail,*FailPhase;
static NSMutableDictionary *Store,*Profiles,*Deletions;
static NSMutableArray *Events;
static BOOL Allowed=YES;
static NSUInteger Checks,Creates;
static RBXOperationContext *Context;
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static BOOL Step(NSString *s){[Events addObject:s];return ![Fail isEqual:s];}
static BOOL Save(void){return [[NSJSONSerialization dataWithJSONObject:Store options:0 error:nil] writeToFile:StorePath atomically:YES];}
static NSMutableDictionary *Profile(NSString *app,NSString *cid){NSDictionary *d=RBXAppDescriptorForType(app);return [@{@"containerId":cid,@"appType":app,@"app":RBXAppDeletionTargetIdentity(d,cid),@"proxy":@{@"country":@"US",@"url":@"http://127.0.0.1:9999"},@"metadata":@{@"role":@"default"}} mutableCopy];}
@implementation RBXOperationContext
+ (instancetype)currentContext{return Context;}
- (BOOL)check:(NSError **)e{return Allowed;}
- (NSTimeInterval)remainingTime{return 1.0;}
- (NSString *)registerCancellationHandler:(void (^)(void))b{return @"fixture-cancel";}
- (void)unregisterCancellationHandler:(NSString *)s{}
- (void)cancelWithReason:(NSString *)r{Allowed=NO;}
@end
@implementation RBXProfileIO
+ (NSDictionary *)readJSONDictionaryAtPath:(NSString *)p error:(NSError **)e{NSData *b=[NSData dataWithContentsOfFile:p options:0 error:e];return b?[NSJSONSerialization JSONObjectWithData:b options:NSJSONReadingMutableContainers error:e]:nil;}
@end
@implementation RBXCentralStore
+ (NSString *)storePath{return StorePath;}
+ (instancetype)sharedStore{static id s;if(!s)s=[self new];return s;}
- (BOOL)update:(void (^)(NSMutableDictionary *))block error:(NSError **)error{
 NSMutableDictionary *next=[NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:Store options:0 error:nil] options:NSJSONReadingMutableContainers error:nil];block(next);NSString *phase=next[@"replacements"][@"old-id"][@"phase"];
 if(FailPhase && [phase isEqual:FailPhase])return NO;Store=next;return Save();
}
@end
@implementation RBXContainerRegistry
- (NSDictionary *)validatedProfileForContainer:(NSString *)cid error:(NSError **)e{return Profiles[cid];}
- (NSArray *)containerIdsWithError:(NSError **)e{return Profiles.allKeys;}
- (NSDictionary *)deletionStateForContainer:(NSString *)cid{return Deletions[cid];}
- (NSDictionary *)deletionIdentityForContainer:(NSString *)cid error:(NSError **)e{NSDictionary *d=RBXAppDeletionJournalDescriptor(Deletions[cid]);return d?RBXAppDeletionTargetIdentity(d,cid):nil;}
- (BOOL)reserveIdentityForProfile:(NSDictionary *)p error:(NSError **)e{return Step(@"reserve");}
- (BOOL)ensureAppCloneForContainer:(NSString *)cid error:(NSError **)e{return Step(@"ensure");}
- (NSString *)createContainerWithId:(NSString *)cid proxyCountry:(NSString *)country proxyURL:(NSString *)proxy nickname:(NSString *)name error:(NSError **)e{return [self createContainerWithId:cid appType:@"reddit" proxyCountry:country proxyURL:proxy nickname:name error:e];}
- (NSString *)createContainerWithId:(NSString *)cid appType:(NSString *)app proxyCountry:(NSString *)country proxyURL:(NSString *)proxy nickname:(NSString *)name error:(NSError **)e{Creates++;Profiles[cid]=Profile(app,cid);Store[@"containers"][cid]=[@{@"appType":app} mutableCopy];Check(Save(),@"candidate store fixture written");return Step(@"create")?cid:nil;}
- (BOOL)updateMetadata:(NSDictionary *)m forContainer:(NSString *)cid local:(BOOL)local error:(NSError **)e{return Step(@"metadata");}
- (BOOL)syncProfileToCloneForContainer:(NSString *)cid error:(NSError **)e{return Step(@"sync");}
- (BOOL)deleteContainer:(NSString *)cid error:(NSError **)e{if(!Step(@"delete"))return NO;if(Profiles[cid]){NSDictionary *d=RBXAppDescriptorForProfile(Profiles[cid]);NSMutableDictionary *j=[RBXAppDeletionJournalIdentity(RBXAppDeletionTargetIdentity(d,cid)) mutableCopy];j[@"phase"]=@"committed";Deletions[cid]=j;[Profiles removeObjectForKey:cid];}return YES;}
@end
@implementation RBXProcessController
- (instancetype)init{return [self initWithAppDescriptor:RBXRedditAppDescriptor()];}
- (instancetype)initWithAppDescriptor:(NSDictionary *)d{self=[super init];if(self)_appDescriptor=d;return self;}
- (BOOL)isProfileStopped:(NSDictionary *)p error:(NSError **)e{return [self.appDescriptor isEqual:RBXAppDescriptorForProfile(p)]&&Step(@"stop");}
- (BOOL)killAllAndWait:(NSTimeInterval)t{return Step(@"drain:reddit");}
@end
@implementation RBXAppProcessCoordinator
- (BOOL)killAllAndWait:(NSTimeInterval)t{return Step(@"drain:all");}
@end
@implementation RBXNetworkGate
+ (NSString *)leasePath{return LeasePath;}
+ (NSString *)lastExitIP{return @"192.0.2.1";}
+ (NSString *)closeTrafficWithReason:(NSString *)reason error:(NSError **)e{return Step(@"close")?@"fixture-generation":nil;}
+ (BOOL)waitForMaintenanceClosure:(NSString *)g timeout:(NSTimeInterval)t{return Step(@"ack");}
@end
@implementation RBXCloudSync
+ (instancetype)sharedSync{static id s;if(!s)s=[self new];return s;}
- (BOOL)paired{return NO;}
- (void)syncProfileInventoryWithContext:(id)c completion:(void (^)(BOOL,NSString *))done{done(YES,@"fixture");}
- (void)syncRotationAuthForContainer:(NSString *)cid context:(id)c completion:(void (^)(BOOL,NSString *))done{done(Step(@"auth"),@"fixture");}
@end
@implementation RBXProxyManager
- (void)rotateAndActivateProfile:(NSDictionary *)p previousExitIP:(NSString *)old generation:(NSString *)g context:(id)c completion:(void (^)(BOOL,NSString *,NSString *))done{done(Step(@"rotate"),@"192.0.2.2",@"fixture");}
@end
__HELPERS__
__BACKEND__
static void Reset(NSString *app){Store=[@{@"containers":[@{@"old-id":[@{@"appType":app,@"nickname":@"Existing name",@"lastIP":@"192.0.2.1"} mutableCopy]} mutableCopy],@"replacements":[NSMutableDictionary dictionary]} mutableCopy];Profiles=[@{@"old-id":Profile(app,@"old-id")} mutableCopy];Deletions=[NSMutableDictionary dictionary];Events=[NSMutableArray array];Creates=0;Fail=FailPhase=nil;Allowed=YES;Check(Save(),@"private initial store written");Check([@{@"state":@"closed"} writeToFile:LeasePath atomically:YES],@"closed fixture lease written");}
static RBXDeviceReplacementBackend *Backend(void){RBXDeviceReplacementBackend *b=[RBXDeviceReplacementBackend new];b.registry=[RBXContainerRegistry new];b.proxies=[RBXProxyManager new];b.context=Context;return b;}
static NSString *Run(void){NSError *error=nil;return RBXRunReplacement(@"old-id",Backend(),&error);}
int main(int argc,char **argv){@autoreleasepool{StorePath=@(argv[1]);LeasePath=@(argv[2]);Context=[RBXOperationContext new];
for(NSString *app in @[@"reddit",@"facebook"]){
 Reset(app);NSString *cid=Run();Check(cid&&[Profiles[cid][@"appType"] isEqual:app]&&!Profiles[@"old-id"],@"actual backend replaces each app with its own app type");Check([Events containsObject:@"drain:all"],@"replacement closes every runnable app family");Check([Store[@"containers"][cid][@"requiresLoginVerification"] boolValue]&&[Store[@"containers"][cid][@"username"] isEqual:@""],@"new identity never inherits a claimed authenticated session");
 for(NSString *point in @[@"stop",@"reserve",@"close",@"drain:all",@"ack",@"create",@"metadata",@"auth",@"rotate",@"sync",@"delete"]){Reset(app);Fail=point;Check(!Run(),@"injected service failure prevents successful replacement");NSString *candidate=Store[@"replacements"][@"old-id"][@"newId"];Check(Profiles[@"old-id"]!=nil,@"original retained until successful candidate and deletion");Fail=nil;NSString *retried=Run();Check(retried&&(!candidate||[retried isEqual:candidate]),@"retry keeps durable candidate identity");Check(Creates==1&&[Profiles[retried][@"appType"] isEqual:app],@"retry creates exactly one candidate in selected app");}
 for(NSString *phase in @[@"prepared",@"created",@"rotated",@"deleting",@"committed"]){Reset(app);FailPhase=phase;Check(!Run(),@"checkpoint failure prevents success");NSString *candidate=Store[@"replacements"][@"old-id"][@"newId"];FailPhase=nil;NSString *retried=Run();Check(retried&&(!candidate||[retried isEqual:candidate])&&Creates==1,@"checkpoint retry preserves candidate and app ownership");}
 Reset(app);Fail=@"rotate";Check(!Run(),@"retained created candidate fixture");Fail=nil;NSDictionary *journal=Store[@"replacements"][@"old-id"];NSString *candidate=journal[@"newId"];NSString *other=[app isEqual:@"reddit"]?@"facebook":@"reddit";Profiles[candidate]=Profile(other,candidate);[Events removeAllObjects];Check(![Backend() createCandidateForJournal:journal error:nil]&&!Events.count,@"retry cannot provision another app under the candidate ID");Check(![Backend() rotateCandidateForJournal:journal error:nil]&&!Events.count,@"foreign candidate rejected before auth or proxy calls");Check(![Backend() validateCandidateForJournal:journal error:nil],@"foreign candidate cannot reach deletion phase");
 Reset(app);Fail=@"delete";Check(!Run(),@"retained deleting-phase fixture");Fail=nil;journal=Store[@"replacements"][@"old-id"];Profiles[@"old-id"]=Profile(other,@"old-id");[Events removeAllObjects];Check(![Backend() deleteOriginalForJournal:journal error:nil]&&!Events.count,@"another app's new original profile cannot be deleted on retry");
 Reset(app);Fail=@"rotate";Check(!Run(),@"journal mutation fixture");Fail=nil;NSMutableDictionary *bad=[Store[@"replacements"][@"old-id"] mutableCopy];bad[@"newId"]=@"substituted-id";NSData *before=[NSData dataWithContentsOfFile:StorePath];Check(![Backend() persistJournal:bad error:nil]&&[[NSData dataWithContentsOfFile:StorePath] isEqual:before],@"published checkpoint cannot replace the immutable candidate identity");
}
printf("PASS: %lu actual per-app replacement backend assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__SOURCE__',str(ROOT/'daemon/RBXReplacement.m')).replace('__HELPERS__',helpers).replace('__BACKEND__',backend)
with tempfile.TemporaryDirectory(prefix='socialbox-replacement-backend-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation','-framework','Security',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'store.json'),str(p/'lease.plist')],check=True)
