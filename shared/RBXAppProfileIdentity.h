#pragma once
#import "RBXAppRegistry.h"
#import "RBXAppKeychainPolicy.h"

// Optional clone metadata may be absent before installation or in a legacy
// profile. When present it cannot redirect this profile into another sandbox.
static inline NSString *RBXAppProfileIdentityBlockReason(NSDictionary *descriptor,
    NSDictionary *profile, NSString *expectedContainer) {
    NSDictionary *owner = RBXAppDescriptorForProfile(profile);
    if (!RBXAppDescriptorIsRegistered(descriptor) || ![owner isEqual:descriptor])
        return @"Profile app does not match its registered clone descriptor.";
    id container = profile[@"containerId"];
    if ((container && (![container isKindOfClass:NSString.class] || ![container length])) ||
        (expectedContainer && (![expectedContainer isKindOfClass:NSString.class] ||
            !expectedContainer.length || ![container isEqual:expectedContainer])))
        return @"Clone target does not match the profile container identity.";
    id app = profile[@"app"];
    if (app && ![app isKindOfClass:NSDictionary.class])
        return @"Profile clone metadata is malformed.";
    id bundle = app[@"bundleIdentifier"];
    if (bundle && (![bundle isKindOfClass:NSString.class] || ![container isKindOfClass:NSString.class] ||
        ![bundle isEqual:RBXAppBundleIdentifier(descriptor, container)]))
        return @"Profile clone bundle does not belong to its container and app.";
    if (RBXAppKeychainMappingEnabled(descriptor) &&
        (bundle || app[@"keychainAccessGroup"] || app[@"keychainPolicyVersion"] || app[@"keychainAccessGroups"]) &&
        (![app[@"keychainAccessGroup"] isEqual:RBXAppKeychainGroup(descriptor, bundle)] ||
         !RBXAppKeychainMetadataMatches(descriptor, bundle, app)))
        return @"Profile clone Keychain policy does not contain its complete registered group set.";
    return nil;
}
