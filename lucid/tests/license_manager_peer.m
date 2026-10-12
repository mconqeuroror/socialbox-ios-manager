#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <bsm/audit.h>
#include <bsm/libbsm.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#import "../HelperSafety/LBXCallerFile.h"
static NSUInteger Checks,Failures,PathCalls,VerifyCalls,OpenCalls;
static void Check(BOOL value,NSString *label){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL: %s\n",label.UTF8String);}}
static audit_token_t Token,FirstPathToken;
static BOOL TokenMissing,PathMissing,TokenUnwritten,PathDrift,VerifyOK=YES,NodePresent=YES,NodeRegular=YES;
static mode_t NodeMode=0755;static uid_t NodeUID;static nlink_t NodeLinks=1;
static NSString *Mode,*const PinPath=@"/private/tmp/socialbox-synthetic-manager",*const PinSHA=@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
static void *SystemBSM;
static void FixtureToken(xpc_object_t message,audit_token_t *token){Check(xpc_get_type(message)==XPC_TYPE_DICTIONARY,@"synthetic token reader receives exact dictionary");if(!TokenUnwritten)*token=Token;}
static int FixturePath(audit_token_t *token,void *bytes,uint32_t capacity){
    PathCalls++;if(PathCalls==1)FirstPathToken=*token;else Check(!memcmp(&FirstPathToken,token,sizeof(*token)),@"post-hash path observation receives same complete audit token");
    const char *path=(PathDrift&&PathCalls>1)?"/private/tmp/different-exec":PinPath.fileSystemRepresentation;
    if(strlen(path)+1>capacity)return 0;memcpy(bytes,path,strlen(path)+1);return (int)strlen(path);
}
static void *FixtureDlsym(void *handle,const char *symbol){
    if(handle==RTLD_DEFAULT&&!strcmp(symbol,"xpc_dictionary_get_audit_token"))return TokenMissing?NULL:(void *)FixtureToken;
    if(handle==RTLD_DEFAULT&&!strcmp(symbol,"proc_pidpath_audittoken"))return PathMissing?NULL:(void *)FixturePath;
    if([Mode isEqual:@"missing-ruid"]&&!strcmp(symbol,"audit_token_to_ruid"))return NULL;
    if([Mode isEqual:@"missing-euid"]&&!strcmp(symbol,"audit_token_to_euid"))return NULL;
    if([Mode isEqual:@"missing-pid"]&&!strcmp(symbol,"audit_token_to_pid"))return NULL;
    return dlsym(handle,symbol);
}
static void *FixtureDlopen(const char *path,int flags){OpenCalls++;Check(!strcmp(path,"/usr/lib/libbsm.0.dylib")&&(flags&RTLD_LOCAL)==RTLD_LOCAL,@"decoder loads fixed Apple install-name only");return [Mode isEqual:@"missing-library"]?NULL:SystemBSM;}
static int FixtureLstat(const char *path,struct stat *node){
    if(!NodePresent||strcmp(path,PinPath.fileSystemRepresentation))return -1;
    memset(node,0,sizeof(*node));node->st_mode=(NodeRegular?S_IFREG:S_IFDIR)|NodeMode;node->st_uid=NodeUID;node->st_nlink=NodeLinks;return 0;
}
static BOOL FixtureVerify(NSString *path,off_t size,NSString *sha){VerifyCalls++;return VerifyOK&&[path isEqual:PinPath]&&size==123&&[sha isEqual:PinSHA];}
// Private link-time fixture substitutions only. The production file contains
// no test provider or callbacks; positive path/file observations here are
// synthetic and do not claim authenticated peer acceptance on a physical phone.
#define dlsym FixtureDlsym
#define dlopen FixtureDlopen
#define lstat FixtureLstat
#define LBXVerifyCallerFile FixtureVerify
#import "../Authorization/LBXLicensePeer.m"
#undef dlsym
#undef dlopen
#undef lstat
#undef LBXVerifyCallerFile
static BOOL Manager(xpc_object_t message){PathCalls=VerifyCalls=0;return LBXLicenseAuthenticateManagerPeer(message,PinPath,PinSHA,123);}
int main(int argc,char **argv){@autoreleasepool{
    Mode=argc>1?@(argv[1]):@"normal";
    SystemBSM=dlopen("/usr/lib/libbsm.0.dylib",RTLD_LAZY|RTLD_LOCAL);
    Check(SystemBSM!=NULL,@"actual host Apple BSM runtime exists");
    audit_token_t actual=INVALID_AUDIT_TOKEN_VALUE;mach_msg_type_number_t count=TASK_AUDIT_TOKEN_COUNT;
    kern_return_t code=task_info(mach_task_self(),TASK_AUDIT_TOKEN,(task_info_t)&actual,&count);
    Check(code==KERN_SUCCESS&&count==TASK_AUDIT_TOKEN_COUNT,@"actual host kernel supplies its audit token");
    Check(audit_token_to_ruid(actual)==getuid()&&audit_token_to_euid(actual)==geteuid()&&audit_token_to_pid(actual)==getpid(),@"real Apple decoder ABI matches actual kernel UID/EUID/PID");
    Token=actual;Token.val[3]=501;Token.val[1]=0;Token.val[5]=42;
    Check(audit_token_to_ruid(Token)==501&&audit_token_to_euid(Token)==0&&audit_token_to_pid(Token)==42,@"synthetic role matrix is decoded by actual Apple routines");
    xpc_object_t message=xpc_dictionary_create(NULL,NULL,0);
    if(![Mode isEqual:@"normal"]){
        Check(!Manager(message)&&VerifyCalls==0&&PathCalls==0,@"missing required decoder library/symbol fails before file pin");
    }else{
        Check(Manager(message)&&VerifyCalls==1&&PathCalls==2,@"synthetic manager501/0 checks same-token path and full executable pin");
        Token.val[1]=501;Check(Manager(message),@"synthetic manager501/501 accepted by same policy");
        Token.val[3]=0;Token.val[1]=0;Check(!Manager(message)&&VerifyCalls==0,@"root real UID0 rejected even with allowed effective0");
        PathCalls=0;Check(LBXLicenseAuthenticatePeer(message,PinPath,nil,0,0),@"generic root response policy remains unchanged");
        Token.val[3]=501;Token.val[1]=502;Check(!Manager(message)&&VerifyCalls==0,@"other effective UID rejected");
        Token.val[1]=0;Token.val[3]=502;Check(!Manager(message)&&VerifyCalls==0,@"other real UID rejected");
        Token.val[3]=501;for(unsigned pid=0;pid<=1;pid++){Token.val[5]=pid;Check(!Manager(message)&&VerifyCalls==0,@"unset and kernel PID denied");}Token.val[5]=42;
        TokenMissing=YES;Check(!Manager(message),@"absent exact message token API denied");TokenMissing=NO;
        PathMissing=YES;Check(!Manager(message),@"absent same-token path API denied");PathMissing=NO;
        TokenUnwritten=YES;Check(!Manager(message)&&VerifyCalls==0,@"unwritten opaque token safe initializer denied");TokenUnwritten=NO;
        Check(!LBXLicenseAuthenticateManagerPeer(NULL,PinPath,PinSHA,123),@"nil message denied");
        Check(!LBXLicenseAuthenticateManagerPeer(xpc_string_create("requestUID501"),PinPath,PinSHA,123),@"non-dictionary message cannot supply identity");
        for(uid_t uid=1;uid<=2;uid++){NodeUID=uid;Check(!Manager(message),@"non-root executable node denied");}NodeUID=0;
        NodeRegular=NO;Check(!Manager(message),@"non-regular executable denied");NodeRegular=YES;
        NodePresent=NO;Check(!Manager(message),@"missing named executable denied");NodePresent=YES;
        NodeMode=0775;Check(!Manager(message),@"group-writable executable denied");NodeMode=0757;Check(!Manager(message),@"public-writable executable denied");NodeMode=0755;
        NodeLinks=2;Check(!Manager(message),@"multiply linked executable denied");NodeLinks=1;
        VerifyOK=NO;Check(!Manager(message),@"failed executable content pin denied");VerifyOK=YES;
        PathDrift=YES;Check(!Manager(message)&&PathCalls==2,@"same-token post-hash exec path drift denied");PathDrift=NO;
        Check(!LBXLicenseAuthenticateManagerPeer(message,PinPath,nil,123),@"manager cannot omit SHA like privileged service");
        Check(!LBXLicenseAuthenticateManagerPeer(message,PinPath,PinSHA,0),@"manager cannot omit expected size");
        Check(!LBXLicenseAuthenticateManagerPeer(message,@"relative",PinSHA,123),@"relative pin denied");
        Check(!LBXLicenseAuthenticateManagerPeer(message,@"/private/tmp/other-manager",PinSHA,123),@"foreign pin path cannot substitute audited executable");
        Check(OpenCalls==1,@"fixed BSM decoder load occurs once without caller providers");
    }
    NSLog(@"%@: %lu manager peer %s assertions, %lu failures",Failures?@"FAIL":@"PASS",(unsigned long)Checks,Mode.UTF8String,(unsigned long)Failures);return Failures?1:0;
}}
