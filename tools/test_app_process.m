#import <Foundation/Foundation.h>
#import <signal.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <libproc.h>
#import <sys/proc.h>
#import <string.h>
#import "RBXAppProcess.h"
#import "RBXOperationContext.h"
#import "RBXBoundedProcess.h"
#import "RBXProcessIdentity.h"

// Exercise the shipped controller and task dispatch without ever signalling
// a real process. Kernel/LS evidence is supplied through its existing PID seam.
static NSMutableArray<NSNumber *> *sKilled;
static NSMutableArray<NSNumber *> *sObserved;
static pid_t sDeniedPID, sChangedPID, sReusedPID;
static int64_t sBirthOffset;
static RBXOperationContext *sOperationContext;
static RBXProcessIdentityResult TestObserve(pid_t pid, RBXObservedProcess *record) {
    [sObserved addObject:@(pid)];
    if (pid == sDeniedPID) return RBXProcessDenied;
    if (pid == sChangedPID) return RBXProcessChanged;
    memset(record, 0, sizeof(*record));
    record->pid = pid; record->startSeconds = 1000 + pid + sBirthOffset;
    strlcpy(record->executable, "/verified/owned/Main", sizeof(record->executable));
    return RBXProcessObserved;
}
static RBXProcessIdentityResult TestTerminate(const RBXObservedProcess *record) {
    NSCAssert(sObserved.count == 3, @"capture all selected identities before any termination");
    if (record->pid == sReusedPID) return RBXProcessChanged;
    [sKilled addObject:@(record->pid)];
    return RBXProcessTerminationRequested;
}
static BOOL SnapshotEnabled;static unsigned SnapshotReads,PathFailures;
static int SnapshotSysctl(int *mib,u_int len,void *old,size_t *size,void *newValue,size_t newSize){
    if(!SnapshotEnabled)return sysctl(mib,len,old,size,newValue,newSize);
    if(!old){*size=sizeof(struct kinfo_proc);return 0;}
    memset(old,0,sizeof(struct kinfo_proc));struct kinfo_proc *p=old;p->kp_proc.p_pid=100;p->kp_proc.p_stat=SRUN;
    *size=sizeof(*p);SnapshotReads++;return 0;
}
static int SnapshotPidpath(int pid,void *path,uint32_t size){
    if(!SnapshotEnabled)return proc_pidpath(pid,path,size);
    if(PathFailures){PathFailures--;errno=EACCES;return 0;}
    strlcpy((char *)path,"/verified/live/Main",size);return (int)strlen((char *)path);
}
static int RBXTestKill(pid_t pid, int signal) {
    if (signal == SIGKILL) { [sKilled addObject:@(pid)]; return 0; }
    if(SnapshotEnabled && pid==100)return 0;
    errno = ESRCH; return -1;
}
#define kill RBXTestKill
#define sysctl SnapshotSysctl
#define proc_pidpath SnapshotPidpath
#define RBXObserveProcess TestObserve
#define RBXTerminateObservedProcess TestTerminate
#import "../daemon/RBXProcessController.m"
#undef kill
#undef sysctl
#undef proc_pidpath
#undef RBXObserveProcess
#undef RBXTerminateObservedProcess

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXOperationContext
+ (RBXOperationContext *)currentContext { return sOperationContext; }
+ (NSString *)daemonBootEpoch { return @"boot"; }
@end
@implementation RBXBoundedProcess @end
#pragma clang diagnostic pop

