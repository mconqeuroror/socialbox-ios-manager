// SocialBoxAppKeychain.dylib — loads into Instagram and Facebook only.
//
// Partitions the apps' own keychain items by the active SocialBox container
// ID. Access groups stay the apps' published groups (no securityd hook, no
// agrp rewrite). Isolation is a CID prefix on kSecAttrAccount so container
// 108's items do not match container 109's queries.
//
// PINNED ABI: public Security.framework SecItemAdd / CopyMatching / Update /
// Delete. Hooks install by symbol name. Darwin major must be 22. Missing
// symbol or unsupported process → install nothing (fail-closed).

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CydiaSubstrate/CydiaSubstrate.h>
#import "LBXInjectCommon.h"

typedef OSStatus (*LBXSecItemQueryFn)(CFDictionaryRef query, CFTypeRef *result);
typedef OSStatus (*LBXSecItemUpdateFn)(CFDictionaryRef query, CFDictionaryRef attributes);
typedef OSStatus (*LBXSecItemDeleteFn)(CFDictionaryRef query);

static LBXSecItemQueryFn oSecItemCopyMatching;
static LBXSecItemQueryFn oSecItemAdd;
static LBXSecItemUpdateFn oSecItemUpdate;
static LBXSecItemDeleteFn oSecItemDelete;

static const char *kCat = "app-keychain";
static NSString *const kCanaryService = @"com.socialbox.partition";
static NSString *const kSidecarPath = @"/private/var/tmp/socialbox_keychain_partition.json";

static NSString *LBXHostBundle(void) {
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    NSString *host = LBXInjectHostBundleID(bundle);
    if (host) return host;
    NSString *exec = NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent;
    if ([exec isEqualToString:@"Instagram"]) return LBXInjectInstagramBundleID;
    if ([exec isEqualToString:@"Facebook"]) return LBXInjectFacebookBundleID;
    return nil;
}

static long long LBXCurrentCID(void) {
    NSString *host = LBXHostBundle();
    if (!host) return 0;
    return LBXInjectActiveContainerForBundleID(host);
}

static NSString *LBXPrefix(long long cid) {
    return [NSString stringWithFormat:@"sbx.%lld.", cid];
}

static BOOL LBXHasPrefix(NSString *account, long long cid) {
    return [account isKindOfClass:NSString.class] && [account hasPrefix:LBXPrefix(cid)];
}

static NSString *LBXApplyPrefix(NSString *account, long long cid) {
    NSString *prefix = LBXPrefix(cid);
    if (![account isKindOfClass:NSString.class] || account.length == 0) return prefix;
    if ([account hasPrefix:prefix]) return account;
    if ([account hasPrefix:@"sbx."]) return prefix; // foreign CID → do not echo it
    return [prefix stringByAppendingString:account];
}

static NSString *LBXStripPrefix(NSString *account, long long cid) {
    NSString *prefix = LBXPrefix(cid);
    if (![account isKindOfClass:NSString.class]) return account;
    if ([account hasPrefix:prefix]) return [account substringFromIndex:prefix.length];
    return account;
}

static NSMutableDictionary *LBXMutableQuery(CFDictionaryRef original) {
    if (!original) return nil;
    NSDictionary *dict = (__bridge NSDictionary *)original;
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    return [dict mutableCopy];
}

static void LBXPrefixAccountInPlace(NSMutableDictionary *query, long long cid) {
    id account = query[(__bridge id)kSecAttrAccount];
    query[(__bridge id)kSecAttrAccount] = LBXApplyPrefix([account isKindOfClass:NSString.class] ? account : nil, cid);
}

static id LBXStripResult(id result, long long cid) {
    if ([result isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *item = [result mutableCopy];
        id account = item[(__bridge id)kSecAttrAccount];
        if ([account isKindOfClass:NSString.class]) {
            item[(__bridge id)kSecAttrAccount] = LBXStripPrefix(account, cid);
        }
        return item;
    }
    if ([result isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in (NSArray *)result) {
            id stripped = LBXStripResult(item, cid);
            if (stripped) [out addObject:stripped];
        }
        return out;
    }
    return result;
}

static NSArray *LBXFilterItems(NSArray *items, long long cid) {
    NSMutableArray *out = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *account = item[(__bridge id)kSecAttrAccount];
        if (LBXHasPrefix(account, cid)) [out addObject:item];
    }
    return out;
}

