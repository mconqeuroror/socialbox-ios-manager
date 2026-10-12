#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RBXNetworkGate : NSObject

+ (NSString *)leasePath;
+ (nullable NSString *)closeTrafficWithReason:(NSString *)reason;
+ (nullable NSString *)closeTrafficWithReason:(NSString *)reason error:(NSError **)error;
// Run only after CLOSED has been established; DNS has a bounded caller deadline.
+ (BOOL)refreshControlAddresses:(NSError **)error;
// Maintenance only, after process termination is proven. Never authorizes launch.
+ (BOOL)waitForMaintenanceClosure:(NSString *)generation timeout:(NSTimeInterval)timeout;
+ (NSDictionary *)setupStatus;
// Bounded read-only DNS using the existing single resolver slot and owner.
+ (nullable NSArray<NSString *> *)proxyAddressesForURL:(NSString *)url;
// Authorization requires the captured current RBXOperationContext. CLOSED
// remains available during cancellation and while recovery is fenced.
+ (BOOL)armTrafficForContainer:(NSString *)containerId
              bundleIdentifier:(NSString *)bundleIdentifier
                      proxyURL:(NSString *)proxyURL
                        exitIP:(NSString *)exitIP
                    generation:(NSString *)generation
                         error:(NSError **)error;
+ (BOOL)openTrafficForContainer:(NSString *)containerId
               bundleIdentifier:(NSString *)bundleIdentifier
                       proxyURL:(NSString *)proxyURL
                         exitIP:(NSString *)exitIP
                     generation:(NSString *)generation
                          error:(NSError **)error;
+ (BOOL)syncCurrentLeaseToProfile:(NSDictionary *)profile error:(NSError **)error;
+ (BOOL)syncFirewallStatusToProfile:(NSDictionary *)profile error:(NSError **)error;
+ (BOOL)waitForHookReadinessForProfile:(NSDictionary *)profile
                              expectedPID:(pid_t)expectedPID
                               generation:(NSString *)generation
                                   timeout:(NSTimeInterval)timeout;
+ (BOOL)waitForSystemFirewallState:(NSString *)state
                         container:(NSString * _Nullable)containerId
                        generation:(NSString *)generation
                           timeout:(NSTimeInterval)timeout;
+ (NSString * _Nullable)lastExitIP;
+ (void)startDaemonHeartbeat;

@end

NS_ASSUME_NONNULL_END
