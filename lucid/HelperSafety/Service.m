#import "LBXDrainProtocol.h"
#import "../Switching/LBXDarwinDrainBackend.h"
#import "../Switching/LBXSocialBoxProduct.h"
#import "LBXXPC.h"
#import "LBXCallerFile.h"
#include <bsm/audit.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdatomic.h>
#include <math.h>
#include <os/log.h>

static BOOL LBXAuthorizedMessage(xpc_object_t message) {
    // Authenticate this message's audit token, never a caller-supplied PID/path
    // or an euid-only check that admits every privileged app on the phone.
    typedef void (*TokenFunction)(xpc_object_t,audit_token_t *);
    typedef int (*PathFunction)(audit_token_t *,void *,uint32_t);
    TokenFunction getToken=(TokenFunction)dlsym(RTLD_DEFAULT,"xpc_dictionary_get_audit_token");
    PathFunction getPath=(PathFunction)dlsym(RTLD_DEFAULT,"proc_pidpath_audittoken");
    if (!getToken || !getPath) return NO;
    audit_token_t token={0}; getToken(message,&token);
    if ((token.val[1]!=0 && token.val[1]!=501) || token.val[5]<=1) return NO; // effective uid, pid
    char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    int length=getPath(&token,path,sizeof(path));
    if (length<=0 || (size_t)length>=sizeof(path) || !memchr(path,0,sizeof(path))) return NO;
    NSString *observed=[NSString stringWithUTF8String:path];
    if ([observed hasPrefix:@"/var/"]) observed=[@"/private" stringByAppendingString:observed];
    NSDictionary *callers=@{
        @LBX_SOCIALBOX_HELPER_PATH:@[@(LBX_SOCIALBOX_HELPER_SIZE),@LBX_SOCIALBOX_HELPER_SHA256],
        @LBX_SOCIALBOX_MANAGER_PATH:@[@(LBX_SOCIALBOX_MANAGER_SIZE),@LBX_SOCIALBOX_MANAGER_SHA256]};
    for (NSString *candidate in callers) {
        // Only the exact manager may call as mobile. The app's checked per-app
        // worker talks directly to this service, never trusts the legacy kill
        // BOOL. No new caller can request arbitrary paths, PIDs or shell code.
        if (token.val[1]!=0 && [candidate hasSuffix:@"/SocialBoxHelper"]) continue;
        NSString *expected=candidate.stringByResolvingSymlinksInPath;
        if ([expected hasPrefix:@"/var/"]) expected=[@"/private" stringByAppendingString:expected];
        struct stat node;
        if (![observed isEqual:expected] || lstat(expected.fileSystemRepresentation,&node) ||
            !S_ISREG(node.st_mode) || node.st_uid!=0 || (node.st_mode&0022)) continue;
        NSArray *pin=callers[candidate];
        if(!LBXVerifyCallerFile(expected,[pin[0] longLongValue],pin[1]))return NO;
        // Hashing takes time. Revalidate the SAME kernel audit token (including
        // PID/exec version); never authenticate a reused numeric PID afterward.
        memset(path,0,sizeof(path));length=getPath(&token,path,sizeof(path));
        if(length<=0 || (size_t)length>=sizeof(path) || !memchr(path,0,sizeof(path)))return NO;
        NSString *current=[NSString stringWithUTF8String:path];
        if([current hasPrefix:@"/var/"])current=[@"/private" stringByAppendingString:current];
        return [current isEqual:expected];
    }
    return NO;
}
static void LBXSend(xpc_object_t message, NSDictionary *receipt) {
    xpc_object_t reply=xpc_dictionary_create_reply(message);
    xpc_connection_t remote=xpc_dictionary_get_remote_connection(message);
    NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
    if (!reply || !remote || !data || data.length>32768) return;
    xpc_dictionary_set_data(reply,"payload",data.bytes,data.length);
    xpc_connection_send_message(remote,reply);
}
int main(void) { @autoreleasepool {
    if (getuid()!=0 || geteuid()!=0) return 77;
    dispatch_queue_t queue=dispatch_queue_create("com.socialbox.drain.service",DISPATCH_QUEUE_SERIAL);
    xpc_connection_t listener=LBXCreateMachService(LBX_DRAIN_SERVICE,queue,XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) return 70;
    xpc_connection_set_event_handler(listener,^(xpc_object_t peer) {
        if (xpc_get_type(peer)!=XPC_TYPE_CONNECTION) return;
        xpc_connection_set_target_queue(peer,queue);
        xpc_connection_set_event_handler(peer,^(xpc_object_t event) { @autoreleasepool {
            if (xpc_get_type(event)!=XPC_TYPE_DICTIONARY) return;
            if (!LBXAuthorizedMessage(event)) {
                os_log_error(OS_LOG_DEFAULT,"LBX_DRAIN_SERVICE unauthorized_peer");
                fputs("LBX_DRAIN_SERVICE unauthorized_peer\n",stderr);fflush(stderr);
                xpc_connection_cancel(peer); return;
            }
            size_t length=0; const void *bytes=xpc_dictionary_get_data(event,"payload",&length);
            id request=bytes && length && length<=4096 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:nil]:nil;
            double now=LBXDrainClock();
            NSDictionary *checked=LBXServiceCheckReply(request,now);
            if(checked) {
                // Authentication happened above. No resolver, process snapshot,
                // termination, storage operation or admission token is involved.
                LBXSend(event,checked);
                os_log(OS_LOG_DEFAULT,"LBX_DRAIN_SERVICE authenticated_check request=%{public}@",request[@"requestID"]);
                return;
            }
            if (!LBXValidateDrainRequest(request,now)) { LBXSend(event,LBXDrainFailure(@{},@"invalid_or_expired_request")); return; }
            // All requests share a serial backend. Queueing consumes the caller's
            // absolute deadline; it never grants a fresh budget after timeout.
            double remaining=[request[@"deadline"] doubleValue]-now;
            if (remaining<.1) { LBXSend(event,LBXDrainFailure(request,@"deadline_exceeded")); return; }
            __block atomic_bool complete=false;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(remaining*NSEC_PER_SEC)),
                dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                    // A blocked system RPC cannot turn into a delayed drain of
                    // a future process. End this owned service, not the app.
                    if (!atomic_load(&complete)) _exit(124);
                });
            NSDictionary *receipt=LBXDrainApplication([LBXDarwinDrainBackend new],request[@"bundleID"],request[@"requestID"],MIN(2.0,remaining),YES);
            if (!LBXValidateDrainReply(receipt,request,LBXDrainClock())) {
                NSString *reason=[receipt[@"reason"] isKindOfClass:NSString.class]?receipt[@"reason"]:@"invalid_receipt";
                receipt=LBXDrainFailure(request,reason);
            }
            atomic_store(&complete,true);
            LBXSend(event,receipt);
            os_log(OS_LOG_DEFAULT,"LBX_DRAIN_SERVICE request=%{public}@ status=%{public}@ reason=%{public}@",request[@"requestID"],receipt[@"status"],receipt[@"reason"]);
        }});
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(listener);
    dispatch_main();
}}
