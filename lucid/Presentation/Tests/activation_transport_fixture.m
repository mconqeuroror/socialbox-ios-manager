#import "../../Authorization/LBXLicenseClient.h"
#import "activation_transport_fixture.h"
#import "saved_setup_transport_fixture.h"
#import "../../Authorization/LBXLicenseIPC.h"
// Only linked by the simulator fixture, never by a production source glob.
static NSUInteger requests;
static NSString *capturedKey;
static void (^pending)(NSDictionary *);
static NSDictionary *pendingRequest;
static NSDictionary *replayReply;
static void (^replay)(NSDictionary *);
void LBXSendLicenseRequest(NSString *operation,NSString *key,void (^completion)(NSDictionary *)){
    if([operation isEqual:@"validate"]){SBTestSavedSetupValidate(completion);return;}
    NSCAssert([operation isEqual:@"activate"],@"Unexpected UI licensing operation");
    requests++;capturedKey=[key copy];pending=[completion copy];pendingRequest=LBXLicenseIPCRequest(operation,key);
}
NSUInteger SBTestLicenseRequestCount(void){return requests;}
NSString *SBTestLicenseRequestedKey(void){return capturedKey;}
void SBTestLicenseCompleteFields(NSDictionary *overrides){
    void (^complete)(NSDictionary *)=pending;pending=nil;capturedKey=nil;
    NSMutableDictionary *reply=[LBXLicenseIPCReply(pendingRequest,@"active",YES) mutableCopy];pendingRequest=nil;
    [reply addEntriesFromDictionary:overrides];replay=complete;replayReply=[reply copy];
    if(complete)complete(reply);
}
void SBTestLicenseComplete(NSString *result){SBTestLicenseCompleteFields(@{@"result":result});}
void SBTestLicenseReplay(void){if(replay&&replayReply)replay(replayReply);}
