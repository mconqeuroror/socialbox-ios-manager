#import "LBXLicenseIPC.h"
#include <math.h>

static BOOL Number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static BOOL Identifier(id value) {
    return [value isKindOfClass:NSString.class] && [value length]==36 &&
        [[[NSUUID alloc] initWithUUIDString:value].UUIDString.lowercaseString isEqual:value];
}
static BOOL Key(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=19)return NO;
    return NSEqualRanges([value rangeOfString:@"[A-HJ-NP-Z2-9]{4}(?:-[A-HJ-NP-Z2-9]{4}){3}" options:NSRegularExpressionSearch],NSMakeRange(0,19));
}
static NSSet *Results(void) {
    static NSSet *values;static dispatch_once_t once;
    dispatch_once(&once,^{values=[NSSet setWithArray:@[@"unchecked",@"active",@"revoked",@"expired",@"invalid",
        @"busy",@"activation_required",@"paired_key_mismatch",@"recovery_required",@"storage_unavailable",
        @"verification_failed",@"service_unavailable",@"invalid_request"]];});return values;
}
double LBXLicenseIPCClock(void) { return NSProcessInfo.processInfo.systemUptime; }
BOOL LBXLicenseIPCValidateRequest(id request,double now) {
    if(![request isKindOfClass:NSDictionary.class] || !Number(request[@"version"]) || ![request[@"version"] isEqual:@1] ||
       !Identifier(request[@"requestID"]) || !Number(request[@"deadline"]) || !isfinite(now) || now<0 ||
       [request[@"deadline"] doubleValue]<=now || [request[@"deadline"] doubleValue]>now+25)return NO;
    NSString *operation=request[@"operation"];
    BOOL activate=[operation isKindOfClass:NSString.class]&&[operation isEqual:@"activate"];
    if(!activate && ![operation isEqual:@"status"] && ![operation isEqual:@"validate"])return NO;
    NSSet *keys=[NSSet setWithArray:activate?@[@"version",@"requestID",@"operation",@"deadline",@"key"]:@[@"version",@"requestID",@"operation",@"deadline"]];
    return [[NSSet setWithArray:[request allKeys]] isEqual:keys] && (!activate || Key(request[@"key"]));
}
NSDictionary *LBXLicenseIPCRequest(NSString *operation,NSString *key) {
    if(![operation isKindOfClass:NSString.class] || (key&&![key isKindOfClass:NSString.class]))return nil;
    NSMutableDictionary *request=[@{@"version":@1,@"operation":[operation copy],@"requestID":NSUUID.UUID.UUIDString.lowercaseString,
        @"deadline":@(LBXLicenseIPCClock()+24)} mutableCopy];
    if(key)request[@"key"]=[[key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    return LBXLicenseIPCValidateRequest(request,LBXLicenseIPCClock())?[request copy]:nil;
}
NSDictionary *LBXLicenseIPCReply(NSDictionary *request,NSString *result,BOOL paired) {
    // Explicit projection: never serialize a configuration, signed receipt or NSError.
    return @{@"version":@1,@"requestID":Identifier(request[@"requestID"])?request[@"requestID"]:@"",
        @"operation":[@[@"status",@"activate",@"validate"] containsObject:request[@"operation"]?:@""]?request[@"operation"]:@"",
        @"result":[Results() containsObject:result]?result:@"verification_failed",@"paired":@(paired),@"engineAuthorized":@NO};
}
BOOL LBXLicenseIPCValidateReply(id reply,NSDictionary *request,double now) {
    if(!LBXLicenseIPCValidateRequest(request,now) || ![reply isKindOfClass:NSDictionary.class] ||
       ![[NSSet setWithArray:[reply allKeys]] isEqual:[NSSet setWithArray:@[@"version",@"requestID",@"operation",@"result",@"paired",@"engineAuthorized"]]] ||
       !Number(reply[@"version"]) || ![reply[@"version"] isEqual:@1] || ![reply[@"requestID"] isEqual:request[@"requestID"]] ||
       ![reply[@"operation"] isEqual:request[@"operation"]] || ![Results() containsObject:reply[@"result"]?:@""] ||
       ![reply[@"paired"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)reply[@"paired"])!=CFBooleanGetTypeID() ||
       ![reply[@"engineAuthorized"] isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)reply[@"engineAuthorized"])!=CFBooleanGetTypeID() ||
       [reply[@"engineAuthorized"] boolValue])return NO;
    // Status is a read-only projection, never an old active assessment.
    return !([reply[@"result"] isEqual:@"active"] &&
        ([request[@"operation"] isEqual:@"status"] || ![reply[@"paired"] boolValue]));
}
