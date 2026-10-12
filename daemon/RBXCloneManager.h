#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@class RBXOperationContext;

@interface RBXCloneManager : NSObject
- (instancetype)initWithOperationContext:(RBXOperationContext *)context;
// Immutable app scope. Legacy initializers select Reddit without rewriting data.
- (nullable instancetype)initWithAppType:(NSString *)appType
                       operationContext:(nullable RBXOperationContext *)context;
@property(nonatomic, readonly, copy) NSDictionary *appDescriptor;
// Read-only exact registration inventory, including owned inactive app clones.
+ (nullable NSArray<NSDictionary *> *)storageTargetsWithError:(NSError **)error;
+ (nullable NSString *)bundleIdentifierForContainer:(NSString *)containerId appType:(NSString *)appType;
+ (nullable NSString *)keychainGroupForBundleIdentifier:(NSString *)bundleIdentifier appType:(NSString *)appType;

+ (NSString *)bundleIdentifierForContainer:(NSString *)containerId;
+ (NSString *)keychainGroupForBundleIdentifier:(NSString *)bundleIdentifier;

// Global maintenance: validate the full inventory, then dispatch each runnable
// owner under one operation and transaction lock. Inactive pending work blocks.
+ (BOOL)recoverAllInterruptedTransactionsWithContext:(RBXOperationContext *)context error:(NSError **)error;
- (void)recoverInterruptedTransactions;
- (BOOL)recoverInterruptedTransactionsWithContext:(RBXOperationContext *)context error:(NSError **)error;

// Copy the decrypted source Reddit bundle into a non-registered private cache,
// then uninstall the visible source app. This is explicit because uninstalling
// also removes the source app's data container.
- (BOOL)archiveSourceAndRemoveVisibleApp:(NSError **)error;

// Import an IPA staged by the launcher at SourceInbox/<UUID>.ipa. Validates a
// decrypted com.reddit.Reddit bundle and replaces only the private source cache.
// The inbox file is consumed on success; failures preserve the previous source.
- (BOOL)importSourceIPA:(NSString *)path error:(NSError **)error;

// Sanitized readiness information for the launcher/diagnostics UI.
- (NSDictionary *)sourceStatus;
// Private change detector for a short-lived creation preview. Never publish it.
- (nullable NSDictionary *)creationSourceBinding;

// Create a temporary signed IPA for Files/MDM sharing from the launcher.
- (nullable NSString *)exportIPAForProfile:(NSDictionary *)profile
                                     error:(NSError **)error;
- (NSDictionary * _Nullable)ensureCloneForContainer:(NSString *)containerId
                                            profile:(NSDictionary *)profile
                                           nickname:(NSString * _Nullable)nickname
                                              error:(NSError **)error;
// Remove through LaunchServices and verify captured app/plugin paths and
// registrations disappear. Failed removal retains durable retry evidence.
- (BOOL)removeCloneForProfile:(NSDictionary *)profile error:(NSError **)error;
// Explicit user deletion only. The registry durably journals the prepared
// target before invoking the remaining, independently retryable phases.
- (nullable NSDictionary *)prepareDeletionForProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)eraseKeychainForDeletionTarget:(NSDictionary *)target error:(NSError **)error;
- (BOOL)uninstallDeletionTarget:(NSDictionary *)target error:(NSError **)error;
- (BOOL)cleanupArtifactsForDeletionTarget:(NSDictionary *)target error:(NSError **)error;
- (BOOL)validateCloneForProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)verifyManagedInstallationForProfile:(NSDictionary *)profile error:(NSError **)error;
- (NSString * _Nullable)dataContainerForBundleIdentifier:(NSString *)bundleIdentifier;
- (BOOL)syncProfile:(NSDictionary *)profile error:(NSError **)error;
- (BOOL)writeControlPlist:(NSDictionary *)document
                  profile:(NSDictionary *)profile
                     name:(NSString *)name
                    error:(NSError **)error;
// Gate maintenance only: exact current global lease/status mirrors. CLOSED
// revocation remains available during cancellation and a persistent fence.
- (BOOL)writeGateControlPlist:(NSDictionary *)document profile:(NSDictionary *)profile
                        name:(NSString *)name error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
