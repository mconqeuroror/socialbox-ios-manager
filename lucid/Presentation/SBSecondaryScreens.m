#import "SBInterfaceCopy.h"
#import "SBSecondaryScreens.h"
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import "LBXDisplayCopy.h"
#import <objc/runtime.h>

static char SBSurfaceKey, SBRowKey, SBRowInteractionKey, SBObserverContext, SBTableObserverContext;
static UIStackView *SBStack(NSArray<UIView *> *views, BOOL horizontal, CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis=horizontal ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical;
    stack.spacing=spacing; return stack;
}
static void SBMove(UIView *view) {
    // A control's delegate, targets, tag, selection and object identity survive.
    // Only constraints crossing its old parent boundary are detached.
    for (UIView *ancestor=view.superview; ancestor; ancestor=ancestor.superview) {
        NSMutableArray *constraints=[NSMutableArray array];
        for(NSLayoutConstraint *constraint in ancestor.constraints)
            if(constraint.firstItem==view || constraint.secondItem==view) [constraints addObject:constraint];
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    if([view.superview isKindOfClass:UIStackView.class]) [(UIStackView *)view.superview removeArrangedSubview:view];
    [view removeFromSuperview]; view.translatesAutoresizingMaskIntoConstraints=NO;
}
static void SBPin(UIView *view, UIView *parent, CGFloat inset) {
    view.translatesAutoresizingMaskIntoConstraints=NO; [parent addSubview:view];
    [NSLayoutConstraint activateConstraints:@[[view.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [view.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [view.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [view.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]]];
}
static BOOL SBIsSecondary(SBScreen role) {
    return (role>=SBScreenCountry && role<=SBScreenGuide) || role==SBScreenSessions ||
        role==SBScreenSessionImport || role==SBScreenBulkCloudPush || role==SBScreenSessionExport || role==SBScreenSessionDestination;
}
static NSArray<NSString *> *SBScreenCopy(SBScreen role) {
    switch(role) {
        case SBScreenCountry: return @[SBUIText(@"picker.countryTitle"), SBUIText(@"picker.countryDetail")];
        case SBScreenCarrier: return @[SBUIText(@"home.carrier"), SBUIText(@"picker.carrierDetail")];
        case SBScreenModel: return @[SBUIText(@"picker.modelTitle"), SBUIText(@"picker.modelDetail")];
        case SBScreenVersion: return @[SBUIText(@"picker.versionTitle"), SBUIText(@"picker.versionDetail")];
        case SBScreenAllowedModels: return @[SBUIText(@"picker.allowedModelsTitle"), SBUIText(@"picker.allowedModelsDetail")];
        case SBScreenAppSelection: return @[SBUIText(@"picker.appsTitle"), SBUIText(@"picker.appsDetail")];
        case SBScreenBackups: return @[SBUIText(@"backups.title"), SBUIText(@"backups.detail")];
        case SBScreenCloud: return @[SBUIText(@"cloud.title"), SBUIText(@"cloud.detail")];
        case SBScreenCloudPush: return @[SBUIText(@"cloudPush.title"), SBUIText(@"cloudPush.detail")];
        case SBScreenSessionDetails: return @[SBUIText(@"sessions.title"), SBUIText(@"sessions.detail")];
        case SBScreenSessions: return @[SBUIText(@"sessionsList.title"), SBUIText(@"sessionsList.detail")];
        case SBScreenSessionImport: return @[SBUIText(@"sessionImport.title"), SBUIText(@"sessionImport.detail")];
        case SBScreenBulkCloudPush: return @[SBUIText(@"cloudBatch.title"), SBUIText(@"cloudBatch.detail")];
        case SBScreenSessionExport: return @[SBUIText(@"sessionExport.title"), SBUIText(@"sessionExport.detail")];
        case SBScreenSessionDestination: return @[SBUIText(@"sessionDestination.title"), SBUIText(@"sessionDestination.detail")];
        case SBScreenBulkProxyImport: return @[SBUIText(@"proxyImport.title"), SBUIText(@"proxyImport.detail")];
        case SBScreenGuide: return @[SBUIText(@"guide.title"), SBUIText(@"guide.detail")];
        default: return @[SBUIText(@"common.unavailable"), SBUIText(@"secondary.unsupportedDetail")];
    }
}

// Own geometric marker. No image resources or recovered drawing code are used.
@interface SBLineMark : UIView
@end
@implementation SBLineMark
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) { self.opaque=NO; self.userInteractionEnabled=NO; self.isAccessibilityElement=NO; }
    return self;
}
- (void)drawRect:(CGRect)rect {
    (void)rect;
    UIBezierPath *path=[UIBezierPath bezierPath]; path.lineWidth=2;
    CGFloat x=CGRectGetMidX(self.bounds),y=CGRectGetMidY(self.bounds);
    [path moveToPoint:CGPointMake(x-7,y-8)]; [path addLineToPoint:CGPointMake(x+6,y-8)];
    [path addLineToPoint:CGPointMake(x+6,y-2)]; [path addLineToPoint:CGPointMake(x-6,y-2)];
    [path addLineToPoint:CGPointMake(x-6,y+8)]; [path addLineToPoint:CGPointMake(x+7,y+8)];
    [SBAccent() setStroke]; [path stroke];
}
@end

// Public UIKit values are display inputs, never action identifiers. Bindings are
// discarded with a reused row; they do not cache or log any model/session value.
@interface SBTextBinding : NSObject
@property(nonatomic,strong) UILabel *source;
@property(nonatomic,weak) UILabel *target;
@property(nonatomic) LBXDisplayTextRole role;
@property(nonatomic,strong) UIColor *baseColor;
- (instancetype)initWithSource:(UILabel *)source target:(UILabel *)target;
- (void)refresh;
@end
@implementation SBTextBinding
- (instancetype)initWithSource:(UILabel *)source target:(UILabel *)target {
    if((self=[super init])) {
        _source=source; _target=target; _role=LBXDisplayTextRoleUserData; _baseColor=target.textColor;
        for(NSString *key in @[@"text",@"attributedText",@"hidden",@"textColor"])
            [source addObserver:self forKeyPath:key options:0 context:&SBObserverContext];
        [self refresh];
    } return self;
}
- (void)refresh {
    self.target.text=LBXDisplayText(self.source.text ?: self.source.attributedText.string ?: @"",self.role);
    self.target.hidden=self.source.hidden;
    CGFloat saturation=0; [self.source.textColor getHue:NULL saturation:&saturation brightness:NULL alpha:NULL];
    self.target.textColor=saturation>.42 ? self.source.textColor : self.baseColor;
}
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=&SBObserverContext) { [super observeValueForKeyPath:key ofObject:object change:change context:context]; return; }
    if(NSThread.isMainThread) [self refresh];
    else { __weak typeof(self) weak=self; dispatch_async(dispatch_get_main_queue(),^{ [weak refresh]; }); }
}
- (void)dealloc {
    for(NSString *key in @[@"text",@"attributedText",@"hidden",@"textColor"])
        [_source removeObserver:self forKeyPath:key context:&SBObserverContext];
}
@end

