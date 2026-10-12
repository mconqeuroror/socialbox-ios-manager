#import "SBAppDelegate.h"
#import "SBContainersViewController.h"
#import "SBProxyViewController.h"
#import "SBLocationViewController.h"
#import "SBDesign.h"
#import "SBInterfaceCopy.h"

static UINavigationController *SBNav(UIViewController *root, NSString *title, NSString *glyph) {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = NO;
    UINavigationBarAppearance *bar = [UINavigationBarAppearance new];
    [bar configureWithOpaqueBackground];
    bar.backgroundColor = SBInk();
    bar.shadowColor = UIColor.clearColor;
    bar.titleTextAttributes = @{
        NSForegroundColorAttributeName : UIColor.whiteColor,
        NSFontAttributeName : [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
    };
    nav.navigationBar.standardAppearance = bar;
    nav.navigationBar.scrollEdgeAppearance = bar;
    nav.navigationBar.compactAppearance = bar;
    nav.navigationBar.tintColor = SBAccent();
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:title image:SBGlyph(glyph) tag:0];
    return nav;
}

@implementation SBAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = SBInk();
    self.window.tintColor = SBAccent();

    UITabBarController *tabs = [UITabBarController new];
    tabs.view.backgroundColor = SBInk();
    tabs.view.tintColor = SBAccent();
    tabs.viewControllers = @[
        SBNav([SBContainersViewController new], SBUIText(@"nav.containers"), @"containers"),
        SBNav([SBProxyViewController new], SBUIText(@"nav.proxy"), @"connection"),
        SBNav([SBLocationViewController new], SBUIText(@"nav.location"), @"location"),
    ];
    UITabBarAppearance *dock = [UITabBarAppearance new];
    [dock configureWithOpaqueBackground];
    dock.backgroundColor = SBPanel();
    dock.shadowColor = UIColor.clearColor;
    tabs.tabBar.standardAppearance = dock;
    if (@available(iOS 15.0, *)) tabs.tabBar.scrollEdgeAppearance = dock;
    tabs.tabBar.barStyle = UIBarStyleBlack;
    tabs.tabBar.tintColor = SBAccent();
    tabs.tabBar.unselectedItemTintColor = SBMuted();
    tabs.tabBar.accessibilityIdentifier = @"socialbox.tabs";

    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