static NSDictionary *Fixture(NSDictionary *descriptor, NSString *container, BOOL source, BOOL plugin) {
    NSString *identifier = source ? descriptor[@"sourceBundleIdentifier"] : RBXAppBundleIdentifier(descriptor, container);
    NSString *bundle = [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@/App.app", container];
    NSDictionary *info = @{@"CFBundleIdentifier":identifier, @"CFBundleExecutable":@"Main"};
    NSDictionary *marker = source ? @{} : @{@"containerId":container, @"bundleIdentifier":identifier};
    NSString *extension = [bundle stringByAppendingPathComponent:@"PlugIns/Share.appex"];
    NSArray *extensions = @[@{@"bundlePath":extension,
        @"info":@{@"CFBundleIdentifier":[identifier stringByAppendingString:@".Share"], @"CFBundleExecutable":@"Share"}}];
    return @{@"info":info, @"marker":marker, @"bundle":bundle, @"registered":bundle,
        @"path":plugin ? [extension stringByAppendingPathComponent:@"Share"] : [bundle stringByAppendingPathComponent:@"Main"],
        @"extensions":extensions};
}

static BOOL Match(NSDictionary *descriptor, NSDictionary *fixture, NSError **error) {
    return RBXAppProcessRegisteredMatch(descriptor, fixture[@"path"], fixture[@"bundle"], fixture[@"info"],
        fixture[@"marker"], fixture[@"registered"], fixture[@"extensions"], error);
}

static NSArray<NSDictionary *> *sFixtures;
static BOOL sBadSnapshot;
static unsigned sOwnershipReads;
static BOOL sOwnershipLost, sSecondSnapshotDenied;
@interface RBXFixtureProcessController : RBXProcessController @end
@implementation RBXFixtureProcessController
- (NSArray<NSNumber *> *)appPids:(NSError **)error {
    sOwnershipReads++;
    if (sBadSnapshot || (sSecondSnapshotDenied && sOwnershipReads > 1)) {
        RBXAppProcessError(error, @"unprovable kernel snapshot"); return nil;
    }
    if (sOwnershipLost && sOwnershipReads > 1) return @[];
    NSMutableArray *pids = [NSMutableArray array];
    for (NSUInteger index = 0; index < sFixtures.count; index++) {
        NSError *classification = nil;
        if (Match(self.appDescriptor, sFixtures[index], &classification)) [pids addObject:@(100 + index)];
        if (classification) { if (error) *error = classification; return nil; }
    }
    return pids;
}
@end

// Run the actual observer with an apparently valid open lease and an unchanged
// executable/PID. Only the kernel birth observation changes between samples.
@interface RBXBirthObserverController : RBXProcessController
@property(nonatomic) NSUInteger kills, revocations;
@property(nonatomic, copy) NSString *observedPath;
@end
@implementation RBXBirthObserverController
- (NSDictionary *)_terminationProcessPaths:(NSError **)error { return @{@100:self.observedPath ?: @"/verified/owned/Main"}; }
- (NSDictionary *)_terminationNetworkLease {
    NSMutableDictionary *lease=[self.activeCloneIdentity mutableCopy];
    lease[@"state"]=@"open"; lease[@"expiresAt"]=@(NSDate.date.timeIntervalSince1970+60);
    return lease;
}
- (BOOL)_terminationMatchesProcessPath:(NSString *)path error:(NSError **)error { return YES; }
- (BOOL)_revokeTerminationBinding:(NSError **)error { self.revocations++; return YES; }
- (void)killAppProcesses { self.kills++; }
@end

@interface RBXBirthLaunchContext : RBXOperationContext
@property(nonatomic) NSUInteger fences;
@property(nonatomic) BOOL cancelledFixture;
@end
@implementation RBXBirthLaunchContext
- (BOOL)inspectionOnly { return NO; }
- (BOOL)check:(NSError **)error {
    if (self.cancelledFixture && error) *error=[NSError errorWithDomain:@"test" code:1 userInfo:nil];
    return !self.cancelledFixture;
}
- (BOOL)markUnsafeWithReason:(NSString *)reason error:(NSError **)error { self.fences++; return YES; }
@end

static BOOL sCancelAtLaunch;
@interface RBXBirthLaunchController : RBXProcessController
@property(nonatomic, strong) NSMutableArray<NSString *> *bindings;
@end
@implementation RBXBirthLaunchController
- (NSArray *)appPids:(NSError **)error { return @[]; }
- (NSDictionary *)_launchNetworkLease {
    return @{@"state":@"armed", @"containerId":@"fixture",
        @"bundleIdentifier":RBXAppBundleIdentifier(self.appDescriptor,@"fixture"),
        @"bootEpoch":@"boot", @"generation":@"generation"};
}
- (NSString *)_launchExecutableForIdentifier:(NSString *)identifier bundlePath:(NSString *)path error:(NSError **)error {
    return @"/verified/owned/Main";
}
- (BOOL)_writeLaunchBinding:(NSString *)binding error:(NSError **)error { [self.bindings addObject:binding]; return YES; }
+ (pid_t)launchRegisteredBundleIdentifier:(NSString *)identifier expectedBundlePath:(NSString *)path
    timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (sCancelAtLaunch) [(RBXBirthLaunchContext *)sOperationContext setCancelledFixture:YES];
    return 100;
}
@end

