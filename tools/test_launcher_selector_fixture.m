// UIKit containment fixture: compile the shipped app delegate unchanged, with
// inert workspace controllers so this test cannot issue daemon or cloud work.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RBXLauncherAppDelegate.h"
#import "RBXLauncherViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXSettingsViewController.h"
#import "RBXAppRegistry.h"

static NSDictionary *setupPublication;
@interface NSDictionary (AppSetupFixture)
+ (id)setupDictionaryWithContentsOfFile:(NSString *)path;
@end
@implementation NSDictionary (AppSetupFixture)
+ (id)setupDictionaryWithContentsOfFile:(NSString *)path {
    if ([path isEqual:@"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"]) return setupPublication;
    return [self setupDictionaryWithContentsOfFile:path];
}
@end

static BOOL RBXTestUnlocked;
static NSUInteger RBXWorkspaceInstances;
static NSMutableArray<NSString *> *RBXWorkspaceTypes;
@implementation RBXLauncherViewController
- (instancetype)init { return [self initWithAppType:@"reddit" advancedMode:NO]; }
- (instancetype)initWithAppType:(NSString *)appType advancedMode:(BOOL)mode { self = [super initWithStyle:UITableViewStylePlain]; if (self) { RBXWorkspaceInstances++; [RBXWorkspaceTypes addObject:appType]; } return self; }
- (instancetype)initWithAdvancedMode:(BOOL)mode { return [self init]; }
- (BOOL)workspaceUnlocked { return RBXTestUnlocked; }
- (void)adoptWorkspaceUnlockFromController:(RBXLauncherViewController *)controller { NSCAssert([controller workspaceUnlocked], @"only an authorized selector can transfer unlock"); }
@end
@implementation RBXProxiesViewController
- (instancetype)init { return [self initWithAppType:@"reddit"]; }
- (instancetype)initWithAppType:(NSString *)appType { self = [super initWithStyle:UITableViewStylePlain]; if (self) { RBXWorkspaceInstances++; [RBXWorkspaceTypes addObject:appType]; } return self; }
@end
@implementation RBXSettingsViewController
- (instancetype)initWithProxyMode:(BOOL)mode { return [self initWithAppType:@"reddit" proxyMode:mode]; }
- (instancetype)initWithAppType:(NSString *)appType proxyMode:(BOOL)mode { self = [super initWithNibName:nil bundle:nil]; if (self) { RBXWorkspaceInstances++; [RBXWorkspaceTypes addObject:appType]; } return self; }
- (instancetype)initWithAppType:(NSString *)appType wizardMode:(BOOL)mode { return [self initWithAppType:appType proxyMode:NO]; }
- (instancetype)initWithWizardMode:(BOOL)mode { return [self initWithProxyMode:NO]; }
- (void)importSourceForAppType:(NSString *)type { [NSException raise:@"UnexpectedImport" format:@"Inactive placeholder must not import"]; }
@end

static void RBXWriteResult(BOOL ok, NSString *message) {
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"selector-result.json"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"ok":@(ok),@"message":message}
        options:NSJSONWritingSortedKeys error:nil];
    [data writeToFile:path atomically:YES];
}
#define CHECK(value, message) do { if (!(value)) { RBXWriteResult(NO, message); return; } } while (0)
static void RBXSelect(UISegmentedControl *control, NSInteger index) {
    control.selectedSegmentIndex = index;
    [control sendActionsForControlEvents:UIControlEventValueChanged];
}

static UIButton *RBXFindSourceButton(UIView *view) {
    if ([view isKindOfClass:UIButton.class] && [view.accessibilityIdentifier isEqual:@"socialbox.source-setup"]) return (UIButton *)view;
    for (UIView *child in view.subviews) { UIButton *found = RBXFindSourceButton(child); if (found) return found; }
    return nil;
}

