#pragma once
#import <Foundation/Foundation.h>

// UI-003: a preview is valid only for the exact choices that were checked.
// The daemon independently validates again when Apply is requested.
static inline BOOL RBXIdentityReviewCanApply(NSDictionary *choices, NSDictionary *validated,
                                           BOOL pending, BOOL proxyMismatch) {
    return !pending && !proxyMismatch && validated.count > 0 && [choices isEqual:validated];
}
