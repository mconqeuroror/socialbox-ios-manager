#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>

// OS-011: optional policy. The existing clone access-group entitlement remains
// the isolation boundary; this helper must never rename groups or item identity.
static inline BOOL RBXKeychainSyncPolicyValid(id policy) {
    return !policy || [policy isEqual:@"unchanged"] || [policy isEqual:@"local-only"];
}

static inline BOOL RBXKeychainSyncPolicyEnabled(id policy) {
    return [policy isEqual:@"local-only"];
}

static inline NSDictionary *RBXKeychainSyncDictionary(NSDictionary *input,
                                                      BOOL enabled) {
    if (!enabled || ![input isKindOfClass:NSDictionary.class]) return input;
    id key = (__bridge id)kSecAttrSynchronizable;
    // Apple defines an absent/false selector as local-only. Preserve that exact
    // dictionary, including reference queries and unrelated update attributes.
    // An explicit true/Any selector is narrowed, never retried or broadened.
    if (!input[key] || [input[key] isEqual:@NO]) return input;
    if (![input[key] isEqual:@YES] && ![input[key] isEqual:(__bridge id)kSecAttrSynchronizableAny])
        return input; // Security retains responsibility for malformed requests.
    NSMutableDictionary *local = input.mutableCopy;
    local[key] = @NO;
    return local;
}
