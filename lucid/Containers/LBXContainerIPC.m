#import "LBXContainerIPC.h"
#import "LBXContainerConfiguration.h"
#include <limits.h>
#include <math.h>

static NSString *const Family=@"container-configuration";
static BOOL Exact(id value,NSArray *keys) {
    if(![value isKindOfClass:NSDictionary.class]||[value count]!=keys.count)return NO;
    for(id key in value)if(![key isKindOfClass:NSString.class])return NO;
    return [[NSSet setWithArray:[value allKeys]] isEqual:[NSSet setWithArray:keys]];
}
static BOOL Number(id value) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue]);
}
static BOOL Revision(id value) {
    if(!Number(value)||CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    const char *type=[value objCType];
    return type&&strchr("cislqCISLQ",type[0])&&!type[1]&&[value longLongValue]>0&&[value unsignedLongLongValue]<=LLONG_MAX;
}
static BOOL UUID(id value) {
    return [value isKindOfClass:NSString.class]&&[value length]==36&&
        [[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value]&&
        ![value isEqual:@"00000000-0000-0000-0000-000000000000"];
}
static NSSet *Operations(void) {
    static NSSet *values;static dispatch_once_t once;
    dispatch_once(&once,^{values=[NSSet setWithArray:@[@"prepare",@"create",@"update",@"read",@"list"]];});return values;
}
static NSSet *Results(void) {
    static NSSet *values;static dispatch_once_t once;
    dispatch_once(&once,^{values=[NSSet setWithArray:@[@"prepared",@"saved",@"record",@"missing",@"listed",@"conflict",
        @"authorization_required",@"storage_unavailable",@"invalid_request",@"service_unavailable",@"unconfirmed"]];});return values;
}
static BOOL Success(NSString *result) {return [@[@"prepared",@"saved",@"record",@"listed"] containsObject:result];}
static NSDictionary *Document(id value) {
    LBXContainerConfiguration *parsed=[LBXContainerConfiguration fromDictionary:value error:nil];
    return parsed&&[parsed.privateDictionary isEqual:value]?parsed.privateDictionary:nil;
}
static BOOL BoundedJSON(id value,NSUInteger maximum) {
    if(![NSJSONSerialization isValidJSONObject:value])return NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data.length&&data.length<=maximum;
}
static NSArray *CanonicalApplications(NSArray *value) {
    NSMutableArray *result=[NSMutableArray array];
    for(NSString *app in @[@"com.burbn.instagram",@"com.facebook.Facebook",@"com.atebits.Tweetie2"])
        if([value containsObject:app])[result addObject:app];
    return [result copy];
}
double LBXContainerIPCClock(void) {return NSProcessInfo.processInfo.systemUptime;}
BOOL LBXContainerIPCValidateRequest(id request,double now) {
    if(![request isKindOfClass:NSDictionary.class]||![request[@"family"] isEqual:Family]||!Revision(request[@"version"])||
        ![request[@"version"] isEqual:@1]||!UUID(request[@"requestID"])||!Number(request[@"deadline"])||
        !isfinite(now)||now<0||[request[@"deadline"] doubleValue]<=now||[request[@"deadline"] doubleValue]>now+25||
        ![Operations() containsObject:request[@"operation"]?:NSNull.null]||!BoundedJSON(request,16384))return NO;
    NSString *operation=request[@"operation"];NSMutableArray *keys=[@[@"family",@"version",@"requestID",@"operation",@"deadline"] mutableCopy];
    if([operation isEqual:@"prepare"]) {
        [keys addObject:@"choices"];id choices=request[@"choices"];
        return Exact(request,keys)&&Exact(choices,@[@"name",@"applications",@"manualIdentifiers",@"proxyReference"])&&
            LBXContainerConfigurationValidateChoices(choices[@"name"],choices[@"applications"],
                choices[@"manualIdentifiers"]==NSNull.null?nil:choices[@"manualIdentifiers"],choices[@"proxyReference"]);
    }
    if([operation isEqual:@"create"]||[operation isEqual:@"update"]) {
        [keys addObject:@"configuration"];if([operation isEqual:@"update"])[keys addObject:@"expected"];
        NSDictionary *candidate=Document(request[@"configuration"]);
        if(!Exact(request,keys)||!candidate)return NO;
        if([operation isEqual:@"create"])return [candidate[@"revision"] isEqual:@1];
        NSDictionary *expected=Document(request[@"expected"]);
        return expected&&[expected[@"identifier"] isEqual:candidate[@"identifier"]]&&
            [expected[@"revision"] unsignedLongLongValue]<LLONG_MAX&&
            [candidate[@"revision"] unsignedLongLongValue]==[expected[@"revision"] unsignedLongLongValue]+1;
    }
    if([operation isEqual:@"read"]) {[keys addObject:@"identifier"];return Exact(request,keys)&&UUID(request[@"identifier"]);}
    [keys addObject:@"after"];id after=request[@"after"];
    return Exact(request,keys)&&[after isKindOfClass:NSString.class]&&(![after length]||UUID(after));
}
NSDictionary *LBXContainerIPCRequest(NSString *operation,NSDictionary *arguments) {
    if(![operation isKindOfClass:NSString.class]||![arguments isKindOfClass:NSDictionary.class])return nil;
    NSSet *base=[NSSet setWithArray:@[@"family",@"version",@"requestID",@"operation",@"deadline"]];
    for(id key in arguments)if([base containsObject:key])return nil;
    NSMutableDictionary *request=[@{@"family":Family,@"version":@1,@"requestID":NSUUID.UUID.UUIDString.lowercaseString,
        @"operation":[operation copy],@"deadline":@(LBXContainerIPCClock()+24)} mutableCopy];
    [request addEntriesFromDictionary:arguments];if(!LBXContainerIPCValidateRequest(request,LBXContainerIPCClock()))return nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
NSDictionary *LBXContainerIPCListEntry(NSDictionary *configuration) {
    NSDictionary *value=Document(configuration);if(!value)return nil;
    return @{@"identifier":value[@"identifier"],@"revision":value[@"revision"],@"name":value[@"name"],@"applications":value[@"applications"]};
}
static NSDictionary *BaseReply(NSDictionary *request,NSString *result) {
    BOOL dictionary=[request isKindOfClass:NSDictionary.class];
    id identifier=dictionary?request[@"requestID"]:nil,operation=dictionary?request[@"operation"]:nil;
    return @{@"family":Family,@"version":@1,@"requestID":UUID(identifier)?[identifier copy]:@"",
        @"operation":[Operations() containsObject:operation?:NSNull.null]?[operation copy]:@"",
        @"result":[Results() containsObject:result?:NSNull.null]?[result copy]:@"service_unavailable",@"runtimeAccepted":@NO,
        @"configuration":NSNull.null,@"entries":@[],@"next":@""};
}
NSDictionary *LBXContainerIPCFailure(NSDictionary *request,NSString *result) {
    if(![Results() containsObject:result?:NSNull.null]||Success(result))result=@"service_unavailable";
    if([result isEqual:@"missing"]&&(![request isKindOfClass:NSDictionary.class]||![request[@"operation"] isEqual:@"read"]))result=@"service_unavailable";
    return BaseReply(request,result);
}
NSDictionary *LBXContainerIPCReply(NSDictionary *request,NSString *result,NSDictionary *configuration,NSArray<NSDictionary *> *entries,NSString *next) {
    NSMutableDictionary *reply=[BaseReply(request,result) mutableCopy];
    reply[@"configuration"]=configuration?:NSNull.null;reply[@"entries"]=entries?:@[];reply[@"next"]=next?:@"";
    if(!LBXContainerIPCValidateReply(reply,request,LBXContainerIPCClock()))return LBXContainerIPCFailure(request,@"service_unavailable");
    NSData *data=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
BOOL LBXContainerIPCValidateReply(id reply,NSDictionary *request,double now) {
    if(!LBXContainerIPCValidateRequest(request,now)||!Exact(reply,@[@"family",@"version",@"requestID",@"operation",@"result",@"runtimeAccepted",@"configuration",@"entries",@"next"])||
        ![reply[@"family"] isEqual:Family]||!Revision(reply[@"version"])||![reply[@"version"] isEqual:@1]||
        ![reply[@"requestID"] isEqual:request[@"requestID"]]||![reply[@"operation"] isEqual:request[@"operation"]]||
        ![Results() containsObject:reply[@"result"]?:NSNull.null]||
        ![reply[@"runtimeAccepted"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)reply[@"runtimeAccepted"])!=CFBooleanGetTypeID()||
        [reply[@"runtimeAccepted"] boolValue]||![reply[@"entries"] isKindOfClass:NSArray.class]||![reply[@"next"] isKindOfClass:NSString.class]||!BoundedJSON(reply,65536))return NO;
    NSString *operation=request[@"operation"],*result=reply[@"result"];
    NSArray *entries=reply[@"entries"];NSString *next=reply[@"next"];
    if(!Success(result))return reply[@"configuration"]==NSNull.null&&entries.count==0&&!next.length&&
        (![result isEqual:@"missing"]||[operation isEqual:@"read"]);
    if([result isEqual:@"listed"]) {
        if(![operation isEqual:@"list"]||reply[@"configuration"]!=NSNull.null||entries.count>40)return NO;
        NSString *previous=request[@"after"];
        for(id entry in entries) {
            if(!Exact(entry,@[@"identifier",@"revision",@"name",@"applications"])||!UUID(entry[@"identifier"])||!Revision(entry[@"revision"])||
                !LBXContainerConfigurationValidateChoices(entry[@"name"],entry[@"applications"],nil,@"")||
                ![entry[@"applications"] isEqual:CanonicalApplications(entry[@"applications"])]||
                (previous.length&&[previous compare:entry[@"identifier"]]!=NSOrderedAscending))return NO;
            previous=entry[@"identifier"];
        }
        return !next.length||(entries.count==40&&UUID(next)&&[next isEqual:entries.lastObject[@"identifier"]]);
    }
    if(entries.count||next.length)return NO;
    NSDictionary *configuration=Document(reply[@"configuration"]);if(!configuration)return NO;
    if([result isEqual:@"prepared"]&&[operation isEqual:@"prepare"]) {
        NSDictionary *choices=request[@"choices"];BOOL random=choices[@"manualIdentifiers"]==NSNull.null;
        return [configuration[@"revision"] isEqual:@1]&&[configuration[@"name"] isEqual:choices[@"name"]]&&
            [configuration[@"applications"] isEqual:CanonicalApplications(choices[@"applications"])]&&
            [configuration[@"proxyReference"] isEqual:choices[@"proxyReference"]]&&
            [configuration[@"identifierMode"] isEqual:random?@"random":@"manual"]&&
            (random||[configuration[@"identifiers"] isEqual:choices[@"manualIdentifiers"]]);
    }
    if([result isEqual:@"saved"]&&[@[@"create",@"update"] containsObject:operation])return [configuration isEqual:request[@"configuration"]];
    return [result isEqual:@"record"]&&[operation isEqual:@"read"]&&[configuration[@"identifier"] isEqual:request[@"identifier"]];
}
