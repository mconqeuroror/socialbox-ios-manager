#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString * const RBXOperationErrorDomain;

// An immutable operation owner, propagated explicitly across asynchronous hops.
// A deadline requests cancellation; only drained work proves quiescence.
@interface RBXOperationContext : NSObject
@property(nonatomic, readonly, copy) NSString *requestID;
@property(nonatomic, readonly, copy) NSString *token;
@property(nonatomic, readonly, copy) NSString *bootEpoch;
@property(nonatomic, readonly) NSTimeInterval deadlineMonotonic;
@property(nonatomic, readonly) NSTimeInterval remainingTime;
@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;
@property(nonatomic, readonly) BOOL inspectionOnly;
+ (instancetype)contextWithRequestID:(NSString *)requestID bootEpoch:(NSString *)bootEpoch timeout:(NSTimeInterval)timeout;
+ (instancetype)contextWithRequestID:(NSString *)requestID bootEpoch:(NSString *)bootEpoch timeout:(NSTimeInterval)timeout inspectionOnly:(BOOL)inspectionOnly;
+ (NSString *)daemonBootEpoch;
+ (nullable RBXOperationContext *)currentContext;
// TLS restore is guaranteed even on exception. This alone does not count work.
- (void)performBlock:(dispatch_block_t)block;
// First mutating work durably records active ownership before returning YES.
// A daemon restart with that marker requires recovery; finish removes it only
// after all counted descendants have stopped. Marker failures reject effects.
- (BOOL)beginWork:(NSError **)error;
// Count revocation cleanup for an already-started owner after cancellation.
// This grants no mutation authority and performs no filesystem/service I/O.
- (BOOL)beginCancellationCleanup;
- (void)endWork;
- (BOOL)check:(NSError **)error;
- (void)cancelWithReason:(NSString *)reason;
// Wait only outside this context's counted work. Uses a monotonic bounded wait.
- (BOOL)waitForQuiescence:(NSTimeInterval)timeout;
// Atomically seal a drained, uncanceled owner before publishing normal results.
// No persistence or external resource calls occur here.
- (BOOL)sealCompletedWork;
// Seal after drain. Sealing with outstanding work sets the persistent fence.
- (void)finish;
- (void)finishWhenQuiescent;
// Wrappers count before enqueue and always execute the captured TLS block.
// The block must check before effects; cleanup/signalling may run after cancel.
- (BOOL)dispatchAsyncOnQueue:(dispatch_queue_t)queue block:(dispatch_block_t)block;
// Never shortens a required delay: a delay exceeding the budget is rejected.
- (BOOL)dispatchAfter:(NSTimeInterval)delay queue:(dispatch_queue_t)queue block:(dispatch_block_t)block;
// Register tasks BEFORE resume. Untrack in completion after all its effects.
// Tasks count as work, even if cancellation raced registration. Sessions do not.
- (void)trackTask:(NSURLSessionTask *)task;
- (void)untrackTask:(NSURLSessionTask *)task;
// Only individually owned sessions; never register shared singleton sessions.
- (void)trackSession:(NSURLSession *)session;
- (void)untrackSession:(NSURLSession *)session;
// Each handler is delivered asynchronously and independently, without TLS.
// Handlers must be ownership-safe if racing unregister/reap/finish; they do
// not count as operation work. Already-canceled registration schedules delivery.
- (NSString *)registerCancellationHandler:(dispatch_block_t)handler;
- (void)unregisterCancellationHandler:(NSString *)handlerToken;
// Sticky across daemon restarts. No automatic clear when a late worker exits.
- (BOOL)markUnsafeWithReason:(NSString *)reason error:(NSError **)error;
// Immediate admission fence; the caller schedules persistence independently.
// The pre-mutation active marker remains the restart fence until recovery.
- (NSDictionary *)fenceInMemoryWithReason:(NSString *)reason;
+ (nullable NSDictionary *)safetyFenceStatus;
+ (BOOL)checkSafetyFence:(NSError **)error;
#ifdef RBX_OPERATION_TESTING
+ (void)setSafetyFenceDirectoryForTesting:(NSString *)directory;
#endif
@end
NS_ASSUME_NONNULL_END
