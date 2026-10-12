// Synthetic UIKit controllers, not archived binaries or isolation acceptance.
#import <UIKit/UIKit.h>
#import <MapKit/MapKit.h>
#import "LBXWorkspace.h"
#import "LBXDisplayCopy.h"
#import "SBBackendAdapter.h"
#import "SBWorkspaceCoordinator.h"
#import "SBSecondaryScreens.h"
#import "SBDesign.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>
#import "LBXPresentation.h"
#import "SBActivationView.h"
#import "activation_transport_fixture.h"
#import "saved_setup_transport_fixture.h"
#import "LBXIsolationViewController.h"
#import "LBXIsolationAssessment.h"
#import "LBXRecoveredContextAdapter.h"
#import "../../ProxyInput/LBXProxyInput.h"
extern BOOL LBXInstallProxyInputFixture(NSDictionary *metadata);
static NSMutableArray *ProxyAdded, *ProxyOriginalInputs;
static NSMutableArray *Failures;
static NSUInteger Checks, HookCount, Actions;
static BOOL LegacyResetAlertTint;
static NSMutableSet<NSString *> *InstalledHookKeys;
static NSUInteger NativeAccentCalls;
static UIColor *SystemOrangeBeforeHook;
static NSString *HookKey(Class cls,SEL selector) { return [NSStringFromClass(cls) stringByAppendingFormat:@"/%@",NSStringFromSelector(selector)]; }
static void UnreviewedHeader(id owner,SEL selector,id table,id header,id section) { (void)owner;(void)selector;(void)table;(void)header;(void)section; }
static NSUInteger DiagnosticCalls, DiagnosticCompletions, DiagnosticHandlers;
static id DiagnosticArgument;
static UIAlertController *DiagnosticAlert;
static UIAlertAction *DiagnosticAction;
static UITextField *DiagnosticField;
static BOOL DiagnosticNested, DiagnosticSuppressPresentation, DiagnosticThrow;
static void (^DiagnosticPresented)(void);
static NSString *Directory;
static NSDictionary *Metadata(void) { return @{@"CFBundleIdentifier":@"com.socialbox.app", @"CFBundleExecutable":@"SocialBox", @"CFBundleShortVersionString":@"3.1.0", @"CFBundleVersion":@"1"}; }
static void Check(BOOL ok, NSString *name) { Checks++; if (!ok) [Failures addObject:name]; }
// A fixture-only stand-in for substrate registration. The production dylib
// resolves the jailbreak's implementation; this symbol is never shipped.
__attribute__((visibility("default"))) void MSHookMessageEx(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method=class_getInstanceMethod(cls,sel); *original=method_getImplementation(method);
    if (!class_addMethod(cls,sel,replacement,method_getTypeEncoding(method))) method_setImplementation(class_getInstanceMethod(cls,sel),replacement);
    HookCount++;
    if(!InstalledHookKeys)InstalledHookKeys=[NSMutableSet set];
    [InstalledHookKeys addObject:HookKey(cls,sel)];
}
@interface _Xv8i : NSObject
@property(nonatomic) long long containerID;
@property(nonatomic,copy) NSString *name;
@property(nonatomic,copy) NSArray *apps;
@end
@implementation _Xv8i @end
@interface _Xth1 : NSObject
+ (UIColor *)primaryColor;
+ (UIColor *)destructiveColor;
@end
@implementation _Xth1
+ (UIColor *)primaryColor { NativeAccentCalls++;return [UIColor colorWithRed:1 green:.4 blue:0 alpha:1]; }
+ (UIColor *)destructiveColor { return UIColor.systemRedColor; }
@end
@interface LBXFixtureScreen : UIViewController <UITableViewDataSource,UITableViewDelegate>
- (void)showError:(id)message;
@property(nonatomic,strong) CAGradientLayer *meshGradientLayer;
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UIImageView *logoView;
@property(nonatomic,strong) UIButton *originalButton;
@property(nonatomic,strong) UILabel *originalLabel;
@property(nonatomic,strong) UITextField *originalField;
@property(nonatomic,strong) UISwitch *originalSwitch;
@property(nonatomic,strong) UIView *statusCard;
@property(nonatomic) NSUInteger loads,appearances,layouts;
@property(nonatomic) NSUInteger headerDisplays, headerCallbacksSeeingOwnedRow;
@property(nonatomic) NSInteger selectedContainer;
@property(nonatomic,strong) UISegmentedControl *modelMode;
@property(nonatomic,strong) UILabel *errorLabel;
@property(nonatomic,strong) UISearchBar *searchBar;
@property(nonatomic,strong) MKMapView *mapView;
@property(nonatomic,strong) UIButton *actionButton;
@property(nonatomic,copy) NSArray *containers;
@property(nonatomic) long long activeContainerID;
- (void)originalAction:(id)sender;
@end
@implementation LBXFixtureScreen
- (void)presentViewController:(UIViewController *)presented animated:(BOOL)animated completion:(void (^)(void))completion {
    [super presentViewController:presented animated:animated completion:completion];
    // Reproduce a legacy presenter applying its orange tint after UIKit returns.
    if(LegacyResetAlertTint && [presented isKindOfClass:UIAlertController.class]) presented.view.tintColor=UIColor.orangeColor;
}
- (void)tableView:(UITableView *)table willDisplayHeaderView:(UIView *)header forSection:(NSInteger)section {
    (void)table;(void)section;self.headerDisplays++;
    if([header isKindOfClass:UITableViewHeaderFooterView.class]) {
        UIView *content=((UITableViewHeaderFooterView *)header).contentView;
        for(UIView *child in content.subviews)if([child.accessibilityIdentifier isEqual:@"socialbox.secondary.row"])self.headerCallbacksSeeingOwnedRow++;
        content.backgroundColor=UIColor.orangeColor;
    }
}
- (void)originalAction:(id)sender { (void)sender; Actions++; }
- (void)viewDidLoad {
    [super viewDidLoad];self.loads++;
    NSMutableArray *models=[NSMutableArray array];for(NSUInteger i=0;i<40;i++){_Xv8i *row=[_Xv8i new];row.containerID=1000+(long long)i;row.name=[NSString stringWithFormat:@"Research %02lu",(unsigned long)i+1];row.apps=@[@"com.fixture.app"];[models addObject:row];}self.containers=models;self.activeContainerID=1000;
    self.searchBar=[UISearchBar new];[self.view addSubview:self.searchBar];
    if([NSStringFromClass(self.class) isEqual:@"LocSimViewController"]){self.mapView=[MKMapView new];[self.view addSubview:self.mapView];self.actionButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.actionButton setTitle:@"Start simulation" forState:0];[self.actionButton addTarget:self action:@selector(originalAction:) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.actionButton];}

    self.view.backgroundColor=UIColor.blackColor;
    self.meshGradientLayer=[CAGradientLayer layer]; self.meshGradientLayer.colors=@[(id)UIColor.blackColor.CGColor,(id)[UIColor colorWithRed:.45 green:.25 blue:0 alpha:1].CGColor];
    [self.view.layer insertSublayer:self.meshGradientLayer atIndex:0];
    self.contentStack=[UIStackView new];self.contentStack.axis=UILayoutConstraintAxisVertical;self.contentStack.spacing=16;
    self.contentStack.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[[self.contentStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18],[self.contentStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],[self.contentStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-22]]];
    UILabel *banner=[UILabel new];banner.text=@"SYNTHETIC UI FIXTURE · no accounts or device checks";banner.textColor=[UIColor colorWithWhite:.72 alpha:1];banner.font=[UIFont systemFontOfSize:11 weight:UIFontWeightMedium];banner.numberOfLines=2;
    [self.contentStack addArrangedSubview:banner];
    self.originalLabel=[UILabel new];self.originalLabel.text=@"Research profile · original value";self.originalLabel.textColor=UIColor.whiteColor;self.originalLabel.font=[UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];self.originalLabel.numberOfLines=2;
    [self.contentStack addArrangedSubview:self.originalLabel];
    self.originalButton=[UIButton buttonWithType:UIButtonTypeSystem];[self.originalButton setTitle:@"New Container" forState:UIControlStateNormal];self.originalButton.titleLabel.font=[UIFont systemFontOfSize:19 weight:UIFontWeightBold];[self.originalButton addTarget:self action:@selector(originalAction:) forControlEvents:UIControlEventTouchUpInside];[self.originalButton.heightAnchor constraintEqualToConstant:54].active=YES;self.originalButton.layer.cornerRadius=20;self.originalButton.backgroundColor=[UIColor colorWithRed:.16 green:.31 blue:.65 alpha:1];
    [self.contentStack addArrangedSubview:self.originalButton];
    self.originalField=[UITextField new];self.originalField.text=@"User-controlled text stays unchanged";self.originalField.textColor=UIColor.whiteColor;self.originalField.borderStyle=UITextBorderStyleRoundedRect;self.originalField.backgroundColor=[UIColor colorWithWhite:.13 alpha:1];[self.contentStack addArrangedSubview:self.originalField];
    for (NSString *label in @[@"Device identity\niPhone 15 · iOS 18.6",@"Proxy\nUS research · configured",@"Setup\nEvidence still needs device testing"]) {
        UIView *card=[UIView new];card.layer.cornerRadius=24;card.backgroundColor=[UIColor colorWithWhite:.18 alpha:.9];
        UILabel *text=[UILabel new];text.text=label;text.numberOfLines=2;text.font=[UIFont systemFontOfSize:18 weight:UIFontWeightMedium];text.textColor=UIColor.whiteColor;text.translatesAutoresizingMaskIntoConstraints=NO;[card addSubview:text];
        [NSLayoutConstraint activateConstraints:@[[card.heightAnchor constraintEqualToConstant:94],[text.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],[text.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],[text.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]]];[self.contentStack addArrangedSubview:card];
    }
    self.statusCard=[UIView new];self.statusCard.layer.cornerRadius=18;self.statusCard.backgroundColor=UIColor.systemGreenColor;self.statusCard.layer.borderColor=UIColor.systemRedColor.CGColor;self.statusCard.layer.borderWidth=2;[self.statusCard.heightAnchor constraintEqualToConstant:40].active=YES;
    self.originalSwitch=[UISwitch new];self.originalSwitch.on=YES;[self.statusCard addSubview:self.originalSwitch];[self.contentStack addArrangedSubview:self.statusCard];
    self.logoView=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cube.fill"]];self.logoView.frame=CGRectMake(0,0,44,34);self.logoView.userInteractionEnabled=NO;self.navigationItem.titleView=[NSStringFromClass(self.class) isEqual:@"HomeViewController"]?self.logoView:nil;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Original" style:UIBarButtonItemStylePlain target:self action:@selector(originalAction:)];
    self.tableView=[[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];self.tableView.dataSource=self;self.tableView.delegate=self;self.tableView.backgroundColor=UIColor.clearColor;
    if ([@[@"_Xc9m", @"CountryPickerViewController", @"CarrierPickerViewController", @"BackupsViewController", @"CloudViewController", @"CloudPushViewController", @"TokensDetailViewController", @"BulkProxyImportViewController"] containsObject:NSStringFromClass(self.class)]) {
        self.contentStack.hidden=YES;self.tableView.frame=self.view.bounds;self.tableView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:self.tableView];
        UILabel *header=[[UILabel alloc] initWithFrame:CGRectMake(0,0,340,50)];header.text=@"  SYNTHETIC FIXTURE · 40 containers";header.textColor=UIColor.lightGrayColor;header.font=[UIFont systemFontOfSize:12 weight:UIFontWeightBold];self.tableView.tableHeaderView=header;
    }
    if ([NSStringFromClass(self.class) isEqual:@"FakeInfoViewController"]) {
        self.originalLabel.text=@"Spoofing Settings";
        self.originalField.text=@"Research device";
        [self.originalButton setTitle:@"Regenerate Identity" forState:0];
        self.modelMode=[[UISegmentedControl alloc] initWithItems:@[@"Range", @"Specific"]];self.modelMode.selectedSegmentIndex=1;
        [self.modelMode addTarget:self action:@selector(originalAction:) forControlEvents:UIControlEventValueChanged];
        [self.contentStack insertArrangedSubview:self.modelMode atIndex:3];
    }
    if ([NSStringFromClass(self.class) isEqual:@"_Xm8u"]) {
        self.originalLabel.text=@"SocialBox License";self.originalField.text=@"SYNTHETIC-KEY";self.originalField.secureTextEntry=YES;
        [self.originalButton setTitle:@"Activate" forState:0];self.originalButton.enabled=NO;
        self.errorLabel=[UILabel new];self.errorLabel.text=@"Fixture only · no validation request";self.errorLabel.textColor=UIColor.systemRedColor;self.errorLabel.numberOfLines=2;[self.contentStack addArrangedSubview:self.errorLabel];
    }
}
- (UILabel *)modelNameValue { return self.originalLabel; }
- (UILabel *)deviceNameValue { return self.originalLabel; }
- (UILabel *)iosVersionValue { return self.originalLabel; }
- (UILabel *)modelNumberValue { return self.originalLabel; }
- (UILabel *)serialValue { return self.originalLabel; }
- (UILabel *)wifiValue { return self.originalLabel; }
- (UILabel *)btValue { return self.originalLabel; }
- (UILabel *)ethernetValue { return self.originalLabel; }
- (UILabel *)imeiValue { return self.originalLabel; }
- (UILabel *)meidValue { return self.originalLabel; }
- (UILabel *)iccidValue { return self.originalLabel; }
- (UILabel *)carrierValue { return self.originalLabel; }
- (UILabel *)mccMncValue { return self.originalLabel; }
- (UILabel *)idfaValue { return self.originalLabel; }
- (UILabel *)idfvValue { return self.originalLabel; }
- (UILabel *)udidValue { return self.originalLabel; }
- (UILabel *)connectionStatusLabel { return self.originalLabel; }
- (UILabel *)deviceIdLabel { return self.originalLabel; }
- (UILabel *)jailbreakTypeLabel { return self.originalLabel; }
- (UILabel *)licenseKeyLabel { return self.originalLabel; }
- (UILabel *)deviceCountLabel { return self.originalLabel; }
- (UILabel *)planTitleLabel { return self.originalLabel; }
- (UILabel *)planStatusLabel { return self.originalLabel; }
- (UILabel *)countryValueLabel { return self.originalLabel; }
- (UILabel *)coordsLabel { return self.originalLabel; }
- (UILabel *)addressLabel { return self.originalLabel; }
- (UILabel *)statusLabel { return self.originalLabel; }
- (UIButton *)fingerprintButton { return self.originalButton; }
- (UISwitch *)mainToggle { return self.originalSwitch; }
- (UITextField *)licenseKeyField { return self.originalField; }
- (UIButton *)validateButton { return self.originalButton; }
- (UILabel *)loadingLabel { return nil; }
- (UITableView *)table { return self.tableView; }
- (UITableView *)backupsTable { return self.tableView; }
- (UITableView *)previewTable { return self.tableView; }
- (UIView *)containerCard { return self.contentStack; }
- (void)showError:(id)message {
    DiagnosticCalls++;DiagnosticArgument=message;
    if(DiagnosticThrow) @throw [NSException exceptionWithName:@"SyntheticError" reason:nil userInfo:nil];
    if([NSStringFromClass(self.class) isEqual:@"_Xm8u"]) {self.errorLabel.text=message;return;}
    if(DiagnosticNested) {DiagnosticNested=NO;DiagnosticSuppressPresentation=YES;[self showError:message];DiagnosticSuppressPresentation=NO;}
    if(DiagnosticSuppressPresentation)return;
    DiagnosticAlert=[UIAlertController alertControllerWithTitle:@"Error" message:message preferredStyle:UIAlertControllerStyleAlert];
    DiagnosticAction=[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){DiagnosticHandlers++;}];
    [DiagnosticAlert addAction:DiagnosticAction];DiagnosticAlert.preferredAction=DiagnosticAction;
    [DiagnosticAlert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=@"untouched-SocialBox-private-field";field.secureTextEntry=YES;DiagnosticField=field;}];
    [self presentViewController:DiagnosticAlert animated:NO completion:^{DiagnosticCompletions++;void(^ready)(void)=DiagnosticPresented;DiagnosticPresented=nil;if(ready)ready();}];
}
- (UILabel *)titleLabel { return self.originalLabel; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];self.appearances++; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews];self.layouts++;self.meshGradientLayer.frame=self.view.bounds; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;(void)section;return 40; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.backgroundColor=[UIColor colorWithWhite:.11 alpha:1];cell.textLabel.text=[NSString stringWithFormat:@"Research %02ld",(long)indexPath.row+1];cell.textLabel.textColor=UIColor.whiteColor;cell.detailTextLabel.text=indexPath.row==0?@"Selected · synthetic state":@"Saved · synthetic state";cell.detailTextLabel.textColor=UIColor.lightGrayColor;cell.imageView.image=[UIImage systemImageNamed:@"iphone"];cell.accessoryType=UITableViewCellAccessoryDetailButton;(void)tableView;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { (void)tableView;self.selectedContainer=indexPath.row; }
@end
@interface HomeViewController:LBXFixtureScreen @end
@implementation HomeViewController @end
@interface _Xc9m:LBXFixtureScreen @end
@implementation _Xc9m @end
@interface LocSimViewController:LBXFixtureScreen @end
@implementation LocSimViewController @end
@interface ProxyViewController:LBXFixtureScreen
- (void)importFromInput:(id)input;
@end
@implementation ProxyViewController
- (void)importFromInput:(id)input { [ProxyOriginalInputs addObject:input?:NSNull.null]; }
- (void)addHTTPProxyWithHost:(NSString *)host port:(NSInteger)port user:(NSString *)user password:(NSString *)password title:(NSString *)title tls:(BOOL)tls {
    (void)title;[ProxyAdded addObject:@{@"host":host,@"port":@(port),@"user":user,@"password":password,@"tls":@(tls),@"kind":@"http"}];
}
- (void)addSOCKS5ProxyWithHost:(NSString *)host port:(NSInteger)port user:(NSString *)user password:(NSString *)password title:(NSString *)title rotationUrl:(NSString *)rotation {
    (void)title;(void)rotation;[ProxyAdded addObject:@{@"host":host,@"port":@(port),@"user":user,@"password":password,@"kind":@"socks5"}];
}
- (void)openProxyImportURL:(NSString *)url { [ProxyAdded addObject:@{@"kind":@"legacy",@"value":url}]; }
@end
@interface SettingsViewController:LBXFixtureScreen @end
@implementation SettingsViewController @end
#define FIXTURE_SCREEN(NAME) @interface NAME:LBXFixtureScreen @end @implementation NAME @end
FIXTURE_SCREEN(FakeInfoViewController)
FIXTURE_SCREEN(CountryPickerViewController)
FIXTURE_SCREEN(CarrierPickerViewController)
FIXTURE_SCREEN(BackupsViewController)
FIXTURE_SCREEN(CloudViewController)
FIXTURE_SCREEN(CloudPushViewController)
FIXTURE_SCREEN(TokensDetailViewController)
FIXTURE_SCREEN(BulkProxyImportViewController)
FIXTURE_SCREEN(_Xm8u)

