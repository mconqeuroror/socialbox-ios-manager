#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "../lucid/Switching/LBXDarwinDrainBackend.h"
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/proc.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static unsigned Checks, Failures, Reads, Closes, Sizes, Tables, Interrupts, TableInterrupts, Grows, Stops;
static int TableMode, NodeMode, ReadMode, PluginMode, ExtensionBinaryMode;
static unsigned Observations, RetrySleeps, SleepInterrupts, TransientIdentityFailures;
static BOOL TwoLiveRows, RetrySleepDenied;
static BOOL DenyExecuteAccess;
static BOOL ChangedParentTimes;
static BOOL FoundationVarAlias;
static IMP OriginalResolvePath;
static RBXProcessIdentityResult ProcessStatus;
static NSString *Installed, *Canonical;
static NSData *InfoData, *ExtensionInfo, *ReadData;
static void Check(BOOL yes, const char *message) { Checks++; if (!yes) { Failures++; fprintf(stderr,"FAIL %s\n",message); } }
static NSString *FakeResolvePath(id self, SEL selector) {
    NSString *resolved=((NSString *(*)(id,SEL))OriginalResolvePath)(self,selector);
    return FoundationVarAlias && [resolved hasPrefix:@"/private/var/"] ? [resolved substringFromIndex:8] : resolved;
}
@interface LSFixture : NSObject
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
- (NSURL *)bundleURL;
- (NSString *)canonicalExecutablePath;
@end
@implementation LSFixture
+ (id)applicationProxyForIdentifier:(NSString *)identifier { (void)identifier; return [self new]; }
- (NSURL *)bundleURL { return [NSURL fileURLWithPath:Installed]; }
- (NSString *)canonicalExecutablePath { return Canonical; }
@end
@interface FilesFixture : NSObject
+ (id)defaultManager;
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error;
@end
@implementation FilesFixture
+ (id)defaultManager { return [self new]; }
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    (void)error; Check([path hasSuffix:@"/PlugIns"],"enumerate only registered embedded extensions");
    return PluginMode==3 ? nil : PluginMode==4 ? @[@"unexpected.bin"] : @[@"Share.appex"];
}
@end
static Class FakeClass(NSString *name) { return [name isEqual:@"LSApplicationProxy"] ? LSFixture.class : Nil; }
static void Reset(void) {
    Reads=Closes=Sizes=Tables=Interrupts=TableInterrupts=Grows=Stops=0;
    Observations=RetrySleeps=SleepInterrupts=TransientIdentityFailures=0;TwoLiveRows=RetrySleepDenied=NO;
    TableMode=NodeMode=ReadMode=PluginMode=ExtensionBinaryMode=0; ChangedParentTimes=FoundationVarAlias=DenyExecuteAccess=NO; ProcessStatus=RBXProcessObserved;
    Installed=@"/private/var/containers/Bundle/Application/11111111-1111-4111-8111-111111111111/Facebook.app";
    Canonical=[Installed stringByAppendingPathComponent:@"Facebook"];
    InfoData=[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"com.facebook.Facebook",@"CFBundleExecutable":@"Facebook"}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    ExtensionInfo=[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"com.facebook.Facebook.Share",@"CFBundleExecutable":@"Share",@"NSExtension":@{}}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];ReadData=InfoData;
}
static void FillStat(struct stat *p, BOOL directory) {
    memset(p,0,sizeof(*p)); p->st_uid=0; p->st_mode=(directory?S_IFDIR:S_IFREG)|0755;
    p->st_ino=123; p->st_dev=1; p->st_size=ReadData.length; p->st_mtimespec.tv_sec=1; p->st_ctimespec.tv_sec=1;
    if(directory&&ChangedParentTimes){p->st_mtimespec.tv_sec=2;p->st_ctimespec.tv_sec=3;p->st_size=500;}
    if(NodeMode==1)p->st_uid=501;
    if(NodeMode==2)p->st_mode|=0020;
    if(NodeMode==3)p->st_mode=(p->st_mode&0777)|S_IFLNK;
}
static int FakeLstat(const char *path, struct stat *p) {
    NSString *value=@(path);
    if([value hasSuffix:@"/PlugIns"]&&PluginMode<2){errno=PluginMode?EACCES:ENOENT;return -1;}
    ReadData=[value containsString:@"/PlugIns/"]?ExtensionInfo:InfoData;
    FillStat(p,!([value hasSuffix:@"/Info.plist"]||[value hasSuffix:@"/Facebook"]||[value hasSuffix:@"/Instagram"]||[value hasSuffix:@"/Share"]));
    if([value hasSuffix:@"/Share"]){
        if(ExtensionBinaryMode==1)p->st_mode=S_IFREG|0644;
        if(ExtensionBinaryMode==2){errno=ENOENT;return -1;}
        if(ExtensionBinaryMode==3)p->st_uid=501;
        if(ExtensionBinaryMode==4)p->st_mode|=0020;
        if(ExtensionBinaryMode==5)p->st_mode=S_IFLNK|0755;
    }
    return 0;
}
static int FakeOpen(const char *path, int flags, ...) {
    Check([@(path) hasSuffix:@"/Info.plist"] && (flags&O_NOFOLLOW) && (flags&O_CLOEXEC),"metadata only opened read-only without symlinks");
    ReadData=[@(path) containsString:@"/PlugIns/"]?ExtensionInfo:InfoData;
    if(ReadMode==1){errno=EACCES;return -1;} return 900;
}
static int FakeFstat(int fd, struct stat *p) { Check(fd==900,"fstat owns exact metadata descriptor"); FillStat(p,NO);
    if(ReadMode==2)p->st_size=0;if(ReadMode==3)p->st_size=2*1024*1024;
    if(ReadMode==4&&Reads)p->st_mtimespec.tv_nsec=1;
    return 0;
}
static ssize_t FakeRead(int fd, void *out, size_t count) { Check(fd==900,"read only owned metadata descriptor"); Reads++;
    if(ReadMode==5&&Reads<3){errno=EINTR;return -1;}
    if(ReadMode==6){errno=EINTR;return -1;}
    if(ReadMode==7)return 0;
    memcpy(out,ReadData.bytes,MIN(count,ReadData.length)); return MIN(count,ReadData.length);
}
static int FakeClose(int fd) { Check(fd==900,"close only owned metadata descriptor"); Closes++;return 0; }
static int FakeAccess(const char *path,int mode) {
    Check(mode==X_OK,"executable access check only");
    if(DenyExecuteAccess || (ExtensionBinaryMode==1 && [@(path) hasSuffix:@"/Share"])){errno=EACCES;return -1;}
    return 0;
}
static int FakeSysctl(int *mib,u_int count,void *out,size_t *bytes,void *input,size_t inputLength) {
    Check(count==4&&mib[0]==CTL_KERN&&mib[1]==KERN_PROC&&mib[2]==KERN_PROC_ALL&&input==NULL&&inputLength==0,"read-only full process table query");
    if(!out){Sizes++;if(Interrupts){Interrupts--;errno=EINTR;return -1;}
        if(TableMode==1){errno=EPERM;return -1;}*bytes=TableMode==2?0:TableMode==3?64*1024*1024:(TwoLiveRows?6:5)*sizeof(struct kinfo_proc);return 0;}
    Tables++;if(TableInterrupts){TableInterrupts--;errno=EINTR;return -1;}
    if(Grows){Grows--;errno=ENOMEM;return -1;}
    if(TableMode==4){errno=EACCES;return -1;}
    struct kinfo_proc *rows=out;size_t rowCount=TwoLiveRows?6:5;memset(rows,0,rowCount*sizeof(*rows));
    rows[0].kp_proc.p_pid=0;rows[1].kp_proc.p_pid=1;rows[2].kp_proc.p_pid=getpid();
    rows[3].kp_proc.p_pid=30000;rows[3].kp_proc.p_stat=SZOMB;
    rows[4].kp_proc.p_pid=30001;rows[4].kp_proc.p_stat=SRUN;
    if(TwoLiveRows){rows[5].kp_proc.p_pid=30002;rows[5].kp_proc.p_stat=SRUN;}
    *bytes=rowCount*sizeof(*rows)+(TableMode==5?1:0);return 0;
}
static RBXProcessIdentityResult FakeObserve(pid_t pid,RBXObservedProcess *result) {
    Observations++;Check(pid==30001||(TwoLiveRows&&pid==30002),"kernel/self/zombie rows excluded before observation");memset(result,0,sizeof(*result));
    result->pid=pid;result->startSeconds=42+(TwoLiveRows?Tables:0);
    NSString *path=TwoLiveRows?[Canonical stringByAppendingFormat:@"-table-%u",Tables]:Canonical;
    strlcpy(result->executable,path.UTF8String,sizeof(result->executable));
    if(TwoLiveRows&&pid==30001)return RBXProcessObserved;
    if(TransientIdentityFailures&&Tables>TransientIdentityFailures)return RBXProcessObserved;
    return ProcessStatus;
}
static int FakeNanosleep(const struct timespec *duration,struct timespec *remaining) {
    RetrySleeps++;Check(duration->tv_sec==0&&duration->tv_nsec>0&&duration->tv_nsec<=20000000,"snapshot retries pause at most20ms per uninterrupted wait");
    if(RetrySleepDenied){errno=EACCES;return -1;}
    if(SleepInterrupts){SleepInterrupts--;*remaining=*duration;errno=EINTR;return -1;}
    return 0;
}
static RBXProcessIdentityResult FakeTerminate(const RBXObservedProcess *p) {
    Stops++;Check(p->pid==30001&&p->startSeconds==42,"exact captured identity forwarded to shared task-right primitive");return RBXProcessTerminationRequested;
}
#define NSClassFromString FakeClass
#define NSFileManager FilesFixture
#define lstat FakeLstat
#define open FakeOpen
#define fstat FakeFstat
#define read FakeRead
#define close FakeClose
#define access FakeAccess
#define sysctl FakeSysctl
#define nanosleep FakeNanosleep
#define RBXObserveProcess FakeObserve
#define RBXTerminateObservedProcess FakeTerminate
#import "../lucid/Switching/LBXDarwinDrainBackend.m"
#undef NSClassFromString
#undef NSFileManager
#undef lstat
#undef open
#undef fstat
#undef read
#undef close
#undef access
#undef sysctl
#undef nanosleep
#undef RBXObserveProcess
#undef RBXTerminateObservedProcess

