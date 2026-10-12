// The production SocialBox view code, with a synthetic backend. This proves
// presentation and action routing only, never recovered backend/device behavior.
#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import "LBXWorkspace.h"
#import "LBXDisplayCopy.h"
#import "LBXPresentation.h"
#import "SBBackendAdapter.h"
#import "SBWorkspaceCoordinator.h"
#import "SBContainersView.h"
#import "SBIdentityForm.h"
#import "SBUpdateService.h"
#import "SBActivationView.h"
#import "activation_transport_fixture.h"
#import "saved_setup_transport_fixture.h"
#import <objc/runtime.h>
void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *original) {
    (void)cls; (void)sel; (void)replacement; (void)original; abort(); // No hooks run in this rendering fixture.
}

static NSUInteger Checks, Actions;
static long long LastContainerID;
static id LastContainerObject;
static id LastProxySender;
static NSUInteger ProxyContextRequests;
static NSMutableArray *ProxyInteractionObservations;
static BOOL SettingsPresenterTop;
static NSUInteger SettingsConfirmationHandlers;
static NSUInteger SettingsConfirmationCompletions;
static NSMutableArray *CaptureReadiness;
static UIAlertController *SettingsConfirmation;
static NSDictionary *Metadata(void) { return @{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"}; }
static NSMutableArray *Failures;
static NSString *Directory;
static void Check(BOOL pass, NSString *reason) { Checks++; if(!pass) [Failures addObject:reason]; }
static NSArray *Views(UIView *root, Class type) {
    NSMutableArray *result=[NSMutableArray array];
    if([root isKindOfClass:type]) [result addObject:root];
    for(UIView *child in root.subviews) [result addObjectsFromArray:Views(child,type)];
    return result;
}
static UIView *Workspace(UIViewController *owner) {
    for(UIView *v in owner.view.subviews) if([v.accessibilityIdentifier isEqual:@"socialbox.workspace"]) return v;
    return nil;
}
static UIButton *FindButton(UIView *root, NSString *title) {
    for(UIButton *b in Views(root,UIButton.class)) if([(b.configuration.title ?: b.currentTitle) isEqual:title]) return b;
    return nil;
}
static UIView *ViewID(UIView *root, NSString *identifier) {
    for(UIView *view in Views(root,UIView.class)) if([view.accessibilityIdentifier isEqual:identifier]) return view;
    return nil;
}
static UIButton *ButtonID(UIView *root, NSString *identifier) { return (id)ViewID(root,identifier); }
static void ObserveProxyStructure(UIView *card, NSString *phase) {
    NSMutableArray *gestures=[NSMutableArray array],*interactions=[NSMutableArray array];
    for(UIGestureRecognizer *gesture in card.gestureRecognizers)
        [gestures addObject:@{@"class":NSStringFromClass(gesture.class),@"delegate":gesture.delegate?NSStringFromClass([(id)gesture.delegate class]):@"nil"}];
    for(id<UIInteraction> interaction in card.interactions)[interactions addObject:NSStringFromClass([(id)interaction class])];
    if(!ProxyInteractionObservations)ProxyInteractionObservations=[NSMutableArray array];
    [ProxyInteractionObservations addObject:@{@"phase":phase,@"gestures":gestures,@"interactions":interactions,
        @"enabled":@(card.userInteractionEnabled),@"data":@(ViewID(card,@"socialbox.proxy.row.data")!=nil)}];
}
static BOOL HasPrefix(UIView *root, NSString *prefix) {
    for(UILabel *label in Views(root,UILabel.class)) if([label.text hasPrefix:prefix]) return YES;
    return NO;
}
@interface _Xv8i : NSObject
@property(nonatomic) long long containerID;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSArray *apps;
@end
@implementation _Xv8i @end
@interface UnexpectedProxyInteraction : NSObject <UIInteraction>
@property(nonatomic,weak) UIView *view;
@end
@implementation UnexpectedProxyInteraction
- (void)willMoveToView:(UIView *)view { (void)view; }
- (void)didMoveToView:(UIView *)view { self.view=view; }
@end
static BOOL HasText(UIView *root, NSString *text) {
    for(UILabel *l in Views(root,UILabel.class)) if([l.text isEqual:text]) return YES;
    return NO;
}
static void AwaitUI(BOOL (^ready)(void), NSUInteger remaining, NSUInteger stable, void (^completion)(BOOL));
static void CheckActivationDenials(NSUInteger index, void (^finished)(void)) {
    NSArray *cases=@[@[@"revoked",@"This license has been revoked."],@[@"expired",@"This license has expired."],
        @[@"invalid",@"This SocialBox license is not valid."],@[@"busy",@"Another license check is in progress."],
        @[@"paired_key_mismatch",@"This installation is already paired with a different key."],
        @[@"recovery_required",@"This key could not be paired."],@[@"storage_unavailable",@"Your saved license cannot be read safely."],
        @[@"verification_failed",@"Your license could not be verified."],@[@"service_unavailable",@"The SocialBox licensing service is unavailable."],
        @[@"unreviewed remote text secret=hidden",@"The SocialBox licensing service is unavailable."]];
    if(index==cases.count){finished();return;}
    NSUInteger before=Actions,calls=SBTestLicenseRequestCount();
    SBActivationView *view=[SBActivationView new];
    UITextField *field=(id)ViewID(view,@"socialbox.activation.key");
    UIButton *button=ButtonID(view,@"socialbox.control.license.button");
    Check(calls==SBTestLicenseRequestCount(),@"new activation view does not contact any service while rendering");
    field.text=@"AAAA-BBBB-CCCC-DDDD";
    [field.delegate textFieldShouldReturn:field];[button sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(SBTestLicenseRequestCount()==calls+1&&!field.enabled&&!button.enabled,@"return submits once and locks duplicate activation while pending");
    SBTestLicenseComplete(cases[index][0]);
    dispatch_async(dispatch_get_main_queue(),^{
        Check(HasPrefix(view,cases[index][1])&&!HasPrefix(view,@"Your SocialBox license was verified."),@"denial or unknown result displays its own English error, never active");
        Check(field.enabled&&button.enabled&&[field.text isEqual:@"AAAA-BBBB-CCCC-DDDD"]&&Actions==before,@"denial preserves entered key and re-enables retry without invoking the original backend");
        [button sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        Check(SBTestLicenseRequestCount()==calls+2&&!button.enabled,@"a retry after a completed denial makes one fresh request");
        SBTestLicenseComplete(@"active");
        AwaitUI(^BOOL{return ![[view valueForKey:@"pending"] boolValue];},60,0,^(BOOL ready){
            Check(ready&&field.text.length==0&&field.enabled&&button.enabled&&HasPrefix(view,@"Your SocialBox license was verified.")&&Actions==before,@"successful retry confirms saved-setup readiness and never invokes recovered admission");
            CheckActivationDenials(index+1,finished);
        });
    });
}
static void Save(UIWindow *window, NSString *name) {
    [window layoutIfNeeded];
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
    __block BOOL drawn=NO;
    NSData *data=[renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context){ drawn=[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES]; }];
    Check(drawn,[@"UIKit completed screenshot rendering: " stringByAppendingString:name]);
    [data writeToFile:[Directory stringByAppendingPathComponent:name] atomically:YES];
}
static BOOL VisibleInWindow(UIView *view, UIWindow *window) {
    if(!view || view.window!=window || CGRectIsEmpty(view.bounds))return NO;
    for(UIView *ancestor=view;ancestor;ancestor=ancestor.superview)if(ancestor.hidden||ancestor.alpha<.01)return NO;
    return CGRectIntersectsRect([view convertRect:view.bounds toView:window],window.bounds);
}
static BOOL FullyVisibleInWindow(UIView *view, UIWindow *window) {
    if(!VisibleInWindow(view,window))return NO;
    CGRect visible=window.bounds;
    for(UIView *ancestor=view.superview;ancestor;ancestor=ancestor.superview)
        if(ancestor.clipsToBounds)visible=CGRectIntersection(visible,[ancestor convertRect:ancestor.bounds toView:window]);
    return CGRectContainsRect(CGRectInset(visible,-1,-1),[view convertRect:view.bounds toView:window]);
}
static BOOL DockContentVisible(UITabBarController *tabs, UIWindow *window) {
    UIView *dock=ViewID(tabs.view,@"socialbox.navigation");NSArray *buttons=Views(dock,UIButton.class);
    if(buttons.count!=3)return NO;
    for(UIButton *button in buttons)if(!VisibleInWindow(button.titleLabel,window)||!VisibleInWindow(button.imageView,window))return NO;
    return YES;
}
static void AwaitUI(BOOL (^ready)(void), NSUInteger remaining, NSUInteger stable, void (^completion)(BOOL)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.05*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSUInteger next=ready()?stable+1:0;
        if(next>=3 || remaining==0)completion(next>=3);
        else AwaitUI(ready,remaining-1,next,completion);
    });
}
// Tab selection changes its model/dock before UIKit finishes replacing the
// selected content. Capture only after actual content is visible and stable on
// successive run-loop turns; a timeout fails the fixture instead of concealing
// a production navigation failure with an arbitrary screenshot delay.
static void AwaitSelectedContent(UIWindow *window, UITabBarController *tabs, UIViewController *owner,
                                 UIView *content, UIViewController *previous, NSUInteger remaining,
                                 NSUInteger stable, void (^completion)(BOOL)) {
    __block NSDictionary *last;
    AwaitUI(^BOOL{
        [window layoutIfNeeded];UINavigationController *navigation=owner.navigationController;
        CGPoint point=[content convertPoint:CGPointMake(CGRectGetMidX(content.bounds),CGRectGetMidY(content.bounds)) toView:window];
        UIView *hit=[window hitTest:point withEvent:nil];
        last=@{@"appActive":@(UIApplication.sharedApplication.applicationState==UIApplicationStateActive),@"keyWindow":@(window.isKeyWindow),
            @"selectedNavigation":@(tabs.selectedViewController==navigation),@"topController":@(navigation.topViewController==owner),
            @"tabTransitionComplete":@(!tabs.transitionCoordinator),@"navigationTransitionComplete":@(!navigation.transitionCoordinator),
            @"previousTransitionComplete":@(!previous.navigationController.transitionCoordinator),@"modalDismissed":@(!tabs.presentedViewController),
            @"dockVisible":@(DockContentVisible(tabs,window)),@"contentVisible":@(VisibleInWindow(content,window)),
            @"previousNotVisible":@(!VisibleInWindow(previous.view,window)),@"contentHitTest":@(hit==content || [hit isDescendantOfView:content])};
        return ![last.allValues containsObject:@NO];
    },remaining,stable,^(BOOL ready){
        if(!CaptureReadiness)CaptureReadiness=[NSMutableArray array];
        [CaptureReadiness addObject:@{@"owner":NSStringFromClass(owner.class),@"ready":@(ready),@"checks":last ?: @{}}];
        completion(ready);
    });
}
@interface Host : UIViewController <UITableViewDataSource,UITableViewDelegate,UISearchBarDelegate,UITextFieldDelegate,MKMapViewDelegate,UIContextMenuInteractionDelegate>
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) CAGradientLayer *meshGradientLayer;
@property(nonatomic,strong) UILabel *source;
@property(nonatomic,strong) UILabel *model;
@property(nonatomic,strong) UILabel *device;
@property(nonatomic,strong) UILabel *version;
@property(nonatomic,strong) UILabel *loadingLabel;
@property(nonatomic,strong) UILabel *errorLabel;
@property(nonatomic,strong) UIButton *sourceButton;
@property(nonatomic,strong) UISwitch *sourceSwitch;
@property(nonatomic,strong) UITextField *licenseKeyField;
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UISearchBar *searchBar;
@property(nonatomic,strong) MKMapView *mapView;
@property(nonatomic,strong) UIButton *actionButton;
@property(nonatomic,strong) UISegmentedControl *mode;
@property(nonatomic) NSUInteger selected;
@property(nonatomic) BOOL denyRequired;
@property(nonatomic,copy) NSArray *containers;
@property(nonatomic) long long activeContainerID;
@property(nonatomic,strong) NSMutableDictionary<NSString *,UIView *> *proxyFixtureViews;
@property(nonatomic,strong) UIContextMenuInteraction *savedProxyContextMenu;
@property(nonatomic,copy) UIContextMenuActionProvider proxyFixtureMenuProvider;
@property(nonatomic,strong) Host *foreignProxyContextOwner;
- (void)buildProxyFixtureRows;
@end
@implementation Host
- (UILabel *)text:(NSString *)text {
    UILabel *label=[UILabel new]; label.text=text; label.textColor=UIColor.whiteColor; [self.contentStack addArrangedSubview:label]; return label;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.blackColor;
    NSMutableArray *rows=[NSMutableArray array];
    for(NSUInteger i=0;i<40;i++) {_Xv8i *row=[_Xv8i new];row.containerID=500+(long long)i*17;row.name=i==17?@"SocialBox":(i==5||i==6?@"Duplicate name":[NSString stringWithFormat:@"Research %02lu",(unsigned long)i+1]);row.apps=@[i%2?@"com.fixture.second":@"com.fixture.first"];[rows addObject:row];}
    self.containers=[[rows reverseObjectEnumerator] allObjects];self.activeContainerID=500;

    self.contentStack=[[UIStackView alloc] initWithFrame:CGRectMake(10,100,340,500)]; self.contentStack.axis=UILayoutConstraintAxisVertical;
    [self.view addSubview:self.contentStack];
    self.source=[self text:@"Test value · synthetic backend"]; self.model=[self text:@"iPhone 15 Pro"];
    self.device=[self text:@"Research workspace"]; self.version=[self text:@"iOS 18.6"];
    self.sourceButton=[UIButton buttonWithType:UIButtonTypeSystem]; [self.sourceButton setTitle:@"Original action" forState:0];
    [self.sourceButton addTarget:self action:@selector(performAction:) forControlEvents:UIControlEventTouchUpInside]; [self.contentStack addArrangedSubview:self.sourceButton];
    self.sourceSwitch=[UISwitch new]; self.sourceSwitch.on=YES;
    [self.sourceSwitch addTarget:self action:@selector(performAction:) forControlEvents:UIControlEventValueChanged]; [self.contentStack addArrangedSubview:self.sourceSwitch];
    self.licenseKeyField=[UITextField new]; self.licenseKeyField.text=@"SYNTHETIC-KEY-NOT-A-LICENSE"; self.licenseKeyField.secureTextEntry=YES; self.licenseKeyField.delegate=self;
    [self.contentStack addArrangedSubview:self.licenseKeyField];
    self.loadingLabel=[self text:@"Checking license…"]; self.loadingLabel.hidden=YES;
    self.errorLabel=[self text:@"Synthetic backend · license not activated"]; self.errorLabel.textColor=UIColor.systemRedColor;
    self.searchBar=[UISearchBar new]; self.searchBar.delegate=self; [self.view addSubview:self.searchBar];
    self.tableView=[[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain]; self.tableView.dataSource=self; self.tableView.delegate=self;
    [self.view addSubview:self.tableView];
    self.meshGradientLayer=[CAGradientLayer layer]; [self.view.layer insertSublayer:self.meshGradientLayer atIndex:0];
    if([NSStringFromClass(self.class) isEqual:@"LocSimViewController"]) {
        self.mapView=[[MKMapView alloc] initWithFrame:CGRectZero]; self.mapView.delegate=self;
        [self.view addSubview:self.mapView]; self.actionButton=[UIButton buttonWithType:UIButtonTypeSystem];
        [self.actionButton setTitle:@"Start simulation" forState:0]; [self.actionButton addTarget:self action:@selector(performAction:) forControlEvents:UIControlEventTouchUpInside];
        [self.contentStack addArrangedSubview:self.actionButton];
    }
    if([NSStringFromClass(self.class) isEqual:@"_Xm8u"]) self.sourceButton.enabled=NO;
    if([NSStringFromClass(self.class) isEqual:@"ProxyViewController"] || [NSStringFromClass(self.class) isEqual:@"FakeInfoViewController"]) {
        for(UIView *view in [self.contentStack.arrangedSubviews copy]) { [self.contentStack removeArrangedSubview:view]; [view removeFromSuperview]; }
        for(NSString *title in @[@"Primary connection", @"Backup connection"]) {
            UIView *card=[UIView new]; card.layer.cornerRadius=30; card.backgroundColor=UIColor.darkGrayColor;
            [card.heightAnchor constraintEqualToConstant:94].active=YES;
            UILabel *label=[UILabel new]; label.text=title; label.frame=CGRectMake(20,20,200,30); label.textColor=UIColor.whiteColor; [card addSubview:label];
            UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(performAction:)]; [card addGestureRecognizer:tap];
            [self.contentStack addArrangedSubview:card];
        }
        if([NSStringFromClass(self.class) isEqual:@"FakeInfoViewController"]) {
            self.mode=[[UISegmentedControl alloc] initWithItems:@[@"Range",@"Specific"]]; self.mode.selectedSegmentIndex=1;
            [self.mode addTarget:self action:@selector(performAction:) forControlEvents:UIControlEventValueChanged]; [self.contentStack insertArrangedSubview:self.mode atIndex:0];
        }
        if([NSStringFromClass(self.class) isEqual:@"ProxyViewController"]) [self buildProxyFixtureRows];
    }
}
- (void)proxyFixtureAction:(id)sender { LastProxySender=sender; Actions++; }
- (void)buildProxyFixtureRows {
    self.proxyFixtureViews=[NSMutableDictionary dictionary];
    for(NSString *role in @[@"system",@"rotate"]) {
        BOOL system=[role isEqual:@"system"];
        UIView *card=system ? [UIView new] : [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        UIView *content=[card isKindOfClass:UIVisualEffectView.class]?((UIVisualEffectView *)card).contentView:card;
        UILabel *title=[UILabel new];title.text=system?@"System Proxy (VPN)":@"Auto-Rotate IP";
        UILabel *detail=[UILabel new];detail.text=system?@"All traffic routed through proxy":@"Rotate IP on each container switch";
        [content addSubview:title];[content addSubview:detail];[content addSubview:[UIImageView new]];
        UISwitch *control=[UISwitch new];control.on=system;control.tag=system?41:42;
        [control addTarget:self action:@selector(proxyFixtureAction:) forControlEvents:UIControlEventValueChanged];[content addSubview:control];
        [card.heightAnchor constraintEqualToConstant:64].active=YES;
        [self.contentStack addArrangedSubview:card];self.proxyFixtureViews[role]=card;self.proxyFixtureViews[[role stringByAppendingString:@"Control"]]=control;
    }
    UIView *hero=[UIView new];UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisVertical;
    for(NSString *text in @[@"Add your first proxy",@"Each container can use a different exit IP so accounts cannot be correlated by network fingerprint.",@"Once added, assign a proxy per container from the Containers tab."]) {
        UILabel *label=[UILabel new];label.text=text;[hero addSubview:label];
    }
    for(NSString *text in @[@"Scan QR code",@"Paste a list",@"Import from Shadowrocket"]) {
        // Recovered makeHeroButtonWithTitle:glyph:action: (0x100206218)
        // formats each static caption with two leading spaces for its image.
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:[@"  " stringByAppendingString:text] forState:UIControlStateNormal];button.tag=43+actions.arrangedSubviews.count;
        button.hidden=[text isEqual:@"Scan QR code"];
        [button addTarget:self action:@selector(proxyFixtureAction:) forControlEvents:UIControlEventTouchUpInside];[actions addArrangedSubview:button];
        self.proxyFixtureViews[text]=button;
    }
    [hero addSubview:actions];[self.contentStack addArrangedSubview:hero];self.proxyFixtureViews[@"empty"]=hero;
    UIView *active=[UIView new];
    for(NSString *text in @[@"SocialBox user proxy",@"proxy.fixture:8080"]) {UILabel *label=[UILabel new];label.text=text;[active addSubview:label];self.proxyFixtureViews[text]=label;}
    [active addSubview:[UIImageView new]];
    for(NSUInteger i=0;i<2;i++) {
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tag=50+i;
        if(!i)button.accessibilityLabel=@"Check IP in Safari";
        button.enabled=i!=0;[button.widthAnchor constraintEqualToConstant:32].active=YES;[button.heightAnchor constraintEqualToConstant:32].active=YES;
        [button setImage:[UIImage systemImageNamed:i?@"xmark.circle.fill":@"globe"] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(proxyFixtureAction:) forControlEvents:UIControlEventTouchUpInside];[active addSubview:button];
        self.proxyFixtureViews[i?@"disconnect":@"checkIP"]=button;
    }
    [self.contentStack addArrangedSubview:active];self.proxyFixtureViews[@"active"]=active;
    // Reviewed makeProxyCard: leaves: status dot, protocol/name/endpoint,
    // optional selection image, and the exact tappable carrier. No network test.
    UIView *saved=[UIView new];[saved addSubview:[UIView new]];saved.tag=73;
    for(NSString *text in @[@"SOCKS5",@"Berlin · standby",@"de-edge.example.invalid:1080"]) {
        UILabel *label=[UILabel new];label.text=text;[saved addSubview:label];
    }
    UIImageView *selection=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle"]];[saved addSubview:selection];
    [saved addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(proxyFixtureAction:)]];
    // Native makeProxyCard: (0x10020636c) adds this exact public interaction
    // to the same tap/associated-model carrier, with the original owner delegate.
    self.savedProxyContextMenu=[[UIContextMenuInteraction alloc] initWithDelegate:self];
    [saved addInteraction:self.savedProxyContextMenu];
    [self.contentStack addArrangedSubview:saved];self.proxyFixtureViews[@"saved"]=saved;
    self.foreignProxyContextOwner=[Host new];
    for(NSString *role in @[@"extraContext",@"foreignContext"]) {
        UIView *card=[UIView new];UILabel *name=[UILabel new];name.text=@"Context fixture";[card addSubview:name];
        [card addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(proxyFixtureAction:)]];
        UIContextMenuInteraction *context=[[UIContextMenuInteraction alloc] initWithDelegate:[role isEqual:@"foreignContext"]?self.foreignProxyContextOwner:self];
        [card addInteraction:context];
        if([role isEqual:@"extraContext"])[card addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(proxyFixtureAction:)]];
        [self.contentStack addArrangedSubview:card];self.proxyFixtureViews[role]=card;
    }
    UIView *unsupported=[UIView new];UITextView *input=[UITextView new];input.text=@"Unsupported native input";[unsupported addSubview:input];
    UIButton *unexpected=[UIButton buttonWithType:UIButtonTypeSystem];[unexpected setTitle:@"Unexpected action" forState:UIControlStateNormal];[unexpected addTarget:self action:@selector(proxyFixtureAction:) forControlEvents:UIControlEventTouchUpInside];[unsupported addSubview:unexpected];
    [unsupported addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(proxyFixtureAction:)]];
    [self.contentStack addArrangedSubview:unsupported];self.proxyFixtureViews[@"unsupported"]=unsupported;self.proxyFixtureViews[@"unexpectedControl"]=unexpected;
}
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    (void)location;ProxyContextRequests++;
    Check(interaction==self.savedProxyContextMenu&&interaction.view==self.proxyFixtureViews[@"saved"],@"native-shaped context callback retains the same interaction and model carrier");
    self.proxyFixtureMenuProvider=^UIMenu *(__unused NSArray<UIMenuElement *> *suggested){
        return [UIMenu menuWithChildren:@[[UIAction actionWithTitle:@"Test Connection" image:nil identifier:nil handler:^(__unused UIAction *action){LastProxySender=interaction.view;Actions++;}]]];
    };
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:self.proxyFixtureMenuProvider];
}
- (void)performAction:(id)sender { (void)sender; Actions++; }
- (void)openConfigureSpoofing { Actions++; }
- (void)showAddProxyMenu { Actions++; }
- (void)importContainerTapped { Actions++; }
- (void)confirmSwitchToContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)editAppsForContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)showProxyPickerForContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)renameContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)exportContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)confirmDeleteContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)createFolderAndMoveContainer:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (void)removeContainerFromFolder:(id)container { Actions++;LastContainerObject=container;LastContainerID=[container containerID]; }
- (UILabel *)modelNameValue { return self.denyRequired ? nil : self.model; }
- (UILabel *)deviceNameValue { return self.device; }
- (UILabel *)iosVersionValue { return self.version; }
- (UILabel *)modelNumberValue { return self.source; }
- (UILabel *)serialValue { return self.source; }
- (UILabel *)wifiValue { return self.source; }
- (UILabel *)btValue { return self.source; }
- (UILabel *)ethernetValue { return self.source; }
- (UILabel *)imeiValue { return self.source; }
- (UILabel *)meidValue { return self.source; }
- (UILabel *)iccidValue { return self.source; }
- (UILabel *)carrierValue { return self.source; }
- (UILabel *)mccMncValue { return self.source; }
- (UILabel *)idfaValue { return self.source; }
- (UILabel *)idfvValue { return self.source; }
- (UILabel *)udidValue { return self.source; }
- (UIButton *)fingerprintButton { return self.sourceButton; }
- (UISwitch *)mainToggle { return self.sourceSwitch; }
- (UILabel *)connectionStatusLabel { return self.source; }
- (UILabel *)deviceIdLabel { return self.source; }
- (UILabel *)jailbreakTypeLabel { return self.source; }
- (UILabel *)licenseKeyLabel { return self.source; }
- (UILabel *)deviceCountLabel { return self.source; }
- (UILabel *)planTitleLabel { return self.source; }
- (UILabel *)planStatusLabel { return self.source; }
- (UILabel *)countryValueLabel { return self.source; }
- (UILabel *)coordsLabel { return self.source; }
- (UILabel *)addressLabel { return self.source; }
- (UILabel *)statusLabel { return self.source; }
- (UIButton *)validateButton { return self.sourceButton; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; (void)section; return 40; }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    (void)table; UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=[NSString stringWithFormat:@"Research %02ld",(long)path.row+1];
    cell.detailTextLabel.text=path.row==0 ? @"Selected · test data" : @"Saved · test data"; return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path { (void)table; self.selected=path.row; Actions++; }
