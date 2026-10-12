// Actual main request coordinator + actual OperationContext, with synthetic
// receipts/closure/publication. No real device paths, processes or networking.
#import <Foundation/Foundation.h>
#define RBX_REQUEST_EXECUTION_TESTING 1
#include "../daemon/main.m"

static NSMutableDictionary *Receipts;
static NSMutableDictionary *ReceiptCounts;
static NSUInteger CloseCount;
static NSUInteger StartupPublications;
static NSObject *FixtureLock;
static dispatch_semaphore_t BlockClosure, ClosureEntered;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXRequestQueue
- (BOOL)finishRequest:(NSDictionary *)request ok:(BOOL)ok message:(NSString *)message
    values:(NSDictionary *)values error:(NSError **)error {
    @synchronized (FixtureLock) {
        NSString *identifier = request[@"requestId"];
        ReceiptCounts[identifier] = @([ReceiptCounts[identifier] unsignedIntegerValue] + 1);
        Receipts[identifier] = @{@"ok": @(ok), @"message": message ?: @"", @"details": values ?: @{}};
    }
    return YES;
}
@end
@implementation RBXNetworkGate
+ (NSString *)closeTrafficWithReason:(NSString *)reason {
    dispatch_semaphore_t blocked, entered;
    @synchronized (FixtureLock) { CloseCount++; blocked = BlockClosure; entered = ClosureEntered; }
    if (entered) dispatch_semaphore_signal(entered);
    if (blocked) dispatch_semaphore_wait(blocked, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC));
    return @"fixture-closed";
}
@end
@implementation RBXAppProcessCoordinator
- (BOOL)killAllAndWait:(NSTimeInterval)timeout { return YES; }
@end
@implementation RBXLauncherState
+ (void)publishWithRegistry:(RBXContainerRegistry *)registry { }
+ (void)publishStartupRecoveryResult:(NSDictionary *)result registry:(RBXContainerRegistry *)registry {
    @synchronized (FixtureLock) { StartupPublications++; }
}
@end
@implementation RBXContainerRegistry @end
#pragma clang diagnostic pop

