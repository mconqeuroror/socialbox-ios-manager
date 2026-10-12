#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, RBXWorkspacePage) {
    RBXWorkspacePageContainers, RBXWorkspacePageHome, RBXWorkspacePageLocation
};

@interface RBXLauncherViewController : UITableViewController
@property(nonatomic) RBXWorkspacePage workspacePage;
- (instancetype)initWithAdvancedMode:(BOOL)advancedMode;
- (instancetype)initWithAppType:(NSString *)appType advancedMode:(BOOL)advancedMode;
- (BOOL)workspaceUnlocked;
- (void)openFromSharedIcon;
- (void)adoptWorkspaceUnlockFromController:(RBXLauncherViewController *)controller;
@end