static OSStatus LBXHookedCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (!oSecItemCopyMatching) return errSecUnimplemented;
    long long cid = LBXCurrentCID();
    if (cid < 1) return errSecItemNotFound;
    NSMutableDictionary *rewritten = LBXMutableQuery(query);
    if (!rewritten) return oSecItemCopyMatching(query, result);

    BOOL hadAccount = [rewritten[(__bridge id)kSecAttrAccount] isKindOfClass:NSString.class] &&
                      [rewritten[(__bridge id)kSecAttrAccount] length] > 0;
    if (hadAccount) {
        NSString *originalAccount = rewritten[(__bridge id)kSecAttrAccount];
        LBXPrefixAccountInPlace(rewritten, cid);
        CFTypeRef found = NULL;
        OSStatus st = oSecItemCopyMatching((__bridge CFDictionaryRef)rewritten, &found);
        if (st == errSecSuccess) {
            if (result) *result = found ? (__bridge_retained CFTypeRef)LBXStripResult((__bridge id)found, cid) : NULL;
            if (found) CFRelease(found);
            return errSecSuccess;
        }
        // One-time claim of a pre-partition item into this container.
        NSMutableDictionary *legacy = [rewritten mutableCopy];
        legacy[(__bridge id)kSecAttrAccount] = originalAccount;
        CFTypeRef legacyFound = NULL;
        if (oSecItemCopyMatching((__bridge CFDictionaryRef)legacy, &legacyFound) == errSecSuccess && legacyFound) {
            NSMutableDictionary *add = LBXMutableQuery(legacyFound);
            if (add) {
                LBXPrefixAccountInPlace(add, cid);
                add[(__bridge id)kSecClass] = rewritten[(__bridge id)kSecClass] ?: (__bridge id)kSecClassGenericPassword;
                oSecItemAdd((__bridge CFDictionaryRef)add, NULL);
                oSecItemDelete((__bridge CFDictionaryRef)legacy);
            }
            if (result) *result = (__bridge_retained CFTypeRef)LBXStripResult((__bridge id)legacyFound, cid);
            CFRelease(legacyFound);
            return errSecSuccess;
        }
        if (legacyFound) CFRelease(legacyFound);
        if (result) *result = NULL;
        return st;
    }

    // Broad query: fetch, keep only this CID's prefixed accounts.
    NSMutableDictionary *broad = [rewritten mutableCopy];
    broad[(__bridge id)kSecReturnAttributes] = @YES;
    if (!broad[(__bridge id)kSecMatchLimit]) broad[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    CFTypeRef raw = NULL;
    OSStatus st = oSecItemCopyMatching((__bridge CFDictionaryRef)broad, &raw);
    if (st != errSecSuccess || !raw) {
        if (result) *result = NULL;
        return st == errSecSuccess ? errSecItemNotFound : st;
    }
    NSArray *items = [(__bridge id)raw isKindOfClass:NSArray.class] ? (__bridge NSArray *)raw : @[ (__bridge id)raw ];
    NSArray *mine = LBXFilterItems(items, cid);
    CFRelease(raw);
    if (mine.count == 0) {
        if (result) *result = NULL;
        return errSecItemNotFound;
    }
    id body = [rewritten[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitOne] ||
              rewritten[(__bridge id)kSecMatchLimit] == nil
                  ? mine.firstObject
                  : mine;
    if (result) *result = (__bridge_retained CFTypeRef)LBXStripResult(body, cid);
    return errSecSuccess;
}

static OSStatus LBXHookedAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (!oSecItemAdd) return errSecUnimplemented;
    long long cid = LBXCurrentCID();
    if (cid < 1) return errSecMissingEntitlement;
    NSMutableDictionary *rewritten = LBXMutableQuery(attributes);
    if (!rewritten) return oSecItemAdd(attributes, result);
    LBXPrefixAccountInPlace(rewritten, cid);
    CFTypeRef found = NULL;
    OSStatus st = oSecItemAdd((__bridge CFDictionaryRef)rewritten, &found);
    if (st == errSecSuccess && result) {
        *result = found ? (__bridge_retained CFTypeRef)LBXStripResult((__bridge id)found, cid) : NULL;
    }
    if (found) CFRelease(found);
    return st;
}

static OSStatus LBXHookedUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (!oSecItemUpdate) return errSecUnimplemented;
    long long cid = LBXCurrentCID();
    if (cid < 1) return errSecItemNotFound;
    NSMutableDictionary *q = LBXMutableQuery(query);
    NSMutableDictionary *u = LBXMutableQuery(attributesToUpdate);
    if (!q) return oSecItemUpdate(query, attributesToUpdate);
    LBXPrefixAccountInPlace(q, cid);
    if (u && u[(__bridge id)kSecAttrAccount]) LBXPrefixAccountInPlace(u, cid);
    return oSecItemUpdate((__bridge CFDictionaryRef)q, u ? (__bridge CFDictionaryRef)u : attributesToUpdate);
}

