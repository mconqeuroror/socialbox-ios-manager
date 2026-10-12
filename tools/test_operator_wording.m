#import <Foundation/Foundation.h>
#import "RBXOperatorWording.h"
#import "RBXIdentityReview.h"
int main(void) { @autoreleasepool {
    NSCAssert([RBXOperatorText(@"NOT_RUN") isEqual:@"NOT VERIFIED"], @"no invented pass");
    NSCAssert([RBXOperatorMessage(@"error domain=NSPOSIX Code=9") isEqual:RBXOperatorText(@"fallback")], @"raw error codes stay advanced");
    NSCAssert([RBXOperatorMessage(@"Proxy country is DE but identity requests US") containsString:@"must match"], @"country mismatch action");
    NSCAssert([RBXOperatorMessage(@"Decrypted source imported") isEqual:@"Decrypted source imported"], @"successful import is not an encryption failure");
    NSCAssert([RBXOperatorMessage(@"License activated; firewall ready") isEqual:@"License activated; firewall ready"], @"success wording is not converted into a failure");
    NSCAssert([RBXOperatorCountry(@"us") hasSuffix:@"US"], @"valid country flag");
    NSCAssert([RBXOperatorCountry(@"12") isEqual:@"Country not verified"], @"invalid country not guessed");
    NSDictionary *row = @{@"isActive":@YES,@"vpnArmed":@YES,@"hooksReady":@YES};
    NSDictionary *state = @{@"updatedAt":@100,@"networkState":@"open",@"firewallSetup":@{@"ready":@YES}};
    NSCAssert([RBXSimpleContainerPresentation(row,state,105)[@"status"] isEqual:@"ready"], @"fresh active snapshot");
    NSMutableDictionary *quarantined=[row mutableCopy]; quarantined[@"launchBlockReason"]=@"Isolation alert";
    NSCAssert([RBXSimpleContainerPresentation(quarantined,state,105)[@"status"] isEqual:@"locked"], @"Retained alert takes priority over old OPEN/readiness labels");
    NSCAssert([RBXSimpleContainerPresentation(row,state,111)[@"status"] isEqual:@"locked"], @"stale active snapshot not ready");
    NSCAssert([RBXSimpleContainerPresentation(@{},state,105)[@"status"] isEqual:@"idle"], @"inactive profile is not called ready");
    NSCAssert([RBXSimpleContainerPresentation(@{@"deletionState":@{}},state,105)[@"status"] isEqual:@"locked"], @"cleanup remains visible");
    NSDictionary *choices = @{@"country":@"US",@"productType":@"iPhone14,2"};
    NSCAssert(!RBXIdentityReviewCanApply(choices,nil,NO,NO), @"unvalidated review cannot apply");
    NSCAssert(RBXIdentityReviewCanApply(choices,choices,NO,NO), @"matching validated review can apply");
    NSCAssert(!RBXIdentityReviewCanApply(@{@"country":@"DE"},choices,NO,NO), @"edited choices invalidate the preview");
    NSCAssert(!RBXIdentityReviewCanApply(choices,choices,YES,NO), @"pending check blocks apply");
    NSCAssert(!RBXIdentityReviewCanApply(choices,choices,NO,YES), @"proxy mismatch blocks apply");
    NSCAssert(RBXContainerSetupMessage(@{@"firewallSetup":@{@"ready":@NO}}) != nil, @"unfinished setup explains blocked Open");
    NSCAssert(RBXContainerSetupMessage(@{}) != nil, @"missing setup cannot pretend ready");
    NSCAssert(RBXContainerSetupMessage(@{@"firewallSetup":NSNull.null}) != nil, @"malformed setup remains blocked");
    NSCAssert(RBXContainerSetupMessage(@{@"firewallSetup":@{@"ready":@"yes"}}) != nil, @"wrong readiness type cannot pass");
    NSCAssert(RBXContainerSetupMessage(@{@"firewallSetup":@{@"ready":@YES}}) == nil, @"ready setup continues to authoritative daemon checks");
    puts("PASS: operator wording and conservative Simple status presentation");
} return 0; }
