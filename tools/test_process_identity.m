#import <Foundation/Foundation.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <libproc.h>
#include <mach/message.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include "RBXProcessIdentity.h"

static unsigned Checks,Failures,Reads,Lookups,Requests,TokenReads,Interrupts;
static int TableError,PathError,ReadSizeMode,ChangedAtRead,HandleMode,TokenMode,ChangeAtLookup;
static BOOL Gone,Zombie,MissingBirth,InvalidPath,Truncated,RequestDenied,RequestError,Throw,MissingClass,MissingToken;
static int64_t Birth;
static const char *Path;
static id ExpectedHandle,ExpectedPredicate;
static void Check(BOOL condition,const char *message){Checks++;if(!condition){Failures++;fprintf(stderr,"FAIL %s\n",message);}}
static void Reset(void){Reads=Lookups=Requests=TokenReads=Interrupts=0;TableError=PathError=ReadSizeMode=ChangedAtRead=HandleMode=TokenMode=ChangeAtLookup=0;Gone=Zombie=MissingBirth=InvalidPath=Truncated=RequestDenied=RequestError=Throw=MissingClass=MissingToken=NO;Birth=42;Path="/private/var/containers/Bundle/Application/test/Facebook.app/Facebook";ExpectedHandle=ExpectedPredicate=nil;}
static pid_t TestGetpid(void){return 50;}
static int TestSysctl(int *mib,u_int count,void *out,size_t *size,void *input,size_t inputSize){
    (void)input;(void)inputSize;
    Check(count==4&&mib[0]==CTL_KERN&&mib[1]==KERN_PROC&&mib[2]==KERN_PROC_PID&&mib[3]==100,"only exact PID query");
    Reads++;if(Interrupts){Interrupts--;errno=EINTR;return -1;}if(TableError){errno=TableError;return -1;}
    if(ChangedAtRead==(int)Reads)Birth++;
    if(Gone){*size=0;return 0;}struct kinfo_proc *p=out;memset(p,0,sizeof(*p));p->kp_proc.p_pid=100;p->kp_proc.p_stat=Zombie?SZOMB:SRUN;
    p->kp_proc.p_starttime.tv_sec=MissingBirth?0:Birth;p->kp_proc.p_starttime.tv_usec=123;
    *size=ReadSizeMode?sizeof(*p)-1:sizeof(*p);return 0;
}
static int TestPath(int pid,void *buffer,uint32_t size){
    Check(pid==100,"path query exact PID");if(PathError){errno=PathError;return 0;}
    if(Truncated){memset(buffer,'x',size);return (int)size;}
    strlcpy(buffer,InvalidPath?"relative":Path,size);return (int)strlen(buffer);
}
static int TestTokenPath(audit_token_t *token,void *buffer,uint32_t size){
    TokenReads++;Check(token->val[5]==100&&token->val[7]==123,"kernel lookup uses exact service audit token");
    if(TokenMode==1){errno=ESRCH;return 0;}
    if(TokenMode==2){memset(buffer,'x',size);return (int)size;}
    if(TokenMode==3){strlcpy(buffer,"/foreign/app",size);return 12;}
    if(TokenMode==4)Birth++;
    strlcpy(buffer,Path,size);return (int)strlen(buffer);
}
static void *TestDlopen(const char *path,int flags){(void)flags;Check(strstr(path,"/RunningBoardServices.framework/RunningBoardServices")!=NULL,"only system framework loaded");return (void *)1;}
static void *TestDlsym(void *handle,const char *symbol){(void)handle;Check(!strcmp(symbol,"proc_pidpath_audittoken"),"only audit-token path API resolved");return MissingToken?NULL:(void *)TestTokenPath;}
static Class TestClass(NSString *name);
#define getpid TestGetpid
#define sysctl TestSysctl
#define proc_pidpath TestPath
#define dlopen TestDlopen
#define dlsym TestDlsym
#define NSClassFromString TestClass
#import "../shared/RBXProcessIdentity.m"
#undef getpid
#undef sysctl
#undef proc_pidpath
#undef dlopen
#undef dlsym
#undef NSClassFromString