@interface RBXSelectorTestDelegate : RBXLauncherAppDelegate
@end
@implementation RBXSelectorTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    RBXWorkspaceTypes = [NSMutableArray array];
    setupPublication = @{@"source":@{@"decrypted":@YES}};
    method_exchangeImplementations(class_getClassMethod(NSDictionary.class,@selector(dictionaryWithContentsOfFile:)),class_getClassMethod(NSDictionary.class,@selector(setupDictionaryWithContentsOfFile:)));
    BOOL result = [super application:application didFinishLaunchingWithOptions:options];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self runChecks]; });
    return result;
}
- (void)runChecks {
    BOOL facebookRunnable = [RBXAppDescriptorForType(@"facebook")[@"runnable"] boolValue];
    NSUInteger expectedInstances = facebookRunnable ? 10 : 5;
    UIViewController *selector = self.window.rootViewController;
    UISegmentedControl *control = [selector valueForKey:@"appSelector"];
    UITabBarController *tabs = [selector valueForKey:@"redditWorkspace"];
    CHECK(control.numberOfSegments == 2, @"Registered app selector has Reddit and Facebook");
    CHECK(control.selectedSegmentIndex == 0 && tabs.parentViewController == selector, @"Reddit is the initial workspace");
    CHECK(tabs.view.window == self.window && tabs.viewControllers.count == 5, @"Original tab tree is attached");
    CHECK(RBXWorkspaceInstances == 5, @"Exactly one original workspace instance per screen");
    RBXSelect(control, 1);
    CHECK(control.selectedSegmentIndex == 0 && tabs.parentViewController == selector, @"Locked app switch must be rejected");
    CHECK(![tabs.delegate tabBarController:tabs shouldSelectViewController:tabs.viewControllers[1]], @"Locked proxy tab must remain denied");
    RBXTestUnlocked = YES;
    CHECK([tabs.delegate tabBarController:tabs shouldSelectViewController:tabs.viewControllers[2]], @"Unlock restores original tab guard");
    tabs.selectedIndex = 2;
    UINavigationController *navigation = (UINavigationController *)tabs.selectedViewController;
    UIViewController *editor = [UIViewController new];
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(20, 80, 200, 48)];
    field.text = @"unsaved draft stays";
    [editor.view addSubview:field];
    [navigation pushViewController:editor animated:NO];
    [self.window layoutIfNeeded];
    CGRect headerFrame = [control convertRect:control.bounds toView:selector.view];
    CGRect workspaceFrame = [tabs.view convertRect:tabs.view.bounds toView:selector.view];
    CHECK(CGRectGetMinY(workspaceFrame) >= CGRectGetMaxY(headerFrame), @"App selector cannot cover existing navigation");
    RBXSelect(control, 1);
    CHECK(control.selectedSegmentIndex == 1 && tabs.parentViewController == nil, @"Facebook detaches Reddit controller tree");
    CHECK(tabs.view.window == nil && editor.view.window == nil, @"Hidden Reddit receipts cannot present over Facebook");
    UIViewController *facebookWorkspace = [selector valueForKey:@"visibleWorkspace"];
    CHECK(selector.childViewControllers.count == 1 && RBXWorkspaceInstances == expectedInstances, @"Inactive Facebook constructs no workspace; active Facebook gets exactly one independent tree");
    if (!facebookRunnable) {
        UILabel *source = [facebookWorkspace valueForKey:@"sourceStatus"];
        CHECK([source.text isEqual:@"Facebook IPA not imported"], @"Reddit source is not shown as Facebook");
        setupPublication = @{@"sources":@{@"facebook":@{@"decrypted":@YES,@"version":@"578.1.0"}}};
        [facebookWorkspace performSelector:@selector(refreshPreparation)];
        CHECK([source.text isEqual:@"Facebook IPA imported · v578.1.0"], @"Actual placeholder shows imported FB version");
        CHECK([RBXFindSourceButton(facebookWorkspace.view).currentTitle isEqual:@"Source details"], @"Ready source no longer asks for import");
        CHECK([((UILabel *)[facebookWorkspace valueForKey:@"networkStatus"]).text isEqual:@"Network protection not verified"], @"Missing network remains explicit");
    }
    if (facebookRunnable) {
        CHECK([facebookWorkspace isKindOfClass:UITabBarController.class], @"Runnable Facebook displays its tabs");
        CHECK(([[RBXWorkspaceTypes subarrayWithRange:NSMakeRange(5,5)] isEqual:@[@"facebook",@"facebook",@"facebook",@"facebook",@"facebook"]]), @"Every FB controller is explicitly app-bound");
        UITabBarController *facebookTabs = (UITabBarController *)facebookWorkspace;
        CHECK([facebookTabs.delegate tabBarController:facebookTabs shouldSelectViewController:facebookTabs.viewControllers[2]], @"Shared passcode permits the FB settings tab after unlock");
        facebookTabs.selectedIndex = 1;
    }
    RBXSelect(control, 0);
    CHECK(tabs.parentViewController == selector && tabs.view.window == self.window, @"Reddit restores the same workspace object");
    CHECK(tabs.selectedIndex == 2 && navigation.topViewController == editor && [field.text isEqual:@"unsaved draft stays"], @"Tab, navigation and unsaved editor state survive app switch");
    UIViewController *sheet = [UIViewController new];
    sheet.modalPresentationStyle = UIModalPresentationFormSheet;
    [editor presentViewController:sheet animated:NO completion:^{
        RBXSelect(control, 1);
        CHECK(control.selectedSegmentIndex == 0 && tabs.parentViewController == selector, @"Presented sheet prevents app switch");
        [sheet dismissViewControllerAnimated:NO completion:^{
            RBXSelect(control, 1);
            CHECK(control.selectedSegmentIndex == 1, @"App switch works after sheet finishes");
            RBXSelect(control, 0);
            CHECK(navigation.topViewController == editor && RBXWorkspaceInstances == expectedInstances, @"Repeated switching preserves original workspace");
            RBXSelect(control, 1);
            CHECK([selector valueForKey:@"visibleWorkspace"] == facebookWorkspace, @"Facebook workspace is cached across switches");
            if (facebookRunnable) CHECK(((UITabBarController *)facebookWorkspace).selectedIndex == 1, @"Facebook selected tab state survives switching");
            RBXSelect(control, 0);
            if (!facebookRunnable) {
                RBXSelect(control, 1);
                UIButton *setupButton = RBXFindSourceButton(facebookWorkspace.view);
                CHECK(setupButton != nil, @"Inactive Facebook exposes explicit source setup");
                [setupButton sendActionsForControlEvents:UIControlEventTouchUpInside];
                CHECK([selector.presentedViewController isKindOfClass:UINavigationController.class] && RBXWorkspaceInstances == 6 && [RBXWorkspaceTypes.lastObject isEqual:@"facebook"], @"Source setup constructs only a Facebook-bound settings controller");
                RBXSelect(control, 0);
                CHECK(control.selectedSegmentIndex == 1, @"Source setup modal prevents cross-app switch");
                [selector dismissViewControllerAnimated:NO completion:^{
                    RBXSelect(control, 0);
                    CHECK(navigation.topViewController == editor && [field.text isEqual:@"unsaved draft stays"], @"Source setup leaves Reddit editor unchanged");
                    RBXWriteResult(YES, @"UIKit inactive selector: scoped source setup, modal/passcode guards, cached placeholder and Reddit editor preservation passed");
                }];
                return;
            }
            RBXWriteResult(YES, facebookRunnable ? @"UIKit active selector: app-bound FB controllers, cached independent tabs, passcode/modal guards and Reddit editor preservation passed" : @"UIKit inactive selector: inert container placeholder, passcode/modal guards and Reddit editor preservation passed");
        }];
    }];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RBXSelectorTestDelegate.class)); }
}
