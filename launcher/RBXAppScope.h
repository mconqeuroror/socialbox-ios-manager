#pragma once
#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"

// App selection changes presentation only. The existing launcher owns unlock;
// a sheet, picker, or passcode prompt must finish before changing its workspace.
static inline BOOL RBXAppScopeMaySelect(id appType, BOOL workspaceUnlocked,
                                      BOOL presentingController) {
    return [appType isKindOfClass:NSString.class] && workspaceUnlocked && !presentingController &&
        RBXAppDescriptorForType(appType) != nil;
}

static inline NSString *RBXAppSourceImportRequestKey(NSDictionary *descriptor) {
    if (!RBXAppDescriptorIsRegistered(descriptor)) return nil;
    return descriptor[@"sourceImportRequestKey"];
}

// Keep existing Reddit persistence namespaces byte-for-byte; other apps cannot
// consume its durable receipts, wizard draft, or saved presentation settings.
static inline NSString *RBXAppScopedPreferenceKey(NSString *legacy, NSDictionary *descriptor) {
    if (!RBXAppDescriptorIsRegistered(descriptor) || !legacy.length) return nil;
    return [descriptor[@"appType"] isEqual:@"reddit"] ? legacy :
        [legacy stringByAppendingFormat:@".%@", descriptor[@"appType"]];
}

static inline NSDictionary *RBXAppScopedRequestValues(NSDictionary *values, NSDictionary *descriptor) {
    if (!RBXAppDescriptorIsRegistered(descriptor) ||
        (values && ![values isKindOfClass:NSDictionary.class])) return nil;
    if (values[@"appType"] && ![values[@"appType"] isEqual:descriptor[@"appType"]]) return nil;
    NSMutableDictionary *scoped = [values mutableCopy] ?: [NSMutableDictionary dictionary];
    scoped[@"appType"] = descriptor[@"appType"];
    return scoped;
}

static inline NSString *RBXAppSourceReadinessError(NSDictionary *state, NSDictionary *descriptor) {
    if (!RBXAppDescriptorIsRegistered(descriptor)) return @"Unknown app workspace.";
    if (![descriptor[@"runnable"] boolValue]) return [NSString stringWithFormat:
        @"%@ support is not enabled in this build.", descriptor[@"displayName"]];
    NSDictionary *source = [state isKindOfClass:NSDictionary.class] && [state[@"source"] isKindOfClass:NSDictionary.class] ? state[@"source"] : @{};
    if (![source[@"decrypted"] isKindOfClass:NSNumber.class] || ![source[@"decrypted"] boolValue]) return [NSString stringWithFormat:
        @"%@ source not imported. Import a decrypted %@ IPA in this workspace's Settings before creating a container.",
        descriptor[@"displayName"], descriptor[@"displayName"]];
    return nil;
}

// This is presentation scoping, not authorization. The daemon independently
// resolves each requested profile's app type before allowing any mutation.
static inline NSDictionary *RBXAppScopedLauncherState(id document, NSDictionary *descriptor) {
    if (![document isKindOfClass:NSDictionary.class] || !RBXAppDescriptorIsRegistered(descriptor)) return @{};
    NSMutableDictionary *state = [document mutableCopy];
    NSMutableSet *foreignIds = [NSMutableSet set];
    NSMutableSet *ownIds = [NSMutableSet set];
    id inventory = document[@"containers"];
    if ([inventory isKindOfClass:NSArray.class]) {
        NSMutableArray *containers = [NSMutableArray array];
        for (id row in inventory) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *owner = RBXAppDescriptorForProfile(row);
            if ([owner[@"appType"] isEqual:descriptor[@"appType"]]) {
                [containers addObject:row];
                if ([row[@"id"] isKindOfClass:NSString.class]) [ownIds addObject:row[@"id"]];
            }
            else if ([row[@"id"] isKindOfClass:NSString.class]) [foreignIds addObject:row[@"id"]];
        }
        state[@"containers"] = containers;
    }
    for (NSString *key in @[@"operation", @"sourceImport", @"cloneExport", @"identityResult"]) {
        id operation = state[key];
        if (![operation isKindOfClass:NSDictionary.class]) continue;
        id container = operation[@"containerId"] ?: operation[@"container"];
        BOOL otherApp = operation[@"appType"] &&
            ![RBXAppDescriptorForType(operation[@"appType"])[@"appType"] isEqual:descriptor[@"appType"]];
        BOOL unattributedForeign = !operation[@"appType"] &&
            ![descriptor[@"appType"] isEqual:@"reddit"] && (!container || ![ownIds containsObject:container]);
        if (otherApp || unattributedForeign || (container && [foreignIds containsObject:container])) state[key] = @{};
    }
    if (![descriptor[@"appType"] isEqual:RBXRedditAppDescriptor()[@"appType"]]) {
        // Never fall back to Reddit's legacy singleton source for another app.
        NSDictionary *sources = [document[@"sources"] isKindOfClass:NSDictionary.class] ? document[@"sources"] : @{};
        NSDictionary *imports = [document[@"sourceImports"] isKindOfClass:NSDictionary.class] ? document[@"sourceImports"] : @{};
        state[@"source"] = [sources[descriptor[@"appType"]] isKindOfClass:NSDictionary.class] ? sources[descriptor[@"appType"]] : @{};
        state[@"sourceImport"] = [imports[descriptor[@"appType"]] isKindOfClass:NSDictionary.class] ? imports[descriptor[@"appType"]] : @{};
    }
    NSDictionary *reports = [document[@"diagnosticsByApp"] isKindOfClass:NSDictionary.class] ? document[@"diagnosticsByApp"] : @{};
    if ([reports[descriptor[@"appType"]] isKindOfClass:NSDictionary.class]) state[@"diagnostics"] = reports[descriptor[@"appType"]];
    // License, lease, proxy, fallback diagnostics and recovery fences are device-wide.
    // Preserve them verbatim instead of hiding a shared failure in an app tab.
    return state;
}
