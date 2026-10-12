#import <Foundation/Foundation.h>
@class LBXNativeSwitchCoordinator, LBXNativeFamilyStorageLayout, LBXNativeInstalledManagerPin;
NS_ASSUME_NONNULL_BEGIN

// Inert manager-facing transaction schema. Never forwards to the recovered
// switch worker. Create/delete/deactivate/saveApps stay refused. Switch may
// reach the source coordinator only after a verified original-manager pin and
// family CID admission. A matching pin is not an installed switch.
@interface LBXNativeManagerBridge : NSObject
+ (instancetype)bridge;
- (NSDictionary *)dispatchRequest:(NSDictionary *)request
                     coordinator:(LBXNativeSwitchCoordinator *)coordinator
                    familyLayout:(LBXNativeFamilyStorageLayout *)layout
                     managerPin:(nullable LBXNativeInstalledManagerPin *)pin
                  beforeDeadline:(double)deadline;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
