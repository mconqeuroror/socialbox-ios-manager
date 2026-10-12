#import "RBXWorkspaceNavigationController.h"
#import "RBXLauncherViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXAppScope.h"

@interface RBXContainerNavigationController ()
@property(nonatomic,copy) NSString *appType;
@end
@implementation RBXContainerNavigationController
@synthesize overviewController=_overviewController;
- (instancetype)initWithContainers:(RBXLauncherViewController *)containers appType:(NSString *)appType {
    if(!containers||!RBXAppDescriptorForType(appType))return nil;
    if((self=[super initWithRootViewController:containers])) {
        _containerController=containers; _appType=[appType copy];
    }
    return self;
}
- (RBXLauncherViewController *)overviewController {
    if(!_overviewController) {
        _overviewController=[[RBXLauncherViewController alloc] initWithAppType:self.appType advancedMode:NO];
        _overviewController.workspacePage=RBXWorkspacePageHome;
    }
    return _overviewController;
}
- (BOOL)selectWorkspacePage:(RBXWorkspaceTab)page {
    if(self.presentedViewController||self.topViewController.presentedViewController)return NO;
    if(page==RBXWorkspaceTabContainers) {
        if(self.viewControllers.count==1)return YES;
        if(self.viewControllers.count==2&&self.topViewController==_overviewController) {
            [self popToRootViewControllerAnimated:NO]; return YES;
        }
        return NO; // Never discard an editor, wizard or Cloud navigation stack.
    }
    if(page!=RBXWorkspaceTabHome||![self.containerController workspaceUnlocked])return NO;
    if(self.topViewController==_overviewController)return YES;
    if(self.viewControllers.count!=1)return NO;
    RBXLauncherViewController *overview=self.overviewController;
    [overview adoptWorkspaceUnlockFromController:self.containerController];
    [self pushViewController:overview animated:NO]; return YES;
}
@end

@interface RBXConnectionNavigationController ()
@property(nonatomic,weak) RBXLauncherViewController *unlockOwner;
@end
@implementation RBXConnectionNavigationController
- (instancetype)initWithAppType:(NSString *)appType {
    if(!RBXAppDescriptorForType(appType))return nil;
    RBXProxiesViewController *proxy=[[RBXProxiesViewController alloc] initWithAppType:appType];
    if((self=[super initWithRootViewController:proxy])) {
        _proxyController=proxy;
        _locationController=[[RBXLauncherViewController alloc] initWithAppType:appType advancedMode:NO];
        _locationController.workspacePage=RBXWorkspacePageLocation;
        _pageSelector=[[UISegmentedControl alloc] initWithItems:@[@"Proxy",@"Location"]];
        _pageSelector.selectedSegmentIndex=0;
        _pageSelector.accessibilityIdentifier=@"socialbox.connection-pages";
        _pageSelector.accessibilityLabel=@"Connection page";
        [_pageSelector addTarget:self action:@selector(changePage:) forControlEvents:UIControlEventValueChanged];
        proxy.navigationItem.titleView=_pageSelector;
    }
    return self;
}
- (void)adoptWorkspaceUnlockFromController:(RBXLauncherViewController *)controller {
    self.unlockOwner=controller;
    [self.locationController adoptWorkspaceUnlockFromController:controller];
}
- (BOOL)selectWorkspacePage:(RBXWorkspaceTab)page {
    if(page==RBXWorkspaceTabConnection)return YES;
    if(page!=RBXWorkspaceTabProxies&&page!=RBXWorkspaceTabLocation)return NO;
    if(![self.unlockOwner workspaceUnlocked]||self.viewControllers.count!=1||
       self.presentedViewController||self.topViewController.presentedViewController)return NO;
    UIViewController *target=page==RBXWorkspaceTabLocation?self.locationController:self.proxyController;
    if(target!=self.topViewController) {
        [self.topViewController.view endEditing:YES];
        self.topViewController.navigationItem.titleView=nil;
        [self setViewControllers:@[target] animated:NO];
        target.navigationItem.titleView=self.pageSelector;
    }
    self.pageSelector.selectedSegmentIndex=page==RBXWorkspaceTabLocation?1:0;
    return YES;
}
- (void)changePage:(UISegmentedControl *)sender {
    NSInteger requested=sender.selectedSegmentIndex;
    // Use the exact tab delegate/license/passcode path for segment taps too.
    BOOL allowed=requested>=0&&requested<=1&&RBXSelectWorkspaceTab(self,
        requested==1?RBXWorkspaceTabLocation:RBXWorkspaceTabProxies);
    if(!allowed)sender.selectedSegmentIndex=self.topViewController==self.locationController?1:0;
}
@end