// The first screen precedes license routing. Exercise registration through the
// real presentation installer, rather than calling the workspace directly.
@interface _Xd2z:LBXFixtureScreen
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UIImageView *logoImageView;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@end
@implementation _Xd2z
- (void)viewDidLoad {
    [super viewDidLoad];
    self.statusLabel=[UILabel new];self.statusLabel.text=@"Checking license";
    self.logoImageView=[UIImageView new];self.spinner=[UIActivityIndicatorView new];
    [self.spinner startAnimating];
    for(UIView *view in @[self.statusLabel,self.logoImageView,self.spinner]) [self.view addSubview:view];
}
@end
@interface SocialBoxOnboardingViewController:LBXFixtureScreen @end
@implementation SocialBoxOnboardingViewController
- (void)tapCreate { Actions++; }
- (void)tapSkip { Actions++; }
@end

static UIView *Workspace(UIViewController *owner) {
    for(UIView *view in owner.view.subviews) if([view.accessibilityIdentifier isEqual:@"socialbox.workspace"]) return view;
    return nil;
}

static UIView *ViewID(UIView *root, NSString *identifier) {
    if([root.accessibilityIdentifier isEqual:identifier])return root;
    for(UIView *child in root.subviews){UIView *match=ViewID(child,identifier);if(match)return match;}return nil;
}
static NSArray *ViewsOfClass(UIView *root, Class type) {
    NSMutableArray *views=[NSMutableArray array];
    if([root isKindOfClass:type])[views addObject:root];
    for(UIView *child in root.subviews)[views addObjectsFromArray:ViewsOfClass(child,type)];
    return views;
}
static BOOL ExactBlue(UIColor *color, UITraitCollection *traits) {
    CGFloat red=0,green=0,blue=0,alpha=0;
    return [[color resolvedColorWithTraitCollection:traits] getRed:&red green:&green blue:&blue alpha:&alpha]
        && fabs(red)<.001 && fabs(green-122.0/255.0)<.001 && fabs(blue-1)<.001 && fabs(alpha-1)<.001;
}
static UILabel *AlertLabel(UIAlertController *alert, NSString *title) {
    for(UILabel *label in ViewsOfClass(alert.view,UILabel.class))
        if([label.text isEqual:title] && !label.hidden && label.alpha>0) return label;
    return nil;
}
static UIColor *AlertLabelColor(UILabel *label) {
    id foreground=label.attributedText.length?[label.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL]:nil;
    return [foreground isKindOfClass:UIColor.class]?foreground:label.textColor;
}
static BOOL AlertContrastLabel(UILabel *label) {
    if(!label)return NO;
    UIColor *color=AlertLabelColor(label);
    if(ExactBlue(color,label.traitCollection))return YES;
    // New UIKit renders white text on its blue action capsule. Earlier UIKit
    // renders blue action text. Keep the platform's public semantic styling.
    if(@available(iOS 26.0,*)) {
        CGFloat red=0,green=0,blue=0,alpha=0;
        return [[color resolvedColorWithTraitCollection:label.traitCollection] getRed:&red green:&green blue:&blue alpha:&alpha]
            && red>.95 && green>.95 && blue>.95 && alpha>.99;
    }
    return NO;
}
static NSUInteger AlertColorPixels(UIAlertController *alert, NSUInteger color) {
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:alert.view.bounds];
    UIImage *image=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context){[alert.view drawViewHierarchyInRect:alert.view.bounds afterScreenUpdates:YES];}];
    CGImageRef source=image.CGImage;size_t width=CGImageGetWidth(source),height=CGImageGetHeight(source);
    NSMutableData *data=[NSMutableData dataWithLength:width*height*4];CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(data.mutableBytes,width,height,8,width*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextDrawImage(context,CGRectMake(0,0,width,height),source);CGContextRelease(context);CGColorSpaceRelease(space);
    const unsigned char *pixels=data.bytes;NSUInteger count=0;
    for(size_t i=0;i<width*height;i++) {
        BOOL matches=color==1?(pixels[i*4]<=2 && abs((int)pixels[i*4+1]-122)<=2 && pixels[i*4+2]>=253)
            :color==2?(pixels[i*4]>200 && pixels[i*4+1]>50 && pixels[i*4+1]<190 && pixels[i*4+2]<70)
            :(pixels[i*4]>178 && pixels[i*4+1]<128 && pixels[i*4+2]<128);
        if(matches && pixels[i*4+3]>=253)count++;
    }
    return count;
}
static NSUInteger MetadataRequests(void) {
    NSUInteger count=0;
    for(NSString *operation in @[@"status",@"stage-create",@"stage-update",@"execute",@"reconcile",@"clear",@"read",@"list"])
        count+=SBTestSavedSetupCount(operation);
    return count;
}
static BOOL VisibleText(UIView *root, NSString *text) {
    if(root.hidden)return NO;
    if([root isKindOfClass:UILabel.class]&&[((UILabel *)root).text isEqual:text])return YES;
    for(UIView *child in root.subviews)if(VisibleText(child,text))return YES;return NO;
}
// These recovered classes actually inherit UITableViewController. Exercise its
// inherited getter and default delegate routing, rather than fabricating a view.
@interface LBXFixturePicker:UITableViewController <UISearchBarDelegate>
@property(nonatomic,strong) UISearchBar *search;
@property(nonatomic,strong) NSArray *values;
@property(nonatomic,copy) NSString *selection;
@property(nonatomic) NSUInteger loads, choices;
- (void)done:(id)sender;
@end
@implementation LBXFixturePicker
- (void)viewDidLoad {
    [super viewDidLoad];self.loads++;self.tableView.backgroundColor=UIColor.blackColor;
    self.values=@[@"iPhone 15",@"iPhone 16",@"iPhone 17"];
    if([NSStringFromClass(self.class) isEqual:@"VersionPickerViewController"])self.values=@[@"18.6",@"26.0",@"26.1"];
    if([NSStringFromClass(self.class) isEqual:@"AppListViewController"])self.values=@[@"Reddit",@"Facebook",@"Fixture App"];
    self.selection=self.values[1];self.search=[UISearchBar new];self.search.delegate=self;self.search.placeholder=@"Search synthetic choices";[self.search sizeToFit];self.tableView.tableHeaderView=self.search;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done:)];
}
- (void)done:(id)sender {(void)sender;Actions++;[self dismissViewControllerAnimated:NO completion:nil];}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {(void)searchBar;self.values=[text isEqual:@"match"]?@[@"Matched choice"]:@[@"iPhone 15",@"iPhone 16",@"iPhone 17"];[self.tableView reloadData];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {(void)tableView;(void)section;return self.values.count;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text=self.values[indexPath.row];cell.textLabel.textColor=UIColor.whiteColor;cell.backgroundColor=[UIColor colorWithWhite:.14 alpha:1];cell.detailTextLabel.text=@"Synthetic option · existing selection handler";cell.detailTextLabel.textColor=UIColor.lightGrayColor;
    cell.accessoryType=[self.selection isEqual:self.values[indexPath.row]]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {self.selection=self.values[indexPath.row];self.choices++;[tableView reloadData];}
@end
#define FIXTURE_PICKER(NAME) @interface NAME:LBXFixturePicker @end @implementation NAME @end
FIXTURE_PICKER(ModelPickerViewController)
FIXTURE_PICKER(VersionPickerViewController)
FIXTURE_PICKER(DRTAllowedModelsViewController)
FIXTURE_PICKER(AppListViewController)

@interface DerivedHome:HomeViewController @end
@implementation DerivedHome @end
@interface WrongSignature:NSObject
- (NSInteger)meshGradientLayer;
- (void)argument:(id)value;
@end
@implementation WrongSignature
- (NSInteger)meshGradientLayer{return 0;}
- (void)argument:(id)value{(void)value;}
@end
static void Save(UIWindow *window, NSString *name) {
    [window layoutIfNeeded];CGRect bounds=window.bounds;bounds.size.height+=30;
    UIGraphicsImageRenderer *r=[[UIGraphicsImageRenderer alloc] initWithBounds:bounds];
    NSData *png=[r PNGDataWithActions:^(UIGraphicsImageRendererContext *ctx){
        [[UIColor colorWithWhite:.04 alpha:1] setFill];UIRectFill(bounds);
        [@"SYNTHETIC UIKit fixture · no physical isolation evidence" drawInRect:CGRectMake(8,7,bounds.size.width-16,20) withAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium],NSForegroundColorAttributeName:UIColor.whiteColor}];
        CGContextTranslateCTM(ctx.CGContext,0,30);[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];
    [png writeToFile:[Directory stringByAppendingPathComponent:name] atomically:YES];
}
static void Invoke(UIBarButtonItem *item) {
    if (item.target && item.action) [UIApplication.sharedApplication sendAction:item.action to:item.target from:item forEvent:nil];
}
// UIKit's presentation/dismissal completion can precede detachment. Sequence
// fixture actions using stable observable readiness, never overlapping modals.
static void AwaitUI(BOOL (^ready)(void), NSUInteger remaining, NSUInteger stable, void (^completion)(BOOL)) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        NSUInteger next=ready()?stable+1:0;
        if(next>=3||remaining==0)completion(next>=3);
        else AwaitUI(ready,remaining-1,next,completion);
    });
}
@interface FixtureApp:UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UITabBarController *tabs;
@property(nonatomic,strong) NSArray<LBXFixtureScreen *> *screens;
@end
@implementation FixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;Failures=[NSMutableArray array];Directory=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
#if defined(LBX_ALERT_TINT_FIXTURE)
    SystemOrangeBeforeHook=UIColor.systemOrangeColor;
    LBXPresentationFixtureMetadata(@{});NSUInteger beforeHooks=HookCount;Check(!LBXDisplayCopyInstallNativeAccent()&&HookCount==beforeHooks,@"native theme installation rejects unsupported host before registration");
    LBXPresentationFixtureMetadata(Metadata());Check(LBXPresentationInstall(),@"actual reviewed presentation hooks install for inert alert fixture");
    [self exerciseNativeAccent];
    self.screens=@[[HomeViewController new],[_Xc9m new],[ProxyViewController new]];
    self.tabs=[UITabBarController new];self.tabs.viewControllers=@[[[UINavigationController alloc] initWithRootViewController:self.screens[0]],[[UINavigationController alloc] initWithRootViewController:self.screens[1]],[[UINavigationController alloc] initWithRootViewController:self.screens[2]]];
    self.tabs.selectedIndex=1;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.window.rootViewController=self.tabs;[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self exerciseSwitchAlert:0];});return YES;
