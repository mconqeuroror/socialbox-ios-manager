#import <Foundation/Foundation.h>
#include <stdint.h>
@class LBXContainerConfiguration;
NS_ASSUME_NONNULL_BEGIN

// Private source-owned physical-context snapshot. This is not a manufactured
// device profile, runtime grant, or evidence that a platform sees a new device.
// Configuration strings remain exact; reservation aliases are normalized only
// in reservationKeys. Facts describe the observed owner device/OS, while
// manufacturer/TAC/operator/advertising relationships remain UNVERIFIED.
// Never log/export privateDictionary, physicalContext or reservationKeys.
@interface LBXContainerIdentitySpecification : NSObject
+ (nullable instancetype)createWithConfiguration:(LBXContainerConfiguration *)configuration error:(NSError **)error;
+ (nullable instancetype)fromDictionary:(id)dictionary error:(NSError **)error;
@property(nonatomic, readonly, copy) NSDictionary<NSString *,id> *privateDictionary;
@property(nonatomic, readonly, copy) NSString *configurationIdentifier;
@property(nonatomic, readonly) uint64_t configurationRevision;
@property(nonatomic, readonly, copy) NSString *configurationSHA256;
@property(nonatomic, readonly, copy) NSDictionary<NSString *,NSString *> *reservationKeys;
@property(nonatomic, readonly, copy) NSDictionary<NSString *,id> *physicalContext;
@property(nonatomic, readonly, copy) NSDictionary<NSString *,id> *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_CONTAINER_IDENTITY_SPECIFICATION_TESTING
@interface LBXContainerIdentitySpecification (Testing)
+ (void)testUsePhysicalContext:(nullable NSDictionary *)context;
+ (nullable instancetype)testCreateWithConfiguration:(LBXContainerConfiguration *)configuration
                                    physicalContext:(id)context error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
