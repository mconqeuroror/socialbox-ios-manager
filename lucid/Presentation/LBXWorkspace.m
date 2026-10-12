#import "SBInterfaceCopy.h"
#import "LBXWorkspace.h"
#import "LBXPresentation.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <MapKit/MapKit.h>
#import <os/log.h>
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import "SBWorkspaceCoordinator.h"
#import "SBSecondaryScreens.h"
#import "SBContainersView.h"
#import "LBXDisplayCopy.h"
#import "SBIdentityForm.h"
#import "SBUpdateService.h"
#import "SBActivationView.h"

// Only this source file constructs the new workspace. No recovered view builder,
// layout, drawing method, or navigation root is copied or replaced.
static char WorkspaceKey, BindingContext;
static NSMutableSet *InstalledScreens;
static UIColor *Canvas(void) { return SBInk(); }
static UIColor *Panel(void) { return SBPanel(); }
static UIColor *Accent(void) { return SBAccent(); }
static UIColor *Muted(void) { return [UIColor colorWithRed:.61 green:.67 blue:.75 alpha:1]; }

NSString *LBXWorkspaceHeading(NSString *heading) { return LBXDisplayCopy(heading); }
static id Read(id owner, NSString *key, Class type) {
    id value=SBBackendReadObject(owner,key,NULL);return [value isKindOfClass:type]?value:nil;
}
static void Invoke(id owner, NSString *action, id value) {
    // Detail-page controls target the original object. Restore its visible
    // navigation position before its own method presents a confirmation/form.
    if([owner isKindOfClass:UIViewController.class]) {
        UIViewController *controller=owner;UINavigationController *nav=controller.navigationController;
        if(!controller.presentedViewController && nav.topViewController!=controller && [nav.viewControllers containsObject:controller])
            [nav popToViewController:controller animated:NO];
    }
    NSString *reason=nil;
    if(!SBBackendInvoke(owner,action,value,&reason)) {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:SBUIText(@"common.functionUnavailable") message:reason ?: @"SB-UI-ACTION" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:SBUIText(@"common.close") style:UIAlertActionStyleCancel handler:nil]];
        if([owner isKindOfClass:UIViewController.class] && ![(UIViewController *)owner presentedViewController])[(UIViewController *)owner presentViewController:alert animated:YES completion:nil];
    }
}

// Observe public UIKit presentation values, never a license, preference store,
// model dictionary, or network state. Values are neither persisted nor logged.
@interface LBXViewBinding : NSObject
@property(nonatomic,strong) NSObject *source;
@property(nonatomic,copy) NSArray<NSString *> *keys;
@property(nonatomic,copy) void (^update)(void);
- (instancetype)initWithSource:(NSObject *)source keys:(NSArray *)keys update:(void(^)(void))update;
@end
@implementation LBXViewBinding
- (instancetype)initWithSource:(NSObject *)source keys:(NSArray *)keys update:(void(^)(void))update {
    if ((self=[super init])) {
        _source=source; _keys=[keys copy]; _update=[update copy];
        for (NSString *key in keys) [source addObserver:self forKeyPath:key options:0 context:&BindingContext];
        update();
    } return self;
}
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context!=&BindingContext) { [super observeValueForKeyPath:key ofObject:object change:change context:context]; return; }
    if (NSThread.isMainThread) self.update();
    else { __weak typeof(self) weak=self; dispatch_async(dispatch_get_main_queue(), ^{ if (weak) weak.update(); }); }
}
- (void)dealloc { for (NSString *key in _keys) [_source removeObserver:self forKeyPath:key context:&BindingContext]; }
@end

