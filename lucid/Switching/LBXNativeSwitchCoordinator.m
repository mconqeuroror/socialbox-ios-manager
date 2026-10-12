#import "LBXNativeSwitchCoordinator.h"
#import "LBXNativeBrokerAuthority.h"
#import "LBXNativeControlStore.h"
#import "LBXNativeIsolationJournal.h"
#import "LBXProcessDrain.h"
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <math.h>
#ifndef LBX_NATIVE_SWITCH_COORDINATOR_TESTING
#define LBX_NATIVE_SWITCH_COORDINATOR_TESTING 0
#endif
@protocol LBXNativeFamilyLayoutGate
- (NSDictionary *)safeStatus;
- (BOOL)allowsContainerID:(NSString *)containerID error:(NSError **)error;
@end
@protocol LBXNativeFamilyExecutionGate
- (NSDictionary *)safeStatus;
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@end

static NSString *const Instagram=@"com.burbn.instagram";
static NSString *const Facebook=@"com.facebook.Facebook";
double LBXNativeSwitchClock(void){mach_timebase_info_data_t scale;mach_timebase_info(&scale);return scale.denom?(double)mach_continuous_time()*scale.numer/scale.denom/1e9:NAN;}
static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-switch-coordinator" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Root switch journals are required":code==3?@"Family group switch refused":code==4?@"Drain or storage fence was not verified":code==5?@"Switch deadline exceeded":code==6?@"Unsupported native operation":@"Native switch transaction refused"}];
    return NO;
}
static BOOL Budget(double deadline){double now=LBXNativeSwitchClock();return isfinite(now)&&isfinite(deadline)&&deadline>now&&deadline-now<=120;}
static NSDictionary *Immutable(id value){if(![NSJSONSerialization isValidJSONObject:value])return nil;NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;}
static BOOL AppID(NSString *value){return [value isEqual:Instagram]||[value isEqual:Facebook];}
static BOOL CID(NSString *value){if(![value isKindOfClass:NSString.class]||!value.length||value.length>19)return NO;if([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;if(value.length>1&&[value hasPrefix:@"0"])return NO;return YES;}
static BOOL Identity(NSDictionary *value){
    if(![value isKindOfClass:NSDictionary.class]||value.count!=2)return NO;
    id device=value[@"device"],inode=value[@"inode"];
    return [device isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)device)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)device)&&[device longLongValue]>=0&&
           [inode isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)inode)!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)inode)&&[inode unsignedLongLongValue]>0;
}
static BOOL Nonce(NSString *value){return [value isKindOfClass:NSString.class]&&value.length==36&&[value isEqual:value.lowercaseString]&&[[NSUUID alloc] initWithUUIDString:value]!=nil;}
@interface LBXNativeSwitchCoordinator ()
@property(nonatomic,strong)LBXNativeIsolationJournal *journal;
@property(nonatomic,strong)LBXNativeBrokerAuthority *broker;
@property(nonatomic,strong)LBXNativeControlStore *store;
@property(nonatomic,copy)NSDictionary *envelope;
@property(nonatomic)BOOL testing;
@property(nonatomic,strong)id<LBXDrainBackend> drainBackend;
@property(nonatomic,copy)NSDictionary *fences;
@property(nonatomic,strong)id familyLayout;
@property(nonatomic,strong)id controlLayout;
@property(nonatomic,strong)id familyApplicationGate;
#if LBX_NATIVE_SWITCH_COORDINATOR_TESTING
@property(nonatomic,copy)BOOL (^drain)(NSArray *,NSError **);
@property(nonatomic,copy)BOOL (^fence)(NSString *,NSError **);
#endif
@end
@implementation LBXNativeSwitchCoordinator
- (instancetype)initPrivate{return [super init];}
- (NSDictionary *)payload{NSDictionary *body=_envelope[@"payload"];return [body isKindOfClass:NSDictionary.class]?body:nil;}
- (NSDictionary *)safeStatus{
    @synchronized(self){NSDictionary *payload=[self payload];
        return Immutable(@{@"kind":@"native-switch-coordinator",@"phase":payload[@"phase"]?:@"unknown",@"runtimeAccepted":@NO,@"isolationVerified":@NO,@"installedSwitchConnected":@NO,@"familyDrainAttached":@(_drainBackend!=nil),@"familyLayoutAttached":@(_familyLayout!=nil),@"familyControlLayoutAttached":@(_controlLayout!=nil),@"familyApplicationGateAttached":@(_familyApplicationGate!=nil)})?:@{};}
}
- (NSString *)description{return @"<LBXNativeSwitchCoordinator>";}
- (NSString *)debugDescription{return self.description;}
- (BOOL)writePayload:(NSDictionary *)payload error:(NSError **)error {
    NSDictionary *frozen=Immutable(payload);if(!frozen)return Fail(error,1);
    if(![_journal compareRecord:_envelope replaceWith:frozen error:error])return NO;
    _envelope=_journal.currentRecord;return _envelope!=nil;
}
static NSDictionary *Idle(void){return @{@"kind":@"native-switch-coordinator",@"formatVersion":@1,@"phase":@"idle",@"containerID":[NSNull null],@"applications":@[],@"nonce":[NSNull null],@"familyGroupIdentity":[NSNull null]};}
static LBXNativeSwitchCoordinator *Open(LBXNativeIsolationJournal *journal,LBXNativeBrokerAuthority *broker,LBXNativeControlStore *store,BOOL testing,NSError **error){
    if(error)*error=nil;if(!journal||!broker||!store){Fail(error,2);return nil;}
    NSError *readError=nil;NSDictionary *current=[journal validatedCurrentRecord:&readError];if(readError){if(error)*error=readError;return nil;}
    if(!current){
        NSDictionary *payload=Immutable(Idle());
        if(!payload||![journal compareRecord:nil replaceWith:payload error:error])return nil;current=journal.currentRecord;
    }
    NSDictionary *body=current[@"payload"];
    if(![body[@"kind"] isEqual:@"native-switch-coordinator"]||![body[@"formatVersion"] isEqual:@1]||![body[@"phase"] isKindOfClass:NSString.class]){Fail(error,1);return nil;}
    NSError *closeError=nil;if(![broker closeAdmissionBeforeDeadline:LBXNativeBrokerClock()+5 error:&closeError]){if(error)*error=closeError;return nil;}
    if(![body[@"phase"] isEqual:@"idle"]&&![body[@"phase"] isEqual:@"committed"]){
        NSDictionary *closed=Immutable(@{@"kind":@"native-switch-coordinator",@"formatVersion":@1,@"phase":@"recovery-closed",@"containerID":body[@"containerID"]?:[NSNull null],@"applications":body[@"applications"]?:@[],@"nonce":body[@"nonce"]?:[NSNull null],@"familyGroupIdentity":body[@"familyGroupIdentity"]?:[NSNull null]});
        if(!closed||![journal compareRecord:current replaceWith:closed error:error])return nil;current=journal.currentRecord;
    }
    LBXNativeSwitchCoordinator *coordinator=[[LBXNativeSwitchCoordinator alloc] initPrivate];
    coordinator.journal=journal;coordinator.broker=broker;coordinator.store=store;coordinator.envelope=current;coordinator.testing=testing;(void)testing;return coordinator;
}
+ (instancetype)openJournal:(LBXNativeIsolationJournal *)journal broker:(LBXNativeBrokerAuthority *)broker store:(LBXNativeControlStore *)store error:(NSError **)error {return Open(journal,broker,store,NO,error);}
#if LBX_NATIVE_SWITCH_COORDINATOR_TESTING
+ (instancetype)testOpenJournal:(LBXNativeIsolationJournal *)journal broker:(LBXNativeBrokerAuthority *)broker store:(LBXNativeControlStore *)store error:(NSError **)error {return Open(journal,broker,store,YES,error);}
- (void)testSetDrain:(BOOL (^)(NSArray<NSString *> *, NSError **))drain {_drain=[drain copy];}
- (void)testSetFence:(BOOL (^)(NSString *, NSError **))fence {_fence=[fence copy];}
#endif
- (BOOL)refuseUnsupportedOperation:(NSString *)operation error:(NSError **)error {
    (void)operation;return Fail(error,6);
}
- (BOOL)attachFamilyLayout:(LBXNativeFamilyStorageLayout *)layout error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;
        Class familyClass=NSClassFromString(@"LBXNativeFamilyStorageLayout");
        id candidate=layout;id<LBXNativeFamilyLayoutGate> gate=candidate;
        if(!familyClass||![candidate isKindOfClass:familyClass]||[gate.safeStatus[@"isolationVerified"] boolValue]||[gate.safeStatus[@"runtimeAccepted"] boolValue])return Fail(error,1);
        _familyLayout=candidate;return YES;
    }
}
- (BOOL)attachControlLayout:(id)layout error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;
        Class controlClass=NSClassFromString(@"LBXNativeControlLayout");
        NSDictionary *status=[layout respondsToSelector:@selector(safeStatus)]?((id<LBXNativeFamilyLayoutGate>)layout).safeStatus:nil;
        NSArray *apps=status[@"applications"];
        BOOL official=NO;if([apps isKindOfClass:NSArray.class]&&apps.count==2)official=[[NSSet setWithArray:apps] isEqual:[NSSet setWithObjects:Instagram,Facebook,nil]];
        if(!controlClass||![layout isKindOfClass:controlClass]||![status[@"kind"] isEqual:@"native-family-control-layout"]||![status[@"layoutStatus"] isEqual:@"OBSERVED"]||![status[@"accountFileContentsRead"] isEqual:@NO]||[status[@"isolationVerified"] boolValue]||[status[@"runtimeAccepted"] boolValue]||!official)return Fail(error,1);
        _controlLayout=layout;return YES;
    }
}
- (BOOL)attachFamilyApplicationGate:(id)gate error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;
        Class gateClass=NSClassFromString(@"LBXNativeFamilyApplicationGate");
        NSDictionary *status=[gate respondsToSelector:@selector(safeStatus)]?((id<LBXNativeFamilyLayoutGate>)gate).safeStatus:nil;
        NSArray *apps=status[@"applications"];
        BOOL official=NO;if([apps isKindOfClass:NSArray.class]&&apps.count==2)official=[[NSSet setWithArray:apps] isEqual:[NSSet setWithObjects:Instagram,Facebook,nil]];
        if(!gateClass||![gate isKindOfClass:gateClass]||![status[@"kind"] isEqual:@"native-family-application-gate"]||[status[@"isolationVerified"] boolValue]||[status[@"runtimeAccepted"] boolValue]||!official||![gate respondsToSelector:@selector(closeAndDrainBeforeDeadline:error:)]||![gate respondsToSelector:@selector(restoreExecutionBeforeDeadline:authorization:error:)])return Fail(error,1);
        _familyApplicationGate=gate;return YES;
    }
}
- (BOOL)attachDrainBackend:(id<LBXDrainBackend>)backend fences:(NSDictionary<NSString *,id<LBXNativeSwitchFence>> *)fences error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(!backend||![fences isKindOfClass:NSDictionary.class]||fences.count!=2||!fences[Instagram]||!fences[Facebook])return Fail(error,1);
        NSMutableDictionary *bound=[NSMutableDictionary dictionary];
        for(NSString *app in fences){id<LBXNativeSwitchFence> fence=fences[app];
            if(!AppID(app)||!fence||![fence respondsToSelector:@selector(closeAllBeforeDeadline:error:)]||![fence respondsToSelector:@selector(openContainerID:beforeDeadline:authorization:error:)])return Fail(error,1);
            bound[app]=fence;}
        _drainBackend=backend;_fences=[bound copy];return YES;
    }
}
- (BOOL)drainFamily:(NSArray *)apps beforeDeadline:(double)deadline error:(NSError **)error {
    if(!_drainBackend||!_fences)return Fail(error,4);
    NSTimeInterval timeout=deadline-LBXNativeSwitchClock();if(!isfinite(timeout)||timeout<0.1)return Fail(error,5);if(timeout>5)timeout=5;
    for(NSString *app in apps){
        if(!_fences[app])return Fail(error,4);
        NSDictionary *receipt=LBXDrainApplication(_drainBackend,app,NSUUID.UUID.UUIDString,timeout,YES);
        if(![receipt[@"status"] isEqual:@"observed_absent"]||[receipt[@"networkFenced"] isEqual:@YES]||[receipt[@"launchesFenced"] isEqual:@YES]||[receipt[@"reusableAdmission"] isEqual:@YES])return Fail(error,4);
    }
    return YES;
}
- (BOOL)closeFences:(NSArray *)apps beforeDeadline:(double)deadline error:(NSError **)error {
    for(NSString *app in apps){id<LBXNativeSwitchFence> fence=_fences[app];if(![fence closeAllBeforeDeadline:deadline error:error])return Fail(error,4);}return YES;
}
- (BOOL)openFences:(NSArray *)apps containerID:(NSString *)containerID beforeDeadline:(double)deadline error:(NSError **)error {
    BOOL (^auth)(void)=^{return YES;};
    for(NSString *app in apps){id<LBXNativeSwitchFence> fence=_fences[app];if(![fence openContainerID:containerID beforeDeadline:deadline authorization:auth error:error])return Fail(error,4);}return YES;
}
- (BOOL)performVerifiedEffects:(NSArray *)apps containerID:(NSString *)containerID identity:(NSDictionary *)identity deadline:(double)deadline seen:(NSSet *)seen error:(NSError **)error {
    if(!_familyApplicationGate)return Fail(error,3);
    id<LBXNativeFamilyExecutionGate> execution=_familyApplicationGate;
    if(![execution closeAndDrainBeforeDeadline:deadline error:error])return Fail(error,4);
#if LBX_NATIVE_SWITCH_COORDINATOR_TESTING
    BOOL (^drain)(NSArray *,NSError **)=_drain;BOOL (^fence)(NSString *,NSError **)=_fence;
    if(drain||fence){
        if(!drain||!fence)return Fail(error,4);
        if(!drain(apps,error))return Fail(error,4);
        if(![_store commitContainerID:containerID applicationIDs:apps familyGroupIdentity:identity beforeDeadline:deadline authorization:^BOOL{return YES;} error:error])return NO;
        if(!fence(containerID,error))return Fail(error,4);
    }else
#endif
    {
        if(![self drainFamily:apps beforeDeadline:deadline error:error])return NO;
        if(![self closeFences:apps beforeDeadline:deadline error:error])return NO;
        if(![_store commitContainerID:containerID applicationIDs:apps familyGroupIdentity:identity beforeDeadline:deadline authorization:^BOOL{return YES;} error:error])return NO;
        if(![self openFences:apps containerID:containerID beforeDeadline:deadline error:error])return NO;
    }
    if(![execution restoreExecutionBeforeDeadline:deadline authorization:^BOOL{return YES;} error:error])return Fail(error,4);
    LBXNativeBrokerEpoch *epoch=[_broker prepareContainerID:containerID beforeDeadline:deadline error:error];
    if(!epoch)return NO;
    BOOL (^admit)(void)=^{
        NSString *ig=[self.store selectedContainerIDForApplication:Instagram error:nil],*fb=[self.store selectedContainerIDForApplication:Facebook error:nil];
        BOOL listedIG=[seen containsObject:Instagram],listedFB=[seen containsObject:Facebook];
        BOOL ok=(!listedIG||[ig isEqual:containerID])&&(!listedFB||[fb isEqual:containerID]);
        return ok;
    };
    if(![_broker admitEpoch:epoch beforeDeadline:deadline authorization:admit error:error])return NO;
    return YES;
}
- (BOOL)switchToContainerID:(NSString *)containerID applicationIDs:(NSArray<NSString *> *)applicationIDs familyGroupIdentity:(NSDictionary *)identity nonce:(NSString *)nonce beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    @synchronized(self){
        if(error)*error=nil;if(!Budget(deadline))return Fail(error,5);
        NSDictionary *phase=[self payload];
        if(!CID(containerID)||!Identity(identity)||!Nonce(nonce)||![applicationIDs isKindOfClass:NSArray.class]||!applicationIDs.count||applicationIDs.count>2)return Fail(error,1);
        NSMutableArray *apps=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
        for(NSString *app in applicationIDs){if(!AppID(app)||[seen containsObject:app])return Fail(error,1);[seen addObject:app];[apps addObject:app];}
        [apps sortUsingSelector:@selector(compare:)];
        if([phase[@"nonce"] isEqual:nonce])return Fail(error,1);
        if(!_controlLayout||!_familyApplicationGate)return Fail(error,3);
        if(_familyLayout&&![(id<LBXNativeFamilyLayoutGate>)_familyLayout allowsContainerID:containerID error:error])return Fail(error,3);
        if(!authorization||!authorization())return Fail(error,1);
        NSDictionary *intent=@{@"kind":@"native-switch-coordinator",@"formatVersion":@1,@"phase":@"intent",@"containerID":containerID,@"applications":apps,@"nonce":nonce,@"familyGroupIdentity":identity};
        if(![self writePayload:intent error:error])return NO;
        if(![_broker closeAdmissionBeforeDeadline:deadline error:error]||![_broker waitForLeasesBeforeDeadline:deadline error:error])return NO;
        NSDictionary *closed=@{@"kind":@"native-switch-coordinator",@"formatVersion":@1,@"phase":@"admission-closed",@"containerID":containerID,@"applications":apps,@"nonce":nonce,@"familyGroupIdentity":identity};
        if(![self writePayload:closed error:error])return NO;
        if(![self performVerifiedEffects:apps containerID:containerID identity:identity deadline:deadline seen:seen error:error])return NO;
        NSDictionary *committed=@{@"kind":@"native-switch-coordinator",@"formatVersion":@1,@"phase":@"committed",@"containerID":containerID,@"applications":apps,@"nonce":nonce,@"familyGroupIdentity":identity};
        return [self writePayload:committed error:error];
    }
}
@end
