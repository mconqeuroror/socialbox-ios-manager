#pragma once
#import <UIKit/UIKit.h>

static inline UIUserInterfaceStyle RBXPreferredAppearance(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:@"RBXAppearance"];
    NSInteger style = [value isKindOfClass:NSNumber.class] ? [value integerValue] : UIUserInterfaceStyleDark;
    return style >= UIUserInterfaceStyleUnspecified && style <= UIUserInterfaceStyleDark ? style : UIUserInterfaceStyleDark;
}

// Shared UIKit styling. All state and actions remain owned by the controllers.
static inline UIColor *RBXAccentColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.24 green:0.88 blue:0.79 alpha:1]
            : [UIColor colorWithRed:0.0 green:0.40 blue:0.37 alpha:1];
    }];
}

static inline UIColor *RBXCanvasColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.045 green:0.05 blue:0.065 alpha:1]
            : [UIColor colorWithRed:0.96 green:0.96 blue:0.97 alpha:1];
    }];
}

static inline UIColor *RBXCardColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1 alpha:0.065] : [UIColor colorWithWhite:1 alpha:0.94];
    }];
}

static inline void RBXStyleCard(UIView *card) {
    card.backgroundColor = RBXCardColor();
    card.layer.cornerRadius = 16;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.borderColor = [UIColor colorWithWhite:0.6 alpha:0.2].CGColor;
}

// Drawn locally: no remote artwork, map requests or borrowed product assets.
// The owner recreates this view when its color appearance changes.
static inline UIView *RBXWorkspaceBackgroundView(UITraitCollection *traits) {
    BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
    CGSize size = CGSizeMake(430, 940);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef cg = context.CGContext;
        [dark ? [UIColor colorWithRed:0.045 green:0.05 blue:0.065 alpha:1] : [UIColor colorWithRed:0.965 green:0.965 blue:0.975 alpha:1] setFill];
        UIRectFill((CGRect){CGPointZero,size});
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)[UIColor colorWithRed:0.10 green:0.50 blue:0.46 alpha:dark ? 0.09 : 0.035].CGColor,
            (id)[UIColor colorWithRed:0.10 green:0.50 blue:0.46 alpha:0].CGColor];
        CGFloat stops[] = {0,1};
        CGGradientRef teal = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
        CGContextDrawRadialGradient(cg, teal, CGPointMake(430,60), 0, CGPointMake(430,60), 430, 0);
        CGGradientRelease(teal);
        colors = @[(id)[UIColor colorWithRed:0.15 green:0.32 blue:0.55 alpha:dark ? 0.18 : 0.04].CGColor,
            (id)[UIColor colorWithRed:0.15 green:0.32 blue:0.55 alpha:0].CGColor];
        CGGradientRef blue = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
        CGContextDrawRadialGradient(cg, blue, CGPointMake(0,750), 0, CGPointMake(0,750), 430, 0);
        CGGradientRelease(blue); CGColorSpaceRelease(space);
    }];
    UIImageView *background = [[UIImageView alloc] initWithImage:image];
    background.contentMode = UIViewContentModeScaleToFill;
    background.userInteractionEnabled = NO;
    background.accessibilityElementsHidden = YES;
    return background;
}

