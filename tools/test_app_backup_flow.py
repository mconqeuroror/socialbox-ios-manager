#!/usr/bin/env python3
"""Actual backup manifest and worker reconstruction with inert service boundaries.

Temporary files hold synthetic profiles. Catalog/generator, clone services and
final consistency validation are replaced; schema decoding and worker mutations
are shipped code. An active registry copy is confined to the test build.
"""
from pathlib import Path
import subprocess,tempfile,shutil
ROOT=Path(__file__).resolve().parents[1];src=(ROOT/'daemon/RBXCloudSync.m').read_text()
def code(sig):
 i=src.index(sig);return src[i:src.index('\n}\n',i)+3]
helpers='\n'.join(code(s) for s in ['static NSError *RBXCloudInputError(', 'static BOOL RBXCloudOptionalStrings(', 'static BOOL RBXCloudValidateManifest('])
if 'static NSDictionary *RBXCloudBackupDescriptor(' in src:
 helpers=code('static NSDictionary *RBXCloudBackupDescriptor(')+'\n'+helpers
fixture=r'''
#import <Foundation/Foundation.h>
#import "RBXCloudSync.h"
#import "RBXProfileIO.h"
#import "RBXProfileGenerator.h"
#import "RBXContainerRegistry.h"
#import "RBXCloneManager.h"
#import "RBXDeviceCatalog.h"
#import "RBXOperationContext.h"
#import "RBXAppRegistry.h"
#import "RBXAppProfileIdentity.h"
static NSString *kProfilesDir;
static NSUInteger Checks,Generations,Writes;
static BOOL Allowed=YES,ValidationOK=YES,WriteOK=YES;
static NSString *GeneratedApp;
static RBXOperationContext *Context;
static void Check(BOOL b,NSString *m){Checks++;if(!b){fprintf(stderr,"FAIL: %s\n",m.UTF8String);exit(1);}}
static NSString *Path(NSString *cid){return [kProfilesDir stringByAppendingPathComponent:[cid stringByAppendingString:@".json"]];}
static NSError *Failure(void){return [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];}
@implementation RBXOperationContext
+ (instancetype)currentContext{return Context;}
@end
static BOOL RBXCloudCheck(RBXOperationContext *c,NSError **e){if(c&&Allowed)return YES;if(e)*e=Failure();return NO;}
static BOOL RBXCloudProfileAvailable(NSString *cid,NSError **e){BOOL ok=[RBXProfileIO isSafeContainerIdentifier:cid];if(!ok&&e)*e=Failure();return ok;}
static BOOL RBXCloudWriteProfile(NSDictionary *p,NSString *cid,BOOL mode,NSError **e){Writes++;Check(!mode,@"restore never requests profile overwrite");if(!WriteOK){if(e)*e=Failure();return NO;}return [[NSJSONSerialization dataWithJSONObject:p options:0 error:e] writeToFile:Path(cid) atomically:YES];}
static NSString *RBXCloudString(NSDictionary *p,NSString *key){return [p[key] isKindOfClass:NSString.class]?p[key]:nil;}
static NSDictionary *RBXBuildMGOverrides(NSDictionary *p){return @{@"fixture":@"derived"};}
@implementation RBXProfileGenerator
+ (NSDictionary *)generateProfileForContainerId:(NSString *)cid proxyCountry:(NSString *)country existingProfiles:(NSArray *)existing error:(NSError **)e{return [self generateProfileForContainerId:cid appType:@"reddit" proxyCountry:country existingProfiles:existing error:e];}
+ (NSDictionary *)generateProfileForContainerId:(NSString *)cid appType:(NSString *)app proxyCountry:(NSString *)country existingProfiles:(NSArray *)existing error:(NSError **)e{Generations++;GeneratedApp=app;NSMutableDictionary *p=[@{@"containerId":cid,@"device":@{},@"serials":@{},@"ids":@{},@"timing":@{},@"reddit":@{@"installId":@"fresh-generated"},@"security":@{@"appAttest":@"blocked",@"deviceCheck":@"blocked"}} mutableCopy];if(![app isEqual:@"reddit"])p[@"appType"]=app;return p;}
@end
@implementation RBXDeviceCatalog
+ (NSArray *)carriersForCountry:(NSString *)country{return @[];}
+ (NSDictionary *)modelForProductType:(NSString *)s{return nil;}
+ (NSString *)regionSuffixForCountry:(NSString *)s{return @"LL/A";}
+ (NSString *)buildForIOS:(NSString *)s{return @"fixture";}
+ (NSString *)darwinForIOS:(NSString *)s{return @"fixture";}
@end
@implementation RBXContainerRegistry
- (NSDictionary *)validatedImportedProfile:(NSDictionary *)p error:(NSError **)e{if(!ValidationOK||[NSFileManager.defaultManager fileExistsAtPath:Path(p[@"containerId"])]){if(e)*e=Failure();return nil;}return p;}
@end
@implementation RBXCloneManager
- (instancetype)init{return [self initWithAppType:@"reddit" operationContext:Context];}
- (instancetype)initWithAppType:(NSString *)app operationContext:(RBXOperationContext *)c{self=[super init];if(self){_appDescriptor=RBXAppDescriptorForType(app);Check(c==Context,@"clone lookup retains operation ownership");}return self;}
- (NSString *)dataContainerForBundleIdentifier:(NSString *)b{return RBXAppOwnsCloneBundleIdentifier(self.appDescriptor,b)?[self.appDescriptor[@"appType"] stringByAppendingString:@"-sandbox"]:nil;}
@end
__HELPERS__
@interface RBXCloudSync (Fixture)
- (NSString *)_writeWorkerProfileForOrigId:(NSString *)origId newId:(NSString *)newId proxyURL:(NSString *)url proxyCountry:(NSString *)country manifest:(NSDictionary *)manifest;
- (NSString *)_dataContainerForProfile:(NSDictionary *)profile;
@end
@implementation RBXCloudSync
__WRITE__
__LOCATE__
@end
static NSMutableDictionary *Manifest(NSString *app){
 NSMutableDictionary *p=[@{@"containerId":@"old",@"device":@{@"deviceName":@"original"},@"ids":@{@"idfa":@"old-idfa",@"idfv":@"old-idfv"},@"serials":@{@"udid":@"old-udid"},@"timing":@{@"syntheticBootEpoch":@"100"},@"security":@{@"appAttest":@"blocked",@"deviceCheck":@"blocked"},@"identityCustomization":@{@"mode":@"manual"}} mutableCopy];
 NSMutableDictionary *m=[@{@"containerId":@"old",@"profile":p,@"profileSeed":@{}} mutableCopy];
 if([app isEqual:@"reddit"])p[@"reddit"]=@{@"installId":@"old-install",@"externalInstallationId":@"old-external"};
 else {p[@"appType"]=app;p[@"facebook"]=@{@"fixtureOpaqueState":@"preserved"};m[@"schemaVersion"]=@2;m[@"appType"]=app;m[@"sourceBundleIdentifier"]=RBXAppDescriptorForType(app)[@"sourceBundleIdentifier"];m[@"restorePolicy"]=@"same-logical-identity-new-local-container-v1";m[@"profileSeed"]=@{@"appType":app};m[@"credentialTransfer"]=@{@"appData":@"included",@"keychain":@"not-exported",@"deviceBoundKeys":@"not-transferable",@"loginPreserved":@NO,@"requiresLoginVerification":@YES};}
 return m;
}
static NSMutableDictionary *Copy(NSDictionary *v){return [NSJSONSerialization JSONObjectWithData:[NSJSONSerialization dataWithJSONObject:v options:0 error:nil] options:NSJSONReadingMutableContainers error:nil];}
int main(int argc,char **argv){@autoreleasepool{kProfilesDir=@(argv[1]);Context=[RBXOperationContext new];RBXCloudSync *cloud=[RBXCloudSync new];
for(NSString *app in @[@"reddit",@"facebook"]){
 NSDictionary *d=RBXAppDescriptorForType(app);NSMutableDictionary *m=Manifest(app);NSError *e=nil;NSData *before=[NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingSortedKeys error:nil];
 Check(RBXCloudValidateManifest(m,@"old",&e)&&!e,@"registered app with exact authenticated ownership accepted");
 Check([before isEqual:[NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingSortedKeys error:nil]],@"manifest validation cannot mutate archived bytes");
 NSString *newId=[app stringByAppendingString:@"-restored"];Check(![cloud _writeWorkerProfileForOrigId:@"old" newId:newId proxyURL:@"http://127.0.0.1:9999" proxyCountry:@"US" manifest:m],@"worker profile reconstructed");
 NSDictionary *p=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Path(newId)] options:0 error:nil];Check([RBXAppDescriptorForProfile(p) isEqual:d]&&[GeneratedApp isEqual:app],@"selected app survives base generation and profile publication");
 for(NSString *key in @[@"device",@"ids",@"serials",@"timing",@"security",@"identityCustomization",app])Check([p[key] isEqual:m[@"profile"][key]],@"same logical identity retains archived configuration bytes");
 Check(!p[@"app"]&&!p[@"installationTransaction"]&&!p[@"authorization"]&&[p[@"containerId"] isEqual:newId],@"new worker does not inherit old clone/transaction/authorization metadata");
 if([app isEqual:@"reddit"])Check(!p[@"appType"],@"Reddit generated document keeps its legacy shape");
 Check([before isEqual:[NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingSortedKeys error:nil]],@"worker reconstruction leaves source manifest unchanged");
 NSUInteger count=Writes;e=nil;Check([cloud _writeWorkerProfileForOrigId:@"old" newId:newId proxyURL:@"" proxyCountry:@"US" manifest:m]&&Writes==count,@"existing destination never overwritten");
 NSMutableDictionary *installed=[m[@"profile"] mutableCopy];NSString *bundle=RBXAppBundleIdentifier(d,@"old");NSMutableDictionary *meta=[@{@"bundleIdentifier":bundle,@"keychainAccessGroup":RBXAppKeychainGroup(d,bundle)} mutableCopy];[meta addEntriesFromDictionary:RBXAppKeychainMetadata(d,bundle)];installed[@"app"]=meta;
 Check([[cloud _dataContainerForProfile:installed] isEqual:[app stringByAppendingString:@"-sandbox"]],@"sandbox lookup uses owning app manager");installed[@"containerId"]=@"foreign";Check(![cloud _dataContainerForProfile:installed],@"mismatched container cannot redirect sandbox lookup");
 for(NSString *fault in @[@"cancel",@"validation",@"write"]){Allowed=![fault isEqual:@"cancel"];ValidationOK=![fault isEqual:@"validation"];WriteOK=![fault isEqual:@"write"];NSString *cid=[NSString stringWithFormat:@"%@-%@",app,fault];Check([cloud _writeWorkerProfileForOrigId:@"old" newId:cid proxyURL:@"" proxyCountry:@"US" manifest:m]&&![NSFileManager.defaultManager fileExistsAtPath:Path(cid)],@"failure cannot publish a destination profile");}Allowed=ValidationOK=WriteOK=YES;
 for(NSString *where in @[@"manifest",@"profile",@"profileSeed"]){NSMutableDictionary *bad=Copy(m);NSMutableDictionary *scope=[where isEqual:@"manifest"]?bad:bad[where];scope[@"appType"]=[app isEqual:@"reddit"]?@"facebook":@"reddit";e=nil;NSUInteger g=Generations;Check(!RBXCloudValidateManifest(bad,@"old",&e)&&e,@"cross-app envelope/profile/seed disagreement rejected");Check([cloud _writeWorkerProfileForOrigId:@"old" newId:@"bad" proxyURL:@"" proxyCountry:@"US" manifest:bad]&&Generations==g,@"invalid ownership rejected before generation or writes");}
}
NSDictionary *fb=Manifest(@"facebook");
for(NSString *key in @[@"schemaVersion",@"appType",@"sourceBundleIdentifier",@"restorePolicy",@"profile",@"profileSeed",@"credentialTransfer"]){NSMutableDictionary *bad=Copy(fb);[bad removeObjectForKey:key];NSError *e=nil;Check(!RBXCloudValidateManifest(bad,@"old",&e)&&e,@"Facebook requires complete explicit restore contract");}
for(id version in @[@YES,@"2",@1,@3,NSNull.null]){NSMutableDictionary *bad=Copy(fb);bad[@"schemaVersion"]=version;Check(!RBXCloudValidateManifest(bad,@"old",nil),@"Facebook rejects unsupported or untyped schema versions");}
for(NSString *key in @[@"keychain",@"deviceBoundKeys",@"loginPreserved",@"requiresLoginVerification"]){NSMutableDictionary *bad=Copy(fb);bad[@"credentialTransfer"][key]=@"invalid";Check(!RBXCloudValidateManifest(bad,@"old",nil),@"Facebook cannot claim transferable device credentials or preserved login");}
printf("PASS: %lu actual app backup/worker assertions\n",(unsigned long)Checks);return 0;}}
'''.replace('__HELPERS__',helpers).replace('__WRITE__',code('- (NSString *)_writeWorkerProfileForOrigId:')).replace('__LOCATE__',code('- (NSString *)_dataContainerForProfile:'))
if __name__ == "__main__":
 with tempfile.TemporaryDirectory(prefix='socialbox-backup-') as tmp:
  p=Path(tmp);shared=p/'shared';shutil.copytree(ROOT/'shared',shared)
  data=(shared/'RBXAppRegistryData.h').read_text();assert data.count('@"runnable": @NO')==1
  (shared/'RBXAppRegistryData.h').write_text(data.replace('@"runnable": @NO','@"runnable": @YES'))
  (p/'test.m').write_text(fixture)
  # Copy the decoder so its quoted shared imports resolve to the temporary registry too.
  (p/'RBXProfileIO.m').write_text((ROOT/'daemon/RBXProfileIO.m').read_text())
  subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-objc-property-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-I'+str(shared),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),str(p/'RBXProfileIO.m'),'-o',str(p/'test')],check=True)
  subprocess.run([str(p/'test'),str(p/'profiles')],check=True)
