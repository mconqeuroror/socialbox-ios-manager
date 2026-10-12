#import "LBXContainerMutationClient.h"
#import "LBXContainerMutationIPC.h"
#import "../Authorization/LBXLicensePeer.h"
#import "../Authorization/LBXLicenseEndpoints.h"
#import "../HelperSafety/LBXXPC.h"

void LBXSendContainerMutationRequest(NSString *operation,NSDictionary *arguments,void (^completion)(NSDictionary *)) {
    if(!completion)return;
    NSDictionary *request=LBXContainerMutationIPCRequest(operation,arguments);
    if(!request){completion(LBXContainerMutationIPCFailure(@{},@"invalid_request"));return;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    dispatch_queue_t queue=dispatch_queue_create("com.socialbox.root-pending.client",DISPATCH_QUEUE_SERIAL);
    xpc_connection_t connection=LBXCreateMachService(LBX_LICENSE_SERVICE_NAME,queue,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if(!connection||!data.length||data.length>16384){completion(LBXContainerMutationIPCFailure(request,@"service_unavailable"));return;}
    __block BOOL finished=NO;
    void (^finish)(NSDictionary *)=^(NSDictionary *reply){
        if(finished)return;finished=YES;xpc_connection_cancel(connection);
        completion(reply?:LBXContainerMutationIPCFailure(request,@"unconfirmed"));
    };
    xpc_connection_set_event_handler(connection,^(xpc_object_t event){if(xpc_get_type(event)==XPC_TYPE_ERROR)finish(nil);});
    xpc_connection_resume(connection);
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_data(message,"payload",data.bytes,data.length);
    xpc_connection_send_message_with_reply(connection,message,queue,^(xpc_object_t event){
        // The existing generic root-response policy is unchanged. The manager
        // role is enforced by the service on this request's kernel audit token.
        if(xpc_get_type(event)!=XPC_TYPE_DICTIONARY||!LBXLicenseAuthenticatePeer(event,@LBX_LICENSE_SERVICE_PATH,nil,0,0)){finish(nil);return;}
        size_t length=0;const void *bytes=xpc_dictionary_get_data(event,"payload",&length);
        id reply=bytes&&length&&length<=65536?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]:nil;
        finish(LBXContainerMutationIPCValidateReply(reply,request,LBXContainerMutationIPCClock())?reply:nil);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,24*NSEC_PER_SEC),queue,^{finish(nil);});
}
