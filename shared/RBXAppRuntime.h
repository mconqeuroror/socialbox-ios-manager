#pragma once
#import "RBXAppRegistry.h"
#import "RBXAppKeychainPolicy.h"

// Bootstrap admission is bound to the compiled registry and this exact container,
// never merely a clone prefix or a selected app in another process.
static inline BOOL RBXAppRuntimeProfileMatchesBundle(NSDictionary *profile, NSString *actualBundle) {
    if (![profile isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    NSString *container = [profile[@"containerId"] isKindOfClass:NSString.class] ? profile[@"containerId"] : nil;
    NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
    return descriptor && container.length && RBXAppOwnsCloneBundleIdentifier(descriptor, actualBundle) &&
        [actualBundle isEqual:RBXAppBundleIdentifier(descriptor, container)] &&
        [app[@"bundleIdentifier"] isEqual:actualBundle] &&
        [app[@"keychainAccessGroup"] isEqual:RBXAppKeychainGroup(descriptor, actualBundle)] &&
        RBXAppKeychainMetadataMatches(descriptor, actualBundle, app);
}

// Existing Reddit constructor behavior is retained. Newly added executable
// filters must be inert until their registered runtime admission is enabled.
static inline BOOL RBXAppRuntimeHooksEnabledForBundle(NSString *bundle) {
    NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(bundle);
    return descriptor && ([descriptor[@"appType"] isEqual:@"reddit"] || [descriptor[@"runnable"] boolValue]);
}

static inline BOOL RBXAppRuntimeHooksEnabled(void) {
    return RBXAppRuntimeHooksEnabledForBundle(NSBundle.mainBundle.bundleIdentifier);
}

// These roots are destination policy, not a claim that a host is active or that
// its wire format is known. FB roots come from Facebook 578.1.0 (1063022819) static URL
// references. See docs/facebook-binary-audit.md for the evidence and limitations.
static inline BOOL RBXAppRuntimeCriticalHostAllowed(NSDictionary *descriptor, NSString *host) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || ![host isKindOfClass:NSString.class]) return NO;
    NSString *value = host.lowercaseString;
    NSArray *domains = nil;
    if ([descriptor[@"appType"] isEqual:@"reddit"])
        domains = @[@"reddit.com", @"redditmedia.com", @"redditstatic.com", @"redd.it"];
    else if ([descriptor[@"appType"] isEqual:@"facebook"])
        domains = @[@"facebook.com", @"fbcdn.net", @"facebook.net", @"fbsbx.com"];
    for (NSString *domain in domains)
        if ([value isEqual:domain] || [value hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    return NO;
}

// This is deliberately narrower than generic OS identity coverage. A collection
// of binary strings is not proof of Facebook's family/machine ID persistence or
// request semantics. Keep readiness denied until its app-specific policy exists.
static inline BOOL RBXAppRuntimeWirePolicyAudited(NSDictionary *descriptor) {
    return RBXAppDescriptorIsRegistered(descriptor) && [descriptor[@"appType"] isEqual:@"reddit"];
}
