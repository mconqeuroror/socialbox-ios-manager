#import "RBXKeychainHooks.h"
#import "RBXHookInstallation.h"
#import "RBXKeychainSyncPolicy.h"
#import "RBXAppKeychainPolicy.h"
#import "RBXAppRuntime.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <substrate.h>

// Dormant legacy item-namespace implementation. The current clone constructor
// does not install it; active Security policies are at the bottom of this file.
//
// Design: we do NOT remap kSecAttrAccessGroup. Rewriting to a new group only works if
// that group is in the app's `keychain-access-groups` entitlement; otherwise SecItemAdd
// fails with errSecMissingEntitlement (-34018) and login breaks. Reddit does not hold a
// wildcard group we can safely retarget, so instead we namespace the item IDENTITY per
// container: class-appropriate identity attributes (including generic data where valid)
// are prefixed with an opaque per-container marker. The access group stays UNCHANGED, so
// entitlements are satisfied, yet two containers can never collide on or read each other's
// items — an item stored as "reddit" in container A is really "<marker A>reddit", which a
// query in container B (searching for "<marker B>reddit") can never match.
//
// The same transform is applied on Add / CopyMatching / Update / Delete so lookups still
// resolve inside the container. CopyMatching reverses the transform in returned attributes
// so the app sees its original values. Broad queries (no primary key) are constrained to
// this container by post-filtering on the marker. Items are forced non-synchronizable so
// nothing rides iCloud keychain upstream and links accounts.

// Opaque per-container marker, e.g. "\x01rbx\x01<containerId>\x01". The control-char
// delimiters make accidental collisions with real service/account strings impossible.
static NSString *sPrefix;
static NSData *sPrefixData;

// Attributes which may carry a marker. kSecAttrGeneric is valid only for generic
// passwords, but is useful both as caller identity and as the fallback marker for an
// otherwise anonymous generic-password item. kSecAttrApplicationLabel is deliberately
// excluded: it is system-computed key material and cannot safely be rewritten.
static NSArray *rbxIdentityKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[ (__bridge id)kSecAttrService,
                  (__bridge id)kSecAttrAccount,
                  (__bridge id)kSecAttrServer,
                  (__bridge id)kSecAttrLabel,
                  (__bridge id)kSecAttrApplicationTag,
                  (__bridge id)kSecAttrGeneric ];
    });
    return keys;
}

static CFTypeRef rbxEffectiveAddClass(NSMutableDictionary *dict) {
    id explicitClass = dict[(__bridge id)kSecClass];
    if (explicitClass) return (__bridge CFTypeRef)explicitClass;

    id valueRef = dict[(__bridge id)kSecValueRef];
    if (!valueRef) return NULL;
    CFTypeRef ref = (__bridge CFTypeRef)valueRef;
    CFTypeID typeID = CFGetTypeID(ref);
    CFTypeRef inferredClass = NULL;
    if (typeID == SecKeyGetTypeID()) inferredClass = kSecClassKey;
    else if (typeID == SecCertificateGetTypeID()) inferredClass = kSecClassCertificate;
    else if (typeID == SecIdentityGetTypeID()) inferredClass = kSecClassIdentity;
    if (inferredClass)
        dict[(__bridge id)kSecClass] = (__bridge id)inferredClass;
    return inferredClass;
}

static BOOL rbxValueHasPrefix(id value, NSString *prefix, NSData *prefixData) {
    if ([value isKindOfClass:[NSString class]])
        return [(NSString *)value hasPrefix:prefix];
    if ([value isKindOfClass:[NSData class]]) {
        NSData *data = value;
        return data.length >= prefixData.length &&
               [[data subdataWithRange:NSMakeRange(0, prefixData.length)] isEqualToData:prefixData];
    }
    return NO;
}

static id rbxApplyPrefix(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = value;
        if ([s hasPrefix:sPrefix]) return s;
        return [sPrefix stringByAppendingString:s];
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *d = value;
        if (d.length >= sPrefixData.length &&
            [[d subdataWithRange:NSMakeRange(0, sPrefixData.length)] isEqualToData:sPrefixData])
            return d;
        NSMutableData *m = [sPrefixData mutableCopy];
        [m appendData:d];
        return m;
    }
    return value;
}

