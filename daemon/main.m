#import "RBXAppAdmission.h"
#import "RBXCreationDraftStore.h"
#import "RBXWorkspaceSelection.h"
#import "RBXInstallPaths.h"
#import "RBXIsolationSentinel.h"
#import "RBXProfileIO.h"
#import <Foundation/Foundation.h>
#import "RBXContainerRegistry.h"
#import "RBXProfileMetadata.h"
#import "RBXReplacement.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXProxyManager.h"
#import "RBXNetworkGate.h"
#import "RBXAppVersionMonitor.h"
#import "RBXLeakMonitor.h"
#import "RBXFingerprintRegistry.h"
#import "RBXABTestFramework.h"
#import "RBXProfileGenerator.h"
#import "RBXCloudSync.h"
#import "RBXLicenseGuard.h"
#import "RBXCloneManager.h"
#import "RBXLauncherState.h"
#import "RBXSentinelController.h"
#import "RBXLaunchSafety.h"
#import "RBXCentralStore.h"
#import "RBXIdentityLifecycle.h"
#import "RBXDataMigration.h"
#import "RBXDiagnostics.h"
#import "RBXSecureConfig.h"
#import "RBXRequestQueue.h"
#import "RBXOperationContext.h"
#import "RBXMemoryBudget.h"
#import <dlfcn.h>
#import <string.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>

// redditboxd Ă˘â‚¬â€ť root daemon.
// Responsibilities:
//  - claim unique launcher requests; Darwin notifications only wake the queue
//  - on launch: validate profile consistency, activate proxy, then bind + launch app
//  - on app death: kill switch (tear down proxy route, purge residue)
//  - periodic container health checks

static RBXContainerRegistry *sRegistry;
static NSMutableDictionary *sCreationDrafts; // Only accessed on the serialized operation queue.
static RBXAppProcessCoordinator *sProc;
static RBXProxyManager *sProxies;
static RBXAppVersionMonitor *sVersionMonitor;
static dispatch_queue_t sSwitchQueue;
static dispatch_queue_t sIPCQueue;
static RBXRequestQueue *sRequests;
static NSMutableSet<NSString *> *sTerminalRequests;
static BOOL sLicenseCheckQueued;
static NSTimeInterval sLastActiveLicenseCheck;
#ifdef RBX_REQUEST_EXECUTION_TESTING
static BOOL sDataReady = YES;
#else
static BOOL sDataReady;
#endif
static NSString *sDataFailure;
@interface RBXRequestExecution : NSObject
@property(nonatomic, strong) NSDictionary *request;
@property(nonatomic, strong) RBXOperationContext *context;
@property(nonatomic, strong) NSDictionary *result;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL bodyFinished;
@property(nonatomic) BOOL published;
@property(nonatomic) BOOL internalStartup;
@property(nonatomic) BOOL cancellationCleanupScheduled;
@end
@implementation RBXRequestExecution
@end

// This lock protects ownership only. No device service or persistence operation
// may run while it is held; a stalled worker must not stall terminal reporting.
static NSMutableDictionary<NSString *, RBXRequestExecution *> *sExecutions;
static BOOL dataReady(void) { @synchronized (sExecutions) { return sDataReady; } }
static dispatch_queue_t sDeadlineQueue;
static dispatch_queue_t sInspectionQueue;
static char sSwitchQueueKey;
static void scheduleRequestDrain(void);
static void completeRequest(NSDictionary *request, BOOL ok, NSString *message, NSDictionary *details);
static void dispatchRequest(NSDictionary *request, dispatch_block_t block);
static void publishLauncherOperation(NSDictionary *pending, NSString *action, NSString *containerId,
                                     BOOL ok, NSString *message);
static void publishIdentityResult(NSDictionary *pending, NSString *containerId, NSString *requestId,
                                  BOOL ok, BOOL applied, NSDictionary *preview,
                                  NSString *message);

static void publishTerminalRequest(NSDictionary *request, BOOL ok, NSString *message, NSDictionary *details) {
    NSString *requestId = request[@"requestId"];
    BOOL internalLicense = [request[@"internalLicenseCheck"] boolValue];
    if (!internalLicense) @synchronized (sTerminalRequests) {
        if ([sTerminalRequests containsObject:requestId]) return;
        [sTerminalRequests addObject:requestId];
    }
    NSError *error = nil;
    BOOL startup;
    @synchronized (sExecutions) { startup = sExecutions[requestId].internalStartup; }
    if (internalLicense) {
        @synchronized (sExecutions) { sLicenseCheckQueued = NO; }
        if (!ok) NSLog(@"redditboxd: license check: %@", message ?: @"locked");
    } else if (startup) {
        [RBXLauncherState publishStartupRecoveryResult:@{@"ok": @(ok),
            @"message": message ?: @"Startup recovery finished", @"details": details ?: @{},
            @"updatedAt": @(NSDate.date.timeIntervalSince1970)} registry:sRegistry];
    } else if (![sRequests finishRequest:request ok:ok message:message ?: @"Operation finished"
        values:details ?: @{} error:&error]) {
        // The queue retains the receipt for retry; never replay its side effect.
        NSLog(@"redditboxd: terminal receipt retained for retry: %@", error.localizedDescription);
    }
    [RBXLauncherState publishWithRegistry:sRegistry];
}

static void completeRequest(NSDictionary *request, BOOL ok, NSString *message, NSDictionary *details) {
    @synchronized (sExecutions) {
        RBXRequestExecution *execution = sExecutions[request[@"requestId"]];
        if (execution) {
        if (execution.published || execution.result) return;
        // Callbacks only stage a result. The owner publishes after drain, or
        // publishes an explicit fenced timeout if drain cannot be established.
        execution.result = @{@"ok": @(ok), @"message": message ?: @"Operation finished",
            @"details": details ?: @{}, @"request": request};
        return;
        }
    }
    // Internal checks have no durable IPC receipt. Once their quiescent owner
    // is retired, obsolete callbacks cannot reset a newer check's coalescer.
    if (![request[@"internalLicenseCheck"] boolValue])
        publishTerminalRequest(request, ok, message, details);
}

static void retireInternalExecution(RBXRequestExecution *execution) {
    if (![execution.request[@"internalLicenseCheck"] boolValue] ||
        ![execution.context waitForQuiescence:0]) return;
    @synchronized (sExecutions) {
        if (execution.published && execution.bodyFinished &&
            sExecutions[execution.request[@"requestId"]] == execution)
            [sExecutions removeObjectForKey:execution.request[@"requestId"]];
    }
}

static BOOL inspectionAction(NSString *action) {
    return [@[@"runDiagnostics", @"exportSupportLog", @"openFirewall", @"refreshLauncher", @"configureIsolationSentinel"] containsObject:action];
}

#ifdef RBX_REQUEST_EXECUTION_TESTING
static NSTimeInterval RBXRequestTestBudget = 5.0;
#endif
static NSTimeInterval requestBudget(NSString *action) {
#ifdef RBX_REQUEST_EXECUTION_TESTING
    return RBXRequestTestBudget;
#else
    if ([@[@"import-source", @"archiveSource", @"createContainer", @"exportCloneIPA",
        @"export", @"importNewest", @"importById", @"cloudVaultRestore", @"refreshLauncher", @"configureCloud", @"startupRecovery", @"replaceContainer", @"applyIdentity"] containsObject:action]) return 600;
    if ([@[@"launchContainer", @"launchSelectedContainer", @"selectContainer", @"deleteContainer"] containsObject:action]) return 240;
    if ([action isEqual:@"runDiagnostics"] || [action isEqual:@"exportSupportLog"]) return 60;
    return 120;
#endif
}

static NSDictionary *operationFailure(RBXOperationContext *context, NSString *fallback) {
    NSError *error = nil;
    [context check:&error];
    return @{@"ok": @NO, @"message": error.localizedDescription ?: fallback};
}

static void publishExecution(RBXRequestExecution *execution, NSDictionary *result) {
    @synchronized (sExecutions) {
        if (execution.published) return;
        execution.published = YES;
    }
    NSDictionary *request = result[@"request"] ?: execution.request;
    publishTerminalRequest(request, [result[@"ok"] boolValue], result[@"message"], result[@"details"] ?: @{});
}

static NSDictionary *fenceRequest(RBXRequestExecution *execution, NSString *reason) {
    NSDictionary *fence = [execution.context fenceInMemoryWithReason:reason];
    // The pre-mutation marker is already durable. A blocked unsafe-record write
    // cannot prevent an error receipt or hold the ownership/inspection lock.
    dispatch_async(sDeadlineQueue, ^{ [execution.context markUnsafeWithReason:reason error:nil]; });
    return fence;
}

