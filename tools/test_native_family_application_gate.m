#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXNativeFamilyApplicationGate.h"
static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
@interface LBXNativeApplicationGate : NSObject
@property(nonatomic,copy)NSDictionary *privateJournalRecord;
@property(nonatomic,copy)NSDictionary *safeStatus;
@property(nonatomic)BOOL drainOK;
@property(nonatomic)BOOL restoreOK;
@property(nonatomic)NSUInteger drains;
@property(nonatomic)NSUInteger restores;
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@end
@implementation LBXNativeApplicationGate
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error {(void)deadline;_drains++;if(error)*error=nil;return _drainOK;}
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error {
    (void)deadline;_restores++;if(error)*error=nil;return authorization&&authorization()&&_restoreOK;
}
@end
static LBXNativeApplicationGate *Make(NSString *bundle,BOOL drain,BOOL restore){
    LBXNativeApplicationGate *g=[LBXNativeApplicationGate new];
    g.privateJournalRecord=@{@"binding":@{@"bundleIdentifier":bundle}};
    g.safeStatus=@{@"runtimeAccepted":@NO,@"isolationVerified":@NO};
    g.drainOK=drain;g.restoreOK=restore;return g;
}
int main(void){@autoreleasepool{
    NSError *error=nil;
    LBXNativeApplicationGate *ig=Make(@"com.burbn.instagram",YES,YES),*fb=Make(@"com.facebook.Facebook",YES,YES);
    LBXNativeFamilyApplicationGate *family=[LBXNativeFamilyApplicationGate gateWithInstagram:ig facebook:fb error:&error];
    Check(family&&!error,@"official pair admitted");
    Check([family.safeStatus[@"isolationVerified"] isEqual:@NO]&&[family.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"family gate is not isolation");
    Check([family.safeStatus[@"installedSwitchConnected"] isEqual:@NO],@"family gate is not installed switch");
    Check(![LBXNativeFamilyApplicationGate gateWithInstagram:fb facebook:ig error:&error],@"swapped official roles refused");
    Check(![LBXNativeFamilyApplicationGate gateWithInstagram:ig facebook:ig error:&error],@"same object cannot cover both apps");
    Check(![LBXNativeFamilyApplicationGate gateWithInstagram:ig facebook:Make(@"com.twitter.twitter",YES,YES) error:&error],@"Twitter cannot join the family execution gate");
    Check(![family restoreExecutionBeforeDeadline:1 authorization:^BOOL{return YES;} error:&error],@"restore before drain refused");
    Check([family closeAndDrainBeforeDeadline:1 error:&error]&&ig.drains==1&&fb.drains==1,@"close drains Instagram and Facebook");
    Check([family.safeStatus[@"familyDrainVerified"] isEqual:@YES],@"both drains recorded");
    Check([family restoreExecutionBeforeDeadline:1 authorization:^BOOL{return YES;} error:&error]&&fb.restores==1&&ig.restores==1,@"restore opens Facebook then Instagram");
    Check([family.safeStatus[@"executionRestored"] isEqual:@YES]&&[family.safeStatus[@"isolationVerified"] isEqual:@NO],@"restore does not claim isolation");
    LBXNativeApplicationGate *failFB=Make(@"com.facebook.Facebook",NO,YES);
    LBXNativeFamilyApplicationGate *partial=[LBXNativeFamilyApplicationGate gateWithInstagram:Make(@"com.burbn.instagram",YES,YES) facebook:failFB error:&error];
    Check(partial&&![partial closeAndDrainBeforeDeadline:1 error:&error]&&error.code==4,@"Facebook drain failure refuses the family close");
    LBXNativeApplicationGate *closedIG=Make(@"com.burbn.instagram",YES,YES),*closedFB=Make(@"com.facebook.Facebook",YES,NO);
    LBXNativeFamilyApplicationGate *restoreFail=[LBXNativeFamilyApplicationGate gateWithInstagram:closedIG facebook:closedFB error:&error];
    Check([restoreFail closeAndDrainBeforeDeadline:1 error:&error],@"pair drains");
    Check(![restoreFail restoreExecutionBeforeDeadline:1 authorization:^BOOL{return YES;} error:&error]&&closedFB.restores==1&&closedIG.restores==0,@"Facebook restore failure leaves Instagram closed");
    printf("PASS: %lu native family application-gate assertions\n",(unsigned long)Checks);return 0;
}}
