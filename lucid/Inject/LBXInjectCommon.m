#import "LBXInjectCommon.h"
#import "../Switching/LBXSocialBoxProduct.h"
#include <sys/sysctl.h>
#include <os/log.h>

NSString *const LBXInjectInstagramBundleID = @"com.burbn.instagram";
NSString *const LBXInjectFacebookBundleID = @"com.facebook.Facebook";

// Pinned Darwin major for this device image (Darwin 22.6.0 == iOS 16.6).
static const int kLBXInjectPinnedDarwinMajor = 22;

bool LBXInjectIsSupportedBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class]) return false;
    return [bundleID isEqualToString:LBXInjectInstagramBundleID] ||
           [bundleID isEqualToString:LBXInjectFacebookBundleID];
}

NSString *LBXInjectHostBundleID(NSString *bundleID) {
    if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) return nil;
    if (LBXInjectIsSupportedBundleID(bundleID)) return bundleID;
    if ([bundleID isEqualToString:LBXInjectInstagramBundleID] ||
        [bundleID hasPrefix:@"com.burbn.instagram."]) {
        return LBXInjectInstagramBundleID;
    }
    if ([bundleID isEqualToString:LBXInjectFacebookBundleID] ||
        [bundleID hasPrefix:@"com.facebook.Facebook."]) {
        return LBXInjectFacebookBundleID;
    }
    return nil;
}

bool LBXInjectOSMajorIsPinned(void) {
    char buf[256];
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osrelease", buf, &len, NULL, 0) != 0) return false;
    buf[sizeof(buf) - 1] = '\0';
    int major = atoi(buf);
    return major == kLBXInjectPinnedDarwinMajor;
}

static NSString *LBXInjectRuntimePathForBundleID(NSString *bundleID) {
    NSString *root = @LBX_SOCIALBOX_CONTROL_RUNTIME;
    return [root stringByAppendingPathComponent:[bundleID stringByAppendingString:@".plist"]];
}

long long LBXInjectActiveContainerForBundleID(NSString *bundleID) {
    if (!LBXInjectIsSupportedBundleID(bundleID)) return 0;
    NSString *path = LBXInjectRuntimePathForBundleID(bundleID);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return 0;
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![plist isKindOfClass:NSDictionary.class]) return 0;
    id value = plist[@"activeContainer"];
    if (![value isKindOfClass:NSNumber.class]) return 0;
    long long cid = [value longLongValue];
    // IG/FB numeric CID domain matches the helper's LBXHelperIsNumericContainerID.
    if (cid < 1 || cid > 999999) return 0;
    return cid;
}

NSString *LBXInjectAccessGroupForContainer(long long containerID) {
    if (containerID < 1) return nil;
    return [NSString stringWithFormat:@"%%.%s.%lld", LBX_SOCIALBOX_KEYCHAIN_TOKEN, containerID];
}

NSString *LBXInjectProfileRootForContainer(long long containerID) {
    if (containerID < 1) return nil;
    NSString *store = [@"/var/jb/var/mobile/Library"
        stringByAppendingPathComponent:@LBX_SOCIALBOX_PROFILE_STORE];
    return [store stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", containerID]];
}

// Known Instagram / Facebook keychain identity tokens. These are the stable,
// app-published keychain service / access-group / application-identifier
// fragments securityd observes for the two supported apps. Attribution is
// strictly scoped to these: anything unrecognised returns nil and runs stock.
// "com.barcelona.*" is Instagram's published service namespace.
static NSString *LBXInjectClassifyToken(NSString *token) {
    if (![token isKindOfClass:NSString.class] || token.length == 0) return nil;

    static NSArray<NSString *> *igFragments;
    static NSArray<NSString *> *fbFragments;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        igFragments = @[
            @"com.burbn.instagram",
            @"com.instagram.",
            @"com.barcelona.",
        ];
        fbFragments = @[
            @"com.facebook.Facebook",
            @"com.facebook.",
        ];
    });

    for (NSString *f in igFragments) {
        if ([token containsString:f]) return LBXInjectInstagramBundleID;
    }
    for (NSString *f in fbFragments) {
        if ([token containsString:f]) return LBXInjectFacebookBundleID;
    }
    return nil;
}

NSString *LBXInjectBundleIDForKeychainIdentity(NSString *identity) {
    return LBXInjectClassifyToken(identity);
}

void LBXInjectLog(const char *category, NSString *format, ...) {
    static os_log_t (^logger)(const char *) = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = ^os_log_t(const char *cat) {
            return os_log_create("com.socialbox.inject", cat ?: "inject");
        };
    });
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(logger(category), "%{public}s", message.UTF8String);
}
