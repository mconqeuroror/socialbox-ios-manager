#import "RBXAppProcessCoordinator.h"
#import "RBXProcessController.h"
#import "RBXOperationContext.h"
#import "RBXAppRegistry.h"
#import "RBXStorageAccess.h"
#import <limits.h>
#import <math.h>
#import <time.h>

static void RBXCoordinatorError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.process-coordinator" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSTimeInterval RBXCoordinatorMonotonicTime(void) {
    struct timespec value;
    return clock_gettime(CLOCK_MONOTONIC, &value) == 0
        ? value.tv_sec + value.tv_nsec / 1e9 : NAN;
}

static NSArray<NSString *> *RBXCoordinatorIdentityKeys(void) {
    return @[@"containerId", @"bundleIdentifier", @"executable", @"pid", @"generation", @"bootEpoch",
        @"processStartSeconds", @"processStartMicroseconds"];
}

static BOOL RBXCoordinatorValidProcessBirth(NSDictionary *identity) {
    id seconds = identity[@"processStartSeconds"], micros = identity[@"processStartMicroseconds"];
    return [seconds isKindOfClass:NSNumber.class] && [micros isKindOfClass:NSNumber.class] &&
        [seconds longLongValue] > 0 && [seconds doubleValue] == [seconds longLongValue] &&
        [micros longLongValue] >= 0 && [micros longLongValue] < 1000000 &&
        [micros doubleValue] == [micros longLongValue];
}

@implementation RBXAppProcessCoordinator {
    NSArray<NSDictionary *> *_appDescriptors;
    NSSet<NSString *> *_runnableTypes;
    NSArray<id<RBXAppProcessControlling>> *_controllers;
    NSDictionary<NSString *, id<RBXAppProcessControlling>> *_controllersByType;
    NSTimeInterval (^_clock)(void);
    id<RBXAppProcessControlling> _activeController;
    NSDictionary *_activeIdentity;
    NSString *_observerToken;
    dispatch_queue_t _watchQueue;
    void (^_onExit)(NSDictionary *, NSString *);
    BOOL _globallyDrained;
    NSString *_epoch;
    NSUInteger _launchInFlight, _stopInFlight;
}

- (instancetype)_initWithControllers:(NSArray<id<RBXAppProcessControlling>> *)controllers
                        descriptors:(NSArray<NSDictionary *> *)descriptors
                              clock:(NSTimeInterval (^)(void))clock {
    if (!controllers.count || controllers.count != descriptors.count || !clock) return nil;
    NSMutableDictionary *byType = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < descriptors.count; i++) {
        NSDictionary *descriptor = descriptors[i];
        if (!RBXAppDescriptorIsRegistered(descriptor) ||
            ![controllers[i].appDescriptor isEqual:descriptor] || byType[descriptor[@"appType"]]) return nil;
        byType[descriptor[@"appType"]] = controllers[i];
    }
    if ((self = [super init])) {
        _appDescriptors = [descriptors copy];
        _controllers = [controllers copy];
        _controllersByType = [byType copy];
        NSMutableSet *runnable=[NSMutableSet set];
        for(NSDictionary *d in descriptors)if([d[@"runnable"] boolValue])[runnable addObject:d[@"appType"]];
        _runnableTypes=[runnable copy];
        _clock = [clock copy];
        _epoch = NSUUID.UUID.UUIDString;
    }
    return self;
}

- (instancetype)init {
    NSMutableArray *descriptors = [NSMutableArray array], *controllers = [NSMutableArray array];
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        RBXProcessController *controller = [[RBXProcessController alloc] initWithAppDescriptor:descriptor];
        if (!controller) return nil;
        [descriptors addObject:descriptor]; [controllers addObject:controller];
    }
    return [self _initWithControllers:controllers descriptors:descriptors clock:^NSTimeInterval {
        return RBXCoordinatorMonotonicTime();
    }];
}

