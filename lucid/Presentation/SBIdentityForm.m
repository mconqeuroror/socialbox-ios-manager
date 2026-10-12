#import "SBInterfaceCopy.h"
#import "SBIdentityForm.h"
#import "SBBackendAdapter.h"
#import "SBDesign.h"
#import "LBXDisplayCopy.h"
#import <objc/runtime.h>

// Reviewed public UIKit boundary: the original identity builders construct
// caption/value picker cards with a tap recognizer, tagged/native switches,
// one Range/Specific segmented control and a regeneration button. Evidence:
// WORKSPACE_CONTRACT.md; original builder offsets 0x1000d5cdc, 0x1000d6358,
// 0x1000d6a70, 0x1000d7c5c, 0x1000d8320, 0x1000db43c; card builders
// 0x1000d9800/0x1000d9f64. Only their control shape is used, never their layout.
// No private getter/action names, storage, configuration or generator live here.
static char IdentityFormKey, IdentityLabelObservation;

typedef NS_ENUM(NSUInteger, SBIdentityFieldKind) { SBIdentityPicker, SBIdentityToggle, SBIdentityMode, SBIdentityRegenerate };
@interface SBIdentityField : NSObject
@property(nonatomic,copy) NSString *key;
@property(nonatomic) SBIdentityFieldKind kind;
@property(nonatomic,strong) UIView *carrier;
@property(nonatomic,strong) UILabel *value;
@property(nonatomic,strong) UIControl *control;
@end
@implementation SBIdentityField @end

@interface SBIdentityPlan : NSObject
@property(nonatomic,strong) NSMutableDictionary<NSString *,SBIdentityField *> *fields;
@property(nonatomic,strong) NSMutableArray<NSString *> *reasons;
@property(nonatomic,strong) NSArray<UILabel *> *compatibility;
@property(nonatomic,strong) UIColor *compatibilityColor;
@property(nonatomic) NSUInteger inspected;
@end
@implementation SBIdentityPlan
- (instancetype)init { if((self=[super init])) { _fields=[NSMutableDictionary dictionary]; _reasons=[NSMutableArray array]; } return self; }
@end
static void Issue(SBIdentityPlan *plan, NSString *code) {
    if(plan.reasons.count<16 && ![plan.reasons containsObject:code]) [plan.reasons addObject:code];
}
static NSArray<NSString *> *FieldCopy(NSString *key) {
    return (@{
        @"country":@[SBUIText(@"picker.countryTitle"),SBUIText(@"identity.countryDetail")],
        @"carrier":@[SBUIText(@"identity.carrierTitle"),SBUIText(@"identity.carrierDetail")],
        @"language":@[SBUIText(@"identity.languageTitle"),SBUIText(@"identity.languageDetail")],
        @"model.mode":@[SBUIText(@"identity.modelModeTitle"),SBUIText(@"identity.modelModeDetail")],
        @"model.min":@[SBUIText(@"identity.modelMinTitle"),SBUIText(@"identity.modelMinDetail")],
        @"model.max":@[SBUIText(@"identity.modelMaxTitle"),SBUIText(@"identity.modelMaxDetail")],
        @"model.allowed":@[SBUIText(@"picker.allowedModelsTitle"),SBUIText(@"identity.allowedModelsDetail")],
        @"system.min":@[SBUIText(@"identity.systemMinTitle"),SBUIText(@"identity.systemMinDetail")],
        @"system.max":@[SBUIText(@"identity.systemMaxTitle"),SBUIText(@"identity.systemMaxDetail")],
        @"lock.model":@[SBUIText(@"identity.lockModelTitle"),SBUIText(@"identity.lockModelDetail")],
        @"current.model":@[SBUIText(@"identity.currentModelTitle"),SBUIText(@"identity.currentModelDetail")],
        @"lock.system":@[SBUIText(@"identity.lockSystemTitle"),SBUIText(@"identity.lockSystemDetail")],
        @"current.system":@[SBUIText(@"identity.currentSystemTitle"),SBUIText(@"identity.currentSystemDetail")],
        @"regenerate":@[SBUIText(@"identity.regenerateTitle"),SBUIText(@"identity.regenerateDetail")]
    })[key];
}
// Exact static captions establish presentation roles only. User values are never
// compared against this catalog, translated, parsed as IDs or used as actions.
static NSString *Section(NSString *text) {
    return (@{@"COUNTRY / REGION":@"region",@"CARRIER":@"carrier",@"APP LANGUAGE":@"language",@"MODEL":@"model",
        @"IOS VERSION RANGE":@"system",@"LOCK VALUES":@"locks",@"OTHER IDENTIFIERS":@"other"})[text];
}
static NSString *PickerKey(NSString *section, NSString *caption) {
    return (@{@"region|COUNTRY":@"country",@"carrier|PROVIDER":@"carrier",@"language|UI LANGUAGE":@"language",
        @"model|FROM":@"model.min",@"model|TO":@"model.max",@"model|ALLOWED MODELS":@"model.allowed",
        @"system|FROM":@"system.min",@"system|TO":@"system.max",
        @"locks|CURRENT MODEL":@"current.model",@"locks|CURRENT VERSION":@"current.system"})
        [[NSString stringWithFormat:@"%@|%@",section ?: @"",caption ?: @""]];
}
static BOOL Footer(NSString *section, NSString *text) {
    NSDictionary *catalog=@{
        @"region":@[@"Carrier name, MCC/MNC match region."],
        @"carrier":@[@"Lock the carrier across all containers. Leave on 'Random per seed' to let the server pick a carrier from the country pool each time."],
        @"model":@[@"Fingerprint picks a random model from this range.",@"Fingerprint picks one model from this discrete list. Empty list falls back to Range."],
        @"system":@[@"Server picks a random patch within this range based on your device seed. Use LOCK VALUES below to pin an exact patch."],
        @"locks":@[@"Regenerate re-asks the server using lock/range rules above. Same seed; IDs stay unless the server changes them."]};
    if([catalog[section ?: @""] containsObject:text]) return YES;
    // Reviewed application-language footer has a product-name slot. Its content
    // is not displayed or used as authority; our language-field description above
    // states the scope. No value label is evaluated by this predicate.
    return [section isEqual:@"language"] && [text hasPrefix:@"Override the "] &&
        [text hasSuffix:@"UI language independently of spoof country. `auto` = follow system + country. Does NOT affect spoofed device values."];
}
static NSString *LabelText(UILabel *label) { return label.text ?: label.attributedText.string ?: @""; }