static void startCancellationCleanup(RBXRequestExecution *execution) {
    BOOL scheduled = NO;
    @synchronized (sExecutions) {
        if (!execution.published && execution.started && !execution.context.inspectionOnly &&
            !execution.cancellationCleanupScheduled) {
            scheduled = [execution.context beginCancellationCleanup];
            execution.cancellationCleanupScheduled = scheduled;
        }
    }
    if (!scheduled) return;
    // Enroll before dispatch. Drain is not proven while CLOSED publication,
    // a device-service lock or process termination is still outstanding.
    dispatch_async(sDeadlineQueue, ^{
        @try {
            BOOL closed = [RBXNetworkGate closeTrafficWithReason:@"request cancellation"] != nil;
            BOOL stopped = [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            if (!closed || !stopped) fenceRequest(execution,
                @"Canceled operation could not prove CLOSED traffic and stopped processes; recovery is required.");
        } @catch (NSException *exception) {
            fenceRequest(execution, @"Cancellation cleanup raised an exception; recovery is required.");
        } @finally { [execution.context endWork]; }
    });
}

static void superviseCancellation(RBXRequestExecution *execution) {
    startCancellationCleanup(execution);
    dispatch_async(sDeadlineQueue, ^{
        BOOL quiet = [execution.context waitForQuiescence:2.0];
        NSDictionary *recovery = nil;
        @synchronized (sExecutions) {
            if (execution.published) return;
            if (execution.started && (!quiet || !execution.bodyFinished)) recovery = fenceRequest(execution,
                @"A canceled request or its cleanup has not stopped; further mutations require recovery.");
        }
        NSMutableDictionary *result = [operationFailure(execution.context,
            execution.started ? @"Operation canceled; revocation was requested." :
                @"Request expired while waiting for the previous operation.") mutableCopy];
        result[@"details"] = @{@"stage": @"deadline", @"operationToken": execution.context.token,
            @"recovery": recovery ?: [RBXOperationContext safetyFenceStatus] ?: @{}};
        publishExecution(execution, result);
        if (quiet) { [execution.context finish]; retireInternalExecution(execution); }
    });
}

static void dispatchOwnedRequest(NSDictionary *request, dispatch_block_t block, BOOL internalStartup) {
    if (dispatch_get_specific(&sSwitchQueueKey)) {
        if ([[RBXOperationContext currentContext] check:nil]) block();
        else completeRequest(request, NO, @"Operation was canceled before its next stage", @{});
        return;
    }
    RBXRequestExecution *execution = [RBXRequestExecution new];
    execution.request = request;
    execution.internalStartup = internalStartup;
    execution.context = [RBXOperationContext contextWithRequestID:request[@"requestId"]
        bootEpoch:[RBXOperationContext daemonBootEpoch] timeout:requestBudget(request[@"action"])
        inspectionOnly:inspectionAction(request[@"action"]) &&
            (![request[@"action"] isEqual:@"refreshLauncher"] || !dataReady() || [RBXOperationContext safetyFenceStatus] != nil)];
    @synchronized (sExecutions) { sExecutions[request[@"requestId"]] = execution; }
    [execution.context registerCancellationHandler:^{ superviseCancellation(execution); }];
    dispatch_queue_t queue = execution.context.inspectionOnly && (!dataReady() || [RBXOperationContext safetyFenceStatus])
        ? sInspectionQueue : sSwitchQueue;
    dispatch_async(queue, ^{
        RBXOperationContext *context = execution.context;
        NSError *startError = nil;
        BOOL began = NO;
        BOOL alreadyPublished;
        @synchronized (sExecutions) {
            alreadyPublished = execution.published;
            if (alreadyPublished) execution.bodyFinished = YES;
        }
        if (alreadyPublished) { retireInternalExecution(execution); return; }
        if (!dataReady() && !internalStartup && !context.inspectionOnly) {
            NSString *reason;
            @synchronized (sExecutions) { reason = sDataFailure; execution.bodyFinished = YES; }
            publishExecution(execution, @{@"ok": @NO, @"message": reason ?: @"Data preflight is not complete; diagnostics remain available"});
            [context finish]; retireInternalExecution(execution); return;
        }
        // The durable pre-mutation marker may block in filesystem I/O. Keep it
        // outside the receipt lock so deadlines and inspection remain reachable.
        began = [context beginWork:&startError];
        @synchronized (sExecutions) {
            if (execution.published) {
                if (began) [context endWork];
                [context finishWhenQuiescent];
                return;
            }
            execution.started = began;
        }
        if (began) {
            [context performBlock:^{
                @try {
                    NSError *stageError = nil;
                    if ([context check:&stageError]) block();
                    else completeRequest(request, NO, stageError.localizedDescription ?: @"Operation cannot start", @{});
                    NSDictionary *staged;
                    @synchronized (sExecutions) { staged = execution.result; }
                    if ([@[@"launchContainer", @"launchSelectedContainer", @"selectContainer"] containsObject:request[@"action"]] && ![staged[@"ok"] boolValue]) {
                        BOOL closed = [RBXNetworkGate closeTrafficWithReason:@"launch request failed"] != nil;
                        BOOL stopped = [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
                        if (!closed || !stopped) {
                            fenceRequest(execution, @"Failed launch cleanup could not be proven; recovery is required.");
                            [context cancelWithReason:@"Failed launch cleanup could not be proven"];
                        }
                    }
                }
                @catch (NSException *exception) {
                    completeRequest(request, NO, [NSString stringWithFormat:
                        @"Operation failed (%@); review diagnostics before retrying.", exception.name], @{});
                    [context cancelWithReason:@"Operation raised an exception"];
                }
                @finally {
                    if (context.cancelled) startCancellationCleanup(execution);
                    @synchronized (sExecutions) { execution.bodyFinished = YES; }
                    [context endWork];
                }
            }];
        } else completeRequest(request, NO, startError.localizedDescription ?: @"Operation cannot start", @{});
        @synchronized (sExecutions) { execution.bodyFinished = YES; }
        BOOL quiet = [context waitForQuiescence:context.remainingTime];
        [context check:nil];
        if (!quiet || ![context sealCompletedWork]) {
            [context cancelWithReason:@"Whole-operation deadline expired before all callbacks finished"];
            startCancellationCleanup(execution);
            quiet = [context waitForQuiescence:2.0];
        }
        NSDictionary *result;
        @synchronized (sExecutions) {
            if (!quiet) fenceRequest(execution,
                @"Outstanding work or cancellation cleanup survived its deadline; further mutations require recovery.");
            result = execution.result ?: @{@"ok": @NO, @"message": @"Operation ended without a completed result"};
        }
        if (context.cancelled || !quiet) {
            NSMutableDictionary *failed = [operationFailure(context, @"Operation canceled") mutableCopy];
            failed[@"details"] = @{@"stage": @"deadline", @"operationToken": context.token,
                @"recovery": [RBXOperationContext safetyFenceStatus] ?: @{}};
            result = failed;
        }
        publishExecution(execution, result);
        if (quiet) { [context finish]; retireInternalExecution(execution); }
    });
}

static NSDictionary *waitForOperationReply(void (^start)(void (^)(NSDictionary *))) {
    RBXOperationContext *context = [RBXOperationContext currentContext];
    if (![context check:nil]) return operationFailure(context, @"Operation cannot continue");
    NSMutableDictionary *box = [NSMutableDictionary dictionary];
    dispatch_semaphore_t wait = dispatch_semaphore_create(0);
    NSString *wakeToken = [context registerCancellationHandler:^{ dispatch_semaphore_signal(wait); }];
    @try {
    start(^(NSDictionary *result) {
        @synchronized (box) {
            if ([context check:nil] && [result isKindOfClass:NSDictionary.class]) box[@"result"] = result;
        }
        dispatch_semaphore_signal(wait);
    });
    if (dispatch_semaphore_wait(wait, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(context.remainingTime * NSEC_PER_SEC))) != 0) {
        [context cancelWithReason:@"A service exceeded the whole-operation deadline"];
        return operationFailure(context, @"Service operation timed out");
    }
    @synchronized (box) { return box[@"result"] ?: operationFailure(context, @"Service operation canceled"); }
    } @finally { [context unregisterCancellationHandler:wakeToken]; }
}

static void dispatchRequest(NSDictionary *request, dispatch_block_t block) {
    dispatchOwnedRequest(request, block, NO);
}

static NSDictionary *waitForCloudOperation(void (^start)(void (^)(BOOL, NSString *))) {
    return waitForOperationReply(^(void (^reply)(NSDictionary *)) {
        start(^(BOOL ok, NSString *message) {
            reply(@{@"ok": @(ok), @"message": message ?: (ok ? @"Completed" : @"Service operation failed")});
        });
    });
}

#ifndef RBX_REQUEST_EXECUTION_TESTING
static BOOL startSystemFirewallController(NSError **error) {
    return [RBXProcessController launchRegisteredBundleIdentifier:@"com.redditbox.firewall"
        expectedBundlePath:nil timeout:8.0 error:error] > 1;
}

static BOOL closeForLicense(NSError **error) {
    NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"license requires activation" error:error];
    BOOL stopped = [sProc killAllAndWait:8];
    BOOL acknowledged = generation.length && [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8];
    if (!generation.length || !stopped || !acknowledged) {
        if (error && !*error) *error = [NSError errorWithDomain:@"com.redditbox.license" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"License is locked; CLOSED traffic/process termination needs recovery"}];
        return NO;
    }
    return YES;
}

static void handleLicenseAction(NSDictionary *pending) {
    dispatchRequest(pending, ^{
        RBXLicenseGuard *guard = RBXLicenseGuard.sharedGuard;
        NSError *error = nil;
        BOOL activate = [pending[@"action"] isEqual:@"activateLicense"];
        if ((activate || !guard.isUnlocked) && !closeForLicense(&error)) {
            [RBXOperationContext.currentContext markUnsafeWithReason:error.localizedDescription ?: @"License closure could not be proven" error:nil];
            completeRequest(pending, NO, error.localizedDescription, @{@"stage": @"license-close"}); return;
        }
        if (activate) {
            [guard invalidatePendingValidation];
            NSString *server = [pending[@"serverURL"] isKindOfClass:NSString.class] ? pending[@"serverURL"] : @"";
            NSURLComponents *origin = [NSURLComponents componentsWithString:server];
            if (![origin.scheme.lowercaseString isEqual:@"https"] || !origin.host.length || origin.user || origin.password ||
                origin.query || origin.fragment || (origin.path.length && ![origin.path isEqual:@"/"])) {
                completeRequest(pending, NO, error.localizedDescription ?: @"Activation requires your HTTPS cloud origin without a path, query or credentials", @{}); return;
            }
            origin.scheme = @"https";
            origin.host = origin.host.lowercaseString;
            origin.path = @"";
            if ([origin.port isEqual:@443]) origin.port = nil;
            if (![RBXCloudSync.sharedSync setServerURL:origin.string error:&error]) {
                completeRequest(pending, NO, error.localizedDescription, @{}); return;
            }
        }
        NSDictionary *result = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            if (activate) [guard activateWithContext:RBXOperationContext.currentContext completion:done];
            else [guard validateWithContext:RBXOperationContext.currentContext completion:done];
        });
        if (![result[@"ok"] boolValue]) {
            NSError *closureError = nil;
            if (!closeForLicense(&closureError)) {
                [RBXOperationContext.currentContext markUnsafeWithReason:closureError.localizedDescription error:nil];
                completeRequest(pending, NO, closureError.localizedDescription, @{@"stage": @"license-close"}); return;
            }
        }
        completeRequest(pending, [result[@"ok"] boolValue], result[@"message"] ?: @"License validation completed", @{@"license": guard.safeStatus});
    });
}

static void scheduleLicenseCheck(void) {
    if (!dataReady()) return;
    if (![RBXOperationContext checkSafetyFence:nil]) return;
    RBXLicenseGuard *guard = RBXLicenseGuard.sharedGuard;
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXNetworkGate.leasePath];
    BOOL active = [@[@"armed", @"open"] containsObject:lease[@"state"] ?: @""];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    // Active sessions check at most every 60 seconds. Idle devices use the
    // 24-hour validation schedule. Retry/backoff never extends signed grace.
    BOOL activeDue = active && now - sLastActiveLicenseCheck >= 60;
    NSDictionary *status = guard.safeStatus;
    // First-run activation is explicit. Missing local prerequisites must not
    // turn the idle timer into repeated CLOSED writes and process enumeration.
    if (!active && (![status[@"paired"] boolValue] || ![status[@"serverURL"] length])) return;
    if ([status[@"retryAt"] doubleValue] > now && (!active || guard.isUnlocked)) return;
    if (!guard.validationDue && !activeDue && (!active || guard.isUnlocked)) return;
    @synchronized (sExecutions) {
        if (sLicenseCheckQueued) return;
        sLicenseCheckQueued = YES;
    }
    sLastActiveLicenseCheck = now;
    NSDictionary *request = @{@"requestId": NSUUID.UUID.UUIDString, @"action": @"validateLicense", @"internalLicenseCheck": @YES};
    handleLicenseAction(request);
}

