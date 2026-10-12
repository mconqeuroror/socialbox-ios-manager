#!/usr/bin/env python3
"""Actual gate publication/sync methods; synthetic service and OS providers."""
from pathlib import Path
import subprocess,tempfile,shutil
ROOT=Path(__file__).resolve().parents[1];source=(ROOT/'daemon/RBXNetworkGate.m').read_text()
def code(sig):
 start=source.index(sig);return source[start:source.index('\n}\n',start)+3]
helpers='\n'.join(code(sig) for sig in ['static RBXCloneManager *RBXGateManagerForProfile(', 'static void RBXGateStopRunnableApps('] if sig in source)
methods='\n'.join(code(sig) for sig in ['+ (BOOL)syncCurrentLeaseToProfile:', '+ (BOOL)syncFirewallStatusToProfile:'])
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
#import "RBXCloneManager.h"
#import "RBXOperationContext.h"
#import "RBXProcessController.h"
#import "RBXNetworkGate.h"
static NSDictionary *Lease,*Status;
static NSMutableArray *Calls,*Kills;
static NSUInteger Checks;
static BOOL CanMutate=YES,CanWrite=YES;
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static BOOL RBXGateMutationAllowed(NSError **e){return CanMutate;}
static NSDictionary *RBXReadFirewallStatus(void){return Status;}
static BOOL RBXProviderAlive(NSDictionary *s){return [s[@"alive"] boolValue];}
@implementation RBXOperationContext
+ (instancetype)currentContext{static id c;if(!c)c=[self new];return c;}
@end
@implementation RBXProcessController
+ (void)killAllProcessesForAppDescriptor:(NSDictionary *)d{[Kills addObject:d[@"appType"]];}
@end
@implementation RBXCloneManager
- (instancetype)init{return [self initWithAppType:@"reddit" operationContext:RBXOperationContext.currentContext];}
- (instancetype)initWithAppType:(NSString *)type operationContext:(RBXOperationContext *)context{Check(context==RBXOperationContext.currentContext,@"context retained for gate publication");self=[super init];if(self)_appDescriptor=RBXAppDescriptorForType(type);return self;}
- (BOOL)writeGateControlPlist:(NSDictionary *)d profile:(NSDictionary *)p name:(NSString *)n error:(NSError **)e{
 [Calls addObject:@{@"owner":self.appDescriptor[@"appType"],@"profile":p,@"record":d,@"name":n}];return CanWrite&&[RBXAppDescriptorForProfile(p) isEqual:self.appDescriptor]&&RBXAppOwnsCloneBundleIdentifier(self.appDescriptor,p[@"app"][@"bundleIdentifier"]);
}
@end
__HELPERS__
__PUBLICATION__
@implementation RBXNetworkGate
+ (NSDictionary *)_lease{return Lease;}
__METHODS__
@end
int main(){@autoreleasepool{Calls=[NSMutableArray array];Kills=[NSMutableArray array];
for(NSDictionary *d in RBXRegisteredAppDescriptors()){
 NSString *app=d[@"appType"],*cid=@"gate-fixture",*bundle=RBXAppBundleIdentifier(d,cid);
 NSDictionary *p=@{@"appType":app,@"containerId":cid,@"app":@{@"bundleIdentifier":bundle}};
 Lease=@{@"state":@"closed",@"containerId":cid,@"bundleIdentifier":bundle};Status=@{@"state":@"closed",@"containerId":cid,@"bundleIdentifier":bundle,@"alive":@YES,@"enforced":@YES};
 CanMutate=NO;[Calls removeAllObjects];Check(RBXPublishCloneControl(Lease,Status)&&Calls.count==2,@"both clone-local revocation records published for each app even during cancellation");for(NSDictionary *call in Calls)Check([call[@"owner"] isEqual:app],@"publication uses selected app manager");
 Check([RBXNetworkGate syncCurrentLeaseToProfile:p error:nil]&&[RBXNetworkGate syncFirewallStatusToProfile:p error:nil],@"both closed syncs use selected app");
 NSMutableDictionary *bad=p.mutableCopy;bad[@"appType"]=[app isEqual:@"reddit"]?@"facebook":@"reddit";NSUInteger before=Calls.count;Check(![RBXNetworkGate syncCurrentLeaseToProfile:bad error:nil]&&![RBXNetworkGate syncFirewallStatusToProfile:bad error:nil]&&Calls.count==before,@"conflicting profile owner never reaches a writer");
 bad=p.mutableCopy;bad[@"containerId"]=@"sibling";Check(![RBXNetworkGate syncCurrentLeaseToProfile:bad error:nil],@"lease of another container denied");
 NSMutableDictionary *open=Lease.mutableCopy;open[@"state"]=@"open";Lease=open;Check(![RBXNetworkGate syncCurrentLeaseToProfile:p error:nil],@"canceled active publication denied");CanMutate=YES;Check([RBXNetworkGate syncCurrentLeaseToProfile:p error:nil],@"valid active publication succeeds");CanWrite=NO;Check(!RBXPublishCloneControl(Lease,Status),@"writer failure cannot report successful revocation");CanWrite=YES;
}
[Calls removeAllObjects];Check(RBXPublishCloneControl(@{},nil)&&!Calls.count,@"no previous clone needs no local mirror");
for(NSString *bundle in @[@"com.facebook.Facebook",@"com.reddit.Reddit",@"com.apple.mobilesafari",@"socialbox.profile.fb.pbad"]){Check(!RBXPublishCloneControl(@{@"bundleIdentifier":bundle},nil)&&!Calls.count,@"source/system/loose-family identities never reach clone control writer");}
__STOP_TEST__
printf("PASS: %lu actual app-scoped gate control assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__HELPERS__',helpers).replace('__PUBLICATION__',code('static BOOL RBXPublishCloneControl(')).replace('__METHODS__',methods).replace('__STOP_TEST__','RBXGateStopRunnableApps();Check([Kills isEqual:@[@"reddit"]],@"emergency stop selects exactly production runnable descriptors");' if 'RBXGateStopRunnableApps' in source else '')
with tempfile.TemporaryDirectory(prefix='socialbox-gate-control-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
 # Exercise exactly the additive future registry without modifying production.
 for header in ['RBXAppRegistry.h','RBXAppRegistryData.h']:
  shutil.copy2(ROOT/'shared'/header,p/header)
 data=(p/'RBXAppRegistryData.h').read_text();assert data.count('@\"runnable\": @NO')==1
 (p/'RBXAppRegistryData.h').write_text(data.replace('@\"runnable\": @NO','@\"runnable\": @YES'))
 (p/'test.m').write_text(fixture.replace('[Kills isEqual:@[@\"reddit\"]]','[Kills isEqual:@[@\"reddit\",@\"facebook\"]]'))
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-Wno-objc-property-implementation','-I'+str(p),'-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
