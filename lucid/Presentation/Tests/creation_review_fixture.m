// All values, navigation and original entries are synthetic and inert.
#import <UIKit/UIKit.h>
#import "SBContainersView.h"
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import "LBXIsolationViewController.h"
static NSUInteger Checks,Creates,Edits,CaseIndex;
static NSMutableArray *Failures;
static NSDictionary *Metadata(void){return @{ @"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"};}
static void Check(BOOL ok,NSString *message){Checks++;if(!ok)[Failures addObject:[NSString stringWithFormat:@"case %lu: %@",(unsigned long)CaseIndex,message]];}
static UIView *Find(UIView *root,NSString *identifier){if([root.accessibilityIdentifier isEqual:identifier])return root;for(UIView *child in root.subviews){UIView *found=Find(child,identifier);if(found)return found;}return nil;}
static NSArray *All(UIView *root,Class type){NSMutableArray *found=[NSMutableArray array];if([root isKindOfClass:type])[found addObject:root];for(UIView *child in root.subviews)[found addObjectsFromArray:All(child,type)];return found;}
static void Tap(UIView *root,NSString *key){[(UIButton *)Find(root,key) sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];}
static void Later(void(^block)(void)){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.65*NSEC_PER_SEC)),dispatch_get_main_queue(),block);}
@implementation LBXIsolationViewController @end
@interface HomeViewController:UIViewController
@property(nonatomic,strong) NSMutableDictionary<NSString *,UILabel *> *labels;
@property(nonatomic,strong) UIButton *create;
@property(nonatomic) BOOL missingModel;
@end
@implementation HomeViewController
- (void)viewDidLoad{[super viewDidLoad];self.labels=[NSMutableDictionary dictionary];
    NSArray *keys=@[@"model",@"system",@"carrier",@"device",@"number",@"serial",@"codes",@"wifi",@"bt",@"ethernet",@"imei",@"meid",@"iccid",@"idfa",@"idfv",@"udid"];
    for(NSString *key in keys){UILabel *label=[UILabel new];label.text=[@"Synthetic value — " stringByAppendingString:key];[self.view addSubview:label];self.labels[key]=label;}
    self.labels[@"model"].text=@"iPhone 15 Pro";self.labels[@"system"].text=@"17.0";self.labels[@"carrier"].text=@"Synthetic carrier";
    self.create=[UIButton buttonWithType:UIButtonTypeSystem];[self.create addTarget:self action:@selector(createEntry:) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.create];}