static void Check(BOOL value, NSString *message) {
    if (!value) @throw [NSException exceptionWithName:@"FixtureFailure" reason:message userInfo:nil];
}
static NSDictionary *Request(NSString *action) {
    return @{@"requestId": NSUUID.UUID.UUIDString, @"action": action};
}
static NSDictionary *WaitReceipt(NSDictionary *request, NSTimeInterval timeout) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    do {
        @synchronized (FixtureLock) {
            NSDictionary *result = Receipts[request[@"requestId"]];
            if (result) return result;
        }
        [NSThread sleepForTimeInterval:0.005];
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    Check(NO, @"accepted request did not receive a bounded terminal result");
    return nil;
}
static void DrainOwner(NSDictionary *request) {
    RBXRequestExecution *execution;
    @synchronized (sExecutions) { execution = sExecutions[request[@"requestId"]]; }
    Check([execution.context waitForQuiescence:2], @"fixture workers stop before the next scenario");
    dispatch_sync(sSwitchQueue, ^{});
}
static void TestDeferredCompletion(void) {
    RBXRequestTestBudget = 3;
    NSDictionary *request = Request(@"fixture-work");
    __block BOOL descendantFinished = NO;
    dispatchRequest(request, ^{
        RBXOperationContext *context = RBXOperationContext.currentContext;
        Check([context dispatchAfter:0.08 queue:sDeadlineQueue block:^{
            if ([context check:nil]) descendantFinished = YES;
        }], @"descendant is tracked before scheduling");
        completeRequest(request, YES, @"staged", @{});
    });
    Check([WaitReceipt(request, 3)[@"ok"] boolValue] && descendantFinished,
        @"staged success is published only after descendants finish");
    completeRequest(request, NO, @"obsolete callback", @{});
    @synchronized (FixtureLock) { Check([ReceiptCounts[request[@"requestId"]] integerValue] == 1, @"late completion cannot replace terminal result"); }
    DrainOwner(request);
}
static void TestQueuedExpiration(void) {
    RBXRequestTestBudget = 3;
    NSDictionary *owner = Request(@"fixture-owner");
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatchRequest(owner, ^{
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        completeRequest(owner, YES, @"owner finished", @{});
    });
    Check(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"owner entered");
    NSUInteger closures;
    @synchronized (FixtureLock) { closures = CloseCount; }
    RBXRequestTestBudget = 0.04;
    NSDictionary *queued = Request(@"launchContainer");
    __block BOOL queuedRan = NO;
    dispatchRequest(queued, ^{ queuedRan = YES; completeRequest(queued, YES, @"unexpected", @{}); });
    Check(![WaitReceipt(queued, 1)[@"ok"] boolValue], @"queued expiration produces failure receipt");
    @synchronized (FixtureLock) { Check(CloseCount == closures, @"expired queued request does not close existing owner"); }
    Check(!queuedRan && !RBXOperationContext.safetyFenceStatus, @"unstarted expiry has no mutation or false unsafe fence");
    dispatch_semaphore_signal(release);
    Check([WaitReceipt(owner, 2)[@"ok"] boolValue], @"preceding owner survives queued expiry");
    DrainOwner(owner);
}
static void TestCancelWake(void) {
    RBXRequestTestBudget = 3;
    NSDictionary *request = Request(@"fixture-reply");
    dispatchRequest(request, ^{
        RBXOperationContext *context = RBXOperationContext.currentContext;
        NSDictionary *reply = waitForOperationReply(^(void (^done)(NSDictionary *)) {
            [context dispatchAfter:0.04 queue:sDeadlineQueue block:^{ [context cancelWithReason:@"fixture early cancellation"]; }];
            // Deliberately never call done: cancellation must wake main's wait.
        });
        completeRequest(request, [reply[@"ok"] boolValue], reply[@"message"], @{});
    });
    Check(![WaitReceipt(request, 1)[@"ok"] boolValue], @"early cancellation wakes a missing callback before the original budget");
    DrainOwner(request);
}
static void TestStartupReceipt(void) {
    RBXRequestTestBudget = 2;
    NSDictionary *request = Request(@"startupRecovery");
    dispatchOwnedRequest(request, ^{ completeRequest(request, YES, @"recovered", @{}); }, YES);
    dispatch_sync(sSwitchQueue, ^{});
    @synchronized (FixtureLock) {
        Check(StartupPublications == 1 && !Receipts[request[@"requestId"]], @"startup recovery publishes status without an invented IPC receipt");
    }
}
static void TestDataPreflightAdmission(void) {
    RBXRequestTestBudget = 3;
    @synchronized (sExecutions) { sDataReady = NO; sDataFailure = @"fixture newer schema retained"; }
    NSDictionary *mutation = Request(@"createContainer");
    __block BOOL mutated = NO;
    dispatchRequest(mutation, ^{ mutated = YES; completeRequest(mutation, YES, @"unexpected", @{}); });
    Check(![WaitReceipt(mutation, 2)[@"ok"] boolValue] && !mutated,
        @"newer schema blocks mutations before their body starts");
    NSDictionary *inspection = Request(@"runDiagnostics");
    dispatchRequest(inspection, ^{
        Check(RBXOperationContext.currentContext.inspectionOnly, @"schema failure permits inspection only");
        completeRequest(inspection, YES, @"diagnostics available", @{});
    });
    Check([WaitReceipt(inspection, 2)[@"ok"] boolValue], @"diagnostics remain reachable after schema rejection");
    dispatch_sync(sInspectionQueue, ^{});
    @synchronized (sExecutions) { sDataReady = YES; sDataFailure = nil; }
}
static void TestInternalCheckRetention(void) {
    RBXRequestTestBudget = 3;
    NSUInteger owners = sExecutions.count, terminals = sTerminalRequests.count;
    for (NSUInteger index = 0; index < 200; index++) {
        NSDictionary *request = @{@"requestId": NSUUID.UUID.UUIDString,
            @"action": @"validateLicense", @"internalLicenseCheck": @YES};
        sLicenseCheckQueued = YES;
        dispatchRequest(request, ^{ completeRequest(request, YES, @"checked", @{}); });
        dispatch_sync(sSwitchQueue, ^{});
        Check(!sLicenseCheckQueued && sExecutions.count == owners && sTerminalRequests.count == terminals,
            @"completed periodic checks retain neither execution graphs nor dedupe IDs");
        sLicenseCheckQueued = YES; // A newer check now owns the coalescer.
        completeRequest(request, NO, @"obsolete periodic callback", @{});
        Check(sLicenseCheckQueued, @"retired callback cannot clear the newer check's ownership");
        sLicenseCheckQueued = NO;
    }
}
static void TestStalledOwnerAndInspection(void) {
    RBXRequestTestBudget = 5;
    NSDictionary *stalled = Request(@"fixture-stalled");
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    __block BOOL lateMutation = NO;
    @synchronized (FixtureLock) {
        BlockClosure = dispatch_semaphore_create(0);
        ClosureEntered = dispatch_semaphore_create(0);
    }
    dispatchRequest(stalled, ^{
        RBXOperationContext *context = RBXOperationContext.currentContext;
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 7 * NSEC_PER_SEC));
        if ([context check:nil]) lateMutation = YES;
        completeRequest(stalled, YES, @"obsolete success", @{});
    });
    Check(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"stalled owner entered");
    @synchronized (sExecutions) {
        RBXRequestExecution *owner = sExecutions[stalled[@"requestId"]];
        [owner.context cancelWithReason:@"fixture explicit cancellation after worker entry"];
    }
    Check(![WaitReceipt(stalled, 4)[@"ok"] boolValue] && RBXOperationContext.safetyFenceStatus,
        @"unquiescent timeout reports failure and persists recovery fence");
    Check(dispatch_semaphore_wait(ClosureEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
        @"cancellation cleanup entered its deliberately stalled gate");
    Check(![sExecutions[stalled[@"requestId"]].context waitForQuiescence:0],
        @"blocked revocation remains counted after the bounded failure receipt");
    RBXRequestTestBudget = 2;
    NSDictionary *inspection = Request(@"runDiagnostics");
    dispatchRequest(inspection, ^{ completeRequest(inspection, YES, @"inspection remains reachable", @{}); });
    Check([WaitReceipt(inspection, 1)[@"ok"] boolValue], @"inspection bypasses the stalled mutation queue");
    dispatch_semaphore_signal(BlockClosure);
    @synchronized (FixtureLock) { BlockClosure = nil; ClosureEntered = nil; }
    NSDictionary *next = Request(@"createContainer");
    __block BOOL nextMutated = NO;
    dispatchRequest(next, ^{ nextMutated = YES; completeRequest(next, YES, @"unexpected", @{}); });
    dispatch_semaphore_signal(release);
    Check(![WaitReceipt(next, 2)[@"ok"] boolValue] && !nextMutated && !lateMutation,
        @"neither late A nor later B can mutate after unproven cleanup");
    DrainOwner(stalled);
    @synchronized (FixtureLock) { Check([ReceiptCounts[stalled[@"requestId"]] integerValue] == 1, @"watchdog/owner race still gives one receipt"); }
}
int main(void) {
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rbx-request-deadline-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        int status = 0;
        @try {
            FixtureLock = [NSObject new]; Receipts = [NSMutableDictionary dictionary]; ReceiptCounts = [NSMutableDictionary dictionary];
            sTerminalRequests = [NSMutableSet set]; sExecutions = [NSMutableDictionary dictionary];
            sRequests = [RBXRequestQueue new]; sProc = [RBXAppProcessCoordinator new]; sRegistry = [RBXContainerRegistry new];
            sSwitchQueue = dispatch_queue_create("fixture.switch", DISPATCH_QUEUE_SERIAL);
            dispatch_queue_set_specific(sSwitchQueue, &sSwitchQueueKey, &sSwitchQueueKey, NULL);
            sDeadlineQueue = dispatch_queue_create("fixture.deadlines", DISPATCH_QUEUE_CONCURRENT);
            sInspectionQueue = dispatch_queue_create("fixture.inspection", DISPATCH_QUEUE_CONCURRENT);
            dispatch_queue_set_specific(sInspectionQueue, &sSwitchQueueKey, &sSwitchQueueKey, NULL);
            [RBXOperationContext setSafetyFenceDirectoryForTesting:[root stringByAppendingPathComponent:@"operations"]];
            TestDeferredCompletion(); TestQueuedExpiration(); TestCancelWake(); TestStartupReceipt(); TestDataPreflightAdmission(); TestInternalCheckRetention(); TestStalledOwnerAndInspection();
            puts("PASS actual request deadline, cancellation wake, one terminal receipt, queue expiry and recovery inspection fixtures");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); status = 1;
        } @finally { [NSFileManager.defaultManager removeItemAtPath:root error:nil]; }
        return status;
    }
}
