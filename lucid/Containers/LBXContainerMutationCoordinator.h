#import <Foundation/Foundation.h>
@class LBXContainerConfiguration;
NS_ASSUME_NONNULL_BEGIN

// Source UUID setup metadata only. No legacy numeric CID, runtime flag, launch,
// account storage, proxy transport or pairing/installation grant is provided.
// All RPCs use the fixed authenticated typed clients and fresh validation.
// Normal startup opens create:NO. create:YES requires trusted external
// initial-setup provenance; this factory cannot prove pristine lost state.
@interface LBXContainerMutationCoordinator : NSObject
+ (nullable instancetype)openWithCreate:(BOOL)create error:(NSError **)error;
- (nullable NSDictionary *)pendingMutation:(NSError **)error;
// Callbacks on main queue. Exact keys: result,configuration,entries,next,pending,
// runtimeAccepted. Private configuration is NSNull/full; pending is strict BOOL;
// runtimeAccepted is always false. Never log/export callback or pending slots.
// Results: active,saved,listed,record,retry_required,conflict,
// authorization_required,unconfirmed,journal_unavailable,no_pending,busy,
// invalid_request. Unresolved server publication retains the exact durable slot.
// A failed local clear after exact root proof retains the candidate in memory
// and requires reconciliation; safe empty state on restart can reflect that clear.
- (void)validateWithCompletion:(void (^)(NSDictionary *))completion;
- (void)listAfter:(NSString *)after completion:(void (^)(NSDictionary *))completion;
- (void)readConfigurationWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *))completion;
// Exact choices: name,applications,manualIdentifiers(NSNull/random or complete
// manual dictionary),proxyReference(empty). One prepare, durable stage, create.
- (void)beginCreationWithChoices:(NSDictionary *)choices completion:(void (^)(NSDictionary *))completion;
// Full read record is expected CAS authority; list projections cannot be used.
// nil retains fields, including every random/manual identifier. No rerandomize.
- (void)beginUpdateOfConfiguration:(LBXContainerConfiguration *)expected
                              name:(nullable NSString *)name applications:(nullable NSArray<NSString *> *)applications
                 manualIdentifiers:(nullable NSDictionary<NSString *,NSString *> *)manualIdentifiers
                        completion:(void (^)(NSDictionary *))completion;
// Exact read candidate => confirm and CAS-clear. Create missing/update exact
// expected => retry_required, never drop. Other state => conflict and retain.
// Retry explicitly reconciles again before resending the SAME candidate/CAS.
// Dismissal, timeout, process restart and authorization_required never discard.
- (void)reconcilePendingWithCompletion:(void (^)(NSDictionary *))completion;
- (void)retryPendingWithCompletion:(void (^)(NSDictionary *))completion;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_CONTAINER_MUTATION_TESTING
typedef void (^LBXMutationLicenseSender)(NSString *,NSString * _Nullable,void (^)(NSDictionary *));
typedef void (^LBXMutationContainerSender)(NSString *,NSDictionary *,void (^)(NSDictionary *));
@interface LBXContainerMutationCoordinator (Testing)
+ (void)testUseLicenseSender:(nullable LBXMutationLicenseSender)licenseSender
              containerSender:(nullable LBXMutationContainerSender)containerSender;
// Failure-only delegate to the real journal, never a completion proof.
- (void)testStopJournalAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
