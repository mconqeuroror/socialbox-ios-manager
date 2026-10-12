#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXPushHooks.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PushKit/PushKit.h>
#import <substrate.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

// Push registration block + token capture (Feature 2.1).
//
// Toggle resolution (per container, default OFF):
//   store containers.<id>.push.enabled == true  -> pass through
//   otherwise                                    -> no-op registration
//
// The hardware APNs token is never handed to Reddit. When a callback still
// fires, the delegate receives a per-container dummy of the same length.

static NSString *sContainerId;
static BOOL sPushEnabled;
static NSString *sRealTokenHex;
static NSData *sRealTokenData;
static NSString *sDummyHex;
static NSData *sDummyData;

static NSString *RBXHexFromData(NSData *data) {
    if (!data.length) return nil;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return [hex copy];
}

static void RBXEnsureDummyToken(void) {
    if (sDummyData.length) return;
    if (!sContainerId) sContainerId = [RBXContainerManager sharedManager].containerId;
    NSString *seed = [NSString stringWithFormat:@"rbx.push.dummy.%@", sContainerId ?: @"default"];
    NSData *seedData = [seed dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(seedData.bytes, (CC_LONG)seedData.length, digest);
    // Flip a nibble so an all-zero / hardware-collision is vanishingly unlikely
    // and the dummy is visibly not a typical APNs token pattern.
    digest[0] ^= 0xA5;
    sDummyData = [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
    sDummyHex = RBXHexFromData(sDummyData);
}

NSString *RBXContainerDummyPushTokenHex(void) {
    RBXEnsureDummyToken();
    return sDummyHex;
}

NSData *RBXContainerDummyPushTokenData(void) {
    RBXEnsureDummyToken();
    return sDummyData;
}

NSString *RBXCapturedRealPushTokenHex(void) {
    return sRealTokenHex;
}

NSData *RBXCapturedRealPushTokenData(void) {
    return sRealTokenData;
}

%hook UIApplication

- (void)registerForRemoteNotifications {
    if (!sContainerId) sContainerId = [RBXContainerManager sharedManager].containerId;
    sPushEnabled = NO;
    RBXLog("push registration suppressed for container %@", sContainerId);
}

- (BOOL)isRegisteredForRemoteNotifications {
    if (!sContainerId) sContainerId = [RBXContainerManager sharedManager].containerId;
    return NO;
}

%end

// This selector is absent on iOS 16. Never count an impossible hook as a
// required installation failure, or add a method which the OS did not expose.
%group RBXOptionalPushMatching
%hook UIApplication
- (void)registerForRemoteNotificationsMatching:(NSInteger)options completionHandler:(void (^)(NSError *))completion {
    if (!sContainerId) sContainerId = [RBXContainerManager sharedManager].containerId;
    RBXLog("push registration (matching) suppressed for container %@", sContainerId);
    if (completion) {
        completion([NSError errorWithDomain:@"com.redditbox.push"
                                       code:1
                                   userInfo:@{NSLocalizedDescriptionKey: @"Push disabled for profile isolation"}]);
    }
}

%end
%end

%hook PKPushRegistry

- (void)setDesiredPushTypes:(NSSet<PKPushType> *)types {
    RBXLog("PushKit registration blocked for container %@",
           [RBXContainerManager sharedManager].containerId);
    %orig([NSSet set]);
}

- (NSSet<PKPushType> *)desiredPushTypes {
    return [NSSet set];
}

- (NSData *)pushTokenForType:(PKPushType)type {
    return nil;
}

%end

// Delegate token capture. The app delegate is created after the ctor, so the
// hook is installed once the class is known (dispatch_async + small delay).

static void (*orig_didRegisterToken)(id self, SEL _cmd, UIApplication *app, NSData *deviceToken);

static void replaced_didRegisterToken(id self, SEL _cmd, UIApplication *app, NSData *deviceToken) {
    (void)self; (void)_cmd; (void)app; (void)deviceToken;
    sRealTokenData = nil;
    sRealTokenHex = nil;
    RBXLog("push token callback dropped for container %@", sContainerId);
}

BOOL RBXInstallPushHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
    %init;
    if (class_getInstanceMethod(UIApplication.class,
            NSSelectorFromString(@"registerForRemoteNotificationsMatching:completionHandler:"))) {
        %init(RBXOptionalPushMatching);
    }
    sContainerId = [RBXContainerManager sharedManager].containerId;
    RBXEnsureDummyToken();

    // Capture the APNs token once the app delegate exists. A short delay after
    // launch is enough (registerForRemoteNotifications happens after didFinishLaunching).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id delegate = [UIApplication sharedApplication].delegate;
        if (!delegate) return;
        Class delegateClass = object_getClass(delegate);
        if (!delegateClass) return;
        SEL sel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
        if (![delegateClass instancesRespondToSelector:sel]) return;

        // Guard against double-install (ctor may run once per process; be safe).
        static BOOL sInstalled = NO;
        if (sInstalled) return;
        sInstalled = YES;

        MSHookMessageEx(delegateClass, sel, (IMP)replaced_didRegisterToken, (IMP *)&orig_didRegisterToken);
        RBXLog("push token capture installed on %@", NSStringFromClass(delegateClass));
    });
    });
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallPushHooks();
    }
}
