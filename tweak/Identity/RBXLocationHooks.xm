#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXLocationHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// C3 — GPS spoof. Design notes:
//  - The app's delegate is read from manager.delegate at delivery time (the property
//    is weak; capturing it eagerly in a dictionary would extend delegate lifetime
//    and go stale if the app swaps delegates later).
//  - startUpdatingLocation/requestLocation do NOT call %orig when spoofing (calling
//    it would trigger the real permission prompt and real CoreLocation activity);
//    a fix is delivered on a dispatch_after of 1-2s with jitter instead.
//  - Each fix gets a ±0.002deg random offset so consecutive fixes are not
//    bit-identical; -location returns the cached last fix for stability.
//  - Not covered (accepted, best-effort per spec): significant location change,
//    visit monitoring, region monitoring, CLGeocoder reverse geocoding,
//    iBeacon ranging, heading updates.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static CLLocation *rbxLastFix;

static void RBXLogLocationEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXLog("CoreLocation hook active for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
}

static void RBXDeliverLocationBlocked(CLLocationManager *manager) {
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didFailWithError:)]) {
        NSError *error = [NSError errorWithDomain:kCLErrorDomain
                                             code:kCLErrorLocationUnknown
                                         userInfo:nil];
        [delegate locationManager:manager didFailWithError:error];
    }
}

static CLLocation *rbxMakeFix(double lat, double lon) {
    double jitterLat = ((double)arc4random_uniform(4001) / 1000.0 - 2.0) / 1000.0;   // ±0.002 deg
    double jitterLon = ((double)arc4random_uniform(4001) / 1000.0 - 2.0) / 1000.0;
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(lat + jitterLat, lon + jitterLon)
                                      altitude:0 horizontalAccuracy:250 verticalAccuracy:-1
                                     timestamp:[NSDate date]];
}

// Reads the profile fix; returns nil when no profile or no location in profile.
static BOOL rbxProfileLocation(double *latOut, double *lonOut) {
    RBXDeviceProfile *p = rbxProfile();
    if (!p) return NO;
    NSString *latStr = [p valueForPath:@"device.location.lat"];
    NSString *lonStr = [p valueForPath:@"device.location.lon"];
    if (!latStr.length || !lonStr.length) return NO;
    double lat = latStr.doubleValue;
    double lon = lonStr.doubleValue;
    // 0/0 is the "unset" marker (generator always writes real city coords).
    if (lat == 0.0 && lon == 0.0) return NO;
    *latOut = lat;
    *lonOut = lon;
    return YES;
}

static CLLocation *rbxCurrentFix(void) {
    double lat = 0.0, lon = 0.0;
    if (!rbxProfileLocation(&lat, &lon)) return nil;
    if (!rbxLastFix) {
        rbxLastFix = rbxMakeFix(lat, lon);
    }
    return rbxLastFix;
}

static void rbxDeliverFix(CLLocationManager *manager) {
    double lat = 0.0, lon = 0.0;
    if (!rbxProfileLocation(&lat, &lon)) return;

    CLLocation *fix = rbxMakeFix(lat, lon);
    rbxLastFix = fix;

    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if (delegate && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:manager didUpdateLocations:@[fix]];
    } else {
        RBXLogDebug("no delegate on %@ to receive the spoofed fix", manager);
    }
}

%hook CLLocationManager

- (void)startUpdatingLocation {
    RBXLogLocationEntry();
    double lat = 0.0, lon = 0.0;
    if (!rbxProfileLocation(&lat, &lon)) {
        if (!rbxProfile()) {
            %orig;
        } else {
            RBXLogErr("location blocked: profile has no safe location");
            RBXDeliverLocationBlocked(self);
        }
        return;
    }
    // 1-2s delay with jitter, mimicking time-to-first-fix of real GPS.
    double seconds = 1.0 + ((double)arc4random_uniform(1001) / 1000.0);
    CLLocationManager *mgr = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        rbxDeliverFix(mgr);
    });
}

- (void)requestLocation {
    RBXLogLocationEntry();
    double lat = 0.0, lon = 0.0;
    if (!rbxProfileLocation(&lat, &lon)) {
        if (!rbxProfile()) {
            %orig;
        } else {
            RBXLogErr("location request blocked: profile has no safe location");
            RBXDeliverLocationBlocked(self);
        }
        return;
    }
    // Same one-shot delivery as startUpdatingLocation, slightly faster (real
    // requestLocation returns a cached/computed fix quickly).
    double seconds = 0.5 + ((double)arc4random_uniform(1001) / 1000.0);
    CLLocationManager *mgr = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        rbxDeliverFix(mgr);
    });
}

- (CLLocation *)location {
    RBXLogLocationEntry();
    double lat = 0.0, lon = 0.0;
    if (rbxProfileLocation(&lat, &lon)) {
        return rbxCurrentFix();
    }
    // No profile (or legacy profile without device.location): pass through, so
    // manager.location stays consistent with the fixes the delegate received.
    return rbxProfile() ? nil : %orig;
}

+ (BOOL)headingAvailable { return NO; }
- (void)startUpdatingHeading {}
- (CLHeading *)heading { return nil; }
- (void)startMonitoringSignificantLocationChanges {}
- (void)startMonitoringVisits {}
- (void)startMonitoringForRegion:(CLRegion *)region {}
- (void)startMonitoringForRegion:(CLRegion *)region
                 desiredAccuracy:(CLLocationAccuracy)accuracy {}
- (void)requestStateForRegion:(CLRegion *)region {}
- (NSSet<CLRegion *> *)monitoredRegions { return [NSSet set]; }
- (void)startRangingBeaconsInRegion:(CLBeaconRegion *)region {}
- (NSSet<CLBeaconRegion *> *)rangedRegions { return [NSSet set]; }

%end

BOOL RBXInstallLocationHooks(void) {
    static BOOL installed = NO;
    if (installed) return RBXHookInstallationPassed();
    installed = YES;
    %init;
    RBXLog("location hooks installed for container %@", rbxProfile().containerId);
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallLocationHooks();
    }
}
