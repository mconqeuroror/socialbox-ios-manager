#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXTimezoneHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>

// C2 — timezone must match the proxy geo (proxy in DE -> Europe/Berlin). All
// delivery variants (system/local/default) are covered because localTimeZone and
// defaultTimeZone are backed by systemTimeZone data unless explicitly overridden.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static NSTimeZone *rbxSpoofedTimeZone(void) {
    static NSTimeZone *sZone;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXDeviceProfile *p = rbxProfile();
        NSString *tz = [p valueForPath:@"device.timezone"];
        if (tz.length) {
            sZone = [[NSTimeZone alloc] initWithName:tz];
            if (!sZone) {
                RBXLogErr("profile timezone %@ is invalid — using fail-safe UTC", tz);
            }
        }
        if (!sZone) sZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return sZone;
}

%hook NSTimeZone

+ (NSTimeZone *)systemTimeZone {
    NSTimeZone *tz = rbxSpoofedTimeZone();
    return tz;
}

+ (NSTimeZone *)localTimeZone {
    NSTimeZone *tz = rbxSpoofedTimeZone();
    return tz;
}

+ (NSTimeZone *)defaultTimeZone {
    NSTimeZone *tz = rbxSpoofedTimeZone();
    return tz;
}

+ (NSTimeZone *)timeZoneWithName:(NSString *)name {
    NSTimeZone *tz = rbxSpoofedTimeZone();
    if (tz && [tz.name isEqualToString:name]) return tz;
    return %orig;
}

%end

BOOL RBXInstallTimezoneHooks(void) {
    static BOOL installed = NO;
    if (installed) return RBXHookInstallationPassed();
    installed = YES;
    %init;
    RBXLog("timezone hooks installed for container %@", rbxProfile().containerId);
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallTimezoneHooks();
    }
}
