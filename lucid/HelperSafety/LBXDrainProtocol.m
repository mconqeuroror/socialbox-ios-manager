#import "LBXDrainProtocol.h"
#include <math.h>
#include <time.h>

static BOOL Number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}
static BOOL UUID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 && [[NSUUID alloc] initWithUUIDString:value];
}
double LBXDrainClock(void) {
    struct timespec t;
    return clock_gettime(CLOCK_MONOTONIC, &t) ? NAN : t.tv_sec + t.tv_nsec / 1e9;
}
NSDictionary *LBXServiceCheckReply(id request,double now) {
    if(![request isKindOfClass:NSDictionary.class] || [request count]!=4 || !isfinite(now) || now<0)return nil;
    id version=request[@"version"],deadline=request[@"deadline"];
    if(!Number(version) || [version doubleValue]!=1 || ![request[@"operation"] isEqual:@"check"] ||
       !UUID(request[@"requestID"]) || !Number(deadline) || !isfinite([deadline doubleValue]) ||
       [deadline doubleValue]<=now || [deadline doubleValue]-now>4)return nil;
    return @{@"schemaVersion":@1,@"mode":@"check",@"status":@"authenticated",@"requestID":request[@"requestID"],
             @"networkFenced":@NO,@"launchesFenced":@NO,@"reusableAdmission":@NO};
}
BOOL LBXValidateServiceCheckReply(id reply,NSDictionary *request,double now) {
    NSDictionary *expected=LBXServiceCheckReply(request,now);
    if(!expected || ![reply isKindOfClass:NSDictionary.class] || ![reply isEqual:expected])return NO;
    if(!Number(reply[@"schemaVersion"]))return NO;
    for(NSString *key in @[@"networkFenced",@"launchesFenced",@"reusableAdmission"])
        if(CFGetTypeID((__bridge CFTypeRef)reply[key])!=CFBooleanGetTypeID())return NO;
    return YES;
}
BOOL LBXValidateDrainRequest(id request, double now) {
    if (![request isKindOfClass:NSDictionary.class] || [request count] != 5 || !isfinite(now) || now < 0) return NO;
    id version=request[@"version"], deadline=request[@"deadline"];
    return Number(version) && [version doubleValue] == 1 && [request[@"operation"] isEqual:@"drain"] &&
        LBXDrainSupportedApplication(request[@"bundleID"]) && UUID(request[@"requestID"]) && Number(deadline) &&
        isfinite([deadline doubleValue]) && [deadline doubleValue] > now && [deadline doubleValue] - now <= 4;
}
BOOL LBXValidateDrainReply(id reply, NSDictionary *request, double now) {
    if (!LBXValidateDrainRequest(request,now) || ![reply isKindOfClass:NSDictionary.class]) return NO;
    id version=reply[@"schemaVersion"], absent=reply[@"absentObservations"], elapsed=reply[@"elapsedSeconds"];
    return Number(version) && [version doubleValue] == 1 && [reply[@"mode"] isEqual:@"drain"] &&
        [reply[@"bundleID"] isEqual:request[@"bundleID"]] && [reply[@"requestID"] isEqual:request[@"requestID"]] &&
        [reply[@"status"] isEqual:@"observed_absent"] && [reply[@"reason"] isEqual:@"two_complete_absent_snapshots"] &&
        Number(absent) && [absent doubleValue] == 2 && Number(elapsed) && isfinite([elapsed doubleValue]) &&
        [elapsed doubleValue] >= .02 && [elapsed doubleValue] < 4 &&
        [reply[@"registrationFingerprint"] isKindOfClass:NSString.class] &&
        [reply[@"registrationFingerprint"] length] == 64 &&
        [reply[@"networkFenced"] isEqual:@NO] && [reply[@"launchesFenced"] isEqual:@NO] && [reply[@"reusableAdmission"] isEqual:@NO];
}
NSDictionary *LBXDrainFailure(NSDictionary *request, NSString *reason) {
    return @{@"schemaVersion":@1, @"status":@"failed", @"reason":reason,
        @"requestID":[request[@"requestID"] isKindOfClass:NSString.class]?request[@"requestID"]:@"",
        @"bundleID":[request[@"bundleID"] isKindOfClass:NSString.class]?request[@"bundleID"]:@"",
        @"networkFenced":@NO, @"launchesFenced":@NO, @"reusableAdmission":@NO};
}
