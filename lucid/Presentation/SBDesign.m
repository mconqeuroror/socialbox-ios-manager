#import "SBInterfaceCopy.h"
#import "SBDesign.h"
#import <objc/runtime.h>
UIColor *SBInk(void) { return [UIColor colorWithRed:.055 green:.068 blue:.078 alpha:1]; }
UIColor *SBPanel(void) { return [UIColor colorWithRed:.092 green:.111 blue:.123 alpha:1]; }
UIColor *SBAccent(void) { return [UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1]; }
UIColor *SBMuted(void) { return [UIColor colorWithRed:.61 green:.68 blue:.69 alpha:1]; }
UIImage *SBGlyph(NSString *name) {
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26,26)];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c=ctx.CGContext;CGContextSetLineWidth(c,1.8);CGContextSetLineCap(c,kCGLineCapRound);
        CGContextSetStrokeColorWithColor(c,UIColor.whiteColor.CGColor);
        if([name isEqual:@"containers"]) {
            for(int row=0;row<2;row++) { CGContextStrokeRect(c,CGRectMake(3,4+row*10,6,6));CGContextMoveToPoint(c,13,7+row*10);CGContextAddLineToPoint(c,23,7+row*10);CGContextStrokePath(c); }
        } else if([name isEqual:@"connection"]) {
            CGContextMoveToPoint(c,7,7);CGContextAddLineToPoint(c,19,19);CGContextMoveToPoint(c,19,7);CGContextAddLineToPoint(c,7,19);CGContextStrokePath(c);
            for(NSValue *v in @[[NSValue valueWithCGPoint:CGPointMake(5,5)],[NSValue valueWithCGPoint:CGPointMake(17,5)],[NSValue valueWithCGPoint:CGPointMake(5,17)],[NSValue valueWithCGPoint:CGPointMake(17,17)]]) { CGPoint p=v.CGPointValue;CGContextStrokeEllipseInRect(c,CGRectMake(p.x,p.y,4,4)); }
        } else if([name isEqual:@"settings"]) {
            for(int row=0;row<3;row++) { CGFloat y=5+8*row,x=row==1?17:8;CGContextMoveToPoint(c,3,y);CGContextAddLineToPoint(c,x-3,y);CGContextMoveToPoint(c,x+3,y);CGContextAddLineToPoint(c,23,y);CGContextStrokePath(c);CGContextStrokeRect(c,CGRectMake(x-2,y-2,4,4)); }
        } else if([name isEqual:@"plus"]) {
            CGContextMoveToPoint(c,13,5);CGContextAddLineToPoint(c,13,21);CGContextMoveToPoint(c,5,13);CGContextAddLineToPoint(c,21,13);CGContextStrokePath(c);
        } else if([name isEqual:@"location"]) {
            CGContextStrokeEllipseInRect(c,CGRectMake(6,6,14,14));CGContextStrokeEllipseInRect(c,CGRectMake(11,11,4,4));
            for(int i=0;i<4;i++){CGContextSaveGState(c);CGContextTranslateCTM(c,13,13);CGContextRotateCTM(c,i*M_PI_2);CGContextMoveToPoint(c,0,-12);CGContextAddLineToPoint(c,0,-8);CGContextStrokePath(c);CGContextRestoreGState(c);}
        } else if([name isEqual:@"more"]) {
            for(int i=0;i<3;i++) CGContextStrokeEllipseInRect(c,CGRectMake(4+i*8,11,3,3));
        } else if([name isEqual:@"import"]) {
            CGContextMoveToPoint(c,13,3);CGContextAddLineToPoint(c,13,17);CGContextMoveToPoint(c,8,12);CGContextAddLineToPoint(c,13,17);CGContextAddLineToPoint(c,18,12);CGContextMoveToPoint(c,4,18);CGContextAddLineToPoint(c,4,23);CGContextAddLineToPoint(c,22,23);CGContextAddLineToPoint(c,22,18);CGContextStrokePath(c);
        } else {
            CGContextMoveToPoint(c,9,5);CGContextAddLineToPoint(c,18,13);CGContextAddLineToPoint(c,9,21);CGContextStrokePath(c);
        }
    }];return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
UILabel *SBLabel(NSString *text,CGFloat size,UIFontWeight weight) {
    UILabel *v=[UILabel new];v.text=text;v.numberOfLines=0;v.textColor=UIColor.whiteColor;
    v.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];v.adjustsFontForContentSizeCategory=YES;return v;
}
UIButton *SBButton(NSString *title,NSString *glyph,BOOL primary,void(^action)(void)) {
    UIButtonConfiguration *config=primary?UIButtonConfiguration.filledButtonConfiguration:UIButtonConfiguration.plainButtonConfiguration;
    config.title=title;config.image=SBGlyph(glyph);config.imagePadding=12;config.baseForegroundColor=primary?SBInk():UIColor.whiteColor;
    config.baseBackgroundColor=SBAccent();config.cornerStyle=UIButtonConfigurationCornerStyleMedium;config.contentInsets=NSDirectionalEdgeInsetsMake(14,16,14,16);
    UIButton *button=[UIButton buttonWithConfiguration:config primaryAction:[UIAction actionWithHandler:^(__unused UIAction *a){if(action)action();}]];
    button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;button.accessibilityLabel=title;return button;
}
static char UnavailableKey;
void SBShowUnavailable(UIViewController *owner,NSString *reason) {
    if(!owner.isViewLoaded || objc_getAssociatedObject(owner,&UnavailableKey)) return;
    for(UIView *v in owner.view.subviews) v.hidden=YES;
    owner.navigationItem.title=SBUIText(@"brand.name");owner.navigationItem.titleView=nil;
    owner.navigationItem.leftBarButtonItems=@[];owner.navigationItem.rightBarButtonItems=@[];
    UIView *panel=[UIView new];panel.backgroundColor=SBInk();panel.translatesAutoresizingMaskIntoConstraints=NO;[owner.view addSubview:panel];
    UILabel *title=SBLabel(SBUIText(@"common.functionUnavailable"),26,UIFontWeightBold);
    UILabel *detail=SBLabel([SBUIText(@"common.incompatiblePrefix") stringByAppendingString:reason ?: @"SB-UI-001"],15,UIFontWeightRegular);detail.textColor=SBMuted();
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,detail]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=NO;[panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[panel.leadingAnchor constraintEqualToAnchor:owner.view.leadingAnchor],[panel.trailingAnchor constraintEqualToAnchor:owner.view.trailingAnchor],[panel.topAnchor constraintEqualToAnchor:owner.view.topAnchor],[panel.bottomAnchor constraintEqualToAnchor:owner.view.bottomAnchor],[stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:24],[stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-24],[stack.topAnchor constraintEqualToAnchor:panel.safeAreaLayoutGuide.topAnchor constant:40]]];
    panel.accessibilityIdentifier=@"socialbox.unavailable";objc_setAssociatedObject(owner,&UnavailableKey,panel,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
