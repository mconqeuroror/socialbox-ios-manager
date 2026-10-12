#pragma once
#import "RBXAppRegistry.h"

// Only a copied clone Info dictionary is passed here, before inside-out signing.
// These key names are audit evidence, not a generic rewrite of arbitrary plist
// values. The source IPA and the user's installed source remain unchanged.
static inline BOOL RBXRewriteAppKeychainInfo(NSMutableDictionary *info,
    NSDictionary *descriptor, NSString *bundleIdentifier, NSError **error) {
    BOOL valid = [info isKindOfClass:NSMutableDictionary.class] &&
        RBXAppDescriptorIsRegistered(descriptor) &&
        RBXAppOwnsCloneBundleIdentifier(descriptor, bundleIdentifier);
    NSArray *keys = valid ? descriptor[@"keychainInfoKeys"] : nil;
    if (valid) for (NSString *key in keys)
        if (info[key] && ![info[key] isKindOfClass:NSString.class]) valid = NO;
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.clone" code:96
            userInfo:@{NSLocalizedDescriptionKey:@"App keychain metadata does not match its registered clone policy"}];
        return NO;
    }
    NSString *group = RBXAppKeychainGroup(descriptor, bundleIdentifier);
    for (NSString *key in keys) if (info[key]) info[key] = group;
    return YES;
}

static inline BOOL RBXAppKeychainInfoMatches(NSDictionary *info,
    NSDictionary *descriptor, NSString *bundleIdentifier) {
    if (![info isKindOfClass:NSDictionary.class]) return NO;
    NSMutableDictionary *expected = [info mutableCopy];
    return RBXRewriteAppKeychainInfo(expected, descriptor, bundleIdentifier, nil) &&
        [expected isEqual:info];
}
