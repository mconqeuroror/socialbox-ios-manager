#pragma once
#import <Foundation/Foundation.h>
#include <math.h>

// Shared with the daemon: a single Boolean is not sufficient evidence.
static inline NSArray<NSString *> *RBXRequiredHookGroups(void) {
    return @[@"web-policy", @"pasteboard", @"mobilegestalt", @"idfa-idfv", @"device",
        @"sysctl-uname", @"runtime-timing", @"iokit", @"telephony", @"locale", @"timezone",
        @"location", @"battery", @"sensors-display", @"metal-gpu", @"process-proxy",
        @"socket-guard", @"network-metadata", @"defaults-wire", @"jailbreak-hiding",
        @"appattest-devicecheck", @"push", @"notifications", @"keychain-sync-policy"];
}
static inline NSArray<NSString *> *RBXRequiredBehaviorChecks(void) {
    return @[@"pasteboard", @"profile-entitlements-keychain", @"mobilegestalt", @"sysctl-uname", @"iokit",
        @"idfa-idfv-device", @"locale-timezone", @"runtime-timing", @"sensors-display",
        @"metal-gpu", @"network-metadata", @"process-proxy", @"socket-guard"];
}
static inline BOOL RBXRequiredChecksPassed(id results, NSArray<NSString *> *required) {
    if (![results isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in required) if (![results[key] isEqual:@YES]) return NO;
    return YES;
}

// Read-only diagnostic ordering. Identity, generation and PID must be checked
// independently; this helper never authorizes or renews a lease.
static inline BOOL RBXHookReceiptTimeMatchesLease(NSDictionary *ready, NSDictionary *lease, NSTimeInterval now) {
    id receipt = ready[@"timestamp"], opened = lease[@"openedAt"];
    for (id value in @[receipt ?: NSNull.null, opened ?: NSNull.null]) {
        if (![value isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
            !isfinite([value doubleValue]) || [value doubleValue] <= 0 || [value doubleValue] > now) return NO;
    }
    if (!isfinite(now)) return NO;
    // OPEN is published after the daemon validates the ARMED receipt. Its
    // openedAt is the transition time, not the start of the readiness challenge.
    if ([lease[@"state"] isEqual:@"open"]) return [receipt doubleValue] <= [opened doubleValue];
    if ([lease[@"state"] isEqual:@"armed"]) return [receipt doubleValue] >= [opened doubleValue];
    return NO;
}
