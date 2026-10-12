#!/usr/bin/env python3
"""Actual cloud snapshot and retirement closure, synthetic service providers."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
cloud=(ROOT/'daemon/RBXCloudSync.m').read_text();registry=(ROOT/'daemon/RBXContainerRegistry.m').read_text()
def code(source,sig):
 i=source.index(sig);return source[i:source.index('\n}\n',i)+3]
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXContainerRegistry.h"
#import "RBXCentralStore.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXNetworkGate.h"
#import "RBXOperationContext.h"
#import "RBXProfileIdentifier.h"
static NSMutableDictionary *Store;
static NSMutableArray *Events;
static NSString *LeasePath;
static BOOL Allowed=YES,Inspect,CloseOK=YES,StopOK=YES,WaitOK=YES;
static NSUInteger Checks;
static void Check(BOOL ok,NSString *m){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static NSError *RBXCloudInputError(NSString *m){return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:m}];}
static NSError *RBXDeletionError(NSString *m){return RBXCloudInputError(m);}
static BOOL RBXRegistryCheckOperation(BOOL mutating,NSError **e){return Allowed;}
@implementation RBXOperationContext
- (BOOL)inspectionOnly{return Inspect;}
- (BOOL)check:(NSError **)e{return Allowed;}
@end
__CHECK__
__QUIESCE__
@implementation RBXNetworkGate
+ (NSString *)leasePath{return LeasePath;}
+ (NSString *)closeTrafficWithReason:(NSString *)reason error:(NSError **)e{[Events addObject:@"close"];return CloseOK?@"fixture-generation":nil;}
+ (BOOL)waitForMaintenanceClosure:(NSString *)generation timeout:(NSTimeInterval)t{[Events addObject:@"ack"];return WaitOK&&[generation isEqual:@"fixture-generation"];}
@end
@implementation RBXProcessController
- (BOOL)killAllAndWait:(NSTimeInterval)t{[Events addObject:@"stop:reddit"];return StopOK;}
@end
@implementation RBXAppProcessCoordinator
- (BOOL)killAllAndWait:(NSTimeInterval)t{Check([Events containsObject:@"close"],@"revocation attempted before global stop");Check(t==8.0,@"existing bounded stop budget retained");[Events addObject:@"stop:all"];return StopOK;}
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore{static id s;if(!s)s=[self new];return s;}
- (BOOL)update:(void (^)(NSMutableDictionary *))b error:(NSError **)e{b(Store);return YES;}
@end
@implementation RBXContainerRegistry
- (NSArray *)containerIdsWithError:(NSError **)e{return @[@"target"];}
__RETIRE__
@end
static NSDictionary *Binding(void){return @{@"serverURL":@"https://fixture.invalid",@"deviceId":@"device-fixture"};}
static void Reset(void){Store=[@{@"cloudProfileBindings":@{@"target":Binding()}} mutableCopy];Events=[NSMutableArray array];Allowed=CloseOK=StopOK=WaitOK=YES;Inspect=NO;Check([@{@"containerId":@"target",@"state":@"open"} writeToFile:LeasePath atomically:YES],@"real fixture lease written");}
int main(int argc,char **argv){@autoreleasepool{LeasePath=@(argv[1]);RBXOperationContext *c=[RBXOperationContext new];RBXContainerRegistry *r=[RBXContainerRegistry new];
for(NSNumber *cloudCase in @[@YES,@NO]){
 Reset();BOOL ok=cloudCase.boolValue?RBXCloudQuiesce(c,nil):[r recordRemoteRetirementForContainer:@"target" binding:Binding() error:nil];Check(ok&&[Events isEqual:@[@"close",@"stop:all",@"ack"]],@"both snapshot and retirement stop every app before closure acknowledgement");
 for(NSNumber *failure in @[@0,@1,@2]){Reset();if(failure.intValue==0)CloseOK=NO;if(failure.intValue==1)StopOK=NO;if(failure.intValue==2)WaitOK=NO;ok=cloudCase.boolValue?RBXCloudQuiesce(c,nil):[r recordRemoteRetirementForContainer:@"target" binding:Binding() error:nil];Check(!ok&&[Events containsObject:@"stop:all"],@"closure failure stays failure and still attempts global stop");}
 Reset();Allowed=NO;Check(!(cloudCase.boolValue?RBXCloudQuiesce(c,nil):[r recordRemoteRetirementForContainer:@"target" binding:Binding() error:nil])&&!Events.count,@"canceled operation cannot begin snapshot/retirement work");
}
Reset();Inspect=YES;Check(!RBXCloudQuiesce(c,nil)&&!Events.count,@"inspection context cannot take mutating snapshot");Inspect=NO;Check(!RBXCloudQuiesce(nil,nil)&&!Events.count,@"snapshot requires an explicit owner");
Reset();Check([@{@"containerId":@"sibling",@"state":@"open"} writeToFile:LeasePath atomically:YES],@"unrelated active lease fixture");Check([r recordRemoteRetirementForContainer:@"target" binding:Binding() error:nil]&&!Events.count,@"retiring inactive target does not interrupt an unrelated app");
Reset();Check(![r recordRemoteRetirementForContainer:@"target" binding:@{@"deviceId":@"foreign"} error:nil]&&!Events.count,@"foreign cloud ownership cannot trigger local closure");
Check([NSFileManager.defaultManager removeItemAtPath:LeasePath error:nil],@"only temporary lease removed");printf("PASS: %lu actual global maintenance closure assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__CHECK__',code(cloud,'static BOOL RBXCloudCheck(')).replace('__QUIESCE__',code(cloud,'static BOOL RBXCloudQuiesce(')).replace('__RETIRE__',code(registry,'- (BOOL)recordRemoteRetirementForContainer:'))
with tempfile.TemporaryDirectory(prefix='socialbox-maintenance-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'lease.plist')],check=True)
