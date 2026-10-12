#pragma once
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sys/types.h>
#import "RBXAppRegistry.h"

// Each registered family needs its own stable-clean interval and process
// inventory work, even while inactive for admission. This is one bounded total
// budget; the coordinator still clips it to the owning operation's deadline.
static inline NSTimeInterval RBXGlobalProcessStopBudget(void) {
    return MIN(30.0, MAX(8.0, 4.0 * RBXRegisteredAppDescriptors().count));
}

// The coordinator owns no lease persistence. Its caller must close the global
// network lease before stop/drain, then arm the exact profile before launch.
// Ordinary transitions/observer callbacks retain their serial transition queue.
// Emergency stop may overlap them: short state locks invalidate admission and
// track in-flight work, with no lock held during process waits or launch I/O.
// Original per-app controllers and their Reddit compatibility methods remain
// scoped to their immutable registered descriptor.
@protocol RBXAppProcessControlling <NSObject>
@property(nonatomic, copy, readonly) NSDictionary *appDescriptor;
@property(nonatomic, readonly) pid_t activeClonePID;
@property(nonatomic, copy, readonly) NSDictionary *activeCloneIdentity;
@property(nonatomic, readonly) NSUInteger terminationObservationInFlight;
- (void)killAppProcesses;
- (BOOL)killAllAndWait:(NSTimeInterval)timeout;
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval
                            deadline:(NSTimeInterval)deadline error:(NSError **)error;
- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)isProfileStopped:(NSDictionary *)profile error:(NSError **)error;
- (void)stopWatchingAppTermination;
- (void)watchAppTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit;
@end

@interface RBXAppProcessCoordinator : NSObject
// Revocation includes every registered descriptor, including inactive apps.
- (instancetype)init;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *appDescriptors;
@property(nonatomic, copy, readonly) NSDictionary *activeCloneIdentity;
@property(nonatomic, readonly) pid_t activeClonePID;

// Issue stop to ALL registered apps first, then drain ALL under one aggregate
// monotonic budget. Any failure prevents success; later apps still receive stop.
// NO also means an overlapping launch/stop or cancelled observer has not yet
// quiesced. A later explicit drain is required; elapsed time is never authority.
- (BOOL)killAllAndWait:(NSTimeInterval)timeout;
- (BOOL)stopAllAppsAndWait:(NSTimeInterval)timeout error:(NSError **)error;
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval error:(NSError **)error;
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval
                             timeout:(NSTimeInterval)timeout error:(NSError **)error;
// Requires prior successful global stop, registered runnable profile, observer
// registration and the underlying controller's current ARMED lease validation.
- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)isProfileStopped:(NSDictionary *)profile error:(NSError **)error;
- (void)watchAppTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit;
- (void)stopWatchingAppTermination;

#ifdef RBX_APP_PROCESS_COORDINATOR_TESTING
// Compiled out of production. Canonical descriptors still bind each fake;
// runnableAppTypes permits future registered apps to be exercised while their
// actual production registry remains inactive. No descriptor fields are changed.
- (instancetype)initWithControllers:(NSArray<id<RBXAppProcessControlling>> *)controllers
                   runnableAppTypes:(NSSet<NSString *> *)runnableAppTypes
                     monotonicClock:(NSTimeInterval (^)(void))clock;
#endif
@end
