#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
// Handles the shared identity-rule screen after the original view builder. The
// form never creates an identity, calls a private selector, or changes a setting
// during rendering. Existing controls/gesture carriers retain their callbacks.
FOUNDATION_EXPORT BOOL SBIdentityApply(UIViewController *owner);
FOUNDATION_EXPORT void SBIdentityRefresh(UIViewController *owner);
// Fixed reason codes and counts only: no identity values or user-provided text.
FOUNDATION_EXPORT NSDictionary<NSString *, id> *SBIdentityStatus(UIViewController *owner);
NS_ASSUME_NONNULL_END
