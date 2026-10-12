#pragma once
#include <math.h>

// UI freshness is intentionally narrower than the signed offline grace. The
// daemon owns signature validation; a cached UI snapshot cannot extend a grant.
typedef enum {
    RBXLicensePresentationValid = 0,
    RBXLicensePresentationInvalidClock,
    RBXLicensePresentationMissingPublication,
    RBXLicensePresentationFuturePublication,
    RBXLicensePresentationStalePublication,
    RBXLicensePresentationMissingExpiry,
    RBXLicensePresentationExpired,
} RBXLicensePresentationWindowResult;

static inline RBXLicensePresentationWindowResult RBXLicensePresentationSnapshotWindow(double now, double publishedAt) {
    if (!isfinite(now) || now < 0) return RBXLicensePresentationInvalidClock;
    if (!isfinite(publishedAt) || publishedAt <= 0) return RBXLicensePresentationMissingPublication;
    double age = now - publishedAt;
    if (age < -2.0) return RBXLicensePresentationFuturePublication;
    if (age > 10.0) return RBXLicensePresentationStalePublication;
    return RBXLicensePresentationValid;
}

static inline RBXLicensePresentationWindowResult RBXLicensePresentationWindow(double now, double publishedAt, double expiresAt) {
    RBXLicensePresentationWindowResult freshness = RBXLicensePresentationSnapshotWindow(now, publishedAt);
    if (freshness != RBXLicensePresentationValid) return freshness;
    if (!isfinite(expiresAt) || expiresAt <= 0) return RBXLicensePresentationMissingExpiry;
    if (expiresAt <= now) return RBXLicensePresentationExpired;
    return RBXLicensePresentationValid;
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

static inline BOOL RBXLicensePresentationNumber(id value) {
    // Property-list booleans are NSNumber subclasses, but are not timestamps.
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]);
}

static inline BOOL RBXLicensePresentationFlag(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
        ([value doubleValue] == 0 || [value doubleValue] == 1);
}

static inline NSDictionary *RBXLicensePresentationState(NSDictionary *snapshot, NSTimeInterval now) {
    NSDictionary *document = [snapshot isKindOfClass:NSDictionary.class] ? snapshot : @{};
    NSDictionary *license = [document[@"license"] isKindOfClass:NSDictionary.class] ? document[@"license"] : @{};
    NSMutableDictionary *state = [@{@"unlocked": @NO, @"offlineGrace": @NO, @"paired": @NO,
        @"retryAt": @0, @"status": @"activation-required",
        @"reason": @"No valid activation token is available on this device."} mutableCopy];
    // Preserve only the published presentation fields, never raw tokens or keys.
    for (NSString *key in @[@"status", @"reason", @"serverURL"])
        if ([license[key] isKindOfClass:NSString.class] && [license[key] length]) state[key] = license[key];
    for (NSString *key in @[@"retryAt", @"lastValidatedAt", @"graceUntil", @"expiresAt"])
        if (RBXLicensePresentationNumber(license[key]) && [license[key] doubleValue] >= 0) state[key] = license[key];
    if (RBXLicensePresentationFlag(license[@"paired"])) state[@"paired"] = @([license[@"paired"] boolValue]);

    double publishedAt = RBXLicensePresentationNumber(document[@"updatedAt"]) ? [document[@"updatedAt"] doubleValue] : NAN;
    RBXLicensePresentationWindowResult result = RBXLicensePresentationSnapshotWindow(now, publishedAt);
    BOOL malformedGrant = license.count && !RBXLicensePresentationFlag(license[@"unlocked"]);
    BOOL granted = !malformedGrant && [license[@"unlocked"] boolValue];
    if (result == RBXLicensePresentationValid && granted) {
        double expiry = RBXLicensePresentationNumber(license[@"expiresAt"]) ? [license[@"expiresAt"] doubleValue] : NAN;
        result = RBXLicensePresentationWindow(now, publishedAt, expiry);
    }
    if (result == RBXLicensePresentationValid && !malformedGrant) {
        state[@"unlocked"] = @(granted);
        state[@"offlineGrace"] = @(granted && RBXLicensePresentationFlag(license[@"offlineGrace"]) &&
            [license[@"offlineGrace"] boolValue]);
        return [state copy];
    }

    switch (result) {
        case RBXLicensePresentationInvalidClock:
        case RBXLicensePresentationFuturePublication:
            state[@"status"] = @"clock-invalid";
            state[@"reason"] = @"Device time and the daemon's status do not agree. Access remains locked; check diagnostics.";
            break;
        case RBXLicensePresentationMissingPublication:
        case RBXLicensePresentationStalePublication:
            state[@"status"] = @"daemon-unavailable";
            state[@"reason"] = @"A fresh daemon status is unavailable. Access remains locked; diagnostics and setup are available offline.";
            break;
        case RBXLicensePresentationExpired:
            state[@"status"] = @"expired";
            state[@"reason"] = @"The signed license validity or offline grace has expired. Validate the paired device or activate a valid key.";
            break;
        case RBXLicensePresentationMissingExpiry:
        case RBXLicensePresentationValid:
            state[@"status"] = @"invalid-status";
            state[@"reason"] = @"The daemon did not publish a complete, valid license state. Access remains locked; check diagnostics.";
            break;
    }
    return [state copy];
}
#endif
