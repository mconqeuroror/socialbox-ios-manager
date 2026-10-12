#import "LBXContainerRootMutationCoordinator.h"
#import "LBXContainerConfiguration.h"
#import "LBXContainerMutationClient.h"
#import "LBXContainerMutationIPC.h"
#import "../Authorization/LBXLicenseClient.h"
#import "../Authorization/LBXLicenseIPC.h"
#include <math.h>
#include <stdint.h>
#include <limits.h>

static NSDictionary *CopyJSON(id value,NSUInteger limit) {
    @try {
        if(![value isKindOfClass:NSDictionary.class]||![NSJSONSerialization isValidJSONObject:value])return nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
        return data.length&&data.length<=limit?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    } @catch(__unused NSException *exception){return nil;}
}
static LBXContainerConfiguration *Configuration(id value) {
    LBXContainerConfiguration *record=[LBXContainerConfiguration fromDictionary:value error:nil];
    return record&&[record.privateDictionary isEqual:value]?record:nil;
}
static NSArray *CanonicalApps(NSArray *applications) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSString *application in @[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"])
        if([applications containsObject:application])[result addObject:application];
    return [result copy];
}
static BOOL SameSlot(NSDictionary *a,NSDictionary *b) {return a&&b&&[a isEqual:b];}
static BOOL MatchesIntent(NSDictionary *slot,NSDictionary *intent) {
    if(!slot||!intent)return NO;NSDictionary *arguments=intent[@"arguments"];
    long long expectedEpoch=[arguments[@"expectedEmptyEpoch"] longLongValue];
    if(expectedEpoch>=LLONG_MAX||![slot[@"stageRequestID"] isEqual:arguments[@"stageRequestID"]]||
       [slot[@"epoch"] longLongValue]!=expectedEpoch+1)return NO;
    if([intent[@"operation"] isEqual:@"stage-update"])return [slot[@"operation"] isEqual:@"update"]&&
        [slot[@"expected"] isEqual:arguments[@"expected"]]&&[slot[@"configuration"] isEqual:arguments[@"configuration"]];
    if([intent[@"operation"] isEqual:@"stage-retire"])return [slot[@"operation"] isEqual:@"retire"]&&
        [slot[@"expected"] isEqual:arguments[@"expected"]]&&[slot[@"configuration"] isEqual:arguments[@"expected"]];
    if(![intent[@"operation"] isEqual:@"stage-create"])return NO;
    NSDictionary *choices=arguments[@"choices"],*record=slot[@"configuration"];BOOL random=choices[@"manualIdentifiers"]==NSNull.null;
    return [slot[@"operation"] isEqual:@"create"]&&[record[@"name"] isEqual:choices[@"name"]]&&
        [record[@"applications"] isEqual:CanonicalApps(choices[@"applications"])]&&[record[@"proxyReference"] isEqual:choices[@"proxyReference"]]&&
        [record[@"identifierMode"] isEqual:random?@"random":@"manual"]&&
        (random||[record[@"identifiers"] isEqual:choices[@"manualIdentifiers"]]);
}
static NSString *FailureResult(NSString *result) {
    if([@[@"authorization_required",@"conflict",@"invalid_request"] containsObject:result])return result;
    return [result isEqual:@"storage_unavailable"]?@"state_unavailable":@"unconfirmed";
}
static NSError *Unavailable(void){return [NSError errorWithDomain:@"com.socialbox.root-setup-coordinator" code:1
    userInfo:@{NSLocalizedDescriptionKey:@"Authenticated saved-setup state is unavailable; reload or verify is required"}];}
