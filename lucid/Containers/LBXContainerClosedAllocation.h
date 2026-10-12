#import <Foundation/Foundation.h>
@class LBXContainerConfiguration, LBXContainerConfigurationStore, LBXLicenseOwner;
NS_ASSUME_NONNULL_BEGIN

// Root-only, private allocation of NEW closed data/groups namespaces. This is
// not an official app/group registration, complete identity, launch grant or
// isolation receipt. It never receives an owner app/container path or opens a
// directory to mobile. Private return values must not be logged or exported.
// The trusted assembler supplies a canonical physical absolute root path;
// symlink ancestors (including rootless aliases) are not traversed here.
@interface LBXContainerClosedAllocation : NSObject
+ (nullable instancetype)openDirectory:(NSString *)directory
                   configurationStore:(LBXContainerConfigurationStore *)store
                         licenseOwner:(LBXLicenseOwner *)owner
                               create:(BOOL)create error:(NSError **)error;
// Both APIs compare the exact current saved configuration and run under one
// source-license fence. Instagram-only membership and no proxy are required.
// Before first intent the exact saved configuration is durably reserved in
// its own store record; all ordinary edits thereafter conflict. A failure after
// reservation can leave no journal yet and still forbids edits. Exact recovery
// keeps that freeze; it never thaws or silently upgrades an old unknown-marker
// journal. Old/mixed allocator versions require an explicit quiesced migration.
// A changed snapshot/context conflicts. Every failure may follow durable
// effects: retain the original candidate/UUID, revalidate and reconcile it.
// Recovery never adopts an unbound post-create node or replaces an assigned
// inode. Initial infrastructure setup is explicit; existing damage is refused.
- (nullable NSDictionary *)ensureClosedAllocationForConfiguration:(LBXContainerConfiguration *)configuration
                                                    beforeDeadline:(double)deadline error:(NSError **)error;
- (nullable NSDictionary *)recoverClosedAllocationForConfiguration:(LBXContainerConfiguration *)configuration
                                                     beforeDeadline:(double)deadline error:(NSError **)error;
// Only format/count/closed-state flags, never UUIDs, paths, digests or identity.
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_CONTAINER_CLOSED_ALLOCATION_TESTING
@interface LBXContainerClosedAllocation (Testing)
// Failure-only synchronous interruption after an exact journal/effect boundary.
// Cannot grant authorization, replace context, assign an inode or open storage.
- (void)testStopAfterBoundary:(nullable NSString *)boundary;
@end
#endif
NS_ASSUME_NONNULL_END