static void handleLaunchContainer(NSDictionary *pending) {
    if (![pending isKindOfClass:[NSDictionary class]]) return;
    NSString *action = pending[@"action"];
    NSString *container = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : nil;
    if (![@[@"launchContainer", @"launchSelectedContainer"] containsObject:action] || !container.length) {
        completeRequest(pending, NO, @"A container ID is required", @{@"stage": @"request"});
        return;
    }


    dispatchRequest(pending, ^{
        NSError *replacementError = nil;
        if (![RBXReplacement launchAllowedForContainer:container error:&replacementError]) {
            completeRequest(pending, NO, replacementError.localizedDescription, @{@"stage": @"replacement"}); return;
        }
        if (![RBXLauncherState refreshBeforeLaunchWithRegistry:sRegistry]) {
            completeRequest(pending, NO, @"Safety status refresh did not finish. Retry after checking Diagnostics.", @{@"stage":@"safety-refresh"}); return;
        }
        NSString *isolationBlock = RBXIsolationLaunchBlock(RBXCentralStore.sharedStore.dictionary,container);
        if (isolationBlock) {
            completeRequest(pending, NO, isolationBlock, @{@"stage":@"isolation-alert"}); return;
        }
        NSString *generation = NSUUID.UUID.UUIDString;
        NSString *previousExitIP = [RBXNetworkGate lastExitIP];
        [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
            NSMutableDictionary *entry = [doc[@"containers"][container] mutableCopy];
            if (entry) {
                entry[@"launchState"] = @"switching";
                entry[@"launchRequestedAt"] = @(NSDate.date.timeIntervalSince1970);
                doc[@"containers"][container] = entry;
            }
        }];
        [RBXLauncherState publishWithRegistry:sRegistry];
        NSLog(@"redditboxd: CONTAINER OPEN REQUEST container=%@ generation=%@",
              container, [generation substringToIndex:8]);

        // Ordering invariant: revoke every process lease before killing sockets,
        // and verify all old traffic owners are gone before rotation is called.
        NSString *closedGeneration =
            [RBXNetworkGate closeTrafficWithReason:@"container switch started"];
        if (!closedGeneration.length) {
            completeRequest(pending, NO, @"Could not persist CLOSED; clone launch cancelled", @{@"stage": @"close-lease"});
            return;
        }
        if (![sProc killAllAndWait:8.0]) {
            NSLog(@"redditboxd: switch aborted before rotation Ă˘â‚¬â€ť old process survived");
            completeRequest(pending, NO, @"Could not prove every previous app process stopped", @{@"stage": @"stop-processes", @"generation": generation});
            return;
        }
        if (![RBXNetworkGate waitForSystemFirewallState:@"closed" container:nil
                                             generation:closedGeneration timeout:8.0]) {
            NSLog(@"redditboxd: switch aborted before rotation Ă˘â‚¬â€ť system firewall not closed");
            completeRequest(pending, NO, @"Per-app firewall is not ready or did not acknowledge CLOSED. Complete Firewall Setup in Settings.", @{@"stage": @"close-firewall", @"generation": generation});
            return;
        }

        RBXOperationContext *context = [RBXOperationContext currentContext];
        NSDictionary *license = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            [[RBXLicenseGuard sharedGuard] validateWithContext:context completion:done];
        });
        if (![license[@"ok"] boolValue]) {
            completeRequest(pending, NO, license[@"message"], @{@"stage": @"license", @"generation": generation});
            return;
        }
        NSDictionary *authorization = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            [[RBXCloudSync sharedSync] syncRotationAuthForContainer:container context:context completion:done];
        });
        if (![authorization[@"ok"] boolValue]) {
            completeRequest(pending, NO, authorization[@"message"],
                @{@"stage": @"rotation-authorization", @"generation": generation});
            return;
        }

        NSError *profileError = nil;
        NSDictionary *profile =
            [sRegistry validatedProfileForContainer:container error:&profileError];
        if (!profile) {
            NSLog(@"redditboxd: container %@ remains blocked: %@",
                  container, profileError.localizedDescription);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Profile validation failed", @{@"stage": @"profile", @"generation": generation});
            return;
        }
        if (![sRegistry ensureAppCloneForContainer:container error:&profileError]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť clone provisioning failed (%@)",
                  container, profileError.localizedDescription);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Clone provisioning failed", @{@"stage": @"provision", @"generation": generation});
            return;
        }
        profile = [sRegistry validatedProfileForContainer:container error:&profileError];
        if (!profile) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť cloned profile invalid (%@)",
                  container, profileError.localizedDescription);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Provisioned profile is invalid", @{@"stage": @"profile-after-provision", @"generation": generation});
            return;
        }
        NSDictionary *appDescriptor = RBXAppDescriptorForProfile(profile);
        RBXCloneManager *clones = appDescriptor ? [[RBXCloneManager alloc]
            initWithAppType:appDescriptor[@"appType"] operationContext:context] : nil;
        if (![clones validateCloneForProfile:profile error:&profileError]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť app clone invalid (%@)",
                  container, profileError.localizedDescription);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Clone validation failed", @{@"stage": @"clone-validation", @"generation": generation});
            return;
        }
        if (![clones verifyManagedInstallationForProfile:profile error:&profileError]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť managed VPN eligibility unverified (%@)",
                  container, profileError.localizedDescription);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Managed VPN assignment is unverified", @{@"stage": @"managed-installation", @"generation": generation});
            return;
        }
        NSString *bundleIdentifier = profile[@"app"][@"bundleIdentifier"];

        NSDictionary *rotation = waitForOperationReply(^(void (^reply)(NSDictionary *)) {
            [sProxies rotateAndActivateProfile:profile previousExitIP:previousExitIP
                generation:generation context:context completion:^(BOOL ok, NSString *ip, NSString *message) {
                reply(@{@"ok": @(ok), @"exitIP": ip ?: @"", @"message": message ?: @"Proxy validation failed"});
            }];
        });
        if (![rotation[@"ok"] boolValue]) {
            completeRequest(pending, NO, rotation[@"message"], @{@"stage": @"rotate-proxy", @"generation": generation});
            return;
        }
        NSString *exitIP = rotation[@"exitIP"];

        NSDictionary *updatedProfile =
            [sRegistry validatedProfileForContainer:container error:&profileError];
        NSString *proxyURL = updatedProfile[@"proxy"][@"url"];
        if (!updatedProfile || !proxyURL.length ||
            ![RBXAppDescriptorForProfile(updatedProfile) isEqual:appDescriptor] ||
            ![updatedProfile[@"containerId"] isEqual:container] ||
            ![updatedProfile[@"app"][@"bundleIdentifier"] isEqual:bundleIdentifier]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť rotated profile invalid", container);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Rotated profile has no usable proxy", @{@"stage": @"rotated-profile", @"generation": generation});
            return;
        }
        NSString *existingDataContainer = [clones
            dataContainerForBundleIdentifier:updatedProfile[@"app"][@"bundleIdentifier"]];
        if (existingDataContainer.length &&
            ![clones syncProfile:updatedProfile error:&profileError]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť cannot refresh clone profile (%@)",
                  container, profileError.localizedDescription);
            completeRequest(pending, NO, profileError.localizedDescription ?: @"Cannot refresh the clone profile", @{@"stage": @"sync-profile", @"generation": generation});
            return;
        }
        NSError *socketError = nil;
        if (![sProc verifyNoAppSocketsForInterval:1.0 error:&socketError]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť socket table changed before arm",
                  container);
            completeRequest(pending, NO, socketError.localizedDescription ?: @"Could not prove old sockets drained", @{@"stage": @"socket-drain", @"generation": generation});
            return;
        }
        // LIFE-019: record irreversible identity use before a process can be
        // launched or any lease can become ARMED/OPEN. Failed later launch
        // steps retain the marker; lastActiveAt still means successful OPEN.
        NSError *freezeError = nil;
        if (!RBXFreezeIdentityBeforeLaunch([RBXCentralStore sharedStore], container, &freezeError)) {
            [RBXNetworkGate closeTrafficWithReason:@"identity freeze publication failed"];
            completeRequest(pending, NO, freezeError.localizedDescription ?: @"Could not durably freeze identity",
                @{@"stage": @"identity-freeze", @"generation": generation});
            return;
        }
        NSError *leaseError = nil;
        if (![RBXNetworkGate armTrafficForContainer:container
                                   bundleIdentifier:bundleIdentifier
                                           proxyURL:proxyURL
                                             exitIP:exitIP
                                         generation:generation
                                              error:&leaseError]) {
            NSLog(@"redditboxd: container %@ remains blocked Ă˘â‚¬â€ť cannot arm proxy (%@)",
                  container, leaseError.localizedDescription);
            completeRequest(pending, NO, leaseError.localizedDescription ?: @"Could not persist ARMED lease", @{@"stage": @"arm-lease", @"generation": generation});
            return;
        }
        if (![RBXNetworkGate waitForSystemFirewallState:@"armed" container:container
                                             generation:generation timeout:8.0]) {
            [RBXNetworkGate closeTrafficWithReason:@"system firewall arm failed"];
            completeRequest(pending, NO, @"The firewall did not acknowledge the ARMED lease", @{@"stage": @"arm-firewall", @"generation": generation});
            return;
        }
        NSError *launchError = nil;
        if (![sProc launchCloneForProfile:updatedProfile error:&launchError]) {
            [RBXNetworkGate closeTrafficWithReason:@"launch failed"];
            completeRequest(pending, NO, launchError.localizedDescription ?: @"The clone could not be launched", @{@"stage": @"launch-process", @"generation": generation});
            return;
        }
        NSTimeInterval syncDeadline = NSProcessInfo.processInfo.systemUptime + MIN(8.0, context.remainingTime);
        BOOL cloneStateReady = NO;
        do {
            NSError *syncError = nil;
            cloneStateReady =
                [clones syncProfile:updatedProfile error:&syncError] &&
                [RBXNetworkGate syncCurrentLeaseToProfile:updatedProfile error:&syncError] &&
                [RBXNetworkGate syncFirewallStatusToProfile:updatedProfile error:&syncError];
            if (!cloneStateReady) [NSThread sleepForTimeInterval:0.05];
        } while (!cloneStateReady && [context check:nil] && NSProcessInfo.processInfo.systemUptime < syncDeadline);
        if (!cloneStateReady) {
            [RBXNetworkGate closeTrafficWithReason:@"clone local state unavailable"];
            [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            completeRequest(pending, NO, @"The clone did not receive its profile and closed control state", @{@"stage": @"clone-control", @"generation": generation});
            return;
        }
        if (![RBXNetworkGate waitForHookReadinessForProfile:updatedProfile
                                               expectedPID:sProc.activeClonePID
                                                generation:generation
                                                    timeout:8.0]) {
            [RBXNetworkGate closeTrafficWithReason:@"hook readiness failed"];
            [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            completeRequest(pending, NO, @"Mandatory hook readiness was not verified", @{@"stage": @"hook-readiness", @"generation": generation});
            return;
        }
        if (![RBXLauncherState refreshBeforeLaunchWithRegistry:sRegistry]) {
            [RBXNetworkGate closeTrafficWithReason:@"safety refresh timed out before OPEN"];
            [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            completeRequest(pending, NO, @"Safety status could not be refreshed before opening.", @{@"stage":@"safety-refresh"}); return;
        }
        isolationBlock = RBXIsolationLaunchBlock(RBXCentralStore.sharedStore.dictionary,container);
        if (isolationBlock) {
            [RBXNetworkGate closeTrafficWithReason:@"isolation finding before OPEN"];
            [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            completeRequest(pending, NO, isolationBlock, @{@"stage":@"isolation-alert"}); return;
        }
        if (![RBXNetworkGate openTrafficForContainer:container
                                    bundleIdentifier:bundleIdentifier
                                            proxyURL:proxyURL
                                              exitIP:exitIP
                                          generation:generation
                                               error:&leaseError]) {
            [RBXNetworkGate closeTrafficWithReason:@"lease open failed"];
            [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            completeRequest(pending, NO, leaseError.localizedDescription ?: @"The firewall did not authorize OPEN", @{@"stage": @"open-lease", @"generation": generation});
            return;
        }
        if (![RBXNetworkGate syncCurrentLeaseToProfile:updatedProfile error:&leaseError] ||
            ![RBXNetworkGate syncFirewallStatusToProfile:updatedProfile error:&leaseError]) {
            [RBXNetworkGate closeTrafficWithReason:@"clone-local open lease failed"];
            [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
            completeRequest(pending, NO, leaseError.localizedDescription ?: @"Could not deliver the OPEN lease to the clone", @{@"stage": @"open-clone-control", @"generation": generation});
            return;
        }
        [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
            NSMutableDictionary *entry = [doc[@"containers"][container] mutableCopy];
            if (entry) {
                entry[@"lastActiveAt"] = @(NSDate.date.timeIntervalSince1970);
                entry[@"launchState"] = @"open";
                [entry removeObjectForKey:@"launchError"];
                doc[@"containers"][container] = entry;
            }
        }];
        completeRequest(pending, YES, @"Container opened", @{@"stage": @"open", @"generation": generation, @"containerId": container});
    });
}

static void darwinCallback(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object,
                           CFDictionaryRef userInfo) {
    scheduleRequestDrain();
}

static void onRedditExit(NSDictionary *identity, NSString *reason) {
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXNetworkGate.leasePath];
    BOOL sameLease = YES;
    for (NSString *key in @[@"containerId", @"bundleIdentifier", @"generation", @"bootEpoch"])
        sameLease = sameLease && ((identity[key] == nil && lease[key] == nil) || [identity[key] isEqual:lease[key]]);
    // An old observation must never close a newer profile's lease.
    if (!sameLease && lease && ![lease[@"state"] isEqual:@"closed"]) return;
    NSError *error = nil;
    if (![RBXNetworkGate closeTrafficWithReason:reason error:&error])
        NSLog(@"redditboxd: exit closure failed: %@", error.localizedDescription);
    // SGATE-002: an exited app must not leave a selected home/executable open.
    if (![sProc killAllAndWait:RBXGlobalProcessStopBudget()]) NSLog(@"redditboxd: storage/process closure after app exit requires recovery");
    NSString *container = identity[@"containerId"];
    [sProxies deactivateProxyForContainer:container];
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *entry = [doc[@"containers"][container ?: @""] mutableCopy];
        if (entry) { entry[@"launchState"] = @"closed"; doc[@"containers"][container] = entry; }
    }];
    [RBXLauncherState publishWithRegistry:sRegistry];
}

// Feature 4/5 Ă˘â‚¬â€ť dashboard doorbells. "rotate" marks the current container dead
// (done in prefs) and asks for a fresh one; we create it, assign an A/B group,
// and launch it. "healthCheck" is handled by RBXHealthChecker's own observer.
static void handleRotate(NSDictionary *pending) {
    if (![pending isKindOfClass:[NSDictionary class]]) return;
    NSString *action = pending[@"action"];
    if (![action isEqualToString:@"createContainer"]) return;

    NSString *from = pending[@"from"];
    if (![from isKindOfClass:[NSString class]]) from = @"default";

    NSError *err = nil;
    NSDictionary *sourceProfile = [sRegistry validatedProfileForContainer:from error:&err];
    NSString *country = sourceProfile[@"proxy"][@"country"];
    if (![country isKindOfClass:[NSString class]] || country.length == 0) country = @"US";
    NSString *proxyURL = @""; // single upstream comes from secure rotation config

    NSString *newId = [from stringByAppendingFormat:@"-%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *created = [sRegistry createContainerWithId:newId
                                            proxyCountry:country
                                                proxyURL:proxyURL
                                                nickname:nil
                                                   error:&err];
    if (!created) {
        NSLog(@"redditboxd: rotate Ă˘â‚¬â€ť create failed: %@", err.localizedDescription);
        completeRequest(pending, NO, err.localizedDescription ?: @"Could not create the replacement container", @{@"stage": @"create"});
        return;
    }
    NSLog(@"redditboxd: rotated %@ -> %@ (group %@)", from, created, [RBXABTestFramework groupForContainer:created]);

    NSMutableDictionary *launch = [pending mutableCopy];
    launch[@"container"] = created;
    launch[@"action"] = @"launchContainer";
    @try { handleLaunchContainer(launch); }
    @catch (NSException *exception) {
        completeRequest(launch, NO, @"Replacement clone launch failed during its transition", @{@"stage": @"launch-exception"});
    }

}

