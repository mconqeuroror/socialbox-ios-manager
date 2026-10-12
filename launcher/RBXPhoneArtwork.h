#pragma once
#import <UIKit/UIKit.h>

// Original, local vector artwork. No account image, physical device query or
// external image/map request is needed to render a container.
static inline UIImage *RBXPhoneArtwork(void) {
    static UIImage *art;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(180,220)];
        art=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef c=context.CGContext;
            CGContextSaveGState(c);
            CGContextSetShadowWithColor(c,CGSizeMake(0,9),16,[UIColor colorWithWhite:0 alpha:.35].CGColor);
            [[UIColor colorWithRed:.30 green:.34 blue:.40 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(37,8,106,198) cornerRadius:24] fill];
            CGContextRestoreGState(c);
            [[UIColor colorWithWhite:.045 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(40,11,100,192) cornerRadius:22] fill];
            CGContextSaveGState(c);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(45,17,90,180) cornerRadius:18] addClip];
            CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
            CGFloat stops[]={0, .55, 1};
            NSArray *palette=@[(id)[UIColor colorWithRed:.08 green:.18 blue:.27 alpha:1].CGColor,
                (id)[UIColor colorWithRed:.17 green:.43 blue:.49 alpha:1].CGColor,
                (id)[UIColor colorWithRed:0 green:122.0/255.0 blue:1 alpha:1].CGColor];
            CGGradientRef gradient=CGGradientCreateWithColors(colors,(__bridge CFArrayRef)palette,stops);
            CGContextDrawLinearGradient(c,gradient,CGPointMake(50,20),CGPointMake(145,210),0);
            CGGradientRelease(gradient);CGColorSpaceRelease(colors);
            [[UIColor colorWithWhite:1 alpha:.12] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(65,56,130,150)] fill];
            [[UIColor colorWithWhite:1 alpha:.10] setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(7,122,160,155)] fill];
            CGContextRestoreGState(c);
            [[UIColor colorWithWhite:.03 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(72,22,36,9) cornerRadius:5] fill];
            [[UIColor colorWithWhite:1 alpha:.7] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(74,189,32,3) cornerRadius:2] fill];
        }];
    });
    return art;
}
