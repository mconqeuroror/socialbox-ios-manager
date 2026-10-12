#pragma once
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, RBXWorkspaceTab) {
    RBXWorkspaceTabHome, RBXWorkspaceTabContainers, RBXWorkspaceTabLocation,
    RBXWorkspaceTabProxies, RBXWorkspaceTabSettings, RBXWorkspaceTabConnection
};
@protocol RBXWorkspacePageSelecting <NSObject>
- (BOOL)selectWorkspacePage:(RBXWorkspaceTab)page;
@end
// Programmatic tab changes must obey the same passcode guard as taps. Tags are
// explicit so setup links cannot silently land on the wrong page after reorder.
static inline BOOL RBXSelectWorkspaceTab(UIViewController *source, RBXWorkspaceTab tag) {
    UITabBarController *tabs = source.tabBarController;
    // Home is now a detail of Containers; proxy/location share Connection.
    // Preserve destination tags rather than treating them as array positions.
    RBXWorkspaceTab section = tag == RBXWorkspaceTabHome ? RBXWorkspaceTabContainers :
        ((tag == RBXWorkspaceTabProxies || tag == RBXWorkspaceTabLocation) ? RBXWorkspaceTabConnection : tag);
    for (UIViewController *target in tabs.viewControllers) {
        if (target.tabBarItem.tag != section) continue;
        id<UITabBarControllerDelegate> delegate = tabs.delegate;
        if ([delegate respondsToSelector:@selector(tabBarController:shouldSelectViewController:)] &&
            ![delegate tabBarController:tabs shouldSelectViewController:target]) return NO;
        if ([target conformsToProtocol:@protocol(RBXWorkspacePageSelecting)] &&
            ![(id<RBXWorkspacePageSelecting>)target selectWorkspacePage:tag]) return NO;
        tabs.selectedViewController = target;
        return YES;
    }
    return NO;
}
