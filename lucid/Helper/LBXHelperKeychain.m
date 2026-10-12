#import "LBXHelperKeychain.h"
#import "LBXHelperPaths.h"
#import "LBXHelperProtocol.h"
#import "../Switching/LBXSocialBoxProduct.h"
#import <Security/Security.h>

static NSError *LBXKeyError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LBXHelperErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSString *LBXHelperAccessGroupForContainer(long long containerID) {
    return [NSString stringWithFormat:@"%%.%s.%lld", LBX_SOCIALBOX_KEYCHAIN_TOKEN, containerID];
}

static NSArray *LBXSecClasses(void) {
    return @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity,
    ];
}

NSDictionary *LBXHelperDumpKeychain(NSString *bundleID, long long containerID, NSError **error) {
    if (!LBXHelperIsIGOrFB(bundleID) || !LBXHelperIsNumericContainerID(containerID)) {
        if (error) *error = LBXKeyError(LBXHelperErrorInvalidArgument, @"IG/FB numeric CID required");
        return nil;
    }
    NSString *agrp = LBXHelperAccessGroupForContainer(containerID);
    NSMutableArray *all = [NSMutableArray array];
    for (id secClass in LBXSecClasses()) {
        NSDictionary *query = @{
            (__bridge id)kSecClass : secClass,
            (__bridge id)kSecAttrAccessGroup : agrp,
            (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnAttributes : @YES,
            (__bridge id)kSecReturnData : @YES,
            (__bridge id)kSecReturnRef : @NO,
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecItemNotFound) continue;
        if (status != errSecSuccess) {
            if (error)
                *error = LBXKeyError(LBXHelperErrorOperationFailed,
                                     [NSString stringWithFormat:@"SecItemCopyMatching %d", (int)status]);
            if (result) CFRelease(result);
            return nil;
        }
        if (CFGetTypeID(result) == CFArrayGetTypeID()) {
            for (id item in (__bridge NSArray *)result) {
                if (![item isKindOfClass:NSDictionary.class]) continue;
                NSMutableDictionary *row = [item mutableCopy];
                row[@"__secClass"] = [secClass description];
                [all addObject:row];
            }
        }
        CFRelease(result);
    }
    return @{
        @"bundleID" : bundleID,
        @"containerID" : @(containerID),
        @"accessGroup" : agrp,
        @"items" : all,
    };
}

BOOL LBXHelperRestoreKeychain(NSDictionary *items, NSString *bundleID, long long containerID,
                              NSError **error) {
    if (!LBXHelperIsIGOrFB(bundleID) || !LBXHelperIsNumericContainerID(containerID) ||
        ![items isKindOfClass:NSDictionary.class]) {
        if (error) *error = LBXKeyError(LBXHelperErrorInvalidArgument, @"invalid restore payload");
        return NO;
    }
    NSString *agrp = LBXHelperAccessGroupForContainer(containerID);
    NSArray *rows = items[@"items"];
    if (![rows isKindOfClass:NSArray.class]) {
        if (error) *error = LBXKeyError(LBXHelperErrorInvalidArgument, @"missing items array");
        return NO;
    }
    for (id row in rows) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *add = [row mutableCopy];
        [add removeObjectForKey:@"__secClass"];
        add[(__bridge id)kSecAttrAccessGroup] = agrp;
        // Prefer class from archive marker when present.
        id marked = row[@"__secClass"];
        if ([marked isKindOfClass:NSString.class]) {
            for (id secClass in LBXSecClasses()) {
                if ([[secClass description] isEqual:marked]) {
                    add[(__bridge id)kSecClass] = secClass;
                    break;
                }
            }
        }
        if (!add[(__bridge id)kSecClass])
            add[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (status == errSecDuplicateItem) {
            NSDictionary *del = @{
                (__bridge id)kSecClass : add[(__bridge id)kSecClass],
                (__bridge id)kSecAttrAccessGroup : agrp,
                (__bridge id)kSecAttrAccount : add[(__bridge id)kSecAttrAccount] ?: [NSNull null],
                (__bridge id)kSecAttrService : add[(__bridge id)kSecAttrService] ?: [NSNull null],
            };
            NSMutableDictionary *clean = [del mutableCopy];
            for (id key in del)
                if (del[key] == [NSNull null]) [clean removeObjectForKey:key];
            SecItemDelete((__bridge CFDictionaryRef)clean);
            status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        }
        if (status != errSecSuccess) {
            if (error)
                *error = LBXKeyError(LBXHelperErrorOperationFailed,
                                     [NSString stringWithFormat:@"SecItemAdd %d", (int)status]);
            return NO;
        }
    }
    return YES;
}

BOOL LBXHelperClearKeychain(NSString *bundleID, BOOL nuclear, NSError **error) {
    if (!LBXHelperIsIGOrFB(bundleID)) {
        if (error) *error = LBXKeyError(LBXHelperErrorInvalidArgument, @"IG/FB required");
        return NO;
    }
    // Nuclear clears a bounded CID range for this product agrp token. Non-nuclear
    // still needs an explicit container — refuse ambiguous clears.
    if (!nuclear) {
        if (error)
            *error = LBXKeyError(LBXHelperErrorInvalidArgument,
                                 @"non-nuclear clear requires dump/restore per containerID");
        return NO;
    }
    for (long long cid = 1; cid <= 32; cid++) {
        NSString *agrp = LBXHelperAccessGroupForContainer(cid);
        for (id secClass in LBXSecClasses()) {
            NSDictionary *query = @{
                (__bridge id)kSecClass : secClass,
                (__bridge id)kSecAttrAccessGroup : agrp,
            };
            OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
            if (status != errSecSuccess && status != errSecItemNotFound) {
                if (error)
                    *error = LBXKeyError(LBXHelperErrorOperationFailed,
                                         [NSString stringWithFormat:@"SecItemDelete %d", (int)status]);
                return NO;
            }
        }
    }
    return YES;
}