#ifdef RBX_APP_PROCESS_COORDINATOR_TESTING
- (instancetype)initWithControllers:(NSArray<id<RBXAppProcessControlling>> *)controllers
                   runnableAppTypes:(NSSet<NSString *> *)runnableAppTypes
                     monotonicClock:(NSTimeInterval (^)(void))clock {
    NSMutableArray *descriptors = [NSMutableArray array], *ordered = [NSMutableArray array];
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        if (![runnableAppTypes containsObject:descriptor[@"appType"]]) continue;
        [descriptors addObject:descriptor];
        for (id<RBXAppProcessControlling> controller in controllers)
            if ([controller.appDescriptor isEqual:descriptor]) [ordered addObject:controller];
    }
    if (descriptors.count != runnableAppTypes.count || ordered.count != controllers.count) return nil;
    RBXAppProcessCoordinator *result=[self _initWithControllers:ordered descriptors:descriptors clock:clock];
    if(result)result->_runnableTypes=[runnableAppTypes copy];
    return result;
}
#endif

- (NSArray<NSDictionary *> *)appDescriptors { return _appDescriptors; }
- (NSDictionary *)activeCloneIdentity { @synchronized (self) { return [_activeIdentity copy]; } }
- (pid_t)activeClonePID { @synchronized (self) { return [_activeIdentity[@"pid"] intValue]; } }

- (void)_cancelObserversLocked {
    _observerToken = nil;
    // Cancel the producers, not merely their consumers. The per-app observer
    // itself writes the global binding and can otherwise revoke a newer app.
    for (id<RBXAppProcessControlling> controller in _controllers)
        [controller stopWatchingAppTermination];
}

- (void)stopWatchingAppTermination {
    @synchronized (self) {
        _epoch = NSUUID.UUID.UUIDString;
        [self _cancelObserversLocked];
        _watchQueue = nil; _onExit = nil;
    }
}

- (BOOL)_epochIsCurrent:(NSString *)epoch {
    @synchronized (self) { return [_epoch isEqual:epoch] && _stopInFlight == 0; }
}

- (BOOL)_observersQuietLocked {
    for (id<RBXAppProcessControlling> controller in _controllers)
        if (controller.terminationObservationInFlight != 0) return NO;
    return YES;
}

- (BOOL)_advanceClock:(NSTimeInterval *)last deadline:(NSTimeInterval)deadline error:(NSError **)error {
    NSTimeInterval now = _clock();
    if (!isfinite(now) || now < *last || now >= deadline) {
        RBXCoordinatorError(error, @"Global process operation exhausted or lost its monotonic deadline");
        return NO;
    }
    *last = now;
    return YES;
}

- (BOOL)_startBudget:(NSTimeInterval)timeout cleanup:(BOOL)cleanup
              started:(NSTimeInterval *)started deadline:(NSTimeInterval *)deadline error:(NSError **)error {
    *started = _clock();
    if (!isfinite(timeout) || timeout <= 0 || !isfinite(*started)) {
        RBXCoordinatorError(error, @"Global process operation requires a finite positive monotonic budget"); return NO;
    }
    *deadline = *started + MIN(timeout, 30.0);
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (context && !(cleanup && context.cancelled)) {
        // Stop is cleanup, not new admission. As in the original controller,
        // an expired owner still gets the initial stop attempt, but can never
        // prove drain after its aggregate deadline. Cancelled owners use the
        // caller's explicit cleanup allowance instead of reopening admission.
        if (!cleanup && ![context check:error]) return NO;
        *deadline = MIN(*deadline, context.deadlineMonotonic);
    }
    if (!isfinite(*deadline) || *deadline <= *started) {
        RBXCoordinatorError(error, @"Global process operation has no remaining aggregate budget"); return NO;
    }
    return YES;
}

- (BOOL)killAllAndWait:(NSTimeInterval)timeout { return [self stopAllAppsAndWait:timeout error:nil]; }