// Original compact section glyphs, drawn locally and tinted by UIKit.
static inline UIImage *RBXSectionArtwork(NSUInteger section) {
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26,26)];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c=context.CGContext; CGContextSetLineWidth(c,1.8); CGContextSetLineCap(c,kCGLineCapRound);
        CGContextSetStrokeColorWithColor(c,UIColor.whiteColor.CGColor); CGContextSetFillColorWithColor(c,UIColor.whiteColor.CGColor);
        if(section==0) {
            for(NSUInteger i=0;i<4;i++) {
                UIBezierPath *tile=[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3+(i%2)*11,3+(i/2)*11,8,8) cornerRadius:2];
                [tile stroke];
            }
        } else if(section==1) {
            CGContextMoveToPoint(c,7,7); CGContextAddLineToPoint(c,19,19); CGContextStrokePath(c);
            CGContextStrokeEllipseInRect(c,CGRectMake(2,2,9,9)); CGContextStrokeEllipseInRect(c,CGRectMake(15,15,9,9));
            CGContextMoveToPoint(c,17,4); CGContextAddLineToPoint(c,22,4); CGContextAddLineToPoint(c,22,9); CGContextStrokePath(c);
            CGContextMoveToPoint(c,4,17); CGContextAddLineToPoint(c,4,22); CGContextAddLineToPoint(c,9,22); CGContextStrokePath(c);
        } else {
            const CGFloat x[]={8,18,11};
            for(NSUInteger i=0;i<3;i++) {
                CGFloat y=5+i*8; CGContextMoveToPoint(c,3,y); CGContextAddLineToPoint(c,23,y); CGContextStrokePath(c);
                CGContextFillEllipseInRect(c,CGRectMake(x[i]-2.5,y-2.5,5,5));
            }
        }
    }];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static inline UILabel *RBXLabel(NSString *text, UIFontTextStyle style, BOOL secondary) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:style];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = secondary ? UIColor.secondaryLabelColor : UIColor.labelColor;
    label.numberOfLines = 0;
    return label;
}

static inline UIStackView *RBXVerticalStack(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = spacing;
    return stack;
}

static inline UIStackView *RBXFormSection(UIStackView *page, NSString *title, NSString *detail) {
    UIStackView *card = RBXVerticalStack(@[], 12);
    card.layoutMarginsRelativeArrangement = YES;
    card.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(20, 18, 20, 18);
    RBXStyleCard(card);
    if (title.length) {
        UILabel *heading = RBXLabel(title, UIFontTextStyleHeadline, NO);
        heading.accessibilityTraits |= UIAccessibilityTraitHeader;
        [card addArrangedSubview:heading];
    }
    if (detail.length) [card addArrangedSubview:RBXLabel(detail, UIFontTextStyleSubheadline, YES)];
    [page addArrangedSubview:card];
    return card;
}

static inline void RBXStyleField(UITextField *field) {
    field.borderStyle = UITextBorderStyleNone;
    field.backgroundColor = UIColor.tertiarySystemGroupedBackgroundColor;
    field.textColor = UIColor.labelColor;
    field.tintColor = RBXAccentColor();
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    field.layer.cornerRadius = 12;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    field.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.rightViewMode = UITextFieldViewModeUnlessEditing;
    field.accessibilityLabel = field.placeholder;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
}

static inline void RBXStyleButton(UIButton *button, BOOL primary) {
    UIColor *foreground = primary ? [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0.065 green:0.065 blue:0.07 alpha:1] : UIColor.whiteColor;
    }] : RBXAccentColor();
    UIButtonConfiguration *configuration = primary ? [UIButtonConfiguration filledButtonConfiguration]
        : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = [button titleForState:UIControlStateNormal];
    configuration.baseBackgroundColor = RBXAccentColor();
    configuration.baseForegroundColor = foreground;
    configuration.buttonSize = UIButtonConfigurationSizeLarge;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleFixed;
    configuration.background.cornerRadius = 14;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
    configuration.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    button.configuration = configuration;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    button.titleLabel.numberOfLines = 0;
    button.titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    button.titleLabel.textAlignment = NSTextAlignmentCenter;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES;
}

static inline void RBXStyleNavigation(UINavigationController *navigation) {
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = RBXCanvasColor();
    appearance.shadowColor = UIColor.clearColor;
    appearance.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.labelColor};
    appearance.largeTitleTextAttributes = @{NSForegroundColorAttributeName: UIColor.labelColor};
    navigation.navigationBar.standardAppearance = appearance;
    navigation.navigationBar.scrollEdgeAppearance = appearance;
    navigation.navigationBar.compactAppearance = appearance;
    navigation.navigationBar.tintColor = RBXAccentColor();
    navigation.view.tintColor = RBXAccentColor();
}