static UILabel *Label(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label=[UILabel new]; label.text=text; label.numberOfLines=0;
    label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory=YES; label.textColor=color; return label;
}
static UIStackView *Stack(NSArray *items, BOOL horizontal, CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:items];
    stack.axis=horizontal ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    stack.spacing=spacing; return stack;
}
static UIView *Inset(UIView *content, CGFloat padding) {
    UIView *view=[UIView new]; view.backgroundColor=Panel(); view.layer.cornerRadius=10;
    content.translatesAutoresizingMaskIntoConstraints=NO; [view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:padding],
        [content.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-padding],
        [content.topAnchor constraintEqualToAnchor:view.topAnchor constant:padding],
        [content.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-padding]]]; return view;
}
static UIButton *Button(NSString *title, NSString *icon, BOOL primary, void(^handler)(void)) {
    UIButtonConfiguration *config=primary ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.title=title; config.image=SBGlyph(icon); config.imagePadding=10;
    config.contentInsets=NSDirectionalEdgeInsetsMake(13,16,13,16); config.cornerStyle=UIButtonConfigurationCornerStyleMedium;
    config.baseBackgroundColor=primary ? Accent() : Panel(); config.baseForegroundColor=primary ? Canvas() : UIColor.whiteColor;
    UIButton *button=[UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__unused UIAction *action){ if(handler) handler(); }]];
    button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    button.titleLabel.adjustsFontForContentSizeCategory=YES; button.accessibilityLabel=title;
    return button;
}
// Brand and information architecture are drawn here; no backend data is copied.
static UIView *BrandMark(CGFloat size) {
    UIView *mark=[UIView new];mark.backgroundColor=Accent();mark.layer.cornerRadius=size*.24;
    mark.accessibilityIdentifier=@"socialbox.mark";mark.isAccessibilityElement=NO;
    UILabel *letter=Label(SBUIText(@"brand.monogram"),size*.64,UIFontWeightBlack,Canvas());letter.textAlignment=NSTextAlignmentCenter;
    letter.adjustsFontForContentSizeCategory=NO;letter.font=[UIFont systemFontOfSize:size*.64 weight:UIFontWeightBlack];
    letter.translatesAutoresizingMaskIntoConstraints=NO;[mark addSubview:letter];
    [NSLayoutConstraint activateConstraints:@[[mark.widthAnchor constraintEqualToConstant:size],[mark.heightAnchor constraintEqualToConstant:size],
        [letter.centerXAnchor constraintEqualToAnchor:mark.centerXAnchor],[letter.centerYAnchor constraintEqualToAnchor:mark.centerYAnchor]]];return mark;
}
static UIView *Disclosure(NSString *title, NSString *icon, NSArray<UIView *> *items) {
    UIStackView *content=Stack(items,NO,8);content.hidden=YES;
    __weak UIStackView *weakContent=content;
    UIButton *toggle=Button(title,icon,NO,^{ weakContent.hidden=!weakContent.hidden; });
    toggle.accessibilityIdentifier=[@"socialbox.details." stringByAppendingString:title];
    toggle.accessibilityHint=SBUIText(@"common.toggleDetails");
    return Stack(@[toggle,content],NO,8);
}
static UIButton *Contact(void) {
    UIButton *button=Button(SBUIText(@"contact.title"),@"connection",NO, ^{
        // Opening a chat never sends a message. Attempt Telegram directly;
        // its public HTTPS profile remains usable when the app is absent.
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"tg://resolve?domain=sctweaks"] options:@{} completionHandler:^(BOOL opened) {
            if(!opened) [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://t.me/sctweaks"] options:@{} completionHandler:nil];
        }];
    });
    button.accessibilityIdentifier=@"socialbox.contact";
    button.accessibilityHint=SBUIText(@"contact.hint");
    return button;
}
static NSArray<UIView *> *Descendants(UIView *root, Class type) {
    NSMutableArray *result=[NSMutableArray array], *pending=[NSMutableArray arrayWithObject:root];
    while(pending.count && result.count<256) {
        UIView *view=pending.lastObject; [pending removeLastObject];
        if ([view isKindOfClass:type]) [result addObject:view];
        for (UIView *child in view.subviews.reverseObjectEnumerator) [pending addObject:child];
    } return result;
}
// Move only public UIKit inputs/map, preserving their delegates, target/action,
// selected values and backend references. Release constraints at the old parent
// boundary; intrinsic constraints inside the control remain untouched.
static void Detach(UIView *view) {
    for (UIView *ancestor=view.superview; ancestor; ancestor=ancestor.superview) {
        NSMutableArray *constraints=[NSMutableArray array];
        for (NSLayoutConstraint *constraint in ancestor.constraints)
            if (constraint.firstItem==view || constraint.secondItem==view) [constraints addObject:constraint];
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    if ([view.superview isKindOfClass:UIStackView.class]) [(UIStackView *)view.superview removeArrangedSubview:view];
    [view removeFromSuperview]; view.hidden=NO; view.translatesAutoresizingMaskIntoConstraints=NO;
}

// Local detail pages have no backend constructors or implicit operations.
@interface SBSettingsPage : UIViewController
@property(nonatomic,copy) NSArray<UIView *> *items;
@end
@implementation SBSettingsPage
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=Canvas();self.view.tintColor=Accent();
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:scroll];
    UIStackView *body=Stack(self.items,NO,12);body.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:body];
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],[body.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[body.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[body.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],[body.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],[body.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
}
@end

@interface LBXWorkspace : UIView <UISearchBarDelegate>
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIStackView *body;
@property(nonatomic,strong) UIScrollView *scroll;
@property(nonatomic,strong) NSMutableArray<LBXViewBinding *> *bindings;
@property(nonatomic,strong) MKMapView *map;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) SBContainersView *containersView;
@property(nonatomic,strong) UIStackView *originalStack;
@property(nonatomic) BOOL refreshing;
- (void)build;
- (void)refresh;
@end

@implementation LBXWorkspace
- (instancetype)initWithOwner:(UIViewController *)owner {
    if ((self=[super initWithFrame:CGRectZero])) {
        self.owner=owner; self.bindings=[NSMutableArray array];
        self.backgroundColor=Canvas(); self.accessibilityIdentifier=@"socialbox.workspace";
        self.scroll=[UIScrollView new]; self.scroll.alwaysBounceVertical=YES;
        self.scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
        self.scroll.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:self.scroll];
        self.body=Stack(@[],NO,14); self.body.translatesAutoresizingMaskIntoConstraints=NO; [self.scroll addSubview:self.body];
        [NSLayoutConstraint activateConstraints:@[[self.scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
          [self.scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor], [self.scroll.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
          [self.scroll.bottomAnchor constraintEqualToAnchor:self.keyboardLayoutGuide.topAnchor],
          [self.body.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:20],
          [self.body.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-20],
          [self.body.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:16],
          [self.body.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-24],
          [self.body.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    } return self;
}
- (void)heading:(NSString *)title detail:(NSString *)detail {
    UILabel *eyebrow=Label(SBUIText(@"brand.eyebrow"),10,UIFontWeightBold,Accent());
    [self.body addArrangedSubview:eyebrow];
    [self.body addArrangedSubview:Label(title,30,UIFontWeightBold,UIColor.whiteColor)];
    if(detail.length) [self.body addArrangedSubview:Label(detail,13,UIFontWeightRegular,Muted())];
}
- (void)section:(NSString *)title {
    UILabel *label=Label(title.uppercaseString,11,UIFontWeightBold,Accent());
    [self.body addArrangedSubview:label]; [self.body setCustomSpacing:8 afterView:label];
}
- (UIButton *)action:(NSString *)title icon:(NSString *)icon selector:(NSString *)selector value:(id)value primary:(BOOL)primary {
    __weak UIViewController *owner=self.owner;
    UIButton *button=Button(title,icon,primary, ^{ Invoke(owner,selector,value); });
    button.enabled=SBBackendActionAvailable(owner,selector,value,NULL);
    button.accessibilityIdentifier=[@"socialbox.action." stringByAppendingString:selector];
    if(!button.enabled) button.accessibilityHint=SBUIText(@"common.nativeActionUnavailable");
    return button;
}
- (UILabel *)bound:(NSString *)getter size:(CGFloat)size {
    UILabel *source=Read(self.owner,getter,UILabel.class);
    LBXDisplayTextRole role=([getter hasSuffix:@"error"] ? LBXDisplayTextRoleDiagnostic : (([getter hasSuffix:@"status"] || [getter hasSuffix:@"loading"]) ? LBXDisplayTextRoleStatus : LBXDisplayTextRoleUserData));
    UILabel *target=Label(LBXDisplayText(source.text ?: SBUIText(@"common.unavailable"),role),size,UIFontWeightMedium,UIColor.whiteColor);
    if(source) {
        __weak UILabel *weak=target;
        [self.bindings addObject:[[LBXViewBinding alloc] initWithSource:source keys:@[@"text",@"textColor",@"hidden"] update:^{
            weak.text=LBXDisplayText(source.text ?: SBUIText(@"common.emptyValue"),role); weak.textColor=source.textColor ?: UIColor.whiteColor;
        }]];
    } return target;
}
- (UIView *)value:(NSString *)title getter:(NSString *)getter {
    UILabel *value=[self bound:getter size:15];value.font=[UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium];
    return Inset(Stack(@[Label(title.uppercaseString,10,UIFontWeightSemibold,Muted()),value],NO,6),14);
}
- (UIView *)toggle:(NSString *)title subtitle:(NSString *)subtitle source:(UISwitch *)source {
    UISwitch *toggle=[UISwitch new]; toggle.onTintColor=Accent(); toggle.accessibilityLabel=title;
    __weak UISwitch *weak=toggle;
    if(source) [self.bindings addObject:[[LBXViewBinding alloc] initWithSource:source keys:@[@"on",@"enabled"] update:^{
        weak.on=source.on; weak.enabled=source.enabled;
    }]]; else toggle.enabled=NO;
    [toggle addAction:[UIAction actionWithHandler:^(__unused UIAction *action){
        if(!source.enabled) return; source.on=weak.on; [source sendActionsForControlEvents:UIControlEventValueChanged];
    }] forControlEvents:UIControlEventValueChanged];
    UIStackView *copy=Stack(@[Label(title,16,UIFontWeightSemibold,UIColor.whiteColor),Label(subtitle,12,UIFontWeightRegular,Muted())],NO,5);
    UIStackView *row=Stack(@[copy,toggle],YES,12); row.alignment=UIStackViewAlignmentCenter;
    [toggle setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return Inset(row,16);
}
- (UIButton *)control:(NSString *)title icon:(NSString *)icon source:(UIButton *)source primary:(BOOL)primary dynamic:(BOOL)dynamic {
    UIButton *button=Button(title,icon,primary, ^{ if(source.enabled) [source sendActionsForControlEvents:UIControlEventTouchUpInside]; });
    __weak UIButton *weak=button;
    if(source) {
        [self.bindings addObject:[[LBXViewBinding alloc] initWithSource:source keys:@[@"enabled",@"hidden"] update:^{ weak.enabled=source.enabled; weak.hidden=source.hidden; }]];
        if(dynamic) [self.bindings addObject:[[LBXViewBinding alloc] initWithSource:source.titleLabel keys:@[@"text"] update:^{
            NSString *value=LBXWorkspaceHeading(source.currentTitle ?: title);
            if(![weak.configuration.title isEqual:value]) { UIButtonConfiguration *config=weak.configuration; config.title=value; weak.configuration=config; }
        }]];
    } else button.enabled=NO;
    SBScreen role=SBBackendScreen(self.owner);
    if(role==SBScreenHome)button.accessibilityIdentifier=@"socialbox.control.identity.create";
    if(role==SBScreenLicense)button.accessibilityIdentifier=@"socialbox.control.license.button";
    if(role==SBScreenLocation)button.accessibilityIdentifier=@"socialbox.control.location.button";
    return button;
}
- (void)home {
    [self heading:SBUIText(@"home.title") detail:SBUIText(@"home.detail")];
    UILabel *tag=Label(SBUIText(@"home.identityEyebrow"),10,UIFontWeightBold,Accent());
    UIStackView *identity=Stack(@[tag,[self bound:@"identity.modelName" size:26],[self bound:@"identity.deviceName" size:14],[self bound:@"identity.osVersion" size:13]],NO,7);
    UIView *mark=BrandMark(52);UIStackView *hero=Stack(@[identity,mark],YES,12);hero.alignment=UIStackViewAlignmentCenter;
    [identity setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIView *card=Inset(hero,20);card.accessibilityIdentifier=@"socialbox.identity-summary";
    [self.body addArrangedSubview:card];
    [self.body addArrangedSubview:[self control:SBUIText(@"containers.create") icon:@"plus.rectangle.on.folder" source:Read(self.owner,@"create",UIButton.class) primary:YES dynamic:NO]];
    [self.body addArrangedSubview:[self action:SBUIText(@"identity.title") icon:@"slider.horizontal.3" selector:@"home.configureIdentity" value:nil primary:NO]];
    [self.body addArrangedSubview:[self toggle:SBUIText(@"home.useIdentity") subtitle:SBUIText(@"home.useIdentityDetail") source:Read(self.owner,@"identity.toggle",UISwitch.class)]];
    NSMutableArray *details=[NSMutableArray array];
    for(NSArray *item in @[@[SBUIText(@"home.modelNumber"),@"identity.modelNumber"],@[SBUIText(@"home.serial"),@"identity.serial"],@[SBUIText(@"home.carrier"),@"identity.carrier"],@[SBUIText(@"home.mobileCodes"),@"identity.mobileCodes"],
        @[SBUIText(@"home.wifi"),@"identity.wifi"],@[SBUIText(@"home.bluetooth"),@"identity.bluetooth"],@[SBUIText(@"home.ethernet"),@"identity.ethernet"],@[SBUIText(@"home.imei"),@"identity.imei"],@[SBUIText(@"home.meid"),@"identity.meid"],@[SBUIText(@"home.iccid"),@"identity.iccid"],
        @[SBUIText(@"home.advertisingID"),@"identity.advertisingID"],@[SBUIText(@"home.vendorID"),@"identity.vendorID"],@[SBUIText(@"home.deviceID"),@"identity.deviceID"]]) [details addObject:[self value:item[0] getter:item[1]]];
    [self.body addArrangedSubview:Disclosure(SBUIText(@"home.identifiers"),@"number",details)];
    NSMutableArray *tools=[NSMutableArray array];
    for(NSArray *item in @[@[SBUIText(@"home.cloudBackups"),@"icloud",@"home.cloud"],@[SBUIText(@"backups.title"),@"externaldrive",@"home.backups"],
        @[SBUIText(@"home.selectApps"),@"app.badge",@"home.apps"],@[SBUIText(@"home.sessions"),@"key",@"home.sessions"],@[SBUIText(@"home.stopApp"),@"stop.circle",@"home.stopApp"]])
        [tools addObject:[self action:item[0] icon:item[1] selector:item[2] value:nil primary:NO]];
    [self.body addArrangedSubview:Disclosure(SBUIText(@"home.tools"),@"square.grid.2x2",tools)];
    [self.body addArrangedSubview:Contact()];
}
- (UIButton *)page:(NSString *)title subtitle:(NSString *)subtitle items:(NSArray<UIView *> *)items {
    __weak UIViewController *owner=self.owner;
    UIButton *button=Button(title,@"chevron",NO,^{
        if(owner.presentedViewController)return;
        SBSettingsPage *page=[SBSettingsPage new];page.title=title;page.items=items;
        [owner.navigationController pushViewController:page animated:YES];
    });
    UIButtonConfiguration *config=button.configuration;config.subtitle=subtitle;button.configuration=config;
    button.accessibilityIdentifier=[@"socialbox.settings." stringByAppendingString:title];return button;
}
- (void)settings {
    [self heading:SBUIText(@"nav.settings") detail:SBUIText(@"settings.detail")];
    NSArray *server=@[[self value:SBUIText(@"settings.device") getter:@"connection.device"],[self value:SBUIText(@"settings.jailbreak") getter:@"connection.jailbreak"]];
    [self.body addArrangedSubview:[self page:SBUIText(@"settings.server") subtitle:SBUIText(@"settings.serverDetail") items:server]];
    NSMutableArray *license=[NSMutableArray array];
    for(NSArray *item in @[@[SBUIText(@"settings.plan"),@"license.plan"],@[SBUIText(@"settings.status"),@"license.status"]])[license addObject:[self value:item[0] getter:item[1]]];
    [self.body addArrangedSubview:[self page:SBUIText(@"settings.license") subtitle:SBUIText(@"settings.licenseDetail") items:license]];
    // Begin reviewed update settings entry.
    __weak UIViewController *owner=self.owner;
    UIButton *updates=Button(SBUIText(@"updates.title"),@"arrow.down.circle",NO,^{
        if(owner.presentedViewController || owner.navigationController.topViewController!=owner)return;
        [owner.navigationController pushViewController:[SBAppUpdatesViewController new] animated:YES];
    });
    updates.accessibilityIdentifier=@"socialbox.settings.updates";
    [self.body addArrangedSubview:updates];
    // End reviewed update settings entry.
    [self.body addArrangedSubview:Contact()];
}
- (void)configuration {
    [self heading:SBUIText(@"configuration.title") detail:SBUIText(@"configuration.detail")];
    // Keep conditional range/specific rows and compatibility warnings together.
    // The public UIKit inputs retain their tags and delegates; our record
    // renderer replaces the old glass-card typography and two-column layout.
    self.originalStack=Read(self.owner,@"surface",UIStackView.class);
    Detach(self.originalStack); self.originalStack.hidden=NO;
    self.originalStack.spacing=12; [self.body addArrangedSubview:self.originalStack];
}
- (void)onboarding {
    [self heading:SBUIText(@"welcome.title") detail:SBUIText(@"welcome.detail")];
    for(NSArray *step in @[@[SBUIText(@"welcome.createNumber"),SBUIText(@"welcome.createTitle"),SBUIText(@"welcome.createDetail")],
                          @[SBUIText(@"welcome.connectionNumber"),SBUIText(@"welcome.connectionTitle"),SBUIText(@"welcome.connectionDetail")],
                          @[SBUIText(@"welcome.reviewNumber"),SBUIText(@"welcome.reviewTitle"),SBUIText(@"welcome.reviewDetail")]]) {
        UIStackView *text=Stack(@[Label(step[1],18,UIFontWeightSemibold,UIColor.whiteColor),Label(step[2],14,UIFontWeightRegular,Muted())],NO,6);
        UILabel *number=Label(step[0],15,UIFontWeightBold,Accent());[number setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *row=Stack(@[number,text],YES,16);row.alignment=UIStackViewAlignmentTop;[self.body addArrangedSubview:Inset(row,18)];
    }
    [self.body addArrangedSubview:[self action:SBUIText(@"welcome.create") icon:@"plus" selector:@"welcome.create" value:nil primary:YES]];
    [self.body addArrangedSubview:[self action:SBUIText(@"welcome.skip") icon:@"arrow.right" selector:@"welcome.skip" value:nil primary:NO]];
}
- (void)splash {
    UIView *space=[UIView new];[space.heightAnchor constraintEqualToConstant:80].active=YES;[self.body addArrangedSubview:space];
    UIView *mark=BrandMark(72);UIStackView *logo=Stack(@[mark],NO,0);logo.alignment=UIStackViewAlignmentCenter;
    [self.body addArrangedSubview:logo];
    UILabel *title=Label(SBUIText(@"brand.name"),36,UIFontWeightBold,UIColor.whiteColor);title.textAlignment=NSTextAlignmentCenter;
    [self.body addArrangedSubview:title];
    UILabel *subtitle=Label(SBUIText(@"startup.detail"),15,UIFontWeightRegular,Muted());subtitle.textAlignment=NSTextAlignmentCenter;
    [self.body addArrangedSubview:subtitle];
    UIActivityIndicatorView *spinner=Read(self.owner,@"startup.spinner",UIActivityIndicatorView.class);Detach(spinner);spinner.color=Accent();
    UIStackView *progress=Stack(@[spinner],NO,0);progress.alignment=UIStackViewAlignmentCenter;[self.body addArrangedSubview:progress];
    UILabel *status=[self bound:@"startup.status" size:13];status.numberOfLines=0;
    status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];status.adjustsFontForContentSizeCategory=YES;status.textAlignment=NSTextAlignmentCenter;
    [self.body addArrangedSubview:status];
    // Keep validation, delegate, success/denial, timers and dismissal entirely original.
}
- (void)license {
    [self heading:SBUIText(@"brand.name") detail:SBUIText(@"license.detail")];
    UIStackView *identity=Stack(@[BrandMark(60)],NO,0);identity.alignment=UIStackViewAlignmentLeading;
    [self.body addArrangedSubview:identity];
    [self section:SBUIText(@"license.required")];
    [self.body addArrangedSubview:Label(SBUIText(@"license.prompt"),22,UIFontWeightSemibold,UIColor.whiteColor)];
    [self.body addArrangedSubview:[SBActivationView new]];
    [self.body addArrangedSubview:Label(SBUIText(@"license.verificationDetail"),13,UIFontWeightRegular,Muted())];
    // No cancel-to-workspace action or new admission flag is introduced.
}
- (void)location {
    self.scroll.hidden=YES;
    UIView *selector=SBConnectionSelector(self.owner);
    UISearchBar *search=Read(self.owner,@"search",UISearchBar.class);Detach(search);
    search.searchBarStyle=UISearchBarStyleMinimal;search.placeholder=SBUIText(@"location.searchPlaceholder");
    UIStackView *top=Stack(@[selector,search],NO,8);top.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:top];
    self.map=Read(self.owner,@"map",MKMapView.class);Detach(self.map);self.map.layer.cornerRadius=12;self.map.clipsToBounds=YES;[self addSubview:self.map];
    UILabel *coordinates=[self bound:@"location.coordinates" size:20];coordinates.font=[UIFont monospacedSystemFontOfSize:20 weight:UIFontWeightSemibold];
    UIButton *more=Button(SBUIText(@"location.tools"),@"more",NO,nil);more.showsMenuAsPrimaryAction=YES;more.accessibilityIdentifier=@"socialbox.location.tools";
    NSMutableArray *actions=[NSMutableArray array];__weak UIViewController *owner=self.owner;
    for(NSArray *item in @[@[SBUIText(@"location.useProxy"),@"location.proxy"],@[SBUIText(@"location.bookmarks"),@"location.bookmarks"],@[SBUIText(@"location.history"),@"location.history"],@[SBUIText(@"location.mapStyle"),@"location.mapStyle"],@[SBUIText(@"location.useDevice"),@"location.device"],@[SBUIText(@"location.copyCoordinates"),@"location.copy"],@[SBUIText(@"location.verify"),@"location.verify"]]) {
        UIAction *action=[UIAction actionWithTitle:item[0] image:nil identifier:nil handler:^(__unused UIAction *a){Invoke(owner,item[1],nil);}];
        if(!SBBackendActionAvailable(owner,item[1],nil,NULL))action.attributes=UIMenuElementAttributesDisabled;
        [actions addObject:action];
    }
    more.menu=[UIMenu menuWithChildren:actions];
    UIStackView *selection=Stack(@[coordinates,[self bound:@"location.address" size:12],[self bound:@"location.status" size:12],more,[self control:SBUIText(@"location.start") icon:@"location" source:Read(self.owner,@"location.button",UIButton.class) primary:YES dynamic:YES]],NO,8);
    UIView *panel=Inset(selection,16);panel.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:panel];
    [NSLayoutConstraint activateConstraints:@[[top.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],[top.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],[top.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],[self.map.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],[self.map.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],[self.map.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:8],[self.map.bottomAnchor constraintEqualToAnchor:panel.topAnchor constant:-8],[self.map.heightAnchor constraintGreaterThanOrEqualToConstant:100],[panel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],[panel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],[panel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10]]];
}
- (void)containers {
    self.scroll.hidden=YES;
    self.containersView=[[SBContainersView alloc] initWithOwner:self.owner];self.containersView.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:self.containersView];
    [NSLayoutConstraint activateConstraints:@[[self.containersView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],[self.containersView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],[self.containersView.topAnchor constraintEqualToAnchor:self.topAnchor],[self.containersView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]]];
}
- (void)proxies {
    [self.body addArrangedSubview:SBConnectionSelector(self.owner)];
    [self heading:SBUIText(@"nav.proxy") detail:SBUIText(@"proxies.detail")];
    [self.body addArrangedSubview:[self action:SBUIText(@"proxies.add") icon:@"plus" selector:@"proxies.add" value:nil primary:YES]];
    UISearchBar *search=Read(self.owner,@"search",UISearchBar.class);
    if(search) { Detach(search); search.searchBarStyle=UISearchBarStyleMinimal; [self.body addArrangedSubview:search]; }
    // Original card roots own model associations and menu interactions. Retain
    // those action carriers, while drawing their contents with our own rows.
    // No private gesture targets, proxy credentials or persisted models are read.
    self.originalStack=Read(self.owner,@"surface",UIStackView.class);
    Detach(self.originalStack); self.originalStack.hidden=NO; self.originalStack.spacing=12;
    [self.body addArrangedSubview:self.originalStack];
}
- (void)build {
    switch(SBBackendScreen(self.owner)) {
        case SBScreenHome: [self home];break;case SBScreenSettings:[self settings];break;
        case SBScreenIdentity:[self configuration];break;case SBScreenLicense:[self license];break;
        case SBScreenStartup:[self splash];break;case SBScreenWelcome:[self onboarding];break;
        case SBScreenLocation:[self location];break;case SBScreenContainers:[self containers];break;
        case SBScreenProxies:[self proxies];break;default:break;
    }
}
- (void)refresh {
    if(self.refreshing) return;
    self.refreshing=YES;
    [self.containersView refresh];
    for(LBXViewBinding *binding in self.bindings) binding.update();
    self.refreshing=NO;
}
@end

// A new compact row presentation inside a retained interaction carrier. Inputs,
// menu gestures, accessibility actions and data-source identity stay attached to
// their original object. Only inert labels and decorative surfaces are hidden.
@interface LBXRecordContent : UIView
@property(nonatomic,strong) NSMutableArray *bindings;
@property(nonatomic,strong) NSArray *sources;
@end
@implementation LBXRecordContent
- (instancetype)initWithLabels:(NSArray<UILabel *> *)labels {
    if((self=[super initWithFrame:CGRectZero])) {
        self.userInteractionEnabled=NO; self.backgroundColor=Panel(); self.layer.cornerRadius=10; self.clipsToBounds=YES; self.bindings=[NSMutableArray array]; self.sources=labels;
        UIStackView *stack=Stack(@[],NO,5);
        NSUInteger index=0;
        for(UILabel *source in labels) {
            UILabel *target=Label(source.text ?: @"",index==0 ? 17 : 13,index==0 ? UIFontWeightSemibold : UIFontWeightRegular,index==0 ? UIColor.whiteColor : Muted());
            __weak UILabel *weak=target;
            [self.bindings addObject:[[LBXViewBinding alloc] initWithSource:source keys:@[@"text",@"textColor",@"hidden"] update:^{
                weak.text=source.text; weak.hidden=source.hidden;
                CGFloat saturation=0; [source.textColor getHue:NULL saturation:&saturation brightness:NULL alpha:NULL];
                weak.textColor=saturation>.4 ? source.textColor : (source==labels.firstObject ? UIColor.whiteColor : Muted());
            }]];
            [stack addArrangedSubview:target]; index++;
        }
        stack.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18], [stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:12],
            [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-12], [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]]];
        UIView *stripe=[UIView new]; stripe.backgroundColor=Accent(); stripe.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:stripe];
        [NSLayoutConstraint activateConstraints:@[[stripe.widthAnchor constraintEqualToConstant:2],[stripe.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [stripe.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],[stripe.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12]]];
    } return self;
}
@end
static char RecordKey, ControlStyleKey;
static void Record(UIView *carrier) {
    if(!carrier || [carrier isKindOfClass:UIControl.class]) return;
    LBXRecordContent *current=objc_getAssociatedObject(carrier,&RecordKey);
    NSMutableArray *labels=[NSMutableArray array];
    for(UILabel *label in Descendants(carrier,UILabel.class)) {
        if(current && [label isDescendantOfView:current]) continue;
        // Do not obscure button, field, or text-view content.
        BOOL input=NO;
        for(UIView *v=label.superview; v && v!=carrier; v=v.superview)
            if([v isKindOfClass:UIControl.class] || [v isKindOfClass:UITextView.class]) input=YES;
        if(!input) [labels addObject:label];
    }
    // Unknown cards with interactive embedded controls remain native instead of
    // covering or stealing their hit testing. Their surrounding layout is ours.
    if(!labels.count || Descendants(carrier,UIControl.class).count || Descendants(carrier,UITextView.class).count) {
        carrier.backgroundColor=Panel(); carrier.layer.cornerRadius=12;
        for(UIButton *button in Descendants(carrier,UIButton.class)) {
            if(objc_getAssociatedObject(button,&ControlStyleKey)) continue;
            objc_setAssociatedObject(button,&ControlStyleKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // Changing UIButton's public appearance leaves targets, primary
            // actions, menu objects, enabled state and selection untouched.
            UIButtonConfiguration *config=button.configuration ?: UIButtonConfiguration.tintedButtonConfiguration;
            config.title=button.currentTitle; config.image=button.currentImage; config.baseBackgroundColor=Panel();
            config.baseForegroundColor=Accent(); config.cornerStyle=UIButtonConfigurationCornerStyleMedium;
            button.configuration=config;
        }
        return;
    }
    if(current && [current.sources isEqual:labels]) return;
    [current removeFromSuperview];
    current=[[LBXRecordContent alloc] initWithLabels:labels];
    for(UILabel *label in labels) label.alpha=0; // hidden remains a backend state, observed above.
    carrier.backgroundColor=Panel(); carrier.layer.cornerRadius=10; carrier.layer.borderWidth=0;
    for(CALayer *layer in carrier.layer.sublayers) if([layer isKindOfClass:NSClassFromString(@"CAGradientLayer")]) layer.hidden=YES;
    current.translatesAutoresizingMaskIntoConstraints=NO; [carrier addSubview:current];
    [NSLayoutConstraint activateConstraints:@[[current.leadingAnchor constraintEqualToAnchor:carrier.leadingAnchor],
        [current.trailingAnchor constraintEqualToAnchor:carrier.trailingAnchor],[current.topAnchor constraintEqualToAnchor:carrier.topAnchor],
        [current.bottomAnchor constraintEqualToAnchor:carrier.bottomAnchor]]];
    objc_setAssociatedObject(carrier,&RecordKey,current,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void Records(UIStackView *stack) {
    for(UIView *view in stack.arrangedSubviews) {
        if([view isKindOfClass:UIStackView.class]) {
            UIStackView *group=(id)view;
            group.axis=UILayoutConstraintAxisVertical; group.distribution=UIStackViewDistributionFill; group.spacing=10;
            Records(group);
        } else if([view isKindOfClass:UILabel.class]) {
            UILabel *label=(id)view; label.font=[UIFont systemFontOfSize:11 weight:UIFontWeightBold]; label.textColor=Muted();
        } else Record(view);
    }
}

// Reviewed proxy builders (0x100202de8, 0x1002035f0, 0x100204500,
// 0x100205714, 0x10020636c) supply public UIKit carriers. Keep their action
// objects and model associations; replace all interior layout and static copy.
// No private selector, gesture target or model dictionary is inspected here.
@interface SBProxyRow : UIView
@property(nonatomic,copy) NSArray<UILabel *> *sources;
@property(nonatomic,copy) NSArray<UIControl *> *controls;
@property(nonatomic,copy) NSArray<UIImageView *> *indicators;
@property(nonatomic,strong) NSMutableArray<LBXViewBinding *> *bindings;
@property(nonatomic,copy) NSString *role;
@property(nonatomic) BOOL available;
@end
@implementation SBProxyRow @end
static char ProxyRowKey, ProxyInteractionKey;
static UIView *ProxyContent(UIView *carrier) {
    return [carrier isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)carrier).contentView : carrier;
}
static BOOL ProxyCollect(UIView *carrier, SBProxyRow *current, NSMutableArray *labels,
                         NSMutableArray *controls, NSMutableArray *images, NSUInteger depth) {
    if(depth>6 || labels.count>12 || controls.count>4 || images.count>3) return NO;
    for(UIView *view in ProxyContent(carrier).subviews) {
        if(view==current) continue;
        if([view isKindOfClass:UILabel.class]) {
            UILabel *label=(id)view;
            if(view.userInteractionEnabled || view.gestureRecognizers.count || (label.text ?: label.attributedText.string).length>4096) return NO;
            [labels addObject:label];
        } else if([view isKindOfClass:UISwitch.class] || [view isKindOfClass:UIButton.class]) [controls addObject:view];
        else if([view isKindOfClass:UIImageView.class]) {
            if(view.userInteractionEnabled || view.gestureRecognizers.count) return NO;
            [images addObject:view];
        } else if([view isMemberOfClass:UIView.class] || [view isKindOfClass:UIStackView.class] || [view isKindOfClass:UIVisualEffectView.class]) {
            if(view.gestureRecognizers.count || !ProxyCollect(view,current,labels,controls,images,depth+1)) return NO;
        } else return NO;
    }
    return labels.count<=12 && controls.count<=4 && images.count<=3;
}
static NSString *ProxyText(UILabel *label) { return label.text ?: label.attributedText.string ?: @""; }
static BOOL ProxyNativeControl(UIControl *control, UIViewController *owner) {
    UIControlEvents event=[control isKindOfClass:UISwitch.class] ? UIControlEventValueChanged : UIControlEventTouchUpInside;
    return [control.allTargets containsObject:owner] && (control.allControlEvents & event)==event;
}
// Begin reviewed native proxy context preservation.
@interface SBProxyContextObservation : NSObject <UIContextMenuInteractionDelegate> @end
@implementation SBProxyContextObservation
- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    (void)interaction;(void)location;return nil;
}
@end
static NSDictionary<NSString *,NSNumber *> *ProxyContextClasses(NSArray *objects, BOOL gestures) {
    NSMutableDictionary *classes=[NSMutableDictionary dictionary];
    for(id object in objects) {
        NSString *key=NSStringFromClass([object class]);
        if(gestures) {
            id delegate=((UIGestureRecognizer *)object).delegate;
            key=[key stringByAppendingFormat:@"/%@",delegate?NSStringFromClass([delegate class]):@"nil"];
        }
        classes[key]=@([classes[key] unsignedIntegerValue]+1);
    }
    return classes;
}
static BOOL ProxyContextInteractionClassesMatch(NSDictionary *actual, NSDictionary *active, NSDictionary *persistent) {
    if(![[NSSet setWithArray:actual.allKeys] isEqual:[NSSet setWithArray:active.allKeys]])return NO;
    for(NSString *key in active) {
        NSUInteger observed=[actual[key] unsignedIntegerValue],expected=[active[key] unsignedIntegerValue];
        if(observed<expected)return NO;
        if(observed!=expected) {
            NSUInteger retained=[persistent[key] unsignedIntegerValue];
            if(!retained || (observed-expected)%retained)return NO;
        }
    }
    return YES;
}
static BOOL ProxyNativeContextCompanions(UIView *carrier, UIViewController *owner) {
    UIContextMenuInteraction *native=nil;
    NSMutableArray *interactions=[NSMutableArray array],*gestures=[NSMutableArray array];NSUInteger taps=0;
    for(id<UIInteraction> interaction in carrier.interactions) {
        if([interaction isKindOfClass:UIContextMenuInteraction.class]) {
            if(native)return NO;
            native=(id)interaction;
            if(native.delegate!=(id)owner || native.view!=carrier)return NO;
        } else [interactions addObject:interaction];
    }
    if(!native)return NO;
    for(UIGestureRecognizer *gesture in carrier.gestureRecognizers) {
        if([gesture isMemberOfClass:UITapGestureRecognizer.class])taps++;
        else [gestures addObject:gesture];
    }
    if(taps!=1 || !gestures.count)return NO;
    // Observe UIKit's own companion set on an unattached, inert reference.
    // This neither calls the native delegate nor alters its existing objects.
    UIView *reference=[UIView new];SBProxyContextObservation *delegate=[SBProxyContextObservation new];
    UIContextMenuInteraction *context=[[UIContextMenuInteraction alloc] initWithDelegate:delegate];
    [reference addInteraction:context];
    NSMutableArray *referenceInteractions=[NSMutableArray array];
    for(id<UIInteraction> interaction in reference.interactions)if(interaction!=context)[referenceInteractions addObject:interaction];
    NSDictionary *active=ProxyContextClasses(referenceInteractions,NO),*referenceGestures=ProxyContextClasses(reference.gestureRecognizers,YES);
    [reference removeInteraction:context];
    // UIKit can retain feedback companions after removal and add another copy
    // on reattachment. Only those observed persistent classes may gain copies.
    NSDictionary *persistent=ProxyContextClasses(reference.interactions,NO);
    return ProxyContextInteractionClassesMatch(ProxyContextClasses(interactions,NO),active,persistent) &&
        [ProxyContextClasses(gestures,YES) isEqual:referenceGestures];
}
// End reviewed native proxy context preservation.
static NSString *ProxyRole(UIView *carrier, NSArray<UILabel *> *labels, NSArray<UIControl *> *controls, NSArray *images) {
    if(controls.count==1 && [controls[0] isKindOfClass:UISwitch.class] && labels.count==2 && images.count==1 && !carrier.gestureRecognizers.count) {
        // Exact static title slots only. Proxy names and other user values are
        // never searched, translated or treated as an action identifier.
        NSString *title=ProxyText(labels[0]);
        if([title isEqual:@"System Proxy (VPN)"]) return @"system";
        if([title isEqual:@"Auto-Rotate IP"]) return @"rotate";
        return nil;
    }
    BOOL buttons=YES;for(UIControl *control in controls) if(![control isKindOfClass:UIButton.class]) buttons=NO;
    if(buttons && controls.count==3 && labels.count==3 && !images.count && !carrier.gestureRecognizers.count && [ProxyText(labels[0]) isEqual:@"Add your first proxy"]) {
        NSArray *titles=@[@"Scan QR code",@"Paste a list",@"Import from Shadowrocket"];
        // The pinned native builder uses @"  %@" at 0x100206218 to pad its
        // image. Accept that exact static variant and our already-restyled one;
        // never trim proxy names, credentials, or arbitrary source values.
        for(NSUInteger i=0;i<titles.count;i++) {
            NSString *title=((UIButton *)controls[i]).currentTitle;
            if(![title isEqual:titles[i]] && ![title isEqual:[@"  " stringByAppendingString:titles[i]]]) return nil;
        }
        return @"empty";
    }
    if(buttons && controls.count==2 && labels.count==2 && images.count==1 && !carrier.gestureRecognizers.count &&
       [controls[0].accessibilityLabel isEqual:@"Check IP in Safari"]) return @"active";
    if(!controls.count && labels.count>=1 && labels.count<=8 && images.count<=1) {
        for(UIGestureRecognizer *gesture in carrier.gestureRecognizers) if(![gesture isKindOfClass:UITapGestureRecognizer.class]) return nil;
        return @"data";
    }
    return nil;
}
static void ProxyPin(UIView *content, UIView *parent, CGFloat inset) {
    content.translatesAutoresizingMaskIntoConstraints=NO;[parent addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [content.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [content.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [content.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]]];
}
static UILabel *ProxyBoundLabel(SBProxyRow *row, UILabel *source, BOOL title) {
    UILabel *target=Label(ProxyText(source),title?17:13,title?UIFontWeightSemibold:UIFontWeightRegular,title?UIColor.whiteColor:Muted());
    // These are reported values, including user names and native test results.
    // Their colors are deliberately neutral; rendering never certifies a test.
    __weak UILabel *weak=target;
    [row.bindings addObject:[[LBXViewBinding alloc] initWithSource:source keys:@[@"text",@"attributedText",@"hidden"] update:^{
        weak.text=LBXDisplayText(ProxyText(source),LBXDisplayTextRoleUserData);weak.hidden=source.hidden;
    }]];
    return target;
}
static void ProxyRecord(UIView *carrier, UIViewController *owner) {
    SBProxyRow *current=objc_getAssociatedObject(carrier,&ProxyRowKey);
    NSMutableArray *labels=[NSMutableArray array],*controls=[NSMutableArray array],*images=[NSMutableArray array];
    BOOL tree=([carrier isMemberOfClass:UIView.class] || [carrier isKindOfClass:UIVisualEffectView.class]) && ProxyCollect(carrier,current,labels,controls,images,0);
    for(UIControl *control in current.controls) if([control isDescendantOfView:current]) [controls addObject:control];
    for(UIImageView *image in current.indicators) if([image isDescendantOfView:current]) [images addObject:image];
    for(UIControl *control in controls) tree=tree && ProxyNativeControl(control,owner);
    // Begin reviewed proxy empty-state removal.
    // Keep the exact native empty carrier and its original controls alive for
    // backend rebuilds, while the existing Add proxy button supplies the entry.
    // Saved proxy rows and unrecognized carriers never match this static shape.
    static char ProxyEmptyVisibilityKey;
    NSString *emptyRole=tree?ProxyRole(carrier,labels,controls,images):nil;
    NSDictionary *emptyVisibility=objc_getAssociatedObject(carrier,&ProxyEmptyVisibilityKey);
    if([emptyRole isEqual:@"empty"]) {
        if(!emptyVisibility) objc_setAssociatedObject(carrier,&ProxyEmptyVisibilityKey,
            @{@"hidden":@(carrier.hidden),@"accessibility":@(carrier.accessibilityElementsHidden)},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        carrier.hidden=YES;carrier.accessibilityElementsHidden=YES;
        return;
    }
    if(emptyVisibility) {
        carrier.hidden=[emptyVisibility[@"hidden"] boolValue];
        carrier.accessibilityElementsHidden=[emptyVisibility[@"accessibility"] boolValue];
        objc_setAssociatedObject(carrier,&ProxyEmptyVisibilityKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // End reviewed proxy empty-state removal.
    // Begin reviewed native proxy context admission.
    NSString *role=tree?ProxyRole(carrier,labels,controls,images):nil;
    if(!role && tree && !controls.count && labels.count>=1 && labels.count<=8 && images.count<=1 &&
       ProxyNativeContextCompanions(carrier,owner))role=@"data";
    BOOL sameObjects=current && [current.sources isEqual:labels] && [current.controls isEqual:controls] && [current.indicators isEqual:images];
    // The active renderer changes only this exact static accessibility caption.
    // Admit its authored variant only for the same previously admitted senders.
    if(!role && tree && sameObjects && current.available && [current.role isEqual:@"active"] &&
       controls.count==2 && labels.count==2 && images.count==1 &&
       [((UIControl *)controls[0]).accessibilityLabel isEqual:SBUIText(@"proxies.checkIP")])role=@"active";
    BOOL sameAdmission=current.available==(role!=nil) && (current.role==role || [current.role isEqual:role]);
    if(current && sameObjects && sameAdmission && (tree || !current.available)) {
        for(LBXViewBinding *binding in current.bindings) binding.update();
        [ProxyContent(carrier) bringSubviewToFront:current];return;
    }
    // End reviewed native proxy context admission.
    // Capture native visibility before suppressing its former layout. Detach
    // deliberately resets hidden, so restore each retained object's own state.
    NSMapTable<UIView *,NSNumber *> *visibility=[NSMapTable strongToStrongObjectsMapTable];
    for(UIView *view in [controls arrayByAddingObjectsFromArray:images]) [visibility setObject:@(view.hidden) forKey:view];
    for(UIControl *control in controls) if([control isDescendantOfView:current]) {Detach(control);[ProxyContent(carrier) addSubview:control];}
    for(UIImageView *image in images) if([image isDescendantOfView:current]) {Detach(image);[ProxyContent(carrier) addSubview:image];}
    [current removeFromSuperview];
    SBProxyRow *row=[SBProxyRow new];row.role=role;row.available=role!=nil;row.sources=labels;row.controls=controls;row.indicators=images;row.bindings=[NSMutableArray array];
    objc_setAssociatedObject(carrier,&ProxyRowKey,row,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *interaction=objc_getAssociatedObject(carrier,&ProxyInteractionKey);
    if(!interaction) {interaction=@(carrier.userInteractionEnabled);objc_setAssociatedObject(carrier,&ProxyInteractionKey,interaction,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
    carrier.userInteractionEnabled=row.available && interaction.boolValue;
    if(!row.available) carrier.isAccessibilityElement=NO;
    UIView *content=ProxyContent(carrier);
    if([carrier isKindOfClass:UIVisualEffectView.class]) ((UIVisualEffectView *)carrier).effect=nil;
    [NSLayoutConstraint deactivateConstraints:carrier.constraints];
    if(content!=carrier) [NSLayoutConstraint deactivateConstraints:content.constraints];
    // Begin reviewed native proxy visibility recovery.
    for(UIView *view in content.subviews) {
        if([view isKindOfClass:UILabel.class]) {view.alpha=0;view.accessibilityElementsHidden=YES;}
        // The opaque unavailable row covers native images. Preserve their own
        // hidden state so a later valid context can restore the exact selection.
        else if(!row.available && [view isKindOfClass:UIImageView.class])continue;
        else view.hidden=YES;
    }
    // End reviewed native proxy visibility recovery.
    for(CALayer *layer in carrier.layer.sublayers) if([layer isKindOfClass:CAGradientLayer.class]) layer.hidden=YES;
    carrier.backgroundColor=Panel();carrier.layer.cornerRadius=8;carrier.layer.borderWidth=0;carrier.layer.shadowOpacity=0;
    row.backgroundColor=Panel();row.accessibilityIdentifier=[@"socialbox.proxy.row." stringByAppendingString:role ?: @"unavailable"];
    UIStackView *body=Stack(@[],NO,10);
    if(!row.available) {
        [body addArrangedSubview:Label(SBUIText(@"proxies.rowUnavailable"),16,UIFontWeightSemibold,UIColor.whiteColor)];
        [body addArrangedSubview:Label(SBUIText(@"proxies.rowUnavailableDetail"),13,UIFontWeightRegular,Muted())];
    } else if([role isEqual:@"system"] || [role isEqual:@"rotate"]) {
        BOOL system=[role isEqual:@"system"];
        UIStackView *copy=Stack(@[Label(system?SBUIText(@"proxies.systemTitle"):SBUIText(@"proxies.rotateTitle"),17,UIFontWeightSemibold,UIColor.whiteColor),
            Label(system?SBUIText(@"proxies.systemDetail"):SBUIText(@"proxies.rotateDetail"),13,UIFontWeightRegular,Muted())],NO,6);
        UISwitch *control=(id)controls[0];Detach(control);control.hidden=[[visibility objectForKey:control] boolValue];control.onTintColor=Accent();
        [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *line=Stack(@[copy,control],YES,18);line.alignment=UIStackViewAlignmentCenter;[body addArrangedSubview:line];
    } else {
        if([role isEqual:@"empty"]) {
            [body addArrangedSubview:Label(SBUIText(@"proxies.emptyTitle"),22,UIFontWeightSemibold,UIColor.whiteColor)];
            [body addArrangedSubview:Label(SBUIText(@"proxies.emptyDetail"),14,UIFontWeightRegular,Muted())];
            [body addArrangedSubview:Label(SBUIText(@"proxies.importHint"),12,UIFontWeightMedium,Muted())];
        } else {
            [body addArrangedSubview:Label(SBUIText(@"proxies.coreState"),10,UIFontWeightMedium,Muted())];
            for(NSUInteger i=0;i<labels.count;i++) [body addArrangedSubview:ProxyBoundLabel(row,labels[i],i==0)];
        }
        for(NSUInteger i=0;i<controls.count;i++) {
            UIButton *button=(id)controls[i];Detach(button);button.hidden=[[visibility objectForKey:button] boolValue];
            for(NSLayoutConstraint *constraint in button.constraints.copy)
                if(constraint.firstItem==button && !constraint.secondItem &&
                   (constraint.firstAttribute==NSLayoutAttributeWidth || constraint.firstAttribute==NSLayoutAttributeHeight)) constraint.active=NO;
            UIButtonConfiguration *configuration=button.configuration ?: UIButtonConfiguration.tintedButtonConfiguration;
            configuration.baseBackgroundColor=Canvas();configuration.baseForegroundColor=Accent();configuration.cornerStyle=UIButtonConfigurationCornerStyleMedium;
            configuration.contentInsets=NSDirectionalEdgeInsetsMake(12,14,12,14);
            if([role isEqual:@"active"]) {
                configuration.title=i==0?SBUIText(@"proxies.checkIP"):SBUIText(@"proxies.disconnect");button.accessibilityLabel=configuration.title;
            } else {
                NSString *title=button.currentTitle;
                if([role isEqual:@"empty"] && [title hasPrefix:@"  "]) title=[title substringFromIndex:2];
                configuration.title=LBXDisplayText(title,LBXDisplayTextRoleFixed);
            }
            button.configuration=configuration;button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
            [body addArrangedSubview:button];
        }
        if([role isEqual:@"data"]) for(UIImageView *indicator in images) {
            Detach(indicator);indicator.hidden=[[visibility objectForKey:indicator] boolValue];indicator.tintColor=Accent();
            UIStackView *line=Stack(@[indicator],NO,0);line.alignment=UIStackViewAlignmentLeading;[body addArrangedSubview:line];
            [indicator.widthAnchor constraintEqualToConstant:22].active=YES;[indicator.heightAnchor constraintEqualToConstant:22].active=YES;
        }
    }
    ProxyPin(body,row,16);ProxyPin(row,content,0);
}
static void ProxyRecords(UIStackView *stack, UIViewController *owner) {
    for(UIView *view in stack.arrangedSubviews) {
        if([view isKindOfClass:UIStackView.class] && !view.gestureRecognizers.count) {
            UIStackView *group=(id)view;group.axis=UILayoutConstraintAxisVertical;group.spacing=12;group.distribution=UIStackViewDistributionFill;ProxyRecords(group,owner);
        } else if([view isKindOfClass:UILabel.class] && !view.gestureRecognizers.count && !view.userInteractionEnabled) {
            UILabel *label=(id)view;label.font=[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];label.textColor=Muted();
        } else ProxyRecord(view,owner);
    }
}
void LBXWorkspaceStyleTable(UITableView *table) {
    if(!table) return;
    table.backgroundColor=Canvas(); table.separatorColor=[Muted() colorWithAlphaComponent:.2];
    for(UITableViewCell *cell in table.visibleCells) Record(cell.contentView);
}
void LBXWorkspaceStyleCell(UITableViewCell *cell) { Record(cell.contentView); }
static NSDictionary *Requirements(void) {
    return @{@(SBScreenHome):@{@"identity.modelName":UILabel.class,@"create":UIButton.class,@"identity.toggle":UISwitch.class},
        @(SBScreenSettings):@{@"connection.status":UILabel.class,@"surface":UIStackView.class},
        @(SBScreenIdentity):@{@"identity.country":UILabel.class,@"surface":UIStackView.class},
        @(SBScreenWelcome):@{@"mesh":CALayer.class},
        @(SBScreenStartup):@{@"logo":UIImageView.class,@"startup.status":UILabel.class,@"startup.spinner":UIActivityIndicatorView.class},
        @(SBScreenLicense):@{@"license.field":UITextField.class,@"license.button":UIButton.class,@"license.error":UILabel.class},
        @(SBScreenLocation):@{@"map":MKMapView.class,@"search":UISearchBar.class,@"location.button":UIButton.class},
        @(SBScreenContainers):@{},@(SBScreenProxies):@{@"search":UISearchBar.class,@"surface":UIStackView.class}};
}
BOOL LBXWorkspaceApply(UIViewController *owner) {
    if(!NSThread.isMainThread || !owner.isViewLoaded) return NO;
    if(SBIdentityApply(owner))return YES;
    if(SBSecondaryApply(owner))return YES;
    SBScreen role=SBBackendScreen(owner);NSString *name=SBBackendScreenName(role);NSDictionary *required=Requirements()[@(role)];
    if(!required)return NO;
    LBXWorkspace *workspace=objc_getAssociatedObject(owner,&WorkspaceKey);
    if(!workspace) {
        // Validate before concealing anything. No speculative getter calls, no
        // KVC, and no instantiation of an admitted screen from the license view.
        for(NSString *getter in required) {
            id object=Read(owner,getter,required[getter]);if(!object){SBShowUnavailable(owner,@"SB-UI-GETTER");return YES;}
            if(role==SBScreenStartup && ![(UIView *)object isDescendantOfView:owner.view]){SBShowUnavailable(owner,@"SB-UI-OWNERSHIP");return YES;}
        }
        if(role==SBScreenWelcome && (!SBBackendActionAvailable(owner,@"welcome.create",nil,NULL) || !SBBackendActionAvailable(owner,@"welcome.skip",nil,NULL))){SBShowUnavailable(owner,@"SB-UI-WELCOME");return YES;}
        workspace=[[LBXWorkspace alloc] initWithOwner:owner];
        for(UIView *view in owner.view.subviews) view.hidden=YES;
        workspace.translatesAutoresizingMaskIntoConstraints=NO; [owner.view addSubview:workspace];
        [NSLayoutConstraint activateConstraints:@[[workspace.leadingAnchor constraintEqualToAnchor:owner.view.leadingAnchor],
            [workspace.trailingAnchor constraintEqualToAnchor:owner.view.trailingAnchor],[workspace.topAnchor constraintEqualToAnchor:owner.view.safeAreaLayoutGuide.topAnchor],
            [workspace.bottomAnchor constraintEqualToAnchor:owner.view.safeAreaLayoutGuide.bottomAnchor]]];
        objc_setAssociatedObject(owner,&WorkspaceKey,workspace,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [workspace build];
        if(role==SBScreenHome || role==SBScreenContainers || role==SBScreenLocation || role==SBScreenProxies || role==SBScreenSettings) {
            owner.navigationItem.leftBarButtonItems=@[];owner.navigationItem.rightBarButtonItems=@[];
            owner.navigationItem.titleView=nil;
            owner.navigationItem.title=role==SBScreenContainers?SBUIText(@"brand.name"):(role==SBScreenHome?SBUIText(@"home.identityNavigation"):(role==SBScreenSettings?SBUIText(@"nav.settings"):SBUIText(@"nav.connection")));
        }
        if(role==SBScreenHome) {
            __weak UIViewController *weakOwner=owner;
            UIAction *back=[UIAction actionWithTitle:SBUIText(@"nav.settings") image:nil identifier:nil handler:^(__unused UIAction *a){SBWorkspaceNavigate(weakOwner,SBScreenSettings);}];
            owner.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithPrimaryAction:back];
        }
        os_log(OS_LOG_DEFAULT,"SB_UI installed screen=%{public}@",name);
        if(!InstalledScreens) InstalledScreens=[NSMutableSet set]; [InstalledScreens addObject:name];
        owner.view.backgroundColor=Canvas();
        CALayer *mesh=Read(owner,@"mesh",CALayer.class); mesh.hidden=YES;
        if(role==SBScreenHome) {
            owner.navigationItem.titleView=nil; owner.navigationItem.title=SBUIText(@"brand.name");
            // Recovered sidebar contains product promotion. Workspace actions
            // above replace it, without opening external links automatically.
            // The source-owned back route above replaces the promotional sidebar.
        }
        if(role==SBScreenLicense || role==SBScreenWelcome) { owner.navigationItem.title=SBUIText(@"brand.name"); owner.navigationItem.titleView=nil; }
        if(role==SBScreenLocation || role==SBScreenProxies) owner.navigationItem.title=SBUIText(@"nav.connection");
        if(role==SBScreenSettings)owner.navigationItem.title=SBUIText(@"nav.settings");
    }
    workspace.table.hidden=NO;
    if(workspace.originalStack) { workspace.originalStack.hidden=NO; if(role==SBScreenProxies) ProxyRecords(workspace.originalStack,owner); else Records(workspace.originalStack); }
    if(workspace.table.tableHeaderView) Record(workspace.table.tableHeaderView);
    for(UITableViewCell *cell in workspace.table.visibleCells) Record(cell.contentView);
    // Keep the backend's batch/reorder bars visible, added after our workspace.
    [workspace refresh];
    SBUpdateObserveAdmittedWorkspace(owner); // Registers only; rendering starts no request.
    return YES;
}
void LBXWorkspaceRefresh(UIViewController *owner) {
    if(!NSThread.isMainThread) { __weak UIViewController *weak=owner; dispatch_async(dispatch_get_main_queue(), ^{ LBXWorkspaceRefresh(weak); }); return; }
    SBSecondaryRefresh(owner);
    SBIdentityRefresh(owner);
    LBXWorkspace *workspace=objc_getAssociatedObject(owner,&WorkspaceKey);
    if(!workspace) return;
    // Recovered builders replace their own rows. Re-render those new records;
    // do not recreate inputs or reset a user's current selection.
    LBXWorkspaceApply(owner);
}
NSDictionary *LBXWorkspaceStatus(void) {
    return @{@"implementation":@"source-owned-workspace",@"screens":[[InstalledScreens allObjects] sortedArrayUsingSelector:@selector(compare:)] ?: @[],
        @"backendAdmissionUnchanged":@YES,@"isolationVerified":@NO};
}
