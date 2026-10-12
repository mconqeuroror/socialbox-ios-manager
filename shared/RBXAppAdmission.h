#pragma once
#import "RBXAppRegistry.h"
#import "RBXAppProfileIdentity.h"

// Selection is an explicit request scope, never an instruction to reinterpret a
// persisted profile. Legacy requests and profiles both retain Reddit semantics.
static inline NSString *RBXAppRequestBlockReason(NSDictionary *request, NSArray<NSDictionary *> *profiles) {
    NSDictionary *descriptor = RBXAppDescriptorForType(request[@"appType"]);
    if (!descriptor) return @"Unknown app type; no action was performed.";
    for (NSDictionary *profile in profiles) {
        NSDictionary *owner = RBXAppDescriptorForProfile(profile);
        if (!owner || ![owner[@"appType"] isEqual:descriptor[@"appType"]])
            return @"This container belongs to a different app. Select its app before continuing.";
    }
    if (![descriptor[@"runnable"] boolValue] && ![request[@"action"] isEqual:@"import-source"])
        return [NSString stringWithFormat:@"%@ is coming soon. Import its own decrypted source first; clone creation and launch remain disabled until its binary and lifecycle audit passes.", descriptor[@"displayName"]];
    return nil;
}

// A descriptor-only change must not accidentally enable a new app in the
// existing Reddit hook bootstrap, recovery journal or global network lease.
static inline NSString *RBXAppCloneBlockReason(NSDictionary *descriptor, NSDictionary *profile, BOOL hasSource) {
    NSDictionary *owner = RBXAppDescriptorForProfile(profile);
    if (!RBXAppDescriptorIsRegistered(descriptor) || !owner ||
        ![owner[@"appType"] isEqual:descriptor[@"appType"]])
        return @"Clone app type does not match its registered descriptor.";
    if (![descriptor[@"runnable"] boolValue]) {
        if (!hasSource) return [NSString stringWithFormat:@"No %@ source imported. Import a decrypted %@ IPA before creating a container.", descriptor[@"displayName"], descriptor[@"displayName"]];
        return [NSString stringWithFormat:@"%@ source is imported. Clone creation and launch require the Phase 2 binary, hook and lifecycle audit.", descriptor[@"displayName"]];
    }
    return RBXAppProfileIdentityBlockReason(descriptor, profile, nil);
}
