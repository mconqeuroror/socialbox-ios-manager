#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Root owns the entitlement gate and dismisses this controller only after a
// fresh daemon-published unlocked state. This controller never performs HTTP.
@interface RBXLicenseViewController : UIViewController
- (instancetype)initWithLicenseState:(nullable NSDictionary *)licenseState;
- (nullable instancetype)initWithLicenseState:(nullable NSDictionary *)licenseState appType:(NSString *)appType;
// Used by the window-level lock gate. Creates no maintenance/server controls.
- (nullable instancetype)initWithLicenseState:(nullable NSDictionary *)licenseState appType:(NSString *)appType activationOnly:(BOOL)activationOnly;
- (void)updateLicenseState:(nullable NSDictionary *)licenseState;
@end

NS_ASSUME_NONNULL_END
