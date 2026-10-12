// SocialBoxLocation.dylib — device-wide CoreLocation remap.
//
// Helper writes /private/var/tmp/socialbox_location_sim.json and posts
// com.socialbox.location. This inject forces CLLocation / CLLocationManager
// onto that pin so Maps and every other app see the SocialBox coordinate
// even when locationd's client simulation class is missing (iOS 16.6).
//
// PINNED ABI: public CoreLocation selectors, installed by name. Darwin major
// must be 22. Unknown executable or missing selector → that hook is skipped.
// SocialBox.app is never remapped: hooking the manager floods Darwin/XPC and
// overwrites the Location tab pin with the last CLI test coordinate.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CydiaSubstrate/CydiaSubstrate.h>
#import <objc/runtime.h>
#include <os/log.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

static NSString *const kSimPath = @"/private/var/tmp/socialbox_location_sim.json";
static NSString *const kHookPath = @"/private/var/tmp/socialbox_location_hook.json";
static const int kPinnedDarwinMajor = 22;

static BOOL gActive;
static double gLat;
static double gLon;
static NSTimeInterval gLoadedAt;
static NSTimeInterval gLastWitnessAt;
static NSHashTable *gManagers;
static os_log_t gLog;

static CLLocationCoordinate2D (*oCoordinate)(id, SEL);
static CLLocation *(*oManagerLocation)(id, SEL);
static void (*oStartUpdating)(id, SEL);
static void (*oStopUpdating)(id, SEL);
static void (*oRequestLocation)(id, SEL);

static BOOL LBXOSPinned(void) {
    char buf[256];
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osrelease", buf, &len, NULL, 0) != 0) return NO;
    buf[sizeof(buf) - 1] = '\0';
    return atoi(buf) == kPinnedDarwinMajor;
}

static NSString *LBXExecName(void) {
    return NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent ?: @"";
}

static BOOL LBXSkipProcess(void) {
    NSString *exec = LBXExecName();
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if ([bundle isEqualToString:@"com.socialbox.app"]) return YES;
    if ([exec isEqualToString:@"SocialBox"]) return YES;
    for (NSString *name in @[
             @"locationd", @"SocialBoxHelper", @"socialbox-drain-service", @"SocialBoxCLI",
             @"cfprefsd", @"securityd", @"containermanagerd", @"ReportCrash", @"launchd"
         ]) {
        if ([exec isEqualToString:name]) return YES;
    }
    return NO;
}

static void LBXReload(void) {
    NSData *data = [NSData dataWithContentsOfFile:kSimPath];
    NSDictionary *row = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![row isKindOfClass:NSDictionary.class]) {
        gActive = NO;
        return;
    }
    BOOL started = [row[@"started"] boolValue];
    double lat = [row[@"lat"] doubleValue];
    double lon = [row[@"lon"] doubleValue];
    if (!started || fabs(lat) > 90 || fabs(lon) > 180) {
        gActive = NO;
        return;
    }
    gLat = lat;
    gLon = lon;
    gActive = YES;
    gLoadedAt = [NSDate.date timeIntervalSince1970];
}

static void LBXEnsureFresh(void) {
    static time_t lastMtime;
    static off_t lastSize;
    struct stat st;
    if (stat(kSimPath.fileSystemRepresentation, &st) != 0) {
        gActive = NO;
        lastMtime = 0;
        lastSize = 0;
        return;
    }
    if (st.st_mtime != lastMtime || st.st_size != lastSize || gLoadedAt == 0) {
        lastMtime = st.st_mtime;
        lastSize = st.st_size;
        LBXReload();
    }
}

static CLLocation *LBXFakeLocation(void) {
    LBXEnsureFresh();
    if (!gActive) return nil;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(gLat, gLon);
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:40
                               horizontalAccuracy:5
                                 verticalAccuracy:5
                                           course:0
                                            speed:0
                                        timestamp:NSDate.date];
}

