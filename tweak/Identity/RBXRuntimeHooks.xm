#import "RBXHookInstallation.h"
#import "RBXRuntimeHooks.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import <substrate.h>
#import <time.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>

static uint64_t (*orig_mach_absolute_time)(void);
static uint64_t (*orig_mach_continuous_time)(void);
static int (*orig_clock_gettime)(clockid_t, struct timespec *);
static uint64_t (*orig_clock_gettime_nsec_np)(clockid_t);
static uint64_t sAbsoluteStart;
static uint64_t sContinuousStart;
static uint64_t sDesiredStart;
static mach_timebase_info_data_t sTimebase;
static BOOL sStrictTiming;
static BOOL sVerified;

static uint64_t RBXSecondsToTicks(NSTimeInterval seconds) {
    long double nanos = (long double)seconds * 1000000000.0L;
    return (uint64_t)(nanos * sTimebase.denom / sTimebase.numer);
}

static uint64_t RBXTicksToNanos(uint64_t ticks) {
    return (uint64_t)((long double)ticks * sTimebase.numer / sTimebase.denom);
}

static uint64_t RBXSyntheticTicks(uint64_t real, uint64_t start) {
    if (!sStrictTiming || real < start) return real;
    return sDesiredStart + (real - start);
}

static uint64_t replaced_mach_absolute_time(void) {
    return RBXSyntheticTicks(orig_mach_absolute_time(), sAbsoluteStart);
}

static uint64_t replaced_mach_continuous_time(void) {
    return RBXSyntheticTicks(orig_mach_continuous_time(), sContinuousStart);
}

static BOOL RBXClockIsMonotonic(clockid_t clockId) {
    if (clockId == CLOCK_MONOTONIC) return YES;
#ifdef CLOCK_MONOTONIC_RAW
    if (clockId == CLOCK_MONOTONIC_RAW) return YES;
#endif
#ifdef CLOCK_UPTIME_RAW
    if (clockId == CLOCK_UPTIME_RAW) return YES;
#endif
    return NO;
}

static int replaced_clock_gettime(clockid_t clockId, struct timespec *value) {
    if (!sStrictTiming || !value || !RBXClockIsMonotonic(clockId))
        return orig_clock_gettime(clockId, value);
    uint64_t nanos = RBXTicksToNanos(replaced_mach_absolute_time());
    value->tv_sec = (time_t)(nanos / NSEC_PER_SEC);
    value->tv_nsec = (long)(nanos % NSEC_PER_SEC);
    return 0;
}

static uint64_t replaced_clock_gettime_nsec_np(clockid_t clockId) {
    if (!sStrictTiming || !RBXClockIsMonotonic(clockId))
        return orig_clock_gettime_nsec_np(clockId);
    return RBXTicksToNanos(replaced_mach_absolute_time());
}

%hook NSProcessInfo

- (NSTimeInterval)systemUptime {
    if (!sStrictTiming) return %orig;
    return (NSTimeInterval)RBXTicksToNanos(replaced_mach_absolute_time()) /
        1000000000.0;
}

%end

BOOL RBXInstallRuntimeHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXDeviceProfile *profile = [RBXContainerManager sharedManager].currentProfile;
        sStrictTiming = [[[profile valueForPath:@"security.strictTiming"] lowercaseString]
                         isEqualToString:@"enabled"];
        mach_timebase_info(&sTimebase);
        if (!sTimebase.numer || !sTimebase.denom) {
            sTimebase.numer = 1;
            sTimebase.denom = 1;
        }
        NSTimeInterval bootEpoch =
            [[profile valueForPath:@"timing.syntheticBootEpoch"] doubleValue];
        NSTimeInterval desired = bootEpoch > 0
            ? MAX(3600.0, NSDate.date.timeIntervalSince1970 - bootEpoch)
            : MAX(3600.0,
                [[profile valueForPath:@"timing.bootTimeOffsetSeconds"] doubleValue]);
        sDesiredStart = RBXSecondsToTicks(desired);

        orig_mach_absolute_time = mach_absolute_time;
        sAbsoluteStart = orig_mach_absolute_time();
        MSHookFunction((void *)mach_absolute_time, (void *)replaced_mach_absolute_time,
                       (void **)&orig_mach_absolute_time);

        void *continuous = dlsym(RTLD_DEFAULT, "mach_continuous_time");
        if (continuous) {
            orig_mach_continuous_time = (uint64_t (*)(void))continuous;
            sContinuousStart = orig_mach_continuous_time();
            MSHookFunction(continuous, (void *)replaced_mach_continuous_time,
                           (void **)&orig_mach_continuous_time);
        }
        MSHookFunction((void *)clock_gettime, (void *)replaced_clock_gettime,
                       (void **)&orig_clock_gettime);
        void *nsec = dlsym(RTLD_DEFAULT, "clock_gettime_nsec_np");
        if (nsec) {
            MSHookFunction(nsec, (void *)replaced_clock_gettime_nsec_np,
                           (void **)&orig_clock_gettime_nsec_np);
        }
        %init;
        NSTimeInterval observed = NSProcessInfo.processInfo.systemUptime;
        struct timespec clock = {};
        uint64_t absolute = mach_absolute_time();
        uint64_t continuousValue = continuous ? ((uint64_t (*)(void))continuous)() : 0;
        uint64_t nanos = nsec ? ((uint64_t (*)(clockid_t))nsec)(CLOCK_MONOTONIC) : 0;
        BOOL clockRead = clock_gettime(CLOCK_MONOTONIC, &clock) == 0;
        double clockSeconds = (double)clock.tv_sec + (double)clock.tv_nsec / NSEC_PER_SEC;
        sVerified = RBXHookInstallationPassed() && orig_mach_continuous_time &&
            orig_clock_gettime_nsec_np && clockRead && (!sStrictTiming ||
            (observed >= desired && observed < desired + 30.0 &&
             RBXTicksToNanos(absolute) / 1e9 >= desired && RBXTicksToNanos(absolute) / 1e9 < desired + 30.0 &&
             RBXTicksToNanos(continuousValue) / 1e9 >= desired && RBXTicksToNanos(continuousValue) / 1e9 < desired + 30.0 &&
             nanos / 1e9 >= desired && nanos / 1e9 < desired + 30.0 &&
             clockSeconds >= desired && clockSeconds < desired + 30.0));
        RBXLog("runtime timing isolation %@ for container %@",
               sVerified ? @"READY" : @"NOT_READY", profile.containerId);
    });
    return RBXHookInstallationPassed();
}

BOOL RBXRuntimeHooksVerified(void) {
    return sVerified;
}
