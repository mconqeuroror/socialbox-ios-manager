#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SBContainersView : UIView
- (instancetype)initWithOwner:(UIViewController *)owner;
- (void)refresh;
@end
NS_ASSUME_NONNULL_END
