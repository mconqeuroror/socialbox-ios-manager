#import "RBXLauncherAppDelegate.h"
#import "RBXLauncherViewController.h"
#import "RBXAppearance.h"
#import "RBXSettingsViewController.h"
#import "RBXProxiesViewController.h"
#import "RBXAppScope.h"
#import "RBXAppSetupStatus.h"
#import "RBXWorkspaceNavigation.h"
#import "RBXWorkspaceNavigationController.h"
#import "RBXLicenseViewController.h"
#import "RBXLicensePresentation.h"

static NSString *const RBXGateStatePath = @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist";

// A cached inactive workspace refreshes the daemon publication when visible,
// including after returning from a completed source import. It sends no IPC.
@interface RBXAppPreparationViewController : UIViewController
@property(nonatomic, copy) NSDictionary *descriptor;
@property(nonatomic, strong) UILabel *sourceStatus;
@property(nonatomic, strong) UILabel *sourceDetail;
@property(nonatomic, strong) UILabel *networkStatus;
@property(nonatomic, strong) UILabel *networkDetail;
@property(nonatomic, strong) UIButton *setupButton;
@property(nonatomic, strong) NSTimer *refreshTimer;
@end
@implementation RBXAppPreparationViewController
- (void)refreshPreparation {
    NSDictionary *publication = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"];
    NSDictionary *status = RBXAppSetupStatus(publication, self.descriptor);
    self.sourceStatus.text = status[@"sourceTitle"];
    self.sourceStatus.textColor = [status[@"sourceReady"] boolValue] ? UIColor.systemGreenColor : UIColor.systemRedColor;
    self.sourceDetail.text = status[@"sourceDetail"];
    self.networkStatus.text = status[@"networkTitle"];
    self.networkStatus.textColor = [status[@"networkReady"] boolValue] ? UIColor.systemGreenColor : UIColor.systemRedColor;
    self.networkDetail.text = status[@"networkDetail"];
    [self.setupButton setTitle:status[@"sourceAction"] forState:UIControlStateNormal];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated]; [self refreshPreparation];
    [self.refreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshPreparation];
    }];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated]; [self.refreshTimer invalidate]; self.refreshTimer = nil;
}
- (void)dealloc { [self.refreshTimer invalidate]; }
@end

static UITabBarController *RBXBuildWorkspaceTabs(RBXLauncherViewController *containers, NSString *appType,
    id<UITabBarControllerDelegate> delegate) {
    RBXContainerNavigationController *library=[[RBXContainerNavigationController alloc] initWithContainers:containers appType:appType];
    RBXConnectionNavigationController *connection=[[RBXConnectionNavigationController alloc] initWithAppType:appType];
    UINavigationController *settings=[[UINavigationController alloc] initWithRootViewController:
        [[RBXSettingsViewController alloc] initWithAppType:appType proxyMode:NO]];
    NSArray *stacks=@[library,connection,settings];
    NSArray *titles=@[@"Containers",@"Connection",@"Settings"];
    NSArray *tags=@[@(RBXWorkspaceTabContainers),@(RBXWorkspaceTabConnection),@(RBXWorkspaceTabSettings)];
    for(NSUInteger index=0;index<stacks.count;index++) {
        UINavigationController *navigation=stacks[index];
        navigation.navigationBar.prefersLargeTitles=YES; RBXStyleNavigation(navigation);
        navigation.tabBarItem=[[UITabBarItem alloc] initWithTitle:titles[index] image:RBXSectionArtwork(index) tag:[tags[index] integerValue]];
        navigation.tabBarItem.accessibilityIdentifier=[@"socialbox.section." stringByAppendingString:[titles[index] lowercaseString]];
    }
    UITabBarController *tabs=[UITabBarController new]; tabs.delegate=delegate; tabs.viewControllers=stacks;
    UITabBarAppearance *appearance=[UITabBarAppearance new]; [appearance configureWithOpaqueBackground];
    appearance.backgroundColor=RBXCanvasColor(); appearance.shadowColor=UIColor.separatorColor;
    tabs.tabBar.standardAppearance=appearance; tabs.tabBar.scrollEdgeAppearance=appearance; tabs.tabBar.tintColor=RBXAccentColor();
    return tabs;
}