@end
#define SCREEN(NAME) @interface NAME:Host @end @implementation NAME @end
SCREEN(HomeViewController)
@interface SettingsViewController:Host @end
@implementation SettingsViewController
- (void)confirmSbreload {
    Actions++;
    SettingsPresenterTop=self.navigationController.topViewController==self;
    SettingsConfirmation=[UIAlertController alertControllerWithTitle:@"Synthetic original confirmation" message:@"This fixture performs no device operation." preferredStyle:UIAlertControllerStyleAlert];
    [SettingsConfirmation addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SettingsConfirmation addAction:[UIAlertAction actionWithTitle:@"Confirm" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){SettingsConfirmationHandlers++;}]];
    [self presentViewController:SettingsConfirmation animated:NO completion:^{SettingsConfirmationCompletions++;}];
}
@end
SCREEN(ProxyViewController)
SCREEN(_Xc9m)
SCREEN(_Xm8u)
SCREEN(FakeInfoViewController)
SCREEN(LocSimViewController)
@interface SocialBoxOnboardingViewController:Host @end
@implementation SocialBoxOnboardingViewController
- (void)tapCreate { Actions+=10; }
- (void)tapSkip { Actions+=20; }
@end
@interface _Xd2z : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIImageView *logoImageView;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UILabel *oldBrand;
@property(nonatomic,strong) NSObject *delegate;
@end
@implementation _Xd2z
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=UIColor.blackColor;
    self.oldBrand=[UILabel new];self.oldBrand.text=@"SocialBox";[self.view addSubview:self.oldBrand];
    self.logoImageView=[UIImageView new];[self.view addSubview:self.logoImageView];
    self.statusLabel=[UILabel new];self.statusLabel.text=@"Checking license…";[self.view addSubview:self.statusLabel];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.view addSubview:self.spinner];[self.spinner startAnimating];
}
@end

