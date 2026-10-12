#import <UIKit/UIKit.h>
// Deliberately no IPC, private Keychain group, selected ID or network privilege.
// The main launcher owns passcode/license UI and the daemon resolves selection.
@interface SBXFacebookEntry : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UILabel *status;
@end
@implementation SBXFacebookEntry
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *screen=[UIViewController new];
    screen.view.backgroundColor=[UIColor colorWithWhite:.065 alpha:1];
    self.status=[UILabel new]; self.status.text=@"Facebook · SocialBox\nOpening your selected container…";
    self.status.textColor=UIColor.whiteColor;self.status.numberOfLines=0;
    self.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];self.status.textAlignment=NSTextAlignmentCenter;
    self.status.translatesAutoresizingMaskIntoConstraints=NO;[screen.view addSubview:self.status];
    [NSLayoutConstraint activateConstraints:@[[self.status.centerYAnchor constraintEqualToAnchor:screen.view.centerYAnchor],
        [self.status.leadingAnchor constraintEqualToAnchor:screen.view.leadingAnchor constant:28],
        [self.status.trailingAnchor constraintEqualToAnchor:screen.view.trailingAnchor constant:-28]]];
    self.window.rootViewController=screen;[self.window makeKeyAndVisible];return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    [application openURL:[NSURL URLWithString:@"socialbox://open/facebook"] options:@{} completionHandler:^(BOOL success) {
        if(!success)self.status.text=@"Open SocialBox to finish setup.\nThis icon cannot open Facebook without SocialBox.";
    }];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(SBXFacebookEntry.class));}}
