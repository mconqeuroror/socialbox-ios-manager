#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXBatteryHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <math.h>

// Battery telemetry must not expose the one physical battery shared by every
// profile. A stable per-container phase drives a plausible independent cycle.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static NSTimeInterval RBXBatteryPhase(RBXDeviceProfile *profile) {
    NSTimeInterval cycle = (11.0 * 60.0 * 60.0) +
        (profile.containerId.hash % (4 * 60 * 60));
    return fmod([NSDate.date timeIntervalSince1970] +
                (profile.containerId.hash % (NSUInteger)cycle), cycle);
}

static NSTimeInterval RBXBatteryCycle(RBXDeviceProfile *profile) {
    return (11.0 * 60.0 * 60.0) +
        (profile.containerId.hash % (4 * 60 * 60));
}

static NSTimeInterval RBXBatteryChargeWindow(RBXDeviceProfile *profile) {
    return (2.0 * 60.0 * 60.0) +
        ((profile.containerId.hash >> 8) % (2 * 60 * 60));
}

%hook UIDevice

- (float)batteryLevel {
    RBXDeviceProfile *p = rbxProfile();
    if (!p) return 0.5f;
    NSTimeInterval cycle = RBXBatteryCycle(p);
    NSTimeInterval chargeWindow = RBXBatteryChargeWindow(p);
    NSTimeInterval phase = RBXBatteryPhase(p);
    float offset = [[p valueForPath:@"timing.batteryOffsetPercent"] floatValue] / 100.0f;
    float base = phase < chargeWindow
        ? 0.15f + (float)(phase / chargeWindow) * 0.80f
        : 0.95f - (float)((phase - chargeWindow) / (cycle - chargeWindow)) * 0.80f;
    return fmaxf(0.08f, fminf(0.98f,
        base + offset));
}

- (UIDeviceBatteryState)batteryState {
    RBXDeviceProfile *p = rbxProfile();
    if (!p) return UIDeviceBatteryStateUnknown;
    return RBXBatteryPhase(p) < RBXBatteryChargeWindow(p)
        ? UIDeviceBatteryStateCharging : UIDeviceBatteryStateUnplugged;
}

%end

BOOL RBXInstallBatteryHooks(void) {
    static BOOL installed = NO;
    if (installed) return RBXHookInstallationPassed();
    installed = YES;
    %init;
    RBXLog("virtual battery hooks installed for container %@", rbxProfile().containerId);
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallBatteryHooks();
    }
}