// UI-003: bind a review to its exact source, selected proxy and cloud account.
// Credentials stay in daemon memory; this dictionary never crosses IPC.
static NSDictionary *creationDraftBinding(NSString *appType, NSError **error) {
    if (!RBXAppDescriptorForType(appType)) return nil;
    RBXCloneManager *clones = [[RBXCloneManager alloc] initWithAppType:appType
        operationContext:RBXOperationContext.currentContext];
    NSDictionary *source = [clones creationSourceBinding];
    NSDictionary *configuration = [RBXSecureConfig rotationConfiguration:error];
    if (!source || ![[clones sourceStatus][@"decrypted"] boolValue] || !configuration || [configuration[@"proxyDisabled"] boolValue]) {
        if (error && !*error) *error = RBXCreationDraftError(@"Import a valid source and configure the selected proxy before preparing a container.");
        return nil;
    }
    return @{@"source":source, @"proxy":configuration,
        @"cloud":RBXCloudSync.sharedSync.serverURL ?: @"", @"account":RBXCloudSync.sharedSync.deviceToken ?: @""};
}
static NSDictionary *creationDraftForRequest(NSDictionary *pending, BOOL exactRevision, NSError **error) {
    NSString *app = pending[@"appType"] ?: @"reddit";
    NSNumber *revision = pending[@"creationDraftRevision"];
    if (exactRevision && (![revision isKindOfClass:NSNumber.class] || revision.unsignedIntegerValue == 0)) {
        if (error) *error = RBXCreationDraftError(@"Reload the preview before continuing."); return nil;
    }
    return RBXCreationGetDraft(sCreationDrafts, pending[@"creationDraftToken"], pending[@"container"], app,
        exactRevision ? revision : nil, creationDraftBinding(app, error), NSDate.date.timeIntervalSince1970, error);
}
static void handleCreationDraftAction(NSDictionary *pending) {
    dispatchRequest(pending, ^{
        NSError *error = nil;
        NSString *action = pending[@"action"], *app = pending[@"appType"] ?: @"reddit";
        if (!sCreationDrafts) sCreationDrafts = [NSMutableDictionary dictionary];
        if ([action isEqual:@"prepareContainer"]) {
            NSString *cid = pending[@"container"], *name = pending[@"nickname"], *role = pending[@"role"] ?: @"default";
            NSString *country = [pending[@"country"] isKindOfClass:NSString.class] ? [pending[@"country"] uppercaseString] : @"";
            if (![RBXProfileIO isSafeContainerIdentifier:cid] || !RBXProfileNicknameValid(name) ||
                ![RBXProfileRoles() containsObject:role] || ![sRegistry canCreateContainerForAppType:app error:&error]) {
                completeRequest(pending, NO, error.localizedDescription ?: @"Enter a container name and valid creation options.", @{}); return;
            }
            NSDictionary *binding = creationDraftBinding(app, &error);
            if (!binding) { completeRequest(pending, NO, error.localizedDescription, @{}); return; }
            // UI-003: the simple wizard selects before enqueue. Reject a proxy
            // changed while waiting before any outbound geography lookup.
            // Older callers omit this additive expectation; their established
            // source/config/account binding and post-lookup checks still apply.
            id expectedProxyRevision = pending[@"proxyConfigurationUpdatedAt"];
            if (expectedProxyRevision && (![expectedProxyRevision isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)expectedProxyRevision) == CFBooleanGetTypeID() ||
                !isfinite([expectedProxyRevision doubleValue]) || [expectedProxyRevision doubleValue] <= 0 ||
                ![expectedProxyRevision isEqual:binding[@"proxy"][@"updatedAt"]])) {
                completeRequest(pending, NO, @"The selected proxy changed while preparation was waiting. Choose its current configuration and prepare again.", @{}); return;
            }
            NSDictionary *region = waitForOperationReply(^(void (^reply)(NSDictionary *)) {
                [sProxies detectRegionForContainer:nil context:RBXOperationContext.currentContext completion:reply];
            });
            if (![region[@"ok"] isEqual:@YES] || (country.length && ![country isEqual:region[@"country"]])) {
                completeRequest(pending, NO, [region[@"ok"] isEqual:@YES] ?
                    @"The requested country does not match the selected proxy. Choose Auto or a matching proxy." :
                    region[@"message"] ?: @"Could not verify the selected proxy. No container was created.", @{}); return;
            }
            country = region[@"country"];
            NSDictionary *envelope = [sRegistry prepareCreationForContainer:cid appType:app proxyCountry:country regionSuggestion:region error:&error];
            if (!envelope || ![RBXOperationContext.currentContext check:&error] || ![binding isEqual:creationDraftBinding(app, &error)]) {
                completeRequest(pending, NO, error.localizedDescription ?: @"Source or proxy changed during preparation. Prepare again.", @{}); return;
            }
            NSDictionary *metadata = @{@"container":cid, @"nickname":name, @"role":role, @"country":country, @"appType":app};
            NSDictionary *record = RBXCreationStoreDraft(sCreationDrafts, envelope, metadata, binding, NSDate.date.timeIntervalSince1970, &error);
            completeRequest(pending, record != nil, record ? @"Preview ready. Review or edit it, then Create. Nothing has been created yet." : error.localizedDescription,
                record ? RBXCreationPublicReview(record) : @{});
            return;
        }
        NSDictionary *record = creationDraftForRequest(pending, ![action isEqual:@"reviewContainerDraft"], &error);
        if (!record) { completeRequest(pending, NO, error.localizedDescription, @{}); return; }
        if ([action isEqual:@"discardContainerDraft"]) {
            [sCreationDrafts removeObjectForKey:record[@"token"]];
            completeRequest(pending, YES, @"Draft discarded. No container was created.", @{}); return;
        }
        if ([action isEqual:@"reviewContainerDraft"]) {
            completeRequest(pending, YES, @"Review the prepared values before Create.", RBXCreationPublicReview(record)); return;
        }
        NSDictionary *envelope = record[@"envelope"];
        if ([action isEqual:@"randomizeIdentityEditor"]) {
            // Generation always starts with the same verified proxy region. It
            // replaces only this unsaved draft, never an existing container.
            // The registry's existing model/OS choice path also regenerates IDs.
            NSDictionary *selection = [pending[@"selection"] isKindOfClass:NSDictionary.class] ? pending[@"selection"] : @{};
            NSMutableDictionary *choices = [selection mutableCopy];
            [choices removeObjectForKey:@"automatic"];
            choices[@"mode"] = @"random";
            envelope = [sRegistry creationProfileByApplyingChoices:choices toPreparedProfile:envelope error:&error];
            record = envelope ? RBXCreationUpdateDraft(sCreationDrafts, record, envelope, &error) : nil;
        } else if ([@[@"previewIdentity", @"applyIdentity"] containsObject:action]) {
            NSDictionary *choices = [pending[@"choices"] isKindOfClass:NSDictionary.class] ? pending[@"choices"] : @{};
            envelope = [sRegistry creationProfileByApplyingChoices:choices toPreparedProfile:envelope error:&error];
            if ([action isEqual:@"applyIdentity"] && envelope) record = RBXCreationUpdateDraft(sCreationDrafts, record, envelope, &error);
            BOOL ok = envelope && record && [RBXOperationContext.currentContext check:&error];
            NSMutableDictionary *details = ok ? [RBXCreationPublicReview(record) mutableCopy] : [NSMutableDictionary dictionary];
            details[@"applied"] = @([action isEqual:@"applyIdentity"] && ok);
            if (ok) details[@"summary"] = envelope[@"review"];
            completeRequest(pending, ok, ok ? ([action isEqual:@"applyIdentity"] ? @"Draft updated. Return to the preview and tap Create to make the container." : @"Draft values are consistent. Nothing has been created.") : error.localizedDescription, details);
            return;
        }
        NSDictionary *privateDraft = record ? [sRegistry creationIdentityEditorDraftForProfile:envelope[@"profile"] error:&error] : nil;
        BOOL ok = privateDraft && [RBXOperationContext.currentContext check:&error] &&
            [RBXSecureConfig saveIdentityEditorDraft:privateDraft requestID:pending[@"requestId"] error:&error];
        NSMutableDictionary *details = ok ? [RBXCreationPublicReview(record) mutableCopy] : [NSMutableDictionary dictionary];
        details[@"draftReady"] = @(ok);
        completeRequest(pending, ok, ok ? @"Prepared identity ready for review" : error.localizedDescription, details);
    });
}

static void handleContainerAction(NSDictionary *pending) {
    if (![pending isKindOfClass:[NSDictionary class]]) return;
    NSString *action = pending[@"action"];
    if (!([action isEqualToString:@"createContainer"] ||
          [action isEqualToString:@"deleteContainer"] ||
          [action isEqualToString:@"updateMetadata"] ||
          [action isEqualToString:@"replaceContainer"] ||
          [action isEqualToString:@"discardMetadataChanges"])) return;

    if ([action isEqual:@"createContainer"]) {
        NSError *admissionError = nil;
        if (![sRegistry canCreateContainerForAppType:pending[@"appType"] ?: @"reddit" error:&admissionError]) {
            completeRequest(pending, NO, admissionError.localizedDescription, @{});
            return;
        }
    }
    dispatchRequest(pending, ^{
        NSError *actionError = nil;
        if ([action isEqual:@"replaceContainer"]) {
            NSString *cid = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : @"";
            NSString *created = [RBXReplacement replaceContainer:cid registry:sRegistry proxies:sProxies
                context:[RBXOperationContext currentContext] error:&actionError];
            publishLauncherOperation(pending, action, created ?: cid, created.length > 0,
                created.length ? @"Replacement committed with fresh identity. Re-adopt the new clone in MDM before opening; Open rotates again."
                : actionError.localizedDescription ?: @"Replacement incomplete. Original data and recovery journal retained; retry Replace.");
            return;
        }
        if ([action isEqual:@"updateMetadata"] || [action isEqual:@"discardMetadataChanges"]) {
            NSString *cid = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : @"";
            BOOL ok = [action isEqual:@"updateMetadata"]
                ? [sRegistry updateMetadata:pending forContainer:cid local:YES error:&actionError]
                : [sRegistry discardMetadataChangesForContainer:cid error:&actionError];
            publishLauncherOperation(pending, action, cid, ok,
                ok ? @"Metadata saved. Refresh to synchronize with cloud." : actionError.localizedDescription);
            return;
        }
        if ([action isEqualToString:@"createContainer"]) {
            NSDictionary *preparedRecord = nil;
            NSDictionary *creationInput = pending;
            if (pending[@"creationDraftToken"]) {
                preparedRecord = creationDraftForRequest(pending, YES, &actionError);
                if (!preparedRecord) { completeRequest(pending, NO, actionError.localizedDescription, @{}); return; }
                creationInput = preparedRecord[@"metadata"];
            }
            NSString *role = creationInput[@"role"] ?: @"default";
            NSString *notes = creationInput[@"notes"] ?: @"";
            if (![RBXProfileRoles() containsObject:role] || !RBXProfileNotesValid(notes)) {
                completeRequest(pending, NO, @"Invalid role or notes longer than 200 characters", @{}); return;
            }
            NSString *cid = creationInput[@"container"];
            NSString *country = creationInput[@"country"];
            NSString *proxyURL = @"";
            NSString *nickname = creationInput[@"nickname"];
            if (![cid isKindOfClass:[NSString class]]) cid = nil;
            if (![country isKindOfClass:[NSString class]] || country.length == 0) country = @"US";
            if (![nickname isKindOfClass:[NSString class]]) nickname = cid;
            NSDictionary *region = nil;
            if (!preparedRecord && [pending[@"autoRegion"] isEqual:@YES]) {
                region = waitForOperationReply(^(void (^reply)(NSDictionary *)) {
                    [sProxies detectRegionForContainer:nil context:RBXOperationContext.currentContext completion:reply];
                });
                if (![region[@"ok"] boolValue]) {
                    publishLauncherOperation(pending, action, cid, NO, region[@"message"] ?: @"Could not detect proxy region. No container was created."); return;
                }
                country = region[@"country"];
            }
            // Consume before side effects. An interrupted commit must reconcile
            // its durable request, never silently replay this prepared identity.
            if (preparedRecord) [sCreationDrafts removeObjectForKey:preparedRecord[@"token"]];
            NSString *created = [sRegistry createContainerWithId:cid appType:pending[@"appType"] ?: @"reddit"
                                                    proxyCountry:country
                                                        proxyURL:proxyURL
                                                        nickname:nickname
                                                regionSuggestion:region
                                                 preparedProfile:preparedRecord[@"envelope"]
                                                           error:&actionError];
            if (!created) {
                NSLog(@"redditboxd: createContainer failed: %@", actionError.localizedDescription);
                publishLauncherOperation(pending, @"createContainer", cid, NO,
                    actionError.localizedDescription);
            } else {
                if (![sRegistry updateMetadata:@{@"role": role, @"notes": notes}
                    forContainer:created local:YES error:&actionError]) {
                    publishLauncherOperation(pending, action, created, NO,
                        actionError.localizedDescription); return;
                }
                // A licensed device is paired. Publish the new identity before
                // Open asks for rotation credentials under the H17 binding.
                // A cloud failure retains the successfully created local clone.
                NSString *message = region ? [NSString stringWithFormat:
                    @"Container created from proxy region %@ (%@). Carrier %@ is a suggested profile. Adopt the clone in MDM before Open.",
                    region[@"country"], region[@"timezone"], region[@"carrierName"]] :
                    @"Container and hidden clone created. Adopt the clone in MDM before Open.";
                if (RBXCloudSync.sharedSync.paired) {
                    NSDictionary *inventory = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
                        [RBXCloudSync.sharedSync syncProfileInventoryWithContext:RBXOperationContext.currentContext completion:done];
                    });
                    if (![inventory[@"ok"] boolValue]) message = [NSString stringWithFormat:
                        @"Container created locally; cloud inventory synchronization is pending. Use Refresh before Open. %@",
                        inventory[@"message"] ?: @"Cloud synchronization did not complete."];
                }
                publishLauncherOperation(pending, @"createContainer", created, YES, message);
                [RBXLauncherState publishWithRegistry:sRegistry];
            }
        } else {
            NSString *cid = pending[@"container"];
            if (![cid isKindOfClass:[NSString class]] || !cid.length) {
                completeRequest(pending, NO, @"A container ID is required", @{}); return;
            }
            if (![RBXReplacement userDeletionAllowedForContainer:cid error:&actionError] ||
                ![sRegistry deleteContainer:cid error:&actionError]) {
                NSLog(@"redditboxd: deleteContainer failed: %@", actionError.localizedDescription);
                publishLauncherOperation(pending, @"deleteContainer", cid, NO,
                    actionError.localizedDescription);
            } else {
                publishLauncherOperation(pending, @"deleteContainer", cid, YES,
                    @"Container deleted locally. Refresh cloud inventory to reconcile any saved cloud deletion intent.");
                [RBXLauncherState publishWithRegistry:sRegistry];
            }
        }
    });
}