// Inspect only known public UIKit leaves. Effect implementation subviews are
// deliberately skipped by inspecting contentView. No gesture targets/private
// association, dynamic selector, model dictionary or arbitrary KVC is read.
static BOOL Collect(UIView *root, NSMutableArray *labels, NSMutableArray *controls, NSMutableArray *images, NSUInteger depth) {
    if(depth>8 || labels.count>8 || controls.count>3 || images.count>3) return NO;
    UIView *content=[root isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)root).contentView : root;
    for(UIView *view in content.subviews) {
        if([view isKindOfClass:UILabel.class]) {
            if(view.gestureRecognizers.count || view.userInteractionEnabled || LabelText((id)view).length>4096) return NO;
            [labels addObject:view];
        } else if([view isKindOfClass:UISwitch.class] || [view isKindOfClass:UISegmentedControl.class] || [view isKindOfClass:UIButton.class]) {
            [controls addObject:view];
        } else if([view isKindOfClass:UIImageView.class]) {
            if(view.gestureRecognizers.count || view.userInteractionEnabled) return NO;
            [images addObject:view];
        } else if([view isMemberOfClass:UIView.class] || [view isKindOfClass:UIStackView.class] || [view isKindOfClass:UIVisualEffectView.class]) {
            if(view.gestureRecognizers.count || !Collect(view,labels,controls,images,depth+1)) return NO;
        } else return NO;
    }
    return labels.count<=8 && controls.count<=3 && images.count<=3;
}
static BOOL NativeControl(UIControl *control, UIViewController *owner, UIControlEvents event) {
    return [control.allTargets containsObject:owner] && (control.allControlEvents & event)==event;
}
static void AddField(SBIdentityPlan *plan, NSString *key, SBIdentityFieldKind kind, UIView *carrier, UILabel *value, UIControl *control) {
    if(!key || plan.fields[key]) { Issue(plan,@"SB-ID-DUPLICATE-ROLE"); return; }
    SBIdentityField *field=[SBIdentityField new]; field.key=key; field.kind=kind;
    field.carrier=carrier; field.value=value; field.control=control; plan.fields[key]=field;
}
static void Inspect(UIView *view, NSString **section, UIViewController *owner, SBIdentityPlan *plan, NSUInteger depth) {
    if(++plan.inspected>160 || depth>5) { Issue(plan,@"SB-ID-LAYOUT-LIMIT"); return; }
    if([view isKindOfClass:UILabel.class]) {
        NSString *text=LabelText((id)view), *next=Section(text);
        if(view.gestureRecognizers.count || view.userInteractionEnabled) Issue(plan,@"SB-ID-INTERACTIVE-CAPTION");
        else if(next) *section=next;
        else if(!Footer(*section,text)) Issue(plan,@"SB-ID-UNKNOWN-CAPTION");
        return;
    }
    if([view isKindOfClass:UIStackView.class] && !view.gestureRecognizers.count) {
        for(UIView *child in ((UIStackView *)view).arrangedSubviews) Inspect(child,section,owner,plan,depth+1);
        return;
    }
    if([view isKindOfClass:UIButton.class]) {
        UIButton *button=(id)view;
        if([*section isEqual:@"locks"] && [button.currentTitle isEqual:@"Regenerate Identity"] && NativeControl(button,owner,UIControlEventTouchUpInside))
            AddField(plan,@"regenerate",SBIdentityRegenerate,view,nil,button);
        else Issue(plan,@"SB-ID-UNKNOWN-BUTTON");
        return;
    }
    if(![view isMemberOfClass:UIView.class] && ![view isKindOfClass:UIVisualEffectView.class]) { Issue(plan,@"SB-ID-UNKNOWN-SURFACE"); return; }
    NSMutableArray *labels=[NSMutableArray array],*controls=[NSMutableArray array],*images=[NSMutableArray array];
    if(!Collect(view,labels,controls,images,0)) { Issue(plan,@"SB-ID-UNKNOWN-CONTROL"); return; }
    if(view.gestureRecognizers.count) {
        UIGestureRecognizer *gesture=view.gestureRecognizers.firstObject;
        if(view.gestureRecognizers.count!=1 || ![gesture isKindOfClass:UITapGestureRecognizer.class] || labels.count!=2 || controls.count || images.count!=1) {
            Issue(plan,@"SB-ID-PICKER-SHAPE"); return;
        }
        NSString *key=PickerKey(*section,LabelText(labels[0]));
        if(!key) { Issue(plan,@"SB-ID-UNKNOWN-PICKER"); return; }
        AddField(plan,key,SBIdentityPicker,view,labels[1],nil); return;
    }
    if(controls.count==1 && [controls[0] isKindOfClass:UISegmentedControl.class] && !labels.count && !images.count) {
        UISegmentedControl *mode=controls[0];
        if(![*section isEqual:@"model"] || mode.numberOfSegments!=2 || ![[mode titleForSegmentAtIndex:0] isEqual:@"Range"] ||
            ![[mode titleForSegmentAtIndex:1] isEqual:@"Specific"] || mode.selectedSegmentIndex<0 || mode.selectedSegmentIndex>1 || !NativeControl(mode,owner,UIControlEventValueChanged))
            Issue(plan,@"SB-ID-MODE-CONTRACT");
        else AddField(plan,@"model.mode",SBIdentityMode,view,nil,mode);
        return;
    }
    if(controls.count==1 && [controls[0] isKindOfClass:UISwitch.class] && labels.count==2 && !images.count && [*section isEqual:@"locks"]) {
        NSString *title=LabelText(labels[0]),*subtitle=LabelText(labels[1]);
        NSString *key=([title isEqual:@"Lock Device Model"] && [subtitle isEqual:@"Keep exact model on regenerate"]) ? @"lock.model" :
            ([title isEqual:@"Lock iOS Version"] && [subtitle isEqual:@"Keep exact version on regenerate"]) ? @"lock.system" : nil;
        if(!key || !NativeControl(controls[0],owner,UIControlEventValueChanged)) Issue(plan,@"SB-ID-TOGGLE-CONTRACT");
        else AddField(plan,key,SBIdentityToggle,view,nil,controls[0]);
        return;
    }
    if(!*section && labels.count==2 && !controls.count && images.count==1 && !plan.compatibility) {
        plan.compatibility=[labels copy]; plan.compatibilityColor=((UIImageView *)images[0]).tintColor; return;
    }
    if([*section isEqual:@"other"] && labels.count==2 && !controls.count && !images.count &&
        [LabelText(labels[0]) isEqual:@"Auto-Generated Values"] && [LabelText(labels[1]) isEqual:@"Serial, UDID, MAC, IMEI, Ads ID"]) return;
    Issue(plan,@"SB-ID-UNSUPPORTED-ROW");
}
static SBIdentityPlan *Plan(UIStackView *source, UILabel *country, UIViewController *owner) {
    SBIdentityPlan *plan=[SBIdentityPlan new]; NSString *section=nil;
    for(UIView *view in [source.arrangedSubviews copy]) Inspect(view,&section,owner,plan,0);
    for(NSString *key in @[@"country",@"carrier",@"language",@"model.mode",@"system.min",@"system.max",@"lock.model",@"current.model",@"lock.system",@"current.system",@"regenerate"])
        if(!plan.fields[key]) Issue(plan,@"SB-ID-MISSING-FIELD");
    if(!plan.compatibility) Issue(plan,@"SB-ID-MISSING-COMPATIBILITY");
    if(plan.fields[@"country"].value!=country) Issue(plan,@"SB-ID-COUNTRY-ANCHOR");
    UISegmentedControl *mode=(id)plan.fields[@"model.mode"].control;
    BOOL range=plan.fields[@"model.min"] && plan.fields[@"model.max"] && !plan.fields[@"model.allowed"];
    BOOL specific=plan.fields[@"model.allowed"] && !plan.fields[@"model.min"] && !plan.fields[@"model.max"];
    if(!mode || (mode.selectedSegmentIndex==0 ? !range : !specific)) Issue(plan,@"SB-ID-CONDITIONAL-FIELDS");
    return plan;
}

