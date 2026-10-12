// SocialBoxSecurityd.dylib — loads into /usr/libexec/securityd.
//
// Purpose (IG/FB only): make Instagram and Facebook keychain items live in the
// per-container SocialBox access group  %.s_o_c_i_a_l_b_o_x.<CID>  so each
// container is isolated and SocialBox's helper can read/write the same group as
// root. This is the "keychain canary" layer of the A/B/A acceptance.
//
// PINNED ABI
//   Hooks are resolved by NAME against the running securityd image:
//     _securityd_xpc_dictionary_handler  (observed, not required)
//     __SecItemCopyMatching / _SecItemCopyMatching
//     __SecItemAdd         / _SecItemAdd
//     __SecItemUpdate      / _SecItemUpdate
//     __SecItemDelete      / _SecItemDelete
//     SecTaskCopyValueForEntitlement   (libsecurity, by name)
//   The internal __SecItem* entry points share the public SecItem C signature,
//   which is the pinned contract below. No offsets. If any required symbol is
//   missing, or the OS major is not the pinned image, NOTHING is hooked.
//
// RECONSTRUCTION NOTE (device A/B/A validates this): the internal securityd
// query dictionary is keyed by the short attribute codes ("agrp","svce",...);
// the public fallback is keyed by the kSecAttr* constants. Rewrite handles both
// families. Caller attribution is scoped strictly to the published IG/FB
// keychain identity tokens — every other process is passed through untouched.

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CydiaSubstrate/CydiaSubstrate.h>
#import "LBXInjectCommon.h"

// ---- pinned signatures --------------------------------------------------
typedef struct __SecTask *LBXSecTaskRef;
extern CFTypeRef SecTaskCopyValueForEntitlement(LBXSecTaskRef task,
                                                CFStringRef entitlement,
                                                CFErrorRef *error);

typedef OSStatus (*LBXSecItemQueryFn)(CFDictionaryRef query, CFTypeRef *result);
typedef OSStatus (*LBXSecItemUpdateFn)(CFDictionaryRef query, CFDictionaryRef attributes);
typedef OSStatus (*LBXSecItemDeleteFn)(CFDictionaryRef query);
typedef CFTypeRef (*LBXSecTaskEntFn)(LBXSecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static LBXSecItemQueryFn  oSecItemCopyMatching;
static LBXSecItemQueryFn  oSecItemAdd;
static LBXSecItemUpdateFn oSecItemUpdate;
static LBXSecItemDeleteFn oSecItemDelete;
static LBXSecTaskEntFn    oSecTaskCopyValueForEntitlement;

static const char *kCat = "securityd";

// ---- attribution + rewrite ----------------------------------------------

// Scan a keychain dictionary for a published IG/FB identity token and return
// the matching supported bundle id, or nil to leave the request untouched.
static NSString *LBXAttributeBundle(NSDictionary *dict) {
    if (![dict isKindOfClass:NSDictionary.class]) return nil;
    NSArray<id> *keys = @[
        @"agrp", (__bridge id)kSecAttrAccessGroup,
        @"svce", (__bridge id)kSecAttrService,
        @"acct", (__bridge id)kSecAttrAccount,
        @"labl",
    ];
    for (id k in keys) {
        id v = dict[k];
        if ([v isKindOfClass:NSString.class]) {
            NSString *bundle = LBXInjectBundleIDForKeychainIdentity(v);
            if (bundle) return bundle;
        }
    }
    return nil;
}

// Returns a rewritten copy of the query with the access group set to the
// SocialBox per-CID group, under whichever key family the dictionary uses.
// Returns nil when the request is not an IG/FB request with a live selection.
static CFDictionaryRef LBXRewriteCopy(CFDictionaryRef original) CF_RETURNS_RETAINED {
    NSDictionary *dict = (__bridge NSDictionary *)original;
    NSString *bundle = LBXAttributeBundle(dict);
    if (!bundle) return NULL;
    long long cid = LBXInjectActiveContainerForBundleID(bundle);
    if (cid < 1) return NULL;
    NSString *agrp = LBXInjectAccessGroupForContainer(cid);
    if (agrp.length == 0) return NULL;

    NSMutableDictionary *copy = [dict mutableCopy];
    BOOL usesShort = (dict[@"agrp"] != nil || dict[@"class"] != nil || dict[@"svce"] != nil);
    if (usesShort) {
        copy[@"agrp"] = agrp;
    } else {
        copy[(__bridge id)kSecAttrAccessGroup] = agrp;
    }
    LBXInjectLog(kCat, @"rewrite agrp bundle=%@ cid=%lld", bundle, cid);
    return (CFDictionaryRef)CFBridgingRetain(copy);
}

static OSStatus hSecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    CFDictionaryRef rw = LBXRewriteCopy(query);
    OSStatus rc = oSecItemCopyMatching(rw ?: query, result);
    if (rw) CFRelease(rw);
    return rc;
}

