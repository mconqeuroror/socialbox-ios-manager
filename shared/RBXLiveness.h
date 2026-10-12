#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

static const NSTimeInterval RBXHeartbeatMaximumAge = 2.5;
static inline BOOL RBXHeartbeatFresh(id timestamp, NSTimeInterval now) {
    if (![timestamp isKindOfClass:NSNumber.class] || !isfinite(now)) return NO;
    NSTimeInterval age = now - [timestamp doubleValue];
    return isfinite(age) && age >= 0 && age <= RBXHeartbeatMaximumAge;
}
