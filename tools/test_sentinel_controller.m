#import <Foundation/Foundation.h>
#import "RBXSentinelController.h"
#import "RBXSentinelIO.h"
#import "RBXCloneManager.h"
#import "RBXProfileIO.h"
#import "RBXCentralStore.h"
#import "RBXHookReadiness.h"
#import "RBXCloneEpoch.h"
#import "RBXProcessIdentity.h"
#import "RBXLaunchSafety.h"
#import "RBXOperationContext.h"

// Execute the actual daemon observer. All clone/control/kernel/store boundaries
// are inert fixtures; no real process, app data, Keychain or network is touched.
static NSDictionary *Control, *Ready, *Report, *ActiveIdentity;
static NSMutableDictionary *Store;
static NSString *Home, *Executable;
static RBXObservedProcess Observed;
static RBXProcessIdentityResult ObservationResult;
static NSUInteger Checks, Observations, ProviderReads;
static BOOL InvalidateDuringObservation, FailStoreWrite;
static BOOL DropStoreWrite, ThrowStoreWrite, DeleteDuringStoreWrite, FailReadBack, FailUnsafeRename;
static NSString *JournalDirectory;
static NSUInteger ReportReads, UnjournaledReportReads;

static NSArray<NSString *> *ActiveJournals(void) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:JournalDirectory error:nil])
        if ([name hasPrefix:@"active-"] && [name hasSuffix:@".plist"]) [files addObject:name];
    return files;
}
static int TestContextRename(int oldDirectory, const char *oldName, int newDirectory, const char *newName) {
    if (FailUnsafeRename && strcmp(newName,"unsafe.plist")==0) { errno=ENOSPC; return -1; }
    return renameat(oldDirectory,oldName,newDirectory,newName);
}
#define renameat TestContextRename
#import "../daemon/RBXOperationContext.m"
#undef renameat

@interface RBXSentinelController (FixtureProviderDeclaration)
+ (void)setProcessIdentityProvider:(NSDictionary *(^)(void))provider;
@end

static int TestPrefs(NSString *home) { (void)home; return open("/dev/null", O_RDONLY); }
static NSDictionary *TestRead(int fd, NSString *name, uid_t owner) {
    (void)fd; (void)owner;
    if ([name isEqual:RBXSentinelControlName]) return Control;
    if ([name isEqual:RBXSentinelReportName]) {
        ReportReads++;
        if (!ActiveJournals().count) UnjournaledReportReads++;
        return Report;
    }
    if ([name isEqual:@"com.redditbox.hook-ready.plist"]) return Ready;
    return nil;
}
static BOOL TestWrite(int fd, NSString *name, NSDictionary *object, uid_t owner) {
    (void)fd; (void)owner;
    if ([name isEqual:RBXSentinelControlName]) Control = object;
    return YES;
}
static RBXProcessIdentityResult TestObserve(pid_t pid, RBXObservedProcess *result) {
    Observations++;
    if (InvalidateDuringObservation) ActiveIdentity = nil;
    if (pid != Observed.pid) return RBXProcessDenied;
    *result = Observed;
    return ObservationResult;
}
#define RBXSentinelPrefs TestPrefs
#define RBXSentinelRead TestRead
#define RBXSentinelWrite TestWrite
#define RBXObserveProcess TestObserve
#import "../daemon/RBXSentinelController.m"
#undef RBXSentinelPrefs
#undef RBXSentinelRead
#undef RBXSentinelWrite
#undef RBXObserveProcess

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXCloneManager
- (NSString *)dataContainerForBundleIdentifier:(NSString *)bundle { (void)bundle; return Home; }
@end
@implementation RBXProfileIO
+ (NSDictionary *)loadProfileForContainer:(NSString *)container error:(NSError **)error {
    (void)container; (void)error; return nil;
}
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore { static id value; if (!value) value = [self new]; return value; }
- (NSMutableDictionary *)dictionary { return FailReadBack ? nil : Store; }
- (BOOL)hasAlertType:(NSString *)type containerId:(NSString *)container {
    for (NSDictionary *row in Store[@"alerts"])
        if ([row[@"type"] isEqual:type] && [row[@"containerId"] isEqual:container]) return YES;
    return NO;
}
- (void)addAlertType:(NSString *)type containerId:(NSString *)container message:(NSString *)message {
    if (!FailStoreWrite) [Store[@"alerts"] addObject:@{@"type":type,@"containerId":container,@"message":message}];
}
- (void)update:(void (^)(NSMutableDictionary *))block { if (!FailStoreWrite) block(Store); }
- (BOOL)update:(void (^)(NSMutableDictionary *))block error:(NSError **)error {
    if (ThrowStoreWrite) @throw [NSException exceptionWithName:@"FixtureInterruption" reason:@"write interrupted" userInfo:nil];
    if (DropStoreWrite) return YES;
    if (FailStoreWrite) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOSPC userInfo:nil];
        return NO;
    }
    if (DeleteDuringStoreWrite) [Store[@"containers"] removeObjectForKey:@"one"];
    block(Store); return YES;
}
@end
#pragma clang diagnostic pop