static void rotateDarwinCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    scheduleRequestDrain();
}

static void containerActionDarwinCallback(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object,
                                          CFDictionaryRef userInfo) {
    scheduleRequestDrain();
}

static void loginActivityDarwinCallback(CFNotificationCenterRef center, void *observer,
                                        CFStringRef name, const void *object,
                                        CFDictionaryRef userInfo) {
    NSString *container = [[NSString stringWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.activeContainer"
        encoding:NSUTF8StringEncoding error:nil]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSError *error = nil;
    NSDictionary *profile = container.length
        ? [sRegistry validatedProfileForContainer:container error:&error] : nil;
    NSString *bundleIdentifier = profile[@"app"][@"bundleIdentifier"];
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    RBXCloneManager *manager = descriptor ? [[RBXCloneManager alloc]
        initWithAppType:descriptor[@"appType"] operationContext:RBXOperationContext.currentContext] : nil;
    NSString *dataContainer = bundleIdentifier.length
        ? [manager dataContainerForBundleIdentifier:bundleIdentifier] : nil;
    NSDictionary *marker = dataContainer.length
        ? [NSDictionary dictionaryWithContentsOfFile:[dataContainer
            stringByAppendingPathComponent:
                @"Library/Preferences/com.redditbox.login-status.plist"]] : nil;
    NSTimeInterval timestamp = [marker[@"lastLoginAt"] doubleValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (![marker[@"containerId"] isEqualToString:container] ||
        ![marker[@"bundleIdentifier"] isEqualToString:bundleIdentifier] ||
        timestamp < now - 600 || timestamp > now + 60) return;
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *entry = [doc[@"containers"][container] mutableCopy];
        if (entry) {
            entry[@"lastLoginAt"] = @(timestamp);
            doc[@"containers"][container] = entry;
        }
    }];
    [RBXLauncherState publishWithRegistry:sRegistry];
}

static void publishLauncherCloudStatus(NSDictionary *pending, BOOL ok, NSString *message) {
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *device = [doc[@"device"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        device[@"launcherCloudStatus"] = @{
            @"ok": @(ok),
            @"paired": @([[RBXCloudSync sharedSync] paired]),
            @"serverHost": [NSURL URLWithString:
                [RBXCloudSync sharedSync].serverURL].host ?: @"",
            @"message": message ?: (ok ? @"Cloud paired and synchronized" :
                @"Cloud operation failed"),
            @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        };
        doc[@"device"] = device;
    }];
    completeRequest(pending, ok, message,
        [[RBXCentralStore sharedStore] dictionary][@"device"][@"launcherCloudStatus"]);
}

static void publishLauncherOperation(NSDictionary *pending, NSString *action, NSString *containerId,
                                     BOOL ok, NSString *message) {
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *device = [doc[@"device"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        device[@"launcherOperation"] = @{
            @"requestId": pending[@"requestId"] ?: @"",
            @"action": action ?: @"",
            @"containerId": containerId ?: @"",
            @"ok": @(ok),
            @"message": message ?: (ok ? @"Operation completed" : @"Operation failed"),
            @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        };
        if ([pending[@"appType"] isEqual:@"facebook"]) {
            NSMutableDictionary *scoped = [device[@"launcherOperation"] mutableCopy];
            scoped[@"appType"] = @"facebook";
            device[@"launcherOperation"] = scoped;
        }
        doc[@"device"] = device;
    }];
    NSDictionary *details = [pending[@"appType"] isEqual:@"facebook"]
        ? @{@"containerId":containerId ?: @"", @"appType":@"facebook"} : @{@"containerId":containerId ?: @""};
    completeRequest(pending, ok, message, details);
}

static void publishIdentityResult(NSDictionary *pending, NSString *containerId, NSString *requestId,
                                  BOOL ok, BOOL applied, NSDictionary *preview,
                                  NSString *message) {
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *device = [doc[@"device"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        device[@"launcherIdentityResult"] = @{
            @"containerId": containerId ?: @"",
            @"requestId": requestId ?: @"",
            @"ok": @(ok),
            @"applied": @(applied),
            @"message": message ?: (ok ? @"Identity is coherent" :
                @"Identity is inconsistent"),
            @"summary": [preview[@"summary"] isKindOfClass:[NSDictionary class]]
                ? preview[@"summary"] : @{},
            @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        };
        if ([pending[@"appType"] isEqual:@"facebook"]) {
            NSMutableDictionary *scoped = [device[@"launcherIdentityResult"] mutableCopy];
            scoped[@"appType"] = @"facebook";
            device[@"launcherIdentityResult"] = scoped;
        }
        doc[@"device"] = device;
    }];
    completeRequest(pending, ok, message,
        [[RBXCentralStore sharedStore] dictionary][@"device"][@"launcherIdentityResult"]);
}

// Private input binding. These values never enter a draft or public receipt.
static NSDictionary *automaticIdentityInput(NSString *container, NSError **error) {
    NSDictionary *profile = [RBXProfileIO loadProfileForContainer:container error:error];
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    NSDictionary *state = profile ? [sRegistry identityEditorStateForContainer:container error:error] : nil;
    if (!state || ![descriptor[@"runnable"] boolValue] || [state[@"locked"] boolValue]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"com.redditbox.identity" code:423 userInfo:
                @{NSLocalizedDescriptionKey:@"Automatic fill requires an available, unused container identity. No draft was changed."}];
        }
        return nil;
    }
    NSDictionary *selected = @{};
    if (![profile[@"proxy"][@"url"] length]) {
        NSDictionary *configuration = [RBXSecureConfig rotationConfiguration:error];
        if (!configuration) return nil;
        selected = [RBXSecureConfig effectiveRotationConfiguration:configuration];
    }
    return @{@"profile":profile, @"selectedConfiguration":selected ?: @{}};
}

static NSDictionary *identityEditorDraftForRequest(NSDictionary *pending, NSError **error) {
    NSString *container = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : @"";
    NSDictionary *selection = [pending[@"selection"] isKindOfClass:NSDictionary.class] ? pending[@"selection"] : nil;
    id value = selection[@"automatic"];
    if (value && (![value isKindOfClass:NSNumber.class] || (![value isEqual:@YES] && ![value isEqual:@NO]))) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox.identity" code:400 userInfo:
                @{NSLocalizedDescriptionKey:@"Automatic draft selection must be a boolean."}];
        }
        return nil;
    }
    BOOL randomize = [pending[@"action"] isEqual:@"randomizeIdentityEditor"];
    if (![value isEqual:@YES]) return [sRegistry privateIdentityEditorDraftForContainer:container randomize:randomize selection:selection error:error];
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!randomize || ![context check:error]) return nil;
    NSDictionary *before = automaticIdentityInput(container,error);
    if (!before) return nil;
    NSDictionary *region = waitForOperationReply(^(void (^reply)(NSDictionary *)) {
        [sProxies detectRegionForContainer:container context:context completion:reply];
    });
    if (![context check:error]) return nil;
    if (![region[@"ok"] isEqual:@YES]) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox.identity" code:422 userInfo:
                @{NSLocalizedDescriptionKey:region[@"message"] ?: @"The actual proxy region could not be verified. No draft was changed."}];
        }
        return nil;
    }
    NSDictionary *current = automaticIdentityInput(container,error);
    if (![before isEqual:current]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"com.redditbox.identity" code:409 userInfo:
                @{NSLocalizedDescriptionKey:@"The profile or selected proxy changed during automatic fill. Reload and retry; no draft was changed."}];
        }
        return nil;
    }
    NSDictionary *draft = [sRegistry privateIdentityEditorDraftForContainer:container randomize:YES
        selection:selection regionSuggestion:region error:error];
    if (!draft || ![context check:error]) return nil;
    current = automaticIdentityInput(container,error);
    if (![before isEqual:current]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"com.redditbox.identity" code:409 userInfo:
                @{NSLocalizedDescriptionKey:@"Automatic fill inputs changed before publication. No draft was changed; retry with the current proxy."}];
        }
        return nil;
    }
    return draft;
}

