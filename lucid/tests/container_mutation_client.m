#import <Foundation/Foundation.h>
#import "../Containers/LBXContainerMutationIPC.h"
#import "../Containers/LBXContainerConfiguration.h"
#import "../Authorization/LBXLicensePeer.h"
#import "../Authorization/LBXLicenseEndpoints.h"
#include <xpc/xpc.h>
#include <dlfcn.h>
static NSUInteger Checks,Failures,Factories,Resumes,Cancels,Completions,PeerChecks;
static BOOL FactoryAvailable=YES,Authenticated=YES;
static dispatch_queue_t Queue;
static void (^EventHandler)(xpc_object_t),(^ReplyHandler)(xpc_object_t),(^Timeout)(void);
static NSDictionary *Wire,*Result;
static double Now;
static void Check(BOOL value,NSString *label){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL: %s\n",label.UTF8String);}}
static xpc_connection_t Factory(const char *name,dispatch_queue_t queue,uint64_t flags){
    Factories++;Check(!strcmp(name,LBX_LICENSE_SERVICE_NAME)&&flags==XPC_CONNECTION_MACH_SERVICE_PRIVILEGED&&queue!=nil,@"client uses compiled privileged service and private queue");
    // Every connection operation below is substituted. Use an opaque retained
    // stand-in instead of a native inactive connection: Apple forbids releasing
    // an inactive connection, and this fixture must not start a real transport.
    Queue=queue;return (xpc_connection_t)xpc_dictionary_create(NULL,NULL,0);
}
static void *FixtureDlsym(void *handle,const char *symbol){if(handle==RTLD_DEFAULT&&!strcmp(symbol,"xpc_connection_create_mach_service"))return FactoryAvailable?(void *)Factory:NULL;return dlsym(handle,symbol);}
static void FixtureCancel(xpc_connection_t connection){Check(connection!=nil,@"one-shot finish cancels its own connection");Cancels++;}
static void FixtureEvent(xpc_connection_t connection,void (^handler)(xpc_object_t)){Check(connection!=nil,@"handler uses created connection");EventHandler=[handler copy];}
static void FixtureResume(xpc_connection_t connection){Check(connection!=nil,@"resumes only created connection");Resumes++;}
static void FixtureSend(xpc_connection_t connection,xpc_object_t message,dispatch_queue_t queue,void (^reply)(xpc_object_t)){
    Check(connection!=nil&&queue==Queue&&xpc_get_type(message)==XPC_TYPE_DICTIONARY,@"one exact dictionary exchange uses private serial queue");
    size_t length=0;const void *data=xpc_dictionary_get_data(message,"payload",&length);
    Wire=data&&length?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:data length:length] options:0 error:nil]:nil;
    Check(length<=16384&&LBXContainerMutationIPCValidateRequest(Wire,LBXContainerMutationIPCClock()),@"outgoing payload retains exact bounded typed request");
    ReplyHandler=[reply copy];
}
static void FixtureAfter(dispatch_time_t when,dispatch_queue_t queue,void (^block)(void)){Check(when!=0&&queue==Queue,@"deadline is scheduled on same serial queue");Timeout=[block copy];}
static BOOL FixturePeer(xpc_object_t event,NSString *path,NSString *sha,off_t size,uid_t uid){PeerChecks++;Check(xpc_get_type(event)==XPC_TYPE_DICTIONARY&&[path isEqual:@LBX_LICENSE_SERVICE_PATH]&&!sha&&!size&&uid==0,@"reply uses unchanged compiled root peer policy");return Authenticated;}
static double FixtureClock(void){return Now;}
// Private translation-unit substitutions only. No provider or endpoint override
// exists in production. This proves serialization/one-shot client semantics with
// actual XPC dictionaries; authenticated Mach peers are a separate physical test.
#define dlsym FixtureDlsym
#define xpc_connection_cancel FixtureCancel
#define xpc_connection_set_event_handler FixtureEvent
#define xpc_connection_resume FixtureResume
#define xpc_connection_send_message_with_reply FixtureSend
#define dispatch_after FixtureAfter
#define LBXLicenseAuthenticatePeer FixturePeer
#define LBXContainerMutationIPCClock FixtureClock
#import "../Containers/LBXContainerMutationClient.m"
#undef dlsym
#undef xpc_connection_cancel
#undef xpc_connection_set_event_handler
#undef xpc_connection_resume
#undef xpc_connection_send_message_with_reply
#undef dispatch_after
#undef LBXLicenseAuthenticatePeer
#undef LBXContainerMutationIPCClock
static void Reset(void){EventHandler=ReplyHandler=nil;Timeout=nil;Queue=nil;Wire=Result=nil;Factories=Resumes=Cancels=Completions=PeerChecks=0;FactoryAvailable=Authenticated=YES;Now=LBXContainerMutationIPCClock();}
static void Send(NSString *operation,NSDictionary *arguments){LBXSendContainerMutationRequest(operation,arguments,^(NSDictionary *reply){Completions++;Result=reply;});}
static xpc_object_t Event(NSDictionary *reply){NSData *data=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];xpc_object_t event=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_data(event,"payload",data.bytes,data.length);return event;}
static NSDictionary *Status(void){return LBXContainerMutationIPCReply(Wire,@"status",@{@"epoch":@"1",@"pending":NSNull.null,@"completed":NSNull.null},nil,nil,nil);}
static void Reply(xpc_object_t event){dispatch_sync(Queue,^{ReplyHandler(event);});}
static void Error(void){dispatch_sync(Queue,^{EventHandler(XPC_ERROR_CONNECTION_INTERRUPTED);});}
static void Expire(void){dispatch_sync(Queue,^{Timeout();});}
static void Outcome(NSString *value){Check(Completions==1&&[Result[@"result"] isEqual:value]&&Cancels==1,@"client produces one expected result and one cancellation");}
int main(void){@autoreleasepool{
    Reset();Send(@"status",@{});NSDictionary *first=Wire;Check(Factories==1&&Resumes==1&&ReplyHandler&&Timeout,@"valid request starts one bounded exchange");
    xpc_object_t event=Event(Status());Reply(event);Outcome(@"status");Check([Result[@"runtimeAccepted"] isEqual:@NO]&&CFGetTypeID((__bridge CFTypeRef)Result[@"runtimeAccepted"])==CFBooleanGetTypeID(),@"client passes strict runtime false without changing state");
    Reply(event);Error();Expire();Check(Completions==1&&Cancels==1,@"duplicate reply error and timeout cannot finish twice");
    Reset();Send(@"status",@{});Check(![Wire[@"requestID"] isEqual:first[@"requestID"]],@"each call has fresh wire correlation UUID");
    Expire();Outcome(@"unconfirmed");Reply(Event(Status()));Error();Check(Completions==1&&Result[@"state"]==NSNull.null,@"late completion after timeout cannot publish confirmed state");
    Reset();Send(@"status",@{});Error();Outcome(@"unconfirmed");Expire();Check(Completions==1,@"connection error and timeout are serialized one-shot");
    Reset();Send(@"status",@{});Authenticated=NO;Reply(Event(Status()));Outcome(@"unconfirmed");Check(Result[@"state"]==NSNull.null,@"wrong root peer cannot disclose private state");
    Reset();Send(@"status",@{});Reply(xpc_string_create("private-untrusted"));Outcome(@"unconfirmed");Check(PeerChecks==0,@"non-dictionary replies are denied before peer check");
    Reset();Send(@"status",@{});NSMutableDictionary *mismatch=[Status() mutableCopy];mismatch[@"requestID"]=NSUUID.UUID.UUIDString.lowercaseString;Reply(Event(mismatch));Outcome(@"unconfirmed");
    Reset();Send(@"status",@{});mismatch=[Status() mutableCopy];mismatch[@"runtimeAccepted"]=@YES;Reply(Event(mismatch));Outcome(@"unconfirmed");
    Reset();Send(@"status",@{});mismatch=[Status() mutableCopy];mismatch[@"state"]=NSNull.null;Reply(Event(mismatch));Outcome(@"unconfirmed");
    Reset();Send(@"status",@{});event=Event(Status());Now=[Wire[@"deadline"] doubleValue];Reply(event);Outcome(@"unconfirmed");Check(Result[@"state"]==NSNull.null,@"reply at original deadline cannot confirm state");
    Reset();Send(@"status",@{});xpc_object_t oversized=xpc_dictionary_create(NULL,NULL,0);NSMutableData *data=[NSMutableData dataWithLength:65537];xpc_dictionary_set_data(oversized,"payload",data.bytes,data.length);Reply(oversized);Outcome(@"unconfirmed");
    Reset();Send(@"status",@{});xpc_object_t malformed=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_string(malformed,"payload","bad-json");Reply(malformed);Outcome(@"unconfirmed");
    Reset();FactoryAvailable=NO;Send(@"status",@{});Check(Completions==1&&[Result[@"result"] isEqual:@"service_unavailable"]&&!Resumes&&!Cancels,@"missing fixed service API fails without alternative transport");
    Reset();Send(@"status",@{@"path":@"caller-endpoint"});Check(Completions==1&&[Result[@"result"] isEqual:@"invalid_request"]&&!Factories,@"invalid caller authority rejected before connection");
    Reset();void (^emptyCompletion)(NSDictionary *)=nil;LBXSendContainerMutationRequest(@"status",@{},emptyCompletion);Check(!Factories&&!Completions,@"nil completion produces no effects");
    NSString *stage=NSUUID.UUID.UUIDString.lowercaseString;NSDictionary *choices=@{@"name":@"Synthetic pending choice",@"applications":@[@"com.burbn.instagram"],@"manualIdentifiers":NSNull.null,@"proxyReference":@""};
    NSDictionary *args=@{@"expectedEmptyEpoch":@"1",@"stageRequestID":stage,@"choices":choices};
    Reset();Send(@"stage-create",args);first=Wire;Error();Outcome(@"unconfirmed");Reset();Send(@"stage-create",args);
    Check([Wire[@"stageRequestID"] isEqual:first[@"stageRequestID"]]&&[Wire[@"choices"] isEqual:first[@"choices"]]&&![Wire[@"requestID"] isEqual:first[@"requestID"]],@"explicit retry preserves choices/stage ID with fresh wire envelope");
    Expire();Outcome(@"unconfirmed");Check(Result[@"state"]==NSNull.null&&Result[@"configuration"]==NSNull.null,@"uncertain exchange never fabricates empty durable state or candidate");
    NSLog(@"%@: %lu root mutation client assertions, %lu failures",Failures?@"FAIL":@"PASS",(unsigned long)Checks,(unsigned long)Failures);return Failures?1:0;
}}
