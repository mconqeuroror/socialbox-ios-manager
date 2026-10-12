#import "saved_setup_transport_fixture.h"
#import "../../Containers/LBXContainerClient.h"
#import "../../Containers/LBXContainerMutationClient.h"
#import "../../Containers/LBXContainerConfiguration.h"
#import "../../Containers/LBXContainerIPC.h"
#import "../../Containers/LBXContainerMutationIPC.h"
#import "../../Authorization/LBXLicenseIPC.h"

// No filesystem, license grant, process role or target runtime is simulated.
// The durable root namespace here means only this fixture's retained memory.
static NSMutableDictionary *Records,*Retired,*Counts;
static NSString *LicenseResult,*Behavior;
static NSUInteger Validations;
static uint64_t Epoch;
static BOOL Established;
static NSDictionary *RootPending,*RootCompleted,*StageArguments;
static NSDictionary *LastCandidate,*LastExpected,*LastStageArguments,*DeferredRequest;
static void (^DeferredCompletion)(NSDictionary *),(^ReplayCompletion)(NSDictionary *);
static NSDictionary *ReplayReply;
static NSDictionary *Snapshot(id value) {
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
}
static void Count(NSString *operation){Counts[operation]=@([Counts[operation] unsignedIntegerValue]+1);}
static NSString *Decimal(uint64_t epoch){return [NSString stringWithFormat:@"%llu",(unsigned long long)epoch];}
static NSDictionary *State(void){return @{@"epoch":Decimal(Epoch),@"pending":RootPending ?: (id)NSNull.null,@"completed":RootCompleted ?: (id)NSNull.null};}
void SBTestSavedSetupReset(void) {
    Records=[NSMutableDictionary dictionary];Retired=[NSMutableDictionary dictionary];Counts=[NSMutableDictionary dictionary];LicenseResult=@"active";Behavior=@"save";
    Epoch=0;Established=NO;Validations=0;RootPending=RootCompleted=StageArguments=nil;
    LastCandidate=LastExpected=LastStageArguments=DeferredRequest=ReplayReply=nil;DeferredCompletion=ReplayCompletion=nil;
}
void SBTestSavedSetupInitializeRoot(void){NSCAssert(!Established&&!RootPending&&!RootCompleted&&!Records.count,@"Only externally pristine synthetic state initializes");Established=YES;Epoch=1;Count(@"fixture-initialize");}
BOOL SBTestSavedSetupRemoveSyntheticRoot(void){BOOL ok=Established&&!DeferredCompletion;Records=Retired=nil;RootPending=RootCompleted=StageArguments=nil;Established=NO;Epoch=0;return ok;}
void SBTestSavedSetupSetLicenseResult(NSString *result){LicenseResult=[result copy];}
void SBTestSavedSetupSetMutationBehavior(NSString *behavior){Behavior=[behavior copy];}
void SBTestSavedSetupValidate(void (^completion)(NSDictionary *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{SBTestSavedSetupValidate(completion);});return;}
    if(!Counts)SBTestSavedSetupReset();Validations++;
    NSDictionary *request=LBXLicenseIPCRequest(@"validate",nil);
    NSDictionary *reply=LBXLicenseIPCReply(request,LicenseResult ?: @"service_unavailable",YES);
    NSCAssert([reply[@"result"] isEqual:LicenseResult]&&LBXLicenseIPCValidateReply(reply,request,LBXLicenseIPCClock()),@"Malformed synthetic typed licensing reply");
    dispatch_async(dispatch_get_main_queue(),^{completion(reply);});
}
NSUInteger SBTestSavedSetupCount(NSString *operation){return [Counts[operation] unsignedIntegerValue];}
NSUInteger SBTestSavedSetupValidateCount(void){return Validations;}
NSDictionary *SBTestSavedSetupLastCandidate(void){return Snapshot(LastCandidate ?: @{});}
NSDictionary *SBTestSavedSetupLastExpected(void){return Snapshot(LastExpected ?: @{});}
NSDictionary *SBTestSavedSetupLastStageArguments(void){return Snapshot(LastStageArguments ?: @{});}
NSDictionary *SBTestSavedSetupRecordSnapshot(void){return Snapshot(Records ?: @{});}
NSDictionary *SBTestSavedSetupRootState(void){return Established?Snapshot(State()):nil;}
static NSDictionary *Reply(NSDictionary *request,NSString *result,NSDictionary *configuration,NSArray *entries,NSString *next){
    NSDictionary *reply=LBXContainerMutationIPCReply(request,result,State(),configuration,entries,next);
    NSCAssert([reply[@"result"] isEqual:result]&&LBXContainerMutationIPCValidateReply(reply,request,LBXContainerMutationIPCClock()),@"Intended synthetic root reply must validate, never normalized failure");return reply;
}
static NSDictionary *Failure(NSDictionary *request,NSString *result){NSDictionary *reply=LBXContainerMutationIPCFailure(request,result);
    NSCAssert([reply[@"result"] isEqual:result]&&LBXContainerMutationIPCValidateReply(reply,request,LBXContainerMutationIPCClock()),@"Intended synthetic root failure must validate");return reply;}
