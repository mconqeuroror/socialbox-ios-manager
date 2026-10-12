#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// A human-readable, anonymous snapshot fetched through the configured HTTP
// proxy. This screen never changes a container, rotates a proxy, or logs in.
@interface RBXAccountStatusViewController : UIViewController
- (instancetype)initWithUsername:(nullable NSString *)username;
@end

NS_ASSUME_NONNULL_END
