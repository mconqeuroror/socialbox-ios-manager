#import "../lucid/HelperSafety/LBXDrainClient.h"
#import "../lucid/HelperSafety/LBXXPC.h"
static unsigned Checks,Failures,Calls,Cancels,Creates;
static BOOL Result,MissingService;
static double Now=100;
static dispatch_queue_t Queue;
static xpc_object_t Connection;
static NSDictionary *Request;
static void (^Event)(xpc_object_t),(^Response)(xpc_object_t),(^Timeout)(void);
static void Check(BOOL value,const char *reason){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL %s\n",reason);}}
static xpc_connection_t Create(const char *name,dispatch_queue_t queue,uint64_t flags){
    Creates++;Check(!strcmp(name,LBX_DRAIN_SERVICE)&&flags==XPC_CONNECTION_MACH_SERVICE_PRIVILEGED,"only privileged named service");
    if(MissingService)return NULL;
    Queue=queue;Connection=xpc_dictionary_create(NULL,NULL,0);return (xpc_connection_t)Connection;
}
static void Handler(xpc_connection_t c,xpc_handler_t handler){Check((id)c==(id)Connection,"handler belongs to owned connection");Event=[handler copy];}
static void Resume(xpc_connection_t c){Check((id)c==(id)Connection,"resume only owned connection");}
static void Cancel(xpc_connection_t c){Check((id)c==(id)Connection,"cancel only owned connection");Cancels++;}
static void Send(xpc_connection_t c,xpc_object_t message,dispatch_queue_t queue,xpc_handler_t reply){
    Check((id)c==(id)Connection&&queue==Queue,"reply queue scoped to connection");size_t size=0;const void *bytes=xpc_dictionary_get_data(message,"payload",&size);
    Request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size] options:0 error:nil];Response=[reply copy];
}
static void After(dispatch_time_t deadline,dispatch_queue_t queue,dispatch_block_t block){(void)deadline;Check(queue==Queue,"timeout and response serialized together");Timeout=[block copy];}
static double Clock(void){return Now;}
#define LBXCreateMachService Create
#define xpc_connection_set_event_handler Handler
#define xpc_connection_resume Resume
#define xpc_connection_cancel Cancel
#define xpc_connection_send_message_with_reply Send
#define dispatch_after After
#define LBXDrainClock Clock
#import "../lucid/HelperSafety/LBXDrainClient.m"
#undef LBXCreateMachService
#undef xpc_connection_set_event_handler
#undef xpc_connection_resume
#undef xpc_connection_cancel
#undef xpc_connection_send_message_with_reply
#undef dispatch_after
#undef LBXDrainClock
static void Reset(void){Event=nil;Response=nil;Timeout=nil;Connection=nil;Request=nil;Queue=nil;Calls=Cancels=Creates=0;Result=NO;Now=100;MissingService=NO;}
static void Begin(void){LBXRequestApplicationDrain(@"com.burbn.instagram",^(BOOL result){Calls++;Result=result;});}
static NSDictionary *Success(void){return @{@"schemaVersion":@1,@"mode":@"drain",@"status":@"observed_absent",@"reason":@"two_complete_absent_snapshots",@"bundleID":Request[@"bundleID"],@"requestID":Request[@"requestID"],@"elapsedSeconds":@.03,@"absentObservations":@2,@"registrationFingerprint":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"networkFenced":@NO,@"launchesFenced":@NO,@"reusableAdmission":@NO};}
static void Reply(id value){NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];xpc_object_t packet=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_data(packet,"payload",bytes.bytes,bytes.length);dispatch_sync(Queue,^{Response(packet);});}
int main(void){@autoreleasepool{
    Reset();LBXCheckDrainService(^(BOOL value){Calls++;Result=value;});
    Check(Request.count==4&&[Request[@"operation"] isEqual:@"check"]&&!Request[@"bundleID"],"real client emits check without an application target");
    Reply(LBXServiceCheckReply(Request,Now));Check(Calls==1&&Result&&Cancels==1,"read-only check completes exactly once");
    dispatch_sync(Queue,^{Timeout();Event(XPC_ERROR_CONNECTION_INVALID);});Check(Calls==1,"check cannot complete again after timeout or cancellation");
    Reset();LBXCheckDrainService(^(BOOL value){Calls++;Result=value;});
    NSDictionary *good=LBXServiceCheckReply(Request,Now);dispatch_sync(Queue,^{Timeout();});Reply(good);Check(Calls==1&&!Result,"late check reply cannot undo failure");
    Reset();LBXCheckDrainService(^(BOOL value){Calls++;Result=value;});good=LBXServiceCheckReply(Request,Now);Now=103.5;Reply(good);Check(Calls==1&&!Result,"expired check rejected even before timer fires");
    Reset();LBXCheckDrainService(^(BOOL value){Calls++;Result=value;});Reply(@{@"status":@"observed_absent"});Check(Calls==1&&!Result,"drain-like result cannot satisfy a read-only check");
    Reset();MissingService=YES;LBXCheckDrainService(^(BOOL value){Calls++;Result=value;});Check(Calls==1&&!Result,"missing service is never reported available");
    Reset();Now=-1;LBXCheckDrainService(^(BOOL value){Calls++;Result=value;});Check(Calls==1&&!Result&&!Creates,"bad check clock opens no connection");
    Reset();Begin();Check(LBXValidateDrainRequest(Request,Now),"real client emits bounded valid request");Reply(Success());Check(Calls==1&&Result&&Cancels==1,"valid receipt completes exactly once");dispatch_sync(Queue,^{Timeout();Event(XPC_ERROR_CONNECTION_INVALID);});Check(Calls==1&&Cancels==1,"timeout/invalidation after success suppressed");
    Reset();Begin();dispatch_sync(Queue,^{Timeout();});Reply(Success());Check(Calls==1&&!Result&&Cancels==1,"late valid reply cannot undo timeout");
    Reset();Begin();Now=103.5;Reply(Success());Check(Calls==1&&!Result,"reply deadline checked even when timer callback delayed");
    Reset();Begin();NSMutableDictionary *foreign=[Success() mutableCopy];foreign[@"requestID"]=NSUUID.UUID.UUIDString;Reply(foreign);Check(Calls==1&&!Result,"foreign operation receipt refused by real client");
    Reset();Begin();Reply(@[@"bad"]);Check(Calls==1&&!Result,"wrong JSON container refused");
    Reset();Begin();xpc_object_t packet=xpc_dictionary_create(NULL,NULL,0);NSMutableData *huge=[NSMutableData dataWithLength:32769];xpc_dictionary_set_data(packet,"payload",huge.bytes,huge.length);dispatch_sync(Queue,^{Response(packet);});Check(Calls==1&&!Result,"oversized response refused before JSON decode");
    Reset();Begin();dispatch_sync(Queue,^{Event(XPC_ERROR_CONNECTION_INTERRUPTED);});Check(Calls==1&&!Result,"service interruption produces failure");
    Reset();MissingService=YES;Begin();Check(Calls==1&&!Result&&!Cancels,"unavailable Mach service cannot succeed");
    Reset();LBXRequestApplicationDrain(@"com.apple.Preferences",^(BOOL value){Calls++;Result=value;});Check(Calls==1&&!Result&&!Creates,"unsupported app creates no connection");
    printf("%s helper client: %u checks, %u failures; XPC transport mocked\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