static void handleLauncherAction(NSDictionary *pending) {
    NSString *action = pending[@"action"];
    if ([action isEqualToString:@"openFirewall"]) {
        NSError *error = nil;
        BOOL opened = startSystemFirewallController(&error);
        completeRequest(pending, opened, opened ? @"Firewall setup opened" :
            (error.localizedDescription ?: @"Could not open firewall setup"), @{});
        return;
    }
    if ([action isEqualToString:@"import-source"]) {
        dispatchRequest(pending, ^{
            NSError *error = nil;
            NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"source IPA import" error:&error];
            BOOL closed = [sProc killAllAndWait:8.0] &&
                [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0];
            NSString *path = [pending[@"ipaPath"] isKindOfClass:NSString.class] ? pending[@"ipaPath"] : @"";
            NSDictionary *descriptor = RBXAppDescriptorForType(pending[@"appType"]);
            RBXCloneManager *importer = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
                operationContext:RBXOperationContext.currentContext];
            BOOL ok = closed && [importer importSourceIPA:path error:&error];
            [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                NSMutableDictionary *device = [doc[@"device"] mutableCopy] ?: [NSMutableDictionary dictionary];
                NSDictionary *importResult = @{@"requestId": pending[@"requestId"] ?: @"",
                    @"ok": @(ok), @"completedAt": @(NSDate.date.timeIntervalSince1970),
                    @"message": ok ? @"Decrypted source imported into private storage. You can now create profiles." :
                        (error.localizedDescription ?: @"Could not prove previous session closed")};
                if ([descriptor[@"appType"] isEqual:@"reddit"]) device[@"launcherSourceImport"] = importResult;
                else {
                    NSMutableDictionary *imports = [device[@"launcherSourceImports"] mutableCopy] ?: [NSMutableDictionary dictionary];
                    NSMutableDictionary *scoped = [importResult mutableCopy];
                    scoped[@"appType"] = descriptor[@"appType"];
                    if (ok) scoped[@"message"] = @"Source imported. Facebook remains inactive until its binary and lifecycle audit passes.";
                    imports[descriptor[@"appType"]] = scoped; device[@"launcherSourceImports"] = imports;
                }
                doc[@"device"] = device;
            }];
            NSDictionary *deviceResult = [[RBXCentralStore sharedStore] dictionary][@"device"];
            NSDictionary *result = [descriptor[@"appType"] isEqual:@"reddit"] ? deviceResult[@"launcherSourceImport"] :
                deviceResult[@"launcherSourceImports"][descriptor[@"appType"]];
            completeRequest(pending, ok, result[@"message"], result);
        });
        return;
    }
    if ([action isEqualToString:@"archiveSource"]) {
        dispatchRequest(pending, ^{
            NSString *generation =
                [RBXNetworkGate closeTrafficWithReason:@"archive visible source app"];
            NSError *error = nil;
            BOOL closed = [sProc killAllAndWait:8.0] &&
                [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0];
            NSDictionary *descriptor = RBXAppDescriptorForType(pending[@"appType"]);
            RBXCloneManager *manager = descriptor ? [[RBXCloneManager alloc]
                initWithAppType:descriptor[@"appType"] operationContext:RBXOperationContext.currentContext] : nil;
            BOOL archived = closed && [manager archiveSourceAndRemoveVisibleApp:&error];
            NSLog(@"redditboxd: source archive %@ (%@)",
                  archived ? @"complete" : @"failed",
                  error.localizedDescription ?: (closed ? @"no detail" : @"network not closed"));
            publishLauncherOperation(pending, @"archiveSource", @"", archived,
                archived ? @"Source app archived and hidden" :
                    (error.localizedDescription ?: @"Network could not be closed"));
        });
        return;
    }
    if ([action isEqualToString:@"configurationChanged"]) {
        dispatchRequest(pending, ^{
            NSString *generation =
                [RBXNetworkGate closeTrafficWithReason:@"proxy configuration changed"];
            if (![sProc killAllAndWait:8.0] ||
                ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0]) {
                publishLauncherOperation(pending, action, @"", NO, @"Could not prove traffic owners terminated");
                return;
            }
            [[RBXLicenseGuard sharedGuard] invalidatePendingValidation];
            NSDictionary *license = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
                [[RBXLicenseGuard sharedGuard] validateWithContext:[RBXOperationContext currentContext] completion:done];
            });
            if (![[RBXOperationContext currentContext] check:nil]) {
                completeRequest(pending, NO, license[@"message"], @{});
                return;
            }
            completeRequest(pending, YES, @"Configuration reloaded; clone traffic remains closed", @{});
        });
        return;
    }
    if ([action isEqualToString:@"detectProxyRegion"]) {
        dispatchRequest(pending, ^{
            NSString *container = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : nil;
            NSDictionary *result = waitForOperationReply(^(void (^reply)(NSDictionary *)) {
                [sProxies detectRegionForContainer:container context:RBXOperationContext.currentContext completion:reply];
            });
            completeRequest(pending, [result[@"ok"] boolValue], result[@"message"], result);
        });
        return;
    }
    if ([action isEqualToString:@"testConfiguration"]) {
        dispatchRequest(pending, ^{
            [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                NSMutableDictionary *device=[doc[@"device"] mutableCopy] ?: [NSMutableDictionary dictionary];
                device[@"launcherConfigurationTest"]=@{@"ok":@NO,@"pending":@YES,
                    @"testedAt":@(NSDate.date.timeIntervalSince1970),
                    @"message":@"A new proxy test is running. Previous success is no longer current."};
                doc[@"device"]=device;
            }];
            [RBXLauncherState publishWithRegistry:sRegistry];
            NSString *generation =
                [RBXNetworkGate closeTrafficWithReason:@"proxy configuration test"];
            BOOL clean = [sProc killAllAndWait:8.0] &&
                [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0];
            if (!clean) {
                [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                    NSMutableDictionary *device = [doc[@"device"] mutableCopy]
                        ?: [NSMutableDictionary dictionary];
                    device[@"launcherConfigurationTest"] = @{
                        @"ok": @NO,
                        @"message": @"Could not prove the previous network session closed",
                        @"testedAt": @(NSDate.date.timeIntervalSince1970),
                    };
                    doc[@"device"] = device;
                }];
                completeRequest(pending, NO, @"Could not prove the previous network session closed",
                    [[RBXCentralStore sharedStore] dictionary][@"device"][@"launcherConfigurationTest"]);
                return;
            }
            NSDictionary *configurationBefore = [RBXSecureConfig rotationConfiguration:nil];
            NSMutableDictionary *result = [waitForOperationReply(^(void (^reply)(NSDictionary *)) {
                [sProxies testCurrentConfigurationWithContext:[RBXOperationContext currentContext] completion:reply];
            }) mutableCopy];
            NSDictionary *configurationAfter = [RBXSecureConfig rotationConfiguration:nil];
            if (!configurationBefore || ![configurationBefore isEqual:configurationAfter]) {
                result[@"ok"] = @NO;
                result[@"message"] = @"Proxy settings changed during the test. Test the selected configuration again.";
            } else if ([configurationBefore[@"updatedAt"] isKindOfClass:NSNumber.class]) {
                result[@"configurationUpdatedAt"] = configurationBefore[@"updatedAt"];
            }
            if ([[RBXOperationContext currentContext] check:nil]) {
                [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                    NSMutableDictionary *device = [doc[@"device"] mutableCopy] ?: [NSMutableDictionary dictionary];
                    device[@"launcherConfigurationTest"] = result;
                    doc[@"device"] = device;
                }];
            }
            completeRequest(pending, [result[@"ok"] boolValue], result[@"message"], result);
        });
        return;
    }
    if ([action isEqualToString:@"runDiagnostics"]) {
        dispatchRequest(pending, ^{
            NSDictionary *report = [RBXDiagnostics runWithRegistry:sRegistry];
            completeRequest(pending, [report[@"ok"] boolValue], @"Diagnostics completed", report);
        });
        return;
    }
    if ([action isEqualToString:@"exportSupportLog"]) {
        dispatchRequest(pending, ^{
            NSDictionary *result = [RBXDiagnostics exportSupportLog];
            completeRequest(pending, [result[@"ok"] boolValue], result[@"message"], result);
        });
        return;
    }
    if ([action isEqualToString:@"exportCloneIPA"]) {
        NSString *containerId = [pending[@"container"] isKindOfClass:[NSString class]]
            ? pending[@"container"] : @"";
        dispatchRequest(pending, ^{
            NSString *generation =
                [RBXNetworkGate closeTrafficWithReason:@"export clone IPA"];
            NSError *error = nil;
            BOOL clean = [sProc killAllAndWait:8.0] &&
                [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0];
            NSDictionary *profile = clean
                ? [sRegistry validatedProfileForContainer:containerId error:&error] : nil;
            NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
            RBXCloneManager *clones = descriptor ? [[RBXCloneManager alloc]
                initWithAppType:descriptor[@"appType"] operationContext:RBXOperationContext.currentContext] : nil;
            NSString *path = profile ? [clones exportIPAForProfile:profile error:&error] : nil;
            [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                NSMutableDictionary *device = [doc[@"device"] mutableCopy]
                    ?: [NSMutableDictionary dictionary];
                device[@"launcherCloneExport"] = @{
                    @"ok": @(path.length > 0),
                    @"containerId": containerId,
                    @"path": path ?: @"",
                    @"generatedAt": @(NSDate.date.timeIntervalSince1970),
                    @"message": path.length ? @"Clone IPA ready to share" :
                        (error.localizedDescription ?: @"Could not safely export clone"),
                };
                if ([pending[@"appType"] isEqual:@"facebook"]) {
                    NSMutableDictionary *scoped = [device[@"launcherCloneExport"] mutableCopy];
                    scoped[@"appType"] = @"facebook";
                    device[@"launcherCloneExport"] = scoped;
                }
                doc[@"device"] = device;
            }];
            NSDictionary *result = [[RBXCentralStore sharedStore] dictionary][@"device"][@"launcherCloneExport"];
            completeRequest(pending, path.length > 0, result[@"message"], result);
        });
        return;
    }
    if ([action isEqualToString:@"configureCloud"]) {
        NSString *serverURL = [pending[@"serverURL"] isKindOfClass:[NSString class]]
            ? pending[@"serverURL"] : @"";
        NSString *pairingCode = [pending[@"pairingCode"] isKindOfClass:[NSString class]]
            ? pending[@"pairingCode"] : @"";
        NSError *serverError = nil;
        [[RBXLicenseGuard sharedGuard] invalidatePendingValidation];
        if (![[RBXCloudSync sharedSync] setServerURL:serverURL error:&serverError]) {
            publishLauncherCloudStatus(pending, NO,
                serverError.localizedDescription ?: @"Invalid cloud server");
            return;
        }
        NSDictionary *paired = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            [[RBXCloudSync sharedSync] pairWithCode:pairingCode context:[RBXOperationContext currentContext] completion:done];
        });
        if (![paired[@"ok"] boolValue]) {
            publishLauncherCloudStatus(pending, NO, paired[@"message"]); return;
        }
        NSDictionary *configured = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            [[RBXCloudSync sharedSync] syncLauncherConfigurationWithContext:[RBXOperationContext currentContext] completion:done];
        });
        if (![configured[@"ok"] boolValue]) {
            publishLauncherCloudStatus(pending, NO, configured[@"message"]); return;
        }
        NSDictionary *inventory = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            [[RBXCloudSync sharedSync] syncProfileInventoryWithContext:[RBXOperationContext currentContext] completion:done];
        });
        publishLauncherCloudStatus(pending, [inventory[@"ok"] boolValue],
            [inventory[@"ok"] boolValue] ? @"Cloud paired and synchronized" : inventory[@"message"]);
        return;
    }

    if ([action isEqualToString:@"appVersionConfigurationChanged"]) {
        [sVersionMonitor startMonitoring];
        completeRequest(pending, YES, @"Version monitor settings reloaded", @{});
        return;
    }
    if ([action isEqual:@"configureIsolationSentinel"]) {
        dispatchRequest(pending, ^{
            NSError *error = nil;
            NSString *container = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : @"";
            NSDictionary *settings = [pending[@"settings"] isKindOfClass:NSDictionary.class] ? RBXSentinelSettings(pending[@"settings"]) : nil;
            BOOL valid = settings && dataReady() && ![RBXOperationContext safetyFenceStatus] &&
                [RBXProfileIO loadProfileForContainer:container error:&error] != nil;
            BOOL ok = valid && [RBXCentralStore.sharedStore update:^(NSMutableDictionary *doc) {
                NSMutableDictionary *containers = [doc[@"containers"] mutableCopy];
                NSMutableDictionary *entry = [containers[container] mutableCopy] ?: [NSMutableDictionary dictionary];
                entry[@"isolationSentinel"] = settings;
                containers[container] = entry; doc[@"containers"] = containers;
            } error:&error];
            completeRequest(pending,ok,ok ? @"Sentinel settings saved. Reopen this clone after enabling. Identity and network policy were not changed." :
                error.localizedDescription ?: @"Sentinel settings unavailable. Use an interval of 1–1440 minutes after resolving recovery.",@{});
        });
        return;
    }
    if ([@[@"loadIdentityEditor", @"randomizeIdentityEditor"] containsObject:action]) {
        NSString *container = [pending[@"container"] isKindOfClass:NSString.class] ? pending[@"container"] : @"";
        dispatchRequest(pending, ^{
            NSError *error = nil;
            NSDictionary *draft = identityEditorDraftForRequest(pending, &error);
            BOOL ok = draft && [RBXOperationContext.currentContext check:&error] &&
                [RBXSecureConfig saveIdentityEditorDraft:draft requestID:pending[@"requestId"] error:&error];
            // Only readiness and ownership metadata go to the durable/public result.
            NSDictionary *details = [pending[@"appType"] isEqual:@"facebook"]
                ? @{@"containerId":container, @"draftReady":@(ok), @"appType":@"facebook"}
                : @{@"containerId":container, @"draftReady":@(ok)};
            completeRequest(pending, ok, ok ? @"Identity details ready" : error.localizedDescription ?: @"Identity could not be loaded", details);
        });
        return;
    }
    if ([action isEqualToString:@"previewIdentity"] ||
        [action isEqualToString:@"applyIdentity"]) {
        NSString *containerId = [pending[@"container"] isKindOfClass:[NSString class]]
            ? pending[@"container"] : @"";
        NSString *requestId = [pending[@"requestId"] isKindOfClass:[NSString class]]
            ? pending[@"requestId"] : @"";
        NSDictionary *choices = [pending[@"choices"] isKindOfClass:[NSDictionary class]]
            ? pending[@"choices"] : @{};
        BOOL apply = [action isEqualToString:@"applyIdentity"];
        dispatchRequest(pending, ^{
            NSError *error = nil;
            if (apply) {
                NSString *generation =
                    [RBXNetworkGate closeTrafficWithReason:@"identity update"];
                BOOL clean = [sProc killAllAndWait:8.0] &&
                    [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0];
                BOOL ok = clean && [sRegistry applyIdentityChoices:choices
                    toContainer:containerId error:&error];
                publishIdentityResult(pending, containerId, requestId, ok, ok, nil,
                    ok ? @"Identity applied. The clone remains network-blocked until opened." :
                        (error.localizedDescription ?:
                            @"Could not prove the previous session closed"));
            } else {
                NSDictionary *preview = [sRegistry previewIdentityChoices:choices
                    forContainer:containerId error:&error];
                publishIdentityResult(pending, containerId, requestId, preview != nil, NO,
                    preview, preview[@"message"] ?: error.localizedDescription);
            }
        });
        return;
    }
    if (![action isEqualToString:@"refreshLauncher"]) {
        completeRequest(pending, NO, @"Unsupported launcher action", @{}); return;
    }
    if (!dataReady()) {
        completeRequest(pending, YES, @"Local state refreshed; data preflight must succeed before cloud synchronization or mutations.", @{});
        return;
    }
    NSDictionary *recovery = [RBXOperationContext safetyFenceStatus];
    if (recovery) {
        completeRequest(pending, YES, @"Local state refreshed; a previous operation needs recovery before further changes.",
            @{@"recovery": recovery});
        return;
    }
    if (![[RBXCloudSync sharedSync] paired]) {
        completeRequest(pending, YES, @"Local launcher state refreshed. Activate a device license to connect cloud management.", @{}); return;
    }
    NSError *beforeError = nil;
    NSDictionary *configurationBefore = [RBXSecureConfig rotationConfiguration:&beforeError];
    if (beforeError) {
        NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"secure proxy settings unreadable"];
        BOOL closed = [sProc killAllAndWait:8.0] &&
            [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0];
        completeRequest(pending, NO, closed ? @"Secure proxy settings could not be read; the session was closed" :
            @"Secure proxy settings could not be read and closure could not be verified", @{}); return;
    }
    NSDictionary *inventory = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
        [[RBXCloudSync sharedSync] syncProfileInventoryWithContext:[RBXOperationContext currentContext] completion:done];
    });
    NSDictionary *configuration = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
        [[RBXCloudSync sharedSync] syncLauncherConfigurationWithContext:[RBXOperationContext currentContext] completion:done];
    });
    NSError *afterError = nil;
    NSDictionary *configurationAfter = [RBXSecureConfig rotationConfiguration:&afterError];
    BOOL changed = ![[RBXSecureConfig effectiveRotationConfiguration:configurationBefore]
        isEqualToDictionary:[RBXSecureConfig effectiveRotationConfiguration:configurationAfter]];
    if (beforeError || afterError || ([configuration[@"ok"] boolValue] && changed)) {
        NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"cloud proxy configuration changed"];
        if (![sProc killAllAndWait:8.0] ||
            ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0]) {
            completeRequest(pending, NO, @"Cloud settings changed, but closure could not be proven", @{}); return;
        }
    }
    if (beforeError || afterError) {
        completeRequest(pending, NO, @"Secure proxy settings could not be compared; the session was closed", @{}); return;
    }
    BOOL ok = [inventory[@"ok"] boolValue] && [configuration[@"ok"] boolValue];
    completeRequest(pending, ok, ok ? @"Launcher refreshed" :
        (![inventory[@"ok"] boolValue] ? inventory[@"message"] : configuration[@"message"]), @{});
}

