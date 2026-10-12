#import <Foundation/Foundation.h>
#include <math.h>
#import "RBXLocationDraft.h"

static inline double RBXScreenNumber(id value) {
    double number=0; return RBXLocationNumber(value,&number) ? number : NAN;
}

// Compare portrait-normalized measurements captured in the unhooked launcher.
// A recommendation is never an identity mutation or proof of hardware identity.
static inline NSDictionary *RBXScreenMatch(NSDictionary *model, NSDictionary *physical) {
    if (![model isKindOfClass:NSDictionary.class]) model=@{};
    if (![physical isKindOfClass:NSDictionary.class]) physical=@{};
    NSDictionary *screen = [model[@"screen"] isKindOfClass:NSDictionary.class] ? model[@"screen"] : @{};
    double w=RBXScreenNumber(screen[@"w"]),h=RBXScreenNumber(screen[@"h"]),scale=RBXScreenNumber(screen[@"scale"]);
    double pw=RBXScreenNumber(physical[@"nativeWidth"]),ph=RBXScreenNumber(physical[@"nativeHeight"]);
    double lw=RBXScreenNumber(physical[@"logicalWidth"]),lh=RBXScreenNumber(physical[@"logicalHeight"]);
    double s=RBXScreenNumber(physical[@"scale"]),ns=RBXScreenNumber(physical[@"nativeScale"]);
    BOOL valid=isfinite(w)&&isfinite(h)&&isfinite(scale)&&isfinite(pw)&&isfinite(ph)&&isfinite(lw)&&isfinite(lh)&&isfinite(s)&&isfinite(ns)&&
        w>0&&h>0&&scale>0&&pw>0&&ph>0&&lw>0&&lh>0&&s>0&&ns>0;
    double a=MIN(w,h),b=MAX(w,h),pa=MIN(pw,ph),pb=MAX(pw,ph),la=MIN(lw,lh),lb=MAX(lw,lh);
    BOOL exact=valid&&fabs(a-pa)<.5&&fabs(b-pb)<.5&&fabs(a/scale-la)<.5&&fabs(b/scale-lb)<.5&&fabs(scale-s)<.001&&fabs(scale-ns)<.001;
    double score=valid ? fabs(a-pa)/pa+fabs(b-pb)/pb+fabs(a/scale-la)/la+fabs(b/scale-lb)/lb+fabs(scale-s)+fabs(scale-ns) : 1e9;
    return @{@"exact":@(exact),@"known":@(valid),@"score":@(score),@"description":valid ?
        [NSString stringWithFormat:@"%.0f × %.0f px · %.0f × %.0f pt · %.0f×",a,b,a/scale,b/scale,scale] : @"Screen measurements unavailable in catalog"};
}

static inline NSArray<NSDictionary *> *RBXScreenModelOptions(NSDictionary *models, NSDictionary *physical, NSString *selected) {
    if (![models isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray *options=[NSMutableArray array];
    BOOL anyExact=NO;
    for (NSString *key in models) {
        if (![key isKindOfClass:NSString.class]||![models[key] isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *match=RBXScreenMatch(models[key],physical); anyExact |= [match[@"exact"] boolValue];
        [options addObject:@{@"title":[models[key][@"marketingName"] isKindOfClass:NSString.class] ? models[key][@"marketingName"] : key,@"value":key,@"selected":@([key isEqual:selected]),
            @"subtitle":[NSString stringWithFormat:@"%@ · %@",key,match[@"description"]],@"match":match}];
    }
    [options sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult result=[a[@"match"][@"score"] compare:b[@"match"][@"score"]];
        return result==NSOrderedSame ? [b[@"value"] compare:a[@"value"] options:NSNumericSearch] : result;
    }];
    double best=options.count ? [options.firstObject[@"match"][@"score"] doubleValue] : 1e9;
    NSMutableArray *result=[NSMutableArray array];
    for (NSDictionary *option in options) {
        NSMutableDictionary *entry=option.mutableCopy; NSDictionary *match=entry[@"match"];
        entry[@"group"]=[match[@"exact"] boolValue] ? @"Recommended · matching screen geometry" :
            !anyExact&&[match[@"known"] boolValue]&&fabs([match[@"score"] doubleValue]-best)<.000001 ? @"Closest in catalog · not an exact match" : @"Other models";
        [entry removeObjectForKey:@"match"]; [result addObject:entry];
    }
    return result;
}
