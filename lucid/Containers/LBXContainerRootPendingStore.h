#import <Foundation/Foundation.h>
@class LBXLicenseOwner, LBXContainerConfigurationStore, LBXContainerRootPendingTransaction, LBXLicenseInstallationEstablishment;
NS_ASSUME_NONNULL_BEGIN
// Root-private exact-candidate metadata. No engine, CID, proxy or account grant.
// Every API requires this exact owner's active synchronous source-operation
// queue and original deadline. Paths and callbacks are trusted local assembly,
// never IPC arguments. No state/context/private dictionary may be logged.
@interface LBXContainerRootPendingStore : NSObject
+ (nullable instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)configurations create:(BOOL)create
    beforeDeadline:(double)deadline error:(NSError **)error;
// Shipping prepared-installation consumer. Initial creation consumes the typed
// proof inside the exact held-empty namespace callback; existing state binds
// the same immutable witness on every use. No parser/Boolean/IPC initialization.
+ (nullable instancetype)openDirectory:(NSString *)directory licenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)configurations
    preparedInstallation:(LBXLicenseInstallationEstablishment *)installation create:(BOOL)create
    beforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)usesLicenseOwner:(LBXLicenseOwner *)owner configurationStore:(LBXContainerConfigurationStore *)configurations;
- (BOOL)withLockedStateBeforeDeadline:(double)deadline
    operation:(BOOL (^)(LBXContainerRootPendingTransaction *transaction, NSError **error))operation error:(NSError **)error;
// Public protocol projection only. Returned state contains full private setup
// choices but excludes root pairing/context/paths and private attempt counts.
+ (nullable NSDictionary *)projectState:(NSDictionary *)privateState;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
// Synchronous, bounded transaction lifetime only; cannot be transferred across
// queues, owners, deadlines or after the callback returns. Publication may have
// occurred even when it reports failure; preserve/reconcile exact state.
@interface LBXContainerRootPendingTransaction : NSObject
@property(nonatomic, readonly, copy) NSDictionary *privateState;
- (BOOL)publishState:(NSDictionary *)next error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
#if LBX_CONTAINER_ROOT_PENDING_TESTING
@interface LBXContainerRootPendingStore (Testing)
// Failure only; no synthetic context, successful filesystem observation or grant.
- (void)testStopAfterBoundary:(nullable NSString *)boundary;
+ (void)testStopEstablishmentAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
