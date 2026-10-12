"""Execute shipped selection handler and shared-icon resolution with inert OS services."""
from pathlib import Path
import shutil, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/main.m').read_text()
start = source.index('static void handleSelectContainer(')
handler = source[start:source.index('\n}\n', start) + 3]
start = source.index('    if ([pending[@"action"] isEqual:@"launchSelectedContainer"])', source.index('static void handleQueuedRequest('))
resolution = source[start:source.index('    // Check the persisted owner', start)]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXWorkspaceSelection.h"
#import "RBXAppAdmission.h"
#import "RBXContainerRegistry.h"
#import "RBXCentralStore.h"
#import "RBXOperationContext.h"
#import "RBXReplacement.h"
#import "RBXNetworkGate.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXLauncherState.h"
static NSMutableDictionary *Doc;
static NSMutableArray *Events;
static NSDictionary *Receipt;
static NSString *Fail;
static NSUInteger Reads,Writes,Checks;
static BOOL Unsafe;
static RBXContainerRegistry *sRegistry;
static RBXAppProcessCoordinator *sProc;
static BOOL Step(NSString *step){[Events addObject:step];return ![Fail isEqual:step];}
static void Check(BOOL ok,NSString *reason){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",reason.UTF8String);exit(1);}}
static void completeRequest(NSDictionary *request,BOOL ok,NSString *message,NSDictionary *details){Receipt=@{@"ok":@(ok),@"details":details};}
@implementation RBXCentralStore
+ (instancetype)sharedStore{static id store; if(!store)store=[self new];return store;}
- (NSMutableDictionary *)dictionary{return Doc;}
- (BOOL)update:(void (^)(NSMutableDictionary *))block error:(NSError **)error{Writes++;if(!Step(Writes==1?@"pending":@"commit"))return NO;block(Doc);return YES;}
@end
@implementation RBXContainerRegistry
- (NSDictionary *)validatedProfileForContainer:(NSString *)container error:(NSError **)error{
 Reads++;if(!Step(Reads==1?@"validate":@"revalidate"))return nil;
 return @{@"appType":[Fail isEqual:@"foreign"]?@"reddit":@"facebook",@"containerId":container};
}
@end
@implementation RBXOperationContext
+ (instancetype)currentContext{static id context;if(!context)context=[self new];return context;}
- (BOOL)check:(NSError **)error{return YES;}
- (BOOL)markUnsafeWithReason:(NSString *)reason error:(NSError **)error{Unsafe=YES;return YES;}
@end
@implementation RBXReplacement
+ (BOOL)launchAllowedForContainer:(NSString *)container error:(NSError **)error{return YES;}
@end
@implementation RBXNetworkGate
+ (NSString *)closeTrafficWithReason:(NSString *)reason error:(NSError **)error{return Step(@"close")?@"generation":nil;}
+ (BOOL)waitForMaintenanceClosure:(NSString *)generation timeout:(NSTimeInterval)timeout{return Step(@"ack");}
@end
@implementation RBXAppProcessCoordinator
- (BOOL)killAllAndWait:(NSTimeInterval)timeout{return Step(@"stop");}
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval error:(NSError **)error{return Step(@"drain");}
@end
@implementation RBXLauncherState
+ (void)publishWithRegistry:(id)registry{}
@end
__HANDLER__
static NSDictionary *Resolve(NSDictionary *pending){
__RESOLUTION__
 return pending;
}
static void Reset(void){Events=[NSMutableArray array];Receipt=nil;Reads=Writes=0;Unsafe=NO;}
int main(void){@autoreleasepool{
 sRegistry=[RBXContainerRegistry new];sProc=[RBXAppProcessCoordinator new];Doc=[@{@"device":[NSMutableDictionary dictionary],@"containers":@{@"keep":@"unchanged"}} mutableCopy];
 for(NSUInteger i=0;i<40;i++){
  Reset();Fail=nil;NSString *cid=[NSString stringWithFormat:@"profile-%lu",(unsigned long)i];
  handleSelectContainer(@{@"action":@"selectContainer",@"appType":@"facebook",@"container":cid,@"requestId":NSUUID.UUID.UUIDString});
  Check([Receipt[@"ok"] boolValue],@"forty daemon selections succeed");
  Check([Events isEqual:@[@"validate",@"pending",@"close",@"stop",@"ack",@"drain",@"revalidate",@"commit"]],@"actual daemon ordering");
  NSDictionary *resolved=Resolve(@{@"action":@"launchSelectedContainer",@"appType":@"facebook",@"requestId":NSUUID.UUID.UUIDString});
  Check([resolved[@"container"] isEqual:cid] && [resolved[@"action"] isEqual:@"launchSelectedContainer"],@"icon resolves latest selection without embedding ID");
  Check([Doc[@"containers"] isEqual:@{@"keep":@"unchanged"}],@"selection never rewrites identities or data");
 }
 for(NSString *failure in @[@"pending",@"close",@"stop",@"ack",@"drain",@"revalidate",@"commit"]){
  Reset();Fail=failure;
  handleSelectContainer(@{@"action":@"selectContainer",@"appType":@"facebook",@"container":@"next",@"requestId":NSUUID.UUID.UUIDString});
  Check(![Receipt[@"ok"] boolValue],@"failed stage never claims selected");
  Check(Unsafe || !RBXWorkspaceSelectedID(Doc[@"device"][@"workspaceSelection"],@"facebook"),@"failed selection cannot silently fall back");
 }
 Reset();Fail=@"foreign";
 handleSelectContainer(@{@"action":@"selectContainer",@"appType":@"facebook",@"container":@"foreign",@"requestId":NSUUID.UUID.UUIDString});
 Check(![Receipt[@"ok"] boolValue]&&Writes==0,@"foreign owner rejected before state changes");
 Check(!Resolve(@{@"action":@"launchSelectedContainer",@"appType":@"facebook",@"container":@"forged"}),@"icon cannot supply a target");
 Check(!Resolve(@{@"action":@"launchSelectedContainer",@"appType":@"reddit"}),@"foreign app cannot resolve");
 printf("Actual workspace dispatch: %lu assertions PASS; 40 selections and closure faults.\n",(unsigned long)Checks);
}}
'''.replace('__HANDLER__', handler).replace('__RESOLUTION__', resolution.replace('return;', 'return nil;'))
with tempfile.TemporaryDirectory(prefix='rbx-workspace-dispatch-') as tmp:
    root=Path(tmp);shutil.copytree(ROOT/'shared',root/'shared')
    registry=root/'shared/RBXAppRegistryData.h'
    registry.write_text(registry.read_text().replace('@"runnable": @NO','@"runnable": @YES'))
    (root/'test.m').write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-I'+str(root/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(root/'test.m'),'-o',str(root/'test')],check=True)
    subprocess.run([str(root/'test')],check=True)
