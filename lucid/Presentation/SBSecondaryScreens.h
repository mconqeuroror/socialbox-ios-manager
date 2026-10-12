#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Called after the backend's view construction/refresh. A recognized secondary
// screen always receives our presentation, including a bounded unavailable view
// when its native UIKit surface cannot be verified. No backend work is started.
FOUNDATION_EXPORT BOOL SBSecondaryApply(UIViewController *owner);
FOUNDATION_EXPORT void SBSecondaryRefresh(UIViewController *owner);
FOUNDATION_EXPORT void SBSecondaryStyleTableCell(UIViewController *owner,
                                                UITableView *table,
                                                UITableViewCell *cell,
                                                NSIndexPath *indexPath);
FOUNDATION_EXPORT void SBSecondaryStyleTableHeader(UIViewController *owner,
                                                  UITableView *table,
                                                  UIView *header);
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SBSecondaryStatus(void);

// Entirely local reading material. It neither loads remote content nor calls a
// backend constructor/action. The workspace can push this controller directly.
@interface SBGuideViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