- (BOOL)stopAllAppsAndWait:(NSTimeInterval)timeout error:(NSError **)error {
    NSString *epoch = NSUUID.UUID.UUIDString;
    @synchronized (self) {
        _epoch = epoch; _stopInFlight++; _globallyDrained = NO;
        _activeController = nil; _activeIdentity = nil;
        [self _cancelObserversLocked];
    }
    BOOL success = NO;
    NSError *failure = nil;
    @try {
        NSTimeInterval last, deadline;
        BOOL budgetValid = [self _startBudget:timeout cleanup:YES started:&last deadline:&deadline error:&failure];
        // Revoke launch permission before reaping, then verify closure again.
        BOOL storageClosed=[RBXStorageAccess closeAll:&failure];
        if (isfinite(timeout) && timeout > 0) {
            // No coordinator lock spans process I/O. A blocked launch/drain
            // cannot stop another thread from issuing every emergency kill.
            for (id<RBXAppProcessControlling> controller in _controllers) [controller killAppProcesses];
            success = budgetValid && storageClosed;
            if (budgetValid) for (id<RBXAppProcessControlling> controller in _controllers) {
                NSError *clockError = nil;
                if (![self _advanceClock:&last deadline:deadline error:&clockError]) {
                    success = NO; if (!failure) failure = clockError; continue;
                }
                if (![controller killAllAndWait:deadline - last]) {
                    success = NO;
                    if (!failure) RBXCoordinatorError(&failure, [NSString stringWithFormat:
                        @"Could not prove all %@ processes and sockets stopped", controller.appDescriptor[@"displayName"]]);
                }
                if (![self _advanceClock:&last deadline:deadline error:&clockError]) {
                    success = NO; if (!failure) failure = clockError;
                }
            }
        }
        if(![RBXStorageAccess closeAll:&failure])success=NO;
    } @catch (NSException *exception) {
        success = NO;
        RBXCoordinatorError(&failure, @"Global stop raised an exception; process quiescence is unproven");
        // A failed delegate does not excuse skipping later emergency stops.
        for (id<RBXAppProcessControlling> controller in _controllers) {
            @try { [controller killAppProcesses]; } @catch (NSException *ignored) { }
        }
    } @finally {
        @synchronized (self) {
            _stopInFlight--;
            BOOL current = [_epoch isEqual:epoch];
            if (!current || _stopInFlight || _launchInFlight || ![self _observersQuietLocked]) {
                success = NO;
                if (!failure) RBXCoordinatorError(&failure, @"An overlapping launch, stop or old observer has not quiesced");
            }
            if (current) _globallyDrained = success;
        }
    }
    if (!success && error) *error = failure;
    return success;
}

- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval error:(NSError **)error {
    return [self verifyNoAppSocketsForInterval:interval timeout:MAX(3.0, interval + 2.0) * _controllers.count error:error];
}

- (BOOL)_verifyControllersForInterval:(NSTimeInterval)interval timeout:(NSTimeInterval)timeout
                              epoch:(NSString *)epoch error:(NSError **)error {
    NSTimeInterval last, deadline;
    if (!isfinite(interval) || interval < 0 ||
        ![self _startBudget:timeout cleanup:NO started:&last deadline:&deadline error:error]) return NO;
    BOOL success = YES;
    NSError *failure = nil;
    for (id<RBXAppProcessControlling> controller in _controllers) {
        NSError *itemError = nil;
        if (![self _epochIsCurrent:epoch]) {
            RBXCoordinatorError(&failure, @"Process verification was superseded by a stop"); success = NO; break;
        }
        if (![self _advanceClock:&last deadline:deadline error:&itemError] || interval > deadline - last) {
            success = NO;
            if (!itemError) RBXCoordinatorError(&itemError, @"Global socket verification cannot fit the required clean interval");
            if (!failure) failure = itemError; continue;
        }
        if (![controller verifyNoAppSocketsForInterval:interval deadline:deadline error:&itemError]) {
            success = NO;
            if (!itemError) RBXCoordinatorError(&itemError, @"An app socket drain could not be proven");
            if (!failure) failure = itemError;
        }
        if (![self _advanceClock:&last deadline:deadline error:&itemError]) {
            success = NO; if (!failure) failure = itemError;
        }
    }
    if (![self _epochIsCurrent:epoch]) {
        success = NO; if (!failure) RBXCoordinatorError(&failure, @"Process verification was superseded by a stop");
    }
    if (!success && error) *error = failure;
    return success;
}

- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval
                             timeout:(NSTimeInterval)timeout error:(NSError **)error {
    NSString *epoch;
    @synchronized (self) {
        if (_activeIdentity || _launchInFlight || _stopInFlight) {
            RBXCoordinatorError(error, @"Global socket verification requires no active or transitioning clone"); return NO;
        }
        epoch = _epoch;
    }
    BOOL success = [self _verifyControllersForInterval:interval timeout:timeout epoch:epoch error:error];
    @synchronized (self) {
        if (![_epoch isEqual:epoch] || _activeIdentity || _launchInFlight || _stopInFlight || ![self _observersQuietLocked]) {
            success = NO; RBXCoordinatorError(error, @"Process verification overlapped another transition or old observer");
        }
        if (!success && [_epoch isEqual:epoch]) _globallyDrained = NO;
    }
    return success;
}

