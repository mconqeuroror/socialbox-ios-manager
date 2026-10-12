#import <UIKit/UIKit.h>
#import "RBXWorkspaceNavigation.h"
@class RBXLauncherViewController, RBXProxiesViewController;

// Navigation owns presentation only. The existing app-scoped controllers keep
// all data, request arguments, receipts, draft validation and license checks.
@interface RBXContainerNavigationController : UINavigationController <RBXWorkspacePageSelecting>
@property(nonatomic,readonly,strong) RBXLauncherViewController *containerController;
@property(nonatomic,readonly,strong) RBXLauncherViewController *overviewController;
- (instancetype)initWithContainers:(RBXLauncherViewController *)containers appType:(NSString *)appType;
@end

@interface RBXConnectionNavigationController : UINavigationController <RBXWorkspacePageSelecting>
@property(nonatomic,readonly,strong) RBXLauncherViewController *locationController;
@property(nonatomic,readonly,strong) RBXProxiesViewController *proxyController;
@property(nonatomic,readonly,strong) UISegmentedControl *pageSelector;
- (instancetype)initWithAppType:(NSString *)appType;
- (void)adoptWorkspaceUnlockFromController:(RBXLauncherViewController *)controller;
@end
