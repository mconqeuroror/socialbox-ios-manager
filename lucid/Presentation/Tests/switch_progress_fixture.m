// Actual presentation source with an inert inherited loader, never the engine.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "SBSwitchProgress.h"
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import "activation_transport_fixture.h"
#import "saved_setup_transport_fixture.h"

static char OverlayKey,TimerKey,BaseKey,LabelKey;
static NSUInteger Checks,Shows,Updates,Hides,Ticks,Hooks;
static NSMutableArray *Failures;
static BOOL ExtraControl;
static BOOL GestureCard,InteractiveLabel;
static CGFloat SpinnerTop=30;
static void Check(BOOL ok,NSString *name){Checks++;if(!ok)[Failures addObject:name];}
__attribute__((visibility("default"))) void MSHookMessageEx(Class cls,SEL sel,IMP replacement,IMP *original){
    Method method=class_getInstanceMethod(cls,sel);*original=method_getImplementation(method);
    if(!class_addMethod(cls,sel,replacement,method_getTypeEncoding(method)))method_setImplementation(class_getInstanceMethod(cls,sel),replacement);
    Hooks++;
}
@interface UIViewController (SyntheticLoader)
- (UIView *)socialbox_loadingOverlay;
- (UILabel *)socialbox_loadingLabel;
- (void)socialbox_showLoadingWithMessage:(id)message;
- (void)socialbox_updateLoadingMessage:(id)message;
- (void)socialbox_hideLoadingWithCompletion:(void(^)(void))completion;
@end
static void Drop(UIViewController *owner){
    [objc_getAssociatedObject(owner,&TimerKey) invalidate];
    [owner.socialbox_loadingOverlay removeFromSuperview];
    objc_setAssociatedObject(owner,&OverlayKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(owner,&LabelKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(owner,&TimerKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@implementation UIViewController (SyntheticLoader)
- (UIView *)socialbox_loadingOverlay{return objc_getAssociatedObject(self,&OverlayKey);}
- (UILabel *)socialbox_loadingLabel{return objc_getAssociatedObject(self,&LabelKey);}
- (void)socialbox_showLoadingWithMessage:(id)message{
    Shows++;if(self.socialbox_loadingOverlay||!self.view.window)return;
    UIView *overlay=[[UIView alloc] initWithFrame:self.view.window.bounds];overlay.backgroundColor=[UIColor colorWithWhite:0 alpha:.85];
    UIView *card=[UIView new];card.backgroundColor=UIColor.darkGrayColor;card.translatesAutoresizingMaskIntoConstraints=NO;[overlay addSubview:card];
    UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.color=[UIColor colorWithRed:1 green:.584 blue:0 alpha:1];spinner.translatesAutoresizingMaskIntoConstraints=NO;[spinner startAnimating];[card addSubview:spinner];
    UILabel *label=[UILabel new];label.text=message;label.textColor=UIColor.whiteColor;label.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    label.textAlignment=NSTextAlignmentCenter;label.numberOfLines=2;label.translatesAutoresizingMaskIntoConstraints=NO;[card addSubview:label];
    label.userInteractionEnabled=InteractiveLabel;
    if(GestureCard)[card addGestureRecognizer:[UITapGestureRecognizer new]];
    if(ExtraControl)[card addSubview:[UIButton new]];
    [NSLayoutConstraint activateConstraints:@[[card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],[card.widthAnchor constraintEqualToConstant:200],
        [card.heightAnchor constraintEqualToConstant:140],[spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:SpinnerTop],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:20],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10]]];
    [self.view.window addSubview:overlay];objc_setAssociatedObject(self,&OverlayKey,overlay,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,&LabelKey,label,OBJC_ASSOCIATION_RETAIN_NONATOMIC);objc_setAssociatedObject(self,&BaseKey,message,OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:.08 repeats:YES block:^(__unused NSTimer *tick){
        Ticks++;self.socialbox_loadingLabel.text=[objc_getAssociatedObject(self,&BaseKey) stringByAppendingString:@" · 1s"];
    }];objc_setAssociatedObject(self,&TimerKey,timer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)socialbox_updateLoadingMessage:(id)message{
    Updates++;objc_setAssociatedObject(self,&BaseKey,message,OBJC_ASSOCIATION_COPY_NONATOMIC);self.socialbox_loadingLabel.text=message;
}
- (void)socialbox_hideLoadingWithCompletion:(void(^)(void))completion{
    Hides++;[objc_getAssociatedObject(self,&TimerKey) invalidate];
    UIView *overlay=self.socialbox_loadingOverlay;
    if(!overlay){if(completion)completion();return;}
    [UIView animateWithDuration:.05 animations:^{overlay.alpha=0;} completion:^(__unused BOOL finished){Drop(self);if(completion)completion();}];
}
@end
@interface _Xc9m:UIViewController @end
@implementation _Xc9m @end
@interface DerivedContainers:_Xc9m @end
@implementation DerivedContainers @end

static UIView *Glyph(UIView *overlay){
    for(UIView *view in overlay.subviews.firstObject.subviews)if([view.accessibilityIdentifier isEqual:@"socialbox.container.switch.progress"])return view;
    return nil;
}
static UIActivityIndicatorView *Spinner(UIView *overlay){
    for(UIView *view in overlay.subviews.firstObject.subviews)if([view isKindOfClass:UIActivityIndicatorView.class])return (id)view;
    return nil;
}
static NSArray *Layers(UIView *glyph){return glyph.layer.sublayers?:@[];}
static BOOL Animating(UIView *glyph){for(CALayer *layer in Layers(glyph))if(layer.animationKeys.count)return YES;return NO;}
static NSDictionary *Metadata(void){return @{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",@"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"};}
@interface ProgressApp:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) _Xc9m *owner;
@end
@implementation ProgressApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options{
    (void)application;(void)options;Failures=[NSMutableArray array];
    SBBackendFixtureConfigure(@{},NSBundle.mainBundle.executablePath);
    Check(!SBSwitchProgressInstall()&&Hooks==0,@"wrong metadata registers no progress hook");
    SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    // A foreign getter blocks installation before any hook. Restore original
    // before the accepted fixture install; this changes no shipped class.
    Method getter=class_getInstanceMethod(UIViewController.class,@selector(socialbox_loadingLabel));
    IMP validGetter=method_getImplementation(getter);
    method_setImplementation(getter,class_getMethodImplementation(NSObject.class,@selector(description)));
    Check(!SBSwitchProgressInstall()&&Hooks==0,@"foreign getter implementation prevents installation");method_setImplementation(getter,validGetter);
    Check(SBSwitchProgressInstall()&&Hooks==1,@"exact inherited Containers show hook installs once");
    Check(SBSwitchProgressInstall()&&Hooks==1,@"repeat installation preserves one hook");
    IMP hide=class_getMethodImplementation(UIViewController.class,@selector(socialbox_hideLoadingWithCompletion:));
    Check(class_getMethodImplementation(_Xc9m.class,@selector(socialbox_hideLoadingWithCompletion:))==hide,@"hide completion implementation remains unhooked");
    Check(class_getMethodImplementation(_Xc9m.class,@selector(socialbox_updateLoadingMessage:))==class_getMethodImplementation(UIViewController.class,@selector(socialbox_updateLoadingMessage:)),@"message update implementation remains unhooked");
    self.owner=[_Xc9m new];self.owner.view.backgroundColor=SBInk();self.owner.title=@"Containers";
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=self.owner;[self.window makeKeyAndVisible];
    [self.owner socialbox_showLoadingWithMessage:@"Preparing container…"];
    UIView *overlay=self.owner.socialbox_loadingOverlay,*glyph=Glyph(overlay);UIActivityIndicatorView *spinner=Spinner(overlay);UILabel *label=self.owner.socialbox_loadingLabel;
    NSTimer *timer=objc_getAssociatedObject(self.owner,&TimerKey);NSArray *constraints=[overlay.subviews.firstObject.constraints copy];
    Check(Shows==1&&overlay&&glyph,@"original loader called once and owns new decoration");
    Check(spinner.isAnimating&&spinner.alpha==0&&!spinner.hidden,@"original spinner remains animating with only visible artwork concealed");
    CGFloat r,g,b,a;[spinner.color getRed:&r green:&g blue:&b alpha:&a];Check(r==0&&fabs(g-122.0/255.0)<.001&&b==1&&a==1,@"cool blue replaces retained orange");
    Check(!glyph.userInteractionEnabled&&!glyph.isAccessibilityElement,@"decoration does not intercept interaction or duplicate spoken status");
    Check([label.text isEqual:@"Preparing container…"]&&label.numberOfLines==2,@"original status text and label contract preserved");
    [overlay layoutIfNeeded];Check(CGRectContainsRect(overlay.subviews.firstObject.bounds,glyph.frame),@"new circular artwork fits original card");
    Check(Animating(glyph)&&Layers(glyph).count==3,@"new orbit and pulse layers animate on visible window");
    [self.owner socialbox_showLoadingWithMessage:@"Must not replace retained message"];
    Check(Shows==2&&self.owner.socialbox_loadingOverlay==overlay&&Glyph(overlay)==glyph&&overlay.subviews.firstObject.subviews.count==3,@"repeat show retains one original overlay and one glyph");
    Check(objc_getAssociatedObject(self.owner,&TimerKey)==timer&&[label.text isEqual:@"Preparing container…"]&&[overlay.subviews.firstObject.constraints isEqual:constraints],@"repeat decoration retains timer message and constraints");
    [self.owner socialbox_updateLoadingMessage:@"Finishing container…"];
    Check(Updates==1&&self.owner.socialbox_loadingLabel==label&&[label.text isEqual:@"Finishing container…"],@"original update retains exact label and message");
    SBSwitchProgressFixtureReduceMotion(glyph,YES);Check(!Animating(glyph)&&Layers(glyph).count==3,@"Reduce Motion shows static ring with no repeating animation");
    SBSwitchProgressFixtureReduceMotion(glyph,NO);Check(Animating(glyph),@"motion can resume without replacing glyph or loader");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        Check(Ticks>0&&timer.valid&&[label.text isEqual:@"Finishing container… · 1s"],@"original actual timer keeps updating original label");
        [self.window layoutIfNeeded];
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
        NSData *png=[renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context){(void)context;[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
        NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [png writeToFile:[directory stringByAppendingPathComponent:@"switch-progress-preview.png"] atomically:YES];
        __block NSUInteger completions=0;[self.owner socialbox_hideLoadingWithCompletion:^{completions++;}];
        Check(Hides==1&&completions==0,@"original hide keeps asynchronous completion timing");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            Check(completions==1&&!self.owner.socialbox_loadingOverlay&&!timer.valid,@"original hide clears its state and invokes completion exactly once");
            Check(!glyph.window&&!Animating(glyph),@"detached artwork stops only its own animations");
            [self.owner socialbox_showLoadingWithMessage:@"New operation"];
            Check(Glyph(self.owner.socialbox_loadingOverlay)!=glyph&&Shows==3,@"later operation creates fresh artwork without retained completion");Drop(self.owner);
            [self negatives];[self finish];
        });
    });return YES;
}
- (void)negatives{
    ExtraControl=YES;[self.owner socialbox_showLoadingWithMessage:@"Unknown card"];
    Check(!Glyph(self.owner.socialbox_loadingOverlay)&&Spinner(self.owner.socialbox_loadingOverlay).alpha==1,@"interactive unknown card remains original");Drop(self.owner);ExtraControl=NO;
    GestureCard=YES;[self.owner socialbox_showLoadingWithMessage:@"Gesture card"];
    Check(!Glyph(self.owner.socialbox_loadingOverlay)&&Spinner(self.owner.socialbox_loadingOverlay).alpha==1,@"gesture-bearing card remains original");Drop(self.owner);GestureCard=NO;
    InteractiveLabel=YES;[self.owner socialbox_showLoadingWithMessage:@"Interactive label"];
    Check(!Glyph(self.owner.socialbox_loadingOverlay)&&Spinner(self.owner.socialbox_loadingOverlay).alpha==1,@"interactive label remains original");Drop(self.owner);InteractiveLabel=NO;
    SpinnerTop=0;[self.owner socialbox_showLoadingWithMessage:@"Compact shape"];
    Check(!Glyph(self.owner.socialbox_loadingOverlay)&&Spinner(self.owner.socialbox_loadingOverlay).alpha==1,@"clipping proposed artwork refuses before concealment");Drop(self.owner);SpinnerTop=30;
    CGRect fullFrame=self.window.frame;self.window.frame=CGRectMake(0,0,320,568);[self.window layoutIfNeeded];
    [self.owner socialbox_showLoadingWithMessage:@"Narrow viewport"];
    Check(Glyph(self.owner.socialbox_loadingOverlay)&&CGRectContainsRect(self.owner.socialbox_loadingOverlay.subviews.firstObject.bounds,Glyph(self.owner.socialbox_loadingOverlay).frame),@"320-point viewport contains full circular artwork");Drop(self.owner);self.window.frame=fullFrame;
    SBBackendFixtureConfigure(@{},NSBundle.mainBundle.executablePath);[self.owner socialbox_showLoadingWithMessage:@"Unsupported host"];
    Check(!Glyph(self.owner.socialbox_loadingOverlay)&&Spinner(self.owner.socialbox_loadingOverlay).alpha==1,@"current metadata mismatch leaves original visuals");Drop(self.owner);SBBackendFixtureConfigure(Metadata(),NSBundle.mainBundle.executablePath);
    UIViewController *other=[UIViewController new];[self.owner addChildViewController:other];[self.owner.view addSubview:other.view];[other didMoveToParentViewController:self.owner];
    [other socialbox_showLoadingWithMessage:@"Other screen"];
    Check(!Glyph(other.socialbox_loadingOverlay)&&Spinner(other.socialbox_loadingOverlay).alpha==1,@"other controllers inherit unchanged loader");Drop(other);[other.view removeFromSuperview];[other removeFromParentViewController];
    DerivedContainers *derived=[DerivedContainers new];[self.owner addChildViewController:derived];[self.owner.view addSubview:derived.view];[derived didMoveToParentViewController:self.owner];
    [derived socialbox_showLoadingWithMessage:@"Unknown subclass"];
    Check(!Glyph(derived.socialbox_loadingOverlay)&&Spinner(derived.socialbox_loadingOverlay).alpha==1,@"unregistered subclass cannot receive decoration");Drop(derived);[derived.view removeFromSuperview];[derived removeFromParentViewController];
    // Replace the label implementation after installation. Original show still
    // runs; the current getter witness prevents any artwork change.
    Method getter=class_getInstanceMethod(UIViewController.class,@selector(socialbox_loadingLabel));IMP valid=method_getImplementation(getter);
    method_setImplementation(getter,class_getMethodImplementation(NSObject.class,@selector(description)));
    [self.owner socialbox_showLoadingWithMessage:@"Replaced getter"];
    Check(!Glyph(self.owner.socialbox_loadingOverlay)&&Spinner(self.owner.socialbox_loadingOverlay).alpha==1,@"post-install foreign getter preserves original artwork");method_setImplementation(getter,valid);Drop(self.owner);
    Check(SBTestLicenseRequestCount()==0&&SBTestSavedSetupValidateCount()==0,@"presentation performs no license or saved-settings request");
}
- (void)finish{
    NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSDictionary *report=@{@"ok":Failures.count==0?@YES:@NO,@"assertions":@(Checks),@"failures":Failures,@"originalShows":@(Shows),@"registeredProgressHooks":@(Hooks),@"scope":@"Synthetic UIKit loader decoration only; no original operation, account, native peer, device or runtime acceptance"};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"presentation-result.json"] atomically:YES];
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProgressApp.class));}}