static id rbxStripPrefix(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = value;
        if ([s hasPrefix:sPrefix]) return [s substringFromIndex:sPrefix.length];
        return s;
    }
    if ([value isKindOfClass:[NSData class]]) {
        NSData *d = value;
        if (d.length >= sPrefixData.length &&
            [[d subdataWithRange:NSMakeRange(0, sPrefixData.length)] isEqualToData:sPrefixData])
            return [d subdataWithRange:NSMakeRange(sPrefixData.length, d.length - sPrefixData.length)];
        return d;
    }
    return value;
}

static BOOL rbxKeyIsValidForDictionary(id key, NSDictionary *dict) {
    if (![key isEqual:(__bridge id)kSecAttrGeneric]) return YES;
    // A missing class is permitted only for persistent-reference queries. If a caller
    // supplied kSecAttrGeneric anyway, namespacing it preserves fail-closed behavior.
    id itemClass = dict[(__bridge id)kSecClass];
    return !itemClass || [itemClass isEqual:(__bridge id)kSecClassGenericPassword];
}

// Namespace every valid marker-bearing attribute present. YES means the resulting query
// has a namespaced selector and therefore cannot match an unmarked sibling item.
static BOOL rbxNamespaceDict(NSMutableDictionary *dict) {
    BOOL any = NO;
    for (id key in rbxIdentityKeys()) {
        if (!rbxKeyIsValidForDictionary(key, dict)) continue;
        id v = dict[key];
        if (v && ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSData class]])) {
            dict[key] = rbxApplyPrefix(v);
            any = YES;
        }
    }
    return any;
}

static void rbxDenamespaceDict(NSMutableDictionary *dict) {
    for (id key in rbxIdentityKeys()) {
        id v = dict[key];
        if (v && ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSData class]]))
            dict[key] = rbxStripPrefix(v);
    }
}

static BOOL rbxSynchronizableIsRejected(NSDictionary *dict) {
    id value = dict[(__bridge id)kSecAttrSynchronizable];
    return value && ![value isEqual:(__bridge id)kCFBooleanFalse];
}

static BOOL rbxUsesSecureEnclave(NSDictionary *dict) {
    id token = dict[(__bridge id)kSecAttrTokenID];
    if (token && [token isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave])
        return YES;

    id valueRef = dict[(__bridge id)kSecValueRef];
    if (!valueRef) return NO;
    CFTypeRef ref = (__bridge CFTypeRef)valueRef;
    if (CFGetTypeID(ref) != SecKeyGetTypeID()) return NO;
    CFDictionaryRef keyAttributes = SecKeyCopyAttributes((SecKeyRef)ref);
    if (!keyAttributes) return YES;
    NSDictionary *attributes = CFBridgingRelease(keyAttributes);
    id keyToken = attributes[(__bridge id)kSecAttrTokenID];
    return keyToken && [keyToken isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave];
}

static BOOL rbxSecureEnclaveIsRejected(NSDictionary *dict) {
    if (!rbxUsesSecureEnclave(dict)) return NO;
    NSString *policy = [[RBXContainerManager sharedManager].currentProfile
                        valueForPath:@"security.appAttest"];
    return ![policy isEqualToString:@"enabled"];
}

// Adds with no caller identity still need a marker that Security accepts for the class.
// Generic data is valid for generic passwords; label is valid for internet passwords,
// certificates, and identities; application tag is valid for keys.
static OSStatus rbxEnsureAddMarker(NSMutableDictionary *dict) {
    CFTypeRef itemClass = rbxEffectiveAddClass(dict);
    if (!itemClass) return errSecParam;
    if (rbxNamespaceDict(dict)) return errSecSuccess;

    id markerKey = nil;
    id markerValue = nil;
    if (CFEqual(itemClass, kSecClassGenericPassword)) {
        markerKey = (__bridge id)kSecAttrGeneric;
        markerValue = sPrefixData;
    } else if (CFEqual(itemClass, kSecClassInternetPassword) ||
               CFEqual(itemClass, kSecClassCertificate) ||
               CFEqual(itemClass, kSecClassIdentity)) {
        markerKey = (__bridge id)kSecAttrLabel;
        markerValue = sPrefix;
    } else if (CFEqual(itemClass, kSecClassKey)) {
        markerKey = (__bridge id)kSecAttrApplicationTag;
        markerValue = sPrefixData;
    } else {
        return errSecParam;
    }
    dict[markerKey] = markerValue;
    return errSecSuccess;
}

