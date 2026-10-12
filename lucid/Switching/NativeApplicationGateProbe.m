#import <Foundation/Foundation.h>
#import "LBXNativeApplicationGate.h"
#import "LBXNativeIsolationJournal.h"
#import "../../shared/RBXStorageGate.h"
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>

// Private acceptance probe. No storage traversal, selection change, data gate,
// account reads, or arbitrary executable/PID input. Root supplies a fresh 0700
// directory below this fixed scope; recovery uses its exact retained journal.
static NSString *const Scope=@"/private/var/root/socialbox-native-gate-probes";
static NSString *const ProbeComponent=@"native-application-gate-probe";
static NSMutableArray *Diagnostics;
static void Diagnose(NSString *stage,BOOL success,NSError *error){
    if(!success&&Diagnostics.count<32)[Diagnostics addObject:@{@"stage":stage,@"errorDomain":error.domain?:@"unavailable",@"errorCode":@(error.code),
        @"sourceStage":[error.userInfo[@"stage"] isKindOfClass:NSString.class]?error.userInfo[@"stage"]:@"unavailable"}];
}
static BOOL CloseAndDrain(LBXNativeApplicationGate *gate,NSString *stage){NSError *error=nil;BOOL ok=[gate closeAndDrainBeforeDeadline:LBXNativeApplicationGateClock()+30 error:&error];Diagnose(stage,ok,error);return ok;}
static double Deadline(double seconds){return LBXNativeApplicationGateClock()+seconds;}
static BOOL DirectoryArgument(NSString *path){
    if(![path isKindOfClass:NSString.class]||![path.stringByDeletingLastPathComponent isEqual:Scope])return NO;
    NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:path.lastPathComponent];
    return uuid&&[[Scope stringByAppendingPathComponent:uuid.UUIDString.lowercaseString] isEqual:path];
}
static BOOL EmptyDirectory(NSString *path){
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat s;
    if(fd<0||fstat(fd,&s)||s.st_uid||s.st_gid||(s.st_mode&07777)!=0700||s.st_flags||!RBXStorageGateNoACL(fd)){if(fd>=0)close(fd);return NO;}
    DIR *dir=fdopendir(fd);if(!dir){close(fd);return NO;}BOOL empty=YES;
    for(;;){errno=0;struct dirent *entry=readdir(dir);if(!entry){if(errno)empty=NO;break;}if(strcmp(entry->d_name,".")&&strcmp(entry->d_name,"..")){empty=NO;break;}}
    closedir(dir);return empty;
}
static BOOL Payload(NSDictionary *value){
    return [value isKindOfClass:NSDictionary.class]&&value.count==9&&[value[@"component"] isEqual:ProbeComponent]&&
        [value[@"formatVersion"] isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value[@"formatVersion"])!=CFBooleanGetTypeID()&&
        [value[@"formatVersion"] isEqual:@1]&&[value[@"applicationGate"] isKindOfClass:NSDictionary.class]&&
        [@[@"PASS",@"FAIL",@"UNKNOWN"] containsObject:value[@"acceptance"]]&&[value[@"spawnErrno"] isKindOfClass:NSNumber.class]&&
        CFGetTypeID((__bridge CFTypeRef)value[@"spawnErrno"])!=CFBooleanGetTypeID()&&!CFNumberIsFloatType((__bridge CFNumberRef)value[@"spawnErrno"])&&
        [value[@"spawnErrno"] longLongValue]>=-1&&[value[@"spawnErrno"] longLongValue]<=4095&&
        [value[@"probeAccountFileContentsRead"] isEqual:@NO]&&[value[@"storagePermissionsChanged"] isEqual:@NO]&&
        [value[@"selectionChanged"] isEqual:@NO]&&[value[@"phase"] isKindOfClass:NSString.class]&&
        [@[@"prepared",@"closed",@"spawn-check-pending",@"spawn-checked",@"restoring",@"restored",@"abort-restoring-original-code",@"aborted-original-code-restored"] containsObject:value[@"phase"]];
}
static BOOL Exact(LBXNativeIsolationJournal *journal,NSDictionary *expected,LBXNativeApplicationGate *gate){
    NSError *error=nil;NSDictionary *current=[journal validatedCurrentRecord:&error];
    if(error)Diagnose(@"journal-validation",NO,error);
    return !error&&expected&&[current isEqual:expected]&&Payload(current[@"payload"])&&
        [current[@"payload"][@"applicationGate"] isEqual:gate.privateJournalRecord];
}
static BOOL Publish(LBXNativeIsolationJournal *journal,NSDictionary **expected,LBXNativeApplicationGate *gate,
                    NSString *phase,NSString *acceptance,NSInteger spawnError){
    NSDictionary *payload=@{@"formatVersion":@1,@"component":ProbeComponent,@"applicationGate":gate.privateJournalRecord,
        @"phase":phase,@"acceptance":acceptance,@"spawnErrno":@(spawnError),
        @"probeAccountFileContentsRead":@NO,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO};
    NSError *error=nil;if(![journal compareRecord:*expected replaceWith:payload error:&error]){Diagnose([@"journal-publish-" stringByAppendingString:phase],NO,error);return NO;}
    *expected=journal.currentRecord;return Exact(journal,*expected,gate);
}
static BOOL Modes(NSDictionary *record,BOOL closed,NSUInteger *changed){
    NSArray *executables=record[@"executables"];if(![executables isKindOfClass:NSArray.class]||!executables.count||executables.count>129)return NO;
    NSUInteger count=0;for(NSDictionary *entry in executables){NSString *path=entry[@"path"];NSDictionary *original=entry[@"metadata"];struct stat s;
        if(![path isKindOfClass:NSString.class]||lstat(path.fileSystemRepresentation,&s)||!S_ISREG(s.st_mode)||s.st_nlink!=1||
           s.st_dev!=[original[@"device"] longLongValue]||s.st_ino!=[original[@"inode"] unsignedLongLongValue]||
           s.st_uid!=[original[@"owner"] unsignedIntValue]||s.st_gid!=[original[@"group"] unsignedIntValue]||s.st_flags!=[original[@"flags"] unsignedIntValue])return NO;
        mode_t mode=[original[@"mode"] unsignedIntValue],expected=closed?(mode&~0111):mode;
        if((s.st_mode&07777)!=expected)return NO;if(mode&0111)count++;
    }if(changed)*changed=count;return YES;
}
typedef enum {ChildNotStarted,ChildDescriptor,ChildSetGroups,ChildSetGID,ChildSetUID,ChildIdentity,
    ChildGroupRead,ChildGroupPolicy,ChildCredentialsVerified,ChildAttributes,ChildAttributeFlags,ChildSpawn,ChildCleanup} ChildStage;
