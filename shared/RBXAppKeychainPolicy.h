#pragma once
#import "RBXAppRegistry.h"
#import <Security/Security.h>

// FBKEY-001. The ordered group set is derived from compiled policy, never from
// profile-supplied entitlements. The first group preserves default creation.
static inline NSArray<NSString *> *RBXAppKeychainGroups(NSDictionary *descriptor, NSString *bundle) {
    if (!RBXAppOwnsCloneBundleIdentifier(descriptor, bundle)) return nil;
    NSString *primary = RBXAppKeychainGroup(descriptor, bundle);
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *suffix in descriptor[@"keychainGroupSuffixes"])
        [groups addObject:[primary stringByAppendingString:suffix]];
    return groups.copy;
}

static inline BOOL RBXAppKeychainMappingEnabled(NSDictionary *descriptor) {
    return RBXAppDescriptorIsRegistered(descriptor) && [descriptor[@"keychainSourceGroups"] count] > 0;
}

static inline NSDictionary *RBXAppKeychainMetadata(NSDictionary *descriptor, NSString *bundle) {
    NSArray *groups = RBXAppKeychainGroups(descriptor, bundle);
    if (!groups) return nil;
    return RBXAppKeychainMappingEnabled(descriptor)
        ? @{@"keychainPolicyVersion":@1, @"keychainAccessGroups":groups} : @{};
}

static inline BOOL RBXAppKeychainMetadataMatches(NSDictionary *descriptor, NSString *bundle, id metadata) {
    NSDictionary *expected = RBXAppKeychainMetadata(descriptor, bundle);
    if (!expected || ![metadata isKindOfClass:NSDictionary.class]) return NO;
    if (!expected.count) return !metadata[@"keychainPolicyVersion"] && !metadata[@"keychainAccessGroups"];
    id version = metadata[@"keychainPolicyVersion"];
    return [version isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID() &&
        [version isEqual:@1] && [metadata[@"keychainAccessGroups"] isEqual:expected[@"keychainAccessGroups"]];
}

// Existing Reddit marker shape is retained. New multi-group markers additionally
// bind their record version, explicit app owner and source identity.
static inline BOOL RBXAppKeychainMarkerMatches(NSDictionary *descriptor, NSString *bundle, id marker) {
    if (!RBXAppKeychainMetadataMatches(descriptor, bundle, marker)) return NO;
    return !RBXAppKeychainMappingEnabled(descriptor) ||
        ([marker[@"formatVersion"] isEqual:@2] && [marker[@"appType"] isEqual:descriptor[@"appType"]] &&
         [marker[@"sourceBundleIdentifier"] isEqual:descriptor[@"sourceBundleIdentifier"]] &&
         [marker[@"keychainAccessGroup"] isEqual:RBXAppKeychainGroup(descriptor, bundle)]);
}

// FBKEY-005. A successful child exit alone is insufficient to advance deletion.
// Bind the bounded receipt to the nonce and compiled policy, then require a
// separate authorization and four-class proof for every mapped group.
static inline BOOL RBXAppKeychainCleanupReceiptBound(NSDictionary *descriptor, NSString *bundle, NSString *nonce, id receipt) {
    NSArray *groups = RBXAppKeychainGroups(descriptor, bundle);
    if (!groups.count || ![nonce isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:nonce] ||
        ![receipt isKindOfClass:NSDictionary.class] || ![nonce isEqual:receipt[@"nonce"]] ||
        ![bundle isEqual:receipt[@"bundleIdentifier"]] || ![groups.firstObject isEqual:receipt[@"accessGroup"]]) return NO;
    BOOL mapped = RBXAppKeychainMappingEnabled(descriptor);
    id version = receipt[@"formatVersion"];
    if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        ![version isEqual:mapped ? @2 : @1] || !RBXAppKeychainMetadataMatches(descriptor, bundle, receipt)) return NO;
    return !mapped || [descriptor[@"appType"] isEqual:receipt[@"appType"]];
}

static inline BOOL RBXAppKeychainCleanupReceiptComplete(NSDictionary *descriptor, NSString *bundle, NSString *nonce, id receipt) {
    NSArray *classes = @[@"genp", @"inet", @"cert", @"keys"];
    if (!RBXAppKeychainCleanupReceiptBound(descriptor, bundle, nonce, receipt) ||
        ![@"cleared" isEqual:receipt[@"status"]] || ![@YES isEqual:receipt[@"proof"]] ||
        ![classes isEqual:receipt[@"classes"]] || ![@501 isEqual:receipt[@"uid"]] || ![@501 isEqual:receipt[@"gid"]] ||
        ![@"complete" isEqual:receipt[@"stage"]] || ![@0 isEqual:receipt[@"osStatus"]]) return NO;
    if (!RBXAppKeychainMappingEnabled(descriptor)) return YES;
    NSArray *groups = RBXAppKeychainGroups(descriptor, bundle), *records = receipt[@"groups"];
    if (![records isKindOfClass:NSArray.class] || records.count != groups.count) return NO;
    for (NSUInteger index = 0; index < groups.count; index++) {
        id record = records[index];
        if (![record isKindOfClass:NSDictionary.class] || ![groups[index] isEqual:record[@"accessGroup"]] ||
            ![@YES isEqual:record[@"proof"]] || ![classes isEqual:record[@"classes"]]) return NO;
    }
    return YES;
}

// Map only audited explicit group names. Omitted groups retain Security's default
// creation / all-entitled-group search behavior. Own group names are idempotent.
// No retry, service/account rewriting, key material transformation or reference
// translation. Returned Security attributes continue to name the actual groups.
static inline NSDictionary *RBXAppKeychainDictionary(NSDictionary *descriptor, NSString *bundle,
                                                     NSDictionary *input, BOOL keyCreation, OSStatus *status) {
    if (status) *status = errSecSuccess;
    if (!RBXAppOwnsCloneBundleIdentifier(descriptor, bundle)) {
        if (status) *status = errSecParam;
        return nil;
    }
    if (!RBXAppKeychainMappingEnabled(descriptor)) return input;
    if (![input isKindOfClass:NSDictionary.class]) {
        if (status) *status = errSecParam;
        return nil;
    }
    NSMutableDictionary *mapped = nil;
    id key = (__bridge id)kSecAttrAccessGroup, value = input[key];
    if (value) {
        if (![value isKindOfClass:NSString.class]) {
            if (status) *status = errSecParam;
            return nil;
        }
        NSArray *sources = descriptor[@"keychainSourceGroups"], *groups = RBXAppKeychainGroups(descriptor, bundle);
        NSUInteger index = [sources indexOfObject:value];
        if (index != NSNotFound) {
            mapped = input.mutableCopy;
            mapped[key] = groups[index];
        } else if (![groups containsObject:value]) {
            if (status) *status = errSecMissingEntitlement;
            return nil;
        }
    }
    if (keyCreation) {
        for (id nestedKey in @[(__bridge id)kSecPrivateKeyAttrs, (__bridge id)kSecPublicKeyAttrs]) {
            id child = input[nestedKey];
            if (!child) continue;
            NSDictionary *nested = RBXAppKeychainDictionary(descriptor, bundle, child, NO, status);
            if (!nested) return nil;
            if (nested != child) {
                if (!mapped) mapped = input.mutableCopy;
                mapped[nestedKey] = nested;
            }
        }
    }
    return mapped ?: input;
}