// Ownership is positive only when at least one marker is ours and no marker belongs to a
// different RedditBox container. Unmarked attributes are allowed because Security may add
// class-specific defaults of its own.
static BOOL rbxItemIsOurs(NSDictionary *attrs) {
    static NSString *allPrefix;
    static NSData *allPrefixData;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allPrefix = @"\x01rbx\x01";
        allPrefixData = [allPrefix dataUsingEncoding:NSUTF8StringEncoding];
    });

    BOOL ours = NO;
    for (id key in rbxIdentityKeys()) {
        id v = attrs[key];
        if (!v) continue;
        if (rbxValueHasPrefix(v, sPrefix, sPrefixData)) ours = YES;
        else if (rbxValueHasPrefix(v, allPrefix, allPrefixData)) return NO;
    }
    return ours;
}

static id rbxReverseResultObject(id obj) {
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [obj mutableCopy];
        rbxDenamespaceDict(m);
        return m;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id it in obj) [arr addObject:rbxReverseResultObject(it)];
        return arr;
    }
    return obj;
}

// Build the caller-facing return object from a full item dict (attributes plus any of
// kSecValueData/Ref/PersistentRef), honoring exactly which return types the caller asked
// for. When more than one is requested the keychain returns a dictionary; a single request
// returns the raw value.
static id rbxBuildReturn(NSDictionary *full, BOOL wantData, BOOL wantAttrs, BOOL wantRef, BOOL wantPRef) {
    id dataV = full[(__bridge id)kSecValueData];
    id refV  = full[(__bridge id)kSecValueRef];
    id prefV = full[(__bridge id)kSecValuePersistentRef];

    NSMutableDictionary *attrs = [full mutableCopy];
    [attrs removeObjectForKey:(__bridge id)kSecValueData];
    [attrs removeObjectForKey:(__bridge id)kSecValueRef];
    [attrs removeObjectForKey:(__bridge id)kSecValuePersistentRef];

    int n = (wantData ? 1 : 0) + (wantAttrs ? 1 : 0) + (wantRef ? 1 : 0) + (wantPRef ? 1 : 0);
    if (n <= 1) {
        if (wantData) return dataV;
        if (wantAttrs) return attrs;
        if (wantRef) return refV;
        if (wantPRef) return prefV;
        return nil;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (wantData && dataV) out[(__bridge id)kSecValueData] = dataV;
    if (wantRef && refV) out[(__bridge id)kSecValueRef] = refV;
    if (wantPRef && prefV) out[(__bridge id)kSecValuePersistentRef] = prefV;
    if (wantAttrs) [out addEntriesFromDictionary:attrs];
    return out;
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static void (*orig_SecAddSharedWebCredential)(
    CFStringRef, CFStringRef, CFStringRef, void (^)(CFErrorRef));
static void (*orig_SecRequestSharedWebCredential)(
    CFStringRef, CFStringRef, void (^)(CFArrayRef, CFErrorRef));

static void rbxLogAddEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ RBXLog("SecItemAdd isolation hook entered"); });
}

static void rbxLogCopyEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ RBXLog("SecItemCopyMatching isolation hook entered"); });
}

static void rbxLogUpdateEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ RBXLog("SecItemUpdate isolation hook entered"); });
}

static void rbxLogDeleteEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ RBXLog("SecItemDelete isolation hook entered"); });
}

// Persistent refs cannot be namespaced. Verify ownership with an attributes-only lookup
// before honoring one; no secret data or object reference is requested during verification.
static OSStatus rbxVerifyPersistentRef(NSDictionary *query) {
    id persistentRef = query[(__bridge id)kSecValuePersistentRef];
    if (!persistentRef) return errSecParam;

    NSMutableDictionary *vq = [NSMutableDictionary dictionary];
    vq[(__bridge id)kSecValuePersistentRef] = persistentRef;
    vq[(__bridge id)kSecReturnAttributes] = (__bridge id)kCFBooleanTrue;
    if (query[(__bridge id)kSecUseAuthenticationContext])
        vq[(__bridge id)kSecUseAuthenticationContext] =
            query[(__bridge id)kSecUseAuthenticationContext];
    vq[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;

    CFTypeRef out = NULL;
    OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)vq, &out);
    if (status != errSecSuccess) {
        if (out) CFRelease(out);
        return status;
    }
    id object = out ? (__bridge_transfer id)out : nil;
    if (![object isKindOfClass:[NSDictionary class]] || !rbxItemIsOurs(object))
        return errSecItemNotFound;
    return errSecSuccess;
}

