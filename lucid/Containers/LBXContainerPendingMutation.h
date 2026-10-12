#import <Foundation/Foundation.h>
@class LBXContainerConfiguration;
NS_ASSUME_NONNULL_BEGIN

// Private MOBILE metadata only, not a source license, pairing provenance,
// runnable container or grant. The production factory requires UID/EUID501,
// observes the fixed compiled client and current physical app home, and uses
// Library/Application Support/SocialBoxPendingMutations. Never export/log slots.
// create:YES requires trusted external initial-setup provenance. The factory
// cannot prove missing entire state is pristine; existing damage is never reset.
// Cooperative writers use the same pinned lock. Same-UID/root external writers
// and root pairing/reset context are outside this local journal's authority.
@interface LBXContainerPendingMutation : NSObject
+ (nullable instancetype)openWithCreate:(BOOL)create error:(NSError **)error;
// nil/no error means verified empty. Any unsafe/missing state yields an error.
- (nullable NSDictionary *)pendingMutation:(NSError **)error;
// Internal coordinator operations. Exact full candidate/expected are durable
// before sending. Slots carry a local UUID and monotonic epoch/attempt counter.
- (nullable NSDictionary *)stageConfiguration:(LBXContainerConfiguration *)configuration
                                      replacing:(nullable LBXContainerConfiguration *)expected error:(NSError **)error;
- (nullable NSDictionary *)beginAttemptForMutation:(NSDictionary *)mutation error:(NSError **)error;
// Trusted coordinator only AFTER fixed-client exact saved/record confirmation.
// No caller Boolean grants completion. CAS checks the entire token/epoch/slot;
// Failure never authorizes any root operation. A failure after atomic clear
// publication may leave verified empty state, but only after trusted root proof.
// The coordinator retains the exact candidate in memory for cleanup reconciliation.
- (BOOL)clearConfirmedMutation:(NSDictionary *)mutation error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_CONTAINER_MUTATION_TESTING
@interface LBXContainerPendingMutation (Testing)
// Real host filesystem observations only; no successful observation Boolean.
+ (void)testUseHomeDirectory:(nullable NSString *)home clientExecutable:(nullable NSString *)executable;
// Failure only: state_staged, state_renamed, state_synced, clear_before_publish.
- (void)testStopAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
