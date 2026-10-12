#!/usr/bin/env python3
"""Execute the actual clone-local control writer against real temporary files."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
s=(ROOT/'daemon/RBXCloneManager.m').read_text()
start=s.index('- (BOOL)writeGateControlPlist:')
method=s[start:s.index('\n}\n',start)+3]
method=method.replace('@"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist"','LeasePath')
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"
#import "RBXCloneEpoch.h"
#import "RBXLiveness.h"
#include <sys/stat.h>
#include <unistd.h>
#include <objc/message.h>
static NSString *LeasePath,*Home;
static NSUInteger Checks,Lookups;
static BOOL Safe=YES,Owned=YES,Present=YES;
static NSError *RBXCloneError(NSInteger c,NSString *m){return [NSError errorWithDomain:@"test" code:c userInfo:@{NSLocalizedDescriptionKey:m}];}
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
@interface RBXOperationContext:NSObject
@property BOOL inspectionOnly;
@property BOOL cancelled;
+ (id)currentContext;
+ (BOOL)checkSafetyFence:(NSError **)error;
+ (NSString *)daemonBootEpoch;
- (BOOL)check:(NSError **)error;
@end
@implementation RBXOperationContext
+ (id)currentContext{return nil;}
+ (BOOL)checkSafetyFence:(NSError **)error{return Safe;}
+ (NSString *)daemonBootEpoch{return @"fixture-boot";}
- (BOOL)check:(NSError **)error{return Safe;}
@end
@interface Proxy:NSObject
- (NSURL *)dataContainerURL;
@end
@implementation Proxy
- (NSURL *)dataContainerURL{return [NSURL fileURLWithPath:Home];}
@end
static NSDictionary *RBXInstalledApplication(NSString *bundle,NSError **error){Lookups++;return Present?@{@"proxy":[Proxy new]}:@{};}
static NSString *RBXProxyPath(id proxy,NSString *selector,NSError **error){return Home;}
static BOOL RBXValidateDataRemovalPath(NSString *path,NSString *bundle,BOOL plugin,NSError **error){return Owned&&[path isEqual:Home];}
static BOOL RBXDeletionContainerID(NSString *value){return [value isKindOfClass:NSString.class]&&value.length>0;}
@interface RBXCloneManager:NSObject
@property NSDictionary *appDescriptor;
+ (NSString *)bundleIdentifierForContainer:(NSString *)container;
@end
@implementation RBXCloneManager
+ (NSString *)bundleIdentifierForContainer:(NSString *)c{return RBXAppBundleIdentifier(RBXRedditAppDescriptor(),c);}
__METHOD__
@end
static NSDictionary *Lease(NSDictionary *descriptor,NSString *state){return @{@"state":state,@"containerId":@"writer-test",@"bundleIdentifier":RBXAppBundleIdentifier(descriptor,@"writer-test"),@"generation":@"fixture-generation",@"bootEpoch":@"fixture-boot",@"heartbeatAt":@([NSDate.date timeIntervalSince1970]),@"controlIPs":@[@"198.51.100.1"],@"lastExitIP":@"198.51.100.2"};}
int main(int argc,char **argv){@autoreleasepool{
 NSString *root=@(argv[1]);LeasePath=[root stringByAppendingPathComponent:@"lease.plist"];
 for(NSDictionary *descriptor in [RBXRegisteredAppDescriptors() reverseObjectEnumerator]){
  RBXCloneManager *manager=[RBXCloneManager new];manager.appDescriptor=descriptor;
  NSString *cid=@"writer-test",*bundle=RBXAppBundleIdentifier(descriptor,cid);
  Home=[root stringByAppendingPathComponent:descriptor[@"appType"]];
  NSDictionary *profile=@{@"appType":descriptor[@"appType"],@"containerId":cid,@"app":@{@"bundleIdentifier":bundle}};
  for(NSString *state in @[@"closed",@"armed",@"open"]){
   NSDictionary *lease=Lease(descriptor,state);Check([lease writeToFile:LeasePath atomically:YES],@"lease written");
   for(NSString *name in @[@"com.redditbox.network-lease.plist",@"com.redditbox.firewall-status.plist"]){
    Check([manager writeGateControlPlist:lease profile:profile name:name error:nil],[NSString stringWithFormat:@"%@ %@ actual clone writer succeeds",descriptor[@"appType"],state]);
    NSDictionary *got=[NSDictionary dictionaryWithContentsOfFile:[[Home stringByAppendingPathComponent:@"Library/Preferences"] stringByAppendingPathComponent:name]];
    Check([got[@"state"] isEqual:state]&&[got[@"bundleIdentifier"] isEqual:bundle],@"real mirror bound to selected clone");
    Check([got[@"bootEpoch"] isEqual:RBXEpochForClone(@"fixture-boot",bundle)],@"clone epoch scoped");
    Check(!got[@"controlIPs"]&&!got[@"lastExitIP"],@"global route values excluded");
   }
   NSUInteger before=Lookups;
   NSDictionary *other=RBXAppDescriptorForType([descriptor[@"appType"] isEqual:@"reddit"]?@"facebook":@"reddit");
   NSMutableDictionary *bad=profile.mutableCopy;bad[@"appType"]=other[@"appType"];
   Check(![manager writeGateControlPlist:lease profile:bad name:@"com.redditbox.network-lease.plist" error:nil]&&Lookups==before,@"foreign owner rejected before OS lookup");
   bad=profile.mutableCopy;bad[@"containerId"]=@"sibling";
   Check(![manager writeGateControlPlist:lease profile:bad name:@"com.redditbox.network-lease.plist" error:nil],@"foreign container rejected");
   NSMutableDictionary *stale=lease.mutableCopy;stale[@"generation"]=@"old";
   Check(![manager writeGateControlPlist:stale profile:profile name:@"com.redditbox.firewall-status.plist" error:nil],@"stale generation rejected");
  }
  NSDictionary *lease=Lease(descriptor,@"closed");[lease writeToFile:LeasePath atomically:YES];
  Owned=NO;Check(![manager writeGateControlPlist:lease profile:profile name:@"com.redditbox.network-lease.plist" error:nil],@"unproven OS home rejected");Owned=YES;
 }
 printf("PASS %lu actual clone gate writer assertions\n",(unsigned long)Checks);
}return 0;}
'''.replace('__METHOD__',method)
with tempfile.TemporaryDirectory(prefix='sbx-clone-writer-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incompatible-pointer-types','-Wno-nullability-completeness','-I'+str(ROOT/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),tmp],check=True)