// Collect this container's persistent refs for a broad operation. The status is kept
// separate so lookup failures are not accidentally collapsed into "not found."
static NSArray *rbxOurPersistentRefs(NSDictionary *namespacedQuery, OSStatus *statusOut) {
    NSMutableDictionary *fq = [namespacedQuery mutableCopy];
    fq[(__bridge id)kSecReturnAttributes] = (__bridge id)kCFBooleanTrue;
    fq[(__bridge id)kSecReturnPersistentRef] = (__bridge id)kCFBooleanTrue;
    fq[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    fq[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;
    [fq removeObjectForKey:(__bridge id)kSecReturnData];
    [fq removeObjectForKey:(__bridge id)kSecReturnRef];

    CFTypeRef out = NULL;
    OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)fq, &out);
    if (st != errSecSuccess) {
        if (out) CFRelease(out);
        if (statusOut) *statusOut = st;
        return nil;
    }
    if (statusOut) *statusOut = errSecSuccess;
    if (!out) return @[];

    id outObj = (__bridge_transfer id)out;
    NSArray *items = [outObj isKindOfClass:[NSArray class]] ? outObj : @[outObj];
    NSMutableArray *refs = [NSMutableArray array];
    for (id it in items) {
        if ([it isKindOfClass:[NSDictionary class]] && rbxItemIsOurs(it)) {
            id pref = it[(__bridge id)kSecValuePersistentRef];
            if (pref) [refs addObject:pref];
        }
    }
    return refs;
}

static OSStatus replaced_SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    rbxLogAddEntry();
    if (!query || !sPrefix) return errSecParam;

    NSMutableDictionary *mq = [(__bridge NSDictionary *)query mutableCopy];
    if (rbxSynchronizableIsRejected(mq) || rbxSecureEnclaveIsRejected(mq) ||
        mq[(__bridge id)kSecAttrApplicationLabel]) {
        if (result) *result = NULL;
        return errSecParam;
    }
    OSStatus prep = rbxEnsureAddMarker(mq);
    if (prep != errSecSuccess) {
        if (result) *result = NULL;
        return prep;
    }
    mq[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kCFBooleanFalse;

    CFTypeRef out = NULL;
    OSStatus st = orig_SecItemAdd((__bridge CFDictionaryRef)mq, result ? &out : NULL);
    if (result) {
        if (out) {
            id reversed = rbxReverseResultObject((__bridge_transfer id)out);
            *result = (__bridge_retained CFTypeRef)reversed;
        } else {
            *result = NULL;
        }
    }
    return st;
}