static OSStatus LBXHookedDelete(CFDictionaryRef query) {
    if (!oSecItemDelete) return errSecUnimplemented;
    long long cid = LBXCurrentCID();
    if (cid < 1) return errSecItemNotFound;
    NSMutableDictionary *q = LBXMutableQuery(query);
    if (!q) return oSecItemDelete(query);
    if ([q[(__bridge id)kSecAttrAccount] isKindOfClass:NSString.class]) {
        LBXPrefixAccountInPlace(q, cid);
    } else {
        // Refuse unscoped deletes so a container cannot wipe another container's items.
        return errSecParam;
    }
    return oSecItemDelete((__bridge CFDictionaryRef)q);
}

static void LBXWriteSidecar(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!data.length) return;
    [data writeToFile:kSidecarPath atomically:YES];
}

static void LBXSelfTest(void) {
    long long cid = LBXCurrentCID();
    NSString *host = LBXHostBundle();
    if (cid < 1 || !host || !oSecItemAdd || !oSecItemCopyMatching || !oSecItemDelete) {
        LBXWriteSidecar(@{
            @"status" : @"NOT_SEPARATED",
            @"reason" : @"no-selection-or-hooks",
            @"hookInstalled" : @YES,
        });
        return;
    }
    NSString *ownAccount = LBXApplyPrefix(@"canary", cid);
    NSDictionary *own = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : kCanaryService,
        (__bridge id)kSecAttrAccount : ownAccount,
        (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    oSecItemDelete((__bridge CFDictionaryRef)own);
    OSStatus added = oSecItemAdd((__bridge CFDictionaryRef)own, NULL);

    NSDictionary *findOwn = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : kCanaryService,
        (__bridge id)kSecAttrAccount : @"canary",
        (__bridge id)kSecReturnAttributes : @YES,
    };
    CFTypeRef ownResult = NULL;
    OSStatus ownSt = LBXHookedCopyMatching((__bridge CFDictionaryRef)findOwn, &ownResult);
    BOOL ownFound = (ownSt == errSecSuccess && ownResult != NULL);
    if (ownResult) CFRelease(ownResult);

    NSString *poisonAccount = @"sbx.999999.poison";
    NSDictionary *poison = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : kCanaryService,
        (__bridge id)kSecAttrAccount : poisonAccount,
        (__bridge id)kSecAttrAccessible : (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    oSecItemDelete((__bridge CFDictionaryRef)poison);
    oSecItemAdd((__bridge CFDictionaryRef)poison, NULL);
    NSDictionary *findPoison = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : kCanaryService,
        (__bridge id)kSecAttrAccount : @"poison",
        (__bridge id)kSecReturnAttributes : @YES,
    };
    CFTypeRef poisonResult = NULL;
    OSStatus poisonSt = LBXHookedCopyMatching((__bridge CFDictionaryRef)findPoison, &poisonResult);
    BOOL foreignFound = (poisonSt == errSecSuccess && poisonResult != NULL);
    if (poisonResult) CFRelease(poisonResult);
    oSecItemDelete((__bridge CFDictionaryRef)poison);

    BOOL separated = (added == errSecSuccess || added == errSecDuplicateItem) && ownFound && !foreignFound;
    LBXWriteSidecar(@{
        @"status" : separated ? @"SEPARATED" : @"NOT_SEPARATED",
        @"separated" : @(separated),
        @"hookInstalled" : @YES,
        @"bundle" : host,
        @"cid" : @(cid),
        @"ownCanaryFound" : @(ownFound),
        @"foreignCanaryFound" : @(foreignFound),
        @"addStatus" : @(added),
    });
    LBXInjectLog(kCat, @"self-test cid=%lld own=%d foreign=%d separated=%d", cid, ownFound, foreignFound, separated);
}

__attribute__((constructor))
static void LBXAppKeychainConstructor(void) {
    if (!LBXInjectOSMajorIsPinned()) {
        LBXInjectLog(kCat, @"os-major-not-pinned; hooks not installed");
        return;
    }
    if (!LBXHostBundle()) return;
    MSHookFunction((void *)SecItemCopyMatching, (void *)LBXHookedCopyMatching, (void **)&oSecItemCopyMatching);
    MSHookFunction((void *)SecItemAdd, (void *)LBXHookedAdd, (void **)&oSecItemAdd);
    MSHookFunction((void *)SecItemUpdate, (void *)LBXHookedUpdate, (void **)&oSecItemUpdate);
    MSHookFunction((void *)SecItemDelete, (void *)LBXHookedDelete, (void **)&oSecItemDelete);
    if (!oSecItemCopyMatching || !oSecItemAdd || !oSecItemUpdate || !oSecItemDelete) {
        LBXInjectLog(kCat, @"symbol-missing; fail-closed with no hooks");
        oSecItemCopyMatching = NULL;
        oSecItemAdd = NULL;
        oSecItemUpdate = NULL;
        oSecItemDelete = NULL;
        return;
    }
    LBXInjectLog(kCat, @"hooks-installed host=%@", LBXHostBundle());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(400 * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                       @autoreleasepool { LBXSelfTest(); }
                   });
}
