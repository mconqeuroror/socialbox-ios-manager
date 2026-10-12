#import <UIKit/UIKit.h>
#import "SBBackendAdapter.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT void SBWorkspaceCoordinate(UIViewController *controller);
FOUNDATION_EXPORT UIViewController * _Nullable SBWorkspaceHost(UIViewController *from, SBScreen screen);
FOUNDATION_EXPORT void SBWorkspaceNavigate(UIViewController *from, SBScreen screen);
FOUNDATION_EXPORT UIView *SBConnectionSelector(UIViewController *owner);
FOUNDATION_EXPORT NSDictionary *SBWorkspaceNavigationStatus(UIViewController *controller);
NS_ASSUME_NONNULL_END
