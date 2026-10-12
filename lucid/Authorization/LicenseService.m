#import "LBXLicenseOwner.h"
#import "LBXLicenseVault.h"
#import "LBXLicensePeer.h"
#import "LBXLicenseIPC.h"
#import "LBXLicenseEndpoints.h"
#import "LBXLicenseInstallationEstablishment.h"
#import "../Containers/LBXContainerRootMutationOwner.h"
#import "../Containers/LBXContainerConfigurationStore.h"
#import "../Containers/LBXContainerEndpoints.h"
#import "../Containers/LBXContainerIPC.h"
#import "../Containers/LBXContainerMutationIPC.h"
#import "../HelperSafety/LBXXPC.h"
#include <unistd.h>
static void Send(xpc_object_t event,NSDictionary *result,NSUInteger limit){
    xpc_object_t reply=xpc_dictionary_create_reply(event);
    xpc_connection_t remote=xpc_dictionary_get_remote_connection(event);
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if(!reply||!remote||!data.length||data.length>limit)return;
    xpc_dictionary_set_data(reply,"payload",data.bytes,data.length);xpc_connection_send_message(remote,reply);
}
int main(void){@autoreleasepool{
    if(getuid()!=0||geteuid()!=0)return 77;
    // launchd owns one fixed private directory outside app/container exports.
    // Setup never accepts a caller path, UUID, credential, signer or endpoint.
    // Established startup is read-only with respect to initialization. Missing
    // pairing state cannot mint a replacement identity or silently reset owner.
    LBXLicenseInstallationEstablishment *installation=[LBXLicenseInstallationEstablishment openFixedPreparedInstallation:nil];
    LBXLicenseOwner *owner=installation.licenseOwner;
    LBXContainerConfigurationStore *store=installation.configurationStore;
    LBXContainerRootMutationOwner *containers=owner&&store?[[LBXContainerRootMutationOwner alloc]
        initWithPreparedInstallation:installation pendingDirectory:@LBX_CONTAINER_PENDING_PATH]:nil;
    dispatch_queue_t queue=dispatch_queue_create("com.socialbox.license.service",DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener=LBXCreateMachService(LBX_LICENSE_SERVICE_NAME,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if(!listener)return 70;
    xpc_connection_set_event_handler(listener,^(xpc_object_t peer){
        if(xpc_get_type(peer)!=XPC_TYPE_CONNECTION)return;
        xpc_connection_set_target_queue(peer,queue);
        xpc_connection_set_event_handler(peer,^(xpc_object_t event){@autoreleasepool{
            if(xpc_get_type(event)!=XPC_TYPE_DICTIONARY)return;
            if(!LBXLicenseAuthenticateManagerPeer(event,@LBX_LICENSE_CLIENT_PATH,@LBX_LICENSE_CLIENT_SHA256,LBX_LICENSE_CLIENT_SIZE)){
                xpc_connection_cancel(peer);return;
            }
            size_t length=0;const void *bytes=xpc_dictionary_get_data(event,"payload",&length);
            id request=bytes&&length&&length<=32768?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]:nil;
            if([request isKindOfClass:NSDictionary.class]&&[request[@"family"] isEqual:@"container-mutation"]){
                if(!LBXContainerMutationIPCValidateRequest(request,LBXContainerMutationIPCClock())){Send(event,LBXContainerMutationIPCFailure(request,@"invalid_request"),65536);return;}
                if(!containers||![installation preparedInstallationCurrent:nil]){Send(event,LBXContainerMutationIPCFailure(request,@"storage_unavailable"),65536);return;}
                [containers handleRequest:request completion:^(NSDictionary *reply){Send(event,[installation preparedInstallationCurrent:nil]?reply:LBXContainerMutationIPCFailure(request,@"storage_unavailable"),65536);}];return;
            }
            if([request isKindOfClass:NSDictionary.class]&&[request[@"family"] isEqual:@"container-configuration"]){
                if(!LBXContainerIPCValidateRequest(request,LBXContainerIPCClock())){Send(event,LBXContainerIPCFailure(request,@"invalid_request"),65536);return;}
                // Close the old raw writer globally, including when no pending
                // slot exists. Old read/list still share the new context gate.
                if(![@[@"read",@"list"] containsObject:request[@"operation"]]){Send(event,LBXContainerIPCFailure(request,@"invalid_request"),65536);return;}
                if(!containers||![installation preparedInstallationCurrent:nil]){Send(event,LBXContainerIPCFailure(request,@"storage_unavailable"),65536);return;}
                [containers handleLegacyConfigurationQuery:request completion:^(NSDictionary *reply){Send(event,[installation preparedInstallationCurrent:nil]?reply:LBXContainerIPCFailure(request,@"storage_unavailable"),65536);}];return;
            }
            if(length>4096||!LBXLicenseIPCValidateRequest(request,LBXLicenseIPCClock())){Send(event,LBXLicenseIPCReply(@{},@"invalid_request",NO),2048);return;}
            if(!owner||![installation preparedInstallationCurrent:nil]){Send(event,LBXLicenseIPCReply(request,@"storage_unavailable",NO),2048);return;}
            [owner handleRequest:request completion:^(NSDictionary *reply){
                BOOL establishes=[@[@"activate",@"validate"] containsObject:request[@"operation"]]&&[reply[@"result"] isEqual:@"active"]&&[reply[@"paired"] boolValue];
                if(establishes){
                    if(!containers){Send(event,LBXLicenseIPCReply(request,@"storage_unavailable",YES),2048);return;}
                    // Genuine activation/validation supplies fresh admission;
                    // preparation supplies typed pristine provenance. Preserve
                    // the original deadline and leave the owner queue first.
                    [containers establishPreparedPendingBeforeDeadline:[request[@"deadline"] doubleValue] completion:^(BOOL ready){
                        NSDictionary *result=ready?reply:LBXLicenseIPCReply(request,@"recovery_required",YES);
                        Send(event,[installation preparedInstallationCurrent:nil]?result:LBXLicenseIPCReply(request,@"storage_unavailable",NO),2048);
                    }];return;
                }
                Send(event,[installation preparedInstallationCurrent:nil]?reply:LBXLicenseIPCReply(request,@"storage_unavailable",NO),2048);
            }];
        }});
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);dispatch_main();
}}
