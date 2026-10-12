#import "LBXRecoveredContextAdapter.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>

// Evidence: recovered arm64 SocialBox 3.1.0-1, not a generic private-API adapter.
// SocialBox.c:91041/91069: _Xc9m containers/activeContainerID (0x1001295dc/600).
// SocialBox.c:213463/213490/213711: _Xv8i containerID/name/apps
// (0x1003065a8/5b8/64c). `otool -arch arm64 -ov` verifies @16@0:8 / q16@0:8.
// loadData (0x10010199c, c:79458) can repair/persist metadata; NEVER invoke it.
// toDictionary includes spoofProfile/proxy/GPS; NEVER invoke it.

static NSDictionary *LBXBaseSnapshot(NSString *status, NSString *reason) {
    return @{@"schemaVersion": @1, @"status": status, @"reason": reason,
             @"source": @"socialbox-3.1.0-1-cached-controller",
             @"contexts": @[], @"activeSelectionStatus": @"UNAVAILABLE",
             @"processBindingStatus": @"UNBOUND", @"identityStatus": @"UNKNOWN",
             @"isolationStatus": @"NOT_RUN", @"networkStatus": @"NOT_RUN",
             @"freshnessStatus": @"UNKNOWN",
             @"capabilities": @{@"readOnlyMetadata": @NO, @"runtimeBinding": @NO,
                                 @"isolationVerification": @NO, @"networkVerification": @NO}};
}

static BOOL LBXEqualString(id value, NSString *expected) {
    return [value isKindOfClass:NSString.class] && [value isEqualToString:expected];
}

static BOOL LBXImageMatches(const char *image, NSString *executablePath) {
    if (!image || !executablePath.length) return NO;
    // dyld paths are compared, not opened or resolved through the filesystem.
    NSString *path = [[NSString alloc] initWithUTF8String:image];
    return path && [path.stringByStandardizingPath
                    isEqualToString:executablePath.stringByStandardizingPath];
}

static Method LBXGetter(id object, Class expectedClass, SEL selector,
                        const char *encoding, NSString *executablePath) {
    if (!object || !expectedClass || object_getClass(object) != expectedClass ||
        !LBXImageMatches(class_getImageName(expectedClass), executablePath)) return NULL;
    Method method = class_getInstanceMethod(expectedClass, selector);
    const char *actual = method ? method_getTypeEncoding(method) : NULL;
    if (!actual || strcmp(actual, encoding) || method_getNumberOfArguments(method) != 2 ||
        ![object respondsToSelector:selector]) return NULL;
    Dl_info info = {0};
    // A same-name selector replaced by a different image is not the recovered getter.
    if (!dladdr((const void *)method_getImplementation(method), &info) ||
        !LBXImageMatches(info.dli_fname, executablePath)) return NULL;
    return method;
}

static id LBXReadObject(id object, Method method) {
    return ((id (*)(id, SEL))method_getImplementation(method))(object, method_getName(method));
}

static long long LBXReadID(id object, Method method) {
    return ((long long (*)(id, SEL))method_getImplementation(method))(object, method_getName(method));
}

static BOOL LBXValidBundleID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0 || [value length] > 255) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-"] invertedSet];
    return [value rangeOfCharacterFromSet:invalid].location == NSNotFound &&
           ![value hasPrefix:@"."] && ![value hasSuffix:@"."] &&
           [value rangeOfString:@".."].location == NSNotFound &&
           [value rangeOfString:@"."].location != NSNotFound;
}

