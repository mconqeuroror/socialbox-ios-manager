#import "SBInterfaceCopy.h"
#import "SBWorkspaceCoordinator.h"
#import "SBDesign.h"
#import <objc/runtime.h>

// Retain the admitted five-controller backend shell. Only our dock is visible;
// the original controller array/order remains stable for its internal callbacks.
// Never construct an admitted shell or replace the application's window root.
@interface SBDockSurface : UIView
@property(nonatomic,copy) void (^updateLayout)(void);
@end
@implementation SBDockSurface
- (void)layoutSubviews { [super layoutSubviews];if(self.updateLayout)self.updateLayout(); }
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange];[self setNeedsLayout]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];[self setNeedsLayout];
}
@end
@interface SBWorkspaceCoordinator : NSObject
@property(nonatomic,weak) UITabBarController *host;
@property(nonatomic,strong) UIView *dock;
@property(nonatomic,strong) NSArray<UIButton *> *buttons;
@property(nonatomic,strong) NSArray<NSValue *> *originalInsets;
@property(nonatomic,strong) NSLayoutConstraint *rowHeight;
@property(nonatomic,strong) UIFont *dockFont;
- (void)updateLayout;
@property(nonatomic) BOOL selectedInitial, redirectPending;
@property(nonatomic) SBScreen connectionScreen;
- (void)refresh;
@end
static char CoordinatorKey;
static UIViewController *Root(UIViewController *v) { return [v isKindOfClass:UINavigationController.class] ? ((UINavigationController *)v).viewControllers.firstObject : v; }
UIViewController *SBWorkspaceHost(UIViewController *from,SBScreen screen) {
    UITabBarController *tabs=from.tabBarController;
    if(!tabs && [from isKindOfClass:UITabBarController.class]) tabs=(id)from;
    for(UIViewController *nav in tabs.viewControllers) { UIViewController *root=Root(nav);if(SBBackendScreen(root)==screen)return root; }
    return nil;
}
void SBWorkspaceNavigate(UIViewController *from,SBScreen screen) {
    UIViewController *target=SBWorkspaceHost(from,screen);if(!target)return;
    UITabBarController *tabs=from.tabBarController;UIViewController *entry=target.navigationController ?: target;
    if(![tabs.viewControllers containsObject:entry])return;
    // Keep pending forms/confirmations intact. Navigation itself invokes no
    // storage, regeneration, switching, license, or network operation.
    if(tabs.presentedViewController)return;
    tabs.selectedViewController=entry;
    if([entry isKindOfClass:UINavigationController.class])[(UINavigationController *)entry popToRootViewControllerAnimated:NO];
    SBWorkspaceCoordinator *coordinator=objc_getAssociatedObject(tabs,&CoordinatorKey);
    if(screen==SBScreenLocation || screen==SBScreenProxies)coordinator.connectionScreen=screen;
    [coordinator refresh];
}
@implementation SBWorkspaceCoordinator
- (void)updateLayout {
    UITabBarController *tabs=self.host;if(!tabs || !self.rowHeight)return;
    CGFloat width=MAX(1,(tabs.view.bounds.size.width-24)/3),height=68;
    UIFont *font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2] scaledFontForFont:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold] maximumPointSize:16 compatibleWithTraitCollection:tabs.traitCollection];
    BOOL fontChanged=![self.dockFont isEqual:font];
    for(UIButton *button in self.buttons) {
        // Re-evaluate against live traits instead of freezing the dock's text
        // size or its bottom inset during an early viewDidLoad callback.
        // Persistent navigation caps caption growth so three destinations remain
        // readable in one row; content continues scaling fully in scroll views.
        if(fontChanged) {
            UIButtonConfiguration *config=button.configuration;
            config.titleTextAttributesTransformer=^NSDictionary *(NSDictionary *input){NSMutableDictionary *d=[input mutableCopy];d[NSFontAttributeName]=font;return d;};
            button.configuration=config;
        }
        CGSize fit=[button systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height)
            withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        height=MAX(height,ceil(fit.height));
    }
    self.dockFont=font;
    if(fabs(self.rowHeight.constant-height)>.5)self.rowHeight.constant=height;
    for(NSUInteger index=0;index<tabs.viewControllers.count;index++) {
        UIViewController *entry=tabs.viewControllers[index];UIEdgeInsets inset=self.originalInsets[index].UIEdgeInsetsValue;inset.bottom+=height;
        if(!UIEdgeInsetsEqualToEdgeInsets(entry.additionalSafeAreaInsets,inset))entry.additionalSafeAreaInsets=inset;
    }
}
- (void)refresh {
    UITabBarController *tabs=self.host;if(!tabs)return;
    tabs.tabBar.hidden=YES;[tabs.view bringSubviewToFront:self.dock];[self updateLayout];
    SBScreen screen=SBBackendScreen(Root(tabs.selectedViewController));
    NSUInteger selected=(screen==SBScreenLocation || screen==SBScreenProxies)?1:((screen==SBScreenSettings || screen==SBScreenHome)?2:0);
    for(NSUInteger i=0;i<self.buttons.count;i++) {
        UIButton *b=self.buttons[i];b.selected=i==selected;
        UIButtonConfiguration *c=b.configuration;c.baseForegroundColor=b.selected?SBAccent():SBMuted();b.configuration=c;
        b.accessibilityTraits=UIAccessibilityTraitButton | (b.selected?UIAccessibilityTraitSelected:0);
    }
}
@end
void SBWorkspaceCoordinate(UIViewController *controller) {
    if(!NSThread.isMainThread)return;
    UITabBarController *tabs=controller.tabBarController;if(!tabs || tabs.viewControllers.count!=5)return;
    NSMutableSet *roles=[NSMutableSet set];
    for(UIViewController *entry in tabs.viewControllers) [roles addObject:@(SBBackendScreen(Root(entry)))];
    NSSet *required=[NSSet setWithArray:@[@(SBScreenHome),@(SBScreenContainers),@(SBScreenLocation),@(SBScreenProxies),@(SBScreenSettings)]];
    if(![roles isEqual:required])return;
    SBWorkspaceCoordinator *coordinator=objc_getAssociatedObject(tabs,&CoordinatorKey);
    if(!coordinator) {
        coordinator=[SBWorkspaceCoordinator new];coordinator.host=tabs;coordinator.connectionScreen=SBScreenProxies;
        objc_setAssociatedObject(tabs,&CoordinatorKey,coordinator,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SBDockSurface *dock=[SBDockSurface new];dock.backgroundColor=SBInk();dock.translatesAutoresizingMaskIntoConstraints=NO;dock.accessibilityIdentifier=@"socialbox.navigation";
        [tabs.view addSubview:dock];coordinator.dock=dock;
        NSMutableArray *buttons=[NSMutableArray array];
        NSArray *titles=@[SBUIText(@"nav.containers"),SBUIText(@"nav.connection"),SBUIText(@"nav.settings")],*icons=@[@"containers",@"connection",@"settings"];
        __weak SBWorkspaceCoordinator *weak=coordinator;dock.updateLayout=^{[weak updateLayout];};
        for(NSUInteger i=0;i<3;i++) {
            UIButton *button=SBButton(titles[i],icons[i],NO,^{
                SBWorkspaceCoordinator *s=weak;
                SBScreen target=i==0?SBScreenContainers:(i==1?s.connectionScreen:SBScreenSettings);
                SBWorkspaceNavigate(Root(s.host.selectedViewController),target);
            });
            UIButtonConfiguration *config=button.configuration;config.imagePlacement=NSDirectionalRectEdgeTop;config.imagePadding=6;config.contentInsets=NSDirectionalEdgeInsetsMake(10,4,8,4);
            config.titleLineBreakMode=NSLineBreakByWordWrapping;button.configuration=config;button.titleLabel.numberOfLines=0;button.titleLabel.textAlignment=NSTextAlignmentCenter;
            button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentCenter;button.accessibilityIdentifier=[@"socialbox.nav." stringByAppendingString:icons[i]];[buttons addObject:button];
        }
        coordinator.buttons=buttons;UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:buttons];row.axis=UILayoutConstraintAxisHorizontal;row.distribution=UIStackViewDistributionFillEqually;row.translatesAutoresizingMaskIntoConstraints=NO;[dock addSubview:row];
        coordinator.rowHeight=[row.heightAnchor constraintEqualToConstant:68];
        [NSLayoutConstraint activateConstraints:@[[dock.leadingAnchor constraintEqualToAnchor:tabs.view.leadingAnchor],[dock.trailingAnchor constraintEqualToAnchor:tabs.view.trailingAnchor],[dock.bottomAnchor constraintEqualToAnchor:tabs.view.bottomAnchor],[row.leadingAnchor constraintEqualToAnchor:dock.leadingAnchor constant:12],[row.trailingAnchor constraintEqualToAnchor:dock.trailingAnchor constant:-12],[row.topAnchor constraintEqualToAnchor:dock.topAnchor],[row.bottomAnchor constraintEqualToAnchor:dock.safeAreaLayoutGuide.bottomAnchor],coordinator.rowHeight]];
        NSMutableArray *insets=[NSMutableArray array];
        for(UIViewController *entry in tabs.viewControllers)[insets addObject:[NSValue valueWithUIEdgeInsets:entry.additionalSafeAreaInsets]];
        coordinator.originalInsets=insets;
    }
    [coordinator refresh];
    if(!coordinator.selectedInitial && !coordinator.redirectPending) {
        coordinator.redirectPending=YES;__weak SBWorkspaceCoordinator *weak=coordinator;
        dispatch_async(dispatch_get_main_queue(), ^{
            SBWorkspaceCoordinator *s=weak;s.selectedInitial=YES;s.redirectPending=NO;
            // Initial overview is a navigation choice only. Never repeat it on
            // refresh, so later user selections and modal flows remain stable.
            if(SBBackendScreen(Root(s.host.selectedViewController))==SBScreenHome)
                SBWorkspaceNavigate(Root(s.host.selectedViewController),SBScreenContainers);
        });
    }
}
UIView *SBConnectionSelector(UIViewController *owner) {
    UISegmentedControl *selection=[[UISegmentedControl alloc] initWithItems:@[SBUIText(@"nav.proxy"),SBUIText(@"nav.location")]];selection.selectedSegmentIndex=SBBackendScreen(owner)==SBScreenLocation?1:0;
    selection.selectedSegmentTintColor=SBPanel();selection.accessibilityLabel=SBUIText(@"nav.connectionType");selection.accessibilityIdentifier=@"socialbox.connection.mode";
    __weak UIViewController *weak=owner;[selection addAction:[UIAction actionWithHandler:^(UIAction *a){
        UISegmentedControl *control=(id)a.sender;SBWorkspaceNavigate(weak,control.selectedSegmentIndex==1?SBScreenLocation:SBScreenProxies);
    }] forControlEvents:UIControlEventValueChanged];return selection;
}
NSDictionary *SBWorkspaceNavigationStatus(UIViewController *controller) {
    SBWorkspaceCoordinator *s=objc_getAssociatedObject(controller.tabBarController,&CoordinatorKey);
    return @{@"installed":@(s!=nil),@"sections":@[@"containers",@"connection",@"settings"],@"originalControllersRetained":@(s.host.viewControllers.count==5),@"backendAdmissionChanged":@NO};
}
