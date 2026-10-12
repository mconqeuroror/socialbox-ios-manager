#!/usr/bin/env python3
"""Execute the daemon's actual profile-owner collection before cloud dispatch."""
from pathlib import Path
import tempfile,subprocess,shutil
ROOT=Path(__file__).resolve().parents[1]
s=(ROOT/'daemon/main.m').read_text();start=s.index('    NSMutableArray *scopedProfiles =',s.index('static void handleQueuedRequest('));end=s.index('    NSString *appBlock',start)
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXAppAdmission.h"
#import "RBXProfileIO.h"
@implementation RBXProfileIO
+ (BOOL)isSafeContainerIdentifier:(id)value{return [value isKindOfClass:NSString.class]&&[value length]>0;}
+ (NSDictionary *)loadProfileForContainer:(NSString *)cid error:(NSError **)error{return [cid isEqual:@"rd"]?@{@"appType":@"reddit"}:([cid isEqual:@"fb"]?@{@"appType":@"facebook"}:nil);}
+ (NSDictionary *)readProfileOwnershipForContainer:(NSString *)cid error:(NSError **)error{return [cid isEqual:@"broken-fb"]?@{@"appType":@"facebook"}:nil;}
@end
static NSString *Admission(NSDictionary *pending){
__COLLECTION__
 return RBXAppRequestBlockReason(pending,scopedProfiles);
}
int main(void){@autoreleasepool{
 for(NSString *key in @[@"container",@"containerId",@"from"]){
  NSCAssert(!Admission(@{@"action":@"export",@"appType":@"reddit",key:@"rd"}),@"Reddit export unchanged");
  NSCAssert(Admission(@{@"action":@"export",@"appType":@"reddit",key:@"fb"}),@"Every container alias checks persisted app ownership");
  NSCAssert(Admission(@{@"action":@"export",@"appType":@"reddit",key:@"broken-fb"}),@"Malformed profile retains ownership gate");
  NSCAssert(!Admission(@{@"action":@"export",@"appType":@"facebook",key:@"fb"}),@"Active fixture Facebook can export only its own profile");
 }
 puts("PASS actual daemon dispatch ownership: all three aliases and malformed-owner fallback");return 0;
}}
'''.replace('__COLLECTION__',s[start:end])
with tempfile.TemporaryDirectory(prefix='rbx-cloud-admission-') as tmp:
 p=Path(tmp);shutil.copytree(ROOT/'shared',p/'shared');data=p/'shared/RBXAppRegistryData.h';data.write_text(data.read_text().replace('@"runnable": @NO','@"runnable": @YES'));(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-Wno-incomplete-implementation','-Wno-incompatible-pointer-types','-I'+str(p/'shared'),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