static UIStackView *Stack(NSArray *views, BOOL horizontal, CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis=horizontal ? UILayoutConstraintAxisHorizontal : UILayoutConstraintAxisVertical; stack.spacing=spacing; return stack;
}
static void Move(UIView *view) {
    for(UIView *parent=view.superview;parent;parent=parent.superview) {
        NSMutableArray *constraints=[NSMutableArray array];
        for(NSLayoutConstraint *constraint in parent.constraints) if(constraint.firstItem==view || constraint.secondItem==view) [constraints addObject:constraint];
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    if([view.superview isKindOfClass:UIStackView.class]) [(UIStackView *)view.superview removeArrangedSubview:view];
    [view removeFromSuperview]; view.translatesAutoresizingMaskIntoConstraints=NO;
}
static void Pin(UIView *content, UIView *parent, CGFloat inset) {
    content.translatesAutoresizingMaskIntoConstraints=NO; [parent addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],
        [content.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],
        [content.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],
        [content.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]]];
}
static void ClearDecorations(UIView *view) {
    [NSLayoutConstraint deactivateConstraints:view.constraints];
    UIView *content=view;
    if([view isKindOfClass:UIVisualEffectView.class]) { ((UIVisualEffectView *)view).effect=nil; content=((UIVisualEffectView *)view).contentView; [NSLayoutConstraint deactivateConstraints:content.constraints]; }
    for(UIView *child in content.subviews) { child.alpha=0; }
    view.backgroundColor=SBPanel(); view.layer.cornerRadius=6; view.layer.borderWidth=0; view.layer.shadowOpacity=0;
    // Existing images/layers stay attached for backend ownership, but no original
    // gradient, card artwork or old typography is used to draw the new field.
    for(CALayer *layer in view.layer.sublayers) if([layer isKindOfClass:CAGradientLayer.class]) layer.hidden=YES;
}