static OSStatus replaced_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    rbxLogCopyEntry();
    if (result) *result = NULL;
    if (!query || !sPrefix) return errSecParam;

    NSDictionary *q = (__bridge NSDictionary *)query;
    if (rbxSynchronizableIsRejected(q) || rbxSecureEnclaveIsRejected(q))
        return errSecParam;

    BOOL hasPersistentRef = q[(__bridge id)kSecValuePersistentRef] != nil;

    NSMutableDictionary *mq = [q mutableCopy];
    BOOL narrow = rbxNamespaceDict(mq);
    if (!hasPersistentRef)
        mq[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kCFBooleanFalse;

    BOOL wantData = [q[(__bridge id)kSecReturnData] boolValue];
    BOOL wantAttrs = [q[(__bridge id)kSecReturnAttributes] boolValue];
    BOOL wantRef = [q[(__bridge id)kSecReturnRef] boolValue];
    BOOL wantPRef = [q[(__bridge id)kSecReturnPersistentRef] boolValue];
    int wantCount = (wantData ? 1 : 0) + (wantAttrs ? 1 : 0) + (wantRef ? 1 : 0) + (wantPRef ? 1 : 0);
    id matchLimit = q[(__bridge id)kSecMatchLimit];
    BOOL wantAll = matchLimit && [matchLimit isEqual:(__bridge id)kSecMatchLimitAll];

    if (hasPersistentRef) {
        OSStatus verified = rbxVerifyPersistentRef(q);
        if (verified != errSecSuccess) return verified;
        CFTypeRef out = NULL;
        OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)mq, result ? &out : NULL);
        if (result && out) {
            if (wantAttrs) {
                id reversed = rbxReverseResultObject((__bridge_transfer id)out);
                *result = (__bridge_retained CFTypeRef)reversed;
            } else {
                *result = out;
            }
        }
        return st;
    }

    // Narrow query: once namespaced it can only match our items, so the keychain does the
    // isolation for us. Preserve the caller's exact return types and limit; just reverse
    // the marker in any attributes we hand back.
    if (narrow) {
        CFTypeRef out = NULL;
        OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)mq, result ? &out : NULL);
        if (result) {
            if (out && wantAttrs) {
                id reversed = rbxReverseResultObject((__bridge_transfer id)out);
                *result = (__bridge_retained CFTypeRef)reversed;
            } else {
                *result = out;
            }
        }
        return st;
    }

    // Broad query (no primary key): the shared access group means orig would return items
    // from every container. Force attributes + all results so we can filter to ours, then
    // rebuild the result in the shape the caller expects.
    NSMutableDictionary *fq = [mq mutableCopy];
    fq[(__bridge id)kSecReturnAttributes] = (__bridge id)kCFBooleanTrue;
    fq[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    fq[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;

    CFTypeRef out = NULL;
    OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)fq, &out);
    if (st != errSecSuccess) {
        return st;
    }

    id outObj = (__bridge_transfer id)out;
    NSArray *items = [outObj isKindOfClass:[NSArray class]] ? outObj : (outObj ? @[outObj] : @[]);
    NSMutableArray *ours = [NSMutableArray array];
    for (id it in items) {
        if ([it isKindOfClass:[NSDictionary class]] && rbxItemIsOurs(it)) {
            NSMutableDictionary *m = [it mutableCopy];
            rbxDenamespaceDict(m);
            [ours addObject:m];
        }
    }

    if (ours.count == 0) {
        return errSecItemNotFound;
    }
    if (!result || wantCount == 0) return errSecSuccess;

    if (wantAll) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:ours.count];
        for (NSDictionary *full in ours) {
            id r = rbxBuildReturn(full, wantData, wantAttrs, wantRef, wantPRef);
            if (r) [arr addObject:r];
        }
        *result = (__bridge_retained CFTypeRef)arr;
    } else {
        NSUInteger limit = [matchLimit isKindOfClass:[NSNumber class]] ? [matchLimit unsignedIntegerValue] : 1;
        if (limit <= 1) {
            id r = rbxBuildReturn(ours[0], wantData, wantAttrs, wantRef, wantPRef);
            *result = r ? (__bridge_retained CFTypeRef)r : NULL;
        } else {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSDictionary *full in ours) {
                if (arr.count >= limit) break;
                id r = rbxBuildReturn(full, wantData, wantAttrs, wantRef, wantPRef);
                if (r) [arr addObject:r];
            }
            *result = (__bridge_retained CFTypeRef)arr;
        }
    }
    return errSecSuccess;
}

static OSStatus replaced_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    rbxLogUpdateEntry();
    if (!query || !attrs || !sPrefix) return errSecParam;

    NSDictionary *q = (__bridge NSDictionary *)query;
    NSDictionary *a = (__bridge NSDictionary *)attrs;
    if (rbxSynchronizableIsRejected(q) || rbxSynchronizableIsRejected(a) ||
        rbxSecureEnclaveIsRejected(q) || rbxSecureEnclaveIsRejected(a) ||
        a[(__bridge id)kSecAttrApplicationLabel])
        return errSecParam;

    BOOL hasPersistentRef = q[(__bridge id)kSecValuePersistentRef] != nil;

    NSMutableDictionary *mq = [(__bridge NSDictionary *)query mutableCopy];
    BOOL narrow = rbxNamespaceDict(mq);
    if (!hasPersistentRef)
        mq[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kCFBooleanFalse;

    // If the update renames an identity attribute, keep it inside the namespace so the item
    // stays isolated and future lookups still resolve.
    NSMutableDictionary *ma = [(__bridge NSDictionary *)attrs mutableCopy];
    rbxNamespaceDict(ma);

    if (hasPersistentRef) {
        OSStatus verified = rbxVerifyPersistentRef(q);
        if (verified != errSecSuccess) return verified;
        return orig_SecItemUpdate((__bridge CFDictionaryRef)mq, (__bridge CFDictionaryRef)ma);
    }

    if (narrow) {
        return orig_SecItemUpdate((__bridge CFDictionaryRef)mq, (__bridge CFDictionaryRef)ma);
    }

    // Broad update: constrain to our items so we never mutate a sibling container's item.
    OSStatus lookupStatus = errSecSuccess;
    NSArray *refs = rbxOurPersistentRefs(mq, &lookupStatus);
    if (!refs) return lookupStatus;
    if (refs.count == 0) return errSecItemNotFound;
    OSStatus firstError = errSecSuccess;
    for (id ref in refs) {
        NSMutableDictionary *dq = [NSMutableDictionary dictionary];
        dq[(__bridge id)kSecValuePersistentRef] = ref;
        OSStatus s = orig_SecItemUpdate((__bridge CFDictionaryRef)dq, (__bridge CFDictionaryRef)ma);
        if (s != errSecSuccess && firstError == errSecSuccess) firstError = s;
    }
    return firstError;
}