#if LBX_CONTAINER_ROOT_COORDINATOR_TESTING
static LBXRootCoordinatorLicenseSender TestLicenseSender;
static LBXRootCoordinatorMutationSender TestMutationSender;
static double TestStepBudget=24;
#endif
@interface LBXContainerRootMutationCoordinator ()
- (instancetype)initPrivate;
@end
@implementation LBXContainerRootMutationCoordinator {
    dispatch_queue_t _queue;BOOL _busy,_available;uint64_t _generation,_step;
    NSDictionary *_state,*_intent,*_slot;
}
+ (instancetype)coordinator {return [[self alloc] initPrivate];}
- (instancetype)initPrivate {if((self=[super init]))_queue=dispatch_queue_create("com.socialbox.root-setup-ui-coordinator",DISPATCH_QUEUE_SERIAL);return self;}
- (NSString *)description {return @"<LBXContainerRootMutationCoordinator: private saved settings; runtimeAccepted=false>";}
- (NSString *)debugDescription {return self.description;}
- (NSDictionary *)renderPending {
    // Root's newest observed pending replaces stale rendering, never retained
    // request authority. Original intent/slot remain separately blocked on conflict.
    id pending=_state[@"pending"];
    if([pending isKindOfClass:NSDictionary.class])return pending;
    if(_slot)return _slot;
    if(_intent){NSDictionary *arguments=_intent[@"arguments"];BOOL create=[_intent[@"operation"] isEqual:@"stage-create"],retire=[_intent[@"operation"] isEqual:@"stage-retire"];
        return CopyJSON(@{@"operation":create?@"create":retire?@"retire":@"update",@"stageRequestID":arguments[@"stageRequestID"],
            @"expectedEmptyEpoch":arguments[@"expectedEmptyEpoch"],@"input":arguments,
            @"configuration":create?NSNull.null:retire?arguments[@"expected"]:arguments[@"configuration"],@"expected":create?NSNull.null:arguments[@"expected"]},32768);}
    return nil;
}
- (NSDictionary *)pendingMutation:(NSError **)error {
    @synchronized(self){if(error)*error=_available?nil:Unavailable();return [self renderPending];}
}
- (NSDictionary *)safeStatus {
    @synchronized(self){return @{@"stateAvailable":@(_available),@"hasPending":@((BOOL)(!_available||[self renderPending]!=nil)),
        @"busy":@(_busy),@"runtimeAccepted":@NO};}
}
- (void)deliver:(NSString *)result configuration:(NSDictionary *)configuration entries:(NSArray *)entries next:(NSString *)next completion:(void (^)(NSDictionary *))completion {
    NSDictionary *reply;
    @synchronized(self){NSDictionary *pending=[self renderPending];reply=CopyJSON(@{@"result":result,@"configuration":configuration?:NSNull.null,
        @"entries":entries?:@[],@"next":next?:@"",@"pending":@((BOOL)(!_available||pending!=nil)),@"runtimeAccepted":@NO,
        @"stateAvailable":@(_available),@"pendingMutation":pending?:NSNull.null},65536);}
    dispatch_async(dispatch_get_main_queue(),^{completion(reply);});
}
- (BOOL)start:(void (^)(NSDictionary *))completion generation:(uint64_t *)generation {
    @synchronized(self){if(_busy){[self deliver:@"busy" configuration:nil entries:nil next:nil completion:completion];return NO;}
        if(_generation==UINT64_MAX){_available=NO;[self deliver:@"state_unavailable" configuration:nil entries:nil next:nil completion:completion];return NO;}
        _busy=YES;*generation=++_generation;return YES;}
}
- (void)finish:(NSString *)result configuration:(NSDictionary *)configuration entries:(NSArray *)entries next:(NSString *)next generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    @synchronized(self){if(!_busy||generation!=_generation)return;_busy=NO;_step++;}
    [self deliver:result configuration:configuration entries:entries next:next completion:completion];
}
- (void)unavailable { @synchronized(self){_available=NO;} }
- (double)stepBudget {
#if LBX_CONTAINER_ROOT_COORDINATOR_TESTING
    @synchronized(self.class){return TestStepBudget;}
#else
    return 24;
#endif
}
- (BOOL)consumeStep:(uint64_t)step generation:(uint64_t)generation deadline:(double)deadline {
    if(!_busy||generation!=_generation||step!=_step)return NO;
    _step++;
    if(!isfinite(LBXContainerMutationIPCClock())||LBXContainerMutationIPCClock()>=deadline)return NO;
    return YES;
}
- (void)validateGeneration:(uint64_t)generation completion:(void (^)(NSString *))completion {
    NSDictionary *request=LBXLicenseIPCRequest(@"validate",nil);uint64_t step=++_step;double budget=[self stepBudget],deadline=LBXContainerMutationIPCClock()+budget;
    void (^complete)(NSDictionary *)=^(NSDictionary *raw){NSDictionary *reply=CopyJSON(raw,2048);dispatch_async(self->_queue,^{
        if(!self->_busy||self->_generation!=generation||self->_step!=step)return;
        BOOL timely=[self consumeStep:step generation:generation deadline:deadline];
        NSMutableDictionary *shape=[request mutableCopy];shape[@"requestID"]=reply[@"requestID"]?:@"";
        // Real fixed client already proves peer/request identity. This additional
        // check validates typed semantics without inventing another client pin.
        BOOL valid=timely&&LBXLicenseIPCValidateReply(reply,shape,LBXLicenseIPCClock());
        NSString *result=valid&&[reply[@"result"] isEqual:@"active"]?@"active":
            valid&&![reply[@"result"] isEqual:@"service_unavailable"]?@"authorization_required":@"unconfirmed";
        if(![result isEqual:@"active"])[self unavailable];completion(result);
    });};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(budget*NSEC_PER_SEC)),_queue,^{
        if(!self->_busy||self->_generation!=generation||self->_step!=step)return;self->_step++;[self unavailable];completion(@"unconfirmed");});