static void handleSelectContainer(NSDictionary *pending) {
    NSString *container = pending[@"container"], *appType = pending[@"appType"] ?: @"reddit";
    __block NSError *error = nil;
    __block BOOL persistedPending = NO;
    BOOL (^valid)(void) = ^BOOL {
        if (![RBXOperationContext.currentContext check:&error] ||
            ![RBXReplacement launchAllowedForContainer:container error:&error]) return NO;
        NSDictionary *profile = [sRegistry validatedProfileForContainer:container error:&error];
        return profile && !RBXAppRequestBlockReason(pending, @[profile]);
    };
    if (!RBXCanonicalProfileIdentifier(container) || !valid()) {
        completeRequest(pending, NO, error.localizedDescription ?: @"Select an available container for this app.", @{}); return;
    }
    BOOL ok = RBXSelectWorkspace(appType, container, pending[@"requestId"],
        ^BOOL(NSDictionary *record) {
            if (![RBXOperationContext.currentContext check:&error]) return NO;
            BOOL written = [RBXCentralStore.sharedStore update:^(NSMutableDictionary *doc) {
                NSMutableDictionary *device = [doc[@"device"] mutableCopy] ?: [NSMutableDictionary dictionary];
                device[@"workspaceSelection"] = record; doc[@"device"] = device;
            } error:&error];
            if (written && [record[@"phase"] isEqual:@"switching"]) persistedPending = YES;
            [RBXLauncherState publishWithRegistry:sRegistry];
            return written;
        }, ^BOOL {
            NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"workspace selection" error:&error];
            BOOL stopped = [sProc killAllAndWait:8.0];
            return generation.length && stopped &&
                [RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0] &&
                [sProc verifyNoAppSocketsForInterval:1.0 error:&error];
        }, valid);
    if (!ok && !persistedPending) {
        // A failed initial write must not leave the previous selection usable.
        [RBXOperationContext.currentContext markUnsafeWithReason:@"Workspace selection could not be persisted; review recovery before opening." error:nil];
    }
    completeRequest(pending, ok, ok ? @"Container selected. Use Open in SocialBox when ready; network checks still apply." :
        error.localizedDescription ?: @"Switch not completed. Traffic stays closed; retry after reviewing setup.",
        @{@"containerId":container ?: @"", @"selectionConfirmed":@(ok)});
}

// UI visibility is not authorization. Check the signed grant at the daemon
// boundary before profile reads, cloud synchronization, drafts or mutations.
static BOOL authorizeQueuedRequest(NSDictionary *pending) {
    id action = pending[@"action"];
    if (![action isKindOfClass:NSString.class] || ![action length]) {
        completeRequest(pending, NO, @"This request has no valid action.", @{@"code": @"invalid-action"});
        return NO;
    }
    // These paths either obtain a grant, close traffic, or inspect diagnostics.
    // A locked device must still be able to activate and recover safely.
    if ([@[@"activateLicense", @"validateLicense", @"configurationChanged",
           @"runDiagnostics", @"exportSupportLog"] containsObject:action]) return YES;
    if ([[RBXLicenseGuard sharedGuard] isUnlocked]) return YES;
    if ([action isEqualToString:@"refreshLauncher"]) {
        // The normal refresh also synchronizes cloud configuration. While
        // locked, publish only local state; never enter that mutation path.
        completeRequest(pending, YES, @"Local state refreshed. Activate SocialBox to continue.",
            @{@"code": @"license-required", @"localOnly": @YES});
        return NO;
    }
    completeRequest(pending, NO, @"Activate SocialBox with a valid device license before using this feature.",
        @{@"code": @"license-required"});
    return NO;
}

static void handleQueuedRequest(NSDictionary *pending) {
    if (!authorizeQueuedRequest(pending)) return;
    if ([pending[@"action"] isEqual:@"launchSelectedContainer"]) {
        NSString *selected = RBXWorkspaceSelectedID(RBXCentralStore.sharedStore.dictionary[@"device"][@"workspaceSelection"], pending[@"appType"] ?: @"reddit");
        if (!selected || pending[@"container"] || pending[@"containerId"] || pending[@"from"]) {
            completeRequest(pending, NO, @"Choose a container in SocialBox and wait for switching to finish first.", @{}); return;
        }
        NSMutableDictionary *resolved = pending.mutableCopy;
        resolved[@"container"] = selected; pending = resolved;
    }
    // Check the persisted owner before any dispatch, mutation or network work.
    NSMutableArray *scopedProfiles = [NSMutableArray array];
    for (NSString *key in @[@"container", @"containerId", @"from"]) {
        id identifier = pending[key];
        if (![RBXProfileIO isSafeContainerIdentifier:identifier]) continue;
        NSDictionary *profile = [RBXProfileIO loadProfileForContainer:identifier error:nil];
        if (!profile) profile = [RBXProfileIO readProfileOwnershipForContainer:identifier error:nil];
        if (profile) [scopedProfiles addObject:profile];
    }
    NSString *appBlock = RBXAppRequestBlockReason(pending, scopedProfiles);
    if (appBlock) { completeRequest(pending, NO, appBlock, @{}); return; }
    NSString *action = pending[@"action"];
    if ([@[@"prepareContainer", @"reviewContainerDraft", @"discardContainerDraft"] containsObject:action] ||
        (pending[@"creationDraftToken"] && [@[@"loadIdentityEditor", @"randomizeIdentityEditor", @"previewIdentity", @"applyIdentity"] containsObject:action])) {
        handleCreationDraftAction(pending); return;
    }
    if ([@[@"activateLicense", @"validateLicense"] containsObject:action]) handleLicenseAction(pending);
    else if ([action isEqualToString:@"selectContainer"]) handleSelectContainer(pending);
    else if ([@[@"launchContainer", @"launchSelectedContainer"] containsObject:action]) handleLaunchContainer(pending);
    else if ([action isEqualToString:@"createContainer"] && pending[@"from"]) handleRotate(pending);
    else if ([@[@"createContainer", @"deleteContainer", @"updateMetadata", @"discardMetadataChanges", @"replaceContainer"] containsObject:action])
        handleContainerAction(pending);
    else if ([@[@"pair", @"export", @"importNewest", @"importById", @"regeneratePassphrase", @"cloudVaultList", @"cloudVaultKey", @"cloudVaultSetKey", @"cloudVaultRestore", @"cloudVaultDelete"] containsObject:action]) {
        NSDictionary *result = waitForCloudOperation(^(void (^done)(BOOL, NSString *)) {
            [[RBXCloudSync sharedSync] handleQueuedAction:pending context:[RBXOperationContext currentContext] completion:done];
        });
        completeRequest(pending, [result[@"ok"] boolValue], result[@"message"], result);
    } else handleLauncherAction(pending);
}

static void scheduleRequestDrain(void) {
    if (!sIPCQueue || !sRequests) return;
    dispatch_async(sIPCQueue, ^{
        NSError *error = nil;
        if (![sRequests retryPendingResultsAndRecoverAbandonedClaims:&error]) {
            NSLog(@"redditboxd: request recovery pending: %@", error.localizedDescription); return;
        }
        for (NSUInteger count = 0; count < 64; count++) {
            NSDictionary *request = [sRequests claimNextRequest:&error];
            if (!request) {
                if (error) NSLog(@"redditboxd: request claim failed: %@", error.localizedDescription);
                break;
            }
            dispatchRequest(request, ^{ handleQueuedRequest(request); });
        }
    });
}

static void launcherActionDarwinCallback(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    scheduleRequestDrain();
}

static BOOL recordAppliedUpdate(NSError **error) {
    NSData *bytes = [NSData dataWithContentsOfFile:RBXInstalledPath(@"/usr/share/redditbox/release.json") options:0 error:error];
    NSDictionary *release = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:error] : nil;
    NSString *version = [release isKindOfClass:NSDictionary.class] && [release[@"version"] isKindOfClass:NSString.class] ? release[@"version"] : @"";
    if ([version rangeOfString:@"^(0|[1-9][0-9]{0,3})\\.(0|[1-9][0-9]{0,3})\\.(0|[1-9][0-9]{0,3})$" options:NSRegularExpressionSearch].location == NSNotFound ||
        ![release[@"schemaVersion"] isEqual:RBXDataMigration.currentVersions[@"store"]] ||
        ![release[@"packageScheme"] isEqual:RBXInstalledScheme()]) {
        if (error && !*error) *error = [NSError errorWithDomain:@"com.redditbox.update" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Installed release metadata is missing or inconsistent; update application could not be recorded"}];
        return NO;
    }
    NSArray *identifiers = [sRegistry containerIdsWithError:error];
    NSDictionary *store = [RBXCentralStore.sharedStore dictionaryWithError:error];
    if (!identifiers || !store) return NO;
    NSDictionary *previousUpdate = [store[@"device"][@"lastAppliedUpdate"] isKindOfClass:NSDictionary.class]
        ? store[@"device"][@"lastAppliedUpdate"] : @{};
    if ([previousUpdate[@"version"] isEqual:version] && [previousUpdate[@"packageScheme"] isEqual:RBXInstalledScheme()]) return YES;
    NSString *message = [NSString stringWithFormat:@"update applied: v%@, containers loaded: %lu", version, (unsigned long)identifiers.count];
    NSDictionary *record = @{@"version": version, @"packageScheme": RBXInstalledScheme(), @"containersLoaded": @(identifiers.count),
        @"appliedAt": @(NSDate.date.timeIntervalSince1970), @"message": message,
        @"requiresMDMReadoption": @([release[@"requiresMDMReadoption"] boolValue])};
    BOOL saved = [RBXCentralStore.sharedStore update:^(NSMutableDictionary *document) {
        NSMutableDictionary *device = [document[@"device"] mutableCopy] ?: [NSMutableDictionary dictionary];
        device[@"lastAppliedUpdate"] = record; document[@"device"] = device;
    } error:error];
    if (saved) {
        NSLog(@"redditboxd: %@", message);
        if ([record[@"requiresMDMReadoption"] boolValue]) NSLog(@"redditboxd: release requires MDM re-adoption; verify each clone association before opening");
    }
    return saved;
}

