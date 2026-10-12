// Actual context and NetworkGate mutation-guard tests. All fence I/O is under
// a temporary root; NetworkGate's device I/O methods are never invoked.
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#define RBX_OPERATION_TESTING 1
#import "RBXOperationContext.h"
#import "RBXSecureConfig.h"
#import "RBXCloneManager.h"
#import "RBXProcessController.h"
#import "RBXLicenseGuard.h"

// Link-only stubs for the gate's unused device service methods.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXSecureConfig @end
@implementation RBXCloneManager @end
@implementation RBXProcessController @end
@implementation RBXLicenseGuard @end
#pragma clang diagnostic pop
static BOOL FailActiveRename, FailUnsafeRename;
static int TestContextRename(int oldDirectory, const char *oldName, int newDirectory, const char *newName) {
    NSString *name = [NSString stringWithUTF8String:newName];
    if ((FailActiveRename && [name hasPrefix:@"active-"]) || (FailUnsafeRename && [name isEqual:@"unsafe.plist"])) {
        FailActiveRename = FailUnsafeRename = NO;
        errno = EIO;
        return -1;
    }
    return renameat(oldDirectory, oldName, newDirectory, newName);
}
#define renameat TestContextRename
#import "../daemon/RBXOperationContext.m"
#undef renameat
#import "../daemon/RBXNetworkGate.m"

