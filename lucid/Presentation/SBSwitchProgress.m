#import "SBSwitchProgress.h"
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static UIColor *ProgressBlue(void) { return [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1]; }
static char ProgressKey;
static IMP OverlayGetter, LabelGetter;
static BOOL Installed;

@interface SBSwitchProgressGlyph : UIView
@property(nonatomic,strong) CAShapeLayer *track, *arc, *halo;
- (void)refreshMotion:(BOOL)reduced;
@end
@implementation SBSwitchProgressGlyph
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.userInteractionEnabled=NO;self.isAccessibilityElement=NO;
        self.accessibilityIdentifier=@"socialbox.container.switch.progress";
        self.track=[CAShapeLayer layer];self.arc=[CAShapeLayer layer];self.halo=[CAShapeLayer layer];
        for(CAShapeLayer *shape in @[self.halo,self.track,self.arc]) {
            shape.fillColor=UIColor.clearColor.CGColor;shape.strokeColor=ProgressBlue().CGColor;
            shape.lineCap=kCALineCapRound;shape.lineWidth=3;[self.layer addSublayer:shape];
        }
        self.track.opacity=.18;self.halo.opacity=0;self.halo.lineWidth=1.5;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(motionChanged:)
            name:UIAccessibilityReduceMotionStatusDidChangeNotification object:nil];
    }return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];[CATransaction setDisableActions:YES];
    CGFloat radius=MIN(self.bounds.size.width,self.bounds.size.height)/2-8;
    CGPoint center=CGPointMake(CGRectGetMidX(self.bounds),CGRectGetMidY(self.bounds));
    for(CAShapeLayer *shape in @[self.track,self.arc,self.halo])shape.frame=self.bounds;
    self.track.path=[UIBezierPath bezierPathWithArcCenter:center radius:MAX(radius,0)
        startAngle:-M_PI_2 endAngle:3*M_PI_2 clockwise:YES].CGPath;
    self.halo.path=self.track.path;
    self.arc.path=[UIBezierPath bezierPathWithArcCenter:center radius:MAX(radius,0)
        startAngle:-M_PI_2 endAngle:M_PI clockwise:YES].CGPath;
    [CATransaction commit];
}
- (void)didMoveToWindow { [super didMoveToWindow];[self refreshMotion:UIAccessibilityIsReduceMotionEnabled()]; }
- (void)motionChanged:(NSNotification *)note {
    (void)note;
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self refreshMotion:UIAccessibilityIsReduceMotionEnabled()];});return;}
    [self refreshMotion:UIAccessibilityIsReduceMotionEnabled()];
}
- (void)refreshMotion:(BOOL)reduced {
    if(!self.window || reduced) {
        [self.arc removeAnimationForKey:@"socialbox.orbit"];
        [self.halo removeAnimationForKey:@"socialbox.pulse"];
        return;
    }
    if(![self.arc animationForKey:@"socialbox.orbit"]) {
        CABasicAnimation *orbit=[CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        orbit.fromValue=@0;orbit.toValue=@(2*M_PI);orbit.duration=1.1;orbit.repeatCount=HUGE_VALF;
        [self.arc addAnimation:orbit forKey:@"socialbox.orbit"];
    }
    if(![self.halo animationForKey:@"socialbox.pulse"]) {
        CABasicAnimation *scale=[CABasicAnimation animationWithKeyPath:@"transform.scale"];
        scale.fromValue=@1;scale.toValue=@1.35;
        CABasicAnimation *fade=[CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue=@.55;fade.toValue=@0;
        CAAnimationGroup *pulse=[CAAnimationGroup animation];pulse.animations=@[scale,fade];
        pulse.duration=1.65;pulse.repeatCount=HUGE_VALF;
        pulse.timingFunction=[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [self.halo addAnimation:pulse forKey:@"socialbox.pulse"];
    }
}
@end
#if LBX_PRESENTATION_FIXTURE
void SBSwitchProgressFixtureReduceMotion(UIView *glyph,BOOL reduced) {
    if([glyph isKindOfClass:SBSwitchProgressGlyph.class])[(SBSwitchProgressGlyph *)glyph refreshMotion:reduced];
}
#endif

static BOOL HostImage(const char *image) {
    return image && [@(image).stringByResolvingSymlinksInPath isEqual:NSBundle.mainBundle.executablePath.stringByResolvingSymlinksInPath];
}
static BOOL OwnedMethod(Class cls,SEL selector,const char *type,IMP expected) {
    Method method=class_getInstanceMethod(cls,selector);Dl_info info={0};
    if(!method || strcmp(method_getTypeEncoding(method),type))return NO;
    IMP implementation=method_getImplementation(method);
    return (!expected || implementation==expected) && dladdr((const void *)implementation,&info) && HostImage(info.dli_fname);
}
static void Decorate(UIViewController *owner) {
    if(!NSThread.isMainThread || SBBackendScreen(owner)!=SBScreenContainers || !owner.isViewLoaded)return;
    Class cls=object_getClass(owner);SEL overlaySelector=NSSelectorFromString(@"socialbox_loadingOverlay");
    SEL labelSelector=NSSelectorFromString(@"socialbox_loadingLabel");
    if(!OwnedMethod(cls,overlaySelector,"@16@0:8",OverlayGetter) || !OwnedMethod(cls,labelSelector,"@16@0:8",LabelGetter))return;
    UIView *overlay=((id(*)(id,SEL))OverlayGetter)(owner,overlaySelector);
    UILabel *label=((id(*)(id,SEL))LabelGetter)(owner,labelSelector);
    UIWindow *window=owner.view.window;
    // Recovered 0x100223568: window -> dimming view -> card -> spinner + label.
    // Unknown or interactive structures stay original. No global theme mutation.
    if(!window || object_getClass(overlay)!=UIView.class || overlay.superview!=window || overlay.subviews.count!=1
        || object_getClass(label)!=UILabel.class)return;
    UIView *card=overlay.subviews.firstObject;
    SBSwitchProgressGlyph *glyph=objc_getAssociatedObject(overlay,&ProgressKey);
    if(object_getClass(card)!=UIView.class || label.superview!=card || card.subviews.count!=(glyph?3u:2u))return;
    UIActivityIndicatorView *spinner=nil;
    for(UIView *view in card.subviews) {
        if(object_getClass(view)==UIActivityIndicatorView.class && !spinner)spinner=(id)view;
        else if(view!=label && view!=glyph)return;
    }
    if(!spinner || label.userInteractionEnabled || label.gestureRecognizers.count || spinner.gestureRecognizers.count
        || card.gestureRecognizers.count || overlay.gestureRecognizers.count
        || (glyph && (glyph.superview!=card || ![glyph isKindOfClass:SBSwitchProgressGlyph.class])))return;
    [overlay layoutIfNeeded];
    CGRect artwork=CGRectMake(CGRectGetMidX(spinner.frame)-26,CGRectGetMidY(spinner.frame)-26,52,52);
    if(!CGRectContainsRect(card.bounds,spinner.frame) || !CGRectContainsRect(card.bounds,label.frame)
        || !CGRectContainsRect(card.bounds,artwork) || CGRectIntersectsRect(artwork,label.frame))return;
    if(!glyph) {
        glyph=[SBSwitchProgressGlyph new];glyph.translatesAutoresizingMaskIntoConstraints=NO;[card addSubview:glyph];
        [NSLayoutConstraint activateConstraints:@[[glyph.centerXAnchor constraintEqualToAnchor:spinner.centerXAnchor],
            [glyph.centerYAnchor constraintEqualToAnchor:spinner.centerYAnchor],
            [glyph.widthAnchor constraintEqualToConstant:52],[glyph.heightAnchor constraintEqualToConstant:52]]];
        objc_setAssociatedObject(overlay,&ProgressKey,glyph,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    card.backgroundColor=SBPanel();card.layer.cornerRadius=22;
    card.layer.borderWidth=1;card.layer.borderColor=[ProgressBlue() colorWithAlphaComponent:.22].CGColor;
    // Keep its animation state, constraints and original lifecycle. Only its
    // visible artwork is replaced; the original label and timer remain live.
    spinner.color=ProgressBlue();spinner.alpha=0;
}
BOOL SBSwitchProgressInstall(void) {
    if(!NSThread.isMainThread || !SBBackendMetadataSupported(SBBackendAppMetadata(),NULL))return NO;
    if(Installed)return YES;
    Class cls=NSClassFromString(@"_Xc9m");SEL show=NSSelectorFromString(@"socialbox_showLoadingWithMessage:");
    SEL overlay=NSSelectorFromString(@"socialbox_loadingOverlay"),label=NSSelectorFromString(@"socialbox_loadingLabel");
    if(!cls || ![cls isSubclassOfClass:UIViewController.class] || !HostImage(class_getImageName(cls))
        || !OwnedMethod(cls,show,"v24@0:8@16",NULL) || !OwnedMethod(cls,overlay,"@16@0:8",NULL)
        || !OwnedMethod(cls,label,"@16@0:8",NULL))return NO;
    typedef void(*Hook)(Class,SEL,IMP,IMP *);Hook hook=(Hook)dlsym(RTLD_DEFAULT,"MSHookMessageEx");
    if(!hook)return NO;
    OverlayGetter=class_getMethodImplementation(cls,overlay);LabelGetter=class_getMethodImplementation(cls,label);
    __block IMP original=NULL;
    IMP replacement=imp_implementationWithBlock(^(UIViewController *owner,id message){
        ((void(*)(id,SEL,id))original)(owner,show,message);Decorate(owner);
    });
    hook(cls,show,replacement,&original);Installed=YES;return YES;
}
