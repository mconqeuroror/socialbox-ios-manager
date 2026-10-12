// Physical-device acceptance only. Every effect targets this tool's own
// unreaped children; no application PID or executable is accepted as input.
#import <Foundation/Foundation.h>
#import "../lucid/Switching/LBXDarwinDrainBackend.h"
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>
#include <spawn.h>
#include <pthread.h>
#include <poll.h>
#include <pwd.h>
#include <grp.h>
extern char **environ;

static double Now(void) { struct timespec t; return clock_gettime(CLOCK_MONOTONIC,&t)==0?t.tv_sec+t.tv_nsec/1e9:0; }
static void *Idle(__unused void *arg) { for(;;) pause(); return NULL; }
static const char *Status(RBXProcessIdentityResult result) {
    switch(result) {
        case RBXProcessObserved:return "observed";
        case RBXProcessGone:return "gone";
        case RBXProcessChanged:return "changed";
        case RBXProcessDenied:return "denied";
        case RBXProcessTerminationRequested:return "termination_requested";
    }
    return "invalid";
}
static pid_t SpawnOwned(const char *executable) {
    int ready[2]; if(pipe(ready)) return -1;
    char fd[24];snprintf(fd,sizeof(fd),"%d",ready[1]);
    char *args[]={(char *)executable,"--owned-child",fd,NULL};
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addclose(&actions,ready[0]);
    pid_t pid=-1;int result=posix_spawn(&pid,executable,&actions,NULL,args,environ);
    posix_spawn_file_actions_destroy(&actions);close(ready[1]);
    struct pollfd event={.fd=ready[0],.events=POLLIN};char value=0;
    BOOL started=!result && poll(&event,1,1000)>0 && read(ready[0],&value,1)==1 && value=='R';
    close(ready[0]);
    if(started)return pid;
    if(!result){int status;pid_t waited=waitpid(pid,&status,WNOHANG);if(waited==0){kill(pid,SIGKILL);while(waitpid(pid,&status,0)<0&&errno==EINTR){}}}
    return -1;
}
static BOOL ReapOwned(pid_t pid,BOOL *needed,int *status) {
    if(pid<=1)return NO;
    pid_t waited;do{waited=waitpid(pid,status,WNOHANG);}while(waited<0&&errno==EINTR);
    *needed=waited==0;
    // Acceptance cleanup only. WNOHANG==0 proves this is our unreaped child;
    // its PID cannot be recycled before reaping. Never used for an app target.
    if(*needed){kill(pid,SIGKILL);do{waited=waitpid(pid,status,0);}while(waited<0&&errno==EINTR);}
    return waited==pid;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(getuid()!=0||geteuid()!=0)return 77;
    if(argc==3&&!strcmp(argv[1],"--owned-child")) {
        struct passwd *mobile=getpwnam("mobile");
        if(!mobile||setgroups(0,NULL)||setgid(mobile->pw_gid)||setuid(mobile->pw_uid))return 77;
        alarm(12);
        pthread_t thread;
        for(unsigned i=0;i<4;i++)if(pthread_create(&thread,NULL,Idle,NULL))return 70;else pthread_detach(thread);
        int ready=atoi(argv[2]);if(ready<3||write(ready,"R",1)!=1)return 74;close(ready);
        for(;;)pause();
    }
    if(argc!=1)return 64;
    LBXDarwinDrainBackend *backend=[LBXDarwinDrainBackend new];NSError *error=nil;
    NSArray *snapshot=[backend snapshot:&error];
    NSMutableDictionary *receipt=[@{@"schemaVersion":@2,@"scope":@"two_own_mobile_uid_multithread_children",
        @"completeProcessSnapshot":@(snapshot!=nil),@"processCount":@(snapshot.count),
        @"targetApplicationPermission":@"NOT_RUN",@"networkIsolation":@"NOT_RUN",
        @"crossContainerIsolation":@"NOT_RUN",@"atomicPIDVersionTermination":@"NOT_PROVEN"} mutableCopy];
    if(error)receipt[@"snapshotFailure"]=error.localizedDescription;
    char executable[PROC_PIDPATHINFO_MAXSIZE]={0};int length=proc_pidpath(getpid(),executable,sizeof(executable));
    pid_t child=-1,control=-1;
    if(length>0&&(size_t)length<sizeof(executable)){child=SpawnOwned(executable);control=SpawnOwned(executable);}
    receipt[@"bothChildrenReady"]=@(child>1&&control>1);
    if(child>1&&control>1){
        RBXObservedProcess observed;RBXProcessIdentityResult captured=RBXObserveProcess(child,&observed);
        receipt[@"observation"]=@(Status(captured));
        RBXObservedProcess stale=observed;stale.startSeconds++;
        BOOL staleRefused=captured==RBXProcessObserved&&RBXTerminateObservedProcess(&stale)==RBXProcessChanged;
        receipt[@"staleObservationRefused"]=@(staleRefused);
        double start=Now();RBXProcessIdentityResult stopped=captured==RBXProcessObserved&&staleRefused?RBXTerminateObservedProcess(&observed):RBXProcessDenied;
        receipt[@"termination"]=@(Status(stopped));BOOL gone=NO;
        for(unsigned pass=0;pass<50;pass++){
            RBXObservedProcess again;if(RBXObserveProcess(child,&again)==RBXProcessGone){gone=YES;break;}usleep(20000);
        }
        double elapsed=Now()-start;receipt[@"stopElapsedMilliseconds"]=@((int)(elapsed*1000));
        receipt[@"observedExitWithinTwoSeconds"]=@(gone&&elapsed>0&&elapsed<2);
        RBXObservedProcess other;BOOL untouched=RBXObserveProcess(control,&other)==RBXProcessObserved;
        receipt[@"sameExecutableControlStillRunning"]=@(untouched);
        BOOL cleanup=NO;int status=0;BOOL reaped=ReapOwned(child,&cleanup,&status);child=-1;
        BOOL killed=reaped&&WIFSIGNALED(status)&&WTERMSIG(status)==SIGKILL;
        receipt[@"acceptanceCleanupNeeded"]=@(cleanup);receipt[@"ownChildReaped"]=@(reaped);receipt[@"targetExitedBySIGKILL"]=@(killed);
        receipt[@"identityScopedStopPassed"]=@(stopped==RBXProcessTerminationRequested&&staleRefused&&gone&&elapsed>0&&elapsed<2&&untouched&&reaped&&killed&&!cleanup);
    }
    BOOL cleanup=NO;int status=0;
    if(child>1)ReapOwned(child,&cleanup,&status);
    receipt[@"ownControlReaped"]=@(control>1&&ReapOwned(control,&cleanup,&status));
    NSData *json=[NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingSortedKeys error:nil];
    if(!json||fwrite(json.bytes,1,json.length,stdout)!=json.length||fputc('\n',stdout)==EOF)return 74;
    return [receipt[@"identityScopedStopPassed"] boolValue]&&snapshot&&[receipt[@"ownControlReaped"] boolValue]?0:1;
}}