typedef enum {AttemptNotStarted,AttemptArgument,AttemptLimit,AttemptAllocation,AttemptPipe,AttemptPipeFlags,
    AttemptSignal,AttemptFork,AttemptPoll,AttemptRead,AttemptTimeout,AttemptReap,AttemptExit,AttemptReceipt,
    AttemptSignalRestore,AttemptComplete} AttemptStage;
typedef struct {uint32_t magic;int stage,credentialError,spawnError,unexpectedSpawn,childReaped;
    uint32_t realUID,effectiveUID,realGID,effectiveGID;int identityObserved,groupCount,rootGroupCount,foreignGroupCount;} SpawnResult;
typedef struct {int stage,error,childExit;} SpawnAttempt;
static SpawnResult EmptySpawnResult(void){return (SpawnResult){.spawnError=-1,.groupCount=-1,.rootGroupCount=-1,.foreignGroupCount=-1};}
static BOOL CredentialValuesAllowed(uid_t realUID,uid_t effectiveUID,gid_t realGID,gid_t effectiveGID,const gid_t *groups,int count){
    if(realUID!=501||effectiveUID!=501||realGID!=501||effectiveGID!=501||count<0||count>128||(count&&!groups))return NO;
    for(int i=0;i<count;i++)if(groups[i]!=501)return NO;
    return YES;
}
static NSString *ChildStageName(int stage){switch(stage){
    case ChildNotStarted:return @"not-started";case ChildDescriptor:return @"descriptor";case ChildSetGroups:return @"setgroups";
    case ChildSetGID:return @"setgid";case ChildSetUID:return @"setuid";case ChildIdentity:return @"identity-readback";
    case ChildGroupRead:return @"group-readback";case ChildGroupPolicy:return @"group-policy";
    case ChildCredentialsVerified:return @"credentials-verified";case ChildAttributes:return @"spawn-attributes";
    case ChildAttributeFlags:return @"spawn-attribute-flags";case ChildSpawn:return @"spawn";case ChildCleanup:return @"unexpected-child-cleanup";
    default:return @"invalid-stage";}}