@interface TestIdentifier:NSObject @end
@implementation TestIdentifier
+ (id)identifierWithPid:(int)pid {Check(pid==100,"service identifier uses observed PID");return @100;}
@end
@interface TestHandle:NSObject @end
@implementation TestHandle
+ (id)handleForIdentifier:(id)identifier error:(NSError **)error {
    Check([identifier isEqual:@100],"handle lookup uses specific identifier");Lookups++;
    if(Throw)[NSException raise:@"MissingSPI" format:@"unavailable"];
    if(ChangeAtLookup==1)Birth++;
    if(ChangeAtLookup==2)Path="/foreign/SameName.app/Facebook";
    if(ChangeAtLookup==3)Gone=YES;
    if(HandleMode==1)return nil;
    if(HandleMode==2)*error=[NSError errorWithDomain:@"test" code:1 userInfo:nil];
    return ExpectedHandle=[self new];
}
- (BOOL)isValid{return HandleMode!=3;}
- (int)pid{return HandleMode==4?101:100;}
- (NSString *)executablePath {
    if(HandleMode==5)return @"/foreign/app";
    if(HandleMode==6)return nil;
    if(HandleMode==8)return [@(Path) substringFromIndex:8]; // permitted /private/var alias
    return @(Path);
}
- (audit_token_t)auditToken {audit_token_t t={{0}};t.val[5]=HandleMode==7?101:100;t.val[7]=123;return t;}
@end
@interface TestPredicate:NSObject @end
@implementation TestPredicate
+ (id)predicateMatchingHandle:(id)handle {Check(handle==ExpectedHandle,"predicate binds verified handle, never a PID/name predicate");return ExpectedPredicate=[self new];}
@end
@interface TestContext:NSObject @end
@implementation TestContext
+ (id)defaultContextWithExplanation:(NSString *)reason{Check(reason.length>0,"termination has diagnostic reason");return [self new];}
@end
@interface TestRequest:NSObject @end
@implementation TestRequest
- (id)initWithPredicate:(id)predicate context:(id)context{Check(predicate==ExpectedPredicate&&[context isKindOfClass:TestContext.class],"request uses only bound predicate and context");return [super init];}
- (BOOL)execute:(NSError **)error{Requests++;if(RequestError)*error=[NSError errorWithDomain:@"RBSServiceErrorDomain" code:1 userInfo:nil];return !RequestDenied;}
@end
static Class TestClass(NSString *name){
    if(MissingClass)return Nil;
    return @{@"RBSProcessIdentifier":TestIdentifier.class,@"RBSProcessHandle":TestHandle.class,
        @"RBSProcessPredicate":TestPredicate.class,@"RBSTerminateContext":TestContext.class,
        @"RBSTerminateRequest":TestRequest.class}[name];
}