#endif
    NSString *reason=nil;Check(LBXPresentationMetadataSupported(Metadata(),&reason),@"pinned base metadata admitted");Check(reason==nil,@"supported metadata reason empty");
    for (NSString *key in Metadata()) { NSMutableDictionary *wrong=[Metadata() mutableCopy];wrong[key]=@"unsupported";Check(!LBXPresentationMetadataSupported(wrong,&reason),[@"reject different " stringByAppendingString:key]);wrong[key]=@1;Check(!LBXPresentationMetadataSupported(wrong,&reason),[@"reject wrong metadata type " stringByAppendingString:key]); }
    Check(!LBXPresentationMetadataSupported(@{},&reason),@"reject empty metadata");
    Check(!LBXPresentationMethodMatches(WrongSignature.class,@selector(meshGradientLayer),"@",NULL),@"reject scalar object getter");
    Check(!LBXPresentationMethodMatches(WrongSignature.class,@selector(argument:),"v",@encode(BOOL)),@"reject non-BOOL lifecycle arg");
    Check(!LBXPresentationMethodMatches(WrongSignature.class,@selector(viewDidLoad),"v",NULL),@"reject missing selector");
    LBXPresentationFixtureMetadata(@{});Check(!LBXPresentationInstall(),@"wrong bundle cannot install");Check(HookCount==0,@"wrong metadata installs no hooks");
    LBXPresentationFixtureMetadata(Metadata());
    SystemOrangeBeforeHook=UIColor.systemOrangeColor;
    // Reproduce the real startup timing: the app creates its initial license
    // progress controller before the queued presentation installer runs.
    _Xd2z *preloadedStartup=[_Xd2z new];[preloadedStartup loadViewIfNeeded];
    UILabel *preloadedStatus=preloadedStartup.statusLabel;UIActivityIndicatorView *preloadedSpinner=preloadedStartup.spinner;
    _Xm8u *preloadedLicense=[_Xm8u new];[preloadedLicense loadViewIfNeeded];
    UITextField *originalLicenseField=preloadedLicense.originalField;
    UIButton *originalLicenseButton=preloadedLicense.originalButton;
    UILabel *originalLicenseError=preloadedLicense.errorLabel;
    id originalLicenseDelegate=originalLicenseField.delegate;
    NSSet *originalLicenseTargets=originalLicenseButton.allTargets;
    NSArray *originalLicenseActions=[originalLicenseButton actionsForTarget:preloadedLicense forControlEvent:UIControlEventTouchUpInside];
    // Both screens already loaded before installation. Keep a visible registered
    // license root and traverse its existing child startup without loading either.
    [preloadedLicense addChildViewController:preloadedStartup];
    [preloadedLicense.view addSubview:preloadedStartup.view];
    [preloadedStartup didMoveToParentViewController:preloadedLicense];
    UIWindow *startupWindow=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    startupWindow.rootViewController=preloadedLicense;self.window=startupWindow;[startupWindow makeKeyAndVisible];
    NSUInteger preloadedActions=Actions;
    NSUInteger preloadedLicenseRequests=SBTestLicenseRequestCount();
    NSUInteger preloadedValidationRequests=SBTestSavedSetupValidateCount();
    NSUInteger preloadedMetadataRequests=MetadataRequests();
    SEL headerSelector=@selector(tableView:willDisplayHeaderView:forSection:);
    Check(class_addMethod(CountryPickerViewController.class,headerSelector,(IMP)UnreviewedHeader,"v40@0:8@16@24@32"),@"fixture installs intentionally unsupported header section ABI");
    Check(LBXPresentationInstall(),@"known UI ABI installs");NSUInteger installedHooks=HookCount;
    [self exerciseNativeAccent];
    Check(Workspace(preloadedStartup)!=nil,@"installation adopts already-loaded startup before another lifecycle event");
    Check(preloadedStartup.loads==1 && preloadedStartup.statusLabel==preloadedStatus && preloadedStartup.spinner==preloadedSpinner && Actions==preloadedActions,@"adopting startup preserves validation controls and calls no operation");
    UIView *licenseWorkspace=Workspace(preloadedLicense);
    SBActivationView *preloadedActivation=ViewsOfClass(licenseWorkspace,SBActivationView.class).firstObject;
    UITextField *sourceLicenseField=(id)ViewID(licenseWorkspace,@"socialbox.activation.key");
    Check(licenseWorkspace!=nil && ViewsOfClass(licenseWorkspace,SBActivationView.class).count==1 && sourceLicenseField!=nil,@"installation adopts already-loaded registered locked page with one source form");
    Check(startupWindow.rootViewController==preloadedLicense && preloadedStartup.parentViewController==preloadedLicense && preloadedLicense.loads==1,@"late license adoption preserves controller root children and original load count");
    Check(preloadedLicense.originalField==originalLicenseField && preloadedLicense.originalButton==originalLicenseButton && preloadedLicense.errorLabel==originalLicenseError && originalLicenseField.delegate==originalLicenseDelegate,@"late license adoption preserves original field button error and delegate");
    Check([originalLicenseField.text isEqual:@"SYNTHETIC-KEY"] && originalLicenseField.secureTextEntry && !originalLicenseButton.enabled && [originalLicenseTargets isEqual:originalLicenseButton.allTargets] && [originalLicenseActions isEqual:[originalLicenseButton actionsForTarget:preloadedLicense forControlEvent:UIControlEventTouchUpInside]],@"late license adoption retains original private input target actions and disabled state");
    Check(ViewID(preloadedLicense.view,@"socialbox.navigation")==nil && preloadedLicense.tabBarController==nil && startupWindow.rootViewController==preloadedLicense,@"late locked-page adoption creates no admitted navigation shell");
    Check(SBTestLicenseRequestCount()==preloadedLicenseRequests && SBTestSavedSetupValidateCount()==preloadedValidationRequests && MetadataRequests()==preloadedMetadataRequests && Actions==preloadedActions,@"late locked-page adoption sends no activation readiness metadata or original operation");
    sourceLicenseField.text=@"AAAA-BBBB-CCCC-DDDD";
    Check(LBXPresentationInstall() && HookCount==installedHooks && Workspace(preloadedLicense)==licenseWorkspace && ViewsOfClass(licenseWorkspace,SBActivationView.class).count==1 && ViewsOfClass(licenseWorkspace,SBActivationView.class).firstObject==preloadedActivation,@"repeat installation retains the same single activation form");
    Check([sourceLicenseField.text isEqual:@"AAAA-BBBB-CCCC-DDDD"] && preloadedLicense.loads==1 && SBTestLicenseRequestCount()==preloadedLicenseRequests && SBTestSavedSetupValidateCount()==preloadedValidationRequests && MetadataRequests()==preloadedMetadataRequests && Actions==preloadedActions,@"repeat late adoption preserves entered source code and sends no request");
    startupWindow.hidden=YES;startupWindow.rootViewController=nil;
    NSMutableSet<NSString *> *expectedHooks=[NSMutableSet set];
    [expectedHooks addObject:@"_Xth1/primaryColor"];
    [expectedHooks addObject:@"UIColor/systemOrangeColor"];
    [expectedHooks addObject:@"UIColor/colorWithRed:green:blue:alpha:"];
    for(NSString *name in LBXPresentationStatus()[@"styledScreenClasses"])
        for(NSString *selector in @[@"viewDidLoad",@"viewWillAppear:",@"viewDidLayoutSubviews",@"presentViewController:animated:completion:"])
            [expectedHooks addObject:[name stringByAppendingFormat:@"/%@",selector]];
    for(NSString *name in @[@"_Xc9m",@"CarrierPickerViewController",@"BackupsViewController",@"CloudViewController",@"CloudPushViewController",@"TokensDetailViewController",@"BulkProxyImportViewController"])
        [expectedHooks addObject:[name stringByAppendingFormat:@"/%@",NSStringFromSelector(headerSelector)]];
    for(NSString *name in @[@"CloudViewController",@"CloudPushViewController",@"_Xm8u"])
        [expectedHooks addObject:[name stringByAppendingString:@"/showError:"]];
    NSMutableSet *extra=[InstalledHookKeys mutableCopy],*missing=[expectedHooks mutableCopy];[extra minusSet:expectedHooks];[missing minusSet:InstalledHookKeys];
    Check(installedHooks==expectedHooks.count&&[InstalledHookKeys isEqualToSet:expectedHooks],[NSString stringWithFormat:@"exact hook set: expected %lu actual %lu extra=%@ missing=%@",(unsigned long)expectedHooks.count,(unsigned long)installedHooks,extra,missing]);
    Check(method_getImplementation(class_getInstanceMethod(CountryPickerViewController.class,headerSelector))==(IMP)UnreviewedHeader,[NSString stringWithFormat:@"unsupported header ABI remains original: %s",method_getTypeEncoding(class_getInstanceMethod(CountryPickerViewController.class,headerSelector))]);
    Check(LBXPresentationInstall()&&HookCount==installedHooks,@"installation idempotent");
    NSUInteger beforeStartupActions=Actions;
    _Xd2z *startup=[_Xd2z new];[startup loadViewIfNeeded];
    Check(startup.loads==1,@"startup runs original load exactly once");
    Check(Workspace(startup)!=nil,@"registered startup lifecycle installs source UI");
    Check([startup.spinner isDescendantOfView:Workspace(startup)]&&VisibleText(Workspace(startup),@"Checking license"),@"startup projects original live status and retains actual spinner");
    Check(startup.spinner.isAnimating && [startup.statusLabel.text isEqual:@"Checking license"],@"startup registration preserves pending validation state");
    SocialBoxOnboardingViewController *welcome=[SocialBoxOnboardingViewController new];[welcome loadViewIfNeeded];
    Check(welcome.loads==1 && Workspace(welcome)!=nil,@"registered welcome lifecycle installs after original load");
    Check(Actions==beforeStartupActions,@"startup and welcome rendering invoke no admission or creation action");
    self.screens=@[[HomeViewController new],[_Xc9m new],[LocSimViewController new],[ProxyViewController new],[SettingsViewController new]];
    NSArray *names=@[@"Home",@"Containers",@"LocSim",@"Proxy",@"Settings"],*icons=@[@"house",@"square.stack.3d.up",@"location",@"network",@"gearshape"];
    NSMutableArray *navigation=[NSMutableArray array];
    for(NSUInteger i=0;i<self.screens.count;i++){LBXFixtureScreen *s=self.screens[i];s.title=names[i];UINavigationController *n=[[UINavigationController alloc] initWithRootViewController:s];n.tabBarItem=[[UITabBarItem alloc] initWithTitle:names[i] image:[UIImage systemImageNamed:icons[i]] tag:i];[navigation addObject:n];}
    self.tabs=[UITabBarController new];self.tabs.viewControllers=navigation;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.window.rootViewController=self.tabs;[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self exerciseImportAlert];});return YES;
}
- (void)exerciseNativeAccent {
    NSUInteger beforeCalls=NativeAccentCalls,beforeHooks=HookCount;
    Check(ExactBlue([_Xth1 primaryColor],UITraitCollection.currentTraitCollection),@"recovered native primary accent getter returns exact #007AFF");
    Check(NativeAccentCalls==beforeCalls,@"supported native accent avoids recreating the original orange");
    Check([[_Xth1 destructiveColor] isEqual:UIColor.systemRedColor],@"native destructive semantic color remains intact");
    Check(ExactBlue(UIColor.systemOrangeColor,UITraitCollection.currentTraitCollection),@"native manager caller of system orange receives exact brand blue");
    NSInvocation *foreign=[NSInvocation invocationWithMethodSignature:[UIColor methodSignatureForSelector:@selector(systemOrangeColor)]];foreign.target=UIColor.class;foreign.selector=@selector(systemOrangeColor);[foreign invoke];
    __unsafe_unretained UIColor *foreignColor=nil;[foreign getReturnValue:&foreignColor];
    Check([foreignColor isEqual:SystemOrangeBeforeHook],@"Foundation-origin color invocation forwards original system color result");
    NSArray *rgbInputs=@[@[@1,@.4,@0,@1],@[@1,@.584,@0,@.35],@[@.85,@.35,@.15,@.7]];
    for(NSArray<NSNumber *> *input in rgbInputs) {
        CGFloat inputRed=input[0].doubleValue,inputGreen=input[1].doubleValue,inputBlue=input[2].doubleValue,inputAlpha=input[3].doubleValue;
        UIColor *mapped=[UIColor colorWithRed:inputRed green:inputGreen blue:inputBlue alpha:inputAlpha];CGFloat r=0,g=0,b=0,a=0;[mapped getRed:&r green:&g blue:&b alpha:&a];
        Check(r==0&&fabs(g-122.0/255.0)<.00001&&b==1&&fabs(a-inputAlpha)<.00001,@"observed native orange RGB becomes brand blue with exact original alpha");
        NSInvocation *other=[NSInvocation invocationWithMethodSignature:[UIColor methodSignatureForSelector:@selector(colorWithRed:green:blue:alpha:)]];other.target=UIColor.class;other.selector=@selector(colorWithRed:green:blue:alpha:);[other setArgument:&inputRed atIndex:2];[other setArgument:&inputGreen atIndex:3];[other setArgument:&inputBlue atIndex:4];[other setArgument:&inputAlpha atIndex:5];[other invoke];__unsafe_unretained UIColor *unchanged=nil;[other getReturnValue:&unchanged];[unchanged getRed:&r green:&g blue:&b alpha:&a];
        Check(fabs(r-inputRed)<.00001&&fabs(g-inputGreen)<.00001&&fabs(b-inputBlue)<.00001&&fabs(a-inputAlpha)<.00001,@"Foundation-origin RGB invocation forwards exact original RGBA");
    }
    UIColor *other=[UIColor colorWithRed:.92 green:.1 blue:.15 alpha:.6];CGFloat otherRed=0,otherGreen=0,otherBlue=0,otherAlpha=0;[other getRed:&otherRed green:&otherGreen blue:&otherBlue alpha:&otherAlpha];
    Check(fabs(otherRed-.92)<.00001&&fabs(otherGreen-.1)<.00001&&fabs(otherBlue-.15)<.00001&&fabs(otherAlpha-.6)<.00001,@"unmatched native semantic RGB retains exact original RGBA");
    Check(LBXDisplayCopyInstallNativeAccent()&&HookCount==beforeHooks,@"native accent hook installation is idempotent");
    LBXPresentationFixtureMetadata(@{});
    UIColor *original=[_Xth1 primaryColor];CGFloat red=0,green=0,blue=0,alpha=0;[original getRed:&red green:&green blue:&blue alpha:&alpha];
    Check(red==1&&fabs(green-.4)<.00001&&blue==0&&alpha==1&&NativeAccentCalls==beforeCalls+1,@"runtime host mismatch forwards exact original native accent getter");
    Check([UIColor.systemOrangeColor isEqual:SystemOrangeBeforeHook],@"runtime host mismatch forwards exact original system orange result");
    LBXPresentationFixtureMetadata(Metadata());
    Check(ExactBlue([_Xth1 primaryColor],UITraitCollection.currentTraitCollection),@"restoring supported metadata restores native brand accent");
}
- (void)exerciseImportAlert {
    self.tabs.selectedIndex=1;_Xc9m *containers=(id)self.screens[1];[containers loadViewIfNeeded];[self.window layoutIfNeeded];
    NSString *message=@"No .socialbox or .socialboxpack files found. Drop yours into 'On My iPhone → Downloads', 'On My iPhone → SocialBox' (any folder), or the SocialBoxInbox — the picker scans all of those.";
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"No Files Found" message:message preferredStyle:UIAlertControllerStyleAlert];
    __block NSUInteger actionCalls=0,completionCalls=0;
    UIAlertAction *original=[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){actionCalls++;}];
    UIAlertAction *cancel=[UIAlertAction actionWithTitle:@"my SocialBox.socialbox" style:UIAlertActionStyleCancel handler:nil];cancel.enabled=NO;
    [alert addAction:original];[alert addAction:cancel];alert.preferredAction=original;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=@"private-SocialBox-key";field.secureTextEntry=YES;field.delegate=(id)self;}];
    UITextField *field=alert.textFields.firstObject;NSUInteger operations=Actions;
    [containers presentViewController:alert animated:NO completion:^{
        completionCalls++;
        Check(completionCalls==1,@"scoped alert hook forwards original presentation completion exactly once");
        Check([alert.message isEqual:@"No importable container archives found. Save an archive to Downloads in Files, then try again."],@"installed presentation hook maps exact empty import regression");
        Check(alert.actions.count==2&&alert.actions[0]==original&&alert.actions[1]==cancel&&alert.preferredAction==original,@"installed alert hook retains exact action objects and preferred action");
        Check(original.style==UIAlertActionStyleDefault&&cancel.style==UIAlertActionStyleCancel&&!cancel.enabled&&alert.preferredStyle==UIAlertControllerStyleAlert,@"installed alert hook preserves styles and enabled flags");
        Check(alert.textFields.firstObject==field&&field.delegate==(id)self&&field.secureTextEntry&&[field.text isEqual:@"private-SocialBox-key"],@"installed alert hook preserves text-field object delegate and private contents");
        Check(actionCalls==0&&Actions==operations&&[cancel.title isEqual:@"my SocialBox.socialbox"],@"presenting mapped alert invokes no handler or operation and leaves user title exact");
        [containers dismissViewControllerAnimated:NO completion:^{[self exerciseSwitchAlert:0];}];
    }];
}
- (void)exerciseSwitchAlert:(NSUInteger)index {
    _Xc9m *containers=(id)self.screens[1];
    AwaitUI(^BOOL{return containers.presentedViewController==nil && containers.view.window!=nil;},50,0,^(BOOL ready){
        Check(ready,@"switch popup fixture waits for original alert to detach");
        if(index==2) {
#if defined(LBX_ALERT_TINT_FIXTURE)
            [self exerciseNativeDialog:0];
#else
            [self exerciseDiagnosticAlert:0];
#endif
            return;
        }
        UIColor *windowTint=self.window.tintColor,*ownerTint=containers.view.tintColor;
        self.window.tintColor=UIColor.orangeColor;containers.view.tintColor=UIColor.orangeColor;
        NSString *message=@"Switch to my SocialBox-private profile?";
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Switch Container" message:message preferredStyle:UIAlertControllerStyleAlert];
        // The native switch path uses Default, never Destructive, for Switch.
        __block NSUInteger handlers=0,completions=0;
        UIAlertAction *switchAction=[UIAlertAction actionWithTitle:@"Switch" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){handlers++;}];
        UIAlertAction *cancel=[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){handlers++;}];
        UIAlertAction *remove=[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){handlers++;}];
        UIAlertAction *disabled=[UIAlertAction actionWithTitle:@"Unavailable" style:UIAlertActionStyleDefault handler:nil];disabled.enabled=NO;
        for(UIAlertAction *action in @[switchAction,cancel,remove,disabled])[alert addAction:action];
        alert.preferredAction=switchAction;
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=@"private-SocialBox-key";field.secureTextEntry=YES;field.delegate=(id)self;}];
        UITextField *field=alert.textFields.firstObject;NSUInteger operations=Actions;
        alert.view.tintColor=UIColor.orangeColor;LegacyResetAlertTint=YES;
        void(^originalCompletion)(void)=index==0?^{
            completions++;
            Check(ExactBlue(alert.view.tintColor,alert.traitCollection),@"original switch presentation completion observes exact brand blue");
            // A completion is also allowed to restore a legacy appearance.
            alert.view.tintColor=UIColor.orangeColor;
        }:nil;
        [containers presentViewController:alert animated:index==0 completion:originalCompletion];
        LegacyResetAlertTint=NO;
        Check(ExactBlue(alert.view.tintColor,alert.traitCollection),@"switch popup reapplies blue after original presenter resets orange");
        AwaitUI(^BOOL{return alert.view.window!=nil && !alert.isBeingPresented && AlertLabel(alert,@"Switch")!=nil;},70,0,^(BOOL displayed){
            Check(displayed,@"switch popup reaches actual displayed UIKit actions");
            Check(completions==(index==0?1:0),@"switch popup keeps original completion count including nil completion");
            Check(ExactBlue(alert.view.tintColor,alert.traitCollection),@"switch popup stays exact brand blue after presentation and original completion");
            UILabel *switchLabel=AlertLabel(alert,@"Switch"),*cancelLabel=AlertLabel(alert,@"Cancel"),*deleteLabel=AlertLabel(alert,@"Delete");
            Check(AlertContrastLabel(switchLabel),@"rendered Switch retains UIKit blue action text or white capsule contrast");
            Check(AlertContrastLabel(cancelLabel),@"rendered Cancel retains UIKit blue or white semantic text");
            Check(AlertColorPixels(alert,YES)>200,@"actual popup rendering contains exact #007AFF action tint pixels");
            // UIKit may render semantic foreground through a vibrancy mask;
            // inspect actual pixels rather than its white backing UILabel.
            Check(deleteLabel && AlertColorPixels(alert,NO)>100,@"actual destructive action rendering retains UIKit semantic red");
            Check(alert.actions.count==4 && alert.actions[0]==switchAction && alert.actions[1]==cancel && alert.actions[2]==remove && alert.actions[3]==disabled && alert.preferredAction==switchAction,@"switch tint keeps every original action object order and preferred action");
            Check(switchAction.style==UIAlertActionStyleDefault && cancel.style==UIAlertActionStyleCancel && remove.style==UIAlertActionStyleDestructive && !disabled.enabled,@"switch tint retains original normal cancel destructive and disabled semantics");
            Check([alert.message isEqual:message] && [switchAction.title isEqual:@"Switch"] && alert.textFields.firstObject==field && field.delegate==(id)self && field.secureTextEntry && [field.text isEqual:@"private-SocialBox-key"],@"switch tint preserves user profile name action title and original private field");
            Check(handlers==0 && Actions==operations,@"styling switch popup invokes no original action or container operation");
            UIViewController *ordinary=[UIViewController new];ordinary.view.tintColor=UIColor.orangeColor;LBXDisplayCopyAlertTint(ordinary);
            Check([ordinary.view.tintColor isEqual:UIColor.orangeColor],@"alert tint leaves non-alert presentation unchanged");
            if(index==0)Save(self.window,@"switch-popup-blue.png");
            [containers dismissViewControllerAnimated:NO completion:^{
                self.window.tintColor=windowTint;containers.view.tintColor=ownerTint;
                [self exerciseSwitchAlert:index+1];
            }];
        });
    });
}
- (void)exerciseNativeDialog:(NSUInteger)index {
    if(index==4) {
#if defined(LBX_ALERT_TINT_FIXTURE)
        NSDictionary *result=@{@"ok":@(Failures.count==0),@"assertions":@(Checks),@"failures":Failures,@"scope":@"Actual presentation/native accent hook: Switch, Create count and Add Proxy/HTTP/SOCKS5 dialogs with inert hosts; no creation, switch, proxy save or phone operation"};
        [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[Directory stringByAppendingPathComponent:@"presentation-result.json"] atomically:YES];
#endif
        return;
    }
    self.tabs.selectedIndex=index?2:1;
    LBXFixtureScreen *owner=self.screens[index?2:1];[owner loadViewIfNeeded];[self.window layoutIfNeeded];
    AwaitUI(^BOOL{return !owner.presentedViewController&&owner.view.window!=nil;},50,0,^(BOOL ready){
        Check(ready,@"native creation/proxy popup waits for visible original owner");if(!ready){[self exerciseNativeDialog:index+1];return;}
        NSArray *titles=@[@"Create containers",@"Add Proxy",@"Add HTTP/HTTPS Proxy",@"Add SOCKS5 Proxy"];
        NSArray *names=@[@"create-count-popup-blue.png",@"add-proxy-menu-blue.png",@"http-proxy-popup-blue.png",@"socks5-proxy-popup-blue.png"];
        BOOL sheet=index==1;
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:titles[index] message:index?@"Synthetic original proxy details":@"How many containers?" preferredStyle:sheet?UIAlertControllerStyleActionSheet:UIAlertControllerStyleAlert];
        __block NSUInteger handlers=0,completions=0;
        NSArray *actionTitles=sheet?@[@"SOCKS5",@"HTTP/HTTPS",@"Bulk Import",@"Cancel"]:@[index==0?@"Create":@"Add",@"Cancel"];
        NSMutableArray<UIAlertAction *> *actions=[NSMutableArray array];
        for(NSString *title in actionTitles) {UIAlertAction *action=[UIAlertAction actionWithTitle:title style:[title isEqual:@"Cancel"]?UIAlertActionStyleCancel:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *item){handlers++;}];[actions addObject:action];[alert addAction:action];}
        if(!sheet)for(NSUInteger fieldIndex=0;fieldIndex<(index==0?1:5);fieldIndex++)[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.text=[NSString stringWithFormat:@"saved value %lu",(unsigned long)fieldIndex];field.delegate=(id)self;field.secureTextEntry=fieldIndex==3;field.tintColor=[_Xth1 primaryColor];}];
        NSArray *fields=[alert.textFields copy]?:@[];NSUInteger operations=Actions;
        // Reproduce the native theme being applied by the caller after the
        // presentation hook has returned; root-view tint alone cannot catch it.
        [owner presentViewController:alert animated:YES completion:^{completions++;}];
        alert.view.tintColor=[_Xth1 primaryColor];
        Check(ExactBlue(alert.view.tintColor,alert.traitCollection),@"native caller applying its theme after presentation remains brand blue");
        AwaitUI(^BOOL{return alert.view.window!=nil&&!alert.isBeingPresented&&AlertLabel(alert,actions.firstObject.title)!=nil;},70,0,^(BOOL shown){
            Check(shown&&completions==1,@"native Create/Add Proxy/HTTP/SOCKS5 popup renders and forwards one completion");
            for(UIAlertAction *action in actions)Check(AlertContrastLabel(AlertLabel(alert,action.title)),@"native creation/proxy action renders blue or UIKit white capsule contrast");
            Check(AlertColorPixels(alert,2)==0,@"native creation/proxy popup renders no orange pixels");
            Check([alert.actions isEqual:actions]&&[alert.textFields?:@[] isEqual:fields],@"creation/proxy popup retains exact original actions and input objects");
            for(NSUInteger fieldIndex=0;fieldIndex<fields.count;fieldIndex++){UITextField *field=fields[fieldIndex];Check([field.text isEqual:[NSString stringWithFormat:@"saved value %lu",(unsigned long)fieldIndex]]&&field.delegate==(id)self&&field.secureTextEntry==(fieldIndex==3),@"creation/proxy input text delegate and privacy remain exact");}
            Check(handlers==0&&Actions==operations,@"blue native creation/proxy styling invokes no original operation");
            Save(self.window,names[index]);
            [owner dismissViewControllerAnimated:NO completion:^{[self exerciseNativeDialog:index+1];}];
        });
    });
}
- (void)exerciseDiagnosticAlert:(NSUInteger)index {
    if(index==2) {
        _Xm8u *license=[_Xm8u new];[license loadViewIfNeeded];NSString *message=@"SocialBox license error password=synthetic-private";
        NSUInteger before=DiagnosticCalls;[license showError:message];
        Check(DiagnosticCalls==before+1&&DiagnosticArgument==message&&[license.errorLabel.text isEqual:message],@"license error entrypoint retains exact original argument and label update");
        Check(!VisibleText(Workspace(license),message),@"license diagnostic label never exposes original raw failure");
        self.window.rootViewController=self.tabs;[self.window layoutIfNeeded];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self exercise];});return;
    }
    LBXFixtureScreen *screen=index==0?[CloudViewController new]:[CloudPushViewController new];
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:screen];[screen loadViewIfNeeded];[self.window layoutIfNeeded];
    NSString *message=@"SocialBox request failed password=synthetic-private";
    DiagnosticNested=index==0;NSUInteger before=DiagnosticCalls,completions=DiagnosticCompletions,handlers=DiagnosticHandlers,operations=Actions;
    DiagnosticPresented=^{
        Check(DiagnosticCalls==before+(index==0?2:1)&&DiagnosticArgument==message,@"reviewed diagnostic wrapper preserves original calls and object argument, including nesting");
        Check([DiagnosticAlert.message hasPrefix:@"The operation could not be completed. Reference: SB-"]&&![DiagnosticAlert.message containsString:@"synthetic-private"]&&![DiagnosticAlert.message containsString:@"SocialBox"],@"reviewed cloud diagnostic presents neutral reference without raw branding or credentials");
        Check(DiagnosticAlert.view.window!=nil&&DiagnosticCompletions==completions+1,@"diagnostic preserves real presentation and exactly one completion");
        Check(DiagnosticAlert.actions.firstObject==DiagnosticAction&&DiagnosticAlert.preferredAction==DiagnosticAction&&DiagnosticAlert.textFields.firstObject==DiagnosticField&&DiagnosticField.secureTextEntry&&[DiagnosticField.text isEqual:@"untouched-SocialBox-private-field"],@"diagnostic mapping preserves original action and field objects and private input");
        Check(DiagnosticHandlers==handlers&&Actions==operations,@"diagnostic presentation invokes no handler or backend operation");
        [screen dismissViewControllerAnimated:NO completion:^{
            DiagnosticThrow=YES;BOOL caught=NO;@try{[screen showError:message];}@catch(__unused NSException *exception){caught=YES;}@finally{DiagnosticThrow=NO;}
            Check(caught,@"diagnostic wrapper preserves original exception propagation");
            NSString *confirmation=@"Delete user archive SocialBox-private.socialbox?";
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Error" message:confirmation preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [screen presentViewController:alert animated:NO completion:^{
                Check([alert.message isEqual:confirmation],@"diagnostic context clears after return and exception; same-title confirmation keeps user filename unchanged");
                [screen dismissViewControllerAnimated:NO completion:^{[self exerciseDiagnosticAlert:index+1];}];
            }];
        }];
    };
    // A new root must finish entering the window before invoking the original
    // error entrypoint. The decisive checks run from UIKit's real completion.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.1*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[screen showError:message];});
}
- (void)exercise {
    NSArray *navigation=[self.tabs.viewControllers copy];
    for(NSUInteger i=0;i<self.screens.count;i++) {
        LBXFixtureScreen *s=self.screens[i];self.tabs.selectedIndex=i;[s loadViewIfNeeded];[self.window layoutIfNeeded];
        NSArray *targets=[s.originalButton actionsForTarget:s forControlEvent:UIControlEventTouchUpInside];NSArray *barItems=[s.navigationItem.rightBarButtonItems copy];
        NSString *value=[s.originalField.text copy],*label=[s.originalLabel.text copy];BOOL on=s.originalSwitch.on;
        CALayer *mesh=s.meshGradientLayer;NSArray *oldChildren=[s.contentStack.arrangedSubviews copy];id delegate=s.tableView.delegate,idSource=s.tableView.dataSource;
        UIColor *semantic=s.statusCard.backgroundColor;CGColorRef border=CGColorRetain(s.statusCard.layer.borderColor);
        NSUInteger count=s.appearances;[s viewWillAppear:NO];Check(s.appearances==count+1,@"original lifecycle called exactly once");
        for(NSUInteger j=0;j<5;j++)LBXPresentationApplyFixture(s);
        Check([s.originalField.text isEqual:value]&&[s.originalLabel.text isEqual:label],@"original field values and labels unchanged");
        Check(s.originalSwitch.on==on,@"original switch state preserved");
        Check([[s.originalButton actionsForTarget:s forControlEvent:UIControlEventTouchUpInside] isEqual:targets],@"original button action preserved");
        NSUInteger old=Actions;[s.originalButton sendActionsForControlEvents:UIControlEventTouchUpInside];Check(Actions==old+1,@"original action still runs once");
        Check(s.meshGradientLayer==mesh&&[s.contentStack.arrangedSubviews isEqual:oldChildren],@"original mesh and card membership retained");
        Check(s.tableView.delegate==delegate&&s.tableView.dataSource==idSource,@"original table delegate/data source retained");
        Check([s.statusCard.backgroundColor isEqual:semantic]&&CGColorEqualToColor(s.statusCard.layer.borderColor,border),@"semantic background and border colors retained");CGColorRelease(border);
        Check([s.navigationItem.rightBarButtonItems isEqual:barItems],@"navigation augmentation idempotent");
        Check(s.loads==1,@"original load executes once");
        if(i!=2)Check(![s.view.backgroundColor isEqual:UIColor.blackColor],@"supported screen receives dark palette");
        else Check(Workspace(s)!=nil&&s.mapView.delegate==nil,@"location has owned workspace while original map delegate remains unchanged");
    }
    Check([self.tabs.viewControllers isEqual:navigation],@"five original navigation roots and order preserved");
    for(NSUInteger i=0;i<5;i++)Check(self.tabs.viewControllers[i].tabBarItem.tag==(NSInteger)i,@"tab identity preserved");
    _Xc9m *containers=(id)self.screens[1];Check([containers tableView:containers.tableView numberOfRowsInSection:0]==40,@"40 container rows preserved");[containers tableView:containers.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:39 inSection:0]];Check(containers.selectedContainer==39,@"last container original selection handler retained");
    UIViewController *unknown=[UIViewController new];unknown.view.backgroundColor=UIColor.magentaColor;LBXPresentationApplyFixture(unknown);Check([unknown.view.backgroundColor isEqual:UIColor.magentaColor],@"unknown controller unchanged");
    DerivedHome *derived=[DerivedHome new];[derived loadViewIfNeeded];Check([derived.view.backgroundColor isEqual:UIColor.blackColor],@"unknown subclass not themed by inherited hook");
    HomeViewController *home=(id)self.screens[0];Check(Workspace(home)!=nil&&home.navigationItem.titleView==nil,@"known inert logo replaced by source-owned workspace heading");
    UIButton *interactive=[UIButton buttonWithType:UIButtonTypeSystem];[interactive setTitle:@"Keep action" forState:0];home.navigationItem.titleView=interactive;LBXPresentationApplyFixture(home);Check(home.navigationItem.titleView==interactive,@"interactive custom title remains unchanged");home.navigationItem.titleView=home.logoView;LBXPresentationApplyFixture(home);
    UIView *before=home.view;UIColor *color=before.backgroundColor;NSMutableDictionary *wrong=[Metadata() mutableCopy];wrong[@"CFBundleShortVersionString"]=@"future";LBXPresentationFixtureMetadata(wrong);home.view.backgroundColor=UIColor.purpleColor;LBXPresentationApplyFixture(home);Check([home.view.backgroundColor isEqual:UIColor.purpleColor],@"runtime metadata mismatch performs no theme mutation");LBXPresentationFixtureMetadata(Metadata());home.view.backgroundColor=color;
    CALayer *validMesh=home.meshGradientLayer;UIColor *validBackground=home.view.backgroundColor;home.meshGradientLayer=(id)@1;home.view.backgroundColor=UIColor.purpleColor;LBXPresentationApplyFixture(home);
    Check([home.view.backgroundColor isEqual:UIColor.purpleColor],@"wrong runtime getter value causes no screen mutation");home.meshGradientLayer=(id)validMesh;home.view.backgroundColor=validBackground;
    SettingsViewController *settings=(id)self.screens[4];NSArray *buttons=settings.navigationItem.rightBarButtonItems;Check(buttons.count==1,@"Settings exposes only owned navigation action");UIBarButtonItem *checks=buttons.firstObject;Check([checks.accessibilityIdentifier isEqual:@"socialbox.isolation-checks"]&&![checks.title isEqual:@"Original"],@"Settings removes inherited promotion/navigation item");NSUInteger old=Actions;[settings.originalButton sendActionsForControlEvents:UIControlEventTouchUpInside];Check(Actions==old+1,@"retained original Settings control handler remains intact");
    self.tabs.selectedIndex=4;Invoke(checks);Check([settings.navigationController.topViewController isKindOfClass:LBXIsolationViewController.class],@"isolation navigation reaches dynamic class");LBXIsolationViewController *diagnostics=(id)settings.navigationController.topViewController;[diagnostics loadViewIfNeeded];
    Check([diagnostics tableView:diagnostics.tableView numberOfRowsInSection:2]==8,@"actual diagnostics contains all eight runtime checks");
    for(NSInteger row=0;row<8;row++){UITableViewCell *cell=[diagnostics tableView:diagnostics.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:2]];Check([cell.textLabel.text hasPrefix:@"Not run ·"],@"actual runtime check honestly remains Not run");}
    UITableViewCell *selection=[diagnostics tableView:diagnostics.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    Check([selection.detailTextLabel.text containsString:@"Container list unavailable"],@"actual diagnostics distinguishes unavailable metadata from empty list");
    NSDictionary *snapshot=LBXRecoveredContextSnapshot(self.screens[1]);Check([snapshot[@"status"] isEqual:@"UNAVAILABLE"],@"real adapter rejects synthetic bundle without original getter reads");
    NSDictionary *publicReport=LBXIsolationPublicReport(@{@"activeContainerID":@"private",@"name":@"private",@"passphrase":@"private",@"overallStatus":@"PASS"});
    Check(!publicReport[@"activeContainerID"]&&!publicReport[@"name"]&&!publicReport[@"passphrase"]&&[publicReport[@"overallStatus"] isEqual:@"NOT_RUN"],@"actual public report strips private fields and unbound PASS");
    NSUInteger depth=settings.navigationController.viewControllers.count;Invoke(checks);Check(settings.navigationController.viewControllers.count==depth,@"repeated action cannot stack diagnostics");
    Check([LBXPresentationStatus()[@"isolationVerified"] isEqual:@NO],@"presentation never claims isolation evidence");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.8*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        Save(self.window,@"fixture-diagnostics.png");
        UINavigationController *nav=(id)self.tabs.viewControllers[4];
        [nav popToRootViewControllerAnimated:NO];
        Check(nav.topViewController==settings,@"diagnostics returns to original Settings after completed transition");
        [self exerciseDetails];
        [self exerciseModalPicker];
    });
}
- (void)exerciseDetails {
    UINavigationController *nav=(id)self.tabs.viewControllers[0];self.tabs.selectedIndex=0;
    for (NSString *name in @[@"FakeInfoViewController",@"CountryPickerViewController",@"CarrierPickerViewController",@"BackupsViewController",@"CloudViewController",@"CloudPushViewController",@"TokensDetailViewController",@"BulkProxyImportViewController",@"_Xm8u"]) {
        LBXFixtureScreen *s=[NSClassFromString(name) new];s.title=name;[nav pushViewController:s animated:NO];[s loadViewIfNeeded];[self.window layoutIfNeeded];
        NSString *value=[s.originalField.text copy],*label=[s.originalLabel.text copy];NSArray *rows=[s.contentStack.arrangedSubviews copy];id delegate=s.tableView.delegate;NSArray *items=[s.navigationItem.rightBarButtonItems copy];
        NSUInteger actions=Actions;[s.originalButton sendActionsForControlEvents:UIControlEventTouchUpInside]; // explicit send tests target preservation even if disabled
        Check(Actions==actions+1,[@"original action preserved: " stringByAppendingString:name]);
        for(int i=0;i<4;i++)LBXPresentationApplyFixture(s);
        Check(s.loads==1&&[s.originalField.text isEqual:value]&&[s.originalLabel.text isEqual:label],[@"form values/lifecycle stable: " stringByAppendingString:name]);
        Check([rows isEqual:s.contentStack.arrangedSubviews]&&s.tableView.delegate==delegate&&[items isEqual:s.navigationItem.rightBarButtonItems],[@"form hierarchy and delegates unchanged: " stringByAppendingString:name]);
        Check(Workspace(s)!=nil||ViewID(s.view,@"socialbox.secondary.surface")!=nil||ViewID(s.view,@"socialbox.identity.form")!=nil,[@"owned detail surface rendered: " stringByAppendingString:name]);
        if([name isEqual:@"FakeInfoViewController"]){
            s.originalField.text=@"My edited name";s.modelMode.selectedSegmentIndex=0;NSUInteger count=Actions;[s.modelMode sendActionsForControlEvents:UIControlEventValueChanged];LBXPresentationApplyFixture(s);
            Check(Actions==count+1&&s.modelMode.selectedSegmentIndex==0&&[s.originalField.text isEqual:@"My edited name"],@"configuration editing and range handler survive theming");
            Save(self.window,@"fixture-configuration.png");
        }
        if([name isEqual:@"_Xm8u"]){
            Check([s.originalLabel.text isEqual:@"SocialBox License"]&&!VisibleText(s.view,@"SocialBox License")&&Workspace(s)!=nil,@"original license heading remains private under owned license surface");
            Check(s.originalField.secureTextEntry&&!s.originalButton.enabled&&[s.errorLabel.text isEqual:@"Fixture only · no validation request"]&&[s.errorLabel.textColor isEqual:UIColor.systemRedColor],@"licence field privacy, disabled admission and error remain unchanged");
            s.originalLabel.text=@"User custom heading";LBXPresentationApplyFixture(s);Check([s.originalLabel.text isEqual:@"User custom heading"],@"unexpected licence title never overwritten");
            s.originalLabel.text=@"SocialBox License";s.originalLabel.userInteractionEnabled=YES;LBXPresentationApplyFixture(s);Check([s.originalLabel.text isEqual:@"SocialBox License"],@"interactive licence heading never replaced");
            s.originalLabel.userInteractionEnabled=NO;LBXPresentationApplyFixture(s);Save(self.window,@"fixture-licence.png");
        }
        if([name isEqual:@"CarrierPickerViewController"]){
            UITableViewHeaderFooterView *header=[[UITableViewHeaderFooterView alloc] initWithReuseIdentifier:@"header"];
            NSUInteger headerCount=s.headerDisplays, prematureStyles=s.headerCallbacksSeeingOwnedRow;header.textLabel.text=@"User section name";
            header.frame=CGRectMake(0,0,340,44);[header setNeedsLayout];[header layoutIfNeeded];
            [s.tableView.delegate tableView:s.tableView willDisplayHeaderView:header forSection:0];
            Check(s.headerDisplays==headerCount+1&&s.headerCallbacksSeeingOwnedRow==prematureStyles,@"header presentation calls original delegate exactly once before creating owned drawing");
            UIView *ownedHeader=ViewID(header.contentView,@"socialbox.secondary.row");
            Check(ownedHeader!=nil&&[ownedHeader.backgroundColor isEqual:SBInk()]&&VisibleText(ownedHeader,@"User section name")&&[header.textLabel.text isEqual:@"User section name"]&&header.textLabel.alpha==0,[NSString stringWithFormat:@"owned header: row=%@ ink=%d copied=%d source=%@ alpha=%.2f",ownedHeader,[ownedHeader.backgroundColor isEqual:SBInk()],VisibleText(ownedHeader,@"User section name"),header.textLabel.text,header.textLabel.alpha]);
            [s.tableView.delegate tableView:s.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:13 inSection:0]];Check(s.selectedContainer==13,@"carrier table selection still calls original delegate");Save(self.window,@"fixture-carrier.png");
        }
        UIView *owned=s.tableView.superview;
        if(s.tableView.superview){[s.tableView removeFromSuperview];s.view.backgroundColor=UIColor.magentaColor;LBXPresentationApplyFixture(s);if(![name isEqual:@"FakeInfoViewController"]&&![name isEqual:@"_Xm8u"])Check(SBSecondaryApply(s),@"secondary route remains owned after table moves");[owned addSubview:s.tableView];}
        [nav popViewControllerAnimated:NO];
    }
    for(NSString *name in @[@"ModelPickerViewController",@"VersionPickerViewController",@"DRTAllowedModelsViewController",@"AppListViewController"]){
        LBXFixturePicker *picker=[NSClassFromString(name) new];picker.title=name;[nav pushViewController:picker animated:NO];[self.window layoutIfNeeded];
        id delegate=picker.tableView.delegate,dataSource=picker.tableView.dataSource,searchDelegate=picker.search.delegate;NSString *selected=[picker.selection copy];NSArray *choices=picker.values;UIBarButtonItem *done=picker.navigationItem.rightBarButtonItem;
        LBXPresentationApplyFixture(picker);Check(delegate==picker.tableView.delegate&&dataSource==picker.tableView.dataSource&&searchDelegate==picker.search.delegate&&done==picker.navigationItem.rightBarButtonItem,@"picker action and delegates remain original");
        Check([selected isEqual:picker.selection]&&choices==picker.values&&picker.loads==1,@"picker options and stored selection unchanged");
        [picker.tableView.delegate tableView:picker.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];LBXPresentationApplyFixture(picker);Check([picker.selection isEqual:choices[2]]&&picker.choices==1,@"picker original choice commits exactly once");
        picker.search.text=@"match";[picker.search.delegate searchBar:picker.search textDidChange:picker.search.text];[self.window layoutIfNeeded];LBXPresentationApplyFixture(picker);Check([picker.tableView numberOfRowsInSection:0]==1&&[picker.search.text isEqual:@"match"],@"picker search still filters original data source");
        if([name isEqual:@"ModelPickerViewController"])Save(self.window,@"fixture-model.png");
        if([name isEqual:@"VersionPickerViewController"])Save(self.window,@"fixture-version.png");
        [nav popViewControllerAnimated:NO];
    }
    // Optional incompatible object never poisons the established shell.
    FakeInfoViewController *bad=[FakeInfoViewController new];[bad loadViewIfNeeded];bad.contentStack=(id)@1;bad.view.backgroundColor=UIColor.magentaColor;LBXPresentationApplyFixture(bad);
    Check(Workspace(bad)||ViewID(bad.view,@"socialbox.unavailable")||ViewID(bad.view,@"socialbox.identity.form"),@"configuration keeps owned surface for incompatible getter");
    Check([LBXPresentationStatus()[@"installed"] boolValue],@"detail incompatibility leaves established shell installed");
    // Same ABI is insufficient: reject a foreign-image implementation before
    // invoking it on the wrong receiver. This executes the production guard.
    SEL tableSelector=@selector(tableView);Method oldGetter=class_getInstanceMethod(CarrierPickerViewController.class,tableSelector);
    IMP originalGetter=method_getImplementation(oldGetter);const char *getterTypes=method_getTypeEncoding(oldGetter);
    IMP foreign=method_getImplementation(class_getInstanceMethod(UIView.class,@selector(layer)));
    class_addMethod(CarrierPickerViewController.class,tableSelector,foreign,getterTypes);
    CarrierPickerViewController *foreignScreen=[CarrierPickerViewController new];foreignScreen.view=[UIView new];foreignScreen.view.backgroundColor=UIColor.magentaColor;
    LBXPresentationApplyFixture(foreignScreen);Check(ViewID(foreignScreen.view,@"socialbox.secondary.unavailable")!=nil,@"foreign-image same-signature getter rejected into owned unavailable surface before invocation");
    class_replaceMethod(CarrierPickerViewController.class,tableSelector,originalGetter,getterTypes);
}
- (void)exerciseModalPicker {
    UINavigationController *nav=(id)self.tabs.viewControllers[0];UIViewController *home=nav.topViewController;
    AwaitUI(^BOOL{
        [self.window layoutIfNeeded];return UIApplication.sharedApplication.applicationState==UIApplicationStateActive&&self.window.isKeyWindow&&self.tabs.selectedViewController==nav&&home.view.window==self.window&&!self.tabs.transitionCoordinator&&!nav.transitionCoordinator&&!self.tabs.presentedViewController;
    },120,0,^(BOOL ready){
    Check(ready,@"modal picker waits for visible Home after fixture navigation");if(!ready){[self finish];return;}
    // The same known picker works as a sheet without taking over its presenter.
    ModelPickerViewController *sheet=[ModelPickerViewController new];sheet.title=@"Choose device model";UINavigationController *sheetNav=[[UINavigationController alloc] initWithRootViewController:sheet];sheetNav.modalPresentationStyle=UIModalPresentationPageSheet;
    [home presentViewController:sheetNav animated:NO completion:^{
    [sheet loadViewIfNeeded];[self.window layoutIfNeeded];LBXPresentationApplyFixture(sheet);
    Check((nav.presentedViewController==sheetNav||home.presentedViewController==sheetNav)&&sheet.view.window==self.window,@"original modal presentation remains visibly intact");
    NSUInteger count=Actions;Invoke(sheet.navigationItem.rightBarButtonItem);Check(Actions==count+1,@"sheet Done calls original dismissal action exactly once");
    AwaitUI(^BOOL{return !self.tabs.presentedViewController&&!nav.presentedViewController&&!home.presentedViewController&&!sheetNav.presentingViewController&&!nav.transitionCoordinator;},120,0,^(BOOL dismissed){
        Check(dismissed,@"original picker dismissal detaches before next fixture action");if(!dismissed){[self finish];return;}
        [self exerciseProxyInput];[self exerciseProxyInputDismissal];
    });
    }];
    });
}
- (void)exerciseProxyInput {
    ProxyAdded=[NSMutableArray array];ProxyOriginalInputs=[NSMutableArray array];
    NSUInteger hooks=HookCount;
    Check(!LBXInstallProxyInputFixture(@{})&&HookCount==hooks,@"proxy hook rejects unknown host before changing method");
    Check(LBXInstallProxyInputFixture(Metadata())&&HookCount==hooks+1,@"actual proxy input hook installed on reviewed method");
    Check(LBXInstallProxyInputFixture(Metadata())&&HookCount==hooks+1,@"proxy hook does not stack on repeated install");
    ProxyViewController *proxy=(id)self.screens[3];
    [proxy importFromInput:@"http://user:p%3Ass@proxy.example:8080"];
    Check(ProxyAdded.count==1&&ProxyOriginalInputs.count==0,@"real hook sends HTTP proxy to typed add, never subscription handler");
    Check([ProxyAdded.lastObject[@"password"] isEqual:@"p:ss"]&&![ProxyAdded.lastObject[@"tls"] boolValue],@"real hook preserves HTTP decoded credentials");
    [proxy importFromInput:@"https://user:secret@proxy.example:8443"];
    Check(ProxyAdded.count==2&&[ProxyAdded.lastObject[@"tls"] boolValue],@"real hook preserves HTTPS transport flag");
    [proxy importFromInput:@"https://subscriptions.example/list?token=fixture"];
    Check(ProxyOriginalInputs.count==1&&ProxyAdded.count==2,@"real hook delegates original subscription exactly once");
    [proxy importFromInput:@"http://proxy.example:bad"];
    Check(ProxyOriginalInputs.count==1&&ProxyAdded.count==2,@"malformed recognized URL never reaches original downloader or add");
    Method method=class_getInstanceMethod(ProxyViewController.class,NSSelectorFromString(@"addHTTPProxyWithHost:port:user:password:title:tls:"));
    IMP original=method_getImplementation(method),foreign=class_getMethodImplementation(NSObject.class,@selector(description));
    method_setImplementation(method,foreign);
    Check(!LBXDispatchProxyInput(proxy,LBXPlanProxyInput(@"SOCKS5 p.example:1080\nHTTPS p.example:443"),nil)&&ProxyAdded.count==2,@"foreign add-method image rejects entire mixed batch before first add");
    method_setImplementation(method,original);
    [proxy importFromInput:@"SOCKS5 p.example:1080\nHTTP p.example:80"];
    Check(ProxyAdded.count==4&&[ProxyAdded[2][@"kind"] isEqual:@"socks5"]&&[ProxyAdded[3][@"kind"] isEqual:@"http"],@"hook mixed list preserves order and protocol");
    Check([LBXPresentationStatus()[@"isolationVerified"] isEqual:@NO],@"proxy import never upgrades isolation evidence");
}
- (void)capture:(NSUInteger)index {
    self.tabs.selectedIndex=index;[self.window layoutIfNeeded];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        Save(self.window,[@[@"fixture-home.png",@"fixture-containers.png",@"fixture-location.png",@"fixture-proxy.png",@"fixture-settings.png"] objectAtIndex:index]);
        if(index<4){[self capture:index+1];return;}
        [self captureDetail:0];

    });
}
- (void)exerciseProxyInputDismissal {
    self.tabs.selectedIndex=3;
    ProxyViewController *proxy=(id)self.screens[3];
    AwaitUI(^BOOL{
        [self.window layoutIfNeeded];return self.tabs.selectedViewController==proxy.navigationController&&proxy.view.window==self.window&&!self.tabs.transitionCoordinator&&!proxy.navigationController.transitionCoordinator&&!self.tabs.presentedViewController;
    },120,0,^(BOOL ready){
        Check(ready,@"proxy dismissal test starts only with visible proxy and no prior modal");if(!ready){[self finish];return;}
        UIAlertController *input=[UIAlertController alertControllerWithTitle:@"Fixture input" message:@"Synthetic dismissal timing test" preferredStyle:UIAlertControllerStyleAlert];
        [input addAction:[UIAlertAction actionWithTitle:@"Import" style:UIAlertActionStyleDefault handler:nil]];
        [proxy presentViewController:input animated:NO completion:^{
            NSUInteger before=ProxyAdded.count,oldInputs=ProxyOriginalInputs.count;
            [proxy dismissViewControllerAnimated:YES completion:nil];
            [proxy importFromInput:@"http://user:fixture-secret@proxy.example:bad"];
            AwaitUI(^BOOL{
                UIAlertController *issue=(id)proxy.presentedViewController;
                return [issue isKindOfClass:UIAlertController.class]&&[issue.title isEqual:@"Check proxy input"]&&issue.view.window==self.window&&!issue.transitionCoordinator;
            },120,0,^(BOOL shown){
                UIAlertController *issue=(id)proxy.presentedViewController;
                Check(shown,@"invalid proxy error survives dismissing input alert");
                Check(ProxyAdded.count==before&&ProxyOriginalInputs.count==oldInputs,@"dismissing-alert error triggers neither add nor subscription fetch");
                if([issue isKindOfClass:UIAlertController.class])Check(![issue.message containsString:@"fixture-secret"]&&! [issue.message containsString:@"proxy.example"],@"visible proxy error never reveals credentials");
                if(!shown){[self finish];return;}
                [proxy dismissViewControllerAnimated:NO completion:^{
                    AwaitUI(^BOOL{return !proxy.presentedViewController&&!self.tabs.presentedViewController&&!proxy.transitionCoordinator;},120,0,^(BOOL dismissed){
                        Check(dismissed,@"proxy error detaches before fixture captures");if(!dismissed){[self finish];return;}[self capture:0];
                    });
                }];
            });
        }];
    });
}
- (void)captureDetail:(NSUInteger)index {
    NSArray *classes=@[@"FakeInfoViewController",@"CarrierPickerViewController",@"ModelPickerViewController",@"VersionPickerViewController",@"_Xm8u"];
    NSArray *titles=@[@"Identity settings",@"Select carrier",@"Select model",@"Select iOS version",@"Activation"];
    NSArray *files=@[@"fixture-configuration.png",@"fixture-carrier.png",@"fixture-model.png",@"fixture-version.png",@"fixture-licence.png"];
    self.tabs.selectedIndex=0;UINavigationController *nav=(id)self.tabs.viewControllers[0];[nav popToRootViewControllerAnimated:NO];
    UIViewController *detail=[NSClassFromString(classes[index]) new];detail.title=titles[index];[nav pushViewController:detail animated:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        [self.window layoutIfNeeded];Check(detail.view.window==self.window&&nav.visibleViewController==detail,@"detail screenshot waits for visible original navigation");Save(self.window,files[index]);
        if(index+1<classes.count){[self captureDetail:index+1];return;}
        [nav popToRootViewControllerAnimated:NO];
        [self finish];
    });
}
- (void)finish {
    NSDictionary *result=@{@"ok":@(Failures.count==0),@"assertions":@(Checks),@"failures":Failures,@"scope":@"Synthetic UIKit presentation fixture; not original backend/device/isolation acceptance",@"status":LBXPresentationStatus()};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[Directory stringByAppendingPathComponent:@"presentation-result.json"] atomically:YES];
}

@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(FixtureApp.class));}}
