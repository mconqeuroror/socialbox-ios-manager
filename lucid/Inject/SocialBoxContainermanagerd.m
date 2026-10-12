// SocialBoxContainermanagerd.dylib — loads into containermanagerd.
//
// Purpose (IG/FB only): when containermanagerd resolves a data container for
// Instagram or Facebook and SocialBox has an active container selection for
// that app, redirect the container's on-disk root/data location into the
// per-CID SocialBox profile root so sibling files (and the app's
// Library/Preferences tree) are isolated per container. This is the
// "sandbox sibling files" layer of the A/B/A acceptance.
//
// PINNED ABI
//   Target class / selectors (observed in the recovered image, stable names):
//     MCMContainerFactory
//       -[… containerForContainerIdentity:createIfNecessary:error:]
//       -[… containerForContainerIdentity:createIfNecessary:updateLinks:error:]
//   Container location ivars (observed): _containerRootURL / _containerDataURL.
//   The hook uses ObjC runtime introspection (class_getInstanceMethod + KVC on
//   the observed ivar names); no fixed struct offsets are baked in. If the
//   class, either selector, or the location ivars are absent, or the OS major
//   is not the pinned image, NOTHING is hooked (fail-closed).

#import <Foundation/Foundation.h>
#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/runtime.h>
#import "LBXInjectCommon.h"

static const char *kCat = "containermanagerd";

typedef id (*LBXContainerFn)(id self, SEL _cmd, id identity, BOOL create, NSError **error);
typedef id (*LBXContainerLinksFn)(id self, SEL _cmd, id identity, BOOL create, BOOL links, NSError **error);

static LBXContainerFn oContainer;
static LBXContainerLinksFn oContainerLinks;

// Extract a supported bundle id from an MCMContainerIdentity-like object using
// the published accessor names, fail-closed if none are present.
static NSString *LBXIdentityBundle(id identity) {
    if (!identity) return nil;
    for (NSString *key in @[ @"bundleIdentifier", @"identifier", @"iosGUID" ]) {
        @try {
            if (![identity respondsToSelector:NSSelectorFromString(key)]) continue;
            id value = [identity valueForKey:key];
            if ([value isKindOfClass:NSString.class]) {
                NSString *bundle = LBXInjectBundleIDForKeychainIdentity(value);
                if (bundle) return bundle;
            }
        } @catch (__unused NSException *e) {
        }
    }
    return nil;
}

// Point the resolved container's location ivars at the per-CID profile root.
static void LBXRedirectContainer(id container, NSString *bundle) {
    if (!container) return;
    long long cid = LBXInjectActiveContainerForBundleID(bundle);
    NSString *root = LBXInjectProfileRootForContainer(cid);
    if (root.length == 0) return;
    NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];

    BOOL redirected = NO;
    for (NSString *ivarName in @[ @"_containerRootURL", @"_containerDataURL" ]) {
        if (class_getInstanceVariable(object_getClass(container), ivarName.UTF8String) == NULL) {
            continue;
        }
        @try {
            // KVC key is the ivar name without the leading underscore.
            NSString *key = [ivarName substringFromIndex:1];
            [container setValue:rootURL forKey:key];
            redirected = YES;
        } @catch (__unused NSException *e) {
        }
    }
    if (redirected) LBXInjectLog(kCat, @"redirect container bundle=%@ cid=%lld", bundle, cid);
}

static id hContainer(id self, SEL _cmd, id identity, BOOL create, NSError **error) {
    id container = oContainer(self, _cmd, identity, create, error);
    NSString *bundle = LBXIdentityBundle(identity);
    if (bundle) LBXRedirectContainer(container, bundle);
    return container;
}

static id hContainerLinks(id self, SEL _cmd, id identity, BOOL create, BOOL links, NSError **error) {
    id container = oContainerLinks(self, _cmd, identity, create, links, error);
    NSString *bundle = LBXIdentityBundle(identity);
    if (bundle) LBXRedirectContainer(container, bundle);
    return container;
}

__attribute__((constructor))
static void LBXContainermanagerdInit(void) {
    @autoreleasepool {
        if (!LBXInjectOSMajorIsPinned()) {
            LBXInjectLog(kCat, @"OS major not pinned; containermanagerd left stock");
            return;
        }
        Class factory = objc_getClass("MCMContainerFactory");
        if (!factory) {
            LBXInjectLog(kCat, @"MCMContainerFactory absent; no hooks");
            return;
        }

        SEL selA = NSSelectorFromString(@"containerForContainerIdentity:createIfNecessary:error:");
        SEL selB = NSSelectorFromString(@"containerForContainerIdentity:createIfNecessary:updateLinks:error:");
        BOOL hasA = (class_getInstanceMethod(factory, selA) != NULL);
        BOOL hasB = (class_getInstanceMethod(factory, selB) != NULL);
        if (!hasA && !hasB) {
            LBXInjectLog(kCat, @"container selectors absent; no hooks");
            return;
        }

        // Require the observed location ivars before mutating anything.
        if (class_getInstanceVariable(factory, "_containerRootURL") == NULL &&
            !objc_getClass("MCMContainer")) {
            // The ivars live on the returned container, not the factory; probe
            // the container class when available, else fail-closed.
            Class container = objc_getClass("MCMContainer");
            if (container && class_getInstanceVariable(container, "_containerRootURL") == NULL) {
                LBXInjectLog(kCat, @"container location ivars absent; no hooks");
                return;
            }
        }

        if (hasA) {
            MSHookMessageEx(factory, selA, (IMP)hContainer, (IMP *)&oContainer);
        }
        if (hasB) {
            MSHookMessageEx(factory, selB, (IMP)hContainerLinks, (IMP *)&oContainerLinks);
        }
        LBXInjectLog(kCat, @"installed container hooks (a=%d b=%d)", hasA, hasB);
    }
}