// Each app owns its navigation stacks and drafts. Additional runnable
// apps receive an independent, cached tree; inactive descriptors expose source setup only.
@interface RBXAppSelectorViewController : UIViewController
@property(nonatomic, strong) UITabBarController *redditWorkspace;
@property(nonatomic, strong) RBXLauncherViewController *containers;
@property(nonatomic, copy) NSArray<NSDictionary *> *descriptors;
@property(nonatomic, strong) UISegmentedControl *appSelector;
@property(nonatomic, strong) UIView *workspaceHost;
@property(nonatomic, strong) UIViewController *visibleWorkspace;
@property(nonatomic, strong) NSMutableDictionary<NSString *, UIViewController *> *workspaces;
@property(nonatomic) NSInteger selectedAppIndex;
@end

@implementation RBXAppSelectorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = RBXCanvasColor();
    self.descriptors = RBXRegisteredAppDescriptors();
    self.workspaces = [NSMutableDictionary dictionary];
    NSMutableArray *titles = [NSMutableArray array];
    for (NSDictionary *descriptor in self.descriptors) [titles addObject:descriptor[@"displayName"]];
    self.appSelector = [[UISegmentedControl alloc] initWithItems:titles];
    self.selectedAppIndex = [self.descriptors indexOfObject:RBXRedditAppDescriptor()];
    self.appSelector.selectedSegmentIndex = self.selectedAppIndex;
    self.appSelector.accessibilityLabel = @"Choose app workspace";
    self.appSelector.accessibilityIdentifier = @"socialbox.app-selector";
    [self.appSelector addTarget:self action:@selector(selectApp:)
        forControlEvents:UIControlEventValueChanged];
    self.appSelector.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.appSelector];
    self.workspaceHost = [UIView new];
    self.workspaceHost.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.workspaceHost];
    [NSLayoutConstraint activateConstraints:@[
        [self.appSelector.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.appSelector.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
        [self.appSelector.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
        [self.appSelector.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [self.workspaceHost.topAnchor constraintEqualToAnchor:self.appSelector.bottomAnchor constant:8],
        [self.workspaceHost.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.workspaceHost.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.workspaceHost.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    [self showWorkspace:self.redditWorkspace];
}

- (UIViewController *)placeholderForDescriptor:(NSDictionary *)descriptor {
    RBXAppPreparationViewController *placeholder = [RBXAppPreparationViewController new];
    placeholder.descriptor = descriptor;
    placeholder.view.backgroundColor = RBXCanvasColor();
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [placeholder.view addSubview:scroll];
    UILabel *title = RBXLabel(descriptor[@"displayName"], UIFontTextStyleLargeTitle, NO);
    title.accessibilityTraits |= UIAccessibilityTraitHeader;
    NSDictionary *status = RBXAppSetupStatus(nil, descriptor);
    placeholder.sourceStatus = RBXLabel(@"Checking imported IPA…", UIFontTextStyleHeadline, YES);
    placeholder.sourceStatus.accessibilityIdentifier = @"socialbox.source-status";
    placeholder.sourceDetail = RBXLabel(@"", UIFontTextStyleBody, YES);
    UILabel *execution = RBXLabel(status[@"executionTitle"], UIFontTextStyleHeadline, YES);
    execution.textColor = UIColor.systemRedColor;
    execution.accessibilityIdentifier = @"socialbox.execution-status";
    UILabel *detail = RBXLabel(status[@"executionDetail"], UIFontTextStyleBody, YES);
    placeholder.networkStatus = RBXLabel(@"Checking network setup…", UIFontTextStyleHeadline, YES);
    placeholder.networkStatus.accessibilityIdentifier = @"socialbox.network-status";
    placeholder.networkDetail = RBXLabel(@"", UIFontTextStyleBody, YES);
    UIButton *setup = [UIButton buttonWithType:UIButtonTypeSystem];
    [setup setTitle:@"Source setup" forState:UIControlStateNormal];
    setup.accessibilityIdentifier = @"socialbox.source-setup";
    RBXStyleButton(setup, NO);
    [setup addTarget:self action:@selector(openSelectedAppSetup) forControlEvents:UIControlEventTouchUpInside];
    placeholder.setupButton = setup;
    UIStackView *content = RBXVerticalStack(@[title, placeholder.sourceStatus, placeholder.sourceDetail,
        execution, detail, placeholder.networkStatus, placeholder.networkDetail, setup], 16);
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:placeholder.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:placeholder.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:placeholder.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:placeholder.view.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];
    return placeholder;
}

- (void)openSelectedAppSetup {
    if (![self.containers workspaceUnlocked] || [self hasPresentedController]) return;
    NSDictionary *descriptor = self.descriptors[self.selectedAppIndex];
    RBXSettingsViewController *settings = [[RBXSettingsViewController alloc]
        initWithAppType:descriptor[@"appType"] proxyMode:NO];
    settings.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done"
        style:UIBarButtonItemStyleDone target:self action:@selector(closeSelectedAppSetup)];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    RBXStyleNavigation(navigation);
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)closeSelectedAppSetup { [self dismissViewControllerAnimated:YES completion:nil]; }

- (UIViewController *)workspaceForDescriptor:(NSDictionary *)descriptor {
    NSString *appType = descriptor[@"appType"];
    if ([appType isEqual:@"reddit"]) return self.redditWorkspace;
    UIViewController *cached = self.workspaces[appType];
    if (cached) return cached;
    if (![descriptor[@"runnable"] boolValue]) {
        cached = [self placeholderForDescriptor:descriptor];
    } else {
        RBXLauncherViewController *containers = [[RBXLauncherViewController alloc] initWithAppType:appType advancedMode:NO];
        [containers adoptWorkspaceUnlockFromController:self.containers];
        cached = RBXBuildWorkspaceTabs(containers,appType,self.redditWorkspace.delegate);
    }
    self.workspaces[appType] = cached;
    return cached;
}

- (BOOL)hasPresentedController {
    UIViewController *controller = self;
    while (controller) {
        if (controller.presentedViewController) return YES;
        if ([controller isKindOfClass:UITabBarController.class])
            controller = ((UITabBarController *)controller).selectedViewController;
        else if ([controller isKindOfClass:UINavigationController.class])
            controller = ((UINavigationController *)controller).visibleViewController;
        else controller = controller == self ? self.visibleWorkspace : nil;
    }
    return NO;
}

- (void)selectApp:(UISegmentedControl *)sender {
    NSInteger selected = sender.selectedSegmentIndex;
    if (selected < 0 || selected >= (NSInteger)self.descriptors.count ||
        !RBXAppScopeMaySelect(self.descriptors[selected][@"appType"],
            [self.containers workspaceUnlocked], [self hasPresentedController])) {
        sender.selectedSegmentIndex = self.selectedAppIndex;
        return;
    }
    if (selected == self.selectedAppIndex) return;
    self.selectedAppIndex = selected;
    NSDictionary *descriptor = self.descriptors[selected];
    UIViewController *workspace = [self workspaceForDescriptor:descriptor];
    [self showWorkspace:workspace];
}

- (void)openSharedFacebook {
    if (![self.containers workspaceUnlocked] || [self hasPresentedController]) return;
    NSDictionary *descriptor = RBXAppDescriptorForType(@"facebook");
    NSInteger index = [self.descriptors indexOfObject:descriptor];
    if (index == NSNotFound) return;
    self.selectedAppIndex = index; self.appSelector.selectedSegmentIndex = index;
    UIViewController *workspace = [self workspaceForDescriptor:descriptor];
    [self showWorkspace:workspace];
    if (![descriptor[@"runnable"] boolValue] || ![workspace isKindOfClass:UITabBarController.class]) return;
    UITabBarController *tabs = (UITabBarController *)workspace;
    UINavigationController *navigation = tabs.viewControllers.firstObject;
    // Never discard a draft or a presented controller for an external URL.
    if (navigation.viewControllers.count != 1) return;
    tabs.selectedIndex = 0;
    RBXLauncherViewController *home = (RBXLauncherViewController *)navigation.viewControllers.firstObject;
    [home adoptWorkspaceUnlockFromController:self.containers];
    [home openFromSharedIcon];
}

- (void)showWorkspace:(UIViewController *)workspace {
    UIViewController *previous = self.visibleWorkspace;
    if (previous == workspace) return;
    // Detaching the inactive tree also makes view.window nil, so durable Reddit
    // receipts cannot present alerts over another app's workspace.
    BOOL appeared = self.view.window != nil;
    [previous willMoveToParentViewController:nil];
    [self addChildViewController:workspace];
    if (appeared) {
        [previous beginAppearanceTransition:NO animated:NO];
        [workspace beginAppearanceTransition:YES animated:NO];
    }
    [previous.view removeFromSuperview];
    workspace.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.workspaceHost addSubview:workspace.view];
    [NSLayoutConstraint activateConstraints:@[
        [workspace.view.topAnchor constraintEqualToAnchor:self.workspaceHost.topAnchor],
        [workspace.view.bottomAnchor constraintEqualToAnchor:self.workspaceHost.bottomAnchor],
        [workspace.view.leadingAnchor constraintEqualToAnchor:self.workspaceHost.leadingAnchor],
        [workspace.view.trailingAnchor constraintEqualToAnchor:self.workspaceHost.trailingAnchor],
    ]];
    [previous removeFromParentViewController];
    [workspace didMoveToParentViewController:self];
    self.visibleWorkspace = workspace;
    if (appeared) {
        [previous endAppearanceTransition];
        [workspace endAppearanceTransition];
    }
}

@end

@interface RBXLauncherAppDelegate () <UITabBarControllerDelegate>
@property(nonatomic, strong) RBXLauncherViewController *containers;
@property(nonatomic, strong) RBXAppSelectorViewController *workspaceController;
@property(nonatomic, strong) RBXLicenseViewController *activationController;
@property(nonatomic, strong) UINavigationController *activationNavigation;
@property(nonatomic, strong) NSTimer *activationTimer;
@property(nonatomic, strong) UIView *privacyCover;
@property(nonatomic) BOOL updatingLicenseGate;
- (void)refreshLicenseGate;
@end

static void RBXRootLicensePublicationChanged(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    __weak RBXLauncherAppDelegate *delegate = (__bridge RBXLauncherAppDelegate *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [delegate refreshLicenseGate]; });
}

@implementation RBXLauncherAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = RBXPreferredAppearance();
    self.window.tintColor = RBXAccentColor();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, RBXRootLicensePublicationChanged,
        CFSTR("com.redditbox.launcherStateChanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    // Decide the entire root before showing the window. No workspace controller
    // or hidden tab tree is constructed until a fresh grant is published.
    [self refreshLicenseGate];
    [self.window makeKeyAndVisible];
    __weak typeof(self) weakSelf = self;
    self.activationTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshLicenseGate];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.activationTimer forMode:NSRunLoopCommonModes];
    return YES;
}

