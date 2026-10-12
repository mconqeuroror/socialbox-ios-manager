#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure predicate for a future serialized adapter. The check and kernel commit
// must share one lock/fence owner; calling this before queuing work is unsafe.
FOUNDATION_EXPORT BOOL RBXPFMutationMatchesFence(NSDictionary *mutation,NSDictionary *fence);

// Offline candidate, deliberately absent from all shipping build targets.
// Rules are a typed AST, not pfctl text or a kernel ABI buffer.
@interface RBXPFPolicyPlan : NSObject
@property(nonatomic, readonly) NSDictionary *binding;
@property(nonatomic, readonly) NSArray<NSDictionary *> *closedRules;
@property(nonatomic, readonly) NSArray<NSDictionary *> *proxyRules;
@property(nonatomic, readonly) NSString *closedDigest;
@property(nonatomic, readonly) NSString *proxyDigest;
@property(nonatomic, readonly) NSArray<NSString *> *externalObligations;
+ (nullable instancetype)planWithRequest:(NSDictionary *)request error:(NSError **)error;
- (NSDictionary *)publicSummary;
@end

// Pure transaction reducer. Calls no ioctl, process, filesystem or network API.
// An acknowledgement represents a future trusted adapter's observation. It is
// not cryptographic evidence, a readiness receipt, or permission to launch apps.
@interface RBXPFTransactionModel : NSObject
@property(nonatomic, readonly) RBXPFPolicyPlan *plan;
@property(nonatomic, readonly) NSString *phase;
@property(nonatomic, readonly, nullable) NSDictionary *requestedAction;
@property(nonatomic, readonly) BOOL closedConfirmedInModel;
@property(nonatomic, readonly) BOOL proxyPolicyConfirmedInModel;
@property(nonatomic, readonly) BOOL applicationAdmissionAllowed; // Always NO.
@property(nonatomic, readonly) BOOL recovering;
@property(nonatomic, readonly, nullable) NSString *failureReason;
- (nullable instancetype)initWithPlan:(RBXPFPolicyPlan *)plan
                       afterInterruption:(BOOL)interrupted
                                     now:(double)now error:(NSError **)error;
- (BOOL)acknowledge:(NSDictionary *)ack now:(double)now error:(NSError **)error;
- (void)tick:(double)now;
- (void)interruptAt:(double)now;
- (NSDictionary *)journalSummary; // Informational; must never deserialize as verified state.
@end

NS_ASSUME_NONNULL_END
