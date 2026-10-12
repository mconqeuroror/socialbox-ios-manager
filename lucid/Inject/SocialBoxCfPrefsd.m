// SocialBoxCfPrefsd.dylib — loads into /usr/sbin/cfprefsd.
//
// Purpose (IG/FB only): when cfprefsd resolves the on-disk path (and the
// in-memory source) for an Instagram or Facebook preferences domain and
// SocialBox has an active container selection for that app, redirect the
// preferences *container* into the per-CID SocialBox profile root — the same
// root SocialBoxContainermanagerd redirects the app's data container to. This
// keeps each container's preferences (both on disk under
// <profileRoot>/Library/Preferences and in cfprefsd's per-container source
// cache) isolated across A/B/A switches. This is the "prefs redirect" layer.
//
// PINNED ABI (iOS 16.6 CoreFoundation, device-extracted 2026-10-06; see
// docs/release-evidence/socialbox-cfprefsd-abi-2026-10-06.json):
//   Boolean __CFPrefsGetPathForTriplet(CFStringRef domain,
//                                      CFStringRef user,
//                                      Boolean     byHost,
//                                      CFStringRef containerPath,
//                                      uint8_t    *buffer /*CFMaxPathSize*/);
//   - arg0 domain        -> __CFPrefsGetCacheStringForBundleID (filename)
//   - arg1 user, arg2 byHost -> directory URL for triplet
//   - arg3 containerPath -> the container the prefs live under  (REWRITTEN)
//   - arg4 buffer        -> output path; returns success Boolean
//   Resolved by NAME against the running cfprefsd/CoreFoundation image. The
//   selector -[CFPrefsDaemon handleSourceMessage:replyHandler:] does NOT exist
//   on this OS and is deliberately NOT hooked.
//
//   FAIL-CLOSED: install nothing unless Darwin major == 22 AND the symbol
//   resolves. No offsets, no struct layouts. Every non-IG/FB domain and every
//   other process passes straight through to the original — cfprefsd serves all
//   system preferences, so attribution is scoped strictly to the two supported
//   app domains with a live container selection.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CydiaSubstrate/CydiaSubstrate.h>
#import "LBXInjectCommon.h"

static const char *kCat = "cfprefsd";

typedef Boolean (*LBXPrefsPathFn)(CFStringRef domain,
                                  CFStringRef user,
                                  Boolean byHost,
                                  CFStringRef containerPath,
                                  uint8_t *buffer);

static LBXPrefsPathFn oPrefsGetPathForTriplet;

// Map a preferences domain to a supported bundle id, or nil to pass through.
static NSString *LBXPrefsDomainBundle(CFStringRef domain) {
    if (!domain || CFGetTypeID(domain) != CFStringGetTypeID()) return nil;
    return LBXInjectBundleIDForKeychainIdentity((__bridge NSString *)domain);
}

static Boolean hPrefsGetPathForTriplet(CFStringRef domain,
                                       CFStringRef user,
                                       Boolean byHost,
                                       CFStringRef containerPath,
                                       uint8_t *buffer) {
    NSString *bundle = LBXPrefsDomainBundle(domain);
    if (!bundle) {
        return oPrefsGetPathForTriplet(domain, user, byHost, containerPath, buffer);
    }
    long long cid = LBXInjectActiveContainerForBundleID(bundle);
    NSString *root = LBXInjectProfileRootForContainer(cid);
    if (root.length == 0) {
        return oPrefsGetPathForTriplet(domain, user, byHost, containerPath, buffer);
    }
    // Redirect the preferences container to the per-CID SocialBox profile root.
    CFStringRef redirected = (__bridge CFStringRef)root;
    LBXInjectLog(kCat, @"redirect prefs domain=%@ cid=%lld", bundle, cid);
    return oPrefsGetPathForTriplet(domain, user, byHost, redirected, buffer);
}

__attribute__((constructor))
static void LBXCfPrefsdInit(void) {
    @autoreleasepool {
        if (!LBXInjectOSMajorIsPinned()) {
            LBXInjectLog(kCat, @"OS major not pinned; cfprefsd left stock");
            return;
        }
        // CoreFoundation lives in the shared cache; resolve the local symbol by
        // name against the global image set (image arg NULL = search all).
        void *sym = MSFindSymbol(NULL, "__CFPrefsGetPathForTriplet");
        if (!sym) {
            LBXInjectLog(kCat, @"__CFPrefsGetPathForTriplet unresolved; no hooks (prefs stock)");
            return;
        }
        MSHookFunction(sym, (void *)hPrefsGetPathForTriplet,
                       (void **)&oPrefsGetPathForTriplet);
        LBXInjectLog(kCat, @"installed prefs path hook");
    }
}
