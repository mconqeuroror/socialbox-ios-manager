// Actual isolated addon with an inert inherited UIKit loader. No original
// operation, admission, account, license, transport or device implementation.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import "../SBBlueProgressAddon.h"
#import "../../Presentation/SBSwitchProgress.h"

static char OverlayKey, LabelKey, TimerKey, MessageKey;
static NSUInteger Checks, Shows, Updates, Hides, Ticks, Hooks;
static NSMutableArray<NSString *> *Failures;
static BOOL ExtraControl, InteractiveLabel;
static NSUInteger GestureKind;
static CGFloat SpinnerTop=30;
static void Check(BOOL accepted, NSString *name) { Checks++;if(!accepted)[Failures addObject:name]; }

__attribute__((visibility("default")))
void MSHookMessageEx(Class cls,SEL selector,IMP replacement,IMP *original) {
    Method method=class_getInstanceMethod(cls,selector);
    *original=method_getImplementation(method);
    if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls,selector),replacement);
    Hooks++;
}

@interface UIViewController (InertProgressLoader)
- (UIView *)socialbox_loadingOverlay;
- (UILabel *)socialbox_loadingLabel;
- (void)socialbox_showLoadingWithMessage:(id)message;
- (void)socialbox_updateLoadingMessage:(id)message;
- (void)socialbox_hideLoadingWithCompletion:(void (^)(void))completion;
@end
static void Drop(UIViewController *owner) {
    [objc_getAssociatedObject(owner,&TimerKey) invalidate];
    [owner.socialbox_loadingOverlay removeFromSuperview];
    const void *keys[]={&OverlayKey,&LabelKey,&TimerKey,&MessageKey};
    for(NSUInteger index=0;index<sizeof(keys)/sizeof(keys[0]);index++) {
        // Explicit local fixture teardown only; never touches authored metadata.
        objc_setAssociatedObject(owner,keys[index],nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@implementation UIViewController (InertProgressLoader)
- (UIView *)socialbox_loadingOverlay { return objc_getAssociatedObject(self,&OverlayKey); }
- (UILabel *)socialbox_loadingLabel { return objc_getAssociatedObject(self,&LabelKey); }
- (void)socialbox_showLoadingWithMessage:(id)message {
    Shows++;
    if(self.socialbox_loadingOverlay || !self.view.window)return;
    UIView *overlay=[[UIView alloc] initWithFrame:self.view.window.bounds];
    overlay.backgroundColor=[UIColor colorWithWhite:0 alpha:.85];
    UIView *card=[UIView new];card.backgroundColor=UIColor.darkGrayColor;
    card.translatesAutoresizingMaskIntoConstraints=NO;[overlay addSubview:card];
    UIActivityIndicatorView *spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.color=[UIColor colorWithRed:1 green:.584 blue:0 alpha:1];
    spinner.translatesAutoresizingMaskIntoConstraints=NO;[spinner startAnimating];[card addSubview:spinner];
    UILabel *label=[UILabel new];label.text=message;label.textColor=UIColor.whiteColor;
    label.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];label.numberOfLines=2;
    label.textAlignment=NSTextAlignmentCenter;label.translatesAutoresizingMaskIntoConstraints=NO;
    label.userInteractionEnabled=InteractiveLabel;[card addSubview:label];
    if(ExtraControl)[card addSubview:[UIButton new]];
    NSArray<UIView *> *gestureTargets=@[label,spinner,card,overlay];
    if(GestureKind)[gestureTargets[GestureKind-1] addGestureRecognizer:[UITapGestureRecognizer new]];
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:200],[card.heightAnchor constraintEqualToConstant:140],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:SpinnerTop],
        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:20],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-10]]];
    [self.view.window addSubview:overlay];
    objc_setAssociatedObject(self,&OverlayKey,overlay,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,&LabelKey,label,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,&MessageKey,message,OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSTimer *timer=[NSTimer scheduledTimerWithTimeInterval:.08 repeats:YES block:^(__unused NSTimer *tick) {
        Ticks++;self.socialbox_loadingLabel.text=[objc_getAssociatedObject(self,&MessageKey) stringByAppendingString:@" · 1s"];
    }];
    objc_setAssociatedObject(self,&TimerKey,timer,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)socialbox_updateLoadingMessage:(id)message {
    Updates++;objc_setAssociatedObject(self,&MessageKey,message,OBJC_ASSOCIATION_COPY_NONATOMIC);
    self.socialbox_loadingLabel.text=message;
}
- (void)socialbox_hideLoadingWithCompletion:(void (^)(void))completion {
    Hides++;[objc_getAssociatedObject(self,&TimerKey) invalidate];
    UIView *overlay=self.socialbox_loadingOverlay;
    if(!overlay){if(completion)completion();return;}
    [UIView animateWithDuration:.05 animations:^{overlay.alpha=0;} completion:^(__unused BOOL finished) {
        Drop(self);if(completion)completion();
    }];
}
@end

@interface _Xc9m:UIViewController @end
@implementation _Xc9m @end
@interface AddonDerivedContainers:_Xc9m @end
@implementation AddonDerivedContainers @end

static NSDictionary *Metadata(void) {
    return @{@"CFBundleIdentifier":@"com.socialbox.app",@"CFBundleExecutable":@"SocialBox",
             @"CFBundleShortVersionString":@"3.1.0",@"CFBundleVersion":@"1"};
}
static UIView *Glyph(UIView *overlay) {
    for(UIView *view in overlay.subviews.firstObject.subviews)
        if([view.accessibilityIdentifier isEqual:@"socialbox.container.switch.progress"])return view;
    return nil;
}
static UIActivityIndicatorView *Spinner(UIView *overlay) {
    for(UIView *view in overlay.subviews.firstObject.subviews)
        if(object_getClass(view)==UIActivityIndicatorView.class)return (id)view;
    return nil;
}
static BOOL Animating(UIView *glyph) {
    for(CALayer *layer in glyph.layer.sublayers)if(layer.animationKeys.count)return YES;
    return NO;
}
static BOOL OriginalArtwork(UIView *overlay) {
    UIActivityIndicatorView *spinner=Spinner(overlay);CGFloat r=0,g=0,b=0,a=0;
    [spinner.color getRed:&r green:&g blue:&b alpha:&a];
    return overlay && !Glyph(overlay) && spinner.isAnimating && spinner.alpha==1 &&
        fabs(r-1)<.001 && fabs(g-.584)<.001 && fabs(b)<.001 && a==1;
}

@interface AddonFixtureApp:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) _Xc9m *owner;
@end
@implementation AddonFixtureApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;Failures=[NSMutableArray array];
    Check(Hooks==0,@"test build has no installing constructor");
    Check(NSClassFromString(@"SBBlueProgressGlyph") && !NSClassFromString(@"SBSwitchProgressGlyph"),
          @"only isolated glyph class is linked");
    Check(!dlsym(RTLD_DEFAULT,"SBSwitchProgressInstall") && !dlsym(RTLD_DEFAULT,"LBXPresentationInstall") &&
          !NSClassFromString(@"LBXContainerRootMutationCoordinator"),@"full overlay and coordinator are absent");
    SBBlueProgressFixtureMetadata(Metadata());SBBlueProgressFixturePins(NO);
    Check(!SBBlueProgressAddonInstall() && Hooks==0,@"missing synthetic pins install no hook");
    SBBlueProgressFixturePins(YES);SBBlueProgressFixtureMetadata(@{});
    Check(!SBBlueProgressAddonInstall() && Hooks==0,@"bad metadata installs no hook");
    NSMutableDictionary *wrong=[Metadata() mutableCopy];wrong[@"CFBundleVersion"]=@1;
    SBBlueProgressFixtureMetadata(wrong);
    Check(!SBBlueProgressAddonInstall() && Hooks==0,@"nonstring metadata refuses exact profile");
    SBBlueProgressFixtureMetadata(Metadata());
    Method getter=class_getInstanceMethod(UIViewController.class,@selector(socialbox_loadingLabel));
    IMP originalGetter=method_getImplementation(getter);
    method_setImplementation(getter,class_getMethodImplementation(NSObject.class,@selector(description)));
    Check(!SBBlueProgressAddonInstall() && Hooks==0,@"foreign getter refuses before hook");
    method_setImplementation(getter,originalGetter);
    IMP originalUpdate=class_getMethodImplementation(UIViewController.class,@selector(socialbox_updateLoadingMessage:));
    IMP originalHide=class_getMethodImplementation(UIViewController.class,@selector(socialbox_hideLoadingWithCompletion:));
    Check(SBBlueProgressAddonInstall() && Hooks==1,@"exact inherited loader installs one isolated show hook");
    Check(SBBlueProgressAddonInstall() && Hooks==1,@"repeat install preserves one hook");
    Check(class_getMethodImplementation(_Xc9m.class,@selector(socialbox_updateLoadingMessage:))==originalUpdate &&
          class_getMethodImplementation(_Xc9m.class,@selector(socialbox_hideLoadingWithCompletion:))==originalHide,
          @"original update and completion implementations remain unhooked");
    self.owner=[_Xc9m new];self.owner.view.backgroundColor=UIColor.blackColor;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=self.owner;[self.window makeKeyAndVisible];
    [self.owner socialbox_showLoadingWithMessage:@"Synthetic presentation preview"];
    UIView *overlay=self.owner.socialbox_loadingOverlay,*glyph=Glyph(overlay);
    UIActivityIndicatorView *spinner=Spinner(overlay);UILabel *label=self.owner.socialbox_loadingLabel;
    NSTimer *timer=objc_getAssociatedObject(self.owner,&TimerKey);
    NSArray *constraints=[overlay.subviews.firstObject.constraints copy];
    Check(Shows==1 && overlay && object_getClass(glyph)==NSClassFromString(@"SBBlueProgressGlyph"),
          @"original called once and exact isolated blue glyph added");
    Check(spinner.isAnimating && spinner.alpha==0 && !spinner.hidden,@"original spinner animation and visibility flag retained");
    CGFloat r=0,g=0,b=0,a=0;[spinner.color getRed:&r green:&g blue:&b alpha:&a];
    Check(r==0 && fabs(g-122.0/255.0)<.001 && b==1 && a==1,@"blue artwork replaces synthetic orange");
    Check(!glyph.userInteractionEnabled && !glyph.isAccessibilityElement,@"glyph does not intercept input or duplicate status");
    Check([label.text isEqual:@"Synthetic presentation preview"] && label.numberOfLines==2,
          @"original exact label and text preserved");
    [overlay layoutIfNeeded];
    Check(CGRectContainsRect(overlay.subviews.firstObject.bounds,glyph.frame) &&
          !CGRectIntersectsRect(glyph.frame,label.frame),@"blue ring fits card without overlapping message");
    Check(glyph.layer.sublayers.count==3 && Animating(glyph),@"visible orbit and pulse animate");
    [self.owner socialbox_showLoadingWithMessage:@"Ignored synthetic repeat"];
    Check(Shows==2 && self.owner.socialbox_loadingOverlay==overlay && Glyph(overlay)==glyph &&
          overlay.subviews.firstObject.subviews.count==3,@"repeat show preserves one overlay and glyph");
    Check(objc_getAssociatedObject(self.owner,&TimerKey)==timer &&
          [label.text isEqual:@"Synthetic presentation preview"] &&
          [overlay.subviews.firstObject.constraints isEqual:constraints],@"repeat retains exact timer text and constraints");
    [self.owner socialbox_updateLoadingMessage:@"Synthetic preview finishing"];
    Check(Updates==1 && self.owner.socialbox_loadingLabel==label && [label.text isEqual:@"Synthetic preview finishing"],
          @"original update reaches same label once");
    SBSwitchProgressFixtureReduceMotion(glyph,YES);
    Check(!Animating(glyph) && glyph.layer.sublayers.count==3,@"synthetic Reduce Motion retains static ring");
    SBSwitchProgressFixtureReduceMotion(glyph,NO);Check(Animating(glyph),@"synthetic motion resumes same glyph");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        Check(Ticks>0 && timer.valid && [label.text isEqual:@"Synthetic preview finishing · 1s"],
              @"original actual timer keeps updating original label");
        [self.window layoutIfNeeded];
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
        NSData *png=[renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];
        }];
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        Check([png writeToFile:[documents stringByAppendingPathComponent:@"addon-preview.png"] atomically:YES],
              @"synthetic preview image retained");
        __block NSUInteger completions=0;
        [self.owner socialbox_hideLoadingWithCompletion:^{completions++;}];
        Check(Hides==1 && completions==0,@"original hide remains asynchronous");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            Check(completions==1 && !self.owner.socialbox_loadingOverlay && !timer.valid,
                  @"original hide clears only its fixture state and completes once");
            Check(!glyph.window && !Animating(glyph),@"detached ring stops its own animations");
            [self.owner socialbox_showLoadingWithMessage:@"Later synthetic preview"];
            Check(Shows==3 && Glyph(self.owner.socialbox_loadingOverlay) && Glyph(self.owner.socialbox_loadingOverlay)!=glyph,
                  @"later loader creates fresh glyph");Drop(self.owner);
            [self negatives];[self finish];
        });
    });return YES;
}
- (void)negatives {
    SBBlueProgressFixturePins(NO);NSUInteger before=Shows;
    Check(!SBBlueProgressAddonInstall() && Hooks==1,@"late pin loss cannot register another hook");
    [self.owner socialbox_showLoadingWithMessage:@"Lost synthetic profile"];
    Check(Shows==before+1 && OriginalArtwork(self.owner.socialbox_loadingOverlay),
          @"late pin loss calls original once without decoration");Drop(self.owner);SBBlueProgressFixturePins(YES);
    SBBlueProgressFixtureMetadata(@{});before=Shows;
    [self.owner socialbox_showLoadingWithMessage:@"Unsupported metadata"];
    Check(Shows==before+1 && OriginalArtwork(self.owner.socialbox_loadingOverlay),
          @"late metadata loss preserves original loader");Drop(self.owner);SBBlueProgressFixtureMetadata(Metadata());
    ExtraControl=YES;[self.owner socialbox_showLoadingWithMessage:@"Unknown control"];
    Check(OriginalArtwork(self.owner.socialbox_loadingOverlay),@"extra control leaves original artwork intact");Drop(self.owner);ExtraControl=NO;
    for(GestureKind=1;GestureKind<=4;GestureKind++) {
        [self.owner socialbox_showLoadingWithMessage:@"Gesture shape"];
        Check(OriginalArtwork(self.owner.socialbox_loadingOverlay),
              [NSString stringWithFormat:@"gesture shape %lu preserves original artwork",(unsigned long)GestureKind]);Drop(self.owner);
    }GestureKind=0;
    InteractiveLabel=YES;[self.owner socialbox_showLoadingWithMessage:@"Interactive label"];
    Check(OriginalArtwork(self.owner.socialbox_loadingOverlay),@"interactive label refuses decoration");Drop(self.owner);InteractiveLabel=NO;
    SpinnerTop=0;[self.owner socialbox_showLoadingWithMessage:@"Clipped ring"];
    Check(OriginalArtwork(self.owner.socialbox_loadingOverlay),@"clipped proposed ring refuses before concealment");Drop(self.owner);SpinnerTop=30;
    UIViewController *other=[UIViewController new];[self attach:other];before=Shows;
    [other socialbox_showLoadingWithMessage:@"Unrelated fixture controller"];
    Check(Shows==before+1 && OriginalArtwork(other.socialbox_loadingOverlay),@"unrelated controller remains original");[self detach:other];
    AddonDerivedContainers *derived=[AddonDerivedContainers new];[self attach:derived];before=Shows;
    [derived socialbox_showLoadingWithMessage:@"Unregistered fixture subclass"];
    Check(Shows==before+1 && OriginalArtwork(derived.socialbox_loadingOverlay),@"subclass cannot receive decoration");[self detach:derived];
    Method getter=class_getInstanceMethod(UIViewController.class,@selector(socialbox_loadingLabel));
    IMP valid=method_getImplementation(getter);method_setImplementation(getter,class_getMethodImplementation(NSObject.class,@selector(description)));
    [self.owner socialbox_showLoadingWithMessage:@"Changed getter"];
    Check(OriginalArtwork(self.owner.socialbox_loadingOverlay),@"postinstall foreign getter preserves original artwork");
    method_setImplementation(getter,valid);Drop(self.owner);
    Check(Hooks==1,@"all refusals leave exactly one original show hook");
}
- (void)attach:(UIViewController *)child {
    [self.owner addChildViewController:child];[self.owner.view addSubview:child.view];[child didMoveToParentViewController:self.owner];
}
- (void)detach:(UIViewController *)child {
    Drop(child);[child willMoveToParentViewController:nil];[child.view removeFromSuperview];[child removeFromParentViewController];
}
- (void)finish {
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSDictionary *result=@{@"ok":Failures.count==0?@YES:@NO,@"assertions":@(Checks),@"failures":Failures,
        @"originalShows":@(Shows),@"originalUpdates":@(Updates),@"originalHides":@(Hides),@"registeredProgressHooks":@(Hooks),
        @"scope":@"Actual isolated addon compiled with explicit synthetic pin/metadata substitutions and inert UIKit loader. No original operation, role/image acceptance, account, license, native peer, phone, runtime or installation acceptance."};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[documents stringByAppendingPathComponent:@"addon-result.json"] atomically:YES];
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AddonFixtureApp.class)); } }
