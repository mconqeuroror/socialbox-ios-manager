#import "LBXContainerMutationIPC.h"
#import "LBXContainerConfiguration.h"
#include <limits.h>
#include <math.h>
#include <string.h>

static NSString *const Family=@"container-mutation";
static BOOL Exact(id value,NSArray *keys) {
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;
    for(id key in value)if(![key isKindOfClass:NSString.class])return NO;
    return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL Number(id value) {return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);}
static BOOL Integer(id value) {
    if(!Number(value)||CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    const char *type=[value objCType];return type&&strchr("cislqCISLQ",type[0])&&!type[1]&&[value longLongValue]>0&&[value unsignedLongLongValue]<=LLONG_MAX;
}
static BOOL UUID(id value) {return [value isKindOfClass:NSString.class]&&[value length]==36&&
    [[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value]&&![value isEqual:@"00000000-0000-0000-0000-000000000000"];}
static BOOL Epoch(id value) {
    if(![value isKindOfClass:NSString.class]||![value length]||[value length]>19||[value hasPrefix:@"0"]||
       [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;
    return [value length]<19||[value compare:@"9223372036854775807"]!=NSOrderedDescending;
}
static uint64_t EpochValue(NSString *value){return (uint64_t)value.longLongValue;}
static BOOL JSONBounded(id value,NSUInteger maximum) {
    @try {if(![NSJSONSerialization isValidJSONObject:value])return NO;NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];return data.length&&data.length<=maximum;}
    @catch(__unused NSException *exception){return NO;}
}
static NSDictionary *Snapshot(id value,NSUInteger maximum) {
    @try {if(![value isKindOfClass:NSDictionary.class]||!JSONBounded(value,maximum))return nil;
        NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];}
    @catch(__unused NSException *exception){return nil;}
}
static NSDictionary *Document(id value) {LBXContainerConfiguration *c=[LBXContainerConfiguration fromDictionary:value error:nil];return c&&[c.privateDictionary isEqual:value]?c.privateDictionary:nil;}
static NSArray *CanonicalApps(NSArray *value) {
    NSMutableArray *ordered=[NSMutableArray array];for(NSString *app in @[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"])if([value containsObject:app])[ordered addObject:app];return [ordered copy];
}
static NSSet *Operations(void) {static NSSet *set;static dispatch_once_t once;dispatch_once(&once,^{set=[NSSet setWithArray:@[@"status",@"stage-create",@"stage-update",@"execute",@"reconcile",@"stage-retire",@"execute-retire",@"reconcile-retire",@"read",@"list"]];});return set;}
static NSSet *Results(void) {static NSSet *set;static dispatch_once_t once;dispatch_once(&once,^{set=[NSSet setWithArray:@[@"status",@"staged",@"saved",@"retry_required",@"retirement_staged",@"retired",@"retirement_retry_required",@"record",@"missing",@"listed",@"conflict",@"authorization_required",@"storage_unavailable",@"invalid_request",@"service_unavailable",@"unconfirmed"]];});return set;}
static BOOL Choices(id value) {return Exact(value,@[@"name",@"applications",@"manualIdentifiers",@"proxyReference"])&&
    LBXContainerConfigurationValidateChoices(value[@"name"],value[@"applications"],value[@"manualIdentifiers"]==NSNull.null?nil:value[@"manualIdentifiers"],value[@"proxyReference"]);}
static BOOL Slot(id value) {
    if(!Exact(value,@[@"token",@"epoch",@"stageRequestID",@"operation",@"configuration",@"expected"])||!UUID(value[@"token"])||!Epoch(value[@"epoch"])||!UUID(value[@"stageRequestID"]))return NO;
    NSDictionary *candidate=Document(value[@"configuration"]);if(!candidate)return NO;
    if([value[@"operation"] isEqual:@"create"])return [candidate[@"revision"] isEqual:@1]&&value[@"expected"]==NSNull.null;
    NSDictionary *expected=Document(value[@"expected"]);
    if([value[@"operation"] isEqual:@"retire"])return expected&&[expected isEqual:candidate];
    return [value[@"operation"] isEqual:@"update"]&&expected&&[expected[@"identifier"] isEqual:candidate[@"identifier"]]&&
        [expected[@"revision"] unsignedLongLongValue]<LLONG_MAX&&[candidate[@"revision"] unsignedLongLongValue]==[expected[@"revision"] unsignedLongLongValue]+1;
}
static BOOL State(id value) {
    if(!Exact(value,@[@"epoch",@"pending",@"completed"])||!Epoch(value[@"epoch"]))return NO;
    uint64_t current=EpochValue(value[@"epoch"]);
    for(NSString *key in @[@"pending",@"completed"])if(value[key]!=NSNull.null&&(!Slot(value[key])||EpochValue(value[key][@"epoch"])>current))return NO;
    if(value[@"pending"]!=NSNull.null&&value[@"completed"]!=NSNull.null){
        NSDictionary *pending=value[@"pending"],*completed=value[@"completed"];
        if([pending[@"token"] isEqual:completed[@"token"]]||[pending[@"stageRequestID"] isEqual:completed[@"stageRequestID"]]||
           EpochValue(completed[@"epoch"])>=EpochValue(pending[@"epoch"]))return NO;
    }
    return JSONBounded(value,16384);
}
double LBXContainerMutationIPCClock(void){return NSProcessInfo.processInfo.systemUptime;}
static BOOL ValidateRequest(id request,double now) {
    if(![request isKindOfClass:NSDictionary.class]||![request[@"family"] isEqual:Family]||!Integer(request[@"version"])||![request[@"version"] isEqual:@1]||
       !UUID(request[@"requestID"])||!Number(request[@"deadline"])||!isfinite(now)||now<0||[request[@"deadline"] doubleValue]<=now||[request[@"deadline"] doubleValue]>now+25||
       ![Operations() containsObject:request[@"operation"]?:NSNull.null])return NO;
    NSString *operation=request[@"operation"];NSMutableArray *keys=[@[@"family",@"version",@"requestID",@"operation",@"deadline"] mutableCopy];BOOL valid=NO;
    if([operation isEqual:@"status"])valid=Exact(request,keys);
    else if([operation isEqual:@"stage-create"]||[operation isEqual:@"stage-update"]||[operation isEqual:@"stage-retire"]){
        [keys addObjectsFromArray:@[@"expectedEmptyEpoch",@"stageRequestID"]];
        if([operation isEqual:@"stage-create"]){[keys addObject:@"choices"];valid=Choices(request[@"choices"]);}
        else if([operation isEqual:@"stage-retire"]){[keys addObject:@"expected"];valid=Document(request[@"expected"])!=nil;}
        else {[keys addObjectsFromArray:@[@"expected",@"configuration"]];NSDictionary *candidate=Document(request[@"configuration"]),*expected=Document(request[@"expected"]);
            valid=candidate&&expected&&[candidate[@"identifier"] isEqual:expected[@"identifier"]]&&[expected[@"revision"] unsignedLongLongValue]<LLONG_MAX&&
                [candidate[@"revision"] unsignedLongLongValue]==[expected[@"revision"] unsignedLongLongValue]+1;}
        valid=valid&&Exact(request,keys)&&Epoch(request[@"expectedEmptyEpoch"])&&UUID(request[@"stageRequestID"]);
    }else if([@[@"execute",@"reconcile",@"execute-retire",@"reconcile-retire"] containsObject:operation]){[keys addObjectsFromArray:@[@"token",@"epoch"]];valid=Exact(request,keys)&&UUID(request[@"token"])&&Epoch(request[@"epoch"]);}
    else if([operation isEqual:@"read"]){[keys addObject:@"identifier"];valid=Exact(request,keys)&&UUID(request[@"identifier"]);}
    else {[keys addObject:@"after"];id after=request[@"after"];valid=Exact(request,keys)&&[after isKindOfClass:NSString.class]&&(![after length]||UUID(after));}
    return valid&&JSONBounded(request,16384);
}
BOOL LBXContainerMutationIPCValidateRequest(id request,double now){@try{return ValidateRequest(request,now);}@catch(__unused NSException *exception){return NO;}}
NSDictionary *LBXContainerMutationIPCRequest(NSString *operation,NSDictionary *arguments) {
    @try {
        if(![operation isKindOfClass:NSString.class]||![arguments isKindOfClass:NSDictionary.class])return nil;
        NSSet *base=[NSSet setWithArray:@[@"family",@"version",@"requestID",@"operation",@"deadline"]];for(id key in arguments)if(![key isKindOfClass:NSString.class]||[base containsObject:key])return nil;
        NSMutableDictionary *request=[@{@"family":Family,@"version":@1,@"requestID":NSUUID.UUID.UUIDString.lowercaseString,@"operation":[operation copy],@"deadline":@(LBXContainerMutationIPCClock()+24)} mutableCopy];
        [request addEntriesFromDictionary:arguments];return LBXContainerMutationIPCValidateRequest(request,LBXContainerMutationIPCClock())?Snapshot(request,16384):nil;
    }@catch(__unused NSException *exception){return nil;}
}
NSDictionary *LBXContainerMutationIPCProjectSlot(id slot){@try{return Slot(slot)?Snapshot(slot,16384):nil;}@catch(__unused NSException *exception){return nil;}}
NSDictionary *LBXContainerMutationIPCProjectState(id state){@try{return State(state)?Snapshot(state,16384):nil;}@catch(__unused NSException *exception){return nil;}}
static BOOL StageMatches(NSDictionary *slot,NSDictionary *request) {
    if(![slot[@"stageRequestID"] isEqual:request[@"stageRequestID"]]||EpochValue(request[@"expectedEmptyEpoch"])>=LLONG_MAX||
       EpochValue(slot[@"epoch"])!=EpochValue(request[@"expectedEmptyEpoch"])+1)return NO;
    if([request[@"operation"] isEqual:@"stage-update"])return [slot[@"operation"] isEqual:@"update"]&&[slot[@"expected"] isEqual:request[@"expected"]]&&[slot[@"configuration"] isEqual:request[@"configuration"]];
    if([request[@"operation"] isEqual:@"stage-retire"])return [slot[@"operation"] isEqual:@"retire"]&&[slot[@"expected"] isEqual:request[@"expected"]]&&[slot[@"configuration"] isEqual:request[@"expected"]];
    if(![request[@"operation"] isEqual:@"stage-create"]||![slot[@"operation"] isEqual:@"create"])return NO;
    NSDictionary *choices=request[@"choices"],*candidate=slot[@"configuration"];BOOL random=choices[@"manualIdentifiers"]==NSNull.null;
    return [candidate[@"name"] isEqual:choices[@"name"]]&&[candidate[@"applications"] isEqual:CanonicalApps(choices[@"applications"])]&&
        [candidate[@"proxyReference"] isEqual:choices[@"proxyReference"]]&&
        [candidate[@"identifierMode"] isEqual:random?@"random":@"manual"]&&(random||[candidate[@"identifiers"] isEqual:choices[@"manualIdentifiers"]]);
}
static BOOL TokenMatches(NSDictionary *slot,NSDictionary *request){return [slot[@"token"] isEqual:request[@"token"]]&&[slot[@"epoch"] isEqual:request[@"epoch"]];}
static BOOL Page(NSArray *entries,NSString *next,NSString *after) {
    if(entries.count>40)return NO;NSString *previous=after;
    for(id entry in entries){
        if(!Exact(entry,@[@"identifier",@"revision",@"name",@"applications"])||!UUID(entry[@"identifier"])||!Integer(entry[@"revision"])||
        !LBXContainerConfigurationValidateChoices(entry[@"name"],entry[@"applications"],nil,@"")||![entry[@"applications"] isEqual:CanonicalApps(entry[@"applications"])]||
        (previous.length&&[previous compare:entry[@"identifier"]]!=NSOrderedAscending))return NO;
        previous=entry[@"identifier"];
    }
    return !next.length||(entries.count==40&&UUID(next)&&[next isEqual:entries.lastObject[@"identifier"]]);
}
static BOOL ValidateReply(id reply,NSDictionary *request,double now) {
    if(!LBXContainerMutationIPCValidateRequest(request,now)||!Exact(reply,@[@"family",@"version",@"requestID",@"operation",@"result",@"state",@"configuration",@"entries",@"next",@"runtimeAccepted"])||
       ![reply[@"family"] isEqual:Family]||!Integer(reply[@"version"])||![reply[@"version"] isEqual:@1]||![reply[@"requestID"] isEqual:request[@"requestID"]]||![reply[@"operation"] isEqual:request[@"operation"]]||
       ![Results() containsObject:reply[@"result"]?:NSNull.null]||![reply[@"runtimeAccepted"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)reply[@"runtimeAccepted"])!=CFBooleanGetTypeID()||[reply[@"runtimeAccepted"] boolValue]||
       ![reply[@"entries"] isKindOfClass:NSArray.class]||![reply[@"next"] isKindOfClass:NSString.class]||!JSONBounded(reply,65536))return NO;
    NSString *operation=request[@"operation"],*result=reply[@"result"],*next=reply[@"next"];NSArray *entries=reply[@"entries"];id state=reply[@"state"];
    if([@[@"authorization_required",@"storage_unavailable",@"invalid_request",@"service_unavailable"] containsObject:result])return state==NSNull.null&&reply[@"configuration"]==NSNull.null&&!entries.count&&!next.length;
    if([@[@"conflict",@"unconfirmed"] containsObject:result])return (state==NSNull.null||State(state))&&reply[@"configuration"]==NSNull.null&&!entries.count&&!next.length;
    if(!State(state))return NO;
    if([result isEqual:@"status"])return [operation isEqual:@"status"]&&reply[@"configuration"]==NSNull.null&&!entries.count&&!next.length;
    if([result isEqual:@"listed"])return [operation isEqual:@"list"]&&reply[@"configuration"]==NSNull.null&&Page(entries,next,request[@"after"]);
    if(entries.count||next.length)return NO;
    if([result isEqual:@"missing"])return [operation isEqual:@"read"]&&reply[@"configuration"]==NSNull.null;
    NSDictionary *configuration=Document(reply[@"configuration"]);if(!configuration)return NO;
    if([result isEqual:@"record"])return [operation isEqual:@"read"]&&[configuration[@"identifier"] isEqual:request[@"identifier"]];
    if([@[@"staged",@"retirement_staged"] containsObject:result]){id slot=state[@"pending"];BOOL retire=[result isEqual:@"retirement_staged"];
        return slot!=NSNull.null&&retire==[slot[@"operation"] isEqual:@"retire"]&&StageMatches(slot,request)&&[configuration isEqual:slot[@"configuration"]];}
    if([@[@"retry_required",@"retirement_retry_required"] containsObject:result]){id slot=state[@"pending"];BOOL retire=[result isEqual:@"retirement_retry_required"];
        return [(retire?@[@"execute-retire",@"reconcile-retire"]:@[@"execute",@"reconcile"]) containsObject:operation]&&slot!=NSNull.null&&
            retire==[slot[@"operation"] isEqual:@"retire"]&&TokenMatches(slot,request)&&[configuration isEqual:slot[@"configuration"]];}
    if(![@[@"saved",@"retired"] containsObject:result]||state[@"pending"]!=NSNull.null||state[@"completed"]==NSNull.null)return NO;
    BOOL retire=[result isEqual:@"retired"];NSDictionary *slot=state[@"completed"];
    if(retire!=[slot[@"operation"] isEqual:@"retire"])return NO;
    BOOL matched=[(retire?@[@"stage-retire"]:@[@"stage-create",@"stage-update"]) containsObject:operation]?StageMatches(slot,request):
        [(retire?@[@"execute-retire",@"reconcile-retire"]:@[@"execute",@"reconcile"]) containsObject:operation]&&TokenMatches(slot,request);
    return matched&&[configuration isEqual:slot[@"configuration"]];
}
BOOL LBXContainerMutationIPCValidateReply(id reply,NSDictionary *request,double now){@try{return ValidateReply(reply,request,now);}@catch(__unused NSException *exception){return NO;}}
static NSDictionary *Base(NSDictionary *request,NSString *result) {
    BOOL dictionary=[request isKindOfClass:NSDictionary.class];id wire=dictionary?request[@"requestID"]:nil,operation=dictionary?request[@"operation"]:nil;
    return @{@"family":Family,@"version":@1,@"requestID":UUID(wire)?[wire copy]:@"",@"operation":[Operations() containsObject:operation?:NSNull.null]?[operation copy]:@"",
        @"result":[Results() containsObject:result?:NSNull.null]?[result copy]:@"service_unavailable",@"state":NSNull.null,@"configuration":NSNull.null,@"entries":@[],@"next":@"",@"runtimeAccepted":@NO};
}
NSDictionary *LBXContainerMutationIPCFailure(NSDictionary *request,NSString *result) {
    if(![@[@"conflict",@"authorization_required",@"storage_unavailable",@"invalid_request",@"service_unavailable",@"unconfirmed"] containsObject:result?:NSNull.null])result=@"service_unavailable";
    return Base(request,result);
}
NSDictionary *LBXContainerMutationIPCReply(NSDictionary *request,NSString *result,NSDictionary *state,NSDictionary *configuration,NSArray<NSDictionary *> *entries,NSString *next) {
    @try {NSMutableDictionary *reply=[Base(request,result) mutableCopy];reply[@"state"]=state?:NSNull.null;reply[@"configuration"]=configuration?:NSNull.null;reply[@"entries"]=entries?:@[];reply[@"next"]=next?:@"";
        return LBXContainerMutationIPCValidateReply(reply,request,LBXContainerMutationIPCClock())?Snapshot(reply,65536):LBXContainerMutationIPCFailure(request,@"service_unavailable");}
    @catch(__unused NSException *exception){return LBXContainerMutationIPCFailure(request,@"service_unavailable");}
}