int main(void) { @autoreleasepool {
    Method resolver=class_getInstanceMethod(NSString.class,@selector(stringByResolvingSymlinksInPath));
    OriginalResolvePath=method_setImplementation(resolver,(IMP)FakeResolvePath);
    LBXDarwinDrainBackend *backend=[LBXDarwinDrainBackend new];NSError *error=nil;Reset();
    LBXDrainTarget *target=[backend resolve:@"com.facebook.Facebook" error:&error];
    Check(target&&target.executables.count==1&&[target.executables[0] isEqual:Canonical]&&target.fingerprint.length==64&&Closes==1,"actual resolver produces exact registered target and closes metadata descriptor");
    NSString *first=target.fingerprint;ChangedParentTimes=YES;
    target=[backend resolve:@"com.facebook.Facebook" error:&error];Check([target.fingerprint isEqual:first],"unrelated parent directory timestamp changes do not revoke unchanged app registration");
    Reset();FoundationVarAlias=YES;
    Check([Installed.stringByResolvingSymlinksInPath hasPrefix:@"/var/"],"fixture reproduces iOS Foundation shortening the private var alias");
    target=[backend resolve:@"com.facebook.Facebook" error:&error];
    Check(target&&[target.bundlePath isEqual:Installed]&&[target.executables[0] isEqual:Canonical]&&[target.fingerprint isEqual:first],"Foundation var alias resolves to the same pinned installation authority");
    Installed=[Installed substringFromIndex:8];Canonical=[Canonical substringFromIndex:8];
    target=[backend resolve:@"com.facebook.Facebook" error:&error];
    Check(target&&[target.bundlePath hasPrefix:@"/private/var/"]&&[target.fingerprint isEqual:first],"LaunchServices var aliases also preserve exact registration fingerprint");
    for(int mode=1;mode<=3;mode++){Reset();FoundationVarAlias=YES;NodeMode=mode;
        Check(![backend resolve:@"com.facebook.Facebook" error:&error]&&!Closes,"alias normalization does not admit writable user-owned or symlink authority");}
    for(NSString *path in @[@"/varx/containers/Bundle/Application/11111111-1111-4111-8111-111111111111/Facebook.app",@"/private/var/containers/Bundle/Application.evil/11111111-1111-4111-8111-111111111111/Facebook.app",@"/var/mobile/11111111-1111-4111-8111-111111111111/Facebook.app"]){
        Reset();FoundationVarAlias=YES;Installed=path;Canonical=[path stringByAppendingPathComponent:@"Facebook"];
        Check(![backend resolve:@"com.facebook.Facebook" error:&error]&&!Closes,"lookalike roots remain rejected before metadata reads");}
    Reset();FoundationVarAlias=YES;
    Installed=@"/private/var/containers/Bundle/Application/11111111-1111-4111-8111-111111111111/Instagram.app";
    Canonical=[Installed stringByAppendingPathComponent:@"Instagram"];
    InfoData=[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"com.burbn.instagram",@"CFBundleExecutable":@"Instagram"}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    target=[backend resolve:@"com.burbn.instagram" error:&error];
    Check(target&&[target.bundlePath isEqual:Installed]&&[target.executables[0] isEqual:Canonical],"registered Instagram retains exact executable authority under Foundation alias normalization");
    Reset();
    InfoData=[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"com.facebook.Facebook",@"CFBundleExecutable":@"Facebook",@"CFBundleVersion":@"2"}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    target=[backend resolve:@"com.facebook.Facebook" error:&error];Check(target&&![target.fingerprint isEqual:first],"metadata change changes registration fingerprint");
    for(int mode=1;mode<=3;mode++){Reset();NodeMode=mode;Check(![backend resolve:@"com.facebook.Facebook" error:&error]&&!Closes,"writable/user-owned/symlink path rejected before open");}
    for(int mode=1;mode<=7;mode++){Reset();ReadMode=mode;target=[backend resolve:@"com.facebook.Facebook" error:&error];
        Check((target!=nil)==(mode==5),"bounded metadata reader rejects denied/empty/huge/changing/short/EINTR-exhausted input");
        Check(Closes==(mode==1?0:1),"every opened metadata descriptor is closed on failure or success");}
    Reset();PluginMode=1;Check(![backend resolve:@"com.facebook.Facebook" error:&error],"extension enumeration denial is not no extensions");
    Reset();PluginMode=2;target=[backend resolve:@"com.facebook.Facebook" error:&error];
    Check(target.executables.count==2&&[target.executables[1] isEqual:[Installed stringByAppendingPathComponent:@"PlugIns/Share.appex/Share"]]&&Closes==2,"registered embedded extension bound to exact executable and metadata");
    Reset();PluginMode=2;ExtensionBinaryMode=1;target=[backend resolve:@"com.facebook.Facebook" error:&error];
    Check(target.executables.count==2&&[target.executables[1] hasSuffix:@"/Share.appex/Share"],"non-executable read-only optional extension is still inventoried by exact metadata path");
    for(int mode=2;mode<=5;mode++){Reset();PluginMode=2;ExtensionBinaryMode=mode;
        Check(![backend resolve:@"com.facebook.Facebook" error:&error],"missing user-owned writable or symlink extension binary still rejects full target");}
    Reset();DenyExecuteAccess=YES;Check(![backend resolve:@"com.facebook.Facebook" error:&error],"main app still requires executable access");
    for(int mode=3;mode<=4;mode++){Reset();PluginMode=mode;Check(![backend resolve:@"com.facebook.Facebook" error:&error],"failed/unknown plugin listing blocks entire target resolution");}
    Reset();PluginMode=2;ExtensionInfo=[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"com.other.Share",@"CFBundleExecutable":@"Share",@"NSExtension":@{}}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];Check(![backend resolve:@"com.facebook.Facebook" error:&error],"foreign extension identifier cannot obtain stop authority");
    Reset();Canonical=@"/unrelated/Facebook";Check(![backend resolve:@"com.facebook.Facebook" error:&error],"LaunchServices canonical executable mismatch rejected");
    for(NSString *path in @[@"/Applications/Facebook.app",@"/private/var/containers/Bundle/Application/notuuid/Facebook.app",@"/private/var/mobile/Facebook.app"]){Reset();Installed=path;Check(![backend resolve:@"com.facebook.Facebook" error:&error],"unknown install layout rejected without search fallback");}
    for(NSString *name in @[@"../Facebook",@"/Facebook",@".",@"..",@"A\\B",@"",@"A\0B"]){Reset();
        InfoData=[NSPropertyListSerialization dataWithPropertyList:@{@"CFBundleIdentifier":@"com.facebook.Facebook",@"CFBundleExecutable":name}format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        Check(![backend resolve:@"com.facebook.Facebook" error:&error],"unsafe executable name rejected");}
    Reset();NSArray *snapshot=[backend snapshot:&error];Check(snapshot.count==1&&Sizes==1&&Tables==1,"complete kernel snapshot filters only system/self/zombie rows");
    Check([backend terminate:((LBXDrainProcess *)snapshot[0]).identity]==RBXProcessTerminationRequested&&Stops==1,"actual adapter calls shared task-right termination");
    for(int mode=1;mode<=5;mode++){Reset();TableMode=mode;Check(![backend snapshot:&error],"denied/empty/huge/malformed kernel table never means absence");}
    Reset();Interrupts=1;Check([backend snapshot:&error].count==1&&Sizes==2,"table sizing EINTR retried");
    Reset();TableInterrupts=1;Check([backend snapshot:&error].count==1&&Sizes==2&&Tables==2,"table read EINTR retried with fresh allocation");
    Reset();Grows=1;Check([backend snapshot:&error].count==1&&Tables==2,"growing process table retried completely");
    Reset();Grows=8;Check(![backend snapshot:&error]&&Tables==4,"unstable kernel table bounded");
    Reset();Interrupts=8;Check(![backend snapshot:&error]&&Sizes==4,"persistent sizing EINTR bounded");
    Reset();ProcessStatus=RBXProcessGone;Check([backend snapshot:&error].count==0,"independently observed exit may be omitted");
    for(NSNumber *status in @[@(RBXProcessDenied),@(RBXProcessChanged)]){
        Reset();ProcessStatus=status.intValue;
        Check(![backend snapshot:&error]&&Sizes==3&&Tables==3&&Observations==3&&RetrySleeps==2&&!Stops,
            "persistent live unreadable/reused PID fails after3 full snapshots without omission or termination");
        for(unsigned failures=1;failures<=2;failures++){
            Reset();TwoLiveRows=YES;TransientIdentityFailures=failures;ProcessStatus=status.intValue;
            error=nil;snapshot=[backend snapshot:&error];
            Check(snapshot.count==2&&Sizes==failures+1&&Tables==failures+1&&Observations==2*(failures+1)&&RetrySleeps==failures&&!error&&!Stops,
                "transient late-row uncertainty retries complete tables and rescans every preceding row");
            for(LBXDrainProcess *row in snapshot)Check(row.identity.startSeconds==42+Tables&&
                [@(row.identity.executable) hasSuffix:[NSString stringWithFormat:@"-table-%u",Tables]],
                "successful retry contains only fresh-table birth/path identities with no partial-result carryover");
        }
    }
    Reset();ProcessStatus=RBXProcessDenied;RetrySleepDenied=YES;
    Check(![backend snapshot:&error]&&Tables==1&&RetrySleeps==1,"failed retry pause refuses snapshot immediately");
    Reset();ProcessStatus=RBXProcessChanged;TransientIdentityFailures=1;SleepInterrupts=2;
    Check([backend snapshot:&error].count==1&&Tables==2&&RetrySleeps==3,"bounded interrupted retry pause permits a genuinely complete next table");
    Reset();ProcessStatus=RBXProcessChanged;SleepInterrupts=8;
    Check(![backend snapshot:&error]&&Tables==1&&RetrySleeps==4,"persistent pause interruptions stop before any second table");
    for(int mode=1;mode<=5;mode++){Reset();TableMode=mode;
        Check(![backend snapshot:&error]&&Sizes==1&&RetrySleeps==0,"invalid or denied kernel query never gains identity retry allowance");}
    printf("%s Darwin drain adapter: %u assertions, %u failures; filesystem/kernel boundaries mocked\n",Failures?"FAIL":"PASS",Checks,Failures);
    return Failures?1:0;
}}
