#pragma once
#import <Foundation/Foundation.h>
#import "RBXCentralStore.h"
#import "RBXProfileIdentifier.h"
#import <math.h>

// LIFE-019 / ID-010: root-private lifecycle metadata, never a generated device
// identifier or an assertion that a launch succeeded. Presence is irreversible
// for a surviving logical profile, including an uncertain publication result.
static BOOL RBXIdentityEntryIsFrozen(NSDictionary *entry) {
    if (![entry isKindOfClass:NSDictionary.class]) return YES;
    if (entry[@"identityFrozenAt"]) return YES;
    for (NSString *key in @[@"lastActiveAt", @"lastLoginAt"]) {
        id value = entry[key];
        if (!value) continue;
        if (![value respondsToSelector:@selector(doubleValue)]) return YES;
        double timestamp = [value doubleValue];
        if (!isfinite(timestamp) || timestamp != 0) return YES;
    }
    return NO;
}

static BOOL RBXIdentityFreezeFailure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity-lifecycle" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

static BOOL RBXFreezeIdentityBeforeLaunch(RBXCentralStore *store, NSString *container,
                                         NSError **error) {
    if (!store || !RBXCanonicalProfileIdentifier(container))
        return RBXIdentityFreezeFailure(error, @"Identity freeze has no valid profile owner");
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!isfinite(now) || now <= 0)
        return RBXIdentityFreezeFailure(error, @"Identity freeze timestamp is unavailable");
    __block NSString *failure = nil;
    BOOL published = [store update:^(NSMutableDictionary *document) {
        id entries = document[@"containers"];
        NSDictionary *entry = [entries isKindOfClass:NSDictionary.class] ? entries[container] : nil;
        if (![entry isKindOfClass:NSDictionary.class]) {
            failure = @"Profile lifecycle metadata is missing or corrupt; launch remains blocked";
            return;
        }
        id marker = entry[@"identityFrozenAt"];
        if (marker && (![marker isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)marker) == CFBooleanGetTypeID() ||
            !isfinite([marker doubleValue]) || [marker doubleValue] <= 0)) {
            failure = @"Identity freeze marker is invalid; retain it for recovery";
            return;
        }
        if (!marker) {
            NSMutableDictionary *updated = [entry mutableCopy];
            updated[@"identityFrozenAt"] = @(now);
            NSMutableDictionary *containers = [entries mutableCopy];
            containers[container] = updated;
            document[@"containers"] = containers;
        }
    } error:error];
    if (!published) return NO;
    return failure ? RBXIdentityFreezeFailure(error, failure) : YES;
}
