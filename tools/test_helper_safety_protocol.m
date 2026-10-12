#import "../lucid/HelperSafety/LBXDrainProtocol.h"
#include <math.h>
static unsigned checks,failures;
static void Check(BOOL value,const char *reason){checks++;if(!value){failures++;fprintf(stderr,"FAIL %s\n",reason);}}
static NSDictionary *Request(void){return @{@"version":@1,@"operation":@"drain",@"bundleID":@"com.burbn.instagram",@"requestID":@"11111111-1111-4111-8111-111111111111",@"deadline":@103.5};}
static NSDictionary *Reply(void){return @{@"schemaVersion":@1,@"mode":@"drain",@"status":@"observed_absent",@"reason":@"two_complete_absent_snapshots",@"bundleID":Request()[@"bundleID"],@"requestID":Request()[@"requestID"],@"elapsedSeconds":@.03,@"absentObservations":@2,@"registrationFingerprint":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"networkFenced":@NO,@"launchesFenced":@NO,@"reusableAdmission":@NO};}
int main(void){@autoreleasepool{
    NSMutableDictionary *check=[Request() mutableCopy];check[@"operation"]=@"check";[check removeObjectForKey:@"bundleID"];
    NSDictionary *checked=LBXServiceCheckReply(check,100);
    Check(checked&&LBXValidateServiceCheckReply(checked,check,100),"authenticated read-only reply accepted for its own nonce");
    Check(!LBXValidateDrainRequest(check,100)&&!LBXValidateDrainReply(checked,Request(),100),"check cannot authorize a drain or claim an absent app");
    Check(!LBXServiceCheckReply(Request(),100)&&!LBXValidateServiceCheckReply(Reply(),check,100),"drain cannot impersonate check response");
    for(NSString *key in check){NSMutableDictionary *bad=[check mutableCopy];[bad removeObjectForKey:key];Check(!LBXServiceCheckReply(bad,100),"missing check request field rejected");}
    for(NSString *key in @[@"bundleID",@"pid",@"path"]){NSMutableDictionary *bad=[check mutableCopy];bad[key]=@"foreign";Check(!LBXServiceCheckReply(bad,100),"read-only check has no target or caller-supplied authority");}
    for(id deadline in @[@YES,@0,@100,@104.01,@(NAN),@(INFINITY),@"103",NSNull.null]){NSMutableDictionary *bad=[check mutableCopy];bad[@"deadline"]=deadline;Check(!LBXServiceCheckReply(bad,100),"malformed or late read-only check rejected");}
    for(NSString *key in checked){NSMutableDictionary *bad=[checked mutableCopy];[bad removeObjectForKey:key];Check(!LBXValidateServiceCheckReply(bad,check,100),"missing read-only reply field rejected");}
    for(NSString *key in @[@"networkFenced",@"launchesFenced",@"reusableAdmission"]){NSMutableDictionary *bad=[checked mutableCopy];bad[key]=@0;Check(!LBXValidateServiceCheckReply(bad,check,100),"numeric zero cannot counterfeit boolean claims");bad[key]=@YES;Check(!LBXValidateServiceCheckReply(bad,check,100),"check never claims launch or network authority");}
    NSMutableDictionary *foreignCheck=[checked mutableCopy];foreignCheck[@"requestID"]=NSUUID.UUID.UUIDString;Check(!LBXValidateServiceCheckReply(foreignCheck,check,100),"foreign check nonce refused");
    Check(!LBXValidateServiceCheckReply(checked,check,103.5)&&!LBXServiceCheckReply(check,NAN),"expired check or unavailable clock refused");
    Check(LBXValidateDrainRequest(Request(),100),"valid bounded exact-app request");
    Check(LBXValidateDrainReply(Reply(),Request(),100.1),"actual drain shape accepted before deadline");
    for(NSString *bundle in LBXManagedApplications()){
        NSMutableDictionary *r=[Request() mutableCopy];r[@"bundleID"]=bundle;
        Check(LBXValidateDrainRequest(r,100),"registered managed app admitted");
        r[@"bundleID"]=[bundle stringByAppendingString:@".evil"];
        Check(!LBXValidateDrainRequest(r,100),"bundle prefix alone never gives authority");
    }
    for(id bundle in @[@"com.socialbox.app",@"com.apple.Preferences",@"com.redditbox",@"com.atebits.Tweetie2",@"com.reddit.Reddit.ShareExtension",@"Instagram",@"/bin/launchctl",@42,NSNull.null]){
        NSMutableDictionary *r=[Request() mutableCopy];r[@"bundleID"]=bundle;Check(!LBXValidateDrainRequest(r,100),"control plane, unsupported app, standalone extension, names and paths rejected");
    }
    for(NSString *key in Request()) {NSMutableDictionary *r=[Request() mutableCopy];[r removeObjectForKey:key];Check(!LBXValidateDrainRequest(r,100),"missing request field rejected");}
    for(id version in @[@YES,@0,@1.5,@"1",NSNull.null]){NSMutableDictionary *r=[Request() mutableCopy];r[@"version"]=version;Check(!LBXValidateDrainRequest(r,100),"strict protocol version type/value");}
    for(id deadline in @[@YES,@0,@100,@104.01,@(NAN),@(INFINITY),@"103",NSNull.null]){NSMutableDictionary *r=[Request() mutableCopy];r[@"deadline"]=deadline;Check(!LBXValidateDrainRequest(r,100),"expired, excessive or malformed budget rejected");}
    Check(!LBXValidateDrainRequest(Request(),NAN)&&!LBXValidateDrainRequest(Request(),-1),"bad server clock refuses request");
    NSMutableDictionary *r=[Request() mutableCopy];r[@"pid"]=@42;Check(!LBXValidateDrainRequest(r,100),"extra authority fields rejected");
    for(NSString *key in Reply()){NSMutableDictionary *p=[Reply() mutableCopy];[p removeObjectForKey:key];Check(!LBXValidateDrainReply(p,Request(),100),"missing reply field cannot become success");}
    for(NSString *key in @[@"bundleID",@"requestID",@"status",@"reason",@"mode"]){NSMutableDictionary *p=[Reply() mutableCopy];p[key]=@"foreign";Check(!LBXValidateDrainReply(p,Request(),100),"foreign request/app/status is not acknowledgement");}
    for(id elapsed in @[@YES,@0,@(-1),@.019,@4,@(NAN),@(INFINITY),@"0.02"]){NSMutableDictionary *p=[Reply() mutableCopy];p[@"elapsedSeconds"]=elapsed;Check(!LBXValidateDrainReply(p,Request(),100),"invalid observation duration rejected");}
    for(NSString *key in @[@"schemaVersion",@"absentObservations"]){NSMutableDictionary *p=[Reply() mutableCopy];p[key]=@YES;Check(!LBXValidateDrainReply(p,Request(),100),"boolean cannot counterfeit numeric evidence");}
    for(NSString *key in @[@"networkFenced",@"launchesFenced",@"reusableAdmission"]){NSMutableDictionary *p=[Reply() mutableCopy];p[key]=@YES;Check(!LBXValidateDrainReply(p,Request(),100),"a drain cannot claim a network/launch fence");}
    Check(!LBXValidateDrainReply(Reply(),Request(),103.5),"reply at deadline is late");
    Check(!LBXValidateDrainReply(LBXDrainFailure(Request(),@"denied"),Request(),100),"failure packet cannot become success");
    Check(!LBXValidateDrainReply(@[],Request(),100)&&!LBXValidateDrainRequest(NSNull.null,100),"malformed containers safely rejected");
    printf("%s helper protocol: %u checks, %u failures\n",failures?"FAIL":"PASS",checks,failures);return failures?1:0;
}}