static void Check(BOOL ok, NSString *message) {
    Checks++;
    if (!ok) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}
static NSDictionary *Replacing(NSDictionary *input, NSString *key, id value) {
    NSMutableDictionary *copy = input.mutableCopy;
    if (value) copy[key] = value; else [copy removeObjectForKey:key];
    return copy;
}
static NSDictionary *Summary(NSDictionary *profile, NSDictionary *lease) {
    return [RBXSentinelController summaryForProfile:profile siblings:@[@"one",@"two"] store:Store lease:lease];
}
int main(void) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int result = 0;
    @try {
        Check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil],@"fixture root");
        root = root.stringByResolvingSymlinksInPath;
        JournalDirectory = [root stringByAppendingPathComponent:@"operations"];
        [RBXOperationContext setSafetyFenceDirectoryForTesting:JournalDirectory];
        NSString *bundle = @"com.redditbox.profile.p1111111111111111";
        NSString *uuid = NSUUID.UUID.UUIDString;
        Home = [root stringByAppendingPathComponent:uuid];
        Executable = [root stringByAppendingPathComponent:@"Main"];
        Check([[NSData data] writeToFile:Executable atomically:NO],@"inert executable path exists for canonicalization");
        Check([@{@"CFBundleExecutable":@"Main"} writeToFile:[root stringByAppendingPathComponent:@"Info.plist"] atomically:YES],@"fixture app info");
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSDictionary *settings = @{@"enabled":@YES,@"intervalMinutes":@15,@"clipboardChallenge":@NO};
        NSDictionary *profile = @{@"containerId":@"one",@"app":@{@"bundleIdentifier":bundle,@"bundlePath":root}};
        NSDictionary *lease = @{@"state":@"open",@"containerId":@"one",@"bundleIdentifier":bundle,@"generation":@"generation",@"bootEpoch":@"boot",@"openedAt":@(now-3)};
        Store = [@{@"containers":[@{@"one":[@{@"isolationSentinel":settings} mutableCopy]} mutableCopy],@"alerts":[NSMutableArray array]} mutableCopy];
        Control = @{@"schemaVersion":@1,@"bundleIdentifier":bundle,@"dataUUID":uuid,@"revision":NSUUID.UUID.UUIDString,
            @"settings":settings,@"issuedAt":@(now),@"targets":@[]};
        NSMutableDictionary *groups = [NSMutableDictionary dictionary], *checks = [NSMutableDictionary dictionary];
        for (NSString *key in RBXRequiredHookGroups()) groups[key] = @YES;
        for (NSString *key in RBXRequiredBehaviorChecks()) checks[key] = @YES;
        Ready = @{@"allHooksInstalled":@YES,@"timestamp":@(now-4),@"containerId":@"one",@"bundleIdentifier":bundle,
            @"generation":@"generation",@"bootEpoch":RBXEpochForClone(@"boot",bundle),@"pid":@42,
            @"installedGroups":groups,@"behaviorChecks":checks};
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *probe in @[@"keychain-default",@"keychain-group",@"filesystem",@"defaults"])
            [rows addObject:RBXSentinelRow(probe,@"none",@"NOT_RUN",@"fixture",0)];
        [rows addObject:RBXSentinelRow(@"pasteboard",@"system",@"NOT_RUN",@"fixture",0)];
        NSMutableDictionary *report = Ready.mutableCopy;
        [report addEntriesFromDictionary:@{@"schemaVersion":@1,@"revision":Control[@"revision"],@"timestamp":@(now-2),@"rows":rows}];
        Report = report;
        Observed.pid = 42; Observed.startSeconds = (int64_t)now-10; Observed.startMicroseconds = 123;
        strlcpy(Observed.executable, Executable.UTF8String, sizeof(Observed.executable));
        ObservationResult = RBXProcessObserved;
        NSDictionary *identity = @{@"containerId":@"one",@"bundleIdentifier":bundle,@"executable":Executable,
            @"generation":@"generation",@"bootEpoch":@"boot",@"pid":@42,
            @"processStartSeconds":@(Observed.startSeconds),@"processStartMicroseconds":@123};
        ActiveIdentity = identity;
        if ([RBXSentinelController respondsToSelector:@selector(setProcessIdentityProvider:)])
            [RBXSentinelController setProcessIdentityProvider:^NSDictionary * { ProviderReads++; return ActiveIdentity; }];
        Check([Summary(profile,lease)[@"current"] isEqual:@YES],@"actual controller accepts current bounded report");
        Observed.startMicroseconds++;
        Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"same PID/path with a different kernel birth rejects the previous run's report");
        Observed.startMicroseconds--;
        ActiveIdentity = nil;
        Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"no daemon-owned active launch means no current report");
        ActiveIdentity = identity;
        for (NSString *key in @[@"containerId",@"bundleIdentifier",@"executable",@"generation",@"bootEpoch",@"pid",@"processStartSeconds",@"processStartMicroseconds"]) {
            ActiveIdentity = Replacing(identity,key,nil);
            Check([Summary(profile,lease)[@"current"] isEqual:@NO],[key stringByAppendingString:@" is required from daemon authority"]);
        }
        ActiveIdentity = identity;
        for (NSString *key in @[@"pid",@"processStartSeconds",@"processStartMicroseconds"]) {
            for (id value in @[@YES,@(-1),@2.5,@(NAN),@"42",NSNull.null,@(1e40)]) {
                ActiveIdentity = Replacing(identity,key,value);
                Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"malformed numeric authority is not coerced into a valid identity");
            }
        }
        for (NSString *key in @[@"containerId",@"bundleIdentifier",@"executable",@"generation",@"bootEpoch"]) {
            ActiveIdentity = Replacing(identity,key,@"different");
            Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"foreign launch authority is rejected");
        }
        ActiveIdentity = identity;
        for (NSNumber *state in @[@(RBXProcessGone),@(RBXProcessChanged),@(RBXProcessDenied)]) {
            ObservationResult = state.intValue;
            Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"unobservable or changed process never supplies current evidence");
        }
        ObservationResult = RBXProcessObserved;
        NSDictionary *originalReady = Ready, *originalReport = Report;
        Ready = Replacing(Ready,@"containerId",@"two"); Report = Replacing(Report,@"containerId",@"two");
        Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"mutually matching foreign readiness/report do not bind to this profile");
        Ready = originalReady; Report = originalReport;
        for (NSString *state in @[@"closed",@"pending",@"unknown"])
            Check([Summary(profile,Replacing(lease,@"state",state))[@"current"] isEqual:@NO],@"closed or unrecognized lease is not current evidence");
        Ready = Replacing(Ready,@"timestamp",@(Observed.startSeconds-1));
        Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"readiness from before this process was born is stale");
        Ready = originalReady;
        for (NSString *key in @[@"containerId",@"bundleIdentifier",@"generation",@"bootEpoch"])
            Check([Summary(profile,Replacing(lease,key,@"other"))[@"current"] isEqual:@NO],@"lease cannot borrow another launch's identity");
        Check([Summary(profile,Replacing(lease,@"openedAt",@(now-5)))[@"current"] isEqual:@NO],@"OPEN receipt ordering is validated");
        NSDictionary *armed = Replacing(Replacing(lease,@"state",@"armed"),@"openedAt",@(now-5));
        Check([Summary(profile,armed)[@"current"] isEqual:@YES],@"ARMED report uses its challenge start ordering");
        NSString *alias = [root stringByAppendingString:@"-alias"];
        Check(symlink(root.fileSystemRepresentation,alias.fileSystemRepresentation)==0,@"controlled path alias fixture");
        strlcpy(Observed.executable,[alias stringByAppendingPathComponent:@"Main"].UTF8String,sizeof(Observed.executable));
        Check([Summary(profile,lease)[@"current"] isEqual:@YES],@"same canonical executable through a filesystem alias remains valid");
        strlcpy(Observed.executable,Executable.UTF8String,sizeof(Observed.executable));
        Check(unlink(alias.fileSystemRepresentation)==0,@"alias fixture cleaned");
        [RBXSentinelController setProcessIdentityProvider:nil];
        Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"unconfigured observer never falls back to a clone-selected PID");
        [RBXSentinelController setProcessIdentityProvider:^NSDictionary * { ProviderReads++; return ActiveIdentity; }];
        InvalidateDuringObservation = YES;
        Check([Summary(profile,lease)[@"current"] isEqual:@NO],@"stop/switch during kernel observation invalidates the captured identity");
        InvalidateDuringObservation = NO; ActiveIdentity = identity;
        Check(Observations > 0 && ProviderReads > Observations,@"production observer consults kernel and revalidates daemon authority");
        Check([Summary(profile,lease)[@"current"] isEqual:@YES],@"good report works again after independent valid fixture restoration");
        NSMutableArray *leaks = rows.mutableCopy;
        leaks[0] = RBXSentinelRow(@"keychain-default",@"none",@"LEAK",@"fixture secret must not be published",0);
        Report = Replacing(Report,@"rows",leaks);
        NSDictionary *summary = Summary(profile,lease);
        Check([summary[@"alert"] isEqual:@YES] && RBXIsolationLaunchBlock(Store,@"one").length,@"valid LEAK is retained and blocks subsequent launch");
        Check(![[summary description] containsString:@"fixture secret"],@"clone-controlled content is absent from public evidence");
        ActiveIdentity = nil;
        Check([Summary(profile,lease)[@"alert"] isEqual:@YES] && [Summary(profile,lease)[@"current"] isEqual:@NO],@"losing current evidence never clears an earlier alert");
        NSUInteger beforeOff = Observations, providerBeforeOff = ProviderReads;
        NSDictionary *enabledControl = Control;
        Store[@"containers"][@"one"][@"isolationSentinel"] = RBXSentinelSettings(nil);
        Check([Summary(profile,lease)[@"alert"] isEqual:@YES],@"turning the sentinel off retains a known alert");
        Check(Observations == beforeOff && ProviderReads == providerBeforeOff,@"OFF never invokes the kernel or identity provider");
        Store[@"containers"][@"one"] = [@{@"isolationSentinel":settings} mutableCopy];
        Store[@"alerts"] = [NSMutableArray array];
        Control = enabledControl;
        ActiveIdentity = identity;
        FailStoreWrite = YES;
        NSDictionary *failure = Summary(profile,lease);
        Check([failure[@"alert"] isEqual:@YES],@"a real LEAK remains visible after storage failure");
        Check(![RBXOperationContext checkSafetyFence:nil],@"failed alert persistence must block subsequent mutation/admission instead of forgetting the LEAK");
        Check([failure[@"persistenceVerified"] isEqual:@NO] && [failure[@"recoveryRequired"] isEqual:@YES],@"failed retention is explicit to the launcher");
        Check(ReportReads>0 && UnjournaledReportReads==0,@"durable operation ownership precedes every report read");
        Check(ActiveJournals().count==1,@"failed publication keeps preexisting restart evidence");
        [RBXOperationContext setSafetyFenceDirectoryForTesting:JournalDirectory];
        Check(![RBXOperationContext checkSafetyFence:nil],@"restart-like cache reset retains persisted unsafe state");

        // Each fault starts with an independent fixture store/journal. Production
        // exposes no corresponding reset/clear operation.
        for (NSString *fault in @[@"false-success",@"exception",@"deleted-profile",@"readback",@"unsafe-write"]) {
            JournalDirectory = [root stringByAppendingPathComponent:fault];
            [RBXOperationContext setSafetyFenceDirectoryForTesting:JournalDirectory];
            Store[@"containers"][@"one"] = [@{@"isolationSentinel":settings} mutableCopy];
            Store[@"alerts"] = [NSMutableArray array];
            FailStoreWrite = [fault isEqual:@"unsafe-write"];
            FailUnsafeRename = FailStoreWrite;
            DropStoreWrite = [fault isEqual:@"false-success"];
            ThrowStoreWrite = [fault isEqual:@"exception"];
            DeleteDuringStoreWrite = [fault isEqual:@"deleted-profile"];
            FailReadBack = [fault isEqual:@"readback"];
            NSDictionary *failed = Summary(profile,lease);
            Check([failed[@"alert"] isEqual:@YES] && [failed[@"recoveryRequired"] isEqual:@YES],@"publication failure never loses an observed LEAK");
            Check(![RBXOperationContext checkSafetyFence:nil],@"all publication faults block admission");
            Check(ActiveJournals().count==1,@"all publication faults preserve their operation journal");
            if (DeleteDuringStoreWrite) Check(!Store[@"containers"][@"one"],@"diagnostics does not recreate a deleted profile");
            if (FailUnsafeRename) {
                Check(![NSFileManager.defaultManager fileExistsAtPath:[JournalDirectory stringByAppendingPathComponent:@"unsafe.plist"]],@"secondary fence failure is reproduced");
                NSString *path = [JournalDirectory stringByAppendingPathComponent:ActiveJournals().firstObject];
                NSMutableDictionary *record = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
                record[@"bootEpoch"] = NSUUID.UUID.UUIDString;
                Check([record writeToFile:path atomically:NO],@"simulate the surviving active journal from a prior daemon boot");
                [RBXOperationContext setSafetyFenceDirectoryForTesting:JournalDirectory];
                Check(![RBXOperationContext checkSafetyFence:nil],@"active marker blocks restart even when unsafe.plist could not be written");
            }
        }
        FailStoreWrite=FailUnsafeRename=DropStoreWrite=ThrowStoreWrite=DeleteDuringStoreWrite=FailReadBack=NO;
        Store[@"containers"][@"one"] = [@{@"isolationSentinel":settings} mutableCopy];
        Store[@"alerts"] = [NSMutableArray array];
        NSString *badParent = [root stringByAppendingPathComponent:@"not-a-directory"];
        Check([[NSData data] writeToFile:badParent atomically:NO],@"unwritable journal fixture");
        JournalDirectory = [badParent stringByAppendingPathComponent:@"operations"];
        [RBXOperationContext setSafetyFenceDirectoryForTesting:JournalDirectory];
        NSUInteger readsBefore = ReportReads;
        Check([Summary(profile,lease)[@"recoveryRequired"] isEqual:@YES],@"failed initial journal is reported as recovery, never success");
        Check(ReportReads==readsBefore && ![RBXOperationContext checkSafetyFence:nil],@"report is not consumed without durable ownership and current admission remains blocked");

        JournalDirectory = [root stringByAppendingPathComponent:@"completed-retention"];
        [RBXOperationContext setSafetyFenceDirectoryForTesting:JournalDirectory];
        Check([Summary(profile,lease)[@"persistenceVerified"] isEqual:@YES],@"valid LEAK is retained atomically with the quarantine");
        Check(!ActiveJournals().count && [RBXOperationContext checkSafetyFence:nil],@"normal completed retention retires ownership without an unrelated global fence");
        Check(RBXIsolationLaunchBlock(Store,@"one").length>0,@"durable per-profile quarantine still blocks launch after completed retention");
        Check([Summary(profile,lease)[@"alert"] isEqual:@YES] && [Store[@"alerts"] count]==1,@"duplicate reports do not grow the alert ring");
        printf("PASS: actual sentinel controller %lu assertions (birth, ownership, report binding, retained alerts)\n",(unsigned long)Checks);
    } @catch (NSException *e) { fprintf(stderr,"FAIL: %s\n",e.reason.UTF8String); result=1; }
    @finally { [NSFileManager.defaultManager removeItemAtPath:root error:nil]; }
    return result;
} }