static OSStatus hSecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    CFDictionaryRef rw = LBXRewriteCopy(attributes);
    OSStatus rc = oSecItemAdd(rw ?: attributes, result);
    if (rw) CFRelease(rw);
    return rc;
}

static OSStatus hSecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) {
    CFDictionaryRef rw = LBXRewriteCopy(query);
    OSStatus rc = oSecItemUpdate(rw ?: query, attributes);
    if (rw) CFRelease(rw);
    return rc;
}

static OSStatus hSecItemDelete(CFDictionaryRef query) {
    CFDictionaryRef rw = LBXRewriteCopy(query);
    OSStatus rc = oSecItemDelete(rw ?: query);
    if (rw) CFRelease(rw);
    return rc;
}

// Grant the SocialBox per-CID access group to the IG/FB client so securityd's
// own access check permits the rewritten group. Scoped to IG/FB; all other
// tasks and all other entitlements fall straight through to the original.
static CFTypeRef hSecTaskCopyValueForEntitlement(LBXSecTaskRef task,
                                                 CFStringRef entitlement,
                                                 CFErrorRef *error) {
    CFTypeRef original = oSecTaskCopyValueForEntitlement(task, entitlement, error);
    if (!entitlement || !CFEqual(entitlement, CFSTR("keychain-access-groups"))) {
        return original;
    }

    // Identify the calling task via its application-identifier entitlement.
    NSString *bundle = nil;
    CFTypeRef appIdent = oSecTaskCopyValueForEntitlement(task, CFSTR("application-identifier"), NULL);
    if (appIdent && CFGetTypeID(appIdent) == CFStringGetTypeID()) {
        bundle = LBXInjectBundleIDForKeychainIdentity((__bridge NSString *)appIdent);
    }
    if (appIdent) CFRelease(appIdent);
    if (!bundle) return original;

    long long cid = LBXInjectActiveContainerForBundleID(bundle);
    NSString *agrp = LBXInjectAccessGroupForContainer(cid);
    if (agrp.length == 0) return original;

    NSMutableArray *groups = [NSMutableArray array];
    if (original && CFGetTypeID(original) == CFArrayGetTypeID()) {
        [groups addObjectsFromArray:(__bridge NSArray *)original];
    }
    if (![groups containsObject:agrp]) [groups addObject:agrp];
    if (original) CFRelease(original);
    LBXInjectLog(kCat, @"grant agrp bundle=%@ cid=%lld", bundle, cid);
    return (CFTypeRef)CFBridgingRetain(groups);
}

// ---- install -------------------------------------------------------------

static void *LBXResolve(MSImageRef image, const char *primary, const char *fallback) {
    void *sym = MSFindSymbol(image, primary);
    if (!sym && fallback) sym = MSFindSymbol(image, fallback);
    return sym;
}

__attribute__((constructor))
static void LBXSecuritydInit(void) {
    @autoreleasepool {
        if (!LBXInjectOSMajorIsPinned()) {
            LBXInjectLog(kCat, @"OS major not pinned; securityd left stock");
            return;
        }
        MSImageRef image = MSGetImageByName("/usr/libexec/securityd");
        if (!image) {
            LBXInjectLog(kCat, @"securityd image not found; no hooks");
            return;
        }

        void *copyMatching = LBXResolve(image, "__SecItemCopyMatching", "_SecItemCopyMatching");
        void *add          = LBXResolve(image, "__SecItemAdd", "_SecItemAdd");
        void *update       = LBXResolve(image, "__SecItemUpdate", "_SecItemUpdate");
        void *del          = LBXResolve(image, "__SecItemDelete", "_SecItemDelete");
        void *taskEnt      = MSFindSymbol(NULL, "_SecTaskCopyValueForEntitlement");

        // Fail-closed: require the full keychain quartet before touching anything.
        if (!copyMatching || !add || !update || !del) {
            LBXInjectLog(kCat, @"SecItem symbols incomplete; no hooks installed");
            return;
        }

        MSHookFunction(copyMatching, (void *)hSecItemCopyMatching, (void **)&oSecItemCopyMatching);
        MSHookFunction(add, (void *)hSecItemAdd, (void **)&oSecItemAdd);
        MSHookFunction(update, (void *)hSecItemUpdate, (void **)&oSecItemUpdate);
        MSHookFunction(del, (void *)hSecItemDelete, (void **)&oSecItemDelete);
        if (taskEnt) {
            MSHookFunction(taskEnt, (void *)hSecTaskCopyValueForEntitlement,
                           (void **)&oSecTaskCopyValueForEntitlement);
        }
        LBXInjectLog(kCat, @"installed keychain hooks (grant=%d)", taskEnt != NULL);
    }
}
