#!/usr/bin/env python3
"""Actual global recovery dispatcher, real transaction files/lock, inert services."""
from pathlib import Path
import subprocess,tempfile,shutil
ROOT=Path(__file__).resolve().parents[1];source=(ROOT/'daemon/RBXCloneManager.m').read_text();start=source.index('+ (BOOL)recoverAllInterruptedTransactionsWithContext:');method=source[start:source.index('\n}\n',start)+3]
registry=(ROOT/'daemon/RBXContainerRegistry.m').read_text();begin=registry.index('- (BOOL)migrateAppClonesWithError:');migration=registry[begin:registry.index('\n}\n',begin)+3]
fixture=r'''
#import <Foundation/Foundation.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import "RBXAppLifecycle.h"
#import "RBXCloneManager.h"
#import "RBXContainerRegistry.h"
#import "RBXOperationContext.h"
#import "RBXStorageAccess.h"
static BOOL StorageOK=YES;
@implementation RBXStorageAccess
+ (BOOL)closeAll:(NSError **)error{return StorageOK;}
@end
static NSString *RBXTransactionsRoot,*FailApp;
static NSMutableArray *Events,*Migrated;
static BOOL MigrationPending;
static id Current;
static BOOL RBXRegistryCheckOperation(BOOL mutation,NSError **error){return Current!=nil;}
static BOOL Allowed=YES,BeginAllowed=YES,Inspect=NO,LockAllowed=YES,Throw;
static NSUInteger Checks,Begins,Ends,Locks;
static int LastFD=-1;
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static NSError *RBXCloneError(NSInteger n,NSString *s){return [NSError errorWithDomain:@"fixture" code:n userInfo:@{NSLocalizedDescriptionKey:s}];}
static int RBXLockTransactions(NSError **e){Locks++;if(!LockAllowed)return -1;LastFD=open([[RBXTransactionsRoot stringByAppendingPathComponent:@".lock"] fileSystemRepresentation],O_RDWR|O_CREAT,0600);Check(LastFD>=0&&flock(LastFD,LOCK_EX|LOCK_NB)==0,@"real fixture transaction lock held");return LastFD;}
static NSDictionary *RBXReadOwnedPlist(NSString *path,NSError **e){return [NSDictionary dictionaryWithContentsOfFile:path];}
@implementation RBXOperationContext
+ (instancetype)currentContext{return Current;}
- (BOOL)inspectionOnly{return Inspect;}
- (BOOL)check:(NSError **)e{return Allowed;}
- (BOOL)beginWork:(NSError **)e{Begins++;return BeginAllowed;}
- (void)endWork{Ends++;}
- (void)performBlock:(void (^)(void))block{id previous=Current;Current=self;@try{block();}@finally{Current=previous;}}
@end
@interface RBXCloneManager (Fixture)
- (BOOL)_recoverTransaction:(NSString *)path error:(NSError **)error;
@end
@implementation RBXCloneManager
- (BOOL)recoverInterruptedTransactionsWithContext:(RBXOperationContext *)context error:(NSError **)error{return YES;}
- (instancetype)initWithAppType:(NSString *)app operationContext:(RBXOperationContext *)context{Check(context==Current,@"owner context propagated inside global operation");self=[super init];if(self)_appDescriptor=RBXAppDescriptorForType(app);return self;}
- (BOOL)_recoverTransaction:(NSString *)path error:(NSError **)error{
 NSDictionary *record=[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"transaction.plist"]];Check(RBXAppInstallationRecordOwnedBy(record,self.appDescriptor),@"actual selected descriptor equals independently derived transaction owner");[Events addObject:self.appDescriptor[@"appType"]];if(Throw)@throw [NSException exceptionWithName:@"fixture" reason:@"service failure" userInfo:nil];return ![FailApp isEqual:self.appDescriptor[@"appType"]];
}
__METHOD__
@end
@implementation RBXContainerRegistry
- (NSArray *)pendingDeletionStates{return MigrationPending?@[@{}]:@[];}
- (NSArray *)containerIdsWithError:(NSError **)error{return @[@"reddit-id",@"deleting-id"];}
- (NSDictionary *)deletionStateForContainer:(NSString *)cid{return MigrationPending&&[cid isEqual:@"deleting-id"]?@{}:nil;}
- (BOOL)ensureAppCloneForContainer:(NSString *)cid error:(NSError **)error{[Migrated addObject:cid];return YES;}
__MIGRATION__
@end
static void Reset(NSString *base){RBXTransactionsRoot=[base stringByAppendingPathComponent:NSUUID.UUID.UUIDString];Check([NSFileManager.defaultManager createDirectoryAtPath:RBXTransactionsRoot withIntermediateDirectories:YES attributes:nil error:nil],@"private fixture root created");Events=[NSMutableArray array];Begins=Ends=Locks=0;LastFD=-1;FailApp=nil;Migrated=[NSMutableArray array];MigrationPending=NO;Allowed=BeginAllowed=LockAllowed=YES;Inspect=Throw=NO;}
static NSString *Record(NSString *app,NSString *phase){NSDictionary *d=RBXAppDescriptorForType(app);NSMutableDictionary *record=[RBXAppInstallationRecord(d,@"recovery-fixture") mutableCopy];record[@"state"]=phase;record[@"hadPreviousInstall"]=@NO;NSString *root=[RBXTransactionsRoot stringByAppendingPathComponent:NSUUID.UUID.UUIDString];Check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil],@"journal root created");NSString *path=[root stringByAppendingPathComponent:@"transaction.plist"];Check([record writeToFile:path atomically:YES],@"canonical journal written");return path;}
static BOOL Run(RBXOperationContext *c){NSError *error=nil;BOOL b=[RBXCloneManager recoverAllInterruptedTransactionsWithContext:c error:&error];if(BeginAllowed&&Begins)Check(Begins==Ends,@"all begun work ended");if(LastFD>=0)Check(fcntl(LastFD,F_GETFD)==-1&&errno==EBADF,@"transaction lock descriptor closed");Check(!Current,@"operation TLS restored");return b;}
int main(int argc,char **argv){@autoreleasepool{NSString *base=@(argv[1]);RBXOperationContext *c=[RBXOperationContext new];BOOL active=[RBXAppDescriptorForType(@"facebook")[@"runnable"] boolValue];
Reset(base);Check(Run(c)&&!Events.count,@"empty inventory succeeds without service operations");
Reset(base);Record(@"reddit",@"prepared");Record(@"facebook",@"committed");Check(Run(c),@"completed inactive backups never block Reddit recovery");Check(Events.count==(active?2:1),@"exact registered runnable owners are dispatched");
Reset(base);Record(@"reddit",@"installed");NSString *fb=Record(@"facebook",@"installed");Check(Run(c)==active,@"pending inactive owner blocks global recovery");Check(active?Events.count==2:Events.count==0,@"entire inventory preflight precedes all service effects");Check([NSFileManager.defaultManager fileExistsAtPath:fb],@"fixture services never erase retained app state");
Reset(base);Record(@"reddit",@"prepared");NSString *bad=Record(@"facebook",@"committed");NSMutableDictionary *record=[NSMutableDictionary dictionaryWithContentsOfFile:bad];record[@"appType"]=@"unknown";Check([record writeToFile:bad atomically:YES],@"unknown owner fixture");Check(!Run(c)&&!Events.count,@"unknown owner rejects entire plan before Reddit side effects");
Reset(base);Record(@"reddit",@"prepared");bad=Record(@"facebook",@"committed");record=[NSMutableDictionary dictionaryWithContentsOfFile:bad];[record removeObjectForKey:@"keychainAccessGroups"];Check([record writeToFile:bad atomically:YES],@"incomplete group fixture");Check(!Run(c)&&!Events.count,@"full group identity required even for an inactive completed journal");
for(NSString *app in (active?@[@"reddit",@"facebook"]:@[@"reddit"])) {Reset(base);Record(app,@"installed");FailApp=app;Check(!Run(c)&&Events.count==1,@"owner failure cannot report all-app recovery success");FailApp=nil;Check(Run(c)&&Events.count==2,@"retry returns to the same app owner");}
Reset(base);Check(!Run(nil)&&!Begins&&!Locks,@"missing context denied before locking");Inspect=YES;Check(!Run(c)&&!Begins&&!Locks,@"inspection cannot mutate");Inspect=NO;Allowed=NO;Check(!Run(c)&&!Begins&&!Locks,@"canceled context denied");
Reset(base);BeginAllowed=NO;Check(!Run(c)&&!Ends&&!Locks,@"begin failure performs no cleanup or service work");
Reset(base);LockAllowed=NO;Check(!Run(c)&&Begins==Ends&&!Events.count,@"lock failure still drains counted work");
Reset(base);Record(@"reddit",@"installed");Throw=YES;BOOL caught=NO;@try{Run(c);}@catch(NSException *e){caught=YES;}Check(caught&&Begins==Ends&&!Current&&fcntl(LastFD,F_GETFD)==-1,@"exception closes lock, ends work and restores TLS");
Reset(base);bad=Record(@"facebook",@"committed");record=[NSMutableDictionary dictionaryWithContentsOfFile:bad];record[@"appType"]=@"unknown";Check([record writeToFile:bad atomically:YES],@"migration unknown journal fixture");__block BOOL migrated=YES;[c performBlock:^{migrated=[[RBXContainerRegistry new] migrateAppClonesWithError:nil];}];Check(!migrated&&!Migrated.count,@"actual registry migration validates all-app recovery before provisioning");
MigrationPending=YES;[c performBlock:^{migrated=[[RBXContainerRegistry new] migrateAppClonesWithError:nil];}];Check(migrated&&[Migrated isEqual:@[@"reddit-id"]]&&!Events.count,@"pending deletion suppresses install recovery and skips that profile");
Check([NSFileManager.defaultManager removeItemAtPath:base error:nil],@"only temporary fixture files removed");printf("PASS: %lu actual global recovery assertions (Facebook active fixture=%d)\n",(unsigned long)Checks,active);return 0;}}
'''.replace('__METHOD__',method).replace('__MIGRATION__',migration)
with tempfile.TemporaryDirectory(prefix='socialbox-global-recovery-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 for active in (False,True):
  if active:
   for h in ['RBXAppRegistry.h','RBXAppRegistryData.h','RBXAppLifecycle.h','RBXAppKeychainPolicy.h']:shutil.copy2(ROOT/'shared'/h,p/h)
   data=(p/'RBXAppRegistryData.h').read_text();assert data.count('@"runnable": @NO')==1;(p/'RBXAppRegistryData.h').write_text(data.replace('@"runnable": @NO','@"runnable": @YES'))
  subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(p),'-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation','-framework','Security',str(p/'test.m'),'-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test'),str(p/'data')],check=True)