int main(void){@autoreleasepool{
    RBXObservedProcess observed;Reset();
    Check(RBXObserveProcess(100,&observed)==RBXProcessObserved&&observed.pid==100&&observed.startSeconds==42&&!strcmp(observed.executable,Path),"capture path and birth between two snapshots");
    Check(RBXTerminateObservedProcess(&observed)==RBXProcessTerminationRequested&&Requests==1&&TokenReads==1,"matching verified handle requests termination, not completed exit");
    for(int pid=0;pid<=1;pid++){Reset();Check(RBXObserveProcess(pid,&observed)==RBXProcessDenied&&Reads==0,"system PID refused before querying");}
    Reset();Check(RBXObserveProcess(50,&observed)==RBXProcessDenied&&Reads==0,"self refused");
    Reset();Check(RBXObserveProcess(100,NULL)==RBXProcessDenied&&Reads==0,"nil output refused");
    Reset();Gone=YES;Check(RBXObserveProcess(100,&observed)==RBXProcessGone&&Lookups==0,"successful empty PID query proves gone");
    Reset();Zombie=YES;Check(RBXObserveProcess(100,&observed)==RBXProcessGone,"zombie has no running task");
    for(int error=0;error<2;error++){Reset();TableError=error?EACCES:ESRCH;Check(RBXObserveProcess(100,&observed)==(error?RBXProcessDenied:RBXProcessGone),"denial distinguished from absence");}
    Reset();MissingBirth=YES;Check(RBXObserveProcess(100,&observed)==RBXProcessDenied,"missing birth denied");
    Reset();ReadSizeMode=1;Check(RBXObserveProcess(100,&observed)==RBXProcessDenied,"short kernel response denied");
    Reset();PathError=EACCES;Check(RBXObserveProcess(100,&observed)==RBXProcessDenied,"unreadable live path denied");
    Reset();PathError=ESRCH;Check(RBXObserveProcess(100,&observed)==RBXProcessChanged,"path disappearance followed by live PID requires rescan");
    Reset();InvalidPath=YES;Check(RBXObserveProcess(100,&observed)==RBXProcessDenied,"nonabsolute path rejected");
    Reset();Truncated=YES;Check(RBXObserveProcess(100,&observed)==RBXProcessDenied,"truncated path rejected");
    Reset();ChangedAtRead=2;Check(RBXObserveProcess(100,&observed)==RBXProcessChanged&&observed.pid==0,"PID reuse during capture publishes no identity");
    Reset();Interrupts=1;Check(RBXObserveProcess(100,&observed)==RBXProcessObserved&&Reads==3,"interrupted kernel query retries");
    Reset();Interrupts=6;Check(RBXObserveProcess(100,&observed)==RBXProcessDenied&&Reads==4,"persistent EINTR bounded to four attempts");
    Reset();RBXObserveProcess(100,&observed);Birth++;Check(RBXTerminateObservedProcess(&observed)==RBXProcessChanged&&Lookups==0&&Requests==0,"PID reuse before service lookup cannot request termination");
    Reset();RBXObserveProcess(100,&observed);Path="/foreign/SameName.app/Facebook";Check(RBXTerminateObservedProcess(&observed)==RBXProcessChanged&&Requests==0,"same PID new executable rejected");
    for(int change=1;change<=3;change++){Reset();RBXObserveProcess(100,&observed);ChangeAtLookup=change;Check(RBXTerminateObservedProcess(&observed)==(change==3?RBXProcessGone:RBXProcessChanged)&&Requests==0,"replacement/disappearance during handle lookup cannot request termination");}
    for(int mode=1;mode<=8;mode++){Reset();RBXObserveProcess(100,&observed);HandleMode=mode;BOOL allowed=mode==6||mode==8;Check(RBXTerminateObservedProcess(&observed)==(allowed?RBXProcessTerminationRequested:RBXProcessDenied)&&Requests==(allowed?1u:0u),"invalid/stale/wrong handle rejected; nil service path still needs token-bound kernel proof");}
    for(int mode=1;mode<=4;mode++){Reset();RBXObserveProcess(100,&observed);TokenMode=mode;Check(RBXTerminateObservedProcess(&observed)==(mode==4?RBXProcessChanged:RBXProcessDenied)&&Requests==0,"denied/truncated/foreign token path or changed process refused");}
    for(int mode=0;mode<3;mode++){Reset();RBXObserveProcess(100,&observed);MissingClass=mode==0;MissingToken=mode==1;Throw=mode==2;Check(RBXTerminateObservedProcess(&observed)==RBXProcessDenied&&Requests==0,"missing SPI or exception fails without a signal fallback");}
    for(int mode=0;mode<2;mode++){Reset();RBXObserveProcess(100,&observed);RequestDenied=mode==0;RequestError=mode==1;Check(RBXTerminateObservedProcess(&observed)==RBXProcessDenied&&Requests==1,"denied service request or accompanying error cannot claim success");}
    Reset();RBXObserveProcess(100,&observed);ChangedAtRead=6;Check(RBXTerminateObservedProcess(&observed)==RBXProcessChanged&&Requests==0,"late replacement during final observation rejected");
    Reset();RBXObserveProcess(100,&observed);observed.executable[0]='r';Check(RBXTerminateObservedProcess(&observed)==RBXProcessDenied&&Lookups==0,"malformed record refused");
    Reset();Check(RBXTerminateObservedProcess(NULL)==RBXProcessDenied&&Lookups==0,"nil record refused");
    printf("%s process identity: %u checks, %u failures; mocked system service, no real process signalled\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
