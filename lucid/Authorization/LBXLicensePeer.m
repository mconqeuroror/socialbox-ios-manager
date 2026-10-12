#import "LBXLicensePeer.h"
#import "../HelperSafety/LBXCallerFile.h"
#include <bsm/audit.h>
#include <dlfcn.h>
#include "../../shared/RBXProc.h"
#include <sys/stat.h>
#include <string.h>

static NSString *Canonical(NSString *path){return [path hasPrefix:@"/var/"]?[@"/private" stringByAppendingString:path]:path;}
BOOL LBXLicenseAuthenticatePeer(xpc_object_t message,NSString *path,NSString *sha256,off_t size,uid_t uid){
    typedef void (*TokenFunction)(xpc_object_t,audit_token_t *);
    typedef int (*PathFunction)(audit_token_t *,void *,uint32_t);
    TokenFunction getToken=(TokenFunction)dlsym(RTLD_DEFAULT,"xpc_dictionary_get_audit_token");
    PathFunction getPath=(PathFunction)dlsym(RTLD_DEFAULT,"proc_pidpath_audittoken");
    if(!getToken||!getPath||!path.isAbsolutePath||(!sha256&&uid!=0))return NO;
    audit_token_t token={0};getToken(message,&token);
    if(token.val[5]<=1 || (uid==(uid_t)-1?(token.val[1]!=0&&token.val[1]!=501):token.val[1]!=uid))return NO;
    char buffer[PROC_PIDPATHINFO_MAXSIZE]={0};int length=getPath(&token,buffer,sizeof(buffer));
    if(length<=0||(size_t)length>=sizeof(buffer)||!memchr(buffer,0,sizeof(buffer)))return NO;
    NSString *expected=Canonical(path.stringByResolvingSymlinksInPath);
    struct stat node;
    if(![Canonical([NSString stringWithUTF8String:buffer]) isEqual:expected] || lstat(expected.fileSystemRepresentation,&node) ||
       !S_ISREG(node.st_mode)||node.st_uid!=0||(node.st_mode&0022)||node.st_nlink!=1)return NO;
    if(sha256&&!LBXVerifyCallerFile(expected,size,sha256))return NO;
    // Match the same audit token again after hashing (including exec version),
    // rather than resolving the numeric PID of a possibly replaced process.
    memset(buffer,0,sizeof(buffer));length=getPath(&token,buffer,sizeof(buffer));
    return length>0&&(size_t)length<sizeof(buffer)&&memchr(buffer,0,sizeof(buffer))&&[Canonical([NSString stringWithUTF8String:buffer]) isEqual:expected];
}

BOOL LBXLicenseAuthenticateManagerPeer(xpc_object_t message,NSString *path,NSString *sha256,off_t size){
    typedef void (*TokenFunction)(xpc_object_t,audit_token_t *);
    typedef int (*PathFunction)(audit_token_t *,void *,uint32_t);
    typedef uid_t (*UIDFunction)(audit_token_t);
    typedef pid_t (*PIDFunction)(audit_token_t);
    TokenFunction getToken=(TokenFunction)dlsym(RTLD_DEFAULT,"xpc_dictionary_get_audit_token");
    PathFunction getPath=(PathFunction)dlsym(RTLD_DEFAULT,"proc_pidpath_audittoken");
    // mach/message.h defines audit_token_t as opaque and directs users to BSM.
    // The by-value ABI is documented in Apple's libbsm.h; the iOS system TBD
    // exports these symbols at this fixed Apple install-name. They are private
    // iOS runtime APIs, so availability must be observed and never assumed.
    static UIDFunction realUID,effectiveUID;static PIDFunction processID;static dispatch_once_t once;
    dispatch_once(&once,^{
        void *library=dlopen("/usr/lib/libbsm.0.dylib",RTLD_LAZY|RTLD_LOCAL);
        if(library){realUID=(UIDFunction)dlsym(library,"audit_token_to_ruid");effectiveUID=(UIDFunction)dlsym(library,"audit_token_to_euid");processID=(PIDFunction)dlsym(library,"audit_token_to_pid");}
    });
    if(!message||xpc_get_type(message)!=XPC_TYPE_DICTIONARY||!getToken||!getPath||!realUID||!effectiveUID||!processID||
       ![path isKindOfClass:NSString.class]||!path.isAbsolutePath||![sha256 isKindOfClass:NSString.class]||!sha256.length||size<=0)return NO;
    audit_token_t token=INVALID_AUDIT_TOKEN_VALUE;getToken(message,&token);
    uid_t effective=effectiveUID(token);if(processID(token)<=1||realUID(token)!=501||(effective!=0&&effective!=501))return NO;
    char buffer[PROC_PIDPATHINFO_MAXSIZE]={0};int length=getPath(&token,buffer,sizeof(buffer));
    if(length<=0||(size_t)length>=sizeof(buffer)||!memchr(buffer,0,sizeof(buffer)))return NO;
    NSString *expected=Canonical(path.stringByResolvingSymlinksInPath);struct stat node;
    if(![Canonical([NSString stringWithUTF8String:buffer]) isEqual:expected]||lstat(expected.fileSystemRepresentation,&node)||
       !S_ISREG(node.st_mode)||node.st_uid!=0||(node.st_mode&0022)||node.st_nlink!=1||!LBXVerifyCallerFile(expected,size,sha256))return NO;
    memset(buffer,0,sizeof(buffer));length=getPath(&token,buffer,sizeof(buffer));
    return length>0&&(size_t)length<sizeof(buffer)&&memchr(buffer,0,sizeof(buffer))&&[Canonical([NSString stringWithUTF8String:buffer]) isEqual:expected];
}