@interface SBRowContent : UIView
@property(nonatomic,strong) NSArray<UILabel *> *sources;
@property(nonatomic,strong) NSArray<UIView *> *controls;
@property(nonatomic,strong) NSArray<UIView *> *indicators;
@property(nonatomic,strong) NSMutableArray<SBTextBinding *> *bindings;
@property(nonatomic,strong) UIStackView *body;
@property(nonatomic,strong) UILabel *fixedTypeSource;
@property(nonatomic) BOOL available;
- (void)refresh;
@end
@implementation SBRowContent
- (void)refresh { for(SBTextBinding *binding in self.bindings) [binding refresh]; }
// The overlay is transparent to row taps/context menus, but contains the exact
// native buttons/switches in its own action slots. They remain the event senders.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit=[super hitTest:point withEvent:event];
    if(!self.available) return hit;
    for(UIView *control in self.controls)
        if(hit==control || [hit isDescendantOfView:control]) return hit;
    return nil;
}
@end

static void SBCollect(UIView *root, NSMutableArray *labels, NSMutableArray *controls,
                      NSMutableArray *indicators, NSMutableArray *decorations, BOOL *valid, NSUInteger depth) {
    if(depth>9 || labels.count>10 || controls.count>6 || decorations.count>80) { *valid=NO; return; }
    for(UIView *view in root.subviews) {
        if([view isKindOfClass:SBRowContent.class]) continue;
        if([view isKindOfClass:UIControl.class] || [view isKindOfClass:UITextView.class] || [view isKindOfClass:UISearchBar.class]) {
            if([view isKindOfClass:UIButton.class] || [view isKindOfClass:UISwitch.class] ||
               [view isKindOfClass:UISegmentedControl.class] || [view isKindOfClass:UITextView.class] ||
               [view isKindOfClass:UISearchBar.class]) [controls addObject:view];
            else *valid=NO;
            continue;
        }
        if([view isKindOfClass:UILabel.class]) {
            if(view.userInteractionEnabled || view.gestureRecognizers.count) *valid=NO;
            else [labels addObject:view];
            continue;
        }
        if([view isKindOfClass:UIImageView.class]) {
            if(view.userInteractionEnabled || view.gestureRecognizers.count) *valid=NO;
            // Custom table bodies use only native semantic status indicators;
            // the rows' own marker replaces ordinary decorative cell imagery.
            else if(((UIImageView *)view).image) [indicators addObject:view];
            continue;
        }
        if(view.gestureRecognizers.count) { *valid=NO; continue; }
        if([view isKindOfClass:UIActivityIndicatorView.class]) { [controls addObject:view]; continue; }
        if([view isKindOfClass:UIStackView.class] || [view isKindOfClass:UIVisualEffectView.class] ||
           [view isMemberOfClass:UIView.class]) {
            [decorations addObject:view]; SBCollect(view,labels,controls,indicators,decorations,valid,depth+1);
        } else *valid=NO;
    }
}
static BOOL SBRowShape(SBScreen role, NSUInteger labels, NSUInteger controls, NSUInteger indicators) {
    switch(role) {
        case SBScreenCountry: case SBScreenCarrier: return labels>=1 && labels<=3 && controls==0 && indicators<=1;
        case SBScreenModel: case SBScreenVersion: case SBScreenAllowedModels:
            return labels>=1 && labels<=3 && controls==0 && indicators<=1;
        case SBScreenAppSelection: return labels>=1 && labels<=4 && controls<=1 && indicators<=1;
        case SBScreenBackups: return labels>=1 && labels<=7 && controls<=4 && indicators<=1;
        case SBScreenCloud: case SBScreenCloudPush: return labels>=1 && labels<=4 && controls==0 && indicators<=2;
        case SBScreenSessionDetails: case SBScreenBulkProxyImport: return labels>=1 && labels<=3 && controls==0 && indicators<=1;
        case SBScreenSessions: case SBScreenSessionImport: case SBScreenBulkCloudPush:
        case SBScreenSessionExport: case SBScreenSessionDestination:
            return labels>=1 && labels<=3 && controls==0 && indicators<=1;
        default: return NO;
    }
}
static void SBStyleControl(UIView *control) {
    control.tintColor=SBAccent(); control.layer.shadowOpacity=0;
    if([control isKindOfClass:UIButton.class]) {
        UIButton *button=(id)control;
        // Style in place: leave title, menu, enabled state, targets and sender
        // identity intact, including actions tied to the control's tag.
        button.backgroundColor=SBPanel(); button.layer.cornerRadius=5;
        button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        if(button.configuration) { UIButtonConfiguration *config=[button.configuration copy];
            config.baseBackgroundColor=SBPanel(); config.baseForegroundColor=SBAccent();
            config.cornerStyle=UIButtonConfigurationCornerStyleSmall; button.configuration=config; }
    } else if([control isKindOfClass:UISwitch.class]) ((UISwitch *)control).onTintColor=SBAccent();
    else if([control isKindOfClass:UISegmentedControl.class]) ((UISegmentedControl *)control).selectedSegmentTintColor=SBAccent();
    else if([control isKindOfClass:UISearchBar.class]) {
        UISearchBar *search=(id)control; search.searchBarStyle=UISearchBarStyleMinimal;
        search.searchTextField.textColor=UIColor.whiteColor; search.searchTextField.backgroundColor=SBPanel();
    } else if([control isKindOfClass:UITextView.class]) {
        UITextView *input=(id)control; input.backgroundColor=SBPanel(); input.textColor=UIColor.whiteColor;
        input.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular]; input.layer.cornerRadius=5;
    } else if([control isKindOfClass:UITextField.class]) {
        UITextField *field=(id)control;field.backgroundColor=SBPanel();field.textColor=UIColor.whiteColor;
        field.font=[UIFont systemFontOfSize:15];field.layer.cornerRadius=5;
    }
}
// Original Backups cell builder 0x10006b1b0 appends filename, byte count,
// date, then a centered 10pt rounded type badge directly to BackupCell's
// contentView. An optional fifth label is its active-state marker. Only that
// proven fixed slot is eligible for mapping; identical filenames stay UserData.
static UILabel *SBBackupTypeLabel(UITableViewCell *cell) {
    if(![cell.reuseIdentifier isEqual:@"BackupCell"])return nil;
    NSMutableArray<UILabel *> *labels=[NSMutableArray array];
    for(UIView *view in cell.contentView.subviews)if([view isKindOfClass:UILabel.class])[labels addObject:(id)view];
    if(labels.count<4||labels.count>5)return nil;
    UILabel *type=labels[3];
    if(type.textAlignment!=NSTextAlignmentCenter||fabs(type.font.pointSize-10)>.01||
       fabs(type.layer.cornerRadius-4)>.01||!type.layer.masksToBounds||type.userInteractionEnabled||type.gestureRecognizers.count)return nil;
    return type;
}
static SBRowContent *SBBuildRow(UIView *carrier, SBScreen role, BOOL header, UILabel *fixedTypeSource, BOOL requireType) {
    SBRowContent *current=objc_getAssociatedObject(carrier,&SBRowKey);
    NSMutableArray *labels=[NSMutableArray array], *controls=[NSMutableArray array], *indicators=[NSMutableArray array], *decorations=[NSMutableArray array]; BOOL valid=YES;
    SBCollect(carrier,labels,controls,indicators,decorations,&valid,0);
    // Native controls moved into an earlier own layout still belong to this
    // carrier. Detached controls from a reuse teardown are never resurrected.
    for(UIView *control in current.controls) if([control isDescendantOfView:carrier]) [controls addObject:control];
    for(UIView *indicator in current.indicators) if([indicator isDescendantOfView:carrier]) [indicators addObject:indicator];
    valid=valid && (header ? (labels.count<=8 && controls.count<=4) : SBRowShape(role,labels.count,controls.count,indicators.count));
    if(requireType && !fixedTypeSource)valid=NO;
    if(current && current.superview==carrier && [current.sources isEqualToArray:labels] &&
       [current.controls isEqualToArray:controls] && [current.indicators isEqualToArray:indicators] && current.available==valid && current.fixedTypeSource==fixedTypeSource) {
        [current refresh]; [carrier bringSubviewToFront:current]; return current;
    }
    for(UIView *control in controls) if([control isDescendantOfView:current]) { SBMove(control); [carrier addSubview:control]; }
    for(UIView *indicator in indicators) if([indicator isDescendantOfView:current]) { SBMove(indicator); [carrier addSubview:indicator]; }
    [current removeFromSuperview];
    SBRowContent *row=[SBRowContent new]; row.available=valid; row.sources=labels; row.controls=controls; row.indicators=indicators;
    row.fixedTypeSource=fixedTypeSource;
    row.bindings=[NSMutableArray array]; row.backgroundColor=SBPanel(); row.accessibilityIdentifier=valid ? @"socialbox.secondary.row" : @"socialbox.secondary.row-unavailable";
    objc_setAssociatedObject(carrier,&SBRowKey,row,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Keep source labels alive for original refresh code; only their drawing is
    // suppressed. Reading or updating a label never selects its model.
    for(UILabel *label in labels) { label.alpha=0; label.accessibilityElementsHidden=YES; }
    for(UIView *decoration in decorations) { decoration.backgroundColor=UIColor.clearColor; decoration.layer.borderWidth=0; decoration.layer.shadowOpacity=0; }
    if(!valid) {
        UILabel *unavailable=SBLabel(SBUIText(@"secondary.rowUnavailable"),14,UIFontWeightRegular);
        unavailable.textColor=SBMuted(); SBPin(unavailable,row,14);
        for(UIView *child in carrier.subviews) child.hidden=YES;
        SBPin(row,carrier,0); return row;
    }
    UIStackView *text=SBStack(@[],NO,3); NSUInteger position=0;
    for(UILabel *source in labels) {
        UILabel *target=SBLabel(@"",position ? 12 : 15,position ? UIFontWeightRegular : UIFontWeightSemibold);
        target.textColor=position ? SBMuted() : UIColor.whiteColor;
        target.lineBreakMode=NSLineBreakByTruncatingTail; target.numberOfLines=position ? 2 : 1;
        SBTextBinding *binding=[[SBTextBinding alloc] initWithSource:source target:target];
        if(source==fixedTypeSource){binding.role=LBXDisplayTextRoleFixed;[binding refresh];}
        [row.bindings addObject:binding];
        [text addArrangedSubview:target]; position++;
    }
    SBLineMark *mark=[[SBLineMark alloc] initWithFrame:CGRectZero];
    [NSLayoutConstraint activateConstraints:@[[mark.widthAnchor constraintEqualToConstant:22],[mark.heightAnchor constraintEqualToConstant:26]]];
    UIStackView *top=SBStack(@[mark,text],YES,11); top.alignment=UIStackViewAlignmentCenter;
    // These are public native state indicators (selection/checkmark/app icon),
    // not packaged artwork. Keeping the actual image view preserves async
    // updates and the backend's selection-mode changes without guessing state.
    for(UIView *indicator in indicators) {
        SBMove(indicator); indicator.tintColor=SBAccent();
        [top addArrangedSubview:indicator]; [NSLayoutConstraint activateConstraints:@[
            [indicator.widthAnchor constraintEqualToConstant:22], [indicator.heightAnchor constraintEqualToConstant:22]]];
    }
    UIStackView *body=SBStack(@[top],NO,8); row.body=body;
    if(controls.count) {
        UIStackView *actions=SBStack(@[],controls.count<=4,7); actions.alignment=UIStackViewAlignmentCenter;
        for(UIView *control in controls) { SBMove(control); SBStyleControl(control); [actions addArrangedSubview:control]; }
        [body addArrangedSubview:actions];
    }
    body.translatesAutoresizingMaskIntoConstraints=NO; [row addSubview:body];
    [NSLayoutConstraint activateConstraints:@[[body.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [body.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [body.topAnchor constraintGreaterThanOrEqualToAnchor:row.topAnchor constant:9],
        [body.bottomAnchor constraintLessThanOrEqualToAnchor:row.bottomAnchor constant:-9],
        [body.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]]];
    SBPin(row,carrier,0); return row;
}

@interface SBSecondarySurface : UIView
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic) SBScreen role;
@property(nonatomic,strong) UITableView *table;
@property(nonatomic,strong) UIStackView *header;
@property(nonatomic,strong) UIView *tableHeader;
@property(nonatomic,strong) UIView *nativeHeader;
@property(nonatomic,strong) UILabel *emptyState;
@property(nonatomic) BOOL observingTable;
@property(nonatomic,strong) UIStackView *footer;
@property(nonatomic,strong) NSLayoutConstraint *footerEmptyHeight;
@property(nonatomic,strong) NSMutableArray<SBTextBinding *> *bindings;
@property(nonatomic,strong) NSMutableDictionary<NSString *,UIView *> *nativeControls;
@property(nonatomic,strong) NSMutableArray<UIView *> *nativeRoots;
@property(nonatomic) BOOL rootTable;
@property(nonatomic) BOOL unavailable;
@property(nonatomic) BOOL refreshing;
- (void)build;
- (void)refresh;
@end

static UIView *SBHeading(SBScreen role) {
    NSArray *copy=SBScreenCopy(role);
    UILabel *eyebrow=SBLabel(SBUIText(@"brand.eyebrow"),10,UIFontWeightBold); eyebrow.textColor=SBAccent();
    UILabel *title=SBLabel(copy[0],25,UIFontWeightBold);
    UILabel *detail=SBLabel(copy[1],13,UIFontWeightRegular); detail.textColor=SBMuted();
    return SBStack(@[eyebrow,title,detail],NO,7);
}
static UIView *SBUnavailableContent(void) {
    UILabel *title=SBLabel(SBUIText(@"secondary.unavailable"),23,UIFontWeightBold);
    UILabel *detail=SBLabel(SBUIText(@"secondary.unavailableDetail"),14,UIFontWeightRegular);
    detail.textColor=SBMuted();
    UIView *panel=SBStack(@[title,detail],NO,10); panel.accessibilityIdentifier=@"socialbox.secondary.unavailable"; return panel;
}
static NSArray *SBGuideSections(void) {
    return @[@[SBUIText(@"guide.accountsEyebrow"),SBUIText(@"guide.accountsTitle"),SBUIText(@"guide.accountsDetail")],
        @[SBUIText(@"guide.connectionsEyebrow"),SBUIText(@"guide.connectionsTitle"),SBUIText(@"guide.connectionsDetail")],
        @[SBUIText(@"guide.identityEyebrow"),SBUIText(@"guide.identityTitle"),SBUIText(@"guide.identityDetail")],
        @[SBUIText(@"guide.backupsEyebrow"),SBUIText(@"guide.backupsTitle"),SBUIText(@"guide.backupsDetail")],
        @[SBUIText(@"guide.sessionsEyebrow"),SBUIText(@"guide.sessionsTitle"),SBUIText(@"guide.sessionsDetail")],
        @[SBUIText(@"guide.checksEyebrow"),SBUIText(@"guide.checksTitle"),SBUIText(@"guide.checksDetail")]];
}
static UIView *SBGuideContent(void) {
    UIStackView *body=SBStack(@[SBHeading(SBScreenGuide)],NO,22);
    for(NSArray *section in SBGuideSections()) {
        UILabel *index=SBLabel(section[0],10,UIFontWeightBold); index.textColor=SBAccent();
        UILabel *title=SBLabel(section[1],18,UIFontWeightSemibold);
        UILabel *detail=SBLabel(section[2],14,UIFontWeightRegular); detail.textColor=SBMuted();
        UIStackView *card=SBStack(@[index,title,detail],NO,7); [body addArrangedSubview:card];
    }
    body.accessibilityIdentifier=@"socialbox.guide.content"; return body;
}
static void SBInstallScrollable(UIView *parent, UIView *content) {
    UIScrollView *scroll=[UIScrollView new]; scroll.alwaysBounceVertical=YES;
    scroll.translatesAutoresizingMaskIntoConstraints=NO; [parent addSubview:scroll];
    content.translatesAutoresizingMaskIntoConstraints=NO; [scroll addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[scroll.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:parent.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:parent.safeAreaLayoutGuide.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
}

@implementation SBSecondarySurface
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])) {
        self.backgroundColor=SBInk(); self.accessibilityIdentifier=@"socialbox.secondary.surface";
        _bindings=[NSMutableArray array]; _nativeControls=[NSMutableDictionary dictionary]; _nativeRoots=[NSMutableArray array];
    } return self;
}
- (void)addBoundLabel:(NSString *)key {
    UILabel *source=SBBackendReadObject(self.owner,key,NULL);
    if(![source isKindOfClass:UILabel.class]) return;
    SBMove(source); source.alpha=0; source.accessibilityElementsHidden=YES; source.translatesAutoresizingMaskIntoConstraints=YES; source.frame=CGRectZero; [self addSubview:source];
    UILabel *target=SBLabel(@"",13,UIFontWeightRegular); target.textColor=SBMuted();
    SBTextBinding *binding=[[SBTextBinding alloc] initWithSource:source target:target]; binding.role=LBXDisplayTextRoleStatus; [binding refresh];
    [self.bindings addObject:binding];
    [self.header addArrangedSubview:target];
}
- (void)addControl:(NSString *)key to:(UIStackView *)stack {
    UIView *view=SBBackendReadObject(self.owner,key,NULL);
    if(![view isKindOfClass:UIView.class]) return;
    if(self.nativeControls[key]==view && view.superview==stack) return;
    UIView *old=self.nativeControls[key]; if(old) { [stack removeArrangedSubview:old]; [old removeFromSuperview]; }
    self.nativeControls[key]=view; SBMove(view); SBStyleControl(view); [stack addArrangedSubview:view];
    if([view isKindOfClass:UITextView.class]) [view.heightAnchor constraintEqualToConstant:112].active=YES;
}
- (UIButton *)action:(NSString *)title key:(NSString *)key {
    __weak UIViewController *owner=self.owner;
    UIButtonConfiguration *config=UIButtonConfiguration.tintedButtonConfiguration;
    config.title=title; config.baseBackgroundColor=SBPanel(); config.baseForegroundColor=SBAccent();
    config.cornerStyle=UIButtonConfigurationCornerStyleSmall; config.contentInsets=NSDirectionalEdgeInsetsMake(9,10,9,10);
    UIButton *button=[UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        SBBackendInvoke(owner,key,nil,NULL);
    }]];
    button.enabled=SBBackendActionAvailable(self.owner,key,nil,NULL); return button;
}
- (void)build {
    self.role=SBBackendScreen(self.owner);
    if(self.role==SBScreenGuide) { SBInstallScrollable(self,SBGuideContent()); return; }
    self.table=SBBackendReadObject(self.owner,@"surface",NULL);
    self.unavailable=![self.table isKindOfClass:UITableView.class];
    if(self.role==SBScreenBulkCloudPush) {
        for(NSString *key in @[@"label",@"passphrase"])
            if(![SBBackendReadObject(self.owner,key,NULL) isKindOfClass:UITextField.class])self.unavailable=YES;
    }
    if(self.role==SBScreenSessionDestination && ![SBBackendReadObject(self.owner,@"search",NULL) isKindOfClass:UISearchBar.class]) self.unavailable=YES;
    if(self.role==SBScreenBulkProxyImport) {
        for(NSString *key in @[@"input",@"mode",@"detail",@"submit"])
            if(!SBBackendReadObject(self.owner,key,NULL)) self.unavailable=YES;
    }
    if(self.unavailable) { self.table=nil; SBInstallScrollable(self,SBUnavailableContent()); return; }
    self.rootTable=self.table==self.owner.view;
    self.header=SBStack(@[SBHeading(self.role)],NO,13);
    self.footer=SBStack(@[],NO,8);
    self.footerEmptyHeight=[self.footer.heightAnchor constraintEqualToConstant:0];
    self.nativeHeader=self.table.tableHeaderView;
    if(self.role==SBScreenBulkCloudPush) {
        // Read and move both exact getter-owned fields before detaching the
        // original header. Never copy values, replace delegates, or infer a
        // saved password. Original placeholders retain their saved-state cue.
        self.header.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:self.header];
        for(NSArray *entry in @[@[@"label",SBUIText(@"cloudBatch.label")],@[@"passphrase",SBUIText(@"cloudBatch.passphrase")]]) {
            UILabel *label=SBLabel(entry[1],12,UIFontWeightSemibold);label.textColor=SBMuted();
            [self.header addArrangedSubview:label];[self addControl:entry[0] to:self.header];
            self.nativeControls[entry[0]].accessibilityLabel=entry[1];
            [self.nativeControls[entry[0]].heightAnchor constraintGreaterThanOrEqualToConstant:40].active=YES;
        }
    }
    self.tableHeader=[UIView new]; self.tableHeader.backgroundColor=SBInk();
    SBPin(self.header,self.tableHeader,16); self.table.tableHeaderView=self.tableHeader;
    if(self.nativeHeader && self.role!=SBScreenBulkCloudPush) {
        // A documented info/filter header becomes a compact source-owned panel;
        // the original switch/search sender, where present, is retained.
        SBRowContent *content=SBBuildRow(self.nativeHeader,self.role,YES,nil,NO);
        [self.nativeHeader.heightAnchor constraintGreaterThanOrEqualToConstant:MAX(60,self.nativeHeader.bounds.size.height)].active=YES;
        [self.header addArrangedSubview:self.nativeHeader]; content.backgroundColor=SBInk();
    }
    if(self.role==SBScreenCountry || self.role==SBScreenCarrier || self.role==SBScreenBackups || self.role==SBScreenCloudPush || self.role==SBScreenSessionDestination)
        [self addControl:@"search" to:self.header];
    if(self.role==SBScreenBackups || self.role==SBScreenCloudPush) [self addBoundLabel:@"detail"];
    if(self.role==SBScreenCloudPush) [self addControl:@"filter" to:self.header];
    if(self.role==SBScreenSessionDetails) { [self addControl:@"mode" to:self.header]; [self addBoundLabel:@"loading"]; }
    if(self.role==SBScreenCloud) {
        [self addBoundLabel:@"quota"]; [self addBoundLabel:@"tier"];
        UIStackView *actions=SBStack(@[[self action:SBUIText(@"cloud.upload") key:@"cloud.pushHelp"],
            [self action:SBUIText(@"cloud.passphrase") key:@"cloud.passphrases"], [self action:SBUIText(@"cloud.reload") key:@"cloud.reload"]],YES,6);
        actions.distribution=UIStackViewDistributionFillEqually; [self.header addArrangedSubview:actions];
    }
    if(self.role==SBScreenBulkProxyImport) {
        [self addControl:@"input" to:self.header]; [self addControl:@"mode" to:self.header];
        [self addBoundLabel:@"detail"]; [self addControl:@"submit" to:self.footer];
    }
    [self addControl:@"activity" to:self.header];
    self.table.backgroundColor=SBInk(); self.table.separatorColor=[UIColor colorWithWhite:.20 alpha:1];
    self.table.separatorInset=UIEdgeInsetsMake(0,14,0,14); self.table.tintColor=SBAccent();
    self.table.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
    self.emptyState=SBLabel(SBUIText(@"secondary.empty"),15,UIFontWeightRegular);
    self.emptyState.textColor=SBMuted(); self.emptyState.textAlignment=NSTextAlignmentCenter;
    self.emptyState.accessibilityIdentifier=@"socialbox.secondary.empty";
    self.table.backgroundView=self.emptyState;
    [self.table addObserver:self forKeyPath:@"contentSize" options:0 context:&SBTableObserverContext]; self.observingTable=YES;
    if(!self.rootTable) {
        SBMove(self.table); [self addSubview:self.table];
        self.footer.translatesAutoresizingMaskIntoConstraints=NO; [self addSubview:self.footer];
        [NSLayoutConstraint activateConstraints:@[[self.table.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.table.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.table.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor],
            [self.table.bottomAnchor constraintEqualToAnchor:self.footer.topAnchor constant:-8],
            [self.footer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [self.footer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [self.footer.bottomAnchor constraintEqualToAnchor:self.keyboardLayoutGuide.topAnchor constant:-10]]];
    }
    [self refresh];
}
- (void)refresh {
    if(self.refreshing || self.unavailable || self.role==SBScreenGuide) return;
    self.refreshing=YES;
    for(SBTextBinding *binding in self.bindings) [binding refresh];
    NSInteger rows=0; for(NSInteger section=0;section<self.table.numberOfSections;section++) rows+=[self.table numberOfRowsInSection:section];
    self.emptyState.hidden=rows!=0;
    if(self.role==SBScreenCloud) {
        // Selection controls are created/removed by the native selection flow.
        // Put only its reviewed controls in our footer, preserving all senders.
        UIView *toolbar=SBBackendReadObject(self.owner,@"selectionToolbar",NULL);
        for(NSString *key in @[@"selectionDelete",@"selectionPull"]) {
            UIView *control=SBBackendReadObject(self.owner,key,NULL);
            if(toolbar && control && ([control isDescendantOfView:toolbar] || self.nativeControls[key]==control))
                [self addControl:key to:self.footer];
            UIView *installed=self.nativeControls[key];
            if(installed) installed.hidden=!toolbar;
        }
    }
    BOOL hasFooter=NO; for(UIView *view in self.footer.arrangedSubviews) if(!view.hidden) hasFooter=YES;
    self.footerEmptyHeight.active=!hasFooter;
    for(UITableViewCell *cell in self.table.visibleCells)
        SBSecondaryStyleTableCell(self.owner,self.table,cell,[self.table indexPathForCell:cell]);
    CGFloat width=MAX(self.table.bounds.size.width,280);
    self.tableHeader.bounds=CGRectMake(0,0,width,self.tableHeader.bounds.size.height);
    CGFloat height=[self.tableHeader systemLayoutSizeFittingSize:CGSizeMake(width,UILayoutFittingCompressedSize.height)
        withHorizontalFittingPriority:UILayoutPriorityRequired verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    height=MAX(height,80);
    if(fabs(self.tableHeader.frame.size.height-height)>.5 || self.table.tableHeaderView!=self.tableHeader) {
        self.tableHeader.frame=CGRectMake(0,0,width,height); self.table.tableHeaderView=self.tableHeader;
    }
    self.refreshing=NO;
}
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=&SBTableObserverContext) { [super observeValueForKeyPath:key ofObject:object change:change context:context]; return; }
    if(NSThread.isMainThread) [self refresh];
    else { __weak typeof(self) weak=self; dispatch_async(dispatch_get_main_queue(),^{ [weak refresh]; }); }
}
- (void)dealloc { if(_observingTable) [_table removeObserver:self forKeyPath:@"contentSize" context:&SBTableObserverContext]; }
- (void)layoutSubviews { [super layoutSubviews]; [self refresh]; }
@end

