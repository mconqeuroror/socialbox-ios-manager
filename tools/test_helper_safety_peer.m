#import <Foundation/Foundation.h>
#import "../lucid/HelperSafety/LBXXPC.h"
#import "../lucid/Switching/LBXSocialBoxProduct.h"
#include <bsm/audit.h>
#include <sys/stat.h>
static unsigned Checks,Failures,PathCalls;
static BOOL MissingToken,MissingPath,KernelDenied,Writable,NonRoot,Link,ChangedProgram,ExitDuringHash,ExecDuringHash;
static unsigned FileChecks;
static unsigned UID,PID=42;
static NSString *KernelPath;
static void Check(BOOL value,const char *reason){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL %s\n",reason);}}
static void Token(xpc_object_t object,audit_token_t *token){(void)object;memset(token,0,sizeof(*token));token->val[1]=UID;token->val[5]=PID;token->val[7]=7;}
static int Path(audit_token_t *token,void *buffer,uint32_t length){PathCalls++;Check(token->val[7]==7,"kernel lookup carries audit PID version");if(KernelDenied)return -1;strlcpy(buffer,KernelPath.UTF8String,length);return (int)KernelPath.length;}
static void *Symbol(void *image,const char *name){(void)image;
    if(!strcmp(name,"xpc_dictionary_get_audit_token"))return MissingToken?NULL:(void *)Token;
    if(!strcmp(name,"proc_pidpath_audittoken"))return MissingPath?NULL:(void *)Path;
    return NULL;
}
static int Stat(const char *path,struct stat *node){(void)path;memset(node,0,sizeof(*node));node->st_uid=NonRoot?501:0;node->st_mode=(Link?S_IFLNK:S_IFREG)|0755|(Writable?0020:0);return 0;}
BOOL LBXVerifyCallerFile(NSString *path,off_t size,NSString *digest) {
    FileChecks++;
    BOOL helper=[path hasSuffix:@"/SocialBoxHelper"];
    Check(size==(helper?(off_t)LBX_SOCIALBOX_HELPER_SIZE:(off_t)LBX_SOCIALBOX_MANAGER_SIZE),"each caller has its own exact byte length");
    Check([digest isEqual:helper?@LBX_SOCIALBOX_HELPER_SHA256:@LBX_SOCIALBOX_MANAGER_SHA256],"each caller has its own reviewed binary digest");
    if(ExitDuringHash)KernelDenied=YES;
    if(ExecDuringHash)KernelPath=@"/private/tmp/replaced";
    return !ChangedProgram;
}
#define dlsym Symbol
#define lstat Stat
#define main LBXServiceMainForTest
#import "../lucid/HelperSafety/Service.m"
#undef dlsym
#undef lstat
#undef main
int main(void){@autoreleasepool{
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);
    KernelPath=[@LBX_SOCIALBOX_HELPER_PATH stringByResolvingSymlinksInPath];
    Check(LBXAuthorizedMessage(message),"expected root helper with kernel-confirmed token accepted");
    UID=501;Check(!LBXAuthorizedMessage(message),"helper cannot call as mobile");UID=502;PathCalls=0;
    Check(!LBXAuthorizedMessage(message)&&PathCalls==0,"other user rejected before path lookup");UID=0;
    PID=1;Check(!LBXAuthorizedMessage(message),"system PID rejected");PID=42;
    MissingToken=YES;Check(!LBXAuthorizedMessage(message),"missing audit API denies service");MissingToken=NO;
    MissingPath=YES;Check(!LBXAuthorizedMessage(message),"missing version-bound path API denies service");MissingPath=NO;
    KernelDenied=YES;Check(!LBXAuthorizedMessage(message),"stale/reused/dead audit token rejected");KernelDenied=NO;
    for(NSString *path in @[@"/var/jb/usr/libexec/SocialBoxHelper.evil",@"/private/tmp/SocialBoxHelper",@"/usr/libexec/launchd",@"/private/tmp/SocialBox.app/SocialBox"]){KernelPath=path;Check(!LBXAuthorizedMessage(message),"same name or other privileged process is not authorized");}
    KernelPath=[@LBX_SOCIALBOX_MANAGER_PATH stringByResolvingSymlinksInPath];
    Check(LBXAuthorizedMessage(message),"exact manager admitted as root");
    UID=501;Check(LBXAuthorizedMessage(message),"exact root-owned manager admitted as mobile");UID=0;
    ChangedProgram=YES;Check(!LBXAuthorizedMessage(message),"different program at approved path cannot gain drain authority");ChangedProgram=NO;
    unsigned before=PathCalls;ExitDuringHash=YES;
    Check(!LBXAuthorizedMessage(message)&&PathCalls==before+2,"caller exiting during hash rejected by same audit token");ExitDuringHash=KernelDenied=NO;
    ExecDuringHash=YES;Check(!LBXAuthorizedMessage(message),"caller path changing during hash rejected");ExecDuringHash=NO;
    KernelPath=[@LBX_SOCIALBOX_MANAGER_PATH stringByResolvingSymlinksInPath];
    Writable=YES;Check(!LBXAuthorizedMessage(message),"legacy group-writable manager rejected");Writable=NO;
    KernelPath=[@LBX_SOCIALBOX_HELPER_PATH stringByResolvingSymlinksInPath];
    Writable=YES;Check(!LBXAuthorizedMessage(message),"mutable executable refused");Writable=NO;
    NonRoot=YES;Check(!LBXAuthorizedMessage(message),"user-owned executable refused");NonRoot=NO;
    Link=YES;Check(!LBXAuthorizedMessage(message),"aliased final executable refused");
    printf("%s helper peer authentication: %u checks, %u failures; audit/kernel boundaries mocked\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