#if LBX_CONTAINER_ROOT_COORDINATOR_TESTING
    LBXRootCoordinatorLicenseSender sender;@synchronized(self.class){sender=[TestLicenseSender copy];}
    if(sender){sender(@"validate",nil,complete);return;}
#endif
    LBXSendLicenseRequest(@"validate",nil,complete);
}
- (void)sendOperation:(NSString *)operation arguments:(NSDictionary *)arguments generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    NSDictionary *request=LBXContainerMutationIPCRequest(operation,arguments);if(!request){completion(nil);return;}
    uint64_t step=++_step;double budget=[self stepBudget],deadline=LBXContainerMutationIPCClock()+budget;
    void (^complete)(NSDictionary *)=^(NSDictionary *raw){NSDictionary *reply=CopyJSON(raw,65536);dispatch_async(self->_queue,^{
        if(!self->_busy||self->_generation!=generation||self->_step!=step)return;
        BOOL timely=[self consumeStep:step generation:generation deadline:deadline];NSMutableDictionary *shape=[request mutableCopy];shape[@"requestID"]=reply[@"requestID"]?:@"";
        completion(timely&&LBXContainerMutationIPCValidateReply(reply,shape,LBXContainerMutationIPCClock())?reply:nil);
    });};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(budget*NSEC_PER_SEC)),_queue,^{
        if(!self->_busy||self->_generation!=generation||self->_step!=step)return;self->_step++;completion(nil);});
#if LBX_CONTAINER_ROOT_COORDINATOR_TESTING
    LBXRootCoordinatorMutationSender sender;@synchronized(self.class){sender=[TestMutationSender copy];}
    if(sender){sender(operation,arguments,complete);return;}