static void SBSecondaryNavigation(UIViewController *owner) {
    owner.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    UINavigationBar *bar=owner.navigationController.navigationBar;
    if([bar.standardAppearance.backgroundColor isEqual:SBInk()] && [bar.tintColor isEqual:SBAccent()]) {
        // Session import installs item-specific appearances. Keeping those
        // would override the owned navigation bar after entering this route.
        owner.navigationItem.standardAppearance=bar.standardAppearance;
        owner.navigationItem.scrollEdgeAppearance=bar.scrollEdgeAppearance;
        owner.navigationItem.compactAppearance=bar.compactAppearance;return;
    }
    UINavigationBarAppearance *appearance=[UINavigationBarAppearance new]; [appearance configureWithOpaqueBackground];
    appearance.backgroundColor=SBInk(); appearance.titleTextAttributes=@{NSForegroundColorAttributeName:UIColor.whiteColor};
    appearance.largeTitleTextAttributes=appearance.titleTextAttributes; appearance.shadowColor=UIColor.clearColor;
    bar.standardAppearance=appearance; bar.scrollEdgeAppearance=appearance; bar.compactAppearance=appearance; bar.tintColor=SBAccent();
    owner.navigationItem.standardAppearance=appearance;owner.navigationItem.scrollEdgeAppearance=appearance;owner.navigationItem.compactAppearance=appearance;
}
BOOL SBSecondaryApply(UIViewController *owner) {
    if(!NSThread.isMainThread || !owner.isViewLoaded || !SBIsSecondary(SBBackendScreen(owner))) return NO;
    SBSecondaryNavigation(owner);
    SBSecondarySurface *surface=objc_getAssociatedObject(owner,&SBSurfaceKey);
    if(!surface) {
        surface=[SBSecondarySurface new]; surface.owner=owner;
        objc_setAssociatedObject(owner,&SBSurfaceKey,surface,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Attach before moving getter-owned UIKit controls so every adapter
        // ownership check continues to see a descendant of the same owner.
        BOOL tableRoot=SBBackendReadObject(owner,@"surface",NULL)==owner.view;
        if(!tableRoot) SBPin(surface,owner.view,0);
        [surface build];
        if(surface.rootTable) {
            // UITableViewController's UIKit-owned table remains its root view.
            // Replacing owner.view would invalidate its inherited table getter.
            owner.view.backgroundColor=SBInk();
        } else {
            for(UIView *view in owner.view.subviews.copy) if(view!=surface) { view.hidden=YES; [surface.nativeRoots addObject:view]; }
        }
        owner.navigationItem.title=SBScreenCopy(surface.role)[0];
        owner.view.tintColor=SBAccent();
    }
    if(!surface.rootTable) {
        // Native refreshes may append new decoration to their old roots. Our
        // surface remains the visible root, including incompatibility states.
        for(UIView *view in owner.view.subviews) if(view!=surface) view.hidden=YES;
        surface.hidden=NO; [owner.view bringSubviewToFront:surface];
    }
    [surface refresh]; return YES;
}
void SBSecondaryRefresh(UIViewController *owner) { (void)SBSecondaryApply(owner); }
void SBSecondaryStyleTableCell(UIViewController *owner, UITableView *table, UITableViewCell *cell, NSIndexPath *indexPath) {
    (void)indexPath;
    if(!NSThread.isMainThread || !cell || !table) return;
    SBScreen role=SBBackendScreen(owner);
    if(!SBIsSecondary(role) || SBBackendReadObject(owner,@"surface",NULL)!=table) return;
    // The retained cell is still the data source's cell at the native index.
    // No replacement data source, delegate, selection index or model is created.
    cell.backgroundColor=SBPanel(); cell.contentView.backgroundColor=SBPanel(); cell.tintColor=SBAccent();
    UIView *selected=[UIView new]; selected.backgroundColor=[SBAccent() colorWithAlphaComponent:.13]; cell.selectedBackgroundView=selected;
    BOOL backupType=role==SBScreenBackups && [cell.reuseIdentifier isEqual:@"BackupCell"];
    SBRowContent *row=SBBuildRow(cell.contentView,role,NO,backupType?SBBackupTypeLabel(cell):nil,backupType);
    NSNumber *originalInteraction=objc_getAssociatedObject(cell,&SBRowInteractionKey);
    if(!row.available) {
        if(!originalInteraction) objc_setAssociatedObject(cell,&SBRowInteractionKey,@(cell.userInteractionEnabled),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.userInteractionEnabled=NO;
    } else if(originalInteraction) {
        cell.userInteractionEnabled=originalInteraction.boolValue; objc_setAssociatedObject(cell,&SBRowInteractionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
void SBSecondaryStyleTableHeader(UIViewController *owner, UITableView *table, UIView *header) {
    if(!NSThread.isMainThread || !header || !SBIsSecondary(SBBackendScreen(owner)) || SBBackendReadObject(owner,@"surface",NULL)!=table) return;
    UIView *carrier=header;
    if([header isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *section=(id)header;
        carrier=section.contentView;
    }
    // The bulk uploader's section UIView carries headerTapped: and its section
    // tag (0x1000c6ec8). Keep that exact view/gesture sender; replace drawing only.
    SBRowContent *row=SBBuildRow(carrier,SBBackendScreen(owner),YES,nil,NO);row.backgroundColor=SBInk();
    NSNumber *interaction=objc_getAssociatedObject(header,&SBRowInteractionKey);
    if(!row.available){
        if(!interaction)objc_setAssociatedObject(header,&SBRowInteractionKey,@(header.userInteractionEnabled),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        header.userInteractionEnabled=NO;
    }else if(interaction){header.userInteractionEnabled=interaction.boolValue;objc_setAssociatedObject(header,&SBRowInteractionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
}
NSDictionary<NSString *,id> *SBSecondaryStatus(void) {
    return @{@"implementation":@"source-owned secondary screens", @"nativeInteractionCarriers":@YES,
        @"renderStartsBackendAction":@NO, @"localGuide":@YES, @"mismatchPresentation":@"unavailable"};
}
@implementation SBGuideViewController
- (void)loadView { self.view=[UIView new]; self.view.backgroundColor=SBInk(); self.view.tintColor=SBAccent(); }
- (void)viewDidLoad { [super viewDidLoad]; self.title=SBUIText(@"guide.navigation"); SBSecondaryNavigation(self); SBInstallScrollable(self.view,SBGuideContent()); }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; SBSecondaryNavigation(self); }
@end