static OSStatus replaced_SecItemDelete(CFDictionaryRef query) {
    rbxLogDeleteEntry();
    if (!query || !sPrefix) return errSecParam;

    NSDictionary *q = (__bridge NSDictionary *)query;
    if (rbxSynchronizableIsRejected(q) || rbxSecureEnclaveIsRejected(q))
        return errSecParam;

    BOOL hasPersistentRef = q[(__bridge id)kSecValuePersistentRef] != nil;

    NSMutableDictionary *mq = [(__bridge NSDictionary *)query mutableCopy];
    BOOL narrow = rbxNamespaceDict(mq);
    if (!hasPersistentRef)
        mq[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kCFBooleanFalse;

    if (hasPersistentRef) {
        OSStatus verified = rbxVerifyPersistentRef(q);
        if (verified != errSecSuccess) return verified;
        return orig_SecItemDelete((__bridge CFDictionaryRef)mq);
    }

    if (narrow) {
        return orig_SecItemDelete((__bridge CFDictionaryRef)mq);
    }

    // Broad delete: a passthrough would wipe every container's items of this class. Convert
    // it into a targeted delete of only our items.
    OSStatus lookupStatus = errSecSuccess;
    NSArray *refs = rbxOurPersistentRefs(mq, &lookupStatus);
    if (!refs) return lookupStatus;
    if (refs.count == 0) return errSecItemNotFound;
    OSStatus firstError = errSecSuccess;
    for (id ref in refs) {
        NSMutableDictionary *dq = [NSMutableDictionary dictionary];
        dq[(__bridge id)kSecValuePersistentRef] = ref;
        OSStatus s = orig_SecItemDelete((__bridge CFDictionaryRef)dq);
        if (s != errSecSuccess && firstError == errSecSuccess) firstError = s;
    }
    return firstError;
}

static CFErrorRef rbxSharedCredentialBlockedError(void) {
    return CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus,
                         errSecInteractionNotAllowed, NULL);
}

static void replaced_SecAddSharedWebCredential(
    CFStringRef domain, CFStringRef account, CFStringRef password,
    void (^completion)(CFErrorRef)) {
    (void)domain; (void)account; (void)password;
    RBXLog("shared web credential write blocked");
    if (completion) {
        CFErrorRef error = rbxSharedCredentialBlockedError();
        completion(error);
        CFRelease(error);
    }
}

static void replaced_SecRequestSharedWebCredential(
    CFStringRef domain, CFStringRef account,
    void (^completion)(CFArrayRef, CFErrorRef)) {
    (void)domain; (void)account;
    RBXLog("shared web credential read blocked");
    if (completion) {
        CFErrorRef error = rbxSharedCredentialBlockedError();
        completion(NULL, error);
        CFRelease(error);
    }
}

void RBXInstallKeychainHooks(RBXContainerManager *mgr) {
    if (!mgr) return;

    NSString *cid = mgr.containerId;
    if (cid.length == 0) cid = @"default";

    sPrefix = [NSString stringWithFormat:@"\x01rbx\x01%@\x01", cid];
    sPrefixData = [sPrefix dataUsingEncoding:NSUTF8StringEncoding];

    MSHookFunction((void *)SecItemAdd, (void *)replaced_SecItemAdd, (void **)&orig_SecItemAdd);
    MSHookFunction((void *)SecItemCopyMatching, (void *)replaced_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching);
    MSHookFunction((void *)SecItemUpdate, (void *)replaced_SecItemUpdate, (void **)&orig_SecItemUpdate);
    MSHookFunction((void *)SecItemDelete, (void *)replaced_SecItemDelete, (void **)&orig_SecItemDelete);
    MSHookFunction((void *)SecAddSharedWebCredential,
                   (void *)replaced_SecAddSharedWebCredential,
                   (void **)&orig_SecAddSharedWebCredential);
    MSHookFunction((void *)SecRequestSharedWebCredential,
                   (void *)replaced_SecRequestSharedWebCredential,
                   (void **)&orig_SecRequestSharedWebCredential);

    RBXLog("keychain hooks installed with per-container identity isolation");
}

// OS-011. Keep this independent of the legacy namespace code: clone entitlements
// already define the access group. Never broaden a query or retry without the
// local selector when Security returns not-found, parameter or entitlement errors.
static OSStatus (*sync_orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*sync_orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*sync_orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*sync_orig_SecItemDelete)(CFDictionaryRef);