static void TestLaunchBirthAdmission(void) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSCAssert([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil], @"private fixture directory");
    NSString *marker=[root stringByAppendingPathComponent:RBXRedditAppDescriptor()[@"cloneMarkerName"]];
    NSCAssert([fm createFileAtPath:marker contents:NSData.data attributes:nil], @"owned clone marker fixture");
    NSDictionary *profile=@{@"containerId":@"fixture", @"app":@{
        @"bundleIdentifier":RBXAppBundleIdentifier(RBXRedditAppDescriptor(),@"fixture"),
        @"bundlePath":root, @"architecture":@"clonedApp-v2", @"cloneState":@"ready"}};
    for (NSUInteger scenario=0; scenario<4; scenario++) {
        RBXBirthLaunchContext *context=[RBXBirthLaunchContext new]; sOperationContext=context;
        RBXBirthLaunchController *controller=[RBXBirthLaunchController new]; controller.bindings=[NSMutableArray array];
        sDeniedPID=scenario==1?100:0; sChangedPID=scenario==2?100:0; sCancelAtLaunch=scenario==3;
        NSError *error=nil; BOOL success=[controller launchCloneForProfile:profile error:&error];
        if (scenario==0) {
            NSCAssert(success && !error && [controller.activeCloneIdentity[@"processStartSeconds"] isEqual:@1100] &&
                [controller.activeCloneIdentity[@"processStartMicroseconds"] isEqual:@0], @"actual launch publishes observed kernel birth");
            NSCAssert(([controller.bindings isEqual:@[@"fixture"]]) && context.fences==0, @"successful birth leaves selected binding");
        } else {
            NSCAssert(!success && error && !controller.activeCloneIdentity && context.fences==1,
                @"denied/changed process or cancelled owner cannot publish launch authority");
            NSCAssert(([controller.bindings isEqual:@[@"fixture",@"__blocked__"]]), @"failed launch birth revokes its provisional binding");
        }
    }
    sOperationContext=nil; sDeniedPID=sChangedPID=0; sCancelAtLaunch=NO;
    NSCAssert([fm removeItemAtPath:root error:nil], @"remove private fixture only");
}

static void Reject(NSDictionary *descriptor, NSDictionary *fixture, BOOL hasError, NSString *message) {
    NSError *error = nil;
    NSCAssert(!Match(descriptor, fixture, &error), @"%@", message);
    NSCAssert((error != nil) == hasError, @"%@ error distinction", message);
}