- (id<RBXAppProcessControlling>)_controllerForProfile:(NSDictionary *)profile error:(NSError **)error {
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    id<RBXAppProcessControlling> controller = descriptor ? _controllersByType[descriptor[@"appType"]] : nil;
    if (!controller || ![controller.appDescriptor isEqual:descriptor]) {
        RBXCoordinatorError(error, @"Profile app is unknown, inactive, or does not match its registered controller"); return nil;
    }
    return controller;
}

- (BOOL)isProfileStopped:(NSDictionary *)profile error:(NSError **)error {
    id<RBXAppProcessControlling> controller = [self _controllerForProfile:profile error:error];
    if (!controller) return NO;
    NSString *epoch;
    @synchronized (self) {
        if (_launchInFlight || _stopInFlight) {
            RBXCoordinatorError(error, @"Profile stop state is unproven while an app transition is in flight"); return NO;
        }
        epoch = _epoch;
    }
    BOOL stopped = [controller isProfileStopped:profile error:error];
    @synchronized (self) {
        if (![_epoch isEqual:epoch] || _launchInFlight || _stopInFlight) {
            RBXCoordinatorError(error, @"Profile stop inspection was superseded by an app transition"); return NO;
        }
    }
    return stopped;
}

- (BOOL)_identity:(NSDictionary *)identity matches:(NSDictionary *)expected {
    if (![identity isKindOfClass:NSDictionary.class] || !expected) return NO;
    for (NSString *key in RBXCoordinatorIdentityKeys())
        if (!expected[key] || ![identity[key] isEqual:expected[key]]) return NO;
    return YES;
}

- (void)_installActiveObserverLocked {
    [self _cancelObserversLocked];
    if (!_activeController || !_activeIdentity || !_watchQueue || !_onExit) return;
    NSString *token = NSUUID.UUID.UUIDString;
    _observerToken = token;
    NSDictionary *expected = _activeIdentity;
    id<RBXAppProcessControlling> controller = _activeController;
    __weak typeof(self) weakSelf = self;
    // Producer registration/cancellation only takes the controller's short
    // state lock; neither method performs process I/O or waits for a handler.
    [controller watchAppTerminationOnQueue:_watchQueue onExit:^(NSDictionary *identity, NSString *reason) {
        typeof(self) self = weakSelf;
        if (!self) return;
        void (^notify)(NSDictionary *, NSString *);
        @synchronized (self) {
            if (![self->_observerToken isEqual:token] || self->_activeController != controller ||
                ![self _identity:identity matches:expected] || ![self _identity:self->_activeIdentity matches:expected]) return;
            self->_observerToken = nil; self->_globallyDrained = NO;
            self->_epoch = NSUUID.UUID.UUIDString;
            self->_activeController = nil; self->_activeIdentity = nil;
            notify = self->_onExit;
        }
        // Consumer may synchronously close traffic or request emergency stop;
        // no coordinator/controller state lock is held through that callback.
        if (notify) notify(expected, reason ?: @"Active app terminated");
    }];
}

- (void)watchAppTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit {
    @synchronized (self) {
        _watchQueue = queue; _onExit = [onExit copy];
        [self _installActiveObserverLocked];
    }
}

- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    id<RBXAppProcessControlling> controller = [self _controllerForProfile:profile error:error];
    if (!controller) return NO;
    if(![_runnableTypes containsObject:controller.appDescriptor[@"appType"]]){RBXCoordinatorError(error,@"This app is inactive; storage maintenance does not grant launch permission");return NO;}
    NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
    NSString *container = [profile[@"containerId"] isKindOfClass:NSString.class] ? [profile[@"containerId"] copy] : nil;
    NSString *bundle = [app[@"bundleIdentifier"] isKindOfClass:NSString.class] ? [app[@"bundleIdentifier"] copy] : nil;
    if (!container.length || ![bundle isEqual:RBXAppBundleIdentifier(controller.appDescriptor, container)]) {
        RBXCoordinatorError(error, @"Profile has no exact registered clone identity"); return NO;
    }
    NSMutableDictionary *snapshot = [profile mutableCopy];
    NSMutableDictionary *appSnapshot = [app mutableCopy]; appSnapshot[@"bundleIdentifier"] = bundle;
    snapshot[@"app"] = [appSnapshot copy]; snapshot[@"containerId"] = container;
    snapshot[@"appType"] = controller.appDescriptor[@"appType"];
    NSString *epoch;
    @synchronized (self) {
        if (!_globallyDrained || _activeIdentity || _launchInFlight || _stopInFlight || !_watchQueue || !_onExit || ![self _observersQuietLocked]) {
            RBXCoordinatorError(error, @"Clone launch requires global quiescence and an installed termination observer"); return NO;
        }
        // Invalidate inspections that began before admission even if this
        // launch finishes before their backend snapshot returns.
        epoch = NSUUID.UUID.UUIDString; _epoch = epoch;
        _launchInFlight++; _globallyDrained = NO;
    }
    BOOL success = NO, reserved = YES, attempted = NO;
    NSError *failure = nil;
    @try {
        // No stop/revoke occurs during preflight: the caller already armed the
        // lease. A concurrent stop invalidates this reservation immediately.
        if ([self _verifyControllersForInterval:0 timeout:3.0 epoch:epoch error:&failure] && [self _epochIsCurrent:epoch] &&
            [RBXStorageAccess openProfile:snapshot authorized:^BOOL {
                RBXOperationContext *context=RBXOperationContext.currentContext;
                return [self _epochIsCurrent:epoch] && (!context || [context check:nil]);
            } error:&failure]) {
            attempted = YES;
            if ([controller launchCloneForProfile:[snapshot copy] error:&failure]) {
                id rawIdentity = controller.activeCloneIdentity;
                NSDictionary *identity = [rawIdentity isKindOfClass:NSDictionary.class] ? rawIdentity : nil;
                BOOL valid = identity != nil;
                for (NSString *key in @[@"containerId", @"bundleIdentifier", @"executable", @"generation", @"bootEpoch"])
                    valid = valid && [identity[key] isKindOfClass:NSString.class] && [identity[key] length] > 0;
                NSNumber *pid = [identity[@"pid"] isKindOfClass:NSNumber.class] ? identity[@"pid"] : nil;
                valid = valid && [identity[@"containerId"] isEqual:container] && [identity[@"bundleIdentifier"] isEqual:bundle] &&
                    [identity[@"executable"] isAbsolutePath] && pid.longLongValue > 1 && pid.longLongValue <= INT_MAX &&
                    pid.doubleValue == pid.longLongValue && pid.intValue == controller.activeClonePID &&
                    RBXCoordinatorValidProcessBirth(identity);
                if (valid) {
                    NSMutableDictionary *expected = [NSMutableDictionary dictionary];
                    for (NSString *key in RBXCoordinatorIdentityKeys()) expected[key] = [identity[key] copy];
                    @synchronized (self) {
                        if ([_epoch isEqual:epoch] && !_stopInFlight && _watchQueue && _onExit && [self _observersQuietLocked]) {
                            _activeController = controller; _activeIdentity = [expected copy];
                            [self _installActiveObserverLocked];
                            // Publish and end reservation at one linearization
                            // point. A later stop can now drain this exact app.
                            _launchInFlight--; reserved = NO; success = YES;
                        }
                    }
                }
                if (!success) RBXCoordinatorError(&failure, @"Launch identity was invalid or its ownership epoch was superseded");
            }
        }
    } @catch (NSException *exception) {
        RBXCoordinatorError(&failure, @"Clone launch raised an exception; global process quiescence is unproven");
    } @finally {
        if (reserved) {
            @synchronized (self) {
                // Registration can fail after state was staged but before its
                // commit. Never retain that tentative authority on an error.
                if ([_epoch isEqual:epoch] && _activeController == controller) {
                    _activeController = nil; _activeIdentity = nil; _observerToken = nil;
                }
            }
            // Keep reservation counted through all late cleanup effects. A
            // concurrent emergency stop cannot report drain while they run.
            if (attempted) for (id<RBXAppProcessControlling> item in _controllers) {
                @try { [item killAppProcesses]; } @catch (NSException *ignored) { }
            }
            [RBXStorageAccess closeAll:nil];
            @synchronized (self) { _launchInFlight--; }
        }
    }
    if (!success) {
        if (!failure) RBXCoordinatorError(&failure, @"Clone launch failed or was superseded; a new global drain is required");
        if (error) *error = failure;
    }
    return success;
}

- (void)dealloc {
    for (id<RBXAppProcessControlling> controller in _controllers) [controller stopWatchingAppTermination];
}
@end
