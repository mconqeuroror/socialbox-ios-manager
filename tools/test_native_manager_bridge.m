#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeManagerBridge.h"
#import "../lucid/Switching/LBXNativeSwitchCoordinator.h"
#import "../lucid/Switching/LBXNativeFamilyStorageLayout.h"
#import "../lucid/Switching/LBXNativeStorageLayout.h"
#import "../lucid/Switching/LBXNativeStorageInventory.h"
#import "../lucid/Switching/LBXNativeBrokerAuthority.h"
#import "../lucid/Switching/LBXNativeControlStore.h"
#import "../lucid/Switching/LBXNativeIsolationJournal.h"
#import "../lucid/Switching/LBXNativeInstalledManagerPin.h"
#import "../lucid/Switching/LBXNativeControlLayout.h"
#import <CommonCrypto/CommonDigest.h>
@implementation LBXNativeStorageInventory
+ (instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error {(void)journal;(void)error;return nil;}
- (BOOL)matchesCurrentRegistration:(NSError **)error {(void)error;return NO;}
+ (instancetype)observeOfficialInstagram:(NSError **)error {(void)error;return nil;}
+ (instancetype)observeOfficialFacebook:(NSError **)error {(void)error;return nil;}
- (NSDictionary *)privateDictionary {return @{};}
- (NSDictionary *)safeStatus {return @{};}
@end
static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSString *Join(NSString *a,NSString *b){return [a stringByAppendingPathComponent:b];}
static void Dir(NSString *p){Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"dir");}
static NSMutableDictionary *Node(NSString *parent,NSString *name,NSString *type,NSUInteger inode) {
    return [@{@"name":name,@"path":[parent stringByAppendingPathComponent:name],@"type":type,@"device":@1,@"inode":@(inode),@"uid":@501,@"gid":@501,@"mode":@0755,@"flags":@0,@"linkCount":@1} mutableCopy];
}
static NSDictionary *Snapshot(NSString *bundle,NSString *rootName,NSUInteger base,NSArray *cids) {
    NSString *path=[@"/private/test" stringByAppendingPathComponent:rootName],*lib=[path stringByAppendingPathComponent:@"Library"],*store=[lib stringByAppendingPathComponent:@"___SocialBox_Containers"];
    NSMutableArray *profiles=[NSMutableArray array];NSUInteger inode=base+10;for(NSString *cid in cids)[profiles addObject:Node(store,cid,@"directory",inode++)];
    return @{@"bundleIdentifier":bundle,@"layoutStatus":@"OBSERVED",@"owners":@[@{@"dataPath":path,@"groups":@{}}],
        @"storage":@{path:@{@"root":Node(@"/private/test",rootName,@"directory",base),@"rootEntries":@[Node(path,@"Library",@"directory",base+1)],@"libraryEntries":@[Node(lib,@"___SocialBox_Containers",@"directory",base+2)],
            @"profileStores":@[@{@"root":Node(lib,@"___SocialBox_Containers",@"directory",base+2),@"profiles":profiles,@"otherEntries":@[]}],@"layoutIssues":@[]}}};
}
@interface Journals:NSObject
@property NSString *base; @property LBXNativeSwitchCoordinator *coordinator;
@end
@implementation Journals
- (instancetype)init {
    if((self=[super init])){
        NSString *raw=Join(NSTemporaryDirectory(),[@"socialbox-bridge-" stringByAppendingString:NSUUID.UUID.UUIDString]);Dir(raw);
        char *p=realpath(raw.fileSystemRepresentation,NULL);_base=@(p);free(p);
        LBXNativeIsolationJournal *bj=[LBXNativeIsolationJournal testOpenDirectory:Join(_base,@"broker") create:YES error:nil];
        LBXNativeIsolationJournal *sj=[LBXNativeIsolationJournal testOpenDirectory:Join(_base,@"store") create:YES error:nil];
        LBXNativeIsolationJournal *cj=[LBXNativeIsolationJournal testOpenDirectory:Join(_base,@"coord") create:YES error:nil];
        _coordinator=[LBXNativeSwitchCoordinator testOpenJournal:cj broker:[LBXNativeBrokerAuthority testOpenJournal:bj error:nil] store:[LBXNativeControlStore testOpenJournal:sj error:nil] error:nil];
        [_coordinator testSetDrain:^BOOL(NSArray *apps,NSError **error){(void)error;return apps.count==2;}];
        [_coordinator testSetFence:^BOOL(NSString *cid,NSError **error){(void)cid;(void)error;return YES;}];
    }return self;
}
- (void)dealloc{[NSFileManager.defaultManager removeItemAtPath:_base error:nil];}
@end
static NSString *Hex(NSData *data){
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString string];for(unsigned i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];return hex;
}
static LBXNativeInstalledManagerPin *FixturePin(NSString *directory){
    NSString *file=[directory stringByAppendingPathComponent:@"SocialBox"];
    NSData *payload=[@"socialbox-bridge-manager-pin\n" dataUsingEncoding:NSUTF8StringEncoding];
    Check([payload writeToFile:file atomically:YES],@"pin fixture");
    Check([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:file error:nil],@"pin mode");
    return [LBXNativeInstalledManagerPin testObservePath:file expectedSHA256:Hex(payload) expectedSize:payload.length error:nil];
}
static void Touch(NSString *p){Check([@"\n" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil],@"control file");Check([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:p error:nil],@"control mode");}
static LBXNativeControlLayout *FixtureControl(NSString *directory){
    NSString *containers=Join(directory,@"Containers"),*runtime=Join(directory,@"runtime");
    Dir(containers);Dir(runtime);Dir(Join(containers,@"com.burbn.instagram"));Dir(Join(containers,@"com.facebook.Facebook"));
    Touch(Join(containers,@"global_metadata.plist"));
    Touch(Join(containers,@"com.burbn.instagram/metadata.plist"));
    Touch(Join(containers,@"com.facebook.Facebook/metadata.plist"));
    Touch(Join(runtime,@"com.burbn.instagram.plist"));
    Touch(Join(runtime,@"com.facebook.Facebook.plist"));
    return [LBXNativeControlLayout testObserveContainers:containers runtimePlists:runtime error:nil];
}
@interface LBXNativeFamilyApplicationGate : NSObject
@property(nonatomic,copy)NSDictionary *safeStatus;
@end
@implementation LBXNativeFamilyApplicationGate
- (instancetype)init {
    if((self=[super init])){
        _safeStatus=@{@"kind":@"native-family-application-gate",@"applications":@[@"com.burbn.instagram",@"com.facebook.Facebook"],@"isolationVerified":@NO,@"runtimeAccepted":@NO};
    }return self;
}
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error {(void)deadline;if(error)*error=nil;return YES;}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    (void)deadline;if(error)*error=nil;return authorization&&authorization();
}
@end
int main(void){@autoreleasepool{
    LBXNativeStorageLayout *ig=[LBXNativeStorageLayout testLayoutForSnapshot:Snapshot(@"com.burbn.instagram",@"IG",1,@[@"108",@"109"]) error:nil];
    LBXNativeStorageLayout *fb=[LBXNativeStorageLayout testLayoutForSnapshot:Snapshot(@"com.facebook.Facebook",@"FB",20,@[@"109"]) error:nil];
    LBXNativeFamilyStorageLayout *family=[LBXNativeFamilyStorageLayout layoutWithInstagram:ig facebook:fb error:nil];
    Journals *j=[Journals new];LBXNativeManagerBridge *bridge=[LBXNativeManagerBridge bridge];LBXNativeInstalledManagerPin *pin=FixturePin(j.base);
    Check(pin&&[pin.safeStatus[@"installedSwitchConnected"] isEqual:@NO],@"fixture pin is not an installed switch");
    double deadline=LBXNativeSwitchClock()+30;
    Check([j.coordinator attachFamilyLayout:family error:nil]&&[j.coordinator.safeStatus[@"familyLayoutAttached"] isEqual:@YES],@"coordinator carries family layout");
    LBXNativeControlLayout *control=FixtureControl(j.base);
    Check(control&&[j.coordinator attachControlLayout:control error:nil]&&[j.coordinator.safeStatus[@"familyControlLayoutAttached"] isEqual:@YES],@"coordinator carries family control layout");
    Check([j.coordinator attachFamilyApplicationGate:[LBXNativeFamilyApplicationGate new] error:nil]&&[j.coordinator.safeStatus[@"familyApplicationGateAttached"] isEqual:@YES],@"coordinator carries family execution gate");
    NSError *denied=nil;Check(![j.coordinator switchToContainerID:@"108" applicationIDs:@[@"com.burbn.instagram",@"com.facebook.Facebook"] familyGroupIdentity:@{@"device":@1,@"inode":@42} nonce:NSUUID.UUID.UUIDString.lowercaseString beforeDeadline:deadline authorization:^BOOL{return YES;} error:&denied]&&denied.code==3,@"coordinator refuses Instagram-only 108 before drain");
    NSDictionary *base=@{@"operation":@"switch",@"containerID":@"109",@"applications":@[@"com.burbn.instagram",@"com.facebook.Facebook"],@"familyGroupIdentity":@{@"device":@1,@"inode":@42},@"nonce":NSUUID.UUID.UUIDString.lowercaseString,@"generation":@1};
    Check([bridge.safeStatus[@"invokedOriginalSwitchWorker"] isEqual:@NO]&&[bridge.safeStatus[@"managerPinVerified"] isEqual:@NO],@"bridge starts without original worker or pin");
    NSDictionary *missing=[bridge dispatchRequest:base coordinator:j.coordinator familyLayout:family managerPin:nil beforeDeadline:deadline];
    Check([missing[@"reason"] isEqual:@"manager-pin-required"]&&[missing[@"installedSwitchConnected"] isEqual:@NO],@"switch without original-manager pin is refused");
    NSDictionary *create=[bridge dispatchRequest:@{@"operation":@"create",@"generation":@1} coordinator:j.coordinator familyLayout:family managerPin:pin beforeDeadline:deadline];
    Check([create[@"result"] isEqual:@"refused"]&&[create[@"reason"] isEqual:@"unsupported-operation"]&&[create[@"invokedOriginalSwitchWorker"] isEqual:@NO],@"create never reaches the old switch worker");
    NSDictionary *pid=[bridge dispatchRequest:@{@"operation":@"switch",@"pid":@1,@"generation":@1} coordinator:j.coordinator familyLayout:family managerPin:pin beforeDeadline:deadline];
    Check([pid[@"reason"] isEqual:@"caller-supplied-capability"],@"PID is not a switch permit");
    NSDictionary *stale=[bridge dispatchRequest:base coordinator:j.coordinator familyLayout:family managerPin:pin beforeDeadline:deadline];
    Check([stale[@"result"] isEqual:@"committed"]&&[stale[@"generation"] isEqual:@1]&&[stale[@"installedSwitchConnected"] isEqual:@NO],@"generation 1 family switch to shared 109 still not installed");
    Check([bridge.safeStatus[@"managerPinVerified"] isEqual:@YES]&&[bridge.safeStatus[@"installedSwitchConnected"] isEqual:@NO],@"verified pin is not connected switching");
    NSMutableDictionary *again=[base mutableCopy];again[@"generation"]=@1;again[@"nonce"]=NSUUID.UUID.UUIDString.lowercaseString;
    Check([[bridge dispatchRequest:again coordinator:j.coordinator familyLayout:family managerPin:pin beforeDeadline:deadline][@"reason"] isEqual:@"stale-generation"],@"replayed generation refused");
    NSMutableDictionary *onlyIG=[base mutableCopy];onlyIG[@"generation"]=@2;onlyIG[@"containerID"]=@"108";onlyIG[@"nonce"]=NSUUID.UUID.UUIDString.lowercaseString;
    Check([[bridge dispatchRequest:onlyIG coordinator:j.coordinator familyLayout:family managerPin:pin beforeDeadline:deadline][@"reason"] isEqual:@"family-container-not-admitted"],@"Instagram-only 108 stops before coordinator commit");
    NSMutableDictionary *next=[base mutableCopy];next[@"generation"]=@2;next[@"containerID"]=@"0";next[@"nonce"]=NSUUID.UUID.UUIDString.lowercaseString;
    NSDictionary *ok=[bridge dispatchRequest:next coordinator:j.coordinator familyLayout:family managerPin:pin beforeDeadline:deadline];
    Check([ok[@"result"] isEqual:@"committed"]&&[ok[@"isolationVerified"] isEqual:@NO],@"default CID switch does not claim isolation");
    printf("PASS: %lu native manager-bridge assertions\n",(unsigned long)Checks);return 0;
}}