@interface TestCancelResource : NSObject
@property(nonatomic) NSUInteger cancellationCount;
@property(nonatomic) dispatch_semaphore_t delivered;
@property(nonatomic) dispatch_semaphore_t releaseGate;
@property(nonatomic) dispatch_semaphore_t finished;
- (void)cancel;
- (void)invalidateAndCancel;
@end
@implementation TestCancelResource
- (void)cancel {
    @synchronized (self) { self.cancellationCount++; }
    if (self.delivered) dispatch_semaphore_signal(self.delivered);
    if (self.releaseGate) dispatch_semaphore_wait(self.releaseGate, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    if (self.finished) dispatch_semaphore_signal(self.finished);
}
- (void)invalidateAndCancel { [self cancel]; }
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}
static RBXOperationContext *Context(NSString *name) {
    return [RBXOperationContext contextWithRequestID:name bootEpoch:RBXOperationContext.daemonBootEpoch timeout:5.0];
}
static void TestCapturedOwnership(void) {
    RBXOperationContext *a = Context(@"A"), *b = Context(@"B");
    Check(!RBXOperationContext.currentContext, @"test begins without borrowed context");
    [a performBlock:^{
        Check(RBXOperationContext.currentContext == a, @"scope installs immutable owner A");
        @try { [b performBlock:^{
            Check(RBXOperationContext.currentContext == b, @"nested scope owns B");
            @throw [NSException exceptionWithName:@"Fixture" reason:@"restore" userInfo:nil];
        }]; } @catch (NSException *exception) { }
        Check(RBXOperationContext.currentContext == a, @"exception restores original owner");
        Check([RBXBootEpoch() isEqual:a.bootEpoch], @"gate and requests share one daemon boot epoch");
        NSString *epochA = RBXEpochForClone(a.bootEpoch, @"com.redditbox.profile.pa");
        Check(epochA.length == 64 && ![epochA isEqual:a.bootEpoch], @"clone never receives raw epoch");
        Check([epochA isEqual:RBXEpochForClone(a.bootEpoch, @"com.redditbox.profile.pa")], @"same clone epoch is stable");
        Check(![epochA isEqual:RBXEpochForClone(a.bootEpoch, @"com.redditbox.profile.pb")], @"different clones have different epochs");
        Check(![epochA isEqual:RBXEpochForClone(@"new-boot", @"com.redditbox.profile.pa")], @"restart invalidates scoped epoch");
    }];
    Check(!RBXOperationContext.currentContext, @"outer scope restores empty TLS");

    dispatch_queue_t queue = dispatch_queue_create("rbx.test.ownership", DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t release = dispatch_semaphore_create(0), entered = dispatch_semaphore_create(0);
    __block NSUInteger mutations = 0;
    __block BOOL ownedA = NO, ownedB = NO;
    Check([a dispatchAsyncOnQueue:queue block:^{
        ownedA = RBXOperationContext.currentContext == a;
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        if ([a check:nil]) mutations++;
    }], @"A work registered before dispatch");
    Check(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"A entered worker");
    [a cancelWithReason:@"synthetic timeout"];
    Check(![a waitForQuiescence:0], @"cancellation is not proof the worker stopped");
    Check([b dispatchAsyncOnQueue:queue block:^{
        ownedB = RBXOperationContext.currentContext == b;
        if ([b check:nil]) mutations += 10;
    }], @"B registered independently");
    dispatch_semaphore_signal(release);
    Check([a waitForQuiescence:1.0] && [b waitForQuiescence:1.0], @"real workers drain");
    Check(ownedA && ownedB, @"each asynchronous hop retains its own captured operation");
    Check(mutations == 10, @"late A cannot apply effects before B's valid effects");
    [a finish]; [b finish];
    Check(![a check:nil] && ![b check:nil], @"sealed owners cannot start another mutation");
}

static void TestTrackedCancellation(void) {
    RBXOperationContext *context = Context(@"resources");
    TestCancelResource *task = [TestCancelResource new], *owned = [TestCancelResource new], *unrelated = [TestCancelResource new];
    task.delivered = dispatch_semaphore_create(0);
    owned.delivered = dispatch_semaphore_create(0);
    [context trackTask:(NSURLSessionTask *)task];
    [context trackSession:(NSURLSession *)owned];
    __block NSUInteger childCancellations = 0;
    dispatch_semaphore_t childDelivered = dispatch_semaphore_create(0);
    NSString *registration = [context registerCancellationHandler:^{ childCancellations++; dispatch_semaphore_signal(childDelivered); }];
    [context cancelWithReason:@"test cancellation"];
    Check(dispatch_semaphore_wait(task.delivered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 &&
        dispatch_semaphore_wait(owned.delivered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 &&
        dispatch_semaphore_wait(childDelivered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"independent cancellation deliveries arrive");
    Check(task.cancellationCount == 1 && owned.cancellationCount == 1 && unrelated.cancellationCount == 0,
        @"only registered task and owned session are canceled");
    Check(childCancellations == 1, @"owned child cancellation is delivered");
    Check(![context waitForQuiescence:0], @"task still counts until its completion releases ownership");
    [context untrackTask:(NSURLSessionTask *)task];
    [context untrackSession:(NSURLSession *)owned];
    [context unregisterCancellationHandler:registration];
    [context registerCancellationHandler:^{ childCancellations++; dispatch_semaphore_signal(childDelivered); }];
    Check(dispatch_semaphore_wait(childDelivered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"already-canceled delivery arrives");
    Check(childCancellations == 2, @"registration racing prior cancellation receives cancellation");
    Check([context waitForQuiescence:0], @"completion proves task drain");
    [context finish];

    RBXOperationContext *blocked = Context(@"blocked-cancellation");
    TestCancelResource *slowTask = [TestCancelResource new];
    slowTask.delivered = dispatch_semaphore_create(0);
    slowTask.releaseGate = dispatch_semaphore_create(0);
    slowTask.finished = dispatch_semaphore_create(0);
    [blocked trackTask:(NSURLSessionTask *)slowTask];
    dispatch_semaphore_t slowHandlerEntered = dispatch_semaphore_create(0), handlerRelease = dispatch_semaphore_create(0);
    dispatch_semaphore_t observerDelivered = dispatch_semaphore_create(0), cancelReturned = dispatch_semaphore_create(0);
    dispatch_semaphore_t handlerDone = dispatch_semaphore_create(0);
    [blocked registerCancellationHandler:^{
        dispatch_semaphore_signal(slowHandlerEntered);
        dispatch_semaphore_wait(handlerRelease, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
        dispatch_semaphore_signal(handlerDone);
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [blocked cancelWithReason:@"synthetic framework lock"];
        dispatch_semaphore_signal(cancelReturned);
    });
    Check(dispatch_semaphore_wait(cancelReturned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
        @"cancel returns without waiting for resource or handler locks");
    Check(dispatch_semaphore_wait(slowHandlerEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 &&
        dispatch_semaphore_wait(slowTask.delivered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
        @"independent slow cancellation callbacks are both in flight");
    [blocked registerCancellationHandler:^{
        Check(!RBXOperationContext.currentContext, @"cancellation delivery never borrows TLS ownership");
        dispatch_semaphore_signal(observerDelivered);
    }];
    Check(dispatch_semaphore_wait(observerDelivered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
        @"watchdog registration is delivered while other cancellation callbacks are blocked");
    Check(![blocked waitForQuiescence:0], @"async cancellation still does not prove resource drain");
    dispatch_semaphore_signal(slowTask.releaseGate);
    dispatch_semaphore_signal(handlerRelease);
    Check(dispatch_semaphore_wait(handlerDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0 &&
        dispatch_semaphore_wait(slowTask.finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"fixture releases blocked cancellation callbacks");
    [blocked untrackTask:(NSURLSessionTask *)slowTask];
    [blocked finish];

    RBXOperationContext *deadline = [RBXOperationContext contextWithRequestID:@"deadline"
        bootEpoch:RBXOperationContext.daemonBootEpoch timeout:0.05];
    dispatch_semaphore_t expired = dispatch_semaphore_create(0);
    [deadline registerCancellationHandler:^{ dispatch_semaphore_signal(expired); }];
    Check(dispatch_semaphore_wait(expired, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
        @"monotonic deadline cancels independently of a waiting request thread");
    Check(deadline.cancelled && deadline.remainingTime == 0 && ![deadline check:nil], @"expired context refuses effects");
    [deadline finish];

    RBXOperationContext *quarantine = Context(@"rotation-quarantine");
    dispatch_queue_t queue = dispatch_queue_create("rbx.test.quarantine", DISPATCH_QUEUE_SERIAL);
    __block BOOL callbackRan = NO, mutationRan = NO, correctOwner = NO;
    Check([quarantine dispatchAfter:2.0 queue:queue block:^{
        callbackRan = YES;
        correctOwner = RBXOperationContext.currentContext == quarantine;
        if ([quarantine check:nil]) mutationRan = YES;
    }], @"rotation quarantine is counted before its timer is scheduled");
    [quarantine cancelWithReason:@"cancel during rotation quarantine"];
    Check(![quarantine waitForQuiescence:0], @"pending quarantine is not falsely reported drained");
    Check([quarantine waitForQuiescence:3.0] && callbackRan && correctOwner && !mutationRan,
        @"canceled two-second quarantine drains with captured owner and cannot activate traffic");
    [quarantine finish];

    RBXOperationContext *tooShort = [RBXOperationContext contextWithRequestID:@"short-quarantine"
        bootEpoch:RBXOperationContext.daemonBootEpoch timeout:0.2];
    __block BOOL earlyRan = NO;
    Check(![tooShort dispatchAfter:2.0 queue:queue block:^{ earlyRan = YES; }],
        @"required quarantine is rejected instead of silently shortened");
    Check([tooShort waitForQuiescence:0] && tooShort.cancelled && !earlyRan, @"rejected timer leaves no escaped worker");
    [tooShort finish];
}

static void TestActiveMarkers(NSString *directory) {
    RBXOperationContext *active = Context(@"active-marker");
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"active-%@.plist", active.token]];
    Check([active beginWork:nil], @"mutating work establishes durable ownership first");
    NSDictionary *record = [NSDictionary dictionaryWithContentsOfFile:path];
    Check([record[@"token"] isEqual:active.token] && [record[@"bootEpoch"] isEqual:active.bootEpoch],
        @"active marker is readable before the caller can perform effects");
    Check([RBXOperationContext checkSafetyFence:nil], @"same-boot active work is not a global fence");
    [active endWork]; [active finish];
    Check(![NSFileManager.defaultManager fileExistsAtPath:path], @"proven drained finish retires its marker");

    RBXOperationContext *cleanup = Context(@"counted-cleanup");
    Check([cleanup beginWork:nil], @"cleanup owner starts with durable marker");
    [cleanup cancelWithReason:@"cancel before cleanup"];
    Check([cleanup beginCancellationCleanup], @"canceled owner can count revocation without gaining mutation authority");
    [cleanup endWork];
    Check(![cleanup waitForQuiescence:0] && ![cleanup check:nil] && ![cleanup sealCompletedWork],
        @"cleanup remains outstanding and cannot authorize normal effects");
    [cleanup endWork]; [cleanup finish];
    RBXOperationContext *sealed = Context(@"completion-seal");
    Check([sealed beginWork:nil], @"normal owner starts");
    [sealed endWork];
    Check([sealed sealCompletedWork], @"drained normal result seals atomically before publication");
    [sealed cancelWithReason:@"late timer"];
    Check(!sealed.cancelled && ![sealed beginCancellationCleanup], @"late timer cannot revoke a completed owner");
    [sealed finish];

    RBXOperationContext *rejected = Context(@"failed-marker");
    FailActiveRename = YES;
    NSError *error = nil;
    Check(![rejected beginWork:&error] && error && rejected.cancelled,
        @"actual marker rename failure rejects work before effects");
    Check(!FailActiveRename, @"publication fault reached the actual rename boundary");
    [rejected finish];

    RBXOperationContext *abandoned = Context(@"abandoned-marker");
    Check([abandoned beginWork:nil], @"owned work begins before simulated daemon death");
    NSString *abandonedPath = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"active-%@.plist", abandoned.token]];
    [abandoned cancelWithReason:@"unresolved operation"];
    FailUnsafeRename = YES;
    Check(![abandoned markUnsafeWithReason:@"Synthetic unquiescent child" error:&error],
        @"unsafe-file publication failure is explicit");
    Check([NSFileManager.defaultManager fileExistsAtPath:abandonedPath],
        @"preexisting active marker survives failed unsafe-file publication");
    [abandoned endWork]; [abandoned finish];
    Check([NSFileManager.defaultManager fileExistsAtPath:abandonedPath],
        @"late drain does not retire restart evidence after failed unsafe publication");
    NSMutableDictionary *oldBoot = [[NSDictionary dictionaryWithContentsOfFile:abandonedPath] mutableCopy];
    oldBoot[@"bootEpoch"] = NSUUID.UUID.UUIDString;
    Check([oldBoot writeToFile:abandonedPath atomically:NO], @"synthetic previous-boot marker writes");
    [RBXOperationContext setSafetyFenceDirectoryForTesting:directory];
    Check(![Context(@"restart-request") beginWork:nil],
        @"restart observes abandoned active marker even without unsafe.plist");
    Check([NSFileManager.defaultManager fileExistsAtPath:abandonedPath],
        @"restart never silently clears incomplete ownership");
    // The synthetic abandoned journal is retained for fixture cleanup.
}

static void TestPersistentFence(NSString *directory) {
    RBXOperationContext *stalled = Context(@"stalled");
    Check([stalled beginWork:nil], @"stalled owned work starts");
    [stalled cancelWithReason:@"deadline expired"];
    Check(![stalled waitForQuiescence:0.01], @"bounded drain reports unresolved work");
    NSError *error = nil;
    Check([stalled markUnsafeWithReason:@"Synthetic child did not quiesce" error:&error],
        error.localizedDescription ?: @"unsafe state persists");
    [stalled endWork]; [stalled finish];
    Check(![RBXOperationContext checkSafetyFence:nil], @"late worker completion never clears unsafe state");
    // Clears only the test process cache; the real persisted file survives.
    [RBXOperationContext setSafetyFenceDirectoryForTesting:directory];
    Check(![Context(@"next-boot") check:nil], @"fresh context reads and honors old persistent fence");
    RBXOperationContext *inspection = [RBXOperationContext contextWithRequestID:@"diagnostics"
        bootEpoch:RBXOperationContext.daemonBootEpoch timeout:5 inspectionOnly:YES];
    Check([inspection beginWork:nil], @"narrow inspection remains usable during recovery");
    Check(![NSFileManager.defaultManager fileExistsAtPath:[directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"active-%@.plist", inspection.token]]], @"inspection does not create a mutation marker");
    [inspection performBlock:^{ Check(!RBXGateMutationAllowed(nil), @"inspection cannot arm or open traffic through fence"); }];
    [inspection cancelWithReason:@"inspection timeout"];
    Check(![inspection check:nil], @"inspection still obeys cancellation");
    [inspection endWork];
    [inspection finish];
    NSString *path = [directory stringByAppendingPathComponent:@"unsafe.plist"];
    Check([[@"corrupt" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:0 error:nil], @"corrupt fence fixture writes");
    [RBXOperationContext setSafetyFenceDirectoryForTesting:directory];
    Check(![RBXOperationContext checkSafetyFence:nil], @"corrupt existing fence is never treated as absent");
}

int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"rbx-context-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        int result = 0;
        @try {
            Check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0700} error:nil], @"temporary fixture directory created");
            root = root.stringByResolvingSymlinksInPath;
            NSString *directory = [root stringByAppendingPathComponent:@"operations"];
            [RBXOperationContext setSafetyFenceDirectoryForTesting:directory];
            TestCapturedOwnership();
            TestTrackedCancellation();
            TestActiveMarkers(directory);
            NSString *fencedDirectory = [root stringByAppendingPathComponent:@"persistent-fence"];
            [RBXOperationContext setSafetyFenceDirectoryForTesting:fencedDirectory];
            TestPersistentFence(fencedDirectory);
            puts("PASS: actual operation TLS, cancellation, tracked drain, deadlines, persistent fence, and NetworkGate authorization guard");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); result = 1;
        } @finally {
            [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        }
        return result;
    }
}