#endif
    LBXSendContainerMutationRequest(operation,arguments,complete);
}
- (BOOL)observeReply:(NSDictionary *)reply {
    NSDictionary *state=LBXContainerMutationIPCProjectState(reply[@"state"]);
    @synchronized(self){if(!state){_available=NO;return NO;}
        if(_state&&[state[@"epoch"] longLongValue]<[_state[@"epoch"] longLongValue]){_available=NO;return NO;}
        _state=state;_available=YES;
        NSDictionary *pending=[state[@"pending"] isKindOfClass:NSDictionary.class]?state[@"pending"]:nil;
        NSDictionary *completed=[state[@"completed"] isKindOfClass:NSDictionary.class]?state[@"completed"]:nil;
        if(_intent){NSDictionary *matching=MatchesIntent(pending,_intent)?pending:MatchesIntent(completed,_intent)?completed:nil;if(matching)_slot=matching;}
        else if(!_slot&&pending)_slot=pending;
        return YES;}
}
- (void)validatedStatus:(uint64_t)generation completion:(void (^)(NSDictionary *,NSString *))completion {
    [self validateGeneration:generation completion:^(NSString *validation){
        if(![validation isEqual:@"active"]){completion(nil,validation);return;}
        [self sendOperation:@"status" arguments:@{} generation:generation completion:^(NSDictionary *reply){
            BOOL status=[reply[@"result"] isEqual:@"status"]&&[self observeReply:reply];
            if(!status){[self unavailable];completion(nil,FailureResult(reply[@"result"]));return;}completion(reply[@"state"],nil);
        }];
    }];
}
- (NSDictionary *)matchingSlotInState:(NSDictionary *)state conflict:(BOOL *)conflict retryStage:(BOOL *)retryStage {
    *conflict=NO;*retryStage=NO;NSDictionary *pending=[state[@"pending"] isKindOfClass:NSDictionary.class]?state[@"pending"]:nil;
    NSDictionary *completed=[state[@"completed"] isKindOfClass:NSDictionary.class]?state[@"completed"]:nil;
    @synchronized(self){if(_intent){NSDictionary *matching=MatchesIntent(pending,_intent)?pending:MatchesIntent(completed,_intent)?completed:nil;
            if(matching){_slot=matching;return matching;}
            if(pending||(_slot!=nil)||[completed[@"stageRequestID"] isEqual:_intent[@"arguments"][@"stageRequestID"]]||![state[@"epoch"] isEqual:_intent[@"arguments"][@"expectedEmptyEpoch"]]){*conflict=YES;return nil;}
            *retryStage=YES;return nil;}
        if(_slot){if(SameSlot(pending,_slot)||SameSlot(completed,_slot))return _slot;*conflict=YES;return nil;}
        if(pending){_slot=pending;return pending;}return nil;}
}
- (void)refreshWithCompletion:(void (^)(NSDictionary *))completion {
    if(!completion)return;dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        [self validatedStatus:generation completion:^(NSDictionary *state,NSString *failure){
            BOOL conflict=NO,retry=NO;if(state)[self matchingSlotInState:state conflict:&conflict retryStage:&retry];
            [self finish:failure?:conflict?@"conflict":@"status" configuration:nil entries:nil next:nil generation:generation completion:completion];
        }];});
}
- (void)validateWithCompletion:(void (^)(NSDictionary *))completion {
    if(!completion)return;dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        [self validateGeneration:generation completion:^(NSString *result){[self finish:result configuration:nil entries:nil next:nil generation:generation completion:completion];}];});
}
- (void)query:(NSString *)operation arguments:(NSDictionary *)arguments completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;NSDictionary *snapshot=CopyJSON(arguments,16384);dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        if(!snapshot||!LBXContainerMutationIPCRequest(operation,snapshot)){[self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        [self validateGeneration:generation completion:^(NSString *validation){if(![validation isEqual:@"active"]){[self finish:validation configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            [self sendOperation:operation arguments:snapshot generation:generation completion:^(NSDictionary *reply){BOOL accepted=([operation isEqual:@"read"]&&[@[@"record",@"missing"] containsObject:reply[@"result"]])||([operation isEqual:@"list"]&&[reply[@"result"] isEqual:@"listed"]);
                BOOL observed=[self observeReply:reply];if(!accepted||!observed){[self unavailable];[self finish:FailureResult(reply[@"result"]) configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
                [self finish:reply[@"result"] configuration:reply[@"configuration"]==NSNull.null?nil:reply[@"configuration"] entries:reply[@"entries"] next:reply[@"next"] generation:generation completion:completion];
            }];
        }];});
}
- (void)listAfter:(NSString *)after completion:(void (^)(NSDictionary *))completion {[self query:@"list" arguments:@{@"after":[after isKindOfClass:NSString.class]?[after copy]:NSNull.null} completion:completion];}
- (void)readConfigurationWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *))completion {[self query:@"read" arguments:@{@"identifier":[identifier isKindOfClass:NSString.class]?[identifier copy]:NSNull.null} completion:completion];}
- (BOOL)confirmCompleted:(NSDictionary *)reply slot:(NSDictionary *)slot {
    NSString *success=[slot[@"operation"] isEqual:@"retire"]?@"retired":@"saved";
    if(![reply[@"result"] isEqual:success]||![reply[@"configuration"] isEqual:slot[@"configuration"]]||![self observeReply:reply])return NO;
    @synchronized(self){if(!SameSlot(_state[@"completed"],slot)||_state[@"pending"]!=NSNull.null)return NO;
        if(_intent&&!MatchesIntent(slot,_intent))return NO;if(_slot&&!SameSlot(_slot,slot))return NO;
        _intent=nil;_slot=nil;return YES;}
}
- (void)executeSlot:(NSDictionary *)slot operation:(NSString *)operation generation:(uint64_t)generation completion:(void (^)(NSDictionary *))completion {
    BOOL retire=[slot[@"operation"] isEqual:@"retire"];
    BOOL retirementVerb=[@[@"execute-retire",@"reconcile-retire"] containsObject:operation];
    if(retire!=retirementVerb||(!retire&&![@[@"execute",@"reconcile"] containsObject:operation])){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
    [self validateGeneration:generation completion:^(NSString *validation){if(![validation isEqual:@"active"]){[self finish:validation configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
        [self sendOperation:operation arguments:@{@"token":slot[@"token"],@"epoch":slot[@"epoch"]} generation:generation completion:^(NSDictionary *reply){
            BOOL completed=[self confirmCompleted:reply slot:slot];BOOL observed=completed||[self observeReply:reply];
            NSString *retry=retire?@"retirement_retry_required":@"retry_required";
            NSString *result=completed?(retire?@"retired":@"saved"):[reply[@"result"] isEqual:retry]&&observed?retry:FailureResult(reply[@"result"]);
            [self finish:result configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];
        }];
    }];
}
- (void)sendRetainedStage:(uint64_t)generation retirement:(BOOL)retire completion:(void (^)(NSDictionary *))completion {
    NSDictionary *intent;@synchronized(self){intent=_intent;}
    if(!intent||retire!=[intent[@"operation"] isEqual:@"stage-retire"]){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
    NSString *success=retire?@"retired":@"saved",*staged=retire?@"retirement_staged":@"staged";
    [self validateGeneration:generation completion:^(NSString *validation){if(![validation isEqual:@"active"]){[self finish:validation configuration:intent[@"arguments"][@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
        [self sendOperation:intent[@"operation"] arguments:intent[@"arguments"] generation:generation completion:^(NSDictionary *reply){BOOL observed=[self observeReply:reply];NSDictionary *slot=nil;
            @synchronized(self){if(observed){id candidate=[reply[@"result"] isEqual:success]?self->_state[@"completed"]:self->_state[@"pending"];if([candidate isKindOfClass:NSDictionary.class]&&MatchesIntent(candidate,intent)){self->_slot=candidate;slot=candidate;}}}
            if([reply[@"result"] isEqual:success]&&slot&&[self confirmCompleted:reply slot:slot]){[self finish:success configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
            if(![reply[@"result"] isEqual:staged]||!slot){[self finish:FailureResult(reply[@"result"]) configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
            [self executeSlot:slot operation:retire?@"execute-retire":@"execute" generation:generation completion:completion];
        }];
    }];
}
- (void)beginCreationWithChoices:(NSDictionary *)choices completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;NSDictionary *snapshot=CopyJSON(choices,16384);dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        BOOL valid=snapshot.count==4&&[[NSSet setWithArray:snapshot.allKeys] isEqual:[NSSet setWithArray:@[@"name",@"applications",@"manualIdentifiers",@"proxyReference"]]]&&
            LBXContainerConfigurationValidateChoices(snapshot[@"name"],snapshot[@"applications"],snapshot[@"manualIdentifiers"]==NSNull.null?nil:snapshot[@"manualIdentifiers"],snapshot[@"proxyReference"]);
        if(!valid){[self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        @synchronized(self){if(self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}}
        [self validatedStatus:generation completion:^(NSDictionary *state,NSString *failure){if(!state){[self finish:failure configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            @synchronized(self){if(state[@"pending"]!=NSNull.null||self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
                self->_intent=CopyJSON(@{@"operation":@"stage-create",@"arguments":@{@"expectedEmptyEpoch":state[@"epoch"],@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"choices":snapshot}},16384);}
            [self sendRetainedStage:generation retirement:NO completion:completion];
        }];});
}
- (void)beginUpdateOfConfiguration:(LBXContainerConfiguration *)expected name:(NSString *)name applications:(NSArray<NSString *> *)applications manualIdentifiers:(NSDictionary<NSString *,NSString *> *)manualIdentifiers completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;LBXContainerConfiguration *prior=[expected isKindOfClass:LBXContainerConfiguration.class]?Configuration(expected.privateDictionary):nil;
    NSDictionary *changes=CopyJSON(@{@"name":name?:NSNull.null,@"applications":applications?:NSNull.null,@"manualIdentifiers":manualIdentifiers?:NSNull.null},16384);
    LBXContainerConfiguration *valid=[prior configurationByUpdatingName:changes[@"name"]==NSNull.null?nil:changes[@"name"] applications:changes[@"applications"]==NSNull.null?nil:changes[@"applications"] manualIdentifiers:changes[@"manualIdentifiers"]==NSNull.null?nil:changes[@"manualIdentifiers"] proxyReference:nil error:nil];
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        if(!prior||!valid||!changes){[self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        @synchronized(self){if(self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}}
        [self validatedStatus:generation completion:^(NSDictionary *state,NSString *failure){if(!state){[self finish:failure configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            @synchronized(self){if(state[@"pending"]!=NSNull.null||self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}}
            [self sendOperation:@"read" arguments:@{@"identifier":prior.identifier} generation:generation completion:^(NSDictionary *reply){BOOL observed=[self observeReply:reply];LBXContainerConfiguration *current=observed&&[reply[@"result"] isEqual:@"record"]?Configuration(reply[@"configuration"]):nil;
                if(!current||![current.privateDictionary isEqual:prior.privateDictionary]){[self finish:observed&&[@[@"record",@"missing"] containsObject:reply[@"result"]]?@"conflict":FailureResult(reply[@"result"]) configuration:current.privateDictionary entries:nil next:nil generation:generation completion:completion];return;}
                LBXContainerConfiguration *candidate=[current configurationByUpdatingName:changes[@"name"]==NSNull.null?nil:changes[@"name"] applications:changes[@"applications"]==NSNull.null?nil:changes[@"applications"] manualIdentifiers:changes[@"manualIdentifiers"]==NSNull.null?nil:changes[@"manualIdentifiers"] proxyReference:nil error:nil];
                @synchronized(self){if(self->_state[@"pending"]!=NSNull.null||self->_intent||self->_slot){[self finish:@"conflict" configuration:current.privateDictionary entries:nil next:nil generation:generation completion:completion];return;}
                    self->_intent=CopyJSON(@{@"operation":@"stage-update",@"arguments":@{@"expectedEmptyEpoch":self->_state[@"epoch"],@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"expected":current.privateDictionary,@"configuration":candidate.privateDictionary}},16384);}
                [self sendRetainedStage:generation retirement:NO completion:completion];
            }];
        }];});
}
- (void)beginRetirementOfConfiguration:(LBXContainerConfiguration *)expected completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;LBXContainerConfiguration *prior=[expected isKindOfClass:LBXContainerConfiguration.class]?Configuration(expected.privateDictionary):nil;
    dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        // Shape check only; the actual epoch and stable ID are retained after
        // authenticated status and exact full read, never from these constants.
        if(!prior||!LBXContainerMutationIPCRequest(@"stage-retire",@{@"expectedEmptyEpoch":@"1",@"stageRequestID":@"11111111-1111-1111-1111-111111111111",@"expected":prior.privateDictionary})){
            [self finish:@"invalid_request" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
        @synchronized(self){if(self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}}
        [self validatedStatus:generation completion:^(NSDictionary *state,NSString *failure){if(!state){[self finish:failure configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            @synchronized(self){if(state[@"pending"]!=NSNull.null||self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}}
            [self sendOperation:@"read" arguments:@{@"identifier":prior.identifier} generation:generation completion:^(NSDictionary *reply){
                BOOL observed=[self observeReply:reply];LBXContainerConfiguration *current=observed&&[reply[@"result"] isEqual:@"record"]?Configuration(reply[@"configuration"]):nil;
                if(!current||![current.privateDictionary isEqual:prior.privateDictionary]){[self finish:observed&&[@[@"record",@"missing"] containsObject:reply[@"result"]]?@"conflict":FailureResult(reply[@"result"]) configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
                @synchronized(self){if(self->_state[@"pending"]!=NSNull.null||self->_intent||self->_slot){[self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
                    self->_intent=CopyJSON(@{@"operation":@"stage-retire",@"arguments":@{@"expectedEmptyEpoch":self->_state[@"epoch"],@"stageRequestID":NSUUID.UUID.UUIDString.lowercaseString,@"expected":current.privateDictionary}},16384);}
                [self sendRetainedStage:generation retirement:YES completion:completion];
            }];
        }];});
}
- (void)pendingAction:(BOOL)retry retirement:(BOOL)retire completion:(void (^)(NSDictionary *))completion {
    if(!completion)return;dispatch_async(_queue,^{uint64_t generation;if(![self start:completion generation:&generation])return;
        [self validatedStatus:generation completion:^(NSDictionary *state,NSString *failure){if(!state){[self finish:failure configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            BOOL conflict=NO,retryStage=NO;NSDictionary *slot=[self matchingSlotInState:state conflict:&conflict retryStage:&retryStage];
            if(conflict){[self finish:@"conflict" configuration:slot[@"configuration"] entries:nil next:nil generation:generation completion:completion];return;}
            NSDictionary *intent;@synchronized(self){intent=self->_intent;}
            if((intent&&retire!=[intent[@"operation"] isEqual:@"stage-retire"])||(slot&&retire!=[slot[@"operation"] isEqual:@"retire"])){
                [self finish:@"conflict" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            if(retryStage){if(retry)[self sendRetainedStage:generation retirement:retire completion:completion];else [self finish:retire?@"retirement_retry_required":@"retry_required" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            if(!slot){[self finish:@"no_pending" configuration:nil entries:nil next:nil generation:generation completion:completion];return;}
            [self executeSlot:slot operation:retire?(retry?@"execute-retire":@"reconcile-retire"):(retry?@"execute":@"reconcile") generation:generation completion:completion];
        }];});
}
- (void)reconcilePendingWithCompletion:(void (^)(NSDictionary *))completion {[self pendingAction:NO retirement:NO completion:completion];}
- (void)retryPendingWithCompletion:(void (^)(NSDictionary *))completion {[self pendingAction:YES retirement:NO completion:completion];}
- (void)reconcileRetirementWithCompletion:(void (^)(NSDictionary *))completion {[self pendingAction:NO retirement:YES completion:completion];}
- (void)retryRetirementWithCompletion:(void (^)(NSDictionary *))completion {[self pendingAction:YES retirement:YES completion:completion];}
#if LBX_CONTAINER_ROOT_COORDINATOR_TESTING
+ (void)testUseLicenseSender:(LBXRootCoordinatorLicenseSender)licenseSender mutationSender:(LBXRootCoordinatorMutationSender)mutationSender {
    @synchronized(self){TestLicenseSender=[licenseSender copy];TestMutationSender=[mutationSender copy];}
}
+ (void)testUseStepBudget:(double)seconds {@synchronized(self){TestStepBudget=isfinite(seconds)&&seconds>0&&seconds<=24?seconds:24;}}
#endif
@end
