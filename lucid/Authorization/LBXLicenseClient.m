#import "LBXLicenseClient.h"
#import "LBXLicenseIPC.h"
#import "LBXLicensePeer.h"
#import "LBXLicenseEndpoints.h"
#import "../HelperSafety/LBXXPC.h"
void LBXSendLicenseRequest(NSString *operation,NSString *key,void (^completion)(NSDictionary *)){
    if(!completion)return;
    NSDictionary *request=LBXLicenseIPCRequest(operation,key);
    if(!request){completion(LBXLicenseIPCReply(@{},@"invalid_request",NO));return;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    dispatch_queue_t queue=dispatch_queue_create("com.socialbox.license.client",DISPATCH_QUEUE_SERIAL);
    xpc_connection_t connection=LBXCreateMachService(LBX_LICENSE_SERVICE_NAME,queue,XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if(!connection||!data){completion(LBXLicenseIPCReply(request,@"service_unavailable",NO));return;}
    __block BOOL finished=NO;
    void (^finish)(NSDictionary *)=^(NSDictionary *reply){
        if(finished)return;finished=YES;xpc_connection_cancel(connection);
        completion(reply?:LBXLicenseIPCReply(request,@"service_unavailable",NO));
    };
    xpc_connection_set_event_handler(connection,^(xpc_object_t event){if(xpc_get_type(event)==XPC_TYPE_ERROR)finish(nil);});
    xpc_connection_resume(connection);
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_data(message,"payload",data.bytes,data.length);
    xpc_connection_send_message_with_reply(connection,message,queue,^(xpc_object_t event){
        if(xpc_get_type(event)!=XPC_TYPE_DICTIONARY || !LBXLicenseAuthenticatePeer(event,@LBX_LICENSE_SERVICE_PATH,nil,0,0)){finish(nil);return;}
        size_t length=0;const void *bytes=xpc_dictionary_get_data(event,"payload",&length);
        id reply=bytes&&length&&length<=2048?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]:nil;
        finish(LBXLicenseIPCValidateReply(reply,request,LBXLicenseIPCClock())?reply:nil);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,24*NSEC_PER_SEC),queue,^{finish(nil);});
}