static OSStatus sync_SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *local = RBXKeychainSyncDictionary((__bridge NSDictionary *)query, YES);
    return sync_orig_SecItemAdd((__bridge CFDictionaryRef)local, result);
}
static OSStatus sync_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary *local = RBXKeychainSyncDictionary((__bridge NSDictionary *)query, YES);
    return sync_orig_SecItemCopyMatching((__bridge CFDictionaryRef)local, result);
}
static OSStatus sync_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    NSDictionary *local = RBXKeychainSyncDictionary((__bridge NSDictionary *)query, YES);
    NSDictionary *changes = RBXKeychainSyncDictionary((__bridge NSDictionary *)attributes, YES);
    return sync_orig_SecItemUpdate((__bridge CFDictionaryRef)local, (__bridge CFDictionaryRef)changes);
}
static OSStatus sync_SecItemDelete(CFDictionaryRef query) {
    NSDictionary *local = RBXKeychainSyncDictionary((__bridge NSDictionary *)query, YES);
    return sync_orig_SecItemDelete((__bridge CFDictionaryRef)local);
}

// BEGIN APP KEYCHAIN WRAPPERS
// FBKEY-002: this alternative installer owns the Security entry points once.
// It does not layer hooks over the Reddit sync wrappers or legacy namespaces.
static NSDictionary *appkey_descriptor;
static NSString *appkey_bundle;
static BOOL appkey_localOnly;
static OSStatus (*appkey_orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*appkey_orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*appkey_orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*appkey_orig_SecItemDelete)(CFDictionaryRef);
static SecKeyRef (*appkey_orig_SecKeyCreateRandomKey)(CFDictionaryRef, CFErrorRef *);
static SecKeyRef (*appkey_orig_SecKeyCreateWithData)(CFDataRef, CFDictionaryRef, CFErrorRef *);
static OSStatus (*appkey_orig_SecKeyGeneratePair)(CFDictionaryRef, SecKeyRef *, SecKeyRef *);

static NSDictionary *appkey_Dictionary(CFDictionaryRef input, BOOL keyCreation, OSStatus *status) {
    NSDictionary *mapped = RBXAppKeychainDictionary(appkey_descriptor, appkey_bundle,
        (__bridge NSDictionary *)input, keyCreation, status);
    if (!mapped) return nil;
    NSDictionary *local = RBXKeychainSyncDictionary(mapped, appkey_localOnly);
    if (keyCreation && appkey_localOnly) {
        NSMutableDictionary *nestedLocal = nil;
        for (id key in @[(__bridge id)kSecPrivateKeyAttrs, (__bridge id)kSecPublicKeyAttrs]) {
            if (!local[key]) continue;
            NSDictionary *child = RBXKeychainSyncDictionary(local[key], YES);
            if (child != local[key]) {
                if (!nestedLocal) nestedLocal = local.mutableCopy;
                nestedLocal[key] = child;
            }
        }
        return nestedLocal ?: local;
    }
    return local;
}
static OSStatus appkey_SecItemAdd(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(query, NO, &status);
    if (!mapped) { if (result) *result = NULL; return status; }
    return appkey_orig_SecItemAdd((__bridge CFDictionaryRef)mapped, result);
}
static OSStatus appkey_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(query, NO, &status);
    if (!mapped) { if (result) *result = NULL; return status; }
    return appkey_orig_SecItemCopyMatching((__bridge CFDictionaryRef)mapped, result);
}
static OSStatus appkey_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(query, NO, &status);
    if (!mapped) return status;
    NSDictionary *changes = appkey_Dictionary(attributes, NO, &status);
    if (!changes) return status;
    return appkey_orig_SecItemUpdate((__bridge CFDictionaryRef)mapped, (__bridge CFDictionaryRef)changes);
}
static OSStatus appkey_SecItemDelete(CFDictionaryRef query) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(query, NO, &status);
    return mapped ? appkey_orig_SecItemDelete((__bridge CFDictionaryRef)mapped) : status;
}
static void appkey_Error(OSStatus status, CFErrorRef *error) {
    if (error) *error = CFErrorCreate(kCFAllocatorDefault, kCFErrorDomainOSStatus, status, NULL);
}
static SecKeyRef appkey_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(parameters, YES, &status);
    if (!mapped) { appkey_Error(status, error); return NULL; }
    return appkey_orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)mapped, error);
}
static SecKeyRef appkey_SecKeyCreateWithData(CFDataRef data, CFDictionaryRef attributes, CFErrorRef *error) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(attributes, YES, &status);
    if (!mapped) { appkey_Error(status, error); return NULL; }
    return appkey_orig_SecKeyCreateWithData(data, (__bridge CFDictionaryRef)mapped, error);
}
static OSStatus appkey_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus status;
    NSDictionary *mapped = appkey_Dictionary(parameters, YES, &status);
    if (!mapped) {
        if (publicKey) *publicKey = NULL;
        if (privateKey) *privateKey = NULL;
        return status;
    }
    return appkey_orig_SecKeyGeneratePair((__bridge CFDictionaryRef)mapped, publicKey, privateKey);
}
// END APP KEYCHAIN WRAPPERS