static NSDictionary *LBXSnapshot(id controller, id bundleID, id version, id build,
                                  NSString *executablePath) {
    if (![NSThread isMainThread]) return LBXBaseSnapshot(@"UNAVAILABLE", @"MAIN_THREAD_REQUIRED");
    @try {
        if (!LBXEqualString(bundleID, @"com.socialbox.app") ||
            !LBXEqualString(version, @"3.1.0") || !LBXEqualString(build, @"1"))
            return LBXBaseSnapshot(@"UNAVAILABLE", @"UNSUPPORTED_HOST_VERSION");
        Class controllerClass = NSClassFromString(@"_Xc9m");
        Method listGetter = LBXGetter(controller, controllerClass, NSSelectorFromString(@"containers"),
                                      "@16@0:8", executablePath);
        Method selectedGetter = LBXGetter(controller, controllerClass, NSSelectorFromString(@"activeContainerID"),
                                          "q16@0:8", executablePath);
        if (!listGetter || !selectedGetter)
            return LBXBaseSnapshot(@"UNAVAILABLE", @"UNSUPPORTED_CONTROLLER_CONTRACT");
        long long before = LBXReadID(controller, selectedGetter);
        id rawRows = LBXReadObject(controller, listGetter);
        if (![rawRows isKindOfClass:NSArray.class] || [rawRows count] > 4096)
            return LBXBaseSnapshot(@"UNAVAILABLE", @"INVALID_CONTEXT_LIST");
        NSArray *rows = [rawRows copy];
        NSMutableArray *contexts = [NSMutableArray arrayWithCapacity:rows.count];
        NSMutableSet *seen = [NSMutableSet set];
        Class rowClass = NSClassFromString(@"_Xv8i");
        for (id row in rows) {
            Method identifier = LBXGetter(row, rowClass, NSSelectorFromString(@"containerID"),
                                          "q16@0:8", executablePath);
            Method name = LBXGetter(row, rowClass, NSSelectorFromString(@"name"),
                                    "@16@0:8", executablePath);
            Method apps = LBXGetter(row, rowClass, NSSelectorFromString(@"apps"),
                                    "@16@0:8", executablePath);
            if (!identifier || !name || !apps)
                return LBXBaseSnapshot(@"UNAVAILABLE", @"UNSUPPORTED_CONTEXT_CONTRACT");
            long long contextID = LBXReadID(row, identifier);
            id rawName = LBXReadObject(row, name);
            id rawApps = LBXReadObject(row, apps);
            if (contextID <= 0 || [seen containsObject:@(contextID)] ||
                ![rawName isKindOfClass:NSString.class] || [rawName length] == 0 || [rawName length] > 512)
                return LBXBaseSnapshot(@"UNAVAILABLE", @"INVALID_CONTEXT_METADATA");
            NSString *safeName = [rawName copy];
            if ([safeName rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
                return LBXBaseSnapshot(@"UNAVAILABLE", @"INVALID_CONTEXT_METADATA");
            if (rawApps && (![rawApps isKindOfClass:NSArray.class] || [rawApps count] > 256))
                return LBXBaseSnapshot(@"UNAVAILABLE", @"INVALID_APP_MEMBERSHIP");
            NSMutableArray *appIDs = [NSMutableArray array];
            NSMutableSet *seenApps = [NSMutableSet set];
            for (id rawApp in [rawApps copy]) {
                if (!LBXValidBundleID(rawApp) || [seenApps containsObject:rawApp])
                    return LBXBaseSnapshot(@"UNAVAILABLE", @"INVALID_APP_MEMBERSHIP");
                NSString *appID = [rawApp copy];
                [seenApps addObject:appID];
                [appIDs addObject:appID];
            }
            [seen addObject:@(contextID)];
            [contexts addObject:@{@"id": [NSString stringWithFormat:@"%lld", contextID], @"name": safeName,
                                  @"appBundleIDs": [appIDs copy],
                                  @"appMembershipStatus": rawApps ? @"OBSERVED_CACHED_UI" : @"UNAVAILABLE"}];
        }
        long long after = LBXReadID(controller, selectedGetter);
        if (before != after) return LBXBaseSnapshot(@"UNAVAILABLE", @"SELECTION_CHANGED_DURING_READ");
        // Stable ID only establishes a cached selection, not daemon/process agreement.
        NSMutableDictionary *snapshot = [LBXBaseSnapshot(@"AVAILABLE", @"CACHED_UI_METADATA_ONLY") mutableCopy];
        snapshot[@"contexts"] = [contexts copy];
        snapshot[@"capabilities"] = @{@"readOnlyMetadata": @YES, @"runtimeBinding": @NO,
                                      @"isolationVerification": @NO, @"networkVerification": @NO};
        if (before > 0 && [seen containsObject:@(before)]) {
            snapshot[@"activeContainerID"] = [NSString stringWithFormat:@"%lld", before];
            snapshot[@"activeSelectionStatus"] = @"OBSERVED_CACHED_UI";
        }
        return [snapshot copy];
    } @catch (__unused NSException *exception) {
        // Exception messages may contain private data; expose a fixed reason only.
        return LBXBaseSnapshot(@"UNAVAILABLE", @"CONTEXT_READ_FAILED");
    }
}

NSDictionary<NSString *, id> *LBXRecoveredContextSnapshot(id controller) {
    NSBundle *bundle = NSBundle.mainBundle;
    return LBXSnapshot(controller, bundle.bundleIdentifier,
                       [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                       [bundle objectForInfoDictionaryKey:@"CFBundleVersion"], bundle.executablePath);
}

#if defined(LBX_RECOVERED_CONTEXT_TESTING)
NSDictionary<NSString *, id> *LBXRecoveredContextSnapshotForTesting(
    id controller, id bundleID, id version, id build, NSString *executablePath) {
    return LBXSnapshot(controller, bundleID, version, build, executablePath);
}
#endif