@interface SBIdentityBinding:NSObject
@property(nonatomic,strong) UILabel *source;
@property(nonatomic,weak) UILabel *target;
@property(nonatomic,weak) UIView *carrier;
@property(nonatomic) LBXDisplayTextRole role;
- (void)refresh;
@end
@implementation SBIdentityBinding
- (instancetype)initWithSource:(UILabel *)source target:(UILabel *)target carrier:(UIView *)carrier role:(LBXDisplayTextRole)role {
    if((self=[super init])) { _source=source; _target=target; _carrier=carrier; _role=role;
        for(NSString *key in @[@"text",@"attributedText",@"hidden",@"textColor"]) [source addObserver:self forKeyPath:key options:0 context:&IdentityLabelObservation];
        [self refresh]; } return self;
}
- (void)refresh {
    NSString *text=LabelText(self.source); self.target.text=LBXDisplayText(text,self.role); self.target.hidden=self.source.hidden;
    self.carrier.accessibilityValue=text;
    if(self.role!=LBXDisplayTextRoleUserData) { CGFloat saturation=0; [self.source.textColor getHue:NULL saturation:&saturation brightness:NULL alpha:NULL]; self.target.textColor=saturation>.4 ? self.source.textColor : SBMuted(); }
}
- (void)observeValueForKeyPath:(NSString *)key ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if(context!=&IdentityLabelObservation) { [super observeValueForKeyPath:key ofObject:object change:change context:context]; return; }
    if(NSThread.isMainThread) [self refresh]; else { __weak typeof(self) weak=self; dispatch_async(dispatch_get_main_queue(),^{ [weak refresh]; }); }
}
- (void)dealloc { for(NSString *key in @[@"text",@"attributedText",@"hidden",@"textColor"]) [_source removeObserver:self forKeyPath:key context:&IdentityLabelObservation]; }
@end

