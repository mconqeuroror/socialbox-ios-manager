#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Immutable, private ROOT OBSERVATION of the official Instagram or Facebook
// installation. No parser, supplied path/backend/PID, license, admission, launch
// or data/group authority is accepted. This does not verify publisher signatures,
// Frameworks, whole-bundle integrity, running-process identity or account/device
// isolation. Never log/export privateDictionary: it contains paths, identities
// and digests.
@interface LBXInstalledApplicationBinding : NSObject
+ (nullable instancetype)observeOfficialInstagram:(NSError **)error;
+ (nullable instancetype)observeOfficialFacebook:(NSError **)error;
- (BOOL)matchesCurrentInstallation:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *privateDictionary;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_INSTALLED_APPLICATION_BINDING_TESTING
@interface LBXInstalledApplicationBinding (Testing)
// Real temporary files, fixed Instagram metadata and current host UID only.
// Exact registration keys: bundlePath, canonicalExecutablePath. nil clears.
// Root layout remains <physical installationRoot>/<UUID>/<bundle>.app.
+ (void)testUseRegistration:(nullable NSDictionary *)registration
          installationRoot:(nullable NSString *)root;
// Invoked after initial descriptor metadata and before content hashing. The
// void fixture callback cannot supply observation facts, bytes or a grant.
+ (void)testAfterOpeningFile:(nullable void (^)(NSString *path))callback;
// Mutation-only fixture boundary after the fixed final registration calls;
// the real inventory, metadata and deadline must still be checked afterward.
+ (void)testAfterFinalRegistration:(nullable void (^)(void))callback;
@end
#endif
NS_ASSUME_NONNULL_END
