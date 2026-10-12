#import "../lucid/HelperSafety/LBXDrainClient.h"
#import <objc/message.h>
static unsigned Checks,Failures,Legacy,Drains,Replies,ServiceChecks;
static BOOL DrainResult,LastReply;
void LBXRequestApplicationDrain(NSString *bundleID,void (^completion)(BOOL)) { (void)bundleID;Drains++;completion(DrainResult); }
void LBXCheckDrainService(void (^completion)(BOOL)){ServiceChecks++;completion(NO);}
static void Check(BOOL value,const char *reason){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL %s\n",reason);}}
@interface HelperFixture : NSObject
- (void)killApp:(NSString *)app reply:(void (^)(BOOL))reply;
@end
@implementation HelperFixture
- (void)killApp:(NSString *)app reply:(void (^)(BOOL))reply { (void)app;Legacy++;reply(YES); }
@end
@interface InheritedFixture : HelperFixture
@end
@implementation InheritedFixture
@end
@interface BadFixture : NSObject
- (BOOL)killApp:(NSString *)app reply:(void (^)(BOOL))reply;
@end
@implementation BadFixture
- (BOOL)killApp:(NSString *)app reply:(void (^)(BOOL))reply { (void)app;(void)reply;return YES; }
@end
#import "../lucid/HelperSafety/LBXHelperSafety.m"
static void Reply(BOOL result){Replies++;LastReply=result;}
int main(void){@autoreleasepool{
    Check(ServiceChecks==0,"foreign executable constructor never probes service");
    NSString *path=[NSBundle.mainBundle.executablePath stringByResolvingSymlinksInPath];
    Check(!LBXInstallHelperMethod(BadFixture.class,path),"wrong return ABI refused");
    Check(!LBXInstallHelperMethod(InheritedFixture.class,path),"inherited method cannot alter unrelated owner");
    Check(!LBXInstallHelperMethod(HelperFixture.class,@"/untrusted/image"),"foreign method image refused");
    HelperFixture *helper=[HelperFixture new];[helper killApp:@"com.burbn.instagram" reply:^(BOOL value){Reply(value);}];
    Check(Legacy==1&&Replies==1&&LastReply,"baseline fixture action reachable before hook");
    Check(LBXInstallHelperMethod(HelperFixture.class,path),"actual hook installs on exact recovered ABI");
    for(NSString *app in LBXManagedApplications()){
        unsigned before=Replies;DrainResult=YES;[helper killApp:app reply:^(BOOL value){Reply(value);}];Check(Replies==before+1&&LastReply&&Legacy==1,"success uses exactly one BOOL and never old name kill");
        DrainResult=NO;[helper killApp:app reply:^(BOOL value){Reply(value);}];Check(Replies==before+2&&!LastReply&&Legacy==1,"service failure preserved, no original fallback");
    }
    unsigned before=Drains;[helper killApp:@"com.apple.Preferences" reply:^(BOOL value){Reply(value);}];Check(!LastReply&&Drains==before&&Legacy==1,"system apps never reach service or original handler");
    [helper killApp:@"com.burbn.instagram" reply:nil];Check(Drains==before,"nil callback has no effects");
    printf("%s helper method: %u checks, %u failures; original host is synthetic\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
