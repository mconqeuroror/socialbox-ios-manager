#import "LBXHelperLocation.h"
#import <CoreLocation/CoreLocation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const LBXLocationReportPath = @"/private/var/tmp/socialbox_location_sim.json";
static id gManager;

// Device-level GPS: the privileged session sequence used by the public
// udevsharold jailbreak tool (CLSimulationManager stop/clear/append/flush/start
// plus AutomaticTimeZoneUpdateNeeded). Rehosted here with SocialBox names only.
// On iOS 16 the client class is often absent; the JSON + Darwin notify still
// drive SocialBoxLocation.dylib so Maps and every other app see the pin.

static void LBXLoadCoreLocation(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_NOW);
    });
}

static Class LBXSimClass(void) {
    LBXLoadCoreLocation();
    for (NSString *name in @[ @"CLSimulationManager", @"CLsimulationManager", @"CLSimulationController" ]) {
        Class cls = NSClassFromString(name);
        if (cls) return cls;
    }
    return Nil;
}

static id LBXSimInstance(Class cls) {
    if (!cls) return nil;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if ([cls respondsToSelector:shared]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id instance = [cls performSelector:shared];
#pragma clang diagnostic pop
        if (instance) return instance;
    }
    return [cls new];
}

static void LBXPostTimeZoneUpdate(void) {
    CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(),
                                                    CFSTR("AutomaticTimeZoneUpdateNeeded"), NULL, NULL,
                                                    kCFNotificationDeliverImmediately);
}

static void LBXPostLocationChanged(void) {
    CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(),
                                                    CFSTR("com.socialbox.location"), NULL, NULL,
                                                    kCFNotificationDeliverImmediately);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
static BOOL LBXSend(id manager, NSString *name, id object) {
    SEL sel = NSSelectorFromString(name);
    if (![manager respondsToSelector:sel]) return NO;
    if (object) [manager performSelector:sel withObject:object];
    else [manager performSelector:sel];
    return YES;
}
#pragma clang diagnostic pop

static BOOL LBXSetNumber(id manager, NSString *key, NSNumber *value) {
    @try {
        [manager setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *ex) {
        return NO;
    }
}

static void LBXWriteReport(NSDictionary *report) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    if (!data.length) return;
    [data writeToFile:LBXLocationReportPath atomically:YES];
    chmod(LBXLocationReportPath.fileSystemRepresentation, 0644);
}

static NSError *LBXLocError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.socialbox.helper" code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"location simulation failed"}];
}

static CLLocation *LBXMakeLocation(double latitude, double longitude) {
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(latitude, longitude);
    if (@available(iOS 13.4, *)) {
        return [[CLLocation alloc] initWithCoordinate:coord
                                             altitude:40
                                   horizontalAccuracy:5
                                     verticalAccuracy:5
                                               course:0
                                       courseAccuracy:-1
                                                speed:0
                                        speedAccuracy:-1
                                            timestamp:NSDate.date];
    }
    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:40
                               horizontalAccuracy:5
                                 verticalAccuracy:5
                                           course:0
                                            speed:0
                                        timestamp:NSDate.date];
}

static NSArray<NSString *> *LBXClassMethods(Class cls) {
    if (!cls) return @[];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned int i = 0; i < count && names.count < 48; i++) {
        [names addObject:@(sel_getName(method_getName(methods[i])))];
    }
    free(methods);
    return names;
}