- (void)createEntry:(id)sender{if(sender==self.create)Creates++;}
- (void)openConfigureSpoofing{Edits++;}
- (UIButton *)fingerprintButton{return self.create;}
- (UILabel *)modelNameValue{return self.missingModel?nil:self.labels[@"model"];}
- (UILabel *)iosVersionValue{return self.labels[@"system"];}
- (UILabel *)carrierValue{return self.labels[@"carrier"];}
- (UILabel *)deviceNameValue{return self.labels[@"device"];}
- (UILabel *)modelNumberValue{return self.labels[@"number"];}
- (UILabel *)serialValue{return self.labels[@"serial"];}
- (UILabel *)mccMncValue{return self.labels[@"codes"];}
- (UILabel *)wifiValue{return self.labels[@"wifi"];}
- (UILabel *)btValue{return self.labels[@"bt"];}
- (UILabel *)ethernetValue{return self.labels[@"ethernet"];}
- (UILabel *)imeiValue{return self.labels[@"imei"];}
- (UILabel *)meidValue{return self.labels[@"meid"];}
- (UILabel *)iccidValue{return self.labels[@"iccid"];}
- (UILabel *)idfaValue{return self.labels[@"idfa"];}
- (UILabel *)idfvValue{return self.labels[@"idfv"];}
- (UILabel *)udidValue{return self.labels[@"udid"];}
@end
@interface _Xc9m:UIViewController
@property(nonatomic,strong) SBContainersView *surface;
@end
@implementation _Xc9m
- (void)viewDidLoad{[super viewDidLoad];self.surface=[[SBContainersView alloc] initWithOwner:self];self.surface.frame=self.view.bounds;self.surface.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;[self.view addSubview:self.surface];}
@end
@interface ReviewDelegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UITabBarController *tabs;
@property(nonatomic,strong) HomeViewController *home;
@property(nonatomic,strong) _Xc9m *containers;
- (void)run:(NSUInteger)index;
@end
@implementation ReviewDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options{
    (void)application;(void)options;Failures=[NSMutableArray array];SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    self.home=[HomeViewController new];[self.home loadViewIfNeeded];self.containers=[_Xc9m new];
    self.tabs=[UITabBarController new];self.tabs.viewControllers=@[[[UINavigationController alloc] initWithRootViewController:self.home],[[UINavigationController alloc] initWithRootViewController:self.containers]];
    self.tabs.selectedIndex=1;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=self.tabs;[self.window makeKeyAndVisible];Later(^{[self run:0];});return YES;
}
- (void)run:(NSUInteger)index{
    CaseIndex=index;
    if(index==12){NSDictionary *result=@{@"ok":@((BOOL)(Failures.count==0)),@"assertions":@(Checks),@"failures":Failures,@"syntheticCreates":@(Creates),@"syntheticSettingsEntries":@(Edits),@"phoneAction":@NO};
        NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL] writeToFile:[directory stringByAppendingPathComponent:@"creation-review-result.json"] atomically:YES];return;}
    SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);self.tabs.selectedIndex=1;self.home.create.enabled=YES;self.home.missingModel=index==2;
    if(@available(iOS 17.0,*))self.window.traitOverrides.preferredContentSizeCategory=index==1?UIContentSizeCategoryAccessibilityExtraExtraExtraLarge:UIContentSizeCategoryLarge;
    self.home.labels[@"carrier"].text=index==3?@"Changed synthetic carrier":@"Synthetic carrier";
    NSUInteger before=Creates,beforeEdits=Edits;
    if(index==10){self.tabs.selectedIndex=0;Tap(self.containers.surface,@"socialbox.containers.create");Check(!self.containers.presentedViewController&&Creates==before&&Edits==beforeEdits,@"offscreen Create refuses");Later(^{[self run:index+1];});return;}
    if(index==11){self.home.create.enabled=NO;Later(^{Check(self.containers.view.window!=nil,@"disabled-control test has a current source");Tap(self.containers.surface,@"socialbox.containers.create");Check(Creates==before&&Edits==beforeEdits,@"disabled original creation refuses");[self.containers dismissViewControllerAnimated:NO completion:nil];Later(^{[self run:index+1];});});return;}
    Later(^{
    Check(self.containers.view.window!=nil&&SBBackendActionAvailable(self.home,@"home.create",nil,NULL),@"review starts from attached source and available original control");
    Tap(self.containers.surface,@"socialbox.containers.create");
    Later(^{UIViewController *review=self.containers.presentedViewController;
        if(index==1){review.view.frame=CGRectMake(0,0,320,568);[review.view setNeedsLayout];[review.view layoutIfNeeded];}
        Check([review.view.accessibilityIdentifier isEqual:@"socialbox.creation.review"]&&Creates==before&&Edits==beforeEdits,@"Create opens review with no original entry");
        NSUInteger valueCount=0;for(UILabel *label in All(review.view,UILabel.class))if([label.accessibilityIdentifier hasPrefix:@"socialbox.creation.value."])valueCount++;
        Check(valueCount==16,@"all sixteen reported values have separate review rows");
        UILabel *model=(id)Find(review.view,@"socialbox.creation.value.identity.modelName");
        Check([model.text isEqual:index==2?@"Unavailable":@"iPhone 15 Pro"],@"missing reported value remains unavailable without invention");
        UILabel *carrier=(id)Find(review.view,@"socialbox.creation.value.identity.carrier");Check([carrier.text isEqual:self.home.labels[@"carrier"].text],@"each new review reads current displayed carrier");
        for(NSString *key in @[@"settings",@"continue",@"cancel"]){UIButton *button=(id)Find(review.view,[@"socialbox.creation." stringByAppendingString:key]);Check(button&&button.bounds.size.height>=44&&!button.hasAmbiguousLayout,@"review action is reachable and unambiguous");}
        UIScrollView *scroll=All(review.view,UIScrollView.class).firstObject;Check(scroll.contentSize.height>scroll.bounds.size.height,@"all profile values are scrollable");
        for(UILabel *label in All(review.view,UILabel.class))if([label.accessibilityIdentifier hasPrefix:@"socialbox.creation.value."]){CGRect frame=[label convertRect:label.bounds toView:review.view];Check(frame.origin.x>=0&&CGRectGetMaxX(frame)<=review.view.bounds.size.width+.5,@"reported values stay within readable width");}
        UIButton *continueButton=(id)Find(review.view,@"socialbox.creation.continue");[scroll scrollRectToVisible:[continueButton convertRect:continueButton.bounds toView:scroll] animated:NO];[scroll layoutIfNeeded];
        CGRect visible=[continueButton convertRect:continueButton.bounds toView:review.view];Check(visible.origin.y>=0&&CGRectGetMaxY(visible)<=review.view.bounds.size.height+.5,@"Continue can be reached after scrolling all profile values");[scroll setContentOffset:CGPointZero animated:NO];
        if(index==0){NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:review.view.bounds];
            [[renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context){[review.view drawViewHierarchyInRect:review.view.bounds afterScreenUpdates:YES];}] writeToFile:[directory stringByAppendingPathComponent:@"creation-review.png"] atomically:YES];}
        if(index==0||index==1){[scroll setContentOffset:CGPointMake(0,MAX(0,scroll.contentSize.height-scroll.bounds.size.height)) animated:NO];[scroll layoutIfNeeded];
            NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:review.view.bounds];
            [[renderer PNGDataWithActions:^(__unused UIGraphicsImageRendererContext *context){[review.view drawViewHierarchyInRect:review.view.bounds afterScreenUpdates:YES];}] writeToFile:[directory stringByAppendingPathComponent:index==0?@"creation-review-actions.png":@"creation-review-large-text.png"] atomically:YES];[scroll setContentOffset:CGPointZero animated:NO];}
        if(index<=3){Tap(review.view,@"socialbox.creation.cancel");}
        else if(index==4){Tap(review.view,@"socialbox.creation.settings");Tap(review.view,@"socialbox.creation.settings");}
        else if(index==5){Tap(review.view,@"socialbox.creation.continue");Tap(review.view,@"socialbox.creation.continue");}
        else if(index==6){self.home.create.enabled=NO;Tap(review.view,@"socialbox.creation.continue");}
        else if(index==7){SBBackendFixtureConfigure(@{},NSBundle.mainBundle.executablePath);Tap(review.view,@"socialbox.creation.continue");}
        else if(index==8){Tap(review.view,@"socialbox.creation.continue");[self.containers.navigationController pushViewController:[UIViewController new] animated:NO];}
        else if(index==9){Tap(review.view,@"socialbox.creation.continue");[self.home.navigationController pushViewController:[UIViewController new] animated:NO];}
        Later(^{Check(Creates==before+(index==5?1:0)&&Edits==beforeEdits+(index==4?1:0),@"explicit original entry occurs once; cancel, duplicate and stale state refuse");
            Check(![self.home.labels[@"model"].text isEqual:@"Unavailable"],@"rendering never changes original labels");
            SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);[self.home.navigationController popToRootViewControllerAnimated:NO];[self.containers.navigationController popToRootViewControllerAnimated:NO];
            [self.tabs dismissViewControllerAnimated:NO completion:nil];Later(^{[self run:index+1];});
        });
    });
    });
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ReviewDelegate.class));}}
