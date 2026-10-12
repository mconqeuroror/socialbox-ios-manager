#import "LBXNativeFamilyApplicationGate.h"

@protocol LBXNativeFamilyAppGate
- (NSDictionary *)privateJournalRecord;
- (NSDictionary *)safeStatus;
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@end

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-family-application-gate" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==4?@"Family execution drain was not verified":@"Family application gate refused"}];
    return NO;
}
static NSDictionary *Immutable(id value){
    if(![NSJSONSerialization isValidJSONObject:value])return nil;
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
}
static NSString *Bundle(id gate){
    id binding=((id<LBXNativeFamilyAppGate>)gate).privateJournalRecord[@"binding"];
    return [binding isKindOfClass:NSDictionary.class]?binding[@"bundleIdentifier"]:nil;
}
static BOOL Honest(id gate,NSString *expected){
    Class gateClass=NSClassFromString(@"LBXNativeApplicationGate");
    if(!gateClass||![gate isKindOfClass:gateClass]||![Bundle(gate) isEqual:expected])return NO;
    NSDictionary *status=((id<LBXNativeFamilyAppGate>)gate).safeStatus;
    return [status[@"runtimeAccepted"] isEqual:@NO]&&![status[@"isolationVerified"] boolValue];
}
@interface LBXNativeFamilyApplicationGate ()
@property(nonatomic,strong)id instagram;
@property(nonatomic,strong)id facebook;
@property(nonatomic)BOOL drained;
@property(nonatomic)BOOL restored;
- (instancetype)initPrivate;
@end
@implementation LBXNativeFamilyApplicationGate
- (instancetype)initPrivate{return [super init];}
- (NSDictionary *)safeStatus{
    return Immutable(@{@"kind":@"native-family-application-gate",@"formatVersion":@1,@"applications":@[Instagram,Facebook],
        @"familyDrainVerified":@(_drained),@"executionRestored":@(_restored),@"runtimeAccepted":@NO,@"isolationVerified":@NO,@"installedSwitchConnected":@NO})?:@{};
}
- (NSString *)description{return @"<LBXNativeFamilyApplicationGate>";}
+ (instancetype)gateWithInstagram:(LBXNativeApplicationGate *)instagram facebook:(LBXNativeApplicationGate *)facebook error:(NSError **)error {
    if(error)*error=nil;
    if(!Honest(instagram,Instagram)||!Honest(facebook,Facebook)||instagram==facebook){Fail(error,1);return nil;}
    LBXNativeFamilyApplicationGate *gate=[[self alloc] initPrivate];
    gate.instagram=instagram;gate.facebook=facebook;return gate;
}
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;
        BOOL instagram=[(id<LBXNativeFamilyAppGate>)_instagram closeAndDrainBeforeDeadline:deadline error:error];
        BOOL facebook=[(id<LBXNativeFamilyAppGate>)_facebook closeAndDrainBeforeDeadline:deadline error:error];
        _drained=instagram&&facebook;_restored=NO;
        return _drained?YES:Fail(error,4);
    }
}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(!_drained||!authorization)return Fail(error,1);
        if(![(id<LBXNativeFamilyAppGate>)_facebook restoreExecutionBeforeDeadline:deadline authorization:authorization error:error])return Fail(error,4);
        if(![(id<LBXNativeFamilyAppGate>)_instagram restoreExecutionBeforeDeadline:deadline authorization:authorization error:error])return Fail(error,4);
        _restored=YES;return YES;
    }
}
@end
