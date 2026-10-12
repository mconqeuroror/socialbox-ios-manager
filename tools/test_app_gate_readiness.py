#!/usr/bin/env python3
"""Actual readiness waiter; real private receipt files, synthetic PID/services."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1];source=(ROOT/'daemon/RBXNetworkGate.m').read_text()
def code(sig):
 start=source.index(sig);return source[start:source.index('\n}\n',start)+3]
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
#import "RBXCloneManager.h"
#import "RBXOperationContext.h"
#import "RBXNetworkGate.h"
#import "RBXCloneEpoch.h"
#import "RBXHookReadiness.h"
#import <string.h>
#define PROC_PIDPATHINFO_MAXSIZE 1024
static NSString *DataRoot,*Executable;
static NSDictionary *Lease;
static BOOL Allowed=YES;
static NSUInteger Checks;
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static BOOL RBXGateMutationAllowed(NSError **e){return Allowed;}
static NSString *RBXBootEpoch(void){return @"fixture-boot";}
static NSTimeInterval RBXGateMonotonicTime(void){return NSProcessInfo.processInfo.systemUptime;}
static int proc_pidpath(int pid,void *buffer,uint32_t size){return pid==123?(int)strlcpy(buffer,Executable.UTF8String,size):0;}
@implementation RBXOperationContext
+ (instancetype)currentContext{return nil;}
@end
@implementation RBXCloneManager
- (instancetype)init{return [self initWithAppType:@"reddit" operationContext:nil];}
- (instancetype)initWithAppType:(NSString *)type operationContext:(id)c{self=[super init];if(self)_appDescriptor=RBXAppDescriptorForType(type);return self;}
- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundle{return RBXAppOwnsCloneBundleIdentifier(self.appDescriptor,bundle)?DataRoot:nil;}
@end
__MANAGER__
@implementation RBXNetworkGate
+ (NSDictionary *)_lease{return Lease;}
__METHOD__
@end
int main(int argc,char **argv){@autoreleasepool{
DataRoot=@(argv[1]);NSString *preferences=[DataRoot stringByAppendingPathComponent:@"Library/Preferences"];
Check([NSFileManager.defaultManager createDirectoryAtPath:preferences withIntermediateDirectories:YES attributes:nil error:nil],@"fixture directory created");
Check([@{@"CFBundleExecutable":@"Main"} writeToFile:[DataRoot stringByAppendingPathComponent:@"Info.plist"] atomically:YES],@"fixture executable metadata written");Executable=[DataRoot stringByAppendingPathComponent:@"Main"];
NSString *path=[preferences stringByAppendingPathComponent:@"com.redditbox.hook-ready.plist"];
NSMutableDictionary *groups=[NSMutableDictionary dictionary],*behavior=[NSMutableDictionary dictionary];for(NSString *s in RBXRequiredHookGroups())groups[s]=@YES;for(NSString *s in RBXRequiredBehaviorChecks())behavior[s]=@YES;
for(NSDictionary *d in RBXRegisteredAppDescriptors()){
 NSString *cid=@"ready-fixture",*bundle=RBXAppBundleIdentifier(d,cid);NSDictionary *p=@{@"containerId":cid,@"appType":d[@"appType"],@"app":@{@"bundleIdentifier":bundle,@"bundlePath":DataRoot}};
 NSTimeInterval now=NSDate.date.timeIntervalSince1970;
 NSDictionary *lease=@{@"state":@"armed",@"containerId":cid,@"bundleIdentifier":bundle,@"generation":@"fixture-generation",@"bootEpoch":RBXBootEpoch(),@"openedAt":@(now-1)};Lease=lease;
 NSDictionary *ready=@{@"containerId":cid,@"bundleIdentifier":bundle,@"generation":@"fixture-generation",@"bootEpoch":RBXEpochForClone(RBXBootEpoch(),bundle),@"pid":@123,@"timestamp":@(now),@"allHooksInstalled":@YES,@"evidenceVersion":@1,@"installedGroups":groups,@"behaviorChecks":behavior};
 Check([ready writeToFile:path atomically:YES],@"private synthetic hook receipt written");Check([RBXNetworkGate waitForHookReadinessForProfile:p expectedPID:123 generation:@"fixture-generation" timeout:0],@"selected app reads its own matching ready receipt");
 for(NSDictionary *change in @[@{@"timestamp":@(now+600)},@{@"timestamp":@0},@{@"timestamp":@YES},@{@"timestamp":@(now-10)},@{@"generation":@"old"},@{@"bootEpoch":@"old"},@{@"containerId":@"sibling"},@{@"bundleIdentifier":@"com.apple.mobilesafari"},@{@"pid":@456},@{@"allHooksInstalled":@NO},@{@"installedGroups":@{}},@{@"behaviorChecks":@{}}]){
 NSMutableDictionary *bad=ready.mutableCopy;[bad addEntriesFromDictionary:change];Check([bad writeToFile:path atomically:YES],@"bad receipt fixture written");Check(![RBXNetworkGate waitForHookReadinessForProfile:p expectedPID:123 generation:@"fixture-generation" timeout:0],@"malformed/foreign/stale/future readiness rejected");}
 Check([ready writeToFile:path atomically:YES],@"matching receipt restored");
 for(NSDictionary *change in @[@{@"state":@"closed"},@{@"generation":@"new"},@{@"containerId":@"sibling"},@{@"bundleIdentifier":@"com.apple.mobilesafari"},@{@"bootEpoch":@"new-boot"}]){NSMutableDictionary *bad=lease.mutableCopy;[bad addEntriesFromDictionary:change];Lease=bad;Check(![RBXNetworkGate waitForHookReadinessForProfile:p expectedPID:123 generation:@"fixture-generation" timeout:0],@"changed lease cannot consume an old readiness receipt");}Lease=lease;
 Allowed=NO;Check(![RBXNetworkGate waitForHookReadinessForProfile:p expectedPID:123 generation:@"fixture-generation" timeout:0],@"cancelled operation cannot consume readiness");Allowed=YES;
 NSMutableDictionary *other=p.mutableCopy;other[@"appType"]=[d[@"appType"] isEqual:@"reddit"]?@"facebook":@"reddit";Check(![RBXNetworkGate waitForHookReadinessForProfile:other expectedPID:123 generation:@"fixture-generation" timeout:0],@"another app cannot claim same receipt path");
}
Check([NSFileManager.defaultManager removeItemAtPath:DataRoot error:nil],@"only fixture files removed");printf("PASS: %lu actual per-app readiness/lease assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__MANAGER__',code('static RBXCloneManager *RBXGateManagerForProfile(')).replace('__METHOD__',code('+ (BOOL)waitForHookReadinessForProfile:'))
with tempfile.TemporaryDirectory(prefix='socialbox-gate-readiness-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'data')],check=True)
