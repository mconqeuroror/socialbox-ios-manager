#ifndef RBX_APP_PROCESS_H
#define RBX_APP_PROCESS_H

#import <Foundation/Foundation.h>
#import "RBXAppRegistry.h"

// Pure evidence classification used after reading the kernel and LaunchServices.
// It never uses an executable-name prefix, and never performs a kill itself.
static inline void RBXAppProcessError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.proc" code:6
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

static inline BOOL RBXAppProcessProtectedIdentifier(id identifier) {
    return [@[@"com.redditbox.launcher", @"com.redditbox.daemon", @"com.redditboxd",
        @"com.redditbox.firewall", @"com.redditbox.firewall.PacketTunnel"] containsObject:identifier ?: NSNull.null];
}

static inline BOOL RBXAppProcessDescriptorValid(id descriptor) {
    return RBXAppDescriptorIsRegistered(descriptor);
}

// NO without an error means another app (or infrastructure), not a bad snapshot.
// A malformed identity in the selected family is unprovable, never silently safe.
static inline BOOL RBXAppProcessCandidate(NSDictionary *descriptor, NSDictionary *info,
                                         NSDictionary *marker, NSError **error) {
    if (!RBXAppProcessDescriptorValid(descriptor)) {
        RBXAppProcessError(error, @"Process inspection requires a registered app descriptor"); return NO;
    }
    NSString *identifier = [info isKindOfClass:NSDictionary.class] &&
        [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] ? info[@"CFBundleIdentifier"] : nil;
    if (!identifier.length) {
        RBXAppProcessError(error, @"cannot identify a live application bundle"); return NO;
    }
    if (RBXAppProcessProtectedIdentifier(identifier)) return NO;
    if ([identifier isEqual:descriptor[@"sourceBundleIdentifier"]]) return YES;
    if (![identifier hasPrefix:descriptor[@"cloneBundlePrefix"]]) return NO;
    NSString *container = [marker isKindOfClass:NSDictionary.class] &&
        [marker[@"containerId"] isKindOfClass:NSString.class] ? marker[@"containerId"] : nil;
    if (!container.length || ![identifier isEqual:RBXAppBundleIdentifier(descriptor, container)] ||
        ![marker[@"bundleIdentifier"] isEqual:identifier] ||
        (marker[@"appType"] && ![marker[@"appType"] isEqual:descriptor[@"appType"]])) {
        RBXAppProcessError(error, @"cannot verify a running clone's identity"); return NO;
    }
    return YES;
}

static inline BOOL RBXAppProcessExecutableName(id value) {
    return [value isKindOfClass:NSString.class] && [value length] &&
        [value isEqual:[value lastPathComponent]] && ![@[@".", @".."] containsObject:value] &&
        ![value containsString:@"\\"];
}

// All paths supplied by the caller are canonical filesystem evidence. Each
// extension is { bundlePath, info }; only a direct embedded PlugIns/*.appex
// executable qualifies. A lookalike app or path prefix is insufficient.
static inline BOOL RBXAppProcessRegisteredMatch(NSDictionary *descriptor,
    NSString *processPath, NSString *bundlePath, NSDictionary *info, NSDictionary *marker,
    NSString *registeredBundlePath, NSArray<NSDictionary *> *extensions, NSError **error) {
    if (!RBXAppProcessCandidate(descriptor, info, marker, error)) return NO;
    if (![processPath isKindOfClass:NSString.class] || !processPath.isAbsolutePath ||
        ![bundlePath isKindOfClass:NSString.class] || !bundlePath.isAbsolutePath ||
        ![bundlePath isEqual:bundlePath.stringByStandardizingPath] ||
        ![bundlePath.pathExtension isEqual:@"app"] ||
        ![registeredBundlePath isKindOfClass:NSString.class] ||
        ![registeredBundlePath isEqual:bundlePath]) {
        RBXAppProcessError(error, @"running app path differs from its registered bundle"); return NO;
    }
    if (!RBXAppProcessExecutableName(info[@"CFBundleExecutable"])) {
        RBXAppProcessError(error, @"registered application executable name is invalid"); return NO;
    }
    NSString *expected = [bundlePath stringByAppendingPathComponent:info[@"CFBundleExecutable"]];
    if ([processPath isEqual:expected]) return YES;
    NSString *plugins = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    for (id item in extensions) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *extension = [item[@"bundlePath"] isKindOfClass:NSString.class] ? item[@"bundlePath"] : nil;
        NSDictionary *extensionInfo = [item[@"info"] isKindOfClass:NSDictionary.class] ? item[@"info"] : nil;
        if (![extension.stringByDeletingLastPathComponent isEqual:plugins] ||
            ![extension.pathExtension isEqual:@"appex"] ||
            RBXAppProcessProtectedIdentifier(extensionInfo[@"CFBundleIdentifier"]) ||
            !RBXAppProcessExecutableName(extensionInfo[@"CFBundleExecutable"])) continue;
        if ([processPath isEqual:[extension stringByAppendingPathComponent:extensionInfo[@"CFBundleExecutable"]]]) return YES;
    }
    RBXAppProcessError(error, @"running app executable cannot be proven from its registration");
    return NO;
}

#endif
