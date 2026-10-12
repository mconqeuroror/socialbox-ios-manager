#pragma once
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "RBXAppRegistryData.h"

// One canonical JSON registry generates the native data and is also imported by
// the cloud console. Missing appType is the legacy Reddit profile format.
static inline NSArray<NSDictionary *> *RBXRegisteredAppDescriptors(void) {
    static NSArray<NSDictionary *> *descriptors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ descriptors = RBXAppRegistryGeneratedDescriptors(); });
    return descriptors;
}

static inline NSDictionary *RBXAppDescriptorForType(id appType) {
    if (!appType) appType = @"reddit";
    if (![appType isKindOfClass:NSString.class]) return nil;
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors())
        if ([descriptor[@"appType"] isEqual:appType]) return descriptor;
    return nil;
}

static inline NSDictionary *RBXRedditAppDescriptor(void) {
    return RBXAppDescriptorForType(@"reddit");
}

static inline NSDictionary *RBXAppDescriptorForProfile(NSDictionary *profile) {
    return [profile isKindOfClass:NSDictionary.class] ? RBXAppDescriptorForType(profile[@"appType"]) : nil;
}

static inline BOOL RBXAppDescriptorIsRegistered(NSDictionary *descriptor) {
    if (![descriptor isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *registered = RBXAppDescriptorForType(descriptor[@"appType"]);
    return registered && [registered isEqual:descriptor];
}

static inline NSString *RBXAppBundleIdentifier(NSDictionary *descriptor, NSString *containerId) {
    if (!RBXAppDescriptorIsRegistered(descriptor) ||
        (containerId && ![containerId isKindOfClass:NSString.class])) return nil;
    // Preserve the original offset basis exactly (it differs from standard
    // FNV-1a's published basis). Changing it would rename every Reddit clone.
    uint64_t hash = 1469598103934665603ULL;
    NSData *bytes = [(containerId ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *cursor = (const uint8_t *)bytes.bytes;
    for (NSUInteger index = 0; index < bytes.length; index++) {
        hash ^= cursor[index];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%@%016llx", descriptor[@"cloneBundlePrefix"], (unsigned long long)hash];
}

static inline NSString *RBXAppKeychainGroup(NSDictionary *descriptor, NSString *bundleIdentifier) {
    if (!RBXAppDescriptorIsRegistered(descriptor) ||
        (bundleIdentifier && ![bundleIdentifier isKindOfClass:NSString.class])) return nil;
    return [descriptor[@"keychainGroupPrefix"] stringByAppendingString:bundleIdentifier ?: @"invalid"];
}

static inline BOOL RBXAppOwnsCloneBundleIdentifier(NSDictionary *descriptor, NSString *bundleIdentifier) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || ![bundleIdentifier isKindOfClass:NSString.class]) return NO;
    NSString *prefix = descriptor[@"cloneBundlePrefix"];
    if (![bundleIdentifier hasPrefix:prefix] || bundleIdentifier.length != prefix.length + 16) return NO;
    NSString *suffix = [bundleIdentifier substringFromIndex:prefix.length];
    return [suffix rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

// Exact source identity or exact generated clone family; no loose substring or
// prefix-only classification of unrelated applications.
static inline NSDictionary *RBXAppDescriptorForBundleIdentifier(NSString *bundleIdentifier) {
    if (![bundleIdentifier isKindOfClass:NSString.class]) return nil;
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors())
        if ([descriptor[@"sourceBundleIdentifier"] isEqual:bundleIdentifier] ||
            RBXAppOwnsCloneBundleIdentifier(descriptor, bundleIdentifier)) return descriptor;
    return nil;
}
