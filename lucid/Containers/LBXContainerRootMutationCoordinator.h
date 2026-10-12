#import <Foundation/Foundation.h>
@class LBXContainerConfiguration;
NS_ASSUME_NONNULL_BEGIN
// Asynchronous saved-settings frontend for the fixed authenticated root service.
// Assembly observes no files, role, pairing or grant. No old mobile journal,
// numeric CID, runtime, target application, proxy or install operation is used.
@interface LBXContainerRootMutationCoordinator : NSObject
+ (instancetype)coordinator;
// Rendering ONLY; never expected/CAS/authorization authority. Remote unavailable
// sets a redacted error, while any known pending rendering copy remains visible.
// A first-stage uncertainty may be an intent with configuration:NSNull, exact
// stageRequestID/expectedEmptyEpoch/input and no invented slot token/identifiers.
- (nullable NSDictionary *)pendingMutation:(NSError **)error;
// All completions are one-shot on main. Exact eight keys: result,configuration,
// entries,next,pending(strict BOOL),runtimeAccepted(false),stateAvailable(strict
// BOOL),pendingMutation(NSNull/rendering copy). Never log/export private values.
// Results: active,status,saved,listed,record,missing,retry_required,conflict,
// authorization_required,unconfirmed,state_unavailable,no_pending,busy,
// invalid_request,retired,retirement_retry_required. Unavailable state
// conservatively sets pending:true. Only retired confirms metadata removal.
// Cache is display-only: no startup mutation or automatic resend is performed.
- (void)refreshWithCompletion:(void (^)(NSDictionary *))completion;
- (void)validateWithCompletion:(void (^)(NSDictionary *))completion;
- (void)listAfter:(NSString *)after completion:(void (^)(NSDictionary *))completion;
- (void)readConfigurationWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *))completion;
// Explicit create validates, observes fresh authenticated status, retains exact
// stage input/ID/empty epoch BEFORE stage, then executes the retained root slot.
// Exact choices: name,applications,manualIdentifiers(NSNull or complete manual
// dictionary),proxyReference(empty or canonical UUID metadata only). No proxy
// resolution, local/random preparation or file writes.
- (void)beginCreationWithChoices:(NSDictionary *)choices completion:(void (^)(NSDictionary *))completion;
// Always fetches a fresh authenticated full read and requires it to equal the
// caller's full expected document before building exact edit CAS. List/cache
// values alone cannot authorize edits. nil fields retain every identifier.
- (void)beginUpdateOfConfiguration:(LBXContainerConfiguration *)expected
                              name:(nullable NSString *)name applications:(nullable NSArray<NSString *> *)applications
                 manualIdentifiers:(nullable NSDictionary<NSString *,NSString *> *)manualIdentifiers
                        completion:(void (^)(NSDictionary *))completion;
// Explicit fresh validation/status reconstructs matching pending/completed slot.
// Retry sends the same retained input/ID or token/epoch, never regenerates.
// Authenticated same empty epoch alone never discards an unresolved local input.
// Different/newer state conflicts and replaces rendering while retaining intent.
// Root durable pending is restart authority; an unsent draft may be dismissed,
// while uncertain request memory survives dismissal only in this live instance.
- (void)reconcilePendingWithCompletion:(void (^)(NSDictionary *))completion;
- (void)retryPendingWithCompletion:(void (^)(NSDictionary *))completion;
// Explicit metadata retirement: fresh validation/status/FULL read must equal
// the complete original, retained before stage-retire with a stable request ID.
// Only strictly unreserved authored records are eligible at the root. No app
// data/account/CID removal, UUID release, discard or runtime authority follows.
- (void)beginRetirementOfConfiguration:(LBXContainerConfiguration *)expected
                           completion:(void (^)(NSDictionary *))completion;
// Separate recovery verbs; generic save/retry cannot execute or confirm retire.
// These reject unresolved create/update work and retain uncertainty unchanged.
- (void)reconcileRetirementWithCompletion:(void (^)(NSDictionary *))completion;
- (void)retryRetirementWithCompletion:(void (^)(NSDictionary *))completion;
// Exact redacted flags: stateAvailable,hasPending,busy,runtimeAccepted; all BOOL.
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
#if LBX_CONTAINER_ROOT_COORDINATOR_TESTING
typedef void (^LBXRootCoordinatorLicenseSender)(NSString *,NSString * _Nullable,void (^)(NSDictionary *));
typedef void (^LBXRootCoordinatorMutationSender)(NSString *,NSDictionary *,void (^)(NSDictionary *));
@interface LBXContainerRootMutationCoordinator (Testing)
+ (void)testUseLicenseSender:(nullable LBXRootCoordinatorLicenseSender)licenseSender
             mutationSender:(nullable LBXRootCoordinatorMutationSender)mutationSender;
// Shortening-only cooperative response timeout, never a grant/clock extension.
+ (void)testUseStepBudget:(double)seconds;
@end
#endif
NS_ASSUME_NONNULL_END
