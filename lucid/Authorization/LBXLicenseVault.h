#import <Foundation/Foundation.h>
@class LBXLicenseOwner;
NS_ASSUME_NONNULL_BEGIN
// Minted only after signature verification and a successful durable CAS commit.
// Private in-process evidence for source-owned consumers, never an IPC payload
// or a grant understood by the retained engine. Contains no public credential
// getters and cannot be reconstructed from lastStatus or paired metadata.
@interface LBXLicenseVerifiedCommit : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString *status;
@property(nonatomic, readonly) NSTimeInterval expiresAt;
- (BOOL)matchesConfiguration:(nullable NSDictionary *)configuration;
@end
// Root-owned installation pairing, not an admission grant. The future app
// client must use authenticated IPC; it must never read this private directory.
@interface LBXLicenseVault : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// Explicitly creates one leaf beneath an existing trusted private/root parent.
// A missing/corrupt established record never generates a replacement identity.
+ (nullable instancetype)openDirectory:(NSString *)directory error:(NSError **)error;
// Ordinary service startup. Never creates missing leaf, lock or pairing state.
+ (nullable instancetype)openExistingDirectory:(NSString *)directory error:(NSError **)error;
// Trusted local installer prerequisite ONLY. Refuses every existing leaf,
// including valid state; returns only infrastructure created by this call.
// Failure may leave durable partial resources; never delete/adopt/reset them.
// Production requires real/effective UID0. This does not prove that absence
// means first installation; an external trusted establishment policy is needed.
+ (nullable instancetype)createPristineDirectory:(NSString *)directory error:(NSError **)error;
// PRIVATE stable observation, available before pairing to trusted root-local
// installer assembly. Exact keys: {server,deviceIdentity,vault:{directory,lock}}.
// No credentials, revision, state-file inode, admission or provenance grant.
// Immutable instantaneous facts only; never IPC/log/export or caller authority.
- (nullable NSDictionary *)installationContextForTrustedInstaller:(NSError **)error;
// Supporting private root observation for the exact owning active source fence.
// Includes stable vault directory/lock facts and paired identity fingerprints,
// never credentials, mutable revision or pairing.json inode. Not an IPC/grant API.
- (nullable NSDictionary *)pairingContextForSourceOwner:(LBXLicenseOwner *)owner
                                        beforeDeadline:(NSTimeInterval)deadline error:(NSError **)error;
// Private snapshots contain a key and bearer; never log or export them.
- (nullable NSDictionary *)configuration:(NSError **)error;
// Reserves a durable generation before sending a request. nil keeps the key.
- (nullable NSDictionary *)beginWithKey:(nullable NSString *)key error:(NSError **)error;
// Only the owning transport's completed receipt may be passed here. Rechecks
// its signature/binding/expiry, then CAS-commits pairing under the file lock.
// This does not grant admission or store a reusable offline authorization.
- (BOOL)commitReceipt:(NSDictionary *)receipt expectedConfiguration:(NSDictionary *)expected error:(NSError **)error;
// Returns signed status/expiry bound to the exact post-commit generation.
- (nullable LBXLicenseVerifiedCommit *)commitVerifiedReceipt:(NSDictionary *)receipt
    expectedConfiguration:(NSDictionary *)expected error:(NSError **)error;
- (NSDictionary *)safeStatus;
@end
#if LBX_LICENSE_VAULT_TESTING
@interface LBXLicenseVault (Testing)
- (void)testUsePublicKey:(NSData *)key keyID:(NSString *)keyID;
+ (void)testPristineBoundaryHandler:(nullable void (^)(NSString *boundary))handler;
+ (void)testStopPristineAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
