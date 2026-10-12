// Faithful synthetic UIKit control shapes only. This fixture never loads the
// recovered runtime, generates an identity, or contacts a service.
#import <UIKit/UIKit.h>
#import "SBIdentityForm.h"
#import "SBBackendAdapter.h"
#import "LBXDisplayCopy.h"

static NSUInteger Checks;
static NSMutableArray *Failures;
static void Check(BOOL pass, NSString *name) { Checks++; if(!pass) [Failures addObject:name]; }
static UILabel *Label(NSString *text) { UILabel *label=[UILabel new]; label.text=text; return label; }
static UIStackView *Stack(NSArray *views) { UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views]; stack.axis=UILayoutConstraintAxisVertical; return stack; }
static NSArray *Views(UIView *root, Class kind) { NSMutableArray *result=[NSMutableArray array]; if([root isKindOfClass:kind]) [result addObject:root]; for(UIView *view in root.subviews) [result addObjectsFromArray:Views(view,kind)]; return result; }
static UIView *Find(UIView *root, NSString *identifier) { for(UIView *view in Views(root,UIView.class)) if([view.accessibilityIdentifier isEqual:identifier]) return view; return nil; }
static UIView *Content(UIView *view) { return [view isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)view).contentView : view; }

@interface FakeInfoViewController:UIViewController <UIGestureRecognizerDelegate>
@property(nonatomic,strong) UIStackView *contentStack;
@property(nonatomic,strong) UILabel *countryValueLabel;
@property(nonatomic,strong) NSMutableDictionary *carriers;
@property(nonatomic,strong) UISegmentedControl *mode;
@property(nonatomic,strong) UISwitch *modelLock;
@property(nonatomic,strong) UISwitch *systemLock;
@property(nonatomic,strong) UIButton *regenerate;
@property(nonatomic,strong) UILabel *compatibilityDetail;
@property(nonatomic,strong) id sender;
@property(nonatomic) NSUInteger events;
@property(nonatomic) NSInteger selectedMode;
@property(nonatomic) BOOL blur;
@property(nonatomic) BOOL invalid;
- (void)build;
@end
@implementation FakeInfoViewController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.blackColor;
    self.contentStack=Stack(@[]); [self.view addSubview:self.contentStack]; [self build];
}
- (UIView *)card {
    UIView *card=self.blur ? [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]] : [UIView new];
    card.tag=521; return card;
}
- (UIView *)picker:(NSString *)caption value:(NSString *)value key:(NSString *)key {
    UIView *card=[self card], *content=Content(card);
    UILabel *label=Label(value); [content addSubview:Label(caption)]; [content addSubview:label]; [content addSubview:[UIImageView new]];
    UITapGestureRecognizer *gesture=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pick:)]; gesture.delegate=self;
    [card addGestureRecognizer:gesture]; card.userInteractionEnabled=YES; self.carriers[key]=card;
    if([key isEqual:@"country"]) self.countryValueLabel=label;
    return card;
}
- (UIView *)toggle:(NSString *)caption subtitle:(NSString *)subtitle key:(NSString *)key {
    UIView *card=[self card], *content=Content(card); [content addSubview:Label(caption)]; [content addSubview:Label(subtitle)];
    UISwitch *control=[UISwitch new]; control.on=YES; control.tag=[key isEqual:@"model"] ? 7 : 9;
    [control addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged]; [content addSubview:control];
    if([key isEqual:@"model"]) self.modelLock=control; else self.systemLock=control;
    return card;
}
- (void)build {
    for(UIView *view in self.contentStack.arrangedSubviews.copy) { [self.contentStack removeArrangedSubview:view]; [view removeFromSuperview]; }
    self.carriers=[NSMutableDictionary dictionary];
    UIView *compat=[self card]; [Content(compat) addSubview:Label(@"Compatibility available")]; self.compatibilityDetail=Label(@"Synthetic status, no runtime claim");
    [Content(compat) addSubview:self.compatibilityDetail]; [Content(compat) addSubview:[UIImageView new]]; [self.contentStack addArrangedSubview:compat];
    [self.contentStack addArrangedSubview:Label(@"COUNTRY / REGION")];
    [self.contentStack addArrangedSubview:[self picker:@"COUNTRY" value:@"SocialBox — user's custom value" key:@"country"]];
    [self.contentStack addArrangedSubview:Label(@"Carrier name, MCC/MNC match region.")];
    [self.contentStack addArrangedSubview:Label(@"CARRIER")]; [self.contentStack addArrangedSubview:[self picker:@"PROVIDER" value:@"Random per seed" key:@"carrier"]];
    [self.contentStack addArrangedSubview:Label(@"Lock the carrier across all containers. Leave on 'Random per seed' to let the server pick a carrier from the country pool each time.")];
    [self.contentStack addArrangedSubview:Label(@"APP LANGUAGE")]; [self.contentStack addArrangedSubview:[self picker:@"UI LANGUAGE" value:@"Auto" key:@"language"]];
    [self.contentStack addArrangedSubview:Label(@"Override the application UI language independently of spoof country. `auto` = follow system + country. Does NOT affect spoofed device values.")];
    [self.contentStack addArrangedSubview:Label(@"MODEL")];
    UIView *modeCard=[self card]; self.mode=[[UISegmentedControl alloc] initWithItems:@[@"Range",@"Specific"]]; self.mode.selectedSegmentIndex=self.selectedMode; self.mode.tag=42;
    [self.mode addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged]; [Content(modeCard) addSubview:self.mode]; [self.contentStack addArrangedSubview:modeCard];
    if(self.selectedMode==0) {
        UIStackView *range=Stack(@[[self picker:@"FROM" value:@"iPhone 12" key:@"model.min"],[self picker:@"TO" value:@"iPhone 16" key:@"model.max"]]); range.axis=UILayoutConstraintAxisHorizontal;
        [self.contentStack addArrangedSubview:range]; [self.contentStack addArrangedSubview:Label(@"Fingerprint picks a random model from this range.")];
    } else { [self.contentStack addArrangedSubview:[self picker:@"ALLOWED MODELS" value:@"2 selected" key:@"model.allowed"]]; [self.contentStack addArrangedSubview:Label(@"Fingerprint picks one model from this discrete list. Empty list falls back to Range.")]; }
    [self.contentStack addArrangedSubview:Label(@"IOS VERSION RANGE")];
    [self.contentStack addArrangedSubview:Stack(@[[self picker:@"FROM" value:@"17" key:@"system.min"],[self picker:@"TO" value:@"18" key:@"system.max"]])];
    [self.contentStack addArrangedSubview:Label(@"Server picks a random patch within this range based on your device seed. Use LOCK VALUES below to pin an exact patch.")];
    [self.contentStack addArrangedSubview:Label(@"LOCK VALUES")];
    [self.contentStack addArrangedSubview:[self toggle:@"Lock Device Model" subtitle:@"Keep exact model on regenerate" key:@"model"]];
    [self.contentStack addArrangedSubview:[self picker:@"CURRENT MODEL" value:@"iPhone 15" key:@"current.model"]];
    [self.contentStack addArrangedSubview:[self toggle:@"Lock iOS Version" subtitle:@"Keep exact version on regenerate" key:@"system"]];
    [self.contentStack addArrangedSubview:[self picker:@"CURRENT VERSION" value:@"17.4.1" key:@"current.system"]];
    self.regenerate=[UIButton buttonWithType:UIButtonTypeSystem]; [self.regenerate setTitle:@"Regenerate Identity" forState:UIControlStateNormal]; self.regenerate.tag=63;
    [self.regenerate addTarget:self action:@selector(regenerate:) forControlEvents:UIControlEventTouchUpInside]; [self.contentStack addArrangedSubview:self.regenerate];
    [self.contentStack addArrangedSubview:Label(@"Regenerate re-asks the server using lock/range rules above. Same seed; IDs stay unless the server changes them.")];
    [self.contentStack addArrangedSubview:Label(@"OTHER IDENTIFIERS")];
    UIView *other=[self card]; [Content(other) addSubview:Label(@"Auto-Generated Values")]; [Content(other) addSubview:Label(@"Serial, UDID, MAC, IMEI, Ads ID")]; [self.contentStack addArrangedSubview:other];
    if(self.invalid) [self.contentStack addArrangedSubview:Label(@"Unknown future setting")];
}
- (void)pick:(UITapGestureRecognizer *)sender { self.events++; self.sender=sender; }
- (void)toggle:(UISwitch *)sender { self.events++; self.sender=sender; }
- (void)modeChanged:(UISegmentedControl *)sender { self.events++; self.sender=sender; self.selectedMode=sender.selectedSegmentIndex; [self build]; SBIdentityRefresh(self); }
- (void)regenerate:(UIButton *)sender { self.events++; self.sender=sender; }
@end

