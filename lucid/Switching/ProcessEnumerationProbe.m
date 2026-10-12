#import <Foundation/Foundation.h>
#import "LBXDarwinDrainBackend.h"
#import "../../shared/RBXProcessIdentity.h"
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <dlfcn.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>

// Read-only diagnosis of complete-process observation. No process identity,
// executable path, account bytes, storage mutation, or stop request is exported.
static double Clock(void){struct timespec t;return clock_gettime(CLOCK_MONOTONIC,&t)?0:t.tv_sec+t.tv_nsec/1e9;}
static void Count(NSMutableDictionary *counts,NSString *key){counts[key]=@([counts[key] unsignedIntegerValue]+1);}
static NSString *Birth(pid_t pid,struct kinfo_proc *process){int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,pid};size_t size=sizeof(*process);memset(process,0,sizeof(*process));errno=0;int rc=sysctl(mib,4,process,&size,NULL,0),saved=errno;
    if(rc)return [NSString stringWithFormat:@"sysctl-errno-%d",saved];if(!size)return @"gone";if(size!=sizeof(*process))return [NSString stringWithFormat:@"unexpected-size-%zu",size];
    if(process->kp_proc.p_pid!=pid)return @"pid-mismatch";if(process->kp_proc.p_stat==SZOMB)return @"zombie";
    if(process->kp_proc.p_starttime.tv_sec<=0)return @"invalid-start-seconds";if(process->kp_proc.p_starttime.tv_usec<0||process->kp_proc.p_starttime.tv_usec>=1000000)return @"invalid-start-microseconds";return nil;}