static void LBXWitness(void) {
    NSTimeInterval now = [NSDate.date timeIntervalSince1970];
    if (now - gLastWitnessAt < 2.0) return;
    gLastWitnessAt = now;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: LBXExecName();
    if ([bundle isEqualToString:@"com.socialbox.app"]) return;
    NSDictionary *row = @{
        @"bundle" : bundle,
        @"exec" : LBXExecName(),
        @"lat" : @(gLat),
        @"lon" : @(gLon),
        @"pid" : @(getpid()),
        @"at" : @(now),
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
    if (!data.length) return;
    [data writeToFile:kHookPath atomically:YES];
    chmod(kHookPath.fileSystemRepresentation, 0644);
}

static void LBXDeliver(CLLocationManager *manager) {
    CLLocation *fix = LBXFakeLocation();
    if (!fix || !manager) return;
    LBXWitness();
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:manager didUpdateLocations:@[ fix ]];
    }
}

static void LBXTrack(CLLocationManager *manager) {
    if (!gManagers) gManagers = [NSHashTable weakObjectsHashTable];
    if (manager) [gManagers addObject:manager];
}

static void LBXNotify(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                      const void *object, CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    static NSTimeInterval lastNotify;
    NSTimeInterval now = [NSDate.date timeIntervalSince1970];
    if (now - lastNotify < 0.25) return;
    lastNotify = now;
    LBXReload();
    if (!gActive) return;
    NSArray *managers = gManagers.allObjects;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (CLLocationManager *manager in managers) LBXDeliver(manager);
    });
}

static CLLocationCoordinate2D hookedCoordinate(id self, SEL sel) {
    LBXEnsureFresh();
    if (gActive) return CLLocationCoordinate2DMake(gLat, gLon);
    return oCoordinate ? oCoordinate(self, sel) : kCLLocationCoordinate2DInvalid;
}

static CLLocation *hookedManagerLocation(id self, SEL sel) {
    CLLocation *fake = LBXFakeLocation();
    return fake ?: (oManagerLocation ? oManagerLocation(self, sel) : nil);
}

static void hookedStartUpdating(id self, SEL sel) {
    LBXEnsureFresh();
    if (gActive) {
        LBXTrack(self);
        dispatch_async(dispatch_get_main_queue(), ^{ LBXDeliver(self); });
        return;
    }
    if (oStartUpdating) oStartUpdating(self, sel);
}

static void hookedRequestLocation(id self, SEL sel) {
    LBXEnsureFresh();
    if (gActive) {
        LBXTrack(self);
        dispatch_async(dispatch_get_main_queue(), ^{ LBXDeliver(self); });
        return;
    }
    if (oRequestLocation) oRequestLocation(self, sel);
}

static void hookedStopUpdating(id self, SEL sel) {
    [gManagers removeObject:self];
    if (!gActive && oStopUpdating) oStopUpdating(self, sel);
}

static void LBXHook(Class cls, SEL sel, IMP imp, void *orig) {
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    MSHookMessageEx(cls, sel, imp, orig);
}

__attribute__((constructor))
static void SocialBoxLocationConstructor(void) {
    if (!LBXOSPinned() || LBXSkipProcess()) return;
    gLog = os_log_create("com.socialbox.inject", "location");
    LBXReload();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, LBXNotify,
                                    CFSTR("com.socialbox.location"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    LBXHook(CLLocation.class, @selector(coordinate), (IMP)hookedCoordinate, (void *)&oCoordinate);
    LBXHook(CLLocationManager.class, @selector(location), (IMP)hookedManagerLocation,
            (void *)&oManagerLocation);
    LBXHook(CLLocationManager.class, @selector(startUpdatingLocation), (IMP)hookedStartUpdating,
            (void *)&oStartUpdating);
    LBXHook(CLLocationManager.class, @selector(requestLocation), (IMP)hookedRequestLocation,
            (void *)&oRequestLocation);
    LBXHook(CLLocationManager.class, @selector(stopUpdatingLocation), (IMP)hookedStopUpdating,
            (void *)&oStopUpdating);
    os_log(gLog, "hooks-installed exec=%{public}@ active=%{public}d", LBXExecName(), gActive);
}