int main(void) { @autoreleasepool {
    SnapshotEnabled=YES;PathFailures=1;SnapshotReads=0;NSError *snapshotError=nil;
    NSDictionary *snapshot=RBXProcessPaths(&snapshotError);
    NSCAssert([snapshot[@100] isEqual:@"/verified/live/Main"] && !snapshotError && SnapshotReads==2,
        @"transient path race requires a complete fresh kernel snapshot");
    PathFailures=10;SnapshotReads=0;snapshotError=nil;
    NSCAssert(!RBXProcessPaths(&snapshotError) && snapshotError && SnapshotReads==3,
        @"persistently unreadable live process stays fail-closed after bounded retries");
    SnapshotEnabled=NO;

    NSDictionary *reddit = RBXRedditAppDescriptor(), *facebook = RBXAppDescriptorForType(@"facebook");
    for (NSDictionary *descriptor in @[reddit, facebook]) {
        NSError *infrastructureError = nil;
        NSCAssert(!RBXIsAppExecutable(descriptor, @"/var/jb/usr/bin/redditboxd", &infrastructureError) && !infrastructureError,
            @"actual classifier excludes the unbundled daemon before LaunchServices");
        NSDictionary *other = [descriptor isEqual:reddit] ? facebook : reddit;
        for (NSNumber *source in @[@NO, @YES]) for (NSNumber *plugin in @[@NO, @YES]) {
            NSDictionary *fixture = Fixture(descriptor, @"container-a", source.boolValue, plugin.boolValue);
            NSError *error = nil;
            NSCAssert(Match(descriptor, fixture, &error) && !error, @"exact registered source/clone + main/plugin");
            Reject(other, fixture, NO, @"one app family cannot select another");
        }
        NSMutableDictionary *fixture = [Fixture(descriptor, @"a", NO, NO) mutableCopy];
        NSMutableDictionary *marker = [fixture[@"marker"] mutableCopy];
        marker[@"containerId"] = @"b"; fixture[@"marker"] = marker;
        Reject(descriptor, fixture, YES, @"clone ID must equal its marker's generated identity");
        marker[@"containerId"] = @"a"; marker[@"appType"] = other[@"appType"];
        Reject(descriptor, fixture, YES, @"explicit marker app type cannot disagree");
        fixture = [Fixture(descriptor, @"a", NO, NO) mutableCopy];
        NSMutableDictionary *info = [fixture[@"info"] mutableCopy];
        info[@"CFBundleIdentifier"] = [info[@"CFBundleIdentifier"] stringByAppendingString:@".evil"];
        fixture[@"info"] = info;
        Reject(descriptor, fixture, YES, @"a matching prefix does not prove a clone");
        fixture = [Fixture(descriptor, @"a", YES, NO) mutableCopy];
        fixture[@"registered"] = @"/Applications/Other.app";
        Reject(descriptor, fixture, YES, @"source ID copied into an unregistered app path is excluded");
        fixture = [Fixture(descriptor, @"a", NO, NO) mutableCopy];
        fixture[@"path"] = [fixture[@"path"] stringByAppendingString:@"Helper"];
        Reject(descriptor, fixture, YES, @"executable name prefix cannot select helpers");
        fixture[@"path"] = [[fixture[@"bundle"] stringByAppendingString:@".evil"] stringByAppendingPathComponent:@"Main"];
        Reject(descriptor, fixture, YES, @"bundle path prefix cannot select a sibling");
        fixture = [Fixture(descriptor, @"a", YES, NO) mutableCopy];
        info = [fixture[@"info"] mutableCopy]; info[@"CFBundleExecutable"] = @"../Main";
        fixture[@"info"] = info;
        Reject(descriptor, fixture, YES, @"executable traversal cannot establish ownership");
        fixture = [Fixture(descriptor, @"a", YES, YES) mutableCopy];
        NSMutableDictionary *extension = [fixture[@"extensions"][0] mutableCopy];
        extension[@"bundlePath"] = @"/Applications/Outside.appex";
        fixture[@"extensions"] = @[extension]; fixture[@"path"] = @"/Applications/Outside.appex/Share";
        Reject(descriptor, fixture, YES, @"a plugin resolved outside the registered bundle is excluded");
        fixture = [Fixture(descriptor, @"a", YES, YES) mutableCopy];
        extension = [fixture[@"extensions"][0] mutableCopy];
        NSMutableDictionary *extensionInfo = [extension[@"info"] mutableCopy];
        extensionInfo[@"CFBundleExecutable"] = @"../Share"; extension[@"info"] = extensionInfo;
        fixture[@"extensions"] = @[extension];
        Reject(descriptor, fixture, YES, @"plugin executable traversal cannot establish ownership");
        for (NSString *protectedID in @[@"com.redditbox.launcher", @"com.redditbox.daemon", @"com.redditboxd",
            @"com.redditbox.firewall", @"com.redditbox.firewall.PacketTunnel"]) {
            fixture = [Fixture(descriptor, @"a", YES, NO) mutableCopy];
            info = [fixture[@"info"] mutableCopy]; info[@"CFBundleIdentifier"] = protectedID; fixture[@"info"] = info;
            Reject(descriptor, fixture, NO, @"launcher/daemon/firewall never qualify as apps");
        }
        fixture = [Fixture(descriptor, @"a", YES, YES) mutableCopy];
        extension = [fixture[@"extensions"][0] mutableCopy];
        extensionInfo = [extension[@"info"] mutableCopy];
        extensionInfo[@"CFBundleIdentifier"] = @"com.redditbox.firewall.PacketTunnel";
        extension[@"info"] = extensionInfo; fixture[@"extensions"] = @[extension];
        Reject(descriptor, fixture, YES, @"firewall extension is excluded even when embedded");
    }

    RBXFixtureProcessController *legacy = [RBXFixtureProcessController new];
    RBXFixtureProcessController *fb = [[RBXFixtureProcessController alloc] initWithAppDescriptor:facebook];
    NSCAssert([legacy.appDescriptor isEqual:reddit] && [fb.appDescriptor isEqual:facebook], @"default is Reddit; explicit Facebook stays separate");
    NSCAssert(![[RBXFixtureProcessController alloc] initWithAppDescriptor:@{@"appType":@"unknown"}], @"unknown controller cannot enumerate or kill");
    NSMutableDictionary *forged = [reddit mutableCopy]; forged[@"cloneBundlePrefix"] = @"com.";
    NSCAssert(![[RBXFixtureProcessController alloc] initWithAppDescriptor:forged], @"descriptors cannot expand the family");
    NSError *error = nil;
    NSCAssert(![legacy isProfileStopped:@{@"appType":@"facebook"} error:&error] &&
        [error.localizedDescription containsString:@"does not match"], @"Reddit controller rejects a Facebook profile before LS/process I/O");
    error = nil;
    NSCAssert(![fb isProfileStopped:@{} error:&error] && [error.localizedDescription containsString:@"does not match"],
        @"missing profile appType remains Reddit and cannot bind to Facebook");

    sFixtures = @[Fixture(reddit,@"a",YES,NO), Fixture(reddit,@"b",NO,NO), Fixture(reddit,@"b",NO,YES),
        Fixture(facebook,@"c",YES,NO), Fixture(facebook,@"d",NO,NO), Fixture(facebook,@"d",NO,YES)];
    sKilled = [NSMutableArray array]; sObserved = [NSMutableArray array]; [legacy killReddit];
    NSCAssert(([sKilled isEqual:@[@100,@101,@102]]), @"legacy Reddit kill selects exactly source/main/extensions");
    NSCAssert(sObserved.count == 3 && sOwnershipReads == 2, @"identities captured and membership reauthorized before stopping");
    sOwnershipReads=0; sOwnershipLost=YES; [sObserved removeAllObjects]; [sKilled removeAllObjects];
    [legacy killAppProcesses];
    NSCAssert(sKilled.count == 0, @"lost ownership does not stop a stale PID");
    sOwnershipReads=0; sOwnershipLost=NO; sSecondSnapshotDenied=YES; [sObserved removeAllObjects];
    [legacy killAppProcesses];
    NSCAssert(sKilled.count == 0, @"failed reauthorization does not stop any captured PID");
    sSecondSnapshotDenied=NO; sDeniedPID=101; [sObserved removeAllObjects];
    [legacy killAppProcesses];
    NSCAssert(sKilled.count == 0, @"unreadable identity aborts before any termination");
    sDeniedPID=0; sChangedPID=101; [sObserved removeAllObjects];
    [legacy killAppProcesses];
    NSCAssert(([sKilled isEqual:@[@100,@102]]), @"changed birth while capturing is not targeted");
    sChangedPID=0; sReusedPID=101; [sObserved removeAllObjects]; [sKilled removeAllObjects];
    [legacy killAppProcesses];
    NSCAssert(([sKilled isEqual:@[@100,@102]]), @"late PID reuse cannot fall back to numeric kill");
    sReusedPID=0; [sObserved removeAllObjects];
    [sKilled removeAllObjects]; [fb killAppProcesses];
    NSCAssert(([sKilled isEqual:@[@103,@104,@105]]), @"Facebook kill selects only its independent family");
    [sObserved removeAllObjects]; [sKilled removeAllObjects]; [RBXFixtureProcessController killAllRedditProcesses];
    NSCAssert(([sKilled isEqual:@[@100,@101,@102]]), @"revoke-to-kill compatibility remains Reddit scoped");
    [sObserved removeAllObjects]; [sKilled removeAllObjects]; [RBXFixtureProcessController killAllProcessesForAppDescriptor:facebook];
    NSCAssert(([sKilled isEqual:@[@103,@104,@105]]), @"descriptor class entry point dispatches separately");
    sBadSnapshot = YES; [sKilled removeAllObjects]; [legacy killAppProcesses];
    NSCAssert(sKilled.count == 0 && ![legacy verifyNoAppSocketsForInterval:0.01 error:&error], @"unprovable snapshot neither kills guessed PIDs nor proves clean sockets");
    sBadSnapshot = NO; sFixtures = @[];
    NSCAssert([legacy verifyNoRedditSocketsForInterval:0.01 error:nil], @"legacy socket verifier uses same scoped PID seam");
    RBXBirthObserverController *observer=[RBXBirthObserverController new];
    NSDictionary *identity=@{@"containerId":@"test", @"bundleIdentifier":@"com.redditbox.profile.test",
        @"executable":@"/verified/owned/Main", @"pid":@100, @"generation":@"generation", @"bootEpoch":@"boot",
        @"processStartSeconds":@1100, @"processStartMicroseconds":@0};
    [observer _setActiveCloneIdentity:identity]; [observer setValue:@"test-token" forKey:@"watchToken"];
    __block NSUInteger exits=0;
    void (^onExit)(NSDictionary *,NSString *)=^(NSDictionary *snapshot,NSString *reason){
        NSCAssert([snapshot isEqual:identity] && reason.length && observer.revocations==exits,
            @"notify original authority before revoking binding"); exits++;
    };
    [observer _sampleAppTerminationWithToken:@"test-token" onExit:onExit];
    NSCAssert(exits==0 && observer.kills==0, @"same birth retains its current authority");
    observer.observedPath=@"/verified/owned/./Main";
    [observer _sampleAppTerminationWithToken:@"test-token" onExit:onExit];
    NSCAssert(exits==0, @"equivalent canonical executable paths retain the same authority");
    observer.observedPath=nil;
    sBirthOffset=1;
    [observer _sampleAppTerminationWithToken:@"test-token" onExit:onExit];
    NSCAssert(exits==1 && observer.kills==1 && observer.revocations==1,
        @"same PID and executable with a new birth cannot inherit an old open lease");
    sBirthOffset=0; sDeniedPID=100;
    [observer _sampleAppTerminationWithToken:@"test-token" onExit:onExit];
    NSCAssert(exits==2 && observer.kills==2, @"unreadable birth cannot keep network authority");
    sDeniedPID=0;
    NSMutableDictionary *withoutBirth=[identity mutableCopy]; [withoutBirth removeObjectForKey:@"processStartSeconds"];
    [observer _setActiveCloneIdentity:withoutBirth];
    [observer _sampleAppTerminationWithToken:@"test-token" onExit:^(NSDictionary *snapshot,NSString *reason){ exits++; }];
    NSCAssert(exits==3 && observer.kills==3, @"legacy or incomplete identity is not runtime authority");
    TestLaunchBirthAdmission();
    puts("PASS: exact registered app classification, Reddit/FB separation, exclusions, identity capture, reauthorization and task dispatch; no real processes signalled");
} return 0; }
