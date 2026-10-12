#!/usr/bin/env python3
"""Actual Registry deletion and durable journals with inert device/service providers."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXContainerRegistry.m').read_text()
start = source.index('- (BOOL)deleteContainer:')
method = source[start:source.index('\n}\n', start) + 3]
restore_start = source.index('static BOOL RBXRestoreDeletionEvidence(')
restore = source[restore_start:source.index('\n}\n', restore_start) + 3]
identity_start=source.index('- (NSDictionary *)deletionIdentityForContainer:')
identity=source[identity_start:source.index('\n}\n',identity_start)+3]
fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <dirent.h>
#import <string.h>
static NSString *FailAction, *FailPhase;
static BOOL FailOnce;
static NSMutableArray *Events;
static NSMutableDictionary *FixtureStore;
static NSString *FixtureStorePath;
static NSUInteger Checks;
static NSData *ReplaceDuringCleanup;
static NSString *ProfilePath(void);
static ssize_t FixtureWrite(int fd,const void *bytes,size_t length) {
    if(FailOnce && FailPhase) {
        id object=[NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:bytes length:length] options:0 format:NULL error:nil];
        if([object isKindOfClass:NSDictionary.class] && [object[@"phase"] isEqual:FailPhase]) { FailOnce=NO;errno=EIO;return -1; }
    }
    return write(fd,bytes,length);
}
#define RBX_REGISTRY_TESTING 1
#define RBX_REGISTRY_JOURNAL_TESTING 1
#define write FixtureWrite
#import "__REGISTRY__"
#undef write
__RESTORE__
static void Check(BOOL ok,NSString *message) {
    Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static BOOL RBXRegistryCheckOperation(BOOL mutation,NSError **error) {return YES;}
static BOOL Service(NSString *action,NSDictionary *descriptor,NSDictionary *target,NSError **error) {
    NSString *app=descriptor[@"appType"] ?: @"none";
    [Events addObject:[NSString stringWithFormat:@"%@:%@",action,app]];
    if(target && ![RBXAppDeletionTargetDescriptor(target) isEqual:descriptor]) {
        if(error)*error=RBXDeletionError(@"wrong app backend");return NO;
    }
    if(FailOnce && [FailAction isEqual:action]) {FailOnce=NO;if(error)*error=RBXDeletionError(@"synthetic service failure");return NO;}
    if([action isEqual:@"artifacts"] && ReplaceDuringCleanup)
        Check([ReplaceDuringCleanup writeToFile:ProfilePath() atomically:YES],@"concurrent owner replacement fixture written");
    return YES;
}
@implementation RBXOperationContext
+ (instancetype)currentContext {static id context;if(!context)context=[self new];return context;}
@end
@implementation RBXCloneManager
- (instancetype)init {return [self initWithAppType:@"reddit" operationContext:RBXOperationContext.currentContext];}
- (instancetype)initWithAppType:(NSString *)appType operationContext:(RBXOperationContext *)context {Check(context==RBXOperationContext.currentContext,@"deletion propagates current operation context");self=[super init];if(self)_appDescriptor=RBXAppDescriptorForType(appType);return self;}
- (NSDictionary *)prepareDeletionForProfile:(NSDictionary *)profile error:(NSError **)error {
    if(![RBXAppDescriptorForProfile(profile) isEqual:self.appDescriptor] || !Service(@"prepare",self.appDescriptor,nil,error))return nil;
    NSMutableDictionary *target=[RBXAppDeletionTargetIdentity(self.appDescriptor,profile[@"containerId"]) mutableCopy];target[@"transactions"]=@[];return target;
}
- (BOOL)eraseKeychainForDeletionTarget:(NSDictionary *)target error:(NSError **)error {return Service(@"erase",self.appDescriptor,target,error);}
- (BOOL)uninstallDeletionTarget:(NSDictionary *)target error:(NSError **)error {return Service(@"uninstall",self.appDescriptor,target,error);}
- (BOOL)cleanupArtifactsForDeletionTarget:(NSDictionary *)target error:(NSError **)error {return Service(@"artifacts",self.appDescriptor,target,error);}
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore {static id store; if(!store)store=[self new];return store;}
+ (NSString *)storePath {return FixtureStorePath;}
- (NSDictionary *)dictionary {return FixtureStore;}
- (NSDictionary *)dictionaryWithError:(NSError **)error {return FixtureStore;}
- (BOOL)update:(void (^)(NSMutableDictionary *))block error:(NSError **)error {block(FixtureStore);return YES;}
@end
@implementation RBXProxyManager
+ (BOOL)removeUpstreamForContainer:(NSString *)container error:(NSError **)error { [Events addObject:@"proxy"];return YES; }
@end
@implementation RBXRotationSecrets
+ (BOOL)removeProfile:(NSString *)container error:(NSError **)error { [Events addObject:@"rotation"];return YES; }
@end
@implementation RBXContainerRegistry
- (BOOL)_deletionIsClosed:(NSString *)container establish:(BOOL)establish error:(NSError **)error {
    [Events addObject:establish ? @"close-establish" : @"close-verify"];return YES;
}
- (BOOL)reserveIdentityForProfile:(NSDictionary *)profile error:(NSError **)error { [Events addObject:@"reserve"];return YES; }
__METHOD__
__IDENTITY__
@end
static NSString *ProfilePath(void){return [kProfilesDir stringByAppendingPathComponent:@"alpha.json"];}
static NSDictionary *Journal(void) {return [NSDictionary dictionaryWithContentsOfFile:[kDeletionRoot stringByAppendingPathComponent:@"alpha.plist"]];}
static void SaveRaw(NSData *data) {Check([data writeToFile:ProfilePath() options:NSDataWritingAtomic error:nil],@"raw fixture profile written");}
static void Setup(NSString *root,NSString *app,BOOL malformed) {
    NSString *base=[root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    kProfilesDir=[base stringByAppendingPathComponent:@"profiles"];kDeletionRoot=[base stringByAppendingPathComponent:@"deletions"];
    kDeletedContainerIds=[base stringByAppendingPathComponent:@"retired.plist"];kActiveBindingPath=[base stringByAppendingPathComponent:@"binding"];kLegacyDataRoots=@[];
    Check([NSFileManager.defaultManager createDirectoryAtPath:kProfilesDir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture roots created");
    FixtureStore=[@{@"containers":[@{@"alpha":@{@"appType":app},@"sibling":@{@"appType":@"reddit",@"untouched":@YES}} mutableCopy]} mutableCopy];
    FixtureStorePath=[base stringByAppendingPathComponent:@"store.json"];
    Check([[NSJSONSerialization dataWithJSONObject:FixtureStore options:0 error:nil] writeToFile:FixtureStorePath atomically:YES],@"stored owner fixture written");
    NSDictionary *profile=@{@"containerId":@"alpha",@"appType":app};
    SaveRaw(malformed ? [@"{malformed" dataUsingEncoding:NSUTF8StringEncoding] : [NSJSONSerialization dataWithJSONObject:profile options:0 error:nil]);
    FailAction=FailPhase=nil;FailOnce=NO;Events=[NSMutableArray array];
    ReplaceDuringCleanup=nil;
}
static BOOL Delete(void){NSError *error=nil;BOOL ok=[[RBXContainerRegistry new] deleteContainer:@"alpha" error:&error]; if(!ok && !FailAction && !FailPhase) fprintf(stderr,"deletion fixture: %s; events: %s\n",error.localizedDescription.UTF8String,Events.description.UTF8String);return ok;}
static void Complete(NSString *app) {
    Check([Journal()[@"phase"] isEqual:@"committed"] && !Journal()[@"profileEvidence"] && !Journal()[@"finalProfileEvidence"],@"committed tombstone drops private evidence only after cleanup");
    Check(![NSFileManager.defaultManager fileExistsAtPath:ProfilePath()] && !FixtureStore[@"containers"][@"alpha"],@"only target profile and store entry removed");
    Check([FixtureStore[@"containers"][@"sibling"][@"untouched"] isEqual:@YES],@"sibling store state preserved");
    Check([RBXAppDeletionJournalDescriptor(Journal())[@"appType"] isEqual:app],@"tombstone retains exact app owner");
}
int main(int argc,char **argv){@autoreleasepool{
    NSString *root=@(argv[1]);
    for(NSString *app in @[@"reddit",@"facebook"]) {
        Setup(root,app,NO);NSError *identityError=nil;Check(![[RBXContainerRegistry new] deletionIdentityForContainer:@"alpha" error:&identityError]&&!identityError,@"missing journal supplies no deletion identity");
        Check(Delete(),@"both apps can complete deletion through the matching backend");Complete(app);
        NSDictionary *identity=[[RBXContainerRegistry new] deletionIdentityForContainer:@"alpha" error:&identityError];
        Check([identity isEqual:RBXAppDeletionTargetIdentity(RBXAppDescriptorForType(app),@"alpha")],@"durable deletion exposes canonical ownership only, with no private profile/artifact evidence");
        Check(![[RBXContainerRegistry new] deletionIdentityForContainer:@"../alpha" error:&identityError]&&identityError,@"unsafe deletion identity request denied");
        Check([Events containsObject:[@"prepare:" stringByAppendingString:app]] && [Events containsObject:[@"erase:" stringByAppendingString:app]] &&
            [Events containsObject:[@"uninstall:" stringByAppendingString:app]] && [Events containsObject:[@"artifacts:" stringByAppendingString:app]],@"all service operations use selected app descriptor");
        NSUInteger before=Events.count;Check(Delete() && Events.count==before,@"committed retry does not repeat effects");
        for(NSString *action in @[@"prepare",@"erase",@"uninstall",@"artifacts"]) {
            Setup(root,app,NO);NSData *original=[NSData dataWithContentsOfFile:ProfilePath()];FailAction=action;FailOnce=YES;
            Check(!Delete() && [[NSData dataWithContentsOfFile:ProfilePath()] isEqual:original],@"failed service retains original profile bytes");
            if([action isEqual:@"erase"] || [action isEqual:@"prepare"])
                Check(![Events containsObject:[@"uninstall:" stringByAppendingString:app]],@"incomplete group cleanup cannot reach uninstall");
            if([action isEqual:@"uninstall"])Check([Journal()[@"phase"] isEqual:@"keychain-cleared"],@"uninstall failure retains cleared checkpoint");
            if([action isEqual:@"artifacts"])Check([Journal()[@"phase"] isEqual:@"uninstalled"],@"artifact failure retains uninstalled checkpoint");
            FailAction=nil;Check(Delete(),@"service recovery resumes retained app-owned checkpoint");Complete(app);
        }
        for(NSString *phase in @[@"prepared",@"keychain-cleared",@"uninstalled",@"cleanup-complete",@"committed"]) {
            Setup(root,app,NO);FailPhase=phase;FailOnce=YES;
            Check(!Delete(),@"checkpoint publication failure cannot report deletion success");
            Check([NSFileManager.defaultManager fileExistsAtPath:ProfilePath()],@"publication failure preserves or restores original profile");
            FailPhase=nil;Check(Delete(),@"checkpoint retry safely resumes same app");Complete(app);
        }
        Setup(root,app,YES);FailAction=@"erase";FailOnce=YES;
        Check(!Delete() && [Journal()[@"profileEvidence"] isEqual:[NSData dataWithContentsOfFile:ProfilePath()]],@"malformed profile keeps exact bytes and independently stored app owner");
        FailAction=nil;Check(Delete(),@"malformed profile can finish cleanup using stored ownership");Complete(app);
        for(NSNumber *malformed in @[@NO,@YES]) {
            Setup(root,app,NO);FailAction=@"erase";FailOnce=YES;Check(!Delete(),@"retain deletion before replacement evidence fixture");FailAction=nil;
            NSString *other=[app isEqual:@"reddit"] ? @"facebook" : @"reddit";
            NSData *replacement=malformed.boolValue ? [@"{new-unowned-bytes" dataUsingEncoding:NSUTF8StringEncoding]
                : [NSJSONSerialization dataWithJSONObject:@{@"containerId":@"alpha",@"appType":other} options:0 error:nil];
            SaveRaw(replacement);[Events removeAllObjects];
            Check(!Delete() && [[NSData dataWithContentsOfFile:ProfilePath()] isEqual:replacement],@"resumed deletion cannot erase a foreign or newly unowned profile");
            Check(![Events containsObject:[@"erase:" stringByAppendingString:app]] && ![Events containsObject:[@"uninstall:" stringByAppendingString:app]],@"changed ownership stops before replaying service effects");
            Setup(root,app,NO);ReplaceDuringCleanup=replacement;
            Check(!Delete() && [[NSData dataWithContentsOfFile:ProfilePath()] isEqual:replacement],@"final removal revalidates profile ownership after service operations");
            Check([Journal()[@"phase"] isEqual:@"cleanup-complete"] && !Journal()[@"finalProfileEvidence"],@"new foreign bytes are not adopted as owned recovery evidence");
        }
    }
    Setup(root,@"facebook",NO);
    SaveRaw([NSJSONSerialization dataWithJSONObject:@{@"containerId":@"alpha",@"appType":@"unknown"} options:0 error:nil]);
    Check(!Delete() && !Journal() && ![Events containsObject:@"prepare:reddit"] && ![Events containsObject:@"prepare:facebook"],@"unknown explicit owner never falls back to another app");
    Setup(root,@"facebook",YES);FixtureStore[@"containers"]=[NSMutableDictionary dictionary];
    Check([[@"{}" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:FixtureStorePath atomically:YES],@"remove independent owner evidence");
    Check(!Delete() && !Journal(),@"unparseable profile with no independent owner cannot guess a deletion app");
    Setup(root,@"facebook",NO);FixtureStore[@"containers"][@"alpha"]=@{@"appType":@"reddit"};
    Check(!Delete() && !Journal() && ![Events containsObject:@"prepare:facebook"],@"conflicting stored and profile owners stop before backend work");
    Check([NSFileManager.defaultManager removeItemAtPath:root error:nil],@"only temporary fixture files removed");
    printf("PASS: %lu actual per-app deletion orchestration assertions\n",(unsigned long)Checks);return 0;
}}
'''.replace('__REGISTRY__', str(ROOT / 'daemon/RBXContainerRegistry.m')).replace('__METHOD__', method).replace('__RESTORE__', restore).replace('__IDENTITY__',identity)
with tempfile.TemporaryDirectory(prefix='socialbox-deletion-flow-') as directory:
    build = Path(directory)
    (build / 'test.m').write_text(fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incomplete-implementation',
                    '-Wno-nullability-completeness', '-Wno-incompatible-pointer-types', '-Wno-objc-property-implementation',
                    '-I' + str(ROOT / 'shared'), '-I' + str(ROOT / 'daemon'), '-framework', 'Foundation',
                    '-framework', 'Security', str(build / 'test.m'), str(ROOT / 'daemon/RBXProfileIO.m'),
                    '-o', str(build / 'test')], check=True)
    subprocess.run([str(build / 'test'), str(build / 'data')], check=True)