static BOOL RBXInstallAppKeychainPolicy(RBXContainerManager *mgr, NSDictionary *descriptor, BOOL localOnly) {
    NSDictionary *profile = mgr.currentProfile.rawProfile;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    if (!mgr.validatedProfileLoaded || !RBXAppRuntimeProfileMatchesBundle(profile, bundle) ||
        !RBXAppKeychainMetadataMatches(descriptor, bundle, profile[@"app"])) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        appkey_descriptor = descriptor;
        appkey_bundle = bundle.copy;
        appkey_localOnly = localOnly;
        MSHookFunction((void *)SecItemAdd, (void *)appkey_SecItemAdd, (void **)&appkey_orig_SecItemAdd);
        MSHookFunction((void *)SecItemCopyMatching, (void *)appkey_SecItemCopyMatching, (void **)&appkey_orig_SecItemCopyMatching);
        MSHookFunction((void *)SecItemUpdate, (void *)appkey_SecItemUpdate, (void **)&appkey_orig_SecItemUpdate);
        MSHookFunction((void *)SecItemDelete, (void *)appkey_SecItemDelete, (void **)&appkey_orig_SecItemDelete);
        MSHookFunction((void *)SecKeyCreateRandomKey, (void *)appkey_SecKeyCreateRandomKey, (void **)&appkey_orig_SecKeyCreateRandomKey);
        MSHookFunction((void *)SecKeyCreateWithData, (void *)appkey_SecKeyCreateWithData, (void **)&appkey_orig_SecKeyCreateWithData);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        MSHookFunction((void *)SecKeyGeneratePair, (void *)appkey_SecKeyGeneratePair, (void **)&appkey_orig_SecKeyGeneratePair);
#pragma clang diagnostic pop
        RBXLog("keychain-group-policy version=1 app=%@ local-only=%d installation=%d container=%@",
            descriptor[@"appType"], localOnly, RBXHookInstallationPassed(), mgr.containerId);
    });
    return [appkey_descriptor isEqual:descriptor] && [appkey_bundle isEqual:bundle] &&
        appkey_localOnly == localOnly && RBXHookInstallationPassed();
}

BOOL RBXInstallKeychainSyncPolicy(RBXContainerManager *mgr) {
    if (!mgr.currentProfile) return NO;
    id security = mgr.currentProfile.rawProfile[@"security"];
    if (security && ![security isKindOfClass:NSDictionary.class]) return NO;
    id policy = security[@"keychainSync"];
    if (!RBXKeychainSyncPolicyValid(policy)) return NO;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(mgr.currentProfile.rawProfile);
    if (!descriptor) return NO;
    if (RBXAppKeychainMappingEnabled(descriptor))
        return RBXInstallAppKeychainPolicy(mgr, descriptor, RBXKeychainSyncPolicyEnabled(policy));
    if (!RBXKeychainSyncPolicyEnabled(policy)) {
        RBXLog("keychain-sync-policy mode=unchanged container=%@; sync isolation is not enabled", mgr.containerId);
        return YES;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MSHookFunction((void *)SecItemAdd, (void *)sync_SecItemAdd, (void **)&sync_orig_SecItemAdd);
        MSHookFunction((void *)SecItemCopyMatching, (void *)sync_SecItemCopyMatching, (void **)&sync_orig_SecItemCopyMatching);
        MSHookFunction((void *)SecItemUpdate, (void *)sync_SecItemUpdate, (void **)&sync_orig_SecItemUpdate);
        MSHookFunction((void *)SecItemDelete, (void *)sync_SecItemDelete, (void **)&sync_orig_SecItemDelete);
        RBXLog("keychain-sync-policy mode=local-only installation=%d container=%@", RBXHookInstallationPassed(), mgr.containerId);
    });
    return RBXHookInstallationPassed();
}
