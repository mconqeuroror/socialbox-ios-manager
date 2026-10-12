#import <Foundation/Foundation.h>
@class LBXLicenseOwner, LBXContainerConfigurationStore, LBXLicenseInstallationEstablishment;
NS_ASSUME_NONNULL_BEGIN
// Authenticated fixed-manager boundary is enforced by the service. This owner
// supplies one shared signed source fence per typed request; it never admits the
// retained engine or maps a source UUID to an old numeric CID.
// Retirement stages the exact strictly unreserved authored document, preserves
// every unfinished slot, and holds strict retired-record proof through clear.
// It supplies no pending discard, allocated purge or runtime authority.
@interface LBXContainerRootMutationOwner : NSObject
- (nullable instancetype)initWithLicenseOwner:(LBXLicenseOwner *)owner
    configurationStore:(LBXContainerConfigurationStore *)configurations pendingDirectory:(NSString *)directory;
// Shipping owner binds the exact prepared installation object; no public
// request can choose paths or invoke establishment. Completion runs on this
// separate trusted queue, safely outside the source owner's completion queue.
- (nullable instancetype)initWithPreparedInstallation:(LBXLicenseInstallationEstablishment *)installation
    pendingDirectory:(NSString *)directory;
- (void)establishPreparedPendingBeforeDeadline:(double)deadline completion:(void (^)(BOOL ready))completion;
- (void)handleRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *reply))completion;
// Only old typed read/list are bridged, retaining request ID and deadline.
// Old prepare/create/update are rejected; there is no legacy-owner fallback.
- (void)handleLegacyConfigurationQuery:(NSDictionary *)request completion:(void (^)(NSDictionary *reply))completion;
@end
#if LBX_CONTAINER_ROOT_PENDING_TESTING
@interface LBXContainerRootMutationOwner (Testing)
- (void)testStopAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
