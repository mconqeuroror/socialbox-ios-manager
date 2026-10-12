#import <Foundation/Foundation.h>
#import <sys/types.h>
@class RBXOperationContext;

@interface RBXProcessController : NSObject

// A controller is bound to one immutable registered app descriptor. The default
// remains Reddit, including legacy profiles whose appType is absent.
- (instancetype)initWithAppDescriptor:(NSDictionary *)descriptor;
@property(nonatomic, copy, readonly) NSDictionary *appDescriptor;

+ (void)killAllProcessesForAppDescriptor:(NSDictionary *)descriptor;
- (void)killAppProcesses;
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval error:(NSError **)error;
// Additive coordinator seam: absolute CLOCK_MONOTONIC deadline, never extended.
- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval
                            deadline:(NSTimeInterval)deadline error:(NSError **)error;
- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error;
- (void)watchAppTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit;

// Compatibility entry points; the instance methods use their controller's app.
// SIGKILL every Reddit process (main + extensions). Used by the container
// switch path and by the license lock (revoke-to-kill).
+ (void)killAllRedditProcesses;
- (void)killReddit;

// Revoke the launch binding, SIGKILL all Reddit processes/extensions, and
// synchronously verify that no matching process remains.
- (BOOL)killAllAndWait:(NSTimeInterval)timeout;

// Uses libproc's kernel fd table and requires a continuous clean interval.
- (BOOL)verifyNoRedditSocketsForInterval:(NSTimeInterval)interval
                                   error:(NSError **)error;

// Launch the signed app clone identified by profile.app.bundleIdentifier.
- (BOOL)launchRedditCloneForProfile:(NSDictionary *)profile error:(NSError **)error;

// uiopen exit success alone does not prove launch. Returns the PID of the exact
// registered app executable, or -1 with an error. Both host and clones use this.
+ (pid_t)launchRegisteredBundleIdentifier:(NSString *)bundleIdentifier
                      expectedBundlePath:(NSString * _Nullable)bundlePath
                                 timeout:(NSTimeInterval)timeout
                                   error:(NSError **)error;

+ (pid_t)launchRegisteredBundleIdentifier:(NSString *)bundleIdentifier
                      expectedBundlePath:(NSString * _Nullable)bundlePath
                                 timeout:(NSTimeInterval)timeout
                                 context:(RBXOperationContext *)context
                                   error:(NSError **)error;

// Call launch and this observer on the same serial transition queue. A timer
// samples current state there; no exit event can overtake the next launch.
@property(nonatomic, readonly) pid_t activeClonePID;
@property(nonatomic, copy, readonly) NSDictionary *activeCloneIdentity;
// Cancellation does not join an executing source handler. Global drain must
// also prove this count is zero before authorizing a later launch.
@property(nonatomic, readonly) NSUInteger terminationObservationInFlight;
// Cancel before switching app controllers: an old observer can revoke the
// shared launch binding even if its consumer ignores the callback.
- (void)stopWatchingAppTermination;
- (void)watchRedditTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit;

// Read-only exact registered-path inspection. NO means running or unprovable;
// an NSError distinguishes the reason. Never closes or kills the target.
- (BOOL)isProfileStopped:(NSDictionary * _Nonnull)profile
                   error:(NSError * _Nullable * _Nullable)error;

@end