static NSString *Trace(pid_t pid){struct kinfo_proc before,after;NSString *issue=Birth(pid,&before);if(issue)return [@"before:" stringByAppendingString:issue];
    char path[PROC_PIDPATHINFO_MAXSIZE]={0};errno=0;int length=proc_pidpath(pid,path,sizeof(path)),saved=errno;
    issue=Birth(pid,&after);if(issue)return [@"after:" stringByAppendingString:issue];
    if(before.kp_proc.p_starttime.tv_sec!=after.kp_proc.p_starttime.tv_sec||before.kp_proc.p_starttime.tv_usec!=after.kp_proc.p_starttime.tv_usec)return @"birth-changed";
    if(length<=0)return [NSString stringWithFormat:@"path-errno-%d",saved];
    size_t count=strnlen(path,sizeof(path));if(length>=(int)sizeof(path)||!count||count>=sizeof(path)||path[0]!='/')return @"invalid-path-format";
    return @"independent-recheck-observed";
}
static NSDictionary *PrivateIdentity(pid_t pid){
    // Read-only csops operation numbers and the identity blob's eight-byte
    // header follow Apple's xnu bsd/sys/codesign.h and kern/kern_proc.c.
    typedef int(*CSOps)(pid_t,unsigned,void *,size_t);CSOps csops=(CSOps)dlsym(RTLD_DEFAULT,"csops");
    struct kinfo_proc before,after;NSString *issue=Birth(pid,&before);if(issue)return @{@"privatePID":@(pid),@"birthFailure":issue};
    uint8_t identity[1024]={0},hash[20]={0};errno=0;int identityRC=csops?csops(pid,11,identity,sizeof(identity)):-1,identityErrno=csops?errno:ENOSYS;
    errno=0;int hashRC=csops?csops(pid,5,hash,sizeof(hash)):-1,hashErrno=csops?errno:ENOSYS;
    issue=Birth(pid,&after);BOOL stable=!issue&&before.kp_proc.p_starttime.tv_sec==after.kp_proc.p_starttime.tv_sec&&before.kp_proc.p_starttime.tv_usec==after.kp_proc.p_starttime.tv_usec;
    NSMutableDictionary *row=[@{@"privatePID":@(pid),@"startSeconds":@(before.kp_proc.p_starttime.tv_sec),@"startMicroseconds":@(before.kp_proc.p_starttime.tv_usec),@"effectiveUID":@(before.kp_eproc.e_ucred.cr_uid),@"realUID":@(before.kp_eproc.e_pcred.p_ruid),@"birthStable":@(stable),@"identityRC":@(identityRC),@"identityErrno":@(identityErrno),@"cdhashRC":@(hashRC),@"cdhashErrno":@(hashErrno)} mutableCopy];
    uint32_t length=0;memcpy(&length,identity+4,4);length=ntohl(length);
    if(!identityRC&&length>=9&&length<=sizeof(identity)&&identity[length-1]==0){NSString *name=[[NSString alloc] initWithBytes:identity+8 length:length-9 encoding:NSUTF8StringEncoding];if(name)row[@"signingIdentifier"]=name;}
    if(!hashRC){NSMutableString *hex=[NSMutableString string];for(NSUInteger i=0;i<sizeof(hash);i++)[hex appendFormat:@"%02x",hash[i]];row[@"cdhash"]=hex;}
    return row;
}
static NSDictionary *Inspect(BOOL privateIdentities){
    NSMutableDictionary *result=[@{@"schemaVersion":@1,@"kind":@"read-only-process-enumeration-diagnostic",@"processDetailsExported":@NO,@"processesTerminated":@0,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO,@"runtimeIsolationAccepted":@NO,@"kinfoProcBytes":@(sizeof(struct kinfo_proc))} mutableCopy];
    if(getuid()!=0||geteuid()!=0){result[@"status"]=@"ROOT_REQUIRED";return result;}
    // Match the framework state of the application-gate capture process.
    if(!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",RTLD_NOW))dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",RTLD_NOW);
    NSError *error=nil;NSArray *snapshot=[[[LBXDarwinDrainBackend alloc] init] snapshot:&error];result[@"backendSnapshotSucceeded"]=@(snapshot!=nil);result[@"backendSnapshotCount"]=@(snapshot.count);
    NSArray *known=@[@"Process enumeration sizing failed",@"Process enumeration failed",@"Process enumeration unstable",@"Live process identity unreadable or changed"];
    result[@"backendFailure"]=[known containsObject:error.localizedDescription]?error.localizedDescription:(error?@"other":@"none");
    int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0};size_t bytes=0;errno=0;int rc=sysctl(mib,4,NULL,&bytes,NULL,0),saved=errno;result[@"sizeQueryRC"]=@(rc);result[@"sizeQueryErrno"]=@(saved);result[@"sizeQueryBytes"]=@(bytes);
    if(rc||!bytes||bytes>32*1024*1024){result[@"status"]=@"SIZE_QUERY_REFUSED";return result;}
    size_t capacity=bytes+64*sizeof(struct kinfo_proc);struct kinfo_proc *table=calloc(1,capacity);if(!table){result[@"status"]=@"ALLOCATION_FAILED";return result;}
    bytes=capacity;errno=0;rc=sysctl(mib,4,table,&bytes,NULL,0);saved=errno;result[@"tableQueryRC"]=@(rc);result[@"tableQueryErrno"]=@(saved);result[@"tableBytes"]=@(bytes);result[@"tableCapacity"]=@(capacity);
    if(rc||!bytes||bytes>capacity||bytes%sizeof(*table)||bytes/sizeof(*table)>65536){free(table);result[@"status"]=@"TABLE_QUERY_REFUSED";return result;}
    NSMutableDictionary *counts=[NSMutableDictionary dictionary],*rechecks=[NSMutableDictionary dictionary];NSMutableArray *privateRows=[NSMutableArray array];NSUInteger traced=0;double until=Clock()+10;BOOL complete=YES;
    for(size_t i=0;i<bytes/sizeof(*table);i++){
        if(Clock()>until){complete=NO;break;}pid_t pid=table[i].kp_proc.p_pid;if(pid<=1||pid==getpid()||table[i].kp_proc.p_stat==SZOMB){Count(counts,@"excluded-system-self-zombie");continue;}
        RBXObservedProcess identity;RBXProcessIdentityResult observed=RBXObserveProcess(pid,&identity);
        NSString *label=observed==RBXProcessObserved?@"observed":observed==RBXProcessGone?@"gone":observed==RBXProcessChanged?@"changed":observed==RBXProcessDenied?@"denied":@"invalid-result";Count(counts,label);
        if(observed!=RBXProcessObserved&&observed!=RBXProcessGone&&traced<64){traced++;Count(rechecks,Trace(pid));if(privateIdentities)[privateRows addObject:PrivateIdentity(pid)];}
    }
    free(table);result[@"status"]=complete?@"DIAGNOSED":@"DIAGNOSIS_TIMEOUT";result[@"rowCount"]=@(bytes/sizeof(struct kinfo_proc));result[@"observationCounts"]=counts;result[@"failureRecheckCounts"]=rechecks;result[@"failureRechecks"]=@(traced);if(privateIdentities){result[@"privateUnavailableProcesses"]=privateRows;result[@"processDetailsExported"]=@YES;}return result;
}
int main(int argc,const char **argv){@autoreleasepool{BOOL privateIdentities=argc==2&&!strcmp(argv[1],"--private-identities");if(argc!=1&&!privateIdentities)return 2;NSDictionary *result=Inspect(privateIdentities);NSData *bytes=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];if(!bytes||fwrite(bytes.bytes,1,bytes.length,stdout)!=bytes.length||putchar('\n')==EOF)return 2;return [result[@"status"] isEqual:@"ROOT_REQUIRED"]?77:0;}}