static int runCommand(int argc, char *argv[]) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            if ([command isEqualToString:@"provision-clone"] && ![[RBXLicenseGuard sharedGuard] isUnlocked]) {
                fprintf(stderr, "activate SocialBox with a valid device license before provisioning clones\n");
                return 1;
            }
            RBXContainerRegistry *registry = [RBXContainerRegistry new];
            if ([command isEqualToString:@"provision-clone"] && argc >= 3) {
                NSString *generation =
                    [RBXNetworkGate closeTrafficWithReason:@"clone provisioning"];
                RBXAppProcessCoordinator *processes = [RBXAppProcessCoordinator new];
                if (![processes killAllAndWait:8.0] ||
                    ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0]) {
                    fprintf(stderr, "cannot provision while app traffic is not proven closed\n");
                    return 1;
                }
                NSError *recoveryError = nil;
                if (![RBXDataMigration preflightAndMigrateWithError:&recoveryError]) {
                    fprintf(stderr, "data preflight failed: %s\n", recoveryError.localizedDescription.UTF8String); return 1;
                }
                if (![RBXCloneManager recoverAllInterruptedTransactionsWithContext:
                    [RBXOperationContext currentContext] error:&recoveryError]) {
                    fprintf(stderr, "clone recovery failed: %s\n", recoveryError.localizedDescription.UTF8String);
                    return 1;
                }
                NSString *container = [NSString stringWithUTF8String:argv[2]];
                NSString *country = argc >= 4
                    ? [NSString stringWithUTF8String:argv[3]] : @"US";
                NSError *error = nil;
                if ([[registry containerIds] containsObject:container]) {
                    if (![registry ensureAppCloneForContainer:container error:&error]) {
                        fprintf(stderr, "clone provisioning failed: %s\n",
                                error.localizedDescription.UTF8String);
                        return 1;
                    }
                } else if (![registry createContainerWithId:container
                    proxyCountry:country proxyURL:@"" nickname:container error:&error]) {
                    fprintf(stderr, "profile/clone provisioning failed: %s\n",
                            error.localizedDescription.UTF8String);
                    return 1;
                }
                printf("ready: %s -> %s\n", container.UTF8String,
                    [RBXCloneManager bundleIdentifierForContainer:container].UTF8String);
                return 0;
            }
            if ([command isEqualToString:@"migrate-clones"]) {
                NSString *generation =
                    [RBXNetworkGate closeTrafficWithReason:@"clone migration"];
                RBXAppProcessCoordinator *processes = [RBXAppProcessCoordinator new];
                if (![processes killAllAndWait:8.0] ||
                    ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:8.0]) {
                    fprintf(stderr, "cannot migrate while app traffic is not proven closed\n");
                    return 1;
                }
                NSError *error = nil;
                BOOL ok = [RBXDataMigration preflightAndMigrateWithError:&error] &&
                    [registry migrateProfilesWithError:&error] && [registry migrateAppClonesWithError:&error];
                if (!ok) fprintf(stderr, "clone migration failed: %s\n", error.localizedDescription.UTF8String);
                return ok ? 0 : 1;
            }
            fprintf(stderr,
                "usage: redditboxd provision-clone PROFILE_ID [COUNTRY] | migrate-clones\n");
            return 64;
}

int main(int argc, char *argv[]) {
    // Rootless launchd can ignore plist Jetsam overrides. Reserve a bounded
    // budget before Foundation/ZIP import work and verify the kernel's result.
    RBXMemoryLimits memoryLimits = {0};
    RBXMemoryControl memoryControl = (RBXMemoryControl)dlsym(RTLD_DEFAULT, "memorystatus_control");
    if (RBXApplyMemoryBudget(memoryControl, getpid(), 256, &memoryLimits) != 0)
        fprintf(stderr, "redditboxd: memory budget could not be configured: %s\n", strerror(errno));
    @autoreleasepool {
        if (argc >= 2) {
            RBXOperationContext *context = [RBXOperationContext contextWithRequestID:NSUUID.UUID.UUIDString
                bootEpoch:[RBXOperationContext daemonBootEpoch] timeout:600];
            NSError *error = nil;
            if (![context beginWork:&error]) {
                fprintf(stderr, "operation rejected: %s\n", error.localizedDescription.UTF8String);
                return 1;
            }
            [context registerCancellationHandler:^{
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    [RBXNetworkGate closeTrafficWithReason:@"command operation canceled"];
                    [[RBXAppProcessCoordinator new] killAllAndWait:RBXGlobalProcessStopBudget()];
                    if (![context waitForQuiescence:2.0]) [context markUnsafeWithReason:
                        @"Command recovery did not quiesce after cancellation." error:nil];
                });
            }];
            __block int status = 1;
            [context performBlock:^{
                @try { status = runCommand(argc, argv); }
                @catch (NSException *exception) { [context cancelWithReason:@"Command raised an exception"]; }
                @finally { [context endWork]; }
            }];
            BOOL quiet = [context waitForQuiescence:context.remainingTime];
            if (!quiet) {
                [context cancelWithReason:@"Command exceeded its whole-operation deadline"];
                [context markUnsafeWithReason:@"Command descendants did not stop before exit." error:nil];
            }
            if (![context check:nil] || !quiet) status = 1;
            if (quiet) [context finish];
            return status;
        }
        NSLog(@"redditboxd starting");

        sRegistry = [RBXContainerRegistry new];
        sProc = [RBXAppProcessCoordinator new];
        [RBXSentinelController setProcessIdentityProvider:^NSDictionary * { return sProc.activeCloneIdentity; }];
        sProxies = [RBXProxyManager new];
        sSwitchQueue = dispatch_queue_create("com.redditbox.proxy-switch",
                                             DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(sSwitchQueue, &sSwitchQueueKey, &sSwitchQueueKey, NULL);
        sIPCQueue = dispatch_queue_create("com.redditbox.request-inbox", DISPATCH_QUEUE_SERIAL);
        sTerminalRequests = [NSMutableSet set];
        sExecutions = [NSMutableDictionary dictionary];
        sDeadlineQueue = dispatch_queue_create("com.redditbox.request-deadlines", DISPATCH_QUEUE_CONCURRENT);
        sInspectionQueue = dispatch_queue_create("com.redditbox.recovery-inspection", DISPATCH_QUEUE_CONCURRENT);
        dispatch_queue_set_specific(sInspectionQueue, &sSwitchQueueKey, &sSwitchQueueKey, NULL);
        // The launcher stages source IPAs as mobile; source/transactions remain
        // private subdirectories. Existing root-owned parent may predate setup.
        NSString *library = @"/var/mobile/Library/RedditBox";
        NSString *inbox = [library stringByAppendingPathComponent:@"SourceInbox"];
        NSError *inboxError = nil;
        BOOL inboxOK = [NSFileManager.defaultManager createDirectoryAtPath:inbox
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700}
            error:&inboxError];
        int libraryFD = open(library.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int inboxFD = libraryFD >= 0 ? openat(libraryFD, "SourceInbox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW) : -1;
        inboxOK = inboxOK && libraryFD >= 0 && inboxFD >= 0 &&
            fchown(libraryFD, 0, 0) == 0 && fchmod(libraryFD, 0755) == 0 &&
            fchown(inboxFD, 501, 501) == 0 && fchmod(inboxFD, 0700) == 0;
        if (inboxFD >= 0) close(inboxFD);
        if (libraryFD >= 0) close(libraryFD);
        if (!inboxOK) NSLog(@"redditboxd: source import inbox unavailable: %@", inboxError);
        NSString *startupGeneration =
            [RBXNetworkGate closeTrafficWithReason:@"daemon startup default"];
        BOOL startupProcessesClosed = [sProc killAllAndWait:RBXGlobalProcessStopBudget()];
        // Keep setup IPC available while the MDM provider is being provisioned.
        // Renewal remains disabled until a CLOSED lease can be verified.
        if (startupGeneration.length) [RBXNetworkGate startDaemonHeartbeat];
        BOOL startupFirewallClosed = [RBXNetworkGate waitForMaintenanceClosure:startupGeneration timeout:8.0];
        [RBXLauncherState startPeriodicPublisherWithRegistry:sRegistry];

        sRequests = [RBXRequestQueue defaultQueue];
        NSError *queueError = nil;
        if (![sRequests prepareDaemon:&queueError])
            NSLog(@"redditboxd: request queue unavailable: %@", queueError.localizedDescription);

        // Notifications carry no payload; every one drains the same durable inbox.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, darwinCallback,
            CFSTR("com.redditbox.launchContainer"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Watch the selected app process exit for the kill switch.
        [sProc watchAppTerminationOnQueue:sSwitchQueue
            onExit:^(NSDictionary *identity, NSString *reason) { onRedditExit(identity, reason); }];

        // Background Reddit account checks are intentionally disabled: under the
        // single-link model only the currently opened container may use Reddit.

        // Feature 4/5 Ă˘â‚¬â€ť dashboard "rotate container" doorbell.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, rotateDarwinCallback,
            CFSTR("com.redditbox.rotate"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Launcher/prefs create+delete containers.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL, containerActionDarwinCallback,
            CFSTR("com.redditbox.containerAction"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            launcherActionDarwinCallback, CFSTR("com.redditbox.launcherAction"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            loginActivityDarwinCallback, CFSTR("com.redditbox.loginActivity"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Feature 7 Ă˘â‚¬â€ť SocialBox Cloud (factory/worker handoff): pairing state,
        // passphrase generation, export/import actions from the prefs Cloud pane.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            launcherActionDarwinCallback, CFSTR("com.redditbox.cloudAction"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // Only after CLOSED, IPC and notifications are ready may recovery own
        // the serial mutation queue. Its watchdog can still report a timeout
        // while an uninterruptible device service is being held for recovery.
        NSDictionary *startup = @{@"requestId": NSUUID.UUID.UUIDString, @"action": @"startupRecovery"};
        dispatchOwnedRequest(startup, ^{
            if (!startupProcessesClosed || !startupFirewallClosed) {
                completeRequest(startup, NO, @"Startup recovery requires verified CLOSED traffic and stopped clones.", @{});
                return;
            }
            NSError *recoveryError = nil;
            if (![RBXDataMigration preflightAndMigrateWithError:&recoveryError]) {
                @synchronized (sExecutions) { sDataFailure = recoveryError.localizedDescription ?: @"Data schema preflight failed; original files retained"; }
                completeRequest(startup, NO, sDataFailure, @{@"schema": RBXDataMigration.currentVersions}); return;
            }
            @synchronized (sExecutions) { sDataReady = YES; }
            BOOL recovered = [sRegistry migrateProfilesWithError:&recoveryError] &&
                [sRegistry migrateAppClonesWithError:&recoveryError];
            if (recovered) recovered = recordAppliedUpdate(&recoveryError);
            if (recovered) {
                // No background store/profile writer starts before the entire
                // schema preflight and forward migrations have succeeded.
                [[RBXCloudSync sharedSync] start];
                sVersionMonitor = [RBXAppVersionMonitor new];
                [sVersionMonitor startMonitoring];
                [[RBXLeakMonitor sharedMonitor] start];
                [[[RBXFingerprintRegistry alloc] init] refreshAndCheck];
            }
            completeRequest(startup, recovered, recovered ? @"Startup recovery completed" :
                (recoveryError.localizedDescription ?: @"Startup recovery did not complete"), @{});
        }, YES);

        // Recover claimed requests as interrupted; never replay their effects.
        // Periodic draining also covers notifications lost while apps suspend.
        static dispatch_source_t requestTimer;
        requestTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sIPCQueue);
        dispatch_source_set_timer(requestTimer, DISPATCH_TIME_NOW, NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(requestTimer, ^{ scheduleRequestDrain(); });
        dispatch_resume(requestTimer);

        // Access-key lock: validate on boot + daily; launch path re-checks above.
        [[RBXLicenseGuard sharedGuard] start];
        static dispatch_source_t licenseTimer;
        licenseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sIPCQueue);
        dispatch_source_set_timer(licenseTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
            10 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(licenseTimer, ^{ scheduleLicenseCheck(); });
        dispatch_resume(licenseTimer);

        dispatch_main();
    }
    return 0;
}
#endif