- (RBXAppSelectorViewController *)buildLicensedWorkspace {
    self.containers = [RBXLauncherViewController new];
    UITabBarController *tabs=RBXBuildWorkspaceTabs(self.containers,@"reddit",self);
    RBXAppSelectorViewController *selector = [RBXAppSelectorViewController new];
    selector.redditWorkspace = tabs;
    selector.containers = self.containers;
    return selector;
}

- (void)refreshLicenseGate {
    NSAssert(NSThread.isMainThread, @"The root entitlement gate runs on the main thread");
    if (self.updatingLicenseGate) return;
    self.updatingLicenseGate = YES;
    NSDictionary *state = RBXLicensePresentationState(
        [NSDictionary dictionaryWithContentsOfFile:RBXGateStatePath], NSDate.date.timeIntervalSince1970);
    if ([state[@"unlocked"] boolValue]) {
        if (!self.workspaceController) {
            [self.window endEditing:YES];
            self.workspaceController = [self buildLicensedWorkspace];
            self.window.rootViewController = self.workspaceController;
            self.activationController = nil;
            self.activationNavigation = nil;
        }
    } else {
        if (!self.activationController) {
            self.activationController = [[RBXLicenseViewController alloc]
                initWithLicenseState:state appType:@"reddit" activationOnly:YES];
            self.activationNavigation = [[UINavigationController alloc] initWithRootViewController:self.activationController];
            RBXStyleNavigation(self.activationNavigation);
            self.activationNavigation.navigationBarHidden = YES;
            self.activationNavigation.interactivePopGestureRecognizer.enabled = NO;
            self.activationNavigation.modalInPresentation = YES;
        }
        if (self.window.rootViewController != self.activationNavigation) {
            // Replace the entire tree, including Facebook, Settings and sheets.
            // A dismissible modal or a license page in one tab cannot lock them.
            [self.window endEditing:YES];
            UIViewController *previous = self.window.rootViewController;
            previous.view.userInteractionEnabled = NO;
            previous.view.accessibilityElementsHidden = YES;
            [previous dismissViewControllerAnimated:NO completion:nil];
            self.window.rootViewController = self.activationNavigation;
            // UIKit can retain a dismissing modal briefly; remove its old root
            // immediately so no workspace pixels or hit targets remain visible.
            [previous.view removeFromSuperview];
            self.workspaceController = nil;
            self.containers = nil;
        }
        [self.activationController updateLicenseState:state];
    }
    if (self.privacyCover) {
        self.window.rootViewController.view.accessibilityElementsHidden = YES;
        [self.window bringSubviewToFront:self.privacyCover];
    }
    self.updatingLicenseGate = NO;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // Cover the app-switcher snapshot and any presented editor/Cloud sheet.
    // Foregrounding re-checks the daemon before this opaque cover is removed.
    [self.window endEditing:YES];
    if (!self.privacyCover) {
        UIView *cover = [[UIView alloc] initWithFrame:self.window.bounds];
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        cover.backgroundColor = RBXCanvasColor();
        cover.accessibilityIdentifier = @"socialbox.privacy-cover";
        cover.accessibilityViewIsModal = YES;
        UILabel *title = RBXLabel(@"SocialBox", UIFontTextStyleTitle1, NO);
        title.translatesAutoresizingMaskIntoConstraints = NO;
        [cover addSubview:title];
        [NSLayoutConstraint activateConstraints:@[
            [title.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
            [title.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
        ]];
        self.privacyCover = cover;
        [self.window addSubview:cover];
    }
    self.window.rootViewController.view.accessibilityElementsHidden = YES;
    [self.window bringSubviewToFront:self.privacyCover];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self refreshLicenseGate];
    [self.privacyCover removeFromSuperview];
    self.privacyCover = nil;
    self.window.rootViewController.view.accessibilityElementsHidden = NO;
}

- (void)dealloc {
    [self.activationTimer invalidate];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, NULL, NULL);
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    if (![url.absoluteString isEqual:@"socialbox://open/facebook"]) return NO;
    [self refreshLicenseGate];
    if (!self.workspaceController || self.privacyCover) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Revocation can arrive between URL delivery and this queued callback.
        [self refreshLicenseGate];
        if (self.workspaceController && !self.privacyCover) [self.workspaceController openSharedFacebook];
    });
    return YES;
}

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)viewController {
    [self refreshLicenseGate];
    if (!self.workspaceController || self.privacyCover) return NO;
    // After device licensing, the independent launcher passcode still applies.
    BOOL allowed = viewController == tabBarController.viewControllers.firstObject || [self.containers workspaceUnlocked];
    if (allowed && [viewController isKindOfClass:UINavigationController.class]) {
        UIViewController *root = ((UINavigationController *)viewController).viewControllers.firstObject;
        if ([root isKindOfClass:RBXLauncherViewController.class] && root != self.containers)
            [(RBXLauncherViewController *)root adoptWorkspaceUnlockFromController:self.containers];
        if ([viewController isKindOfClass:RBXConnectionNavigationController.class])
            [(RBXConnectionNavigationController *)viewController adoptWorkspaceUnlockFromController:self.containers];
    }
    return allowed;
}

@end