static BOOL LBXDriveLocationd(double latitude, double longitude, NSMutableDictionary *report) {
    Class cls = LBXSimClass();
    report[@"class"] = cls ? NSStringFromClass(cls) : @"";
    if (!cls) return NO;
    if (!gManager) gManager = LBXSimInstance(cls);
    id manager = gManager;
    if (!manager) return NO;

    LBXSetNumber(manager, @"locationDeliveryBehavior", @1);
    LBXSetNumber(manager, @"locationRepeatBehavior", @1);
    LBXSetNumber(manager, @"locationInterval", @0.5);

    CLLocation *location = LBXMakeLocation(latitude, longitude);
    LBXSend(manager, @"stopLocationSimulation", nil);
    LBXSend(manager, @"stopSimulation", nil);
    LBXSend(manager, @"clearSimulatedLocations", nil);
    BOOL setLoc = LBXSend(manager, @"setSimulatedLocation:", location) ||
                  LBXSend(manager, @"appendSimulatedLocation:", location) ||
                  LBXSend(manager, @"setLocation:", location);
    LBXSend(manager, @"flush", nil);
    BOOL started = LBXSend(manager, @"startLocationSimulation", nil) ||
                   LBXSend(manager, @"startSimulation", nil);
    LBXPostTimeZoneUpdate();

    report[@"hasStart"] = @([manager respondsToSelector:NSSelectorFromString(@"startLocationSimulation")] ||
                            [manager respondsToSelector:NSSelectorFromString(@"startSimulation")]);
    report[@"hasAppend"] = @([manager respondsToSelector:NSSelectorFromString(@"appendSimulatedLocation:")]);
    report[@"hasSet"] = @([manager respondsToSelector:NSSelectorFromString(@"setSimulatedLocation:")]);
    report[@"methods"] = LBXClassMethods([manager class]);
    report[@"locationd"] = @(setLoc && started);
    return setLoc && started;
}

static void LBXStopLocationd(NSMutableDictionary *report) {
    Class cls = LBXSimClass();
    report[@"class"] = cls ? NSStringFromClass(cls) : @"";
    if (!cls) return;
    if (!gManager) gManager = LBXSimInstance(cls);
    id manager = gManager;
    if (!manager) return;
    LBXSend(manager, @"stopLocationSimulation", nil);
    LBXSend(manager, @"stopSimulation", nil);
    LBXSend(manager, @"clearSimulatedLocations", nil);
    LBXSend(manager, @"flush", nil);
    LBXPostTimeZoneUpdate();
}

static BOOL LBXDriveLocationdBounded(double latitude, double longitude, NSMutableDictionary *report) {
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ok = LBXDriveLocationd(latitude, longitude, report);
        dispatch_semaphore_signal(sem);
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC))) != 0) {
        report[@"locationd"] = @NO;
        report[@"locationdTimeout"] = @YES;
        return NO;
    }
    return ok;
}

static void LBXStopLocationdBounded(NSMutableDictionary *report) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        LBXStopLocationd(report);
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
}

BOOL LBXHelperStartLocationSimulation(double latitude, double longitude, NSString **detail, NSError **error) {
    if (fabs(latitude) > 90 || fabs(longitude) > 180) {
        if (error) *error = LBXLocError(11, @"Choose a valid coordinate first.");
        return NO;
    }
    NSMutableDictionary *report = [@{
        @"lat" : @(latitude),
        @"lon" : @(longitude),
        @"uid" : @(getuid()),
        @"euid" : @(geteuid()),
        @"started" : @YES,
        @"class" : @"",
        @"locationd" : @NO,
        @"inject" : @YES,
    } mutableCopy];
    // Publish the new pin before talking to locationd so a hung client class
    // cannot leave Maps on the previous CLI test coordinate.
    LBXWriteReport(report);
    LBXPostLocationChanged();
    BOOL locationd = LBXDriveLocationdBounded(latitude, longitude, report);
    report[@"locationd"] = @(locationd);
    report[@"lat"] = @(latitude);
    report[@"lon"] = @(longitude);
    report[@"started"] = @YES;
    LBXWriteReport(report);
    LBXPostLocationChanged();
    if (detail) {
        *detail = [NSString stringWithFormat:@"GPS set to %.5f, %.5f%@%@", latitude, longitude,
                                             locationd ? @" via locationd" : @"",
                                             @" (device-wide)"];
    }
    return YES;
}

BOOL LBXHelperStopLocationSimulation(NSString **detail, NSError **error) {
    (void)error;
    NSMutableDictionary *report = [@{
        @"started" : @NO,
        @"inject" : @NO,
        @"locationd" : @NO,
        @"euid" : @(geteuid()),
    } mutableCopy];
    LBXWriteReport(report);
    LBXPostLocationChanged();
    LBXStopLocationdBounded(report);
    report[@"started"] = @NO;
    report[@"inject"] = @NO;
    LBXWriteReport(report);
    LBXPostLocationChanged();
    if (detail) *detail = @"GPS simulation stopped.";
    return YES;
}
