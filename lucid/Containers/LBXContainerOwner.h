#import <Foundation/Foundation.h>
@class LBXLicenseOwner, LBXContainerConfigurationStore;
NS_ASSUME_NONNULL_BEGIN
// Service-internal consumer. The service must authenticate the kernel peer and
// exact packaged client before calling this. Payload fields confer no authority.
@interface LBXContainerOwner : NSObject
- (nullable instancetype)initWithLicenseOwner:(LBXLicenseOwner *)owner
                                       store:(nullable LBXContainerConfigurationStore *)store;
- (void)handleRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
