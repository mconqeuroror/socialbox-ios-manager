#import <Foundation/Foundation.h>
@class LBXLicenseOwner, LBXLicenseVault, LBXContainerConfigurationStore;
NS_ASSUME_NONNULL_BEGIN
// Trusted local installation provenance for unpaired source licensing storage.
// No IPC constructor, caller Boolean, license grant, reset or runtime authority.
// Preparation is explicitly invoked by the fixed root-owned installer. Ordinary
// service startup opens only an existing complete immutable prepared record.
@interface LBXLicenseInstallationEstablishment : NSObject
+ (nullable instancetype)prepareFixedInstallation:(NSError **)error;
+ (nullable instancetype)openFixedPreparedInstallation:(NSError **)error;
@property(nonatomic,readonly,strong) LBXLicenseOwner *licenseOwner;
@property(nonatomic,readonly,strong) LBXLicenseVault *vault;
@property(nonatomic,readonly,strong) LBXContainerConfigurationStore *configurationStore;
// Reobserves private files, stable seed/server/namespace and fixed image policy.
// This is provenance only: it cannot authorize a source operation or pair a key.
- (BOOL)preparedInstallationCurrent:(NSError **)error;
// Private root-local physical witness for a future paired establishment binding.
// Never export/log it or use it as a caller-supplied grant. This unguarded
// observation carries no active-source-fence authority.
- (nullable NSDictionary *)privatePreparedWitness:(NSError **)error;
// Typed consumption of THIS factory-created installation proof, ONLY inside
// THIS exact store's synchronous held-empty setup callback and THIS owner's
// active source-operation queue/original deadline. namespaceContext must be
// that callback's original borrowed object, not a parsed/copied dictionary.
// Does not take configuration.lock again or initialize/publish pending state.
- (nullable NSDictionary *)consumeForInitialPendingWithLicenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)store namespaceContext:(NSDictionary *)namespaceContext
    pendingDirectory:(NSString *)pendingDirectory inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Durable one-shot reservation BEFORE initial pending effects, in the same
// original held-empty callback and source fence. Only the exact pristine seed
// can become terminal consumed, on its original inode. Never recreates,
// restores, renames or adopts seed state. A nil result may follow a durable
// terminal or partial write; later ordinary observations do not reset it.
- (nullable NSDictionary *)reserveInitialPendingWithLicenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)store namespaceContext:(NSDictionary *)namespaceContext
    pendingDirectory:(NSString *)pendingDirectory inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
// Ordinary established pending-context observation in the same exact fence.
// It reuses only the store's existing allowed namespace proof scope or takes
// the normal bounded namespace lock; never usable in the held-empty callback.
// Both APIs require the exact fixed declared pending path. The immutable
// PRIVATE witness has the same {anchor,intent,prepared,documentSHA256} shape.
// It contains no credentials/changing revision and is never a transferable
// grant, parser input, IPC payload or lifetime authorization. Reobserve before
// every effect; a later admission/deadline failure may follow durable effects.
- (nullable NSDictionary *)privatePreparedWitnessForLicenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)store pendingDirectory:(NSString *)pendingDirectory
    inCurrentSourceOperationBeforeDeadline:(double)deadline error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
#if LBX_LICENSE_INSTALLATION_TESTING
@interface LBXLicenseInstallationEstablishment (Testing)
// Test-only fixed-policy assembly. File observations remain actual descriptor
// observations; no successful filesystem/licensing result is injected.
+ (nullable instancetype)testPreparePaths:(NSDictionary *)paths clientSHA256:(NSString *)sha size:(NSUInteger)size error:(NSError **)error;
+ (nullable instancetype)testOpenPaths:(NSDictionary *)paths clientSHA256:(NSString *)sha size:(NSUInteger)size error:(NSError **)error;
+ (void)testStopAfterBoundary:(nullable NSString *)boundary;
+ (void)testBoundaryHandler:(nullable void (^)(NSString *boundary))handler;
@end
#endif
NS_ASSUME_NONNULL_END
