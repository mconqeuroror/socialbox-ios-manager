#!/usr/bin/env python3
"""Run the shipped queue dispatcher with inert services and a mocked grant.

This tests admission before profile reads, cloud work or handler dispatch. The
separate service-lifetime/live probes test the real signed-grant verifier.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/main.m').read_text()
start = source.index('static void handleQueuedRequest(')
handler = source[start:source.index('\n}\n', start) + 3]
auth_start = source.find('static BOOL authorizeQueuedRequest(')
auth = source[auth_start:source.index('\n}\n', auth_start) + 3] if auth_start >= 0 else ''
cli_start = source.index('            NSString *command =', source.index('static int runCommand('))
cli_prefix = source[cli_start:source.index('            RBXContainerRegistry *registry', cli_start)]
fixture = r'''
#import <Foundation/Foundation.h>
static BOOL Granted;
static NSUInteger Dispatches, Reads, GrantChecks, Checks;
static NSDictionary *Receipt;
@interface RBXLicenseGuard : NSObject
+ (instancetype)sharedGuard;
- (BOOL)isUnlocked;
@end
@implementation RBXLicenseGuard
+ (instancetype)sharedGuard { static id guard; if (!guard) guard=[self new]; return guard; }
- (BOOL)isUnlocked { GrantChecks++; return Granted; }
@end
@interface RBXCentralStore : NSObject
+ (instancetype)sharedStore;
- (NSDictionary *)dictionary;
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore { return [self new]; }
- (NSDictionary *)dictionary { Reads++; return @{@"device":@{}}; }
@end
@interface RBXProfileIO : NSObject
+ (BOOL)isSafeContainerIdentifier:(id)value;
+ (NSDictionary *)loadProfileForContainer:(id)value error:(NSError **)error;
+ (NSDictionary *)readProfileOwnershipForContainer:(id)value error:(NSError **)error;
@end
@implementation RBXProfileIO
+ (BOOL)isSafeContainerIdentifier:(id)value { return [value isKindOfClass:NSString.class]; }
+ (NSDictionary *)loadProfileForContainer:(id)value error:(NSError **)error { Reads++; return @{}; }
+ (NSDictionary *)readProfileOwnershipForContainer:(id)value error:(NSError **)error { Reads++; return @{}; }
@end
@interface RBXOperationContext : NSObject
+ (instancetype)currentContext;
@end
@implementation RBXOperationContext
+ (instancetype)currentContext { return [self new]; }
@end
@interface RBXCloudSync : NSObject
+ (instancetype)sharedSync;
- (void)handleQueuedAction:(id)pending context:(id)context completion:(void (^)(BOOL, NSString *))done;
@end
@implementation RBXCloudSync
+ (instancetype)sharedSync { return [self new]; }
- (void)handleQueuedAction:(id)pending context:(id)context completion:(void (^)(BOOL, NSString *))done { Dispatches++; done(YES,@"fixture cloud result"); }
@end
static NSString *RBXWorkspaceSelectedID(id state,id app) { Reads++; return @"selected"; }
static NSString *RBXAppRequestBlockReason(id pending,id profiles) { return nil; }
static NSDictionary *waitForCloudOperation(void (^work)(void (^)(BOOL, NSString *))) {
 __block NSDictionary *result; work(^(BOOL ok,NSString *message){result=@{@"ok":@(ok),@"message":message};}); return result;
}
static void completeRequest(id pending,BOOL ok,NSString *message,NSDictionary *details) { Receipt=@{@"ok":@(ok),@"message":message,@"details":details}; }
static void handleCreationDraftAction(id pending) { Dispatches++; }
static void handleLicenseAction(id pending) { Dispatches++; }
static void handleSelectContainer(id pending) { Dispatches++; }
static void handleLaunchContainer(id pending) { Dispatches++; }
static void handleRotate(id pending) { Dispatches++; }
static void handleContainerAction(id pending) { Dispatches++; }
static void handleLauncherAction(id pending) { Dispatches++; }
__AUTH__
__HANDLER__
static int CLIAdmission(int argc,char *argv[]) {
__CLI__
 return 0;
}
static void Check(BOOL ok,NSString *reason) { Checks++; if (!ok) { fprintf(stderr,"FAIL: %s\n",reason.UTF8String); exit(1); } }
static void Reset(BOOL grant) { Granted=grant; Dispatches=Reads=GrantChecks=0; Receipt=nil; }
int main(void) { @autoreleasepool {
 NSArray *protectedActions=@[@"prepareContainer",@"reviewContainerDraft",@"discardContainerDraft",@"loadIdentityEditor",@"randomizeIdentityEditor",@"previewIdentity",@"applyIdentity",@"selectContainer",@"launchContainer",@"launchSelectedContainer",@"createContainer",@"deleteContainer",@"updateMetadata",@"discardMetadataChanges",@"replaceContainer",@"pair",@"export",@"importNewest",@"importById",@"regeneratePassphrase",@"cloudVaultList",@"cloudVaultKey",@"cloudVaultSetKey",@"cloudVaultRestore",@"cloudVaultDelete",@"archiveSource",@"detectProxyRegion",@"testConfiguration",@"importSource",@"futureAction"];
 for (NSString *action in protectedActions) {
  for (NSUInteger draft=0;draft<2;draft++) {
   Reset(NO); NSMutableDictionary *request=[@{@"action":action,@"appType":@"reddit",@"container":@"owned",@"from":@"previous",@"containerId":@"sibling"} mutableCopy];
   if (draft) request[@"creationDraftToken"]=@"draft";
   handleQueuedRequest(request);
   Check(Dispatches==0 && Reads==0 && GrantChecks==1,[NSString stringWithFormat:@"Locked %@ denied before reads or dispatch",action]);
   Check(Receipt && ![Receipt[@"ok"] boolValue] && [Receipt[@"details"][@"code"] isEqual:@"license-required"],@"Locked mutation produces an explicit failure receipt");
  }
  Reset(YES); handleQueuedRequest(@{@"action":action,@"appType":@"reddit"});
  Check(GrantChecks==1 && Dispatches==1,@"A verified grant preserves existing dispatch");
 }
 for (NSString *action in @[@"activateLicense",@"validateLicense",@"configurationChanged",@"runDiagnostics",@"exportSupportLog"]) {
  Reset(NO); handleQueuedRequest(@{@"action":action,@"appType":@"reddit"});
  Check(Dispatches==1 && GrantChecks==0,@"Activation, closure and diagnostics remain available while locked");
 }
 Reset(NO); handleQueuedRequest(@{@"action":@"refreshLauncher",@"container":@"owned"});
 Check(Dispatches==0 && Reads==0 && [Receipt[@"ok"] boolValue],@"Locked refresh is local receipt only; never cloud sync");
 Reset(YES); handleQueuedRequest(@{@"action":@"refreshLauncher"});
 Check(Dispatches==1 && GrantChecks==1,@"Licensed refresh preserves existing behavior");
 for (id invalid in @[NSNull.null,@42,@[],@{},@""]) {
  Reset(YES); handleQueuedRequest(@{@"action":invalid});
  Check(Dispatches==0 && Reads==0 && Receipt && ![Receipt[@"ok"] boolValue],@"Malformed action fails closed even with a grant");
 }
 Reset(YES); handleQueuedRequest(@{}); Check(Dispatches==0 && Receipt && ![Receipt[@"ok"] boolValue],@"Absent action fails closed");
 char *provision[]={"redditboxd","provision-clone","test"};
 Reset(NO); Check(CLIAdmission(3,provision)==1 && GrantChecks==1,@"Direct provisioning requires a verified grant too");
 Reset(YES); Check(CLIAdmission(3,provision)==0 && GrantChecks==1,@"Licensed direct provisioning remains allowed");
 char *recovery[]={"redditboxd","migrate-clones"};
 Reset(NO); Check(CLIAdmission(2,recovery)==0,@"Closed-state root upgrade recovery remains possible while locked");
 printf("PASS license dispatch: %lu assertions, 30 protected actions, recovery and CLI admission\n",(unsigned long)Checks);
} }
'''.replace('__AUTH__',auth).replace('__HANDLER__',handler).replace('__CLI__',cli_prefix)
with tempfile.TemporaryDirectory(prefix='rbx-license-dispatch-') as temp:
    root=Path(temp)
    (root/'test.m').write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incompatible-pointer-types','-framework','Foundation',str(root/'test.m'),'-o',str(root/'test')],check=True)
    subprocess.run([str(root/'test')],check=True)