static void Screenshot(UIWindow *window, NSString *name) {
    [window layoutIfNeeded]; UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
    UIImage *image=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) { [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES]; }];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [UIImagePNGRepresentation(image) writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES];
}
@interface IdentityFixtureApp:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation IdentityFixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options; Failures=[NSMutableArray array];
    SBBackendFixtureConfigure(@{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"},NSBundle.mainBundle.executablePath);
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    FakeInfoViewController *owner=[FakeInfoViewController new]; self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:owner]; [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/3),dispatch_get_main_queue(),^{ [self test:owner]; }); return YES;
}
- (void)test:(FakeInfoViewController *)owner {
    UIView *country=owner.carriers[@"country"]; UITapGestureRecognizer *gesture=(id)country.gestureRecognizers.firstObject;
    UISwitch *toggle=owner.modelLock; UISegmentedControl *mode=owner.mode; UIButton *button=owner.regenerate;
    Check(SBIdentityApply(owner),@"handles known identity controller"); Check([SBIdentityStatus(owner)[@"available"] boolValue],@"reviewed range layout accepted");
    Check([SBIdentityStatus(owner)[@"fieldCount"] unsignedIntegerValue]==13,@"all 13 range fields represented");
    Check(owner.events==0,@"rendering invokes no native action"); Check(owner.contentStack.hidden,@"original source stack hidden");
    UIView *form=Find(owner.view,@"socialbox.identity.form"); Check(form!=nil && !form.hidden,@"own form is visible");
    Check([Find(owner.view,@"socialbox.identity.scope") isDescendantOfView:form],@"shared current-session scope rendered");
    Check([owner.navigationItem.title isEqual:@"Identity rules"],@"own navigation is English");
    Check([((UILabel *)Find(form,@"socialbox.identity.scope")).text isEqual:@"These rules apply to the shared workspace and current session. They are not separate settings for the selected container."],@"English copy preserves shared scope");
    Check([country isDescendantOfView:form] && country==Find(form,@"socialbox.identity.field.country"),@"same picker carrier moved into own form");
    Check(gesture.view==country && gesture.delegate==owner && country.tag==521,@"picker gesture view delegate and tag retained");
    Check(toggle==Find(form,@"socialbox.identity.control.lock.model") && toggle.tag==7 && toggle.on,@"native switch identity tag and value retained");
    Check(mode==Find(form,@"socialbox.identity.control.model.mode") && mode.tag==42 && mode.selectedSegmentIndex==0,@"native mode identity tag and selection retained");
    Check([[mode titleForSegmentAtIndex:0] isEqual:@"Model range"] && [[mode titleForSegmentAtIndex:1] isEqual:@"Model list"],@"mode labels are English without changing selection");
    Check(button==Find(form,@"socialbox.identity.control.regenerate") && button.tag==63,@"native regeneration sender retained");
    Check([button.currentTitle isEqual:@"Regenerate identity using these rules"],@"native sender has English action title");
    Check([((UILabel *)Find(form,@"socialbox.identity.value.country")).text isEqual:@"SocialBox — user's custom value"],@"user value not rebranded");
    owner.countryValueLabel.text=@"Changed native value";
    Check([((UILabel *)Find(form,@"socialbox.identity.value.country")).text isEqual:@"Changed native value"],@"source value update reflected without rebuild");
    owner.countryValueLabel.attributedText=[[NSAttributedString alloc] initWithString:@"Attributed user value"];
    Check([((UILabel *)Find(form,@"socialbox.identity.value.country")).text isEqual:@"Attributed user value"],@"attributed native value update reflected");
    owner.countryValueLabel.hidden=YES; Check(Find(form,@"socialbox.identity.value.country").hidden,@"value visibility update retained"); owner.countryValueLabel.hidden=NO;
    [toggle setOn:NO animated:NO]; [toggle sendActionsForControlEvents:UIControlEventValueChanged];
    Check(owner.events==1 && owner.sender==toggle && !toggle.on,@"switch dispatch retains original sender and new state");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside]; Check(owner.events==2 && owner.sender==button,@"explicit regeneration dispatch preserves sender");
    [owner pick:gesture]; Check(owner.events==3 && owner.sender==gesture,@"fixture native picker callback retained");
    UIView *sameForm=form; SBIdentityApply(owner); SBIdentityRefresh(owner);
    Check(Find(owner.view,@"socialbox.identity.form")==sameForm && [SBIdentityStatus(owner)[@"available"] boolValue],@"repeated apply and refresh do not reparse moved controls");
    Check(owner.events==3,@"refresh triggers no action"); [self.window layoutIfNeeded];
    UIScrollView *scroll=(id)Views(form,UIScrollView.class).firstObject;
    Check(scroll.contentSize.height>scroll.bounds.size.height,@"own form is scrollable");
    Check(country.bounds.size.height>80 && country.bounds.size.width>250,@"picker own layout has usable geometry");
    Screenshot(self.window,@"identity-top.png"); scroll.contentOffset=CGPointMake(0,MAX(0,scroll.contentSize.height-scroll.bounds.size.height)); Screenshot(self.window,@"identity-bottom.png");
    mode.selectedSegmentIndex=1; [mode sendActionsForControlEvents:UIControlEventValueChanged];
    Check(owner.events==4 && owner.sender==mode,@"model mode action preserves original sender");
    Check([SBIdentityStatus(owner)[@"available"] boolValue] && [SBIdentityStatus(owner)[@"fieldCount"] unsignedIntegerValue]==12,@"native rebuild switches form to discrete-list fields");
    Check(Find(form,@"socialbox.identity.field.model.allowed")!=nil && Find(form,@"socialbox.identity.field.model.min")==nil,@"conditional field membership follows native rebuild");
    Check(Find(form,@"socialbox.identity.control.model.mode")!=mode,@"new native controls replace stale ones after rebuild");
    mode=owner.mode; mode.selectedSegmentIndex=0; [mode sendActionsForControlEvents:UIControlEventValueChanged];
    Check([SBIdentityStatus(owner)[@"available"] boolValue] && Find(form,@"socialbox.identity.field.model.min")!=nil,@"native rebuild returns to range");
    owner.blur=YES; [owner build]; SBIdentityRefresh(owner);
    Check([SBIdentityStatus(owner)[@"available"] boolValue],@"reviewed blur carrier shapes supported");
    UIView *blurCountry=Find(form,@"socialbox.identity.field.country"); Check([blurCountry isKindOfClass:UIVisualEffectView.class] && ((UIVisualEffectView *)blurCountry).effect==nil,@"original blur artwork removed while carrier retained");
    owner.invalid=YES; [owner build]; NSUInteger before=owner.events; SBIdentityRefresh(owner);
    Check(![SBIdentityStatus(owner)[@"available"] boolValue],@"unknown source row closes form");
    Check([SBIdentityStatus(owner)[@"reasonCodes"] containsObject:@"SB-ID-UNKNOWN-CAPTION"],@"unknown row yields fixed reason");
    Check(owner.events==before && owner.contentStack.hidden,@"unsupported form leaves native actions untouched and source hidden");
    Check(Find(form,@"socialbox.identity.control.regenerate")==nil,@"unsupported form exposes no partial actions");
    Screenshot(self.window,@"identity-unavailable.png"); owner.invalid=NO; [owner build]; SBIdentityRefresh(owner);
    Check([SBIdentityStatus(owner)[@"available"] boolValue],@"valid native rebuild recovers form");
    Check(!SBIdentityApply([UIViewController new]),@"unrelated screen rejected");
    Check([SBIdentityStatus(owner)[@"scope"] isEqual:@"shared-rules-current-session"] && ![SBIdentityStatus(owner)[@"runtimeVerified"] boolValue],@"status distinguishes scope and unverified real runtime");
    NSDictionary *result=@{@"ok":@(!Failures.count),@"assertions":@(Checks),@"failures":Failures,@"status":SBIdentityStatus(owner),@"fixtureOnly":@YES};
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[documents stringByAppendingPathComponent:@"identity-result.json"] atomically:YES];
}
@end
int main(int argc,char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(IdentityFixtureApp.class)); } }
