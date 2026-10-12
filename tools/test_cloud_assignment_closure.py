"""Execute the shipped cloud revocation method; no phone, network or real profiles."""
from pathlib import Path
import subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT/'daemon/RBXCloudSync.m').read_text()
start = source.index('- (void)_enforceCurrentAssignmentWithContext:')
method = source[start:source.index('\n}\n', start)+3]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXOperationContext.h"
#import "RBXNetworkGate.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXProcessController.h"
static NSMutableArray *Events;
static NSMutableDictionary *Profile;
static NSArray *Assignments;
static NSString *Fail;
static BOOL CloudFailure, ValidContext, Paired;
static NSUInteger Checks;
static BOOL Step(NSString *s){[Events addObject:s];return ![Fail isEqual:s];}
static void Check(BOOL ok,NSString *why){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);exit(1);}}
static BOOL RBXCloudCheck(id context,NSError **error){return ValidContext;}
static NSMutableDictionary *RBXCloudLoadProfile(NSString *cid,NSError **error){return [Profile mutableCopy];}
static NSDictionary *RBXCloudResponseDictionary(NSData *data,NSError **error){return CloudFailure?nil:@{};}
static NSArray *RBXCloudAssignmentArray(NSDictionary *d,NSError **error){return CloudFailure?nil:Assignments;}
static NSString *RBXCloudString(NSDictionary *d,NSString *k){return d[k];}
static NSDictionary *RBXBuildMGOverrides(NSDictionary *p){return @{};}
static BOOL RBXCloudWriteProfile(NSDictionary *p,NSString *cid,BOOL existing,NSError **error){
 if(!Step(@"write"))return NO;Profile=[p mutableCopy];return YES;
}
@implementation RBXOperationContext
- (BOOL)markUnsafeWithReason:(NSString *)s error:(NSError **)error{return Step(@"unsafe");}
@end
@implementation RBXNetworkGate
+ (NSString *)closeTrafficWithReason:(NSString *)s error:(NSError **)error{return Step(@"closed")?@"generation":nil;}
+ (BOOL)waitForMaintenanceClosure:(NSString *)g timeout:(NSTimeInterval)t{return Step(@"ack");}
@end
@implementation RBXAppProcessCoordinator
- (BOOL)killAllAndWait:(NSTimeInterval)t{return Step(@"stop-all-apps");}
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)t error:(NSError **)error{return Step(@"drain");}
@end
@implementation RBXProcessController
+ (void)killAllRedditProcesses{Step(@"reddit-only");}
@end
@interface Fixture : NSObject
- (BOOL)paired;
- (NSString *)serverURL;
- (NSString *)deviceToken;
- (NSData *)_performDataRequest:(id)r context:(id)c error:(NSError **)e;
- (void)_enforceCurrentAssignmentWithContext:(RBXOperationContext *)c;
@end
@implementation Fixture
- (BOOL)paired{return Paired;}
- (NSString *)serverURL{return @"https://fixture.invalid";}
- (NSString *)deviceToken{return @"fixture";}
- (NSData *)_performDataRequest:(id)r context:(id)c error:(NSError **)e{return [NSData data];}
__METHOD__
@end
static void Reset(void){
 Events=[NSMutableArray array];Fail=nil;CloudFailure=NO;ValidContext=YES;Paired=YES;
 Profile=[@{@"containerId":@"fixture",@"appType":@"facebook",@"proxy":@{@"url":@"http://fixture.invalid:9000",@"proxyId":@"old"}} mutableCopy];Assignments=@[];
}
int main(void){@autoreleasepool{
 Fixture *f=[Fixture new];RBXOperationContext *c=[RBXOperationContext new];
 Reset();[f _enforceCurrentAssignmentWithContext:c];
 Check([Events isEqual:@[@"closed",@"stop-all-apps",@"ack",@"drain",@"write"]],@"revocation closes and drains ALL app families before profile mutation");
 Check([Profile[@"proxy"][@"url"] isEqual:@""] && !Profile[@"proxy"][@"proxyId"],@"revoked assignment removed");
 for(NSString *failure in @[@"closed",@"stop-all-apps",@"ack",@"drain"]){
  Reset();Fail=failure;NSDictionary *before=[Profile copy];[f _enforceCurrentAssignmentWithContext:c];
  Check([Events containsObject:@"stop-all-apps"],@"stop is attempted even when CLOSED persistence fails");
  Check([Events containsObject:@"unsafe"] && ![Events containsObject:@"write"],@"unproven closure fences recovery and prevents profile writes");
  Check([Profile isEqual:before],@"closure failure preserves profile");
 }
 Reset();Fail=@"write";[f _enforceCurrentAssignmentWithContext:c];
 Check([Events containsObject:@"closed"] && [Events containsObject:@"stop-all-apps"] && [Events containsObject:@"unsafe"],@"write failure remains closed and fenced");
 Reset();Assignments=@[@{@"profileId":@"fixture",@"proxy":@{@"url":@"http://fixture.invalid:9000"}}];
 [f _enforceCurrentAssignmentWithContext:c];Check(!Events.count,@"matching assignment leaves existing session unchanged");
 Reset();CloudFailure=YES;[f _enforceCurrentAssignmentWithContext:c];Check(!Events.count,@"transient cloud failure does not invent revocation");
 Reset();Paired=NO;[f _enforceCurrentAssignmentWithContext:c];Check(!Events.count,@"unpaired remains a no-op");
 printf("PASS: %lu cloud assignment closure assertions\n",(unsigned long)Checks);
}}
'''
# The only device file read is an active ID. Replace that boundary, retaining
# the entire production method including ordering and every failure branch.
begin = method.index('    NSString *containerId = ')
end = method.index('    NSError *profileError', begin)
method = method[:begin]+'    NSString *containerId = @"fixture";\n'+method[end:]
with tempfile.TemporaryDirectory(prefix='rbx-cloud-close-') as d:
    path=Path(d)/'fixture.m';path.write_text(fixture.replace('__METHOD__',method))
    exe=Path(d)/'fixture'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-I'+str(ROOT/'daemon'),'-I'+str(ROOT/'shared'),str(path),'-framework','Foundation','-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
