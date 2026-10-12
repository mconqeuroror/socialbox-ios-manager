// Source-owned responsive UI with synthetic containers only. No recovered core,
// license service, network request, container switch or device state is used.
#import <UIKit/UIKit.h>
#import "SBBackendAdapter.h"
#import "SBContainersView.h"
#import "SBWorkspaceCoordinator.h"
#import "SBDesign.h"
#import "LBXIsolationViewController.h"

static NSUInteger Checks, Operations;
static NSMutableArray *Failures,*Cases;
static void Check(BOOL result,NSString *message) { Checks++;if(!result)[Failures addObject:message]; }
static NSArray *Views(UIView *root,Class type) {
    NSMutableArray *items=[NSMutableArray array];if([root isKindOfClass:type])[items addObject:root];
    for(UIView *child in root.subviews)[items addObjectsFromArray:Views(child,type)];return items;
}
static UIView *Identified(UIView *root,NSString *identifier) {
    for(UIView *view in Views(root,UIView.class))if([view.accessibilityIdentifier isEqual:identifier])return view;return nil;
}
@implementation LBXIsolationViewController @end
@interface _Xv8i:NSObject
@property(nonatomic) long long containerID;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSArray *apps;
@end
@implementation _Xv8i @end
@interface SyntheticHost:UIViewController @end
@implementation SyntheticHost
- (void)showCreateContainerAlert { Operations++; }
- (void)importContainerTapped { Operations++; }
- (void)confirmSwitchToContainer:(id)container { (void)container;Operations++; }
- (void)editAppsForContainer:(id)container { (void)container;Operations++; }
- (void)showProxyPickerForContainer:(id)container { (void)container;Operations++; }
- (void)renameContainer:(id)container { (void)container;Operations++; }
- (void)exportContainer:(id)container { (void)container;Operations++; }
- (void)confirmDeleteContainer:(id)container { (void)container;Operations++; }
- (void)createFolderAndMoveContainer:(id)container { (void)container;Operations++; }
- (void)removeContainerFromFolder:(id)container { (void)container;Operations++; }
@end
#define SCREEN(NAME) @interface NAME:SyntheticHost @end @implementation NAME @end
SCREEN(HomeViewController)
SCREEN(LocSimViewController)
SCREEN(ProxyViewController)
SCREEN(SettingsViewController)
@interface _Xc9m:SyntheticHost
@property(nonatomic,copy) NSArray *containers;
@property(nonatomic) long long activeContainerID;
@property(nonatomic,strong) SBContainersView *surface;
@end
@implementation _Xc9m
- (void)viewDidLoad {
    [super viewDidLoad];NSMutableArray *records=[NSMutableArray array];
    for(NSUInteger index=0;index<40;index++) {
        _Xv8i *record=[_Xv8i new];record.containerID=500+(long long)index*17;
        record.name=[NSString stringWithFormat:@"Research %02lu — a long project name",(unsigned long)index+1];
        record.apps=@[@"com.fixture.long.application.identifier"];[records addObject:record];
    }
    self.containers=records;self.activeContainerID=500;self.view.backgroundColor=SBInk();
    self.surface=[[SBContainersView alloc] initWithOwner:self];self.surface.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.surface];
    [NSLayoutConstraint activateConstraints:@[[self.surface.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.surface.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.surface.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.surface.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];
}
- (NSString *)folderNameForContainerID:(long long)identifier { (void)identifier;return @"Long research folder name"; }
@end

@interface LayoutDelegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIViewController *root;
@property(nonatomic,strong) UITabBarController *tabs;
@property(nonatomic,strong) _Xc9m *containers;
@property(nonatomic,strong) NSArray *scenarios;
- (void)runScenario:(NSUInteger)index;
@end
@implementation LayoutDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;Failures=[NSMutableArray array];Cases=[NSMutableArray array];
    SBBackendFixtureConfigure(@{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"},NSBundle.mainBundle.executablePath);
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.root=[UIViewController new];self.window.rootViewController=self.root;[self.window makeKeyAndVisible];
    self.scenarios=@[
        @{@"name":@"320-portrait",@"width":@320,@"height":@568,@"category":UIContentSizeCategoryLarge},
        @{@"name":@"375-portrait",@"width":@375,@"height":@667,@"category":UIContentSizeCategoryLarge},
        @{@"name":@"390-portrait",@"width":@390,@"height":@844,@"category":UIContentSizeCategoryLarge},
        @{@"name":@"390-bottom-inset",@"width":@390,@"height":@844,@"category":UIContentSizeCategoryLarge,@"bottomInset":@34},
        @{@"name":@"667-landscape",@"width":@667,@"height":@375,@"category":UIContentSizeCategoryLarge},
        @{@"name":@"320-accessibility",@"width":@320,@"height":@568,@"category":UIContentSizeCategoryAccessibilityExtraExtraExtraLarge},
        @{@"name":@"390-accessibility",@"width":@390,@"height":@844,@"category":UIContentSizeCategoryAccessibilityExtraExtraExtraLarge}];
    dispatch_async(dispatch_get_main_queue(),^{[self runScenario:0];});return YES;
}
- (void)finish {
    Check(Operations==0,@"Rendering, resizing and scrolling never invoke a backend operation");
    NSDictionary *report=@{@"ok":Failures.count==0?@YES:@NO,@"assertions":@(Checks),@"failures":Failures,@"cases":Cases,@"backendOperations":@(Operations),
        @"scope":@"Actual source-owned minimal Containers UIKit at seven synthetic viewport sizes/content-size traits. No recovered-core, keyboard-input or physical device acceptance."};
    NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"layout-result.json"] atomically:YES];
}
- (void)runScenario:(NSUInteger)index {
    if(index>=self.scenarios.count){[self finish];return;}
    [self.window endEditing:YES];[self.tabs willMoveToParentViewController:nil];[self.tabs.view removeFromSuperview];[self.tabs removeFromParentViewController];
    NSDictionary *scenario=self.scenarios[index];self.tabs=[UITabBarController new];self.containers=[_Xc9m new];
    NSMutableArray *navs=[NSMutableArray array];
    for(UIViewController *owner in @[[HomeViewController new],self.containers,[LocSimViewController new],[ProxyViewController new],[SettingsViewController new]])
        [navs addObject:[[UINavigationController alloc] initWithRootViewController:owner]];
    self.tabs.viewControllers=navs;self.tabs.selectedIndex=1;
    [self.root addChildViewController:self.tabs];
    self.tabs.view.frame=CGRectMake(0,0,[scenario[@"width"] doubleValue],[scenario[@"height"] doubleValue]);
    [self.root.view addSubview:self.tabs.view];[self.tabs didMoveToParentViewController:self.root];
    [self.root setOverrideTraitCollection:[UITraitCollection traitCollectionWithPreferredContentSizeCategory:scenario[@"category"]] forChildViewController:self.tabs];
    [self.containers loadViewIfNeeded];SBWorkspaceCoordinate(self.containers);[self.tabs.view layoutIfNeeded];
    if(scenario[@"bottomInset"])self.tabs.additionalSafeAreaInsets=UIEdgeInsetsMake(0,0,[scenario[@"bottomInset"] doubleValue],0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [self.tabs.view layoutIfNeeded];[self.containers.surface layoutIfNeeded];
        [self inspect:scenario];[self runScenario:index+1];
    });
}
- (void)inspect:(NSDictionary *)scenario {
    NSString *name=scenario[@"name"];[self.window layoutIfNeeded];[self.tabs.view layoutIfNeeded];[self.containers.surface layoutIfNeeded];
    SBContainersView *surface=self.containers.surface;UITableView *table=Views(surface,UITableView.class).firstObject;
    UIButton *create=(id)Identified(surface,@"socialbox.containers.create");UIView *dock=Identified(self.tabs.view,@"socialbox.navigation");
    Check(table!=nil&&table.bounds.size.height>=44,[name stringByAppendingString:@": results retain a usable scroll viewport"]);
    Check(!surface.hasAmbiguousLayout&&!table.hasAmbiguousLayout&&!dock.hasAmbiguousLayout,[name stringByAppendingString:@": primary layout is unambiguous"]);
    Check(create.bounds.size.height>=44&&CGRectGetMinY(create.frame)>=0&&CGRectGetMaxX(create.frame)<=surface.bounds.size.width+.5,[name stringByAppendingString:@": create action fits and remains at least 44 points tall"]);
    Check(CGRectGetMaxY(table.frame)<=CGRectGetMinY(create.frame),[name stringByAppendingString:@": list never overlaps create action"]);
    Check(table.tableHeaderView.bounds.size.height>0&&table.contentSize.height>table.bounds.size.height,[name stringByAppendingString:@": header and all results share scrollable content"]);
    Check([table.dataSource tableView:table numberOfRowsInSection:0]==40,[name stringByAppendingString:@": preserves all forty records"]);
    NSMutableSet *identifiers=[NSMutableSet set];
    for(NSUInteger row=0;row<40;row++) {
        UITableViewCell *cell=[table.dataSource tableView:table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]];
        NSString *expected=[NSString stringWithFormat:@"socialbox.container.%lu",(unsigned long)(500+row*17)];
        Check([cell.accessibilityIdentifier isEqual:expected],[name stringByAppendingFormat:@": stable ID at row %lu",(unsigned long)row]);[identifiers addObject:cell.accessibilityIdentifier?:@""];
        UIButton *switchButton=(id)cell.accessoryView;UIListContentConfiguration *content=(id)cell.contentConfiguration;
        Check([content.text isEqual:[self.containers.containers[row] name]]&&content.textProperties.numberOfLines==0,[name stringByAppendingString:@": saved row names remain exact and fully wrapping"]);
        Check([switchButton isKindOfClass:UIButton.class]&&switchButton.bounds.size.width>=44&&switchButton.bounds.size.height>=44&&content.secondaryText==nil,[name stringByAppendingString:@": one reachable switch button with no app copy"]);

    }
    Check(identifiers.count==40,[name stringByAppendingString:@": no duplicate stable IDs"]);
    for(UILabel *label in Views(table.tableHeaderView,UILabel.class)) {
        if(CGRectIsEmpty(label.bounds))continue;CGRect text=[label convertRect:label.bounds toView:table.tableHeaderView];
        Check(text.origin.x>=-.5&&CGRectGetMaxX(text)<=table.tableHeaderView.bounds.size.width+.5,[name stringByAppendingString:@": header label stays within readable width"]);
    }
    UILabel *heading=(id)Identified(surface,@"socialbox.containers.title");
    UILabel *selectedName=(id)Identified(surface,@"socialbox.containers.selectedName");
    UILabel *swipeHint=(id)Identified(surface,@"socialbox.containers.swipeHint");
    Check([selectedName.text isEqual:[@"Selected: " stringByAppendingString:[self.containers.containers.firstObject name]]],[name stringByAppendingString:@": selected header retains exact saved name"]);
    Check(selectedName.font.pointSize<=20&&selectedName.numberOfLines==1&&selectedName.bounds.size.height<=ceil(selectedName.font.lineHeight)+1,[name stringByAppendingString:@": selected header remains one bounded line"]);
    Check(swipeHint.font.pointSize<=16&&swipeHint.numberOfLines==2,[name stringByAppendingString:@": discoverable gestures have a bounded hint"]);
    Check(heading&&heading.font.pointSize<=44,[name stringByAppendingString:@": bounded heading leaves room for rows"]);
    Check(!Identified(surface,@"socialbox.containers.search")&&!Identified(surface,@"socialbox.containers.tools")&&Views(surface,UISegmentedControl.class).count==0,[name stringByAppendingString:@": extra controls and app filters are absent"]);
    if(heading&&UIContentSizeCategoryIsAccessibilityCategory(surface.traitCollection.preferredContentSizeCategory)) {
        CGSize titleSize=[heading.text sizeWithAttributes:@{NSFontAttributeName:heading.font}];
        Check(titleSize.width<=heading.bounds.size.width+.5&&heading.bounds.size.height<=ceil(heading.font.lineHeight)+1,[name stringByAppendingString:@": heading fits without splitting"]);
    }
    Check(dock.bounds.size.height-dock.safeAreaInsets.bottom<=100,[name stringByAppendingString:@": navigation leaves room for content"]);
    NSArray *buttons=Views(dock,UIButton.class);Check(buttons.count==3,[name stringByAppendingString:@": original three-section navigation remains"]);
    for(UIButton *button in buttons) {
        CGRect rect=[button convertRect:button.bounds toView:dock];
        Check(rect.size.height>=44&&rect.origin.x>=-.5&&CGRectGetMaxX(rect)<=dock.bounds.size.width+.5&&CGRectGetMaxY(rect)<=dock.bounds.size.height-dock.safeAreaInsets.bottom+.5,[name stringByAppendingString:@": navigation button clears live safe area"]);
        Check(button.titleLabel.font.pointSize>=11&&button.titleLabel.font.pointSize<=16.5,[name stringByAppendingString:@": navigation caption remains legible"]);
        if(UIContentSizeCategoryIsAccessibilityCategory(surface.traitCollection.preferredContentSizeCategory))Check(button.titleLabel.font.pointSize>11,[name stringByAppendingString:@": navigation caption follows larger text"]);
    }
    NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.tabs.view.bounds];
    NSData *preview=[renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context){[self.tabs.view drawViewHierarchyInRect:self.tabs.view.bounds afterScreenUpdates:YES];}];
    [preview writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    [table scrollRectToVisible:table.tableHeaderView.frame animated:NO];[table layoutIfNeeded];
    Check(heading&&[heading isDescendantOfView:table]&&!CGRectIsEmpty(heading.bounds),[name stringByAppendingString:@": heading remains in scrollable content"]);
    [table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:39 inSection:0] atScrollPosition:UITableViewScrollPositionBottom animated:NO];[table layoutIfNeeded];
    Check([table.indexPathsForVisibleRows containsObject:[NSIndexPath indexPathForRow:39 inSection:0]],[name stringByAppendingString:@": last record can be reached"]);
    [table setContentOffset:CGPointZero animated:NO];
    CGFloat tableHeight=table.bounds.size.height,createY=create.frame.origin.y;
    _Xv8i *active=self.containers.containers.firstObject;NSString *originalName=active.name;
    CGFloat originalHeaderHeight=table.tableHeaderView.bounds.size.height;
    active.name=[@"Saved Unicode name ✨ " stringByPaddingToLength:512 withString:@"Long container name " startingAtIndex:0];[surface refresh];[surface layoutIfNeeded];
    Check(selectedName.text.length>512&&fabs(table.tableHeaderView.bounds.size.height-originalHeaderHeight)<1,[name stringByAppendingString:@": very long selected names do not enlarge the header"]);
    active.name=originalName;[surface refresh];[surface layoutIfNeeded];
    NSArray *original=self.containers.containers;self.containers.containers=@[];self.containers.activeContainerID=-1;[surface refresh];[surface layoutIfNeeded];
    Check([table.dataSource tableView:table numberOfRowsInSection:0]==0&&table.tableFooterView.bounds.size.height>0,[name stringByAppendingString:@": empty state stays readable"]);
    Check(selectedName.hidden&&swipeHint.hidden,[name stringByAppendingString:@": empty inventory does not invent a name or advertise gestures"]);
    self.containers.containers=original;self.containers.activeContainerID=500;[surface refresh];[surface layoutIfNeeded];
    Check([table.dataSource tableView:table numberOfRowsInSection:0]==40,[name stringByAppendingString:@": new valid snapshot restores all rows"]);
    [Cases addObject:@{@"name":name,@"width":@(surface.bounds.size.width),@"height":@(surface.bounds.size.height),@"tableHeight":@(tableHeight),@"headerHeight":@(table.tableHeaderView.bounds.size.height),@"dockHeight":@(dock.bounds.size.height),@"createY":@(createY),@"category":surface.traitCollection.preferredContentSizeCategory,@"viewportOriginY":@(self.tabs.view.frame.origin.y),@"windowHeight":@(self.window.bounds.size.height)}];
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(LayoutDelegate.class)); } }
