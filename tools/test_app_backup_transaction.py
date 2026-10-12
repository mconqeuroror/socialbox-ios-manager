#!/usr/bin/env python3
"""Actual post-decryption import transaction and export envelope, synthetic services.

Uses the real worker writer, manifest/schema validation and restore file copier.
Crypto, HTTP, extraction, OS installation, proxy and central-store durability are
inert boundaries; these tests cannot prove device state or credential transfer.
"""
from pathlib import Path
import subprocess,tempfile,shutil,runpy
ROOT=Path(__file__).resolve().parents[1]
base=runpy.run_path(str(ROOT/'tools/test_app_backup_flow.py'));source=base['src'];fixture=base['fixture'];code=base['code']
start=source.index('    // Public list metadata is not the authority for decrypted app ownership.')
end=source.index('\n}\n',start)+3
transaction='''- (BOOL)importFixture:(NSDictionary *)manifest archive:(NSData *)archive context:(RBXOperationContext *)context message:(NSString **)message {
 NSString *expectedAppType=ExpectedApp;NSError *err=nil;NSDictionary *chosen=@{@"containerId":@"old",@"id":@"backup-fixture"};
'''+source[start:end]
start=source.index('    NSDictionary *profileSeed = @{',source.index('- (BOOL)_exportContainer:'))
end=source.index('    NSData *plaintext = ',start)
envelope='''static NSDictionary *ExportEnvelope(NSDictionary *profile) {
 NSDictionary *descriptor=RBXAppDescriptorForProfile(profile),*cont=@{};NSString *container=profile[@"containerId"],*failure=nil;NSString * __strong *message=&failure;NSError *stageError=nil;NSData *archive=[@"synthetic-archive" dataUsingEncoding:NSUTF8StringEncoding];RBXCentralStore *_store=[RBXCentralStore new];
'''+source[start:end]+'''return envelope;
}
'''
additions=r'''
#import "RBXCentralStore.h"
#import "RBXBackupSnapshot.h"
#import "RBXAppVersionMonitor.h"
#import "RBXProfileTransport.h"
#import "RBXProfileMetadata.h"
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
static NSString *Fail,*Destination,*Stage,*ExpectedApp;
static NSMutableArray *Events;
static NSMutableDictionary *Document;
static BOOL TamperAfterInstall,TamperAfterSync;
static BOOL Step(NSString *event,NSError **error){[Events addObject:event];if([Fail isEqual:event]){if(error)*error=Failure();return NO;}return YES;}
static NSMutableDictionary *RBXCloudReadPlist(void){return [NSMutableDictionary dictionary];}
static NSDictionary *RBXCloudLoadProfile(NSString *cid,NSError **error){return [RBXProfileIO profileDictionaryFromData:[NSData dataWithContentsOfFile:Path(cid)] containerId:cid error:error];}
static BOOL RBXCloudIsDir(NSString *p){BOOL dir=NO;return p&&[NSFileManager.defaultManager fileExistsAtPath:p isDirectory:&dir]&&dir;}
static NSString *FixtureTempDirectory(void){return kProfilesDir.stringByDeletingLastPathComponent;}
static BOOL RBXCloudPrepareStage(NSString *path,NSString *cid,NSString *mode,RBXOperationContext *c,NSError **error){Stage=path;Destination=cid;Check([mode isEqual:@"import"],@"restore stage owns import operation");if(!Step(@"stage",error))return NO;return [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error];}
static BOOL RBXCloudUntar(NSString *archive,NSString *path,NSString *old,RBXOperationContext *c,NSError **error){if(!Step(@"extract",error))return NO;Check([old isEqual:@"old"],@"archive extraction binds original owner");NSString *docs=[path stringByAppendingPathComponent:@"AppData/Documents"];[NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:error];return [@"source-app-state" writeToFile:[docs stringByAppendingPathComponent:@"fixture.bin"] atomically:YES encoding:NSUTF8StringEncoding error:error];}
static BOOL RBXCloudQuiesce(RBXOperationContext *c,NSError **error){return Step(@"closed-all-stopped",error);}
static int FixtureChown(const char *p,uid_t u,gid_t g){return 0;}
#define lchown FixtureChown
__RESTORE__
#undef lchown
@implementation RBXCentralStore
- (BOOL)update:(void (^)(NSMutableDictionary *))b error:(NSError **)error{if(!Step(@"publish",error))return NO;b(Document);return YES;}
- (void)addAlertType:(NSString *)t containerId:(NSString *)cid message:(NSString *)m{[Events addObject:@"alert"];}
- (NSString *)effectiveAttestModeForContainer:(NSString *)cid{return @"off";}
@end
@implementation RBXAppVersionMonitor
+ (NSString *)installedRedditVersion{return @"reddit-version-fixture";}
@end
@implementation RBXBackupSnapshot
+ (BOOL)validateDatabasesInTree:(NSString *)tree context:(RBXOperationContext *)c error:(NSError **)error{return Step(@"databases",error);}
@end
static void Tamper(NSString *cid){NSMutableDictionary *p=[RBXCloudLoadProfile(cid,nil) mutableCopy];p[@"appType"]=[ExpectedApp isEqual:@"reddit"]?@"facebook":@"reddit";[p removeObjectForKey:@"app"];[[NSJSONSerialization dataWithJSONObject:p options:0 error:nil] writeToFile:Path(cid) atomically:YES];}
'''.replace('__RESTORE__',code('static BOOL RBXCloudRestoreDataContents('))
# Inject after fixture helpers/production validator, before implementations that use them.
index=fixture.index('@implementation RBXProfileGenerator');fixture=fixture[:index]+additions.replace('__UNUSED__','')+fixture[index:]
# RBXCloudInputError is needed by the actual copier before its later definition.
fixture=fixture.replace('#import "RBXCentralStore.h"','static NSError *RBXCloudInputError(NSString *m);\n#import "RBXCentralStore.h"',1)
registry=r'''
- (BOOL)ensureAppCloneForContainer:(NSString *)cid error:(NSError **)error{
 Check([Events containsObject:@"closed-all-stopped"],@"global closure precedes clone install");NSDictionary *d=RBXAppDescriptorForProfile(RBXCloudLoadProfile(cid,error));Check([d[@"appType"] isEqual:ExpectedApp],@"installed worker is selected app");
 NSMutableDictionary *p=[RBXCloudLoadProfile(cid,error) mutableCopy];NSString *b=RBXAppBundleIdentifier(d,cid);NSMutableDictionary *a=[@{@"bundleIdentifier":b,@"keychainAccessGroup":RBXAppKeychainGroup(d,b)} mutableCopy];[a addEntriesFromDictionary:RBXAppKeychainMetadata(d,b)];p[@"app"]=a;[[NSJSONSerialization dataWithJSONObject:p options:0 error:nil] writeToFile:Path(cid) atomically:YES];
 [NSFileManager.defaultManager createDirectoryAtPath:[kProfilesDir stringByAppendingPathComponent:cid] withIntermediateDirectories:YES attributes:nil error:nil];if(TamperAfterInstall)Tamper(cid);return Step(@"install",error);
}
- (BOOL)deleteContainer:(NSString *)cid error:(NSError **)error{Check([cid isEqual:Destination]&&! [cid isEqual:@"old"],@"rollback targets only newly allocated destination");Check([RBXAppDescriptorForProfile(RBXCloudLoadProfile(cid,nil))[@"appType"] isEqual:ExpectedApp],@"rollback never receives foreign-owned profile");if(!Step(@"rollback",error))return NO;[NSFileManager.defaultManager removeItemAtPath:Path(cid) error:nil];[NSFileManager.defaultManager removeItemAtPath:[kProfilesDir stringByAppendingPathComponent:cid] error:nil];return YES;}
'''
fixture=fixture.replace('return [[NSJSONSerialization dataWithJSONObject:p options:0 error:e] writeToFile:Path(cid) atomically:YES];}', 'BOOL wrote=[[NSJSONSerialization dataWithJSONObject:p options:0 error:e] writeToFile:Path(cid) atomically:YES];if(WriteUncertain&&wrote){if(e)*e=Failure();return NO;}return wrote;}')
fixture=fixture.replace('static BOOL Allowed=YES,ValidationOK=YES,WriteOK=YES;', 'static BOOL Allowed=YES,ValidationOK=YES,WriteOK=YES,WriteUncertain=NO;')
fixture=fixture.replace('@implementation RBXContainerRegistry' ,'@implementation RBXContainerRegistry\n'+registry)
a=fixture.index('- (NSString *)dataContainerForBundleIdentifier:');b=fixture.index('\n@end',a)
fixture=fixture[:a]+r'''
- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundle{return RBXAppOwnsCloneBundleIdentifier(self.appDescriptor,bundle)?[kProfilesDir stringByAppendingPathComponent:Destination]:nil;}
- (BOOL)syncProfile:(NSDictionary *)profile error:(NSError **)error{Check([RBXAppDescriptorForProfile(profile) isEqual:self.appDescriptor],@"clone sync uses matching app manager");if(TamperAfterSync)Tamper(profile[@"containerId"]);return Step(@"sync",error);}
'''+fixture[b:]
extra=r'''
- (NSDictionary *)_loadProfile:(NSString *)cid error:(NSError **)e{return RBXCloudLoadProfile(cid,e);}
- (BOOL)_checkProxyContinuity:(NSString *)url proxyCountry:(NSString *)country seedLocale:(NSString *)locale seedTimezone:(NSString *)tz error:(NSError **)e{Check([locale isEqual:@"en_US"]&&[tz isEqual:@"America/New_York"],@"proxy continuity uses archived app profile location");return Step(@"proxy",e);}
'''
fixture=fixture.replace('@interface RBXCloudSync (Fixture)','@interface RBXCloudSync ()\n@property(nonatomic) RBXCentralStore *store;\n- (BOOL)importFixture:(NSDictionary *)m archive:(NSData *)a context:(RBXOperationContext *)c message:(NSString **)message;\n@end\n@interface RBXCloudSync (Fixture)')
fixture=fixture.replace('@implementation RBXCloudSync','@implementation RBXCloudSync\n'+extra+'\n#define NSTemporaryDirectory FixtureTempDirectory\n'+transaction+'\n#undef NSTemporaryDirectory\n')
index=fixture.index('int main(');fixture=fixture[:index]+envelope+r'''
static void Reset(NSString *root,NSString *app){[NSFileManager.defaultManager removeItemAtPath:root error:nil];[NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];kProfilesDir=[root stringByAppendingPathComponent:@"profiles"];[NSFileManager.defaultManager createDirectoryAtPath:kProfilesDir withIntermediateDirectories:YES attributes:nil error:nil];Events=[NSMutableArray array];Document=[NSMutableDictionary dictionary];Destination=Stage=Fail=nil;ExpectedApp=app;Allowed=ValidationOK=WriteOK=YES;WriteUncertain=NO;TamperAfterInstall=TamperAfterSync=NO;}
static NSMutableDictionary *Ready(NSString *app){NSMutableDictionary *m=Manifest(app);m[@"schemaVersion"]=[app isEqual:@"reddit"]?@1:@2;m[@"profile"][@"device"]=@{@"locale":@"en_US",@"timezone":@"America/New_York"};m[@"profile"][@"proxy"]=@{@"url":@"http://127.0.0.1:9999",@"country":@"US"};return m;}
int main(int argc,char **argv){@autoreleasepool{NSString *root=@(argv[1]);Context=[RBXOperationContext new];RBXCloudSync *cloud=[RBXCloudSync new];cloud.store=[RBXCentralStore new];
for(NSString *app in @[@"reddit",@"facebook"]){
 Reset(root,app);NSMutableDictionary *m=Ready(app);NSString *message=nil;NSData *archive=[@"synthetic archive" dataUsingEncoding:NSUTF8StringEncoding];
 Check([cloud importFixture:m archive:archive context:Context message:&message],@"complete actual post-decryption restore transaction succeeds");
 Check([Document[@"containers"][Destination][@"appType"] isEqual:[app isEqual:@"reddit"]?nil:app] || ([app isEqual:@"reddit"]&&!Document[@"containers"][Destination][@"appType"]),@"central store retains app without changing legacy Reddit shape");
 NSDictionary *entry=Document[@"containers"][Destination];Check([entry[@"identityFrozenAt"] doubleValue]>0&&[entry[@"requiresLoginVerification"] boolValue]&&![entry[@"loginKnown"] boolValue],@"restored identity frozen and login remains unverified");
 if([app isEqual:@"facebook"])Check([entry[@"attest"][@"mode"] isEqual:@"off"],@"blocked Facebook attest policy survives worker registration");
 Check([[NSString stringWithContentsOfFile:[[kProfilesDir stringByAppendingPathComponent:Destination] stringByAppendingPathComponent:@"Documents/fixture.bin"] encoding:NSUTF8StringEncoding error:nil] isEqual:@"source-app-state"],@"actual restore copier preserves app data bytes");
 Check(!RBXCloudIsDir(Stage)&&![Events containsObject:@"rollback"],@"successful import removes staging without rollback");
 NSDictionary *exported=ExportEnvelope(m[@"profile"]);Check(exported&&RBXCloudValidateManifest(exported,@"old",nil),@"actual export envelope round-trips manifest validation");
 if([app isEqual:@"facebook"]){Check([exported[@"profileSeed"] isEqual:@{@"appType":@"facebook"}],@"Facebook full profile is sole identity seed authority");Check([exported[@"appVersion"] isEqual:@""],@"missing Facebook version never substitutes Reddit version");}
 else Check([exported[@"schemaVersion"] isEqual:@1]&&!exported[@"appType"]&&!exported[@"restorePolicy"],@"Reddit envelope identity shape remains unchanged");
 for(NSString *fault in @[@"proxy",@"stage",@"extract",@"databases",@"closed-all-stopped",@"install",@"sync",@"publish"]){Reset(root,app);Fail=fault;message=nil;BOOL ok=[cloud importFixture:Ready(app) archive:archive context:Context message:&message];Check(!ok&&message.length&&!Document[@"containers"][Destination?:@""],@"service failure never publishes successful restore");if([@[@"install",@"sync",@"publish"] containsObject:fault])Check([Events containsObject:@"rollback"]&&![NSFileManager.defaultManager fileExistsAtPath:Path(Destination)],@"post-write failure cleans only owned new candidate");}
 Reset(root,app);WriteUncertain=YES;message=nil;Check(![cloud importFixture:Ready(app) archive:archive context:Context message:&message],@"uncertain profile write cannot report success");Check([NSFileManager.defaultManager fileExistsAtPath:Path(Destination)]&&RBXCloudIsDir(Stage)&&![Events containsObject:@"rollback"],@"uncertain publication retains profile and durable stage for recovery");
 for(NSNumber *afterSync in @[@NO,@YES]){Reset(root,app);TamperAfterInstall=!afterSync.boolValue;TamperAfterSync=afterSync.boolValue;message=nil;Check(![cloud importFixture:Ready(app) archive:archive context:Context message:&message],@"foreign candidate substitution blocks restore");Check(![Events containsObject:@"rollback"]&&[NSFileManager.defaultManager fileExistsAtPath:Path(Destination)]&&RBXCloudIsDir(Stage),@"foreign candidate and recovery evidence retained without deletion");}
 Reset(root,app);NSMutableDictionary *foreignManifest=Ready([app isEqual:@"reddit"]?@"facebook":@"reddit");Check(![cloud importFixture:foreignManifest archive:archive context:Context message:&message]&&!Events.count&&!Destination,@"decrypted wrong-app backup rejected before any restore mutations");
 Reset(root,app);Allowed=NO;Check(![cloud importFixture:Ready(app) archive:archive context:Context message:&message]&&!Events.count,@"expired operation starts no work");
}
printf("PASS: %lu actual export/restore transaction assertions\n",(unsigned long)Checks);return 0;}}
'''
with tempfile.TemporaryDirectory(prefix='socialbox-restore-transaction-') as tmp:
 p=Path(tmp);shared=p/'shared';shutil.copytree(ROOT/'shared',shared)
 data=(shared/'RBXAppRegistryData.h').read_text();assert data.count('@"runnable": @NO')==1
 (shared/'RBXAppRegistryData.h').write_text(data.replace('@"runnable": @NO','@"runnable": @YES'))
 (p/'test.m').write_text(fixture);(p/'RBXProfileIO.m').write_text((ROOT/'daemon/RBXProfileIO.m').read_text())
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-objc-property-implementation','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-I'+str(shared),'-I'+str(ROOT/'daemon'),'-framework','Foundation',str(p/'test.m'),str(p/'RBXProfileIO.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test'),str(p/'profiles')],check=True)