@interface FixtureDelegate:UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UITabBarController *tabs;
@end
@implementation FixtureDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    SBTestSavedSetupReset();SBTestSavedSetupInitializeRoot(); // Explicit synthetic establishment, never a UI action.
    (void)application;(void)options;Failures=[NSMutableArray array];Directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    LBXPresentationFixtureMetadata(Metadata());
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.tabs=[UITabBarController new];NSMutableArray *navs=[NSMutableArray array];
    for(NSString *name in @[@"HomeViewController",@"_Xc9m",@"LocSimViewController",@"ProxyViewController",@"SettingsViewController"]) {
        Host *host=[NSClassFromString(name) new];[host loadViewIfNeeded];
        [navs addObject:[[UINavigationController alloc] initWithRootViewController:host]];
    }
    self.tabs.viewControllers=navs;self.window.rootViewController=self.tabs;[self.window makeKeyAndVisible];
    NSUInteger renderActions=Actions;
    for(UINavigationController *nav in navs) {
        Host *host=(id)nav.topViewController;id delegate=host.tableView.delegate,dataSource=host.tableView.dataSource,searchDelegate=host.searchBar.delegate;
        Check(LBXWorkspaceApply(host),[@"workspace installs: " stringByAppendingString:NSStringFromClass(host.class)]);
        UIView *workspace=Workspace(host);Check(workspace!=nil,@"source-owned workspace exists");
        Check(LBXWorkspaceApply(host)&&Workspace(host)==workspace,@"workspace rendering is idempotent");
        Check(host.tableView.delegate==delegate&&host.tableView.dataSource==dataSource&&host.searchBar.delegate==searchDelegate,@"original delegates remain owned by backend");
        Check([host.licenseKeyField.text isEqual:@"SYNTHETIC-KEY-NOT-A-LICENSE"]&&host.sourceSwitch.on,@"rendering keeps backend inputs unchanged");
        SBWorkspaceCoordinate(host);
    }
    Check(Actions==renderActions,@"rendering all primary screens and coordinator performs no operation");
    Check([self.tabs.viewControllers isEqual:navs]&&self.tabs.tabBar.hidden,@"five original admitted controllers retained behind owned navigation");
    UIView *dock=ViewID(self.tabs.view,@"socialbox.navigation");
    Check(dock!=nil&&Views(dock,UIButton.class).count==3,@"owned dock exposes exactly three sections");
    HomeViewController *home=(id)((UINavigationController *)navs[0]).viewControllers.firstObject;
    _Xc9m *containers=(id)((UINavigationController *)navs[1]).viewControllers.firstObject;
    LocSimViewController *location=(id)((UINavigationController *)navs[2]).viewControllers.firstObject;
    SettingsViewController *settings=(id)((UINavigationController *)navs[4]).viewControllers.firstObject;
    Host *proxy=(id)((UINavigationController *)navs[3]).viewControllers.firstObject;
    NSDictionary *beforeUpdateRender=SBUpdateService.sharedService.snapshot;
    Check([beforeUpdateRender[@"state"] isEqual:@"unchecked"],@"rendering admitted screens only registers update lifecycle without checking");
    Check(ButtonID(Workspace(settings),@"socialbox.settings.updates")!=nil,@"Settings exposes the source update page");
    SBAppUpdatesViewController *updates=[SBAppUpdatesViewController new];[updates loadViewIfNeeded];
    [updates.view setNeedsLayout];[updates.view layoutIfNeeded];
    Check([SBUpdateService.sharedService.snapshot isEqual:beforeUpdateRender],@"opening and laying out update page performs no check");
    Check(HasText(updates.view,@"Updates have not been checked yet."),@"update page reports unchecked without inferred success");
    Check(ButtonID(updates.view,@"socialbox.updates.check").enabled,@"explicit check control available");
    Check(ButtonID(updates.view,@"socialbox.updates.open").hidden,@"update instructions hidden until supported release observed");

    UIView *system=proxy.proxyFixtureViews[@"system"],*rotate=proxy.proxyFixtureViews[@"rotate"],*hero=proxy.proxyFixtureViews[@"empty"],*activeProxy=proxy.proxyFixtureViews[@"active"],*unsupported=proxy.proxyFixtureViews[@"unsupported"];
    UIView *systemRow=ViewID(system,@"socialbox.proxy.row.system");
    UISwitch *systemSwitch=(id)proxy.proxyFixtureViews[@"systemControl"],*rotateSwitch=(id)proxy.proxyFixtureViews[@"rotateControl"];
    Check(systemRow&&[systemSwitch isDescendantOfView:systemRow]&&systemSwitch.tag==41&&systemSwitch.on&&!systemSwitch.hidden,@"proxy system control moves into authored row with exact sender/tag/value and remains visible");
    Check(ViewID(rotate,@"socialbox.proxy.row.rotate")&&[rotateSwitch isDescendantOfView:ViewID(rotate,@"socialbox.proxy.row.rotate")]&&!rotateSwitch.on&&!rotateSwitch.hidden&&((UIVisualEffectView *)rotate).effect==nil,@"proxy rotation row replaces blur artwork and retains off state");
    Check(hero.hidden&&hero.accessibilityElementsHidden&&!ViewID(hero,@"socialbox.proxy.row.empty"),@"exact native empty proxy card is omitted from layout and accessibility without drawing a replacement");
    Check(!HasText(ViewID(system,@"socialbox.proxy.row.system"),@"All traffic routed through proxy")&&!HasText(Workspace(proxy),@"Add your first connection"),@"proxy presentation does not draw the removed connection guidance");
    UIButton *addProxy=ButtonID(Workspace(proxy),@"socialbox.action.proxies.add");
    Check(addProxy&&addProxy.enabled&&!addProxy.hidden&&[addProxy.accessibilityLabel isEqual:@"Add proxy"],@"existing Add proxy entry remains enabled above the saved rows");
    Check(ViewID(activeProxy,@"socialbox.proxy.row.active")&&HasText(ViewID(activeProxy,@"socialbox.proxy.row.active"),@"SocialBox user proxy"),@"active proxy row preserves user-provided names");
    UIView *savedProxy=proxy.proxyFixtureViews[@"saved"];
    Check(ViewID(savedProxy,@"socialbox.proxy.row.data")&&savedProxy.userInteractionEnabled&&
        [savedProxy.interactions containsObject:proxy.savedProxyContextMenu]&&proxy.savedProxyContextMenu.delegate==proxy,
        @"saved proxy retains the original public context-menu interaction and owner delegate in its selectable data carrier");
    Check(ProxyContextRequests==0,@"rendering saved proxy does not invoke its native context menu or connection test");
    UIContextMenuInteraction *retainedContext=proxy.savedProxyContextMenu;
    ObserveProxyStructure(savedProxy,@"initial");
    [savedProxy removeInteraction:retainedContext];LBXWorkspaceRefresh(proxy);
    ObserveProxyStructure(savedProxy,@"removed");
    Check(ViewID(savedProxy,@"socialbox.proxy.row.data")&&savedProxy.userInteractionEnabled&&retainedContext.view==nil,
        @"same saved carrier remains selectable when its native menu is temporarily removed");
    [savedProxy addInteraction:retainedContext];LBXWorkspaceRefresh(proxy);
    ObserveProxyStructure(savedProxy,@"reattached");
    Check(ViewID(savedProxy,@"socialbox.proxy.row.data")&&savedProxy.userInteractionEnabled&&retainedContext.view==savedProxy&&retainedContext.delegate==proxy,
        @"late native context-menu attachment preserves the same saved carrier and owner");
    UILongPressGestureRecognizer *extraLongPress=[[UILongPressGestureRecognizer alloc] initWithTarget:proxy action:@selector(proxyFixtureAction:)];
    [savedProxy addGestureRecognizer:extraLongPress];LBXWorkspaceRefresh(proxy);
    Check(!savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.unavailable"),
        @"cached saved row rejects a later unrelated long press despite identical labels and model carrier");
    [savedProxy removeGestureRecognizer:extraLongPress];LBXWorkspaceRefresh(proxy);
    ObserveProxyStructure(savedProxy,@"gestureRecovered");
    UIImageView *recoveredSelection=Views(ViewID(savedProxy,@"socialbox.proxy.row.data"),UIImageView.class).firstObject;
    Check(savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.data")&&
        recoveredSelection&&!recoveredSelection.hidden,
        @"saved row recovers its original selection visibility after the foreign gesture is removed");
    UIContextMenuInteraction *foreignContext=[[UIContextMenuInteraction alloc] initWithDelegate:proxy.foreignProxyContextOwner];
    [savedProxy removeInteraction:retainedContext];[savedProxy addInteraction:foreignContext];LBXWorkspaceRefresh(proxy);
    Check(!savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.unavailable")&&foreignContext.delegate==proxy.foreignProxyContextOwner,
        @"cached saved row rejects a retained foreign context delegate despite identical source values");
    [savedProxy removeInteraction:foreignContext];[savedProxy addInteraction:retainedContext];LBXWorkspaceRefresh(proxy);
    ObserveProxyStructure(savedProxy,@"delegateRecovered");
    UIImageView *restoredSelection=Views(ViewID(savedProxy,@"socialbox.proxy.row.data"),UIImageView.class).firstObject;
    Check(savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.data")&&retainedContext.view==savedProxy&&retainedContext.delegate==proxy&&
        restoredSelection&&!restoredSelection.hidden&&ProxyContextRequests==0,
        @"native menu restoration reuses the exact interaction and delegate without invoking its callback");
    UnexpectedProxyInteraction *unknownInteraction=[UnexpectedProxyInteraction new];
    [savedProxy addInteraction:unknownInteraction];LBXWorkspaceRefresh(proxy);
    Check(!savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.unavailable")&&unknownInteraction.view==savedProxy,
        @"an unknown interaction stays rejected alongside an otherwise valid native context menu");
    [savedProxy removeInteraction:unknownInteraction];LBXWorkspaceRefresh(proxy);
    Check(savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.data")&&retainedContext.view==savedProxy,
        @"removing the unknown interaction restores the same original native menu and selectable row");
    for(NSUInteger cycle=0;cycle<3;cycle++) {
        [savedProxy removeInteraction:retainedContext];LBXWorkspaceRefresh(proxy);
        [savedProxy addInteraction:retainedContext];LBXWorkspaceRefresh(proxy);
        UIImageView *selection=Views(ViewID(savedProxy,@"socialbox.proxy.row.data"),UIImageView.class).firstObject;
        Check(savedProxy.userInteractionEnabled&&ViewID(savedProxy,@"socialbox.proxy.row.data")&&retainedContext.view==savedProxy&&
            retainedContext.delegate==proxy&&selection&&!selection.hidden&&ProxyContextRequests==0,
            @"repeated UIKit context reattachment preserves its original delegate, selection visibility and callbacks");
    }
    for(NSString *role in @[@"extraContext",@"foreignContext"]) {
        UIView *card=proxy.proxyFixtureViews[role];
        Check(ViewID(card,@"socialbox.proxy.row.unavailable")&&!card.userInteractionEnabled,
            [role isEqual:@"extraContext"]?@"extra unrelated long press is rejected despite a native context menu":@"context interaction with a foreign delegate is rejected");
    }
    UIButton *checkIP=(id)proxy.proxyFixtureViews[@"checkIP"];
    Check(!checkIP.enabled&&!checkIP.hidden&&proxy.proxyFixtureViews[@"Scan QR code"].hidden&&!proxy.proxyFixtureViews[@"Paste a list"].hidden,@"proxy layout preserves independent native enabled and hidden state");
    BOOL oldButtonDimensions=NO;for(NSLayoutConstraint *constraint in checkIP.constraints)if(constraint.active&&constraint.constant==32)oldButtonDimensions=YES;
    Check(!oldButtonDimensions,@"proxy active button releases its old icon-only size for the authored caption");
    Check(ViewID(unsupported,@"socialbox.proxy.row.unavailable")&&!unsupported.userInteractionEnabled&&proxy.proxyFixtureViews[@"unexpectedControl"].hidden,@"unknown proxy controls are concealed and their carrier cannot receive touches");
    NSUInteger proxyActions=Actions;
    UIContextMenuConfiguration *nativeMenu=[proxy.savedProxyContextMenu.delegate contextMenuInteraction:proxy.savedProxyContextMenu configurationForMenuAtLocation:CGPointZero];
    UIMenu *providedMenu=proxy.proxyFixtureMenuProvider(@[]);
    UIAction *nativeMenuAction=(id)providedMenu.children.firstObject;
    UIButton *menuSender=[UIButton buttonWithConfiguration:UIButtonConfiguration.plainButtonConfiguration primaryAction:nativeMenuAction];
    Check(nativeMenu&&ProxyContextRequests==1&&[nativeMenuAction.title isEqual:@"Test Connection"]&&Actions==proxyActions,
        @"original saved-proxy delegate still supplies its exact menu without invoking the action");
    [menuSender sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(Actions==proxyActions+1&&LastProxySender==savedProxy,@"original context-menu action retains its model carrier and callback exactly once");
    proxyActions=Actions;[addProxy sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(Actions==proxyActions+1,@"Add proxy forwards exactly once to the existing native menu");
    proxyActions=Actions;[systemSwitch setOn:NO animated:NO];[systemSwitch sendActionsForControlEvents:UIControlEventValueChanged];
    Check(Actions==proxyActions+1&&LastProxySender==systemSwitch&&!systemSwitch.on,@"proxy authored switch sends exactly one native value change");
    UIButton *paste=(id)proxy.proxyFixtureViews[@"Paste a list"];proxyActions=Actions;[paste sendActionsForControlEvents:UIControlEventTouchUpInside];
    Check(Actions==proxyActions+1&&LastProxySender==paste&&paste.tag==44&&[paste isDescendantOfView:hero]&&hero.hidden,@"omitted proxy card retains its exact original import callback and sender");
    proxyActions=Actions;UIButton *disconnect=(id)proxy.proxyFixtureViews[@"disconnect"];[disconnect sendActionsForControlEvents:UIControlEventTouchUpInside];
    Check(Actions==proxyActions+1&&LastProxySender==disconnect&&[disconnect isDescendantOfView:ViewID(activeProxy,@"socialbox.proxy.row.active")],@"proxy disconnect keeps native sender and action");
    UILabel *proxyName=(id)proxy.proxyFixtureViews[@"SocialBox user proxy"];proxyName.text=@"Updated proxy name";
    Check(HasText(ViewID(activeProxy,@"socialbox.proxy.row.active"),@"Updated proxy name"),@"proxy user values remain live after re-layout");
    proxyActions=Actions;LBXWorkspaceApply(proxy);LBXWorkspaceRefresh(proxy);
    Check(Actions==proxyActions&&ViewID(system,@"socialbox.proxy.row.system")==systemRow&&[systemSwitch isDescendantOfView:systemRow],@"proxy repeated rendering is idempotent and invokes no operation");
    hero.hidden=NO;hero.accessibilityElementsHidden=NO;LBXWorkspaceRefresh(proxy);
    Check(hero.hidden&&hero.accessibilityElementsHidden&&Actions==proxyActions,@"native empty-card visibility refresh stays omitted without an operation");
    UIView *unavailableRow=ViewID(unsupported,@"socialbox.proxy.row.unavailable");LBXWorkspaceRefresh(proxy);
    Check(ViewID(unsupported,@"socialbox.proxy.row.unavailable")==unavailableRow&&!unsupported.userInteractionEnabled,@"unsupported proxy rows remain closed and stable across layout refreshes");
    for(UIView *view in proxy.contentStack.arrangedSubviews.copy) { [proxy.contentStack removeArrangedSubview:view];[view removeFromSuperview]; }
    [proxy buildProxyFixtureRows];LBXWorkspaceRefresh(proxy);
    Check(proxy.proxyFixtureViews[@"systemControl"]!=systemSwitch&&[proxy.proxyFixtureViews[@"systemControl"] isDescendantOfView:ViewID(proxy.view,@"socialbox.proxy.row.system")]&&! [systemSwitch isDescendantOfView:Workspace(proxy)],@"native proxy rebuild adopts current controls without resurrecting stale senders");
    Check(proxy.proxyFixtureViews[@"empty"].hidden&&proxy.proxyFixtureViews[@"empty"].accessibilityElementsHidden&&
        [proxy.proxyFixtureViews[@"Paste a list"] isDescendantOfView:proxy.proxyFixtureViews[@"empty"]],@"fresh native rebuild omits only the new empty card and retains its original controls");
    renderActions=Actions; // Subsequent dock checks follow the explicit proxy events above.
    NSArray *sectionIDs=@[@"socialbox.nav.containers",@"socialbox.nav.connection",@"socialbox.nav.settings"];
    for(NSString *identifier in sectionIDs) Check(ButtonID(dock,identifier)!=nil,@"dock section has semantic identifier");
    [ButtonID(dock,sectionIDs[1]) sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(self.tabs.selectedViewController==navs[3]&&Actions==renderActions,@"connection dock selection is navigation only");
    [ButtonID(dock,sectionIDs[2]) sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(self.tabs.selectedViewController==navs[4]&&Actions==renderActions,@"settings dock selection is navigation only");
    [ButtonID(dock,sectionIDs[0]) sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(self.tabs.selectedViewController==navs[1]&&Actions==renderActions,@"container dock selection is navigation only");
    Check([SBWorkspaceNavigationStatus(containers)[@"sections"] isEqual:@[@"containers",@"connection",@"settings"]],@"navigation reports three presentation sections");
    UIView *containerView=ViewID(Workspace(containers),@"socialbox.containers");
    UITableView *ownTable=Views(containerView,UITableView.class).firstObject;
    Check(ownTable&&ownTable!=containers.tableView&&ownTable.delegate!=(id)containers,@"owned table keeps guarded stable-ID routing");
    Check([ownTable.dataSource tableView:ownTable numberOfRowsInSection:0]==40,@"all forty containers remain visible");
    Check(!ViewID(containerView,@"socialbox.containers.search")&&!ViewID(containerView,@"socialbox.containers.tools")&&Views(containerView,UISegmentedControl.class).count==0,@"minimal Containers has no search, Tools or app filters");
    UISwipeActionsConfiguration *deleteSwipe=[ownTable.delegate tableView:ownTable trailingSwipeActionsConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
    UISwipeActionsConfiguration *renameSwipe=[ownTable.delegate tableView:ownTable leadingSwipeActionsConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    Check(deleteSwipe.actions.count==1&&[deleteSwipe.actions.firstObject.title isEqual:@"Delete"]&&!deleteSwipe.performsFirstActionWithFullSwipe,@"inactive row offers explicit Delete without full swipe");
    Check(renameSwipe.actions.count==1&&[renameSwipe.actions.firstObject.title isEqual:@"Rename"]&&!renameSwipe.performsFirstActionWithFullSwipe,@"saved names have an explicit Rename gesture");
    Check([ownTable.delegate tableView:ownTable trailingSwipeActionsConfigurationForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]]==nil,@"selected row has no Delete gesture");
    Check(![ownTable.delegate respondsToSelector:@selector(tableView:contextMenuConfigurationForRowAtIndexPath:point:)],@"no extra container context menu is added");
    NSMutableSet *ids=[NSMutableSet set];UIButton *switchButton=nil;
    for(NSUInteger index=0;index<40;index++) {
        UITableViewCell *cell=[ownTable.dataSource tableView:ownTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
        NSString *expected=[NSString stringWithFormat:@"socialbox.container.%lld",500+(long long)index*17];
        Check([cell.accessibilityIdentifier isEqual:expected],@"rows retain exact stable identities");[ids addObject:cell.accessibilityIdentifier?:@""];
        UIListContentConfiguration *content=(id)cell.contentConfiguration;
        Check(content.secondaryText==nil&&[cell.accessoryView isKindOfClass:UIButton.class],@"row shows name and one switch control, without app counts");
        UIButton *button=(id)cell.accessoryView;
        Check([button.configuration.title isEqual:index==0?@"Selected":@"Switch"]&&button.enabled==(index!=0),@"selected state comes only from original active ID");
        if(index==17){switchButton=button;Check([content.text isEqual:@"SocialBox"],@"user name remains byte-for-byte");}
    }
    Check(ids.count==40,@"forty list identities are unique");
    NSUInteger before=Actions;
    [ownTable.delegate tableView:ownTable didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    Check(Actions==before&&containers.navigationController.topViewController==containers,@"selected row does nothing and opens no detail");
    _Xv8i *replacement=[_Xv8i new];replacement.containerID=789;replacement.name=@"SocialBox";replacement.apps=@[@"com.fixture.second"];
    NSMutableArray *latest=[containers.containers mutableCopy];for(NSUInteger i=0;i<latest.count;i++)if([latest[i] containerID]==789)latest[i]=replacement;
    containers.containers=[[latest reverseObjectEnumerator] allObjects];
    [switchButton sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(Actions==before+1&&LastContainerID==789&&LastContainerObject==replacement,@"Switch resolves latest exact model after replacement/reorder");
    Check(containers.activeContainerID==500&&containers.navigationController.topViewController==containers,@"dispatch fabricates neither completed selection nor detail navigation");
    containers.containers=[[latest reverseObjectEnumerator] allObjects];
    [((SBContainersView *)containerView) refresh];
    before=Actions;containers.activeContainerID=789;[((SBContainersView *)containerView) refresh];
    UITableViewCell *selected=[ownTable.dataSource tableView:ownTable cellForRowAtIndexPath:[NSIndexPath indexPathForRow:17 inSection:0]];
    Check(!((UIButton *)selected.accessoryView).enabled&&[((UIButton *)selected.accessoryView).configuration.title isEqual:@"Selected"]&&Actions==before,@"fresh original state updates Selected without invoking a switch");
    Check([((UILabel *)ViewID(containerView,@"socialbox.containers.selectedName")).text isEqual:@"Selected: SocialBox"],@"selected header preserves the actual saved name without brand replacement");
    NSArray *valid=containers.containers;containers.containers=[valid arrayByAddingObject:replacement];[((SBContainersView *)containerView) refresh];
    Check([ownTable.dataSource tableView:ownTable numberOfRowsInSection:0]==0&&Actions==before,@"ambiguous original records close list without side effects");
    containers.containers=valid;containers.activeContainerID=500;[((SBContainersView *)containerView) refresh];
    Check([ownTable.dataSource tableView:ownTable numberOfRowsInSection:0]==40,@"restored valid observation renders all records");
    // Successful creation review is exercised after selected content actually
    // attaches below. didFinishLaunching and synchronous tab changes do not
    // establish the production source's current-window presentation contract.
    UIButton *create=ButtonID(containerView,@"socialbox.containers.create");
    home.sourceButton.enabled=NO;before=Actions;[create sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];Check(Actions==before,@"disabled backend creation cannot be triggered");
    before=Actions;NSMutableArray *without=[containers.containers mutableCopy];[without removeObject:replacement];containers.containers=without;
    [switchButton sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(Actions==before,@"captured button cannot act on removed record");
    UIViewController *notice=containers.presentedViewController;
    Check([notice isKindOfClass:UIAlertController.class]&&[((UIAlertController *)notice).message isEqual:@"Please try again."],@"failed action exposes simple retry copy without diagnostic codes");
    [containers dismissViewControllerAnimated:NO completion:nil];containers.containers=[[latest reverseObjectEnumerator] allObjects];
    [self.tabs dismissViewControllerAnimated:NO completion:nil];[containers dismissViewControllerAnimated:NO completion:nil];[home dismissViewControllerAnimated:NO completion:nil];home.sourceButton.enabled=YES;
    UIButton *configure=ButtonID(Workspace(home),@"socialbox.action.home.configureIdentity");before=Actions;[configure sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(configure!=nil&&Actions==before+1,@"verified configuration navigation invokes original method once");
    Check(!ButtonID(Workspace(home),@"socialbox.action.home.cloud").enabled,@"missing action ABI remains disabled");
    home.model.text=@"Updated identity";Check(HasText(Workspace(home),@"Updated identity"),@"async identity value remains live");home.model.text=@"iPhone 15 Pro";
    Check([location.mapView isDescendantOfView:Workspace(location)]&&!location.mapView.hidden&&location.mapView.delegate==location,@"same map and delegate move into owned panel");
    Check([location.searchBar isDescendantOfView:Workspace(location)]&&!location.searchBar.hidden,@"location search remains visible");
    [location.actionButton setTitle:@"Stop simulation" forState:0];LBXWorkspaceRefresh(location);
    Check(FindButton(Workspace(location),@"Stop simulation")!=nil,@"simulation state updates source control presentation");
    _Xm8u *license=[_Xm8u new];[license loadViewIfNeeded];id inputDelegate=license.licenseKeyField.delegate;before=Actions;
    Check(LBXWorkspaceApply(license),@"owned license screen installs without admission");SBWorkspaceCoordinate(license);
    Check(!license.tabBarController&&!ViewID(license.view,@"socialbox.navigation")&&Actions==before,@"locked license never creates dock or admitted navigation");
    Check(license.licenseKeyField.delegate==inputDelegate&&license.licenseKeyField.secureTextEntry,@"license input privacy and original editing delegate preserved");
    UIButton *activate=ButtonID(Workspace(license),@"socialbox.control.license.button");
    UITextField *ownedKey=(UITextField *)ViewID(Workspace(license),@"socialbox.activation.key");
    Check(activate!=nil&&activate.enabled&&ownedKey!=license.licenseKeyField,@"SocialBox input is independent of original key field and validation gate");
    before=Actions;NSUInteger licenseCalls=SBTestLicenseRequestCount();
    ownedKey.text=@"wrong";[activate sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check(SBTestLicenseRequestCount()==licenseCalls&&Actions==before,@"invalid key causes neither own IPC nor original event");
    ownedKey.text=@"AAAA-BBBB-CCCC-DDDD";[activate sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    [ownedKey.delegate textFieldShouldReturn:ownedKey];
    Check(SBTestLicenseRequestCount()==licenseCalls+1&&!activate.enabled&&!ownedKey.enabled&&Actions==before,@"one explicit own request; duplicate return/submit blocked");
    Check([SBTestLicenseRequestedKey() isEqual:@"AAAA-BBBB-CCCC-DDDD"]&&[license.licenseKeyField.text isEqual:@"SYNTHETIC-KEY-NOT-A-LICENSE"],@"new key reaches only our client, never original form or server");
    SBTestLicenseComplete(@"active");
    FakeInfoViewController *config=[FakeInfoViewController new];[config loadViewIfNeeded];NSArray *controls=[config.contentStack.arrangedSubviews copy];
    Check(LBXWorkspaceApply(config)&&ViewID(config.view,@"socialbox.identity.form")&&![SBIdentityStatus(config)[@"available"] boolValue]&&[controls isEqual:config.contentStack.arrangedSubviews]&&config.mode.selectedSegmentIndex==1,@"unsupported synthetic identity shape fails into owned form without changing original controls");
    before=Actions;[config.mode sendActionsForControlEvents:UIControlEventValueChanged];Check(Actions==before+1,@"identity mode event retained");
    HomeViewController *bad=[HomeViewController new];[bad loadViewIfNeeded];bad.denyRequired=YES;before=Actions;
    Check(LBXWorkspaceApply(bad)&&ViewID(bad.view,@"socialbox.unavailable")&&bad.contentStack.hidden&&Actions==before,@"unsupported contract shows own unavailable state without invoking backend");
    UIViewController *foreign=[UIViewController new];[foreign loadViewIfNeeded];Check(!LBXWorkspaceApply(foreign),@"unknown controller not adopted");
    Check(![LBXWorkspaceStatus()[@"isolationVerified"] boolValue],@"presentation never claims physical isolation evidence");
    NSString *privateText=@"key-SocialBox-123 https://socialbox.example/proxy";
    NSString *empty=@"No .socialbox or .socialboxpack files found. Drop yours into 'On My iPhone → Downloads', 'On My iPhone → SocialBox' (any folder), or the SocialBoxInbox — the picker scans all of those.";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"No Files Found" message:empty preferredStyle:UIAlertControllerStyleAlert];
    __block NSUInteger alertCallbacks=0;void(^originalHandler)(UIAlertAction *)=^(__unused UIAlertAction *action){alertCallbacks++;};
    UIAlertAction *ok=[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:originalHandler];
    UIAlertAction *cancel=[UIAlertAction actionWithTitle:@"my SocialBox.socialbox" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:ok];[alert addAction:cancel];alert.preferredAction=ok;cancel.enabled=NO;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=privateText;field.secureTextEntry=YES;field.delegate=license;}];
    UITextField *field=alert.textFields.firstObject;LBXDisplayCopyAlert(alert);
    Check([alert.message isEqual:@"No importable container archives found. Save an archive to Downloads in Files, then try again."],@"exact reported empty import alert has owned copy");
    Check(alert.actions.count==2&&alert.actions[0]==ok&&alert.actions[1]==cancel&&alert.preferredAction==ok,@"original alert action objects and preferred action remain identical");
    Check(ok.style==UIAlertActionStyleDefault&&cancel.style==UIAlertActionStyleCancel&&!cancel.enabled&&alert.preferredStyle==UIAlertControllerStyleAlert,@"alert style and action styles/enabled state preserved");
    Check(alert.textFields.firstObject==field&&field.delegate==license&&field.secureTextEntry&&[field.text isEqual:privateText],@"alert field identity delegate privacy and contents unchanged");
    Check(alertCallbacks==0&&[cancel.title isEqual:@"my SocialBox.socialbox"],@"copy rendering invokes no action handler and preserves user filename action");
    UILabel *userLabel=[UILabel new];userLabel.text=@"SocialBox";[foreign.view addSubview:userLabel];LBXDisplayCopyApply(foreign);
    Check([userLabel.text isEqual:@"SocialBox"],@"unmarked user label identical to brand stays unchanged");LBXDisplayCopySetRole(userLabel,LBXDisplayTextRoleUserData);LBXDisplayCopyApply(foreign);
    Check([userLabel.text isEqual:@"SocialBox"],@"explicit user-data role never rewrites exact match");
    UILabel *systemLabel=[UILabel new];systemLabel.text=empty;[foreign.view addSubview:systemLabel];LBXDisplayCopySetRole(systemLabel,LBXDisplayTextRoleFixed);
    Check([systemLabel.text isEqual:alert.message],@"explicit fixed role maps system copy");
    NSMutableArray *opened=[NSMutableArray array];__block BOOL telegramInstalled=YES;
    Method openMethod=class_getInstanceMethod(UIApplication.class,@selector(openURL:options:completionHandler:));
    IMP fake=imp_implementationWithBlock(^(__unused UIApplication *app,NSURL *url,__unused NSDictionary *options,void(^completion)(BOOL)){[opened addObject:url.absoluteString];if(completion)completion(telegramInstalled);});IMP originalOpen=method_setImplementation(openMethod,fake);
    UIButton *contact=ButtonID(Workspace(settings),@"socialbox.contact");Check(contact!=nil&&opened.count==0,@"contact exists without opening externally during render");
    [contact sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];Check([opened isEqual:@[@"tg://resolve?domain=sctweaks"]],@"explicit contact opens owner profile without message");
    [opened removeAllObjects];telegramInstalled=NO;[contact sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
    Check([opened isEqual:@[@"tg://resolve?domain=sctweaks",@"https://t.me/sctweaks"]],@"missing Telegram falls back to same owner profile");method_setImplementation(openMethod,originalOpen);imp_removeBlock(fake);
    _Xd2z *splash=[_Xd2z new];[splash loadViewIfNeeded];NSObject *delegate=[NSObject new];splash.delegate=delegate;UILabel *status=splash.statusLabel;UIActivityIndicatorView *spinner=splash.spinner;before=Actions;
    Check(LBXWorkspaceApply(splash)&&splash.oldBrand.hidden&&splash.logoImageView.hidden&&HasText(Workspace(splash),@"SocialBox"),@"startup shows owned brand before admission");
    Check([spinner isDescendantOfView:Workspace(splash)]&&spinner.isAnimating&&splash.delegate==delegate&&Actions==before,@"startup keeps original spinner and admission delegate with no operation");
    Check(LBXWorkspaceApply(splash)&&splash.statusLabel==status,@"startup repeated rendering keeps backend label identity");
    _Xd2z *badSplash=[_Xd2z new];[badSplash loadViewIfNeeded];[badSplash.statusLabel removeFromSuperview];Check(LBXWorkspaceApply(badSplash)&&ViewID(badSplash.view,@"socialbox.unavailable")&&badSplash.oldBrand.hidden,@"detached startup status shows owned unavailable surface");
    SocialBoxOnboardingViewController *welcome=[SocialBoxOnboardingViewController new];[welcome loadViewIfNeeded];before=Actions;Check(LBXWorkspaceApply(welcome)&&Actions==before,@"welcome has no completion side effect");
    [ButtonID(Workspace(welcome),@"socialbox.action.welcome.create") sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];Check(Actions==before+10,@"welcome creation forwards once");
    [ButtonID(Workspace(welcome),@"socialbox.action.welcome.skip") sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];Check(Actions==before+30,@"welcome skip forwards once");
    self.tabs.selectedViewController=navs[1];SBWorkspaceCoordinate(containers);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        NSUInteger delayedActions=Actions;license.errorLabel.text=@"Unreviewed SocialBox server password=private-error";license.errorLabel.hidden=NO;
        Check(!HasText(Workspace(license),license.errorLabel.text)&&HasPrefix(Workspace(license),@"Your SocialBox license was verified."),@"original delayed errors cannot overwrite our signed license result");
        Check(activate.enabled&&ownedKey.enabled&&ownedKey.text.length==0&&!license.tabBarController&&Actions==delayedActions,@"own verification clears input and leaves unavailable engine locked");
        status.text=@"Start Simulation";[spinner stopAnimating];LBXWorkspaceRefresh(splash);
        Check(HasText(Workspace(splash),@"Start simulation")&&!HasText(Workspace(splash),@"Start Simulation"),@"delayed startup status uses owned English copy");
        Check(!spinner.isAnimating&&Actions==delayedActions&&splash.delegate==delegate,@"delayed error rendering does not admit or invoke operations");
        void(^captureSplash)(void)=^{
        self.window.rootViewController=splash;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            Save(self.window,@"workspace-startup-preview.png");self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:license];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.3*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                Save(self.window,@"workspace-license-preview.png");
                [[NSJSONSerialization dataWithJSONObject:ProxyInteractionObservations ?: @[] options:NSJSONWritingPrettyPrinted error:nil]
                    writeToFile:[Directory stringByAppendingPathComponent:@"proxy-interaction-observations.json"] atomically:YES];
                NSMutableArray *savedGestures=[NSMutableArray array];
                for(UIGestureRecognizer *gesture in proxy.proxyFixtureViews[@"saved"].gestureRecognizers)
                    [savedGestures addObject:@{@"class":NSStringFromClass(gesture.class),@"delegate":gesture.delegate?NSStringFromClass([(id)gesture.delegate class]):@"nil",@"contextIsDelegate":@(gesture.delegate==(id)proxy.savedProxyContextMenu)}];
                [[NSJSONSerialization dataWithJSONObject:savedGestures options:NSJSONWritingPrettyPrinted error:nil]
                    writeToFile:[Directory stringByAppendingPathComponent:@"proxy-gesture-observation.json"] atomically:YES];
                NSDictionary *report=@{@"ok":@(Failures.count==0),@"assertions":@(Checks),@"failures":Failures,@"scope":@"Actual source-owned UI with synthetic backend; no device/backend/isolation acceptance",@"status":LBXWorkspaceStatus(),@"captureReadiness":CaptureReadiness ?: @[]};
                [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[Directory stringByAppendingPathComponent:@"presentation-result.json"] atomically:YES];
            });
        });
        };
        void(^finishCaptures)(void)=^{
            SBAppUpdatesViewController *updatePage=[SBAppUpdatesViewController new];
            NSDictionary *before=SBUpdateService.sharedService.snapshot;
            self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:updatePage];
            AwaitUI(^BOOL{[self.window layoutIfNeeded];return FullyVisibleInWindow(ButtonID(updatePage.view,@"socialbox.updates.check"),self.window);},60,0,^(BOOL ready){
                Check(ready&&[SBUpdateService.sharedService.snapshot isEqual:before],@"visible update page remains read-only until explicit check");
                Save(self.window,@"workspace-updates-preview.png");CheckActivationDenials(0,captureSplash);
            });
        };
        void(^capture)(void)=^{
            Save(self.window,@"workspace-containers-preview.png");
            NSUInteger captureActions=Actions;
            // Select representative native carrier states without invoking any
            // core action. The production workspace still creates every pixel.
            UIView *systemCard=proxy.proxyFixtureViews[@"system"],*rotateCard=proxy.proxyFixtureViews[@"rotate"],
                   *activeCard=proxy.proxyFixtureViews[@"active"],*savedCard=proxy.proxyFixtureViews[@"saved"],*emptyCard=proxy.proxyFixtureViews[@"empty"];
            for(UIView *view in proxy.contentStack.arrangedSubviews.copy){[proxy.contentStack removeArrangedSubview:view];[view removeFromSuperview];}
            for(UIView *view in @[systemCard,rotateCard,activeCard,savedCard])[proxy.contentStack addArrangedSubview:view];
            ((UILabel *)proxy.proxyFixtureViews[@"SocialBox user proxy"]).text=@"Amsterdam · primary";
            ((UILabel *)proxy.proxyFixtureViews[@"proxy.fixture:8080"]).text=@"nl-edge.example.invalid:1080";
            ((UIButton *)proxy.proxyFixtureViews[@"checkIP"]).enabled=YES;
            LBXWorkspaceRefresh(proxy);SBWorkspaceNavigate(containers,SBScreenProxies);
            UIScrollView *proxyScroll=Views(Workspace(proxy),UIScrollView.class).firstObject;
            [proxyScroll setContentOffset:CGPointZero animated:NO];
            AwaitSelectedContent(self.window,self.tabs,proxy,Workspace(proxy),containers,60,0,^(BOOL proxyReady){
                UIView *systemOwned=ViewID(systemCard,@"socialbox.proxy.row.system"),*rotateOwned=ViewID(rotateCard,@"socialbox.proxy.row.rotate");
                Check(proxyReady&&FullyVisibleInWindow(systemOwned,self.window)&&FullyVisibleInWindow(rotateOwned,self.window),@"proxy controls capture waits for visible complete authored switch rows");
                Check(Actions==captureActions,@"preparing populated proxy capture invokes no native operation");
                Save(self.window,@"workspace-proxy-controls-preview.png");
                [self.window layoutIfNeeded];
                CGFloat y=CGRectGetMinY([activeCard convertRect:activeCard.bounds toView:proxyScroll])-16;
                CGFloat maximum=MAX(0,proxyScroll.contentSize.height-proxyScroll.bounds.size.height);
                [proxyScroll setContentOffset:CGPointMake(0,MIN(MAX(0,y),maximum)) animated:NO];
                AwaitUI(^BOOL{
                    [self.window layoutIfNeeded];
                    return FullyVisibleInWindow(ViewID(activeCard,@"socialbox.proxy.row.active"),self.window)&&FullyVisibleInWindow(ViewID(savedCard,@"socialbox.proxy.row.data"),self.window);
                },60,0,^(BOOL connectionsReady){
                    Check(connectionsReady&&savedCard.tag==73&&[savedCard.interactions containsObject:proxy.savedProxyContextMenu]&&
                        proxy.savedProxyContextMenu.delegate==proxy&&savedCard.userInteractionEnabled,@"active and saved proxy capture includes complete authored rows and retains its native context-menu carrier and delegate");
                    UIImageView *indicator=Views(ViewID(savedCard,@"socialbox.proxy.row.data"),UIImageView.class).firstObject;
                    // UIKit applies SF Symbol alignment insets (this circle's
                    // bounds are22x21); Auto Layout sizes its alignment rect.
                    CGRect indicatorAlignment=[indicator alignmentRectForFrame:indicator.frame];
                    Check(indicator&&fabs(indicatorAlignment.size.width-22)<.5&&fabs(indicatorAlignment.size.height-22)<.5,@"rendered saved-proxy selection indicator has its required 22 by 22 alignment geometry without stretching");
                    Check(Actions==captureActions,@"scrolling proxy fixture performs no connection test or selection");
                    Save(self.window,@"workspace-proxy-connections-preview.png");
                    for(UIView *view in proxy.contentStack.arrangedSubviews.copy){[proxy.contentStack removeArrangedSubview:view];[view removeFromSuperview];}
                    [proxy.contentStack addArrangedSubview:emptyCard];proxy.proxyFixtureViews[@"Scan QR code"].hidden=NO;
                    LBXWorkspaceRefresh(proxy);[self.window layoutIfNeeded];
                    [proxyScroll setContentOffset:CGPointZero animated:NO];
                    AwaitUI(^BOOL{
                        [self.window layoutIfNeeded];return emptyCard.hidden&&FullyVisibleInWindow(ButtonID(Workspace(proxy),@"socialbox.action.proxies.add"),self.window)&&DockContentVisible(self.tabs,self.window);
                    },60,0,^(BOOL emptyReady){
                        Check(emptyReady&&emptyCard.accessibilityElementsHidden&&!FullyVisibleInWindow(proxy.proxyFixtureViews[@"Scan QR code"],self.window)&&!FullyVisibleInWindow(proxy.proxyFixtureViews[@"Import from Shadowrocket"],self.window),@"empty proxy capture shows Add proxy while the old card and its import controls remain omitted");
                        Check(Actions==captureActions,@"empty proxy fixture capture invokes no import or state mutation");
                        Save(self.window,@"workspace-proxy-empty-preview.png");finishCaptures();
                    });
                });
            });
        };
        void(^settingsRegression)(void)=^{
            // UIKit may invoke dismissal completion before detaching its modal.
            // The production coordinator intentionally rejects navigation then.
            AwaitUI(^BOOL{return !self.tabs.presentedViewController;},60,0,^(BOOL dismissed){
            Check(dismissed,@"fixture waits for modal detachment before selecting Settings");
            SBWorkspaceNavigate(containers,SBScreenSettings);
            AwaitSelectedContent(self.window,self.tabs,settings,Workspace(settings),containers,60,0,^(BOOL settingsReady){
            Check(settingsReady,@"simplified Settings becomes visibly selected after container flow");
            NSUInteger beforePage=Actions;
            Check(!ButtonID(Workspace(settings),@"socialbox.settings.Maintenance") &&
                !ButtonID(Workspace(settings),@"socialbox.settings.cloud") &&
                !ButtonID(Workspace(settings),@"socialbox.settings.identity") &&
                !ButtonID(Workspace(settings),@"socialbox.settings.Seed backup"),@"unverified maintenance cloud identity and seed shortcuts are absent from Settings");
            Check(HasText(Workspace(settings),@"Device, license status, and support.") &&
                !HasText(Workspace(settings),@"Key") && !HasText(Workspace(settings),@"Sign out"),@"Settings keeps informational status and omits license material and untested sign-out");
            Check(Actions==beforePage && SettingsConfirmationHandlers==0 && SettingsConfirmationCompletions==0,@"simplified Settings rendering invokes no hidden backend action or confirmation");
            SBWorkspaceNavigate(settings,SBScreenContainers);
            AwaitSelectedContent(self.window,self.tabs,containers,containerView,settings,40,0,^(BOOL settled){
                Check(settled,@"container capture waits for selected content to replace Settings and finish transitions");
                Check(self.tabs.selectedViewController==containers.navigationController && containers.navigationController.topViewController==containers &&
                    containers.navigationController.navigationBar.topItem==containers.navigationItem &&
                    ButtonID(dock,@"socialbox.nav.containers").selected,@"captured container content navigation title and dock agree on selected screen");
                Check(VisibleInWindow(containerView,self.window) && VisibleInWindow(ownTable,self.window) && ownTable.visibleCells.count>0 &&
                    !VisibleInWindow(Workspace(settings),self.window),@"container preview contains visible table rows and no visible Settings workspace");
                Check(DockContentVisible(self.tabs,self.window),@"all three dock titles and icons are visible before container preview capture");
                Check(Actions==beforePage && SettingsConfirmationHandlers==0,@"settling navigation and capture invokes no backend or confirmation handler");
                capture();
            });
            });
            });
        };
        void(^creationRegression)(void)=^{
            AwaitSelectedContent(self.window,self.tabs,containers,containerView,nil,60,0,^(BOOL ready){
                Check(ready,@"creation review waits for attached selected Containers");
                NSUInteger beforeReview=Actions;
                [create sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
                AwaitUI(^BOOL{return containers.presentedViewController.view.window!=nil &&
                    !containers.presentedViewController.isBeingPresented;},60,0,^(BOOL presented){
                    Check(presented&&create!=nil&&Actions==beforeReview&&
                        [containers.presentedViewController.view.accessibilityIdentifier isEqual:@"socialbox.creation.review"],
                        @"container creation opens current-value review before any original control event");
                    UIButton *cancel=ButtonID(containers.presentedViewController.view,@"socialbox.creation.cancel");
                    Check(cancel!=nil,@"creation review exposes explicit Cancel");
                    [cancel sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
                    AwaitUI(^BOOL{return !containers.presentedViewController;},60,0,^(BOOL dismissed){
                        Check(dismissed&&Actions==beforeReview,@"creation review Cancel completes without original control event");
                        settingsRegression();
                    });
                });
            });
        };
        UIViewController *modal=self.tabs.presentedViewController;
        if(!modal)for(UINavigationController *navigation in navs)if(navigation.presentedViewController){modal=navigation.presentedViewController;break;}
        if(modal)[modal dismissViewControllerAnimated:NO completion:^{
            AwaitUI(^BOOL{return !self.tabs.presentedViewController;},60,0,^(__unused BOOL dismissed){creationRegression();});
        }];else creationRegression();
    });return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(FixtureDelegate.class)); } }