static NSString *AttemptStageName(int stage){switch(stage){
    case AttemptNotStarted:return @"not-started";case AttemptArgument:return @"argument";case AttemptLimit:return @"descriptor-limit";
    case AttemptAllocation:return @"allocation";case AttemptPipe:return @"pipe";case AttemptPipeFlags:return @"pipe-flags";
    case AttemptSignal:return @"signal-setup";case AttemptFork:return @"fork";case AttemptPoll:return @"poll-receipt";
    case AttemptRead:return @"read-receipt";case AttemptTimeout:return @"receipt-timeout";case AttemptReap:return @"reap-child";
    case AttemptExit:return @"child-exit";case AttemptReceipt:return @"receipt-validation";case AttemptSignalRestore:return @"signal-restore";
    case AttemptComplete:return @"complete";default:return @"invalid-stage";}}
static NSDictionary *SpawnDetails(const SpawnResult *result,const SpawnAttempt *attempt,BOOL received){
    return @{ @"receiptReceived":@(received),@"transportStage":AttemptStageName(attempt->stage),@"transportErrno":@(attempt->error),
        @"childExit":@(attempt->childExit),@"credentialStage":ChildStageName(result->stage),@"credentialErrno":@(result->credentialError),
        @"identityObserved":@(result->identityObserved!=0),@"allIdentityIDs501":@(result->identityObserved&&result->realUID==501&&result->effectiveUID==501&&result->realGID==501&&result->effectiveGID==501),
        @"groupCount":@(result->groupCount),@"rootGroupCount":@(result->rootGroupCount),@"foreignGroupCount":@(result->foreignGroupCount)};
}
static double ChildClock(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return t.tv_sec+t.tv_nsec/1e9;}
static BOOL Reap(pid_t pid,int *status,double seconds){double until=ChildClock()+seconds;do{pid_t result=waitpid(pid,status,WNOHANG);if(result==pid)return YES;if(result<0&&errno!=EINTR)return NO;struct timespec delay={0,10000000};nanosleep(&delay,NULL);}while(ChildClock()<until);return NO;}
static void SpawnChild(const char *path,int out,int maximumFD,BOOL spawn){
    // After fork use C/POSIX only. Drop inherited root descriptors before UID.
    if(out!=3&&dup2(out,3)<0)_exit(120);for(int fd=0;fd<maximumFD;fd++)if(fd!=3)close(fd);
    SpawnResult result=EmptySpawnResult();result.magic=0x53424750;result.stage=ChildDescriptor;
    if(fcntl(3,F_SETFD,FD_CLOEXEC)<0){result.credentialError=errno;goto send;}
    result.stage=ChildSetGroups;if(setgroups(0,NULL)){result.credentialError=errno;goto send;}
    result.stage=ChildSetGID;if(setgid(501)){result.credentialError=errno;goto send;}
    result.stage=ChildSetUID;if(setuid(501)){result.credentialError=errno;goto send;}
    result.stage=ChildIdentity;result.realUID=getuid();result.effectiveUID=geteuid();result.realGID=getgid();result.effectiveGID=getegid();result.identityObserved=1;
    if(result.realUID!=501||result.effectiveUID!=501||result.realGID!=501||result.effectiveGID!=501){result.credentialError=EPERM;goto send;}
    result.stage=ChildGroupRead;gid_t groups[128];result.groupCount=getgroups(128,groups);
    if(result.groupCount<0){result.credentialError=errno;goto send;}
    result.rootGroupCount=0;result.foreignGroupCount=0;
    for(int i=0;i<result.groupCount;i++){if(groups[i]==0)result.rootGroupCount++;if(groups[i]!=501)result.foreignGroupCount++;}
    result.stage=ChildGroupPolicy;
    // The device credential-only receipt confirms Darwin reports primary
    // GID501 here after setgroups(0) + setgid/setuid501. Allow only that GID;
    // any root/foreign group, read failure or mismatched identity still fails.
    if(!CredentialValuesAllowed(result.realUID,result.effectiveUID,result.realGID,result.effectiveGID,groups,result.groupCount)){result.credentialError=EPERM;goto send;}
    result.stage=ChildCredentialsVerified;
    if(spawn){
        result.stage=ChildAttributes;posix_spawnattr_t attributes;int rc=posix_spawnattr_init(&attributes);
        if(!rc){result.stage=ChildAttributeFlags;rc=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_START_SUSPENDED|POSIX_SPAWN_CLOEXEC_DEFAULT);
            if(!rc){char *const arguments[]={(char *)path,NULL};char *const environment[]={NULL};pid_t spawned=-1;
                result.stage=ChildSpawn;
                result.spawnError=posix_spawn(&spawned,path,NULL,&attributes,arguments,environment);
                if(!result.spawnError){result.stage=ChildCleanup;result.unexpectedSpawn=1;int status=0;
                    // This is our own immediate suspended child, never a caller
                    // PID. Root additionally drains the exact captured app.
                    if(!kill(spawned,SIGKILL)&&Reap(spawned,&status,2))result.childReaped=1;
                }
            }else result.spawnError=rc;posix_spawnattr_destroy(&attributes);
        }else result.spawnError=rc;
    }
