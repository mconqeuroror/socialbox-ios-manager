#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

// Durable launcher/daemon transport. Darwin notifications are wakeups only;
// request and terminal-result identity always comes from these records.
@interface RBXRequestQueue : NSObject
+ (instancetype)defaultQueue;
- (instancetype)initWithRootDirectory:(NSString *)path
                           daemonUID:(uid_t)daemonUID
                           clientUID:(uid_t)clientUID;

// Call after startup establishes CLOSED. Holds the daemon lock until dealloc.
- (BOOL)prepareDaemon:(NSError **)error;

// A nonnil ID means the request was published. If directory fsync subsequently
// fails, the ID is still returned with an error: observe that ID; do not resubmit.
- (nullable NSString *)enqueueAction:(NSString *)action
                              values:(NSDictionary *)values
                               error:(NSError **)error;

// Returns one immutable, durably claimed request. nil + nil error means empty.
- (nullable NSDictionary *)claimNextRequest:(NSError **)error;

// First terminal result wins. Failed persistence retains the claim and queues
// this result for retry, without executing the operation again. values becomes
// result.details; reserved base keys cannot be overridden through values.
- (BOOL)finishRequest:(NSDictionary *)request
                  ok:(BOOL)ok
             message:(NSString *)message
              values:(nullable NSDictionary *)values
               error:(NSError **)error;
- (nullable NSDictionary *)resultForRequestID:(NSString *)requestID
                                       error:(NSError **)error;

// Call at startup and periodically. Active requests are excluded. Any abandoned
// claim receives an interrupted result; side effects are never replayed.
- (BOOL)retryPendingResultsAndRecoverAbandonedClaims:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
