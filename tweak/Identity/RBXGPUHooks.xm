#import "RBXHookInstallation.h"
#import "RBXGPUHooks.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <string.h>

static uint64_t (*orig_registryID)(id, SEL);
static NSString *(*orig_deviceName)(id, SEL);
static uint64_t sSyntheticRegistryID;
static BOOL sVerified;

static uint64_t replaced_registryID(id self, SEL command) {
    return sSyntheticRegistryID;
}

static NSString *replaced_deviceName(id self, SEL command) {
    NSString *name = [[RBXContainerManager sharedManager].currentProfile
                      valueForPath:@"device.gpuName"];
    return name.length ? name : orig_deviceName(self, command);
}

BOOL RBXInstallGPUHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXDeviceProfile *profile = [RBXContainerManager sharedManager].currentProfile;
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:
            [profile valueForPath:@"serials.platformUUID"]];
        uuid_t bytes = {};
        [uuid getUUIDBytes:bytes];
        memcpy(&sSyntheticRegistryID, bytes, sizeof(sSyntheticRegistryID));
        if (!sSyntheticRegistryID) sSyntheticRegistryID = profile.containerId.hash ?: 1;

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        Class deviceClass = object_getClass(device);
        if (deviceClass && [device respondsToSelector:@selector(registryID)]) {
            MSHookMessageEx(deviceClass, @selector(registryID),
                            (IMP)replaced_registryID, (IMP *)&orig_registryID);
        }
        if (deviceClass && [device respondsToSelector:@selector(name)]) {
            MSHookMessageEx(deviceClass, @selector(name),
                            (IMP)replaced_deviceName, (IMP *)&orig_deviceName);
        }
        sVerified = device && RBXHookInstallationPassed() &&
            [device respondsToSelector:@selector(registryID)] &&
            device.registryID == sSyntheticRegistryID &&
            [profile valueForPath:@"device.gpuName"].length &&
            [device.name isEqual:[profile valueForPath:@"device.gpuName"]];
        RBXLog("Metal identity isolation %@ container=%@",
               sVerified ? @"READY" : @"NOT_READY", profile.containerId);
    });
    return RBXHookInstallationPassed();
}

BOOL RBXGPUHooksVerified(void) {
    return sVerified;
}