send:;
    const char *bytes=(const char *)&result;size_t offset=0;while(offset<sizeof(result)){ssize_t n=write(3,bytes+offset,sizeof(result)-offset);if(n<0&&errno==EINTR)continue;if(n<=0)break;offset+=(size_t)n;}_exit(offset==sizeof(result)?0:121);
}
static BOOL AttemptKind(NSString *path,BOOL spawn,SpawnResult *result,SpawnAttempt *attempt){
    *result=EmptySpawnResult();*attempt=(SpawnAttempt){.stage=AttemptArgument,.childExit=-1};
    if(spawn&&(![path isKindOfClass:NSString.class]||!path.isAbsolutePath)){attempt->error=EINVAL;return NO;}
    attempt->stage=AttemptLimit;errno=0;long limit=sysconf(_SC_OPEN_MAX);if(limit<4||limit>1048576){attempt->error=errno?:EINVAL;return NO;}
    attempt->stage=AttemptAllocation;char *executable=spawn?strdup(path.fileSystemRepresentation):NULL;if(spawn&&!executable){attempt->error=errno?:ENOMEM;return NO;}
    attempt->stage=AttemptPipe;int pipeFD[2];if(pipe(pipeFD)){attempt->error=errno;free(executable);return NO;}
    attempt->stage=AttemptPipeFlags;
    if(fcntl(pipeFD[0],F_SETFD,FD_CLOEXEC)<0||fcntl(pipeFD[1],F_SETFD,FD_CLOEXEC)<0||fcntl(pipeFD[0],F_SETFL,O_NONBLOCK)<0){attempt->error=errno;close(pipeFD[0]);close(pipeFD[1]);free(executable);return NO;}
    struct sigaction original,action={0};action.sa_handler=SIG_DFL;sigemptyset(&action.sa_mask);
    attempt->stage=AttemptSignal;if(sigaction(SIGCHLD,&action,&original)){attempt->error=errno;close(pipeFD[0]);close(pipeFD[1]);free(executable);return NO;}
    attempt->stage=AttemptFork;pid_t child=fork();if(child<0)attempt->error=errno;if(child==0){close(pipeFD[0]);SpawnChild(executable,pipeFD[1],(int)limit,spawn);}
    close(pipeFD[1]);free(executable);size_t offset=0;double until=ChildClock()+5;BOOL good=child>0;
    while(good&&offset<sizeof(*result)&&ChildClock()<until){struct pollfd p={pipeFD[0],POLLIN,0};int ready=poll(&p,1,100);
        if(ready<0&&errno==EINTR)continue;if(ready<0){attempt->stage=AttemptPoll;attempt->error=errno;good=NO;break;}if(!ready)continue;
        ssize_t n=read(pipeFD[0],(char *)result+offset,sizeof(*result)-offset);if(n<0&&(errno==EINTR||errno==EAGAIN))continue;if(n<=0){attempt->stage=AttemptRead;attempt->error=n<0?errno:0;good=NO;break;}offset+=(size_t)n;
    }
    if(good&&offset<sizeof(*result)){attempt->stage=AttemptTimeout;attempt->error=ETIMEDOUT;good=NO;}
    close(pipeFD[0]);int status=0;BOOL reaped=child>0&&Reap(child,&status,1);
    if(child>0&&!reaped){if(good){attempt->stage=AttemptReap;attempt->error=errno?:ETIMEDOUT;}kill(child,SIGKILL);reaped=Reap(child,&status,2);good=NO;}
    if(reaped&&WIFEXITED(status))attempt->childExit=WEXITSTATUS(status);
    if(good&&(!reaped||!WIFEXITED(status)||WEXITSTATUS(status)!=0)){attempt->stage=AttemptExit;good=NO;}
    if(good&&(offset!=sizeof(*result)||result->magic!=0x53424750)){attempt->stage=AttemptReceipt;good=NO;}
    if(sigaction(SIGCHLD,&original,NULL)){if(good){attempt->stage=AttemptSignalRestore;attempt->error=errno;}good=NO;}
    if(good)attempt->stage=AttemptComplete;return good;
}
static int Output(NSDictionary *value,int code){NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];if(!bytes||fwrite(bytes.bytes,1,bytes.length,stdout)!=bytes.length||putchar('\n')==EOF)return 2;return code;}
#if LBX_PRIVATE_GATE_ABORT_RECOVERY
static int AbortUnstarted(LBXNativeIsolationJournal *journal){
    NSError *error=nil;NSDictionary *expected=[journal validatedCurrentRecord:&error];LBXNativeApplicationGate *gate=nil;BOOL restored=NO;
    @try {
        NSDictionary *payload=expected[@"payload"];
        BOOL eligible=Payload(payload)&&[payload[@"acceptance"] isEqual:@"FAIL"]&&[payload[@"spawnErrno"] isEqual:@-1]&&
            [@[@"prepared",@"abort-restoring-original-code",@"aborted-original-code-restored"] containsObject:payload[@"phase"]];
        if(!error&&eligible)gate=[LBXNativeApplicationGate recoverFromJournal:journal beforeDeadline:Deadline(120) error:&error];
        Diagnose(@"abort-gate-recover",gate!=nil,error);
        if(gate){error=nil;
            restored=[gate restoreOriginalExecutionForUnstartedProbe:journal beforeDeadline:Deadline(120) authorization:^BOOL{
                // The private method itself owns the exact journal intent
                // transition. Revalidate its live envelope and static binding.
                return getuid()==0&&geteuid()==0&&Exact(journal,journal.currentRecord,gate);
            } error:&error];Diagnose(@"abort-original-code-restore",restored,error);
            restored=restored&&Modes(gate.privateJournalRecord,NO,NULL);
        }
    }@catch(__unused NSException *exception){Diagnose(@"abort-operation-refused",NO,nil);restored=NO;}
    NSDictionary *report=@{@"status":restored?@"ABORTED":@"FAIL",@"acceptance":@"FAIL",@"abortUnstartedProbe":@YES,
        @"originalExecutionRestored":@(restored),@"executableCount":@([gate.privateJournalRecord[@"executables"] count]),@"freshDrainObserved":@NO,
        @"journalRetained":@YES,@"probeAccountFileContentsRead":@NO,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO,@"runtimeIsolationAccepted":@NO,@"diagnostics":Diagnostics};
    [journal close];return Output(report,restored?0:3);
}
#endif
int main(int argc,const char **argv){@autoreleasepool{
    Diagnostics=[NSMutableArray array];
    if(argc==2&&!strcmp(argv[1],"credentials")){
        if(getuid()!=0||geteuid()!=0)return Output(@{@"status":@"REFUSED",@"rootRequired":@YES},77);
        SpawnResult result;SpawnAttempt attempt;BOOL received=AttemptKind(nil,NO,&result,&attempt);
        BOOL confirmed=received&&!result.credentialError&&result.stage==ChildCredentialsVerified;
        return Output(@{@"status":confirmed?@"PASS":@"FAIL",@"credentialOnly":@YES,@"spawnAttempted":@NO,
            @"spawnCredentialDropConfirmed":@(confirmed),@"spawnDiagnostics":SpawnDetails(&result,&attempt,received),
            @"applicationExecutionModesChanged":@NO,@"probeAccountFileContentsRead":@NO,@"storagePermissionsChanged":@NO,
            @"selectionChanged":@NO,@"runtimeIsolationAccepted":@NO},confirmed?0:3);
    }
    if(argc!=3||getuid()!=0||geteuid()!=0)return Output(@{@"status":@"REFUSED",@"rootRequired":@YES},77);
    NSString *mode=@(argv[1]),*directory=@(argv[2]);BOOL aborting=NO;
#if LBX_PRIVATE_GATE_ABORT_RECOVERY
    aborting=[mode isEqual:@"abort-unstarted"];
#endif
    BOOL recovery=[mode isEqual:@"recover"]||aborting;
    if((!recovery&&![mode isEqual:@"exercise"])||!DirectoryArgument(directory))return Output(@{@"status":@"REFUSED",@"fixedPrivateJournalScopeRequired":@YES},2);
    umask(077);if(!recovery&&!EmptyDirectory(directory))return Output(@{@"status":@"REFUSED",@"freshPrivateJournalRequired":@YES},2);
    NSError *operationError=nil;LBXNativeIsolationJournal *journal=[LBXNativeIsolationJournal openDirectory:directory create:!recovery error:&operationError];
    if(!journal){Diagnose(@"journal-open",NO,operationError);return Output(@{@"status":@"REFUSED",@"journalValidated":@NO,@"diagnostics":Diagnostics},2);}
#if LBX_PRIVATE_GATE_ABORT_RECOVERY
    if(aborting)return AbortUnstarted(journal);
#endif
    operationError=nil;__block NSDictionary *expected=[journal validatedCurrentRecord:&operationError];if(operationError)Diagnose(@"journal-initial-validation",NO,operationError);LBXNativeApplicationGate *gate=nil;
    BOOL effects=NO,trialPassed=NO,restored=NO,drained=NO,closedReadback=NO,unexpected=NO,unexpectedReaped=NO,credentials=NO;NSInteger spawnError=-1;NSUInteger changed=0,executables=0;
    NSDictionary *spawnDiagnostics=@{@"receiptReceived":@NO,@"transportStage":@"not-started",@"credentialStage":@"not-started"};
    NSString *acceptance=recovery?@"UNKNOWN":@"FAIL";
    @try{
        if(recovery){if(!Payload(expected[@"payload"])||[@[@"abort-restoring-original-code",@"aborted-original-code-restored"] containsObject:expected[@"payload"][@"phase"]])@throw [NSException exceptionWithName:@"Refused" reason:nil userInfo:nil];
            operationError=nil;gate=[LBXNativeApplicationGate recoverFromJournal:journal beforeDeadline:Deadline(120) error:&operationError];Diagnose(@"gate-recover",gate!=nil,operationError);effects=gate!=nil;}
        else if(!expected){operationError=nil;gate=[LBXNativeApplicationGate captureOfficialInstagramBeforeDeadline:Deadline(120) error:&operationError];Diagnose(@"gate-capture",gate!=nil,operationError);
            if(gate&&!Publish(journal,&expected,gate,@"prepared",acceptance,spawnError))gate=nil;}
        if(!gate||!Exact(journal,expected,gate))@throw [NSException exceptionWithName:@"Refused" reason:nil userInfo:nil];
        executables=[gate.privateJournalRecord[@"executables"] count];effects=YES;
        drained=CloseAndDrain(gate,@"initial-close-and-drain");
        closedReadback=Modes(gate.privateJournalRecord,YES,&changed);
        if(drained&&closedReadback&&Publish(journal,&expected,gate,@"closed",acceptance,spawnError)&&!recovery){
            if(Publish(journal,&expected,gate,@"spawn-check-pending",acceptance,spawnError)){
                NSString *main=gate.privateJournalRecord[@"binding"][@"mainExecutable"][@"path"];SpawnResult result;SpawnAttempt attempt;
                BOOL received=AttemptKind(main,YES,&result,&attempt);spawnDiagnostics=SpawnDetails(&result,&attempt,received);
                spawnError=result.spawnError;unexpected=result.unexpectedSpawn!=0;unexpectedReaped=result.childReaped!=0;credentials=received&&!result.credentialError;
                trialPassed=received&&credentials&&!unexpected&&spawnError==EACCES&&Modes(gate.privateJournalRecord,YES,NULL);
                acceptance=trialPassed?@"PASS":@"FAIL";
                if(!Publish(journal,&expected,gate,@"spawn-checked",acceptance,spawnError))trialPassed=NO;
            }
        }
        // Even ambiguous/rejected launch checks may restore the original app
        // after a fresh successful drain. No storage or selection changed here.
        drained=CloseAndDrain(gate,@"pre-restore-close-and-drain");
        if(drained&&Exact(journal,expected,gate)&&Modes(gate.privateJournalRecord,YES,NULL)&&
           Publish(journal,&expected,gate,@"restoring",acceptance,spawnError)){
            NSDictionary *permit=expected;
            operationError=nil;BOOL restoredByGate=[gate restoreExecutionBeforeDeadline:Deadline(120) authorization:^BOOL{return Exact(journal,permit,gate);} error:&operationError];Diagnose(@"gate-restore",restoredByGate,operationError);
            restored=restoredByGate&&
                Modes(gate.privateJournalRecord,NO,NULL)&&Exact(journal,permit,gate);
            if(restored&&!Publish(journal,&expected,gate,@"restored",acceptance,spawnError))restored=NO;
        }
    }@catch(__unused NSException *exception){Diagnose(@"probe-operation-refused",NO,nil);trialPassed=NO;}
    if(effects&&!restored){drained=CloseAndDrain(gate,@"emergency-close-and-drain");trialPassed=NO;}
    BOOL pass=restored&&(recovery||trialPassed);NSDictionary *report=@{@"status":pass?@"PASS":@"FAIL",@"acceptance":recovery?@"UNKNOWN":(trialPassed?@"PASS":@"FAIL"),
        @"recoveryMode":@(recovery),@"originalExecutionRestored":@(restored),@"freshDrainObserved":@(drained),@"executableCount":@(executables),
        @"closedModesVerified":@(closedReadback),@"executableModeChangeCount":closedReadback?@(changed):NSNull.null,@"spawnErrno":@(spawnError),@"spawnCredentialDropConfirmed":@(credentials),@"unexpectedSpawn":@(unexpected),@"unexpectedSpawnChildReaped":@(unexpectedReaped),
        @"journalRetained":@YES,@"probeAccountFileContentsRead":@NO,@"storagePermissionsChanged":@NO,@"selectionChanged":@NO,@"runtimeIsolationAccepted":@NO,@"diagnostics":Diagnostics,@"spawnDiagnostics":spawnDiagnostics};
    [journal close];return Output(report,pass?0:3);
}}
