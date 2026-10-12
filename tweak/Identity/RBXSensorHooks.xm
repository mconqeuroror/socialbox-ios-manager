#import "RBXHookInstallation.h"
#import "RBXSensorHooks.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <CoreMotion/CoreMotion.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static BOOL sSensorsBlocked;
static BOOL sVerified;

static RBXDeviceProfile *RBXSensorProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

%hook CMMotionManager
- (BOOL)isAccelerometerAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (BOOL)isGyroAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (BOOL)isMagnetometerAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (BOOL)isDeviceMotionAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (CMAccelerometerData *)accelerometerData {
    return sSensorsBlocked ? nil : %orig;
}
- (CMGyroData *)gyroData {
    return sSensorsBlocked ? nil : %orig;
}
- (CMMagnetometerData *)magnetometerData {
    return sSensorsBlocked ? nil : %orig;
}
- (CMDeviceMotion *)deviceMotion {
    return sSensorsBlocked ? nil : %orig;
}
- (void)startAccelerometerUpdates {
    if (!sSensorsBlocked) %orig;
}
- (void)startGyroUpdates {
    if (!sSensorsBlocked) %orig;
}
- (void)startMagnetometerUpdates {
    if (!sSensorsBlocked) %orig;
}
- (void)startDeviceMotionUpdates {
    if (!sSensorsBlocked) %orig;
}
- (void)startDeviceMotionUpdatesUsingReferenceFrame:(CMAttitudeReferenceFrame)referenceFrame {
    if (!sSensorsBlocked) %orig;
}
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue
                             withHandler:(CMAccelerometerHandler)handler {
    if (!sSensorsBlocked) %orig;
}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue
                    withHandler:(CMGyroHandler)handler {
    if (!sSensorsBlocked) %orig;
}
- (void)startMagnetometerUpdatesToQueue:(NSOperationQueue *)queue
                            withHandler:(CMMagnetometerHandler)handler {
    if (!sSensorsBlocked) %orig;
}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue
                            withHandler:(CMDeviceMotionHandler)handler {
    if (!sSensorsBlocked) %orig;
}
- (void)startDeviceMotionUpdatesUsingReferenceFrame:(CMAttitudeReferenceFrame)referenceFrame
                                            toQueue:(NSOperationQueue *)queue
                                         withHandler:(CMDeviceMotionHandler)handler {
    if (!sSensorsBlocked) %orig;
}
%end

%hook CMAltimeter
+ (BOOL)isRelativeAltitudeAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (void)startRelativeAltitudeUpdatesToQueue:(NSOperationQueue *)queue
                                withHandler:(CMAltitudeHandler)handler {
    if (!sSensorsBlocked) %orig;
}
+ (BOOL)isAbsoluteAltitudeAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (void)startAbsoluteAltitudeUpdatesToQueue:(NSOperationQueue *)queue
                                withHandler:(CMAbsoluteAltitudeHandler)handler {
    if (!sSensorsBlocked) %orig;
}
%end

%hook CMPedometer
+ (BOOL)isStepCountingAvailable {
    return sSensorsBlocked ? NO : %orig;
}
+ (BOOL)isDistanceAvailable {
    return sSensorsBlocked ? NO : %orig;
}
+ (BOOL)isFloorCountingAvailable {
    return sSensorsBlocked ? NO : %orig;
}
+ (BOOL)isPaceAvailable {
    return sSensorsBlocked ? NO : %orig;
}
+ (BOOL)isCadenceAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (void)startPedometerUpdatesFromDate:(NSDate *)start
                          withHandler:(CMPedometerHandler)handler {
    if (!sSensorsBlocked) %orig;
}
- (void)queryPedometerDataFromDate:(NSDate *)start
                            toDate:(NSDate *)end
                       withHandler:(CMPedometerHandler)handler {
    if (!sSensorsBlocked) %orig;
}
%end

%hook CMMotionActivityManager
+ (BOOL)isActivityAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (void)startActivityUpdatesToQueue:(NSOperationQueue *)queue
                        withHandler:(CMMotionActivityHandler)handler {
    if (!sSensorsBlocked) %orig;
}
- (void)queryActivityStartingFromDate:(NSDate *)start
                               toDate:(NSDate *)end
                              toQueue:(NSOperationQueue *)queue
                          withHandler:(CMMotionActivityQueryHandler)handler {
    if (!sSensorsBlocked) %orig;
}
%end

%hook CMSensorRecorder
+ (BOOL)isAccelerometerRecordingAvailable {
    return sSensorsBlocked ? NO : %orig;
}
+ (BOOL)isAuthorizedForRecording {
    return sSensorsBlocked ? NO : %orig;
}
- (CMSensorDataList *)accelerometerDataFromDate:(NSDate *)fromDate
                                         toDate:(NSDate *)toDate {
    return sSensorsBlocked ? nil : %orig;
}
%end

