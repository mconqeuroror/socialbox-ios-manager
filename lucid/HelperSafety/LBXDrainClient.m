#import "LBXDrainClient.h"
#import "LBXXPC.h"
#include <os/log.h>
#include <math.h>

static void LBXSendServiceRequest(NSDictionary *request,BOOL check,void (^completion)(BOOL)) {
    if (!completion) return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (!data) { completion(NO); return; }
    // Each request owns a serial completion queue. A timeout, interruption and a
    // delayed service reply can race, but cannot report success twice or late.
    dispatch_queue_t queue=dispatch_queue_create("com.socialbox.drain.reply",DISPATCH_QUEUE_SERIAL);
    xpc_connection_t connection=LBXCreateMachService(LBX_DRAIN_SERVICE,queue,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!connection) { completion(NO); return; }
    __block BOOL finished=NO;
    void (^finish)(BOOL)=^(BOOL success) {
        if (finished) return;
        finished=YES;
        xpc_connection_cancel(connection);
        os_log(OS_LOG_DEFAULT,"LBX_HELPER_DRAIN operation=%{public}s result=%{public}s request=%{public}@",check?"check":"drain",success?(check?"authenticated":"observed_absent"):"failed",request[@"requestID"]);
        completion(success);
    };
    xpc_connection_set_event_handler(connection,^(xpc_object_t event) {
        if (xpc_get_type(event)==XPC_TYPE_ERROR) finish(NO);
    });
    xpc_connection_resume(connection);
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_data(message,"payload",data.bytes,data.length);
    xpc_connection_send_message_with_reply(connection,message,queue,^(xpc_object_t reply) {
        size_t length=0;
        const void *bytes=xpc_get_type(reply)==XPC_TYPE_DICTIONARY?xpc_dictionary_get_data(reply,"payload",&length):NULL;
        id result=bytes && length && length<=32768 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]:nil;
        double now=LBXDrainClock();
        finish(check?LBXValidateServiceCheckReply(result,request,now):LBXValidateDrainReply(result,request,now));
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3500*NSEC_PER_MSEC),queue,^{ finish(NO); });
}
void LBXRequestApplicationDrain(NSString *bundleID,void (^completion)(BOOL)) {
    if(!completion)return;
    double now=LBXDrainClock();
    if(!LBXDrainSupportedApplication(bundleID) || !isfinite(now) || now<0){completion(NO);return;}
    LBXSendServiceRequest(@{@"version":@1,@"operation":@"drain",@"bundleID":[bundleID copy],
        @"requestID":NSUUID.UUID.UUIDString,@"deadline":@(now+3.5)},NO,completion);
}
void LBXCheckDrainService(void (^completion)(BOOL)) {
    if(!completion)return;
    double now=LBXDrainClock();
    if(!isfinite(now) || now<0){completion(NO);return;}
    LBXSendServiceRequest(@{@"version":@1,@"operation":@"check",@"requestID":NSUUID.UUID.UUIDString,
        @"deadline":@(now+3.5)},YES,completion);
}