static NSDictionary *Arguments(NSDictionary *request){NSMutableDictionary *args=[request mutableCopy];[args removeObjectsForKeys:@[@"family",@"version",@"requestID",@"operation",@"deadline"]];return Snapshot(args);}
static BOOL Token(NSDictionary *slot,NSDictionary *request){return slot&&[slot[@"token"] isEqual:request[@"token"]]&&[slot[@"epoch"] isEqual:request[@"epoch"]];}
static void CompleteSlot(void){NSCAssert(RootPending,@"Completion needs retained synthetic slot");RootCompleted=RootPending;RootPending=nil;Epoch++;}
static NSDictionary *Execute(NSDictionary *request,BOOL mutate){
    if(RootPending&&!Token(RootPending,request))return Reply(request,@"conflict",nil,@[],@"");
    NSDictionary *slot=RootPending ?: RootCompleted;BOOL retire=[slot[@"operation"] isEqual:@"retire"];
    BOOL retirementVerb=[@[@"execute-retire",@"reconcile-retire"] containsObject:request[@"operation"]];
    if(!Token(slot,request)||retire!=retirementVerb)return Reply(request,@"conflict",nil,@[],@"");
    if(retire){NSDictionary *original=slot[@"expected"],*tombstone=Retired[original[@"identifier"]];
        if([tombstone isEqual:original]){if(RootPending)CompleteSlot();return Reply(request,@"retired",original,@[],@"");}
        if(!RootPending||![Records[original[@"identifier"]] isEqual:original])return Reply(request,@"conflict",nil,@[],@"");
        if(!mutate)return Reply(request,@"retirement_retry_required",original,@[],@"");
        Epoch++;Retired[original[@"identifier"]]=original;[Records removeObjectForKey:original[@"identifier"]];CompleteSlot();return Reply(request,@"retired",original,@[],@"");}
    if(!RootPending){if(Token(RootCompleted,request)&&[Records[RootCompleted[@"configuration"][@"identifier"]] isEqual:RootCompleted[@"configuration"]])return Reply(request,@"saved",RootCompleted[@"configuration"],@[],@"");return Reply(request,@"conflict",nil,@[],@"");}
    NSDictionary *candidate=RootPending[@"configuration"],*record=Records[candidate[@"identifier"]];
    if([record isEqual:candidate]){CompleteSlot();return Reply(request,@"saved",candidate,@[],@"");}
    BOOL retry=([RootPending[@"operation"] isEqual:@"create"]&&!record)||([RootPending[@"operation"] isEqual:@"update"]&&[record isEqual:RootPending[@"expected"]]);
    if(!retry)return Reply(request,@"conflict",nil,@[],@"");
    if(!mutate)return Reply(request,@"retry_required",candidate,@[],@"");
    Epoch++;Records[candidate[@"identifier"]]=candidate;CompleteSlot();return Reply(request,@"saved",candidate,@[],@"");
}
static NSDictionary *Stage(NSDictionary *request){
    NSDictionary *args=Arguments(request);LastStageArguments=args;
    BOOL retire=[request[@"operation"] isEqual:@"stage-retire"];
    NSDictionary *old=RootPending ?: RootCompleted;
    if(old&&[old[@"stageRequestID"] isEqual:request[@"stageRequestID"]]){
        if(![args isEqual:StageArguments])return Reply(request,@"conflict",nil,@[],@"");
        if(RootPending)return Reply(request,retire?@"retirement_staged":@"staged",old[@"configuration"],@[],@"");
        if(retire)return [Retired[old[@"configuration"][@"identifier"]] isEqual:old[@"configuration"]]?Reply(request,@"retired",old[@"configuration"],@[],@""):Reply(request,@"conflict",nil,@[],@"");
        return [Records[old[@"configuration"][@"identifier"]] isEqual:old[@"configuration"]]?Reply(request,@"saved",old[@"configuration"],@[],@""):Reply(request,@"conflict",nil,@[],@"");
    }
    if(RootPending||![request[@"expectedEmptyEpoch"] isEqual:Decimal(Epoch)])return Reply(request,@"conflict",nil,@[],@"");
    NSDictionary *candidate,*expected=nil;BOOL create=[request[@"operation"] isEqual:@"stage-create"];
    if(create){NSDictionary *choices=request[@"choices"];id manual=choices[@"manualIdentifiers"];
        LBXContainerConfiguration *model=[LBXContainerConfiguration createWithName:choices[@"name"] applications:choices[@"applications"] manualIdentifiers:manual==NSNull.null?nil:manual proxyReference:@"" error:nil];
        candidate=model.privateDictionary;NSCAssert(candidate,@"Synthetic candidate must be complete");Count(@"candidate-generation");
    }else {candidate=retire?request[@"expected"]:request[@"configuration"];expected=request[@"expected"];if(![Records[expected[@"identifier"]] isEqual:expected])return Reply(request,@"conflict",nil,@[],@"");}
    if(Retired[candidate[@"identifier"]])return Reply(request,@"conflict",nil,@[],@"");
    Epoch++;RootPending=Snapshot(@{@"token":NSUUID.UUID.UUIDString.lowercaseString,@"epoch":Decimal(Epoch),@"stageRequestID":request[@"stageRequestID"],@"operation":create?@"create":retire?@"retire":@"update",@"configuration":candidate,@"expected":expected ?: (id)NSNull.null});
    StageArguments=args;LastCandidate=Snapshot(candidate);LastExpected=expected?Snapshot(expected):nil;
    return Reply(request,retire?@"retirement_staged":@"staged",candidate,@[],@"");
}
void SBTestSavedSetupCompleteDeferred(NSString *result,BOOL publish){
    NSDictionary *request=DeferredRequest;void (^completion)(NSDictionary *)=DeferredCompletion;DeferredRequest=nil;DeferredCompletion=nil;
    if(request&&completion){NSDictionary *reply=publish?Execute(request,YES):Failure(request,result);
        NSCAssert([reply[@"result"] isEqual:result],@"Deferred intended result must match");ReplayCompletion=[completion copy];ReplayReply=Snapshot(reply);dispatch_async(dispatch_get_main_queue(),^{completion(reply);completion(reply);});}
}
void SBTestSavedSetupReplayDeferred(void){if(ReplayCompletion&&ReplayReply){Count(@"fixture-replay");void (^callback)(NSDictionary *)=ReplayCompletion;NSDictionary *reply=ReplayReply;dispatch_async(dispatch_get_main_queue(),^{callback(reply);});}}
void LBXSendContainerMutationRequest(NSString *operation,NSDictionary *arguments,void (^completion)(NSDictionary *)){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{LBXSendContainerMutationRequest(operation,arguments,completion);});return;}
    if(!Counts)SBTestSavedSetupReset();Count(operation);NSDictionary *request=LBXContainerMutationIPCRequest(operation,arguments);
    NSCAssert(request&&LBXContainerMutationIPCValidateRequest(request,LBXContainerMutationIPCClock()),@"Malformed synthetic root request");NSDictionary *reply=nil;
    if(!Established)reply=Failure(request,@"storage_unavailable");
    else if([operation isEqual:@"status"])reply=Reply(request,@"status",nil,@[],@"");
    else if([operation isEqual:@"list"]){NSMutableArray *entries=[NSMutableArray array];BOOL more=NO;NSString *after=request[@"after"];
        for(NSString *identifier in [Records.allKeys sortedArrayUsingSelector:@selector(compare:)]){if(after.length&&[identifier compare:after]!=NSOrderedDescending)continue;
            if(entries.count==40){more=YES;break;}NSDictionary *doc=Records[identifier];[entries addObject:@{@"identifier":doc[@"identifier"],@"revision":doc[@"revision"],@"name":doc[@"name"],@"applications":doc[@"applications"]}];}
        reply=Reply(request,@"listed",nil,entries,more?entries.lastObject[@"identifier"]:@"");
    }else if([operation isEqual:@"read"]){NSDictionary *doc=Records[request[@"identifier"]];reply=Reply(request,doc?@"record":@"missing",doc,@[],@"");}
    else if([operation hasPrefix:@"stage-"]){
        if([Behavior isEqual:@"unknown_stage_missing"]){LastStageArguments=Arguments(request);Behavior=@"save";reply=Failure(request,@"unconfirmed");}
        else if([Behavior isEqual:@"unknown_stage_published"]){(void)Stage(request);Behavior=@"save";reply=Failure(request,@"unconfirmed");}
        else reply=Stage(request);
    }else if([operation isEqual:@"reconcile"]||[operation isEqual:@"reconcile-retire"])reply=Execute(request,NO);
    else {NSString *behavior=Behavior ?: @"save";Behavior=@"save";
        if([behavior isEqual:@"defer"]){NSCAssert(!DeferredCompletion,@"One deferred synthetic request");DeferredRequest=request;DeferredCompletion=[completion copy];return;}
        if([behavior isEqual:@"conflict"]){NSMutableDictionary *different=[RootPending[@"configuration"] mutableCopy];different[@"name"]=@"Concurrent synthetic setup";Records[different[@"identifier"]]=Snapshot(different);reply=Reply(request,@"conflict",nil,@[],@"");}
        else if([behavior isEqual:@"unconfirmed_saved"]){(void)Execute(request,YES);reply=Failure(request,@"unconfirmed");}
        else if([behavior isEqual:@"unconfirmed_missing"])reply=Failure(request,@"unconfirmed");
        else reply=Execute(request,YES);
    }
    dispatch_async(dispatch_get_main_queue(),^{completion(reply);});
}
// Any accidental old raw writer/read/list use is counted and denied; never
// substitute the retired caller-owned journal with an equivalent fake writer.
void LBXSendContainerRequest(NSString *operation,NSDictionary *arguments,void (^completion)(NSDictionary *)){
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{LBXSendContainerRequest(operation,arguments,completion);});return;}
    if(!Counts)SBTestSavedSetupReset();Count([@"legacy." stringByAppendingString:operation]);
    NSDictionary *request=LBXContainerIPCRequest(operation,arguments);NSCAssert(request,@"Valid old request required");
    NSDictionary *reply=LBXContainerIPCFailure(request,@"authorization_required");dispatch_async(dispatch_get_main_queue(),^{completion(reply);});
}