%hook CMHeadphoneMotionManager
- (BOOL)isDeviceMotionAvailable {
    return sSensorsBlocked ? NO : %orig;
}
- (CMDeviceMotion *)deviceMotion {
    return sSensorsBlocked ? nil : %orig;
}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue
                            withHandler:(CMHeadphoneDeviceMotionHandler)handler {
    if (!sSensorsBlocked) %orig;
}
%end

%hook UIDevice
- (void)setProximityMonitoringEnabled:(BOOL)enabled {
    if (!sSensorsBlocked) %orig;
}
- (BOOL)isProximityMonitoringEnabled {
    return sSensorsBlocked ? NO : %orig;
}
- (BOOL)proximityState {
    return sSensorsBlocked ? NO : %orig;
}
- (void)beginGeneratingDeviceOrientationNotifications {
    if (!sSensorsBlocked) %orig;
}
- (BOOL)isGeneratingDeviceOrientationNotifications {
    return sSensorsBlocked ? NO : %orig;
}
- (UIDeviceOrientation)orientation {
    return sSensorsBlocked ? UIDeviceOrientationPortrait : %orig;
}
%end

%hook NSProcessInfo
- (NSProcessInfoThermalState)thermalState {
    return sSensorsBlocked ? NSProcessInfoThermalStateNominal : %orig;
}
- (BOOL)isLowPowerModeEnabled {
    return sSensorsBlocked ? NO : %orig;
}
%end

%hook UIScreen
- (CGRect)nativeBounds {
    RBXDeviceProfile *profile = RBXSensorProfile();
    CGFloat width = [[profile valueForPath:@"device.screen.w"] doubleValue];
    CGFloat height = [[profile valueForPath:@"device.screen.h"] doubleValue];
    return width > 0 && height > 0 ? CGRectMake(0, 0, width, height) : %orig;
}
- (CGFloat)scale {
    CGFloat value = [[RBXSensorProfile() valueForPath:@"device.screen.scale"] doubleValue];
    return value > 0 ? value : %orig;
}
- (CGFloat)nativeScale {
    CGFloat value = [[RBXSensorProfile() valueForPath:@"device.screen.scale"] doubleValue];
    return value > 0 ? value : %orig;
}
- (CGRect)bounds {
    CGRect pixels = self.nativeBounds;
    CGFloat scale = self.scale;
    return scale > 0 ? CGRectMake(0, 0, pixels.size.width / scale,
                                  pixels.size.height / scale) : %orig;
}
- (NSInteger)maximumFramesPerSecond {
    NSInteger value = [[RBXSensorProfile() valueForPath:@"device.screen.fps"] integerValue];
    return value > 0 ? value : %orig;
}
- (CGFloat)brightness {
    NSUInteger hash = RBXSensorProfile().containerId.hash;
    return 0.45 + (CGFloat)(hash % 31) / 100.0;
}
- (BOOL)isCaptured { return NO; }
%end

%hook CADisplayLink
- (CFTimeInterval)duration {
    NSInteger fps = [[RBXSensorProfile() valueForPath:@"device.screen.fps"] integerValue];
    return fps > 0 ? 1.0 / (CFTimeInterval)fps : %orig;
}
%end

BOOL RBXInstallSensorHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *policy = [RBXSensorProfile() valueForPath:@"security.sensorAccess"];
        sSensorsBlocked = ![policy isEqualToString:@"enabled"];
        %init;
        // Do not instantiate UIKit/CoreMotion while dyld holds its initializer
        // lock. Verification runs after the constructor returns, before readiness.

    });
    return RBXHookInstallationPassed();
}

BOOL RBXSensorHooksVerified(void) {
    sVerified = NO;
    if (!RBXHookInstallationPassed()) return NO;
    CMMotionManager *motion = [CMMotionManager new];
    UIScreen *screen = UIScreen.mainScreen;
    RBXDeviceProfile *profile = RBXSensorProfile();
    BOOL display = screen.nativeBounds.size.width == [[profile valueForPath:@"device.screen.w"] doubleValue] &&
        screen.nativeBounds.size.height == [[profile valueForPath:@"device.screen.h"] doubleValue] &&
        screen.scale == [[profile valueForPath:@"device.screen.scale"] doubleValue] &&
        screen.maximumFramesPerSecond == [[profile valueForPath:@"device.screen.fps"] integerValue];
    sVerified = display && (!sSensorsBlocked || (!motion.accelerometerAvailable &&
        !motion.gyroAvailable && !motion.magnetometerAvailable && !motion.deviceMotionAvailable &&
        !motion.accelerometerData && !motion.gyroData && !motion.magnetometerData && !motion.deviceMotion));
    RBXLog("sensor/display isolation %@ policy=%@ container=%@",
           sVerified ? @"READY" : @"NOT_READY",
           sSensorsBlocked ? @"blocked" : @"enabled",
           RBXSensorProfile().containerId);
    return sVerified;
}