@interface SBIdentityForm:UIView
@property(nonatomic,weak) UIViewController *owner;
@property(nonatomic,strong) UIStackView *source;
@property(nonatomic,strong) NSArray *remainingSourceViews;
@property(nonatomic,strong) UIStackView *body;
@property(nonatomic,strong) UIScrollView *scroll;
@property(nonatomic,strong) NSMutableArray<SBIdentityBinding *> *bindings;
@property(nonatomic,strong) SBIdentityPlan *plan;
@property(nonatomic) BOOL rebuilding;
- (void)refresh;
@end
@implementation SBIdentityForm
- (instancetype)initWithOwner:(UIViewController *)owner {
    if((self=[super initWithFrame:CGRectZero])) { _owner=owner; _bindings=[NSMutableArray array]; self.backgroundColor=SBInk(); self.accessibilityIdentifier=@"socialbox.identity.form";
        self.scroll=[UIScrollView new]; self.scroll.alwaysBounceVertical=YES; self.scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive; Pin(self.scroll,self,0);
        self.body=Stack(@[],NO,16); self.body.translatesAutoresizingMaskIntoConstraints=NO; [self.scroll addSubview:self.body];
        [NSLayoutConstraint activateConstraints:@[[self.body.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:20],
            [self.body.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-20],
            [self.body.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:24],
            [self.body.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-28],
            [self.body.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    } return self;
}
- (void)heading:(NSString *)title {
    UILabel *label=SBLabel(title,13,UIFontWeightBold); label.textColor=SBAccent(); [self.body addArrangedSubview:label];
}
- (void)bind:(UILabel *)source target:(UILabel *)target carrier:(UIView *)carrier role:(LBXDisplayTextRole)role {
    [self.bindings addObject:[[SBIdentityBinding alloc] initWithSource:source target:target carrier:carrier role:role]];
}
- (UIView *)field:(SBIdentityField *)field {
    NSArray *copy=FieldCopy(field.key); UILabel *title=SBLabel(copy[0],16,UIFontWeightSemibold);
    UILabel *detail=SBLabel(copy[1],12,UIFontWeightRegular); detail.textColor=SBMuted();
    if(field.kind==SBIdentityPicker) {
        UIView *carrier=field.carrier; Move(carrier); ClearDecorations(carrier);
        UILabel *value=SBLabel(@"",18,UIFontWeightMedium); value.accessibilityIdentifier=[@"socialbox.identity.value." stringByAppendingString:field.key];
        [self bind:field.value target:value carrier:carrier role:LBXDisplayTextRoleUserData];
        UILabel *indicator=SBLabel(@"›",27,UIFontWeightRegular); indicator.textColor=SBAccent(); indicator.isAccessibilityElement=NO;
        UIStackView *text=Stack(@[title,value,detail],NO,5), *row=Stack(@[text,indicator],YES,12); row.alignment=UIStackViewAlignmentCenter;
        [indicator setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal]; row.userInteractionEnabled=NO;
        UIView *content=[carrier isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)carrier).contentView : carrier;
        Pin(row,content,16); carrier.accessibilityIdentifier=[@"socialbox.identity.field." stringByAppendingString:field.key]; carrier.accessibilityLabel=copy[0];
        return carrier;
    }
    UIControl *control=field.control; Move(control); control.tintColor=SBAccent();
    UIStackView *text=Stack(@[title,detail],NO,5), *content=nil;
    if(field.kind==SBIdentityToggle) {
        ((UISwitch *)control).onTintColor=SBAccent(); content=Stack(@[text,control],YES,14); content.alignment=UIStackViewAlignmentCenter;
        [control setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    } else if(field.kind==SBIdentityMode) {
        UISegmentedControl *mode=(id)control; [mode setTitle:SBUIText(@"identity.rangeMode") forSegmentAtIndex:0]; [mode setTitle:SBUIText(@"identity.listMode") forSegmentAtIndex:1];
        mode.selectedSegmentTintColor=SBAccent(); content=Stack(@[text,mode],NO,12);
    } else {
        UIButton *button=(id)control; UIButtonConfiguration *config=UIButtonConfiguration.filledButtonConfiguration;
        config.title=copy[0]; config.baseBackgroundColor=SBAccent(); config.baseForegroundColor=SBInk();
        config.cornerStyle=UIButtonConfigurationCornerStyleMedium; config.contentInsets=NSDirectionalEdgeInsetsMake(16,16,16,16); button.configuration=config;
        [button setTitle:copy[0] forState:UIControlStateNormal]; button.titleLabel.adjustsFontForContentSizeCategory=YES;
        content=Stack(@[button,detail],NO,9);
    }
    control.accessibilityLabel=copy[0]; control.accessibilityIdentifier=[@"socialbox.identity.control." stringByAppendingString:field.key];
    UIView *panel=[UIView new]; panel.backgroundColor=SBPanel(); panel.layer.cornerRadius=6; panel.hidden=field.carrier.hidden; Pin(content,panel,16);
    return panel;
}
- (void)rebuildWithSource:(UIStackView *)source country:(UILabel *)country {
    self.rebuilding=YES;
    SBIdentityPlan *plan=source && country ? Plan(source,country,self.owner) : [SBIdentityPlan new];
    if(!source || !country) Issue(plan,@"SB-ID-SOURCE-UNAVAILABLE");
    [self.bindings removeAllObjects];
    for(UIView *view in [self.body.arrangedSubviews copy]) { [self.body removeArrangedSubview:view]; [view removeFromSuperview]; }
    self.plan=plan; self.source=source;
    [self.body addArrangedSubview:SBLabel(SBUIText(@"identity.title"),28,UIFontWeightBold)];
    UILabel *scope=SBLabel(SBUIText(@"identity.scope"),14,UIFontWeightRegular);
    scope.textColor=SBMuted(); scope.accessibilityIdentifier=@"socialbox.identity.scope"; [self.body addArrangedSubview:scope];
    if(plan.reasons.count) {
        [self heading:SBUIText(@"identity.unavailable")];
        [self.body addArrangedSubview:SBLabel(SBUIText(@"identity.unavailableDetail"),15,UIFontWeightRegular)];
        UILabel *code=SBLabel([plan.reasons componentsJoinedByString:@" · "],11,UIFontWeightRegular); code.textColor=SBMuted(); [self.body addArrangedSubview:code];
    } else {
        [self heading:SBUIText(@"identity.compatibility")];
        for(UILabel *sourceLabel in plan.compatibility) {
            UILabel *label=SBLabel(@"",14,UIFontWeightRegular);
            [self bind:sourceLabel target:label carrier:nil role:LBXDisplayTextRoleStatus]; [self.body addArrangedSubview:label];
        }
        NSArray *groups=@[@[SBUIText(@"identity.regionGroup"),@[@"country",@"carrier",@"language"]],
            @[SBUIText(@"identity.modelGroup"),@[@"model.mode",@"model.min",@"model.max",@"model.allowed"]],
            @[SBUIText(@"identity.systemGroup"),@[@"system.min",@"system.max"]],
            @[SBUIText(@"identity.locksGroup"),@[@"lock.model",@"current.model",@"lock.system",@"current.system"]],
            @[SBUIText(@"identity.applyGroup"),@[@"regenerate"]]];
        for(NSArray *group in groups) { [self heading:group[0]]; for(NSString *key in group[1]) if(plan.fields[key]) [self.body addArrangedSubview:[self field:plan.fields[key]]]; }
        UILabel *note=SBLabel(SBUIText(@"identity.otherDetail"),12,UIFontWeightRegular);
        note.textColor=SBMuted(); [self.body addArrangedSubview:note];
    }
    self.remainingSourceViews=[source.arrangedSubviews copy] ?: @[];
    self.scroll.contentOffset=CGPointZero; self.rebuilding=NO;
}
- (void)refresh {
    if(self.rebuilding) return;
    UIStackView *source=SBBackendReadObject(self.owner,@"surface",NULL);
    UILabel *country=SBBackendReadObject(self.owner,@"identity.country",NULL);
    if(![source isKindOfClass:UIStackView.class]) source=nil;
    if(![country isKindOfClass:UILabel.class]) country=nil;
    if(!self.plan || self.source!=source || ![self.remainingSourceViews isEqual:source.arrangedSubviews ?: @[]])
        [self rebuildWithSource:source country:country];
    else for(SBIdentityBinding *binding in self.bindings) [binding refresh];
}
@end

BOOL SBIdentityApply(UIViewController *owner) {
    if(!NSThread.isMainThread || SBBackendScreen(owner)!=SBScreenIdentity || !owner.isViewLoaded) return NO;
    SBIdentityForm *form=objc_getAssociatedObject(owner,&IdentityFormKey);
    if(!form) {
        form=[[SBIdentityForm alloc] initWithOwner:owner];
        for(UIView *view in owner.view.subviews) view.hidden=YES;
        form.translatesAutoresizingMaskIntoConstraints=NO; [owner.view addSubview:form];
        [NSLayoutConstraint activateConstraints:@[[form.leadingAnchor constraintEqualToAnchor:owner.view.leadingAnchor],
            [form.trailingAnchor constraintEqualToAnchor:owner.view.trailingAnchor], [form.topAnchor constraintEqualToAnchor:owner.view.safeAreaLayoutGuide.topAnchor],
            [form.bottomAnchor constraintEqualToAnchor:owner.view.keyboardLayoutGuide.topAnchor]]];
        objc_setAssociatedObject(owner,&IdentityFormKey,form,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        owner.navigationItem.title=SBUIText(@"identity.navigation"); owner.navigationItem.titleView=nil;
    }
    [form refresh]; return YES;
}
void SBIdentityRefresh(UIViewController *owner) {
    if(!NSThread.isMainThread || SBBackendScreen(owner)!=SBScreenIdentity) return;
    [objc_getAssociatedObject(owner,&IdentityFormKey) refresh];
}
NSDictionary *SBIdentityStatus(UIViewController *owner) {
    if(!NSThread.isMainThread) return @{@"available":@NO,@"reasonCodes":@[@"SB-ID-MAIN-THREAD"],@"fieldCount":@0};
    SBIdentityForm *form=objc_getAssociatedObject(owner,&IdentityFormKey);
    return @{@"available":@(form.plan && !form.plan.reasons.count),@"reasonCodes":form.plan.reasons ?: @[@"SB-ID-NOT-INSTALLED"],
        @"fieldCount":@(form.plan.fields.count),@"scope":@"shared-rules-current-session",@"runtimeVerified":@NO};
}
