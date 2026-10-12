#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXDeviceHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// UIDevice-level identity: name, model, systemVersion, identifierForVendor (IDFV).
// AppsFlyer/Firebase/Reddit read these directly; all must come from the profile.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static NSString *sRealIdfv;

static void RBXLogDeviceHookEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXLog("UIDevice identity hook active for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
}

NSString *RBXRealIDFVString(void) {
    return sRealIdfv;
}

%hook UIDevice

- (NSString *)name {
    RBXLogDeviceHookEntry();
    NSString *n = rbxProfile().deviceName;
    return n ?: %orig;
}

- (NSString *)model {
    RBXLogDeviceHookEntry();
    return rbxProfile() ? @"iPhone" : %orig;
}

- (NSString *)localizedModel {
    RBXLogDeviceHookEntry();
    return rbxProfile() ? @"iPhone" : %orig;
}

- (NSString *)systemVersion {
    RBXLogDeviceHookEntry();
    NSString *v = rbxProfile().iosVersion;
    return v ?: %orig;
}

- (NSUUID *)identifierForVendor {
    RBXLogDeviceHookEntry();
    NSUUID *real = %orig;
    if (!sRealIdfv && real) {
        sRealIdfv = [real.UUIDString copy];
    }
    NSString *v = rbxProfile().idfv;
    if (v) return [[NSUUID alloc] initWithUUIDString:v];
    return real;
}

%end

%hook NSProcessInfo
- (NSOperatingSystemVersion)operatingSystemVersion {
    NSArray<NSString *> *parts = [rbxProfile().iosVersion componentsSeparatedByString:@"."];
    if (parts.count != 2 && parts.count != 3) return %orig;
    NSInteger values[3] = {0, 0, 0};
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSString *part = parts[index];
        if (!part.length) return %orig;
        for (NSUInteger offset = 0; offset < part.length; offset++) {
            unichar character = [part characterAtIndex:offset];
            if (character < '0' || character > '9') return %orig;
            NSInteger digit = character - '0';
            if (values[index] > (NSIntegerMax - digit) / 10) return %orig;
            values[index] = values[index] * 10 + digit;
        }
    }
    // Catalog versions such as 26.5 have an implicit zero patch component.
    return (NSOperatingSystemVersion){values[0], values[1], values[2]};
}
- (NSString *)operatingSystemVersionString {
    RBXDeviceProfile *profile = rbxProfile();
    if (!profile) return %orig;
    return [NSString stringWithFormat:@"Version %@ (Build %@)", profile.iosVersion,
        [profile valueForPath:@"device.buildVersion"]];
}
%end

BOOL RBXInstallDeviceHooks(RBXDeviceProfile *profile) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        (void)profile;
        %init;
        (void)[UIDevice currentDevice].identifierForVendor;
        RBXLog("UIDevice hooks installed for container %@", rbxProfile().containerId);
    });
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallDeviceHooks(rbxProfile());
    }
}
