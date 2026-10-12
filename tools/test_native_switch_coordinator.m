#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeSwitchCoordinator.h"
#import "../lucid/Switching/LBXNativeBrokerAuthority.h"
#import "../lucid/Switching/LBXNativeControlStore.h"
#import "../lucid/Switching/LBXNativeIsolationJournal.h"
#import "../lucid/Switching/LBXProcessDrain.h"

static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSString *Join(NSString *a,NSString *b){return [a stringByAppendingPathComponent:b];}
static void Dir(NSString *p){Check([NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture directory");}
@interface Fixture:NSObject
@property NSString *base,*broker,*store,*coord;
@end
@implementation Fixture
- (instancetype)init {if((self=[super init])){NSString *raw=Join(NSTemporaryDirectory(),[@"socialbox-switch-" stringByAppendingString:NSUUID.UUID.UUIDString]);Dir(raw);char *p=realpath(raw.fileSystemRepresentation,NULL);Check(p!=NULL,@"canonical fixture");_base=@(p);free(p);_broker=Join(_base,@"broker");_store=Join(_base,@"store");_coord=Join(_base,@"coord");}return self;}
- (void)dealloc{[NSFileManager.defaultManager removeItemAtPath:_base error:nil];}
@end
static NSDictionary *Group(void){return @{@"device":@1,@"inode":@42};}
static NSString *Nonce(void){return NSUUID.UUID.UUIDString.lowercaseString;}
static NSString *Bundle(NSString *name){return [NSString stringWithFormat:@"/private/var/containers/Bundle/Application/11111111-1111-4111-8111-11111111111%@/%@.app", [name isEqual:@"Instagram"]?@"3":@"4", name];}
@interface MockFence:NSObject<LBXNativeSwitchFence>
@property BOOL closed; @property NSString *opened;
@end
@implementation MockFence
- (BOOL)closeAllBeforeDeadline:(double)deadline error:(NSError **)error {(void)deadline;(void)error;_closed=YES;_opened=nil;return YES;}
- (BOOL)openContainerID:(NSString *)containerID beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    (void)deadline;if(!_closed||!authorization||!authorization())return NO;_opened=containerID;return YES;
}
@end
@interface FamilyDrain:NSObject<LBXDrainBackend>
@property double now; @property BOOL blockFacebook; @property NSMutableArray *drained;
@end
@implementation FamilyDrain
- (instancetype)init {if((self=[super init])){_now=100;_drained=[NSMutableArray array];}return self;}
- (LBXDrainTarget *)target:(NSString *)bundleID {
    NSString *name=[bundleID isEqual:@"com.burbn.instagram"]?@"Instagram":@"Facebook";NSString *root=Bundle(name);
    LBXDrainTarget *target=[LBXDrainTarget new];target.bundleID=bundleID;target.bundlePath=root;
    target.executables=@[[root stringByAppendingPathComponent:name]];target.fingerprint=[name stringByAppendingString:@"-reg"];return target;
}
- (LBXDrainTarget *)resolve:(NSString *)bundleID error:(NSError **)error {
    (void)error;if(_blockFacebook&&[bundleID isEqual:@"com.facebook.Facebook"])return nil;
    if(![_drained containsObject:bundleID])[_drained addObject:bundleID];
    return [self target:bundleID];
}
- (NSArray *)snapshot:(NSError **)error {(void)error;return @[];}
- (RBXProcessIdentityResult)terminate:(RBXObservedProcess)identity {(void)identity;return RBXProcessGone;}
- (double)monotonicTime {return _now;}
- (BOOL)pause {_now+=0.03;return YES;}
@end
@interface LBXNativeControlLayout : NSObject
@property(nonatomic,copy)NSDictionary *safeStatus;
@end
@implementation LBXNativeControlLayout
- (instancetype)init {
    if((self=[super init])){
        _safeStatus=@{@"kind":@"native-family-control-layout",@"layoutStatus":@"OBSERVED",@"applications":@[@"com.burbn.instagram",@"com.facebook.Facebook"],
            @"accountFileContentsRead":@NO,@"isolationVerified":@NO,@"runtimeAccepted":@NO};
    }return self;
}
@end
@interface LBXNativeFamilyApplicationGate : NSObject
@property(nonatomic,copy)NSDictionary *safeStatus;
@property(nonatomic)NSUInteger closes;
@property(nonatomic)NSUInteger restores;
@end
@implementation LBXNativeFamilyApplicationGate
- (instancetype)init {
    if((self=[super init])){
        _safeStatus=@{@"kind":@"native-family-application-gate",@"applications":@[@"com.burbn.instagram",@"com.facebook.Facebook"],
            @"isolationVerified":@NO,@"runtimeAccepted":@NO};
    }return self;
}
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error {(void)deadline;if(error)*error=nil;_closes++;return YES;}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    (void)deadline;if(error)*error=nil;if(!authorization||!authorization())return NO;_restores++;return YES;
}
@end
static LBXNativeSwitchCoordinator *Open(Fixture *f){
    LBXNativeIsolationJournal *bj=[LBXNativeIsolationJournal testOpenDirectory:f.broker create:YES error:nil];
    LBXNativeIsolationJournal *sj=[LBXNativeIsolationJournal testOpenDirectory:f.store create:YES error:nil];
    LBXNativeIsolationJournal *cj=[LBXNativeIsolationJournal testOpenDirectory:f.coord create:YES error:nil];
    LBXNativeBrokerAuthority *broker=[LBXNativeBrokerAuthority testOpenJournal:bj error:nil];
    LBXNativeControlStore *store=[LBXNativeControlStore testOpenJournal:sj error:nil];
    Check(bj&&sj&&cj&&broker&&store,@"child journals");
    LBXNativeSwitchCoordinator *coord=[LBXNativeSwitchCoordinator testOpenJournal:cj broker:broker store:store error:nil];
    Check(coord!=nil,@"open coordinator");
    Check([coord attachControlLayout:[LBXNativeControlLayout new] error:nil]&&[coord.safeStatus[@"familyControlLayoutAttached"] isEqual:@YES],@"family control layout required before switch");
    Check([coord attachFamilyApplicationGate:[LBXNativeFamilyApplicationGate new] error:nil]&&[coord.safeStatus[@"familyApplicationGateAttached"] isEqual:@YES],@"family execution gate required before switch");
    return coord;
}
int main(void){@autoreleasepool{
    Fixture *f=[Fixture new];double deadline=LBXNativeSwitchClock()+30;NSArray *family=@[@"com.burbn.instagram",@"com.facebook.Facebook"];
    LBXNativeSwitchCoordinator *c=Open(f);
    Check([c.safeStatus[@"installedSwitchConnected"] isEqual:@NO]&&![c.safeStatus[@"isolationVerified"] boolValue],@"coordinator never claims installed isolation");
    Check(![c refuseUnsupportedOperation:@"create" error:nil]&&![c refuseUnsupportedOperation:@"delete" error:nil],@"create/delete stay unsupported");
    LBXNativeSwitchCoordinator *bare=({
        LBXNativeIsolationJournal *bj=[LBXNativeIsolationJournal testOpenDirectory:Join(f.base,@"bare-broker") create:YES error:nil];
        LBXNativeIsolationJournal *sj=[LBXNativeIsolationJournal testOpenDirectory:Join(f.base,@"bare-store") create:YES error:nil];
        LBXNativeIsolationJournal *cj=[LBXNativeIsolationJournal testOpenDirectory:Join(f.base,@"bare-coord") create:YES error:nil];
        [LBXNativeSwitchCoordinator testOpenJournal:cj broker:[LBXNativeBrokerAuthority testOpenJournal:bj error:nil] store:[LBXNativeControlStore testOpenJournal:sj error:nil] error:nil];
    });
    NSError *controlMissing=nil;[bare testSetDrain:^BOOL(NSArray *apps,NSError **error){(void)apps;(void)error;return YES;}];[bare testSetFence:^BOOL(NSString *cid,NSError **error){(void)cid;(void)error;return YES;}];
    Check(![bare switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:&controlMissing]&&controlMissing.code==3,@"switch without family control layout refused");
    NSError *missing=nil;Check(![c switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:&missing]&&missing.code==4,@"missing drain/fence cannot succeed");
    [c testSetDrain:^BOOL(NSArray *apps,NSError **error){(void)error;return apps.count==2;}];
    [c testSetFence:^BOOL(NSString *cid,NSError **error){(void)error;return [cid isEqual:@"0"]||[cid isEqual:@"5"];}];
    Check(![c switchToContainerID:@"0" applicationIDs:@[@"com.atebits.Tweetie2"] familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Twitter refused");
    Check(![c switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return NO;} error:nil],@"authorization failure");
    NSString *first=Nonce();
    Check([c switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:first beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Instagram and Facebook switch together to 0");
    Check([c.safeStatus[@"phase"] isEqual:@"committed"],@"committed phase after verified family switch");
    Check(![c switchToContainerID:@"5" applicationIDs:family familyGroupIdentity:Group() nonce:first beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"replayed nonce refused");
    Check(![c switchToContainerID:@"5" applicationIDs:@[@"com.burbn.instagram"] familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Instagram-only switch cannot leave Facebook on the family group");
    Check([c switchToContainerID:@"5" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"second family switch to 5");
    [c testSetDrain:^BOOL(NSArray *apps,NSError **error){(void)apps;if(error)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];return NO;}];
    Check(![c switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"failed drain cannot commit");
    Check(![c.description containsString:@"com.burbn.instagram"],@"description omits bundle IDs");
    Fixture *g=[Fixture new];LBXNativeSwitchCoordinator *wired=Open(g);
    Check(![wired switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"unwired family drain cannot succeed");
    FamilyDrain *backend=[FamilyDrain new];MockFence *igFence=[MockFence new],*fbFence=[MockFence new];
    Check(![wired attachDrainBackend:backend fences:@{@"com.burbn.instagram":igFence} error:nil],@"Instagram fence alone cannot cover Facebook");
    Check([wired attachDrainBackend:backend fences:@{@"com.burbn.instagram":igFence,@"com.facebook.Facebook":fbFence} error:nil],@"attach Instagram and Facebook fences");
    Check([wired.safeStatus[@"familyDrainAttached"] isEqual:@YES],@"family drain attachment is visible without claiming isolation");
    Check([wired switchToContainerID:@"0" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"source drain stops both apps then opens both fences");
    Check(igFence.closed&&fbFence.closed&&[igFence.opened isEqual:@"0"]&&[fbFence.opened isEqual:@"0"],@"both family fences closed then opened to CID 0");
    Check([backend.drained isEqual:@[@"com.burbn.instagram",@"com.facebook.Facebook"]],@"drain order is the canonical family list");
    backend.blockFacebook=YES;igFence.closed=NO;fbFence.closed=NO;igFence.opened=nil;fbFence.opened=nil;
    Check(![wired switchToContainerID:@"5" applicationIDs:family familyGroupIdentity:Group() nonce:Nonce() beforeDeadline:deadline authorization:^BOOL{return YES;} error:nil],@"Facebook drain failure aborts before CID 5");
    Check(!fbFence.closed&&![wired.safeStatus[@"isolationVerified"] boolValue],@"failed family drain does not open Facebook storage");
    printf("PASS: %lu native switch coordinator assertions for Instagram/Facebook\n",(unsigned long)Checks);return 0;
}}
