#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXAppleIdentifierHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <AdSupport/ASIdentifierManager.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>

// IDFA / IDFV / ATT posture (A5/A6 + D3). Without these hooks every container
// shares the same IDFA/IDFV -> one device for AppsFlyer/Firebase/Reddit.
// Payload comes from the profile; the ATT status derives from the posture:
//   random           -> IDFA = per-container UUID, ATT authorized
//   zeroWithATTDenied-> IDFA = all-zeros UUID, isAdvertisingTrackingEnabled NO,
//                       ATTrackingManager reports denied, no system prompt

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static NSString *sRealIdfa;

NSString *RBXRealIDFAString(void) {
    return sRealIdfa;
}

%hook ASIdentifierManager

- (NSUUID *)advertisingIdentifier {
    NSUUID *real = %orig;
    if (!sRealIdfa && real) {
        sRealIdfa = [real.UUIDString copy];
    }
    RBXDeviceProfile *p = rbxProfile();
    if (p.idfa) {
        return [[NSUUID alloc] initWithUUIDString:p.idfa];
    }
    return real;
}

- (BOOL)isAdvertisingTrackingEnabled {
    RBXDeviceProfile *p = rbxProfile();
    if (p.idfaPosture == RBXIDFAPostureZeroWithATTDenied) {
        return NO;
    }
    return p ? YES : NO;
}

%end

%hook ATTrackingManager

+ (ATTrackingManagerAuthorizationStatus)trackingAuthorizationStatus {
    RBXDeviceProfile *p = rbxProfile();
    if (p.idfaPosture == RBXIDFAPostureZeroWithATTDenied) {
        return ATTrackingManagerAuthorizationStatusDenied;
    }
    return p ? ATTrackingManagerAuthorizationStatusAuthorized
             : ATTrackingManagerAuthorizationStatusDenied;
}

+ (void)requestTrackingAuthorizationWithCompletionHandler:(void(^)(ATTrackingManagerAuthorizationStatus status))completion {
    RBXDeviceProfile *p = rbxProfile();
    ATTrackingManagerAuthorizationStatus status =
        p && p.idfaPosture == RBXIDFAPostureRandom
            ? ATTrackingManagerAuthorizationStatusAuthorized
            : ATTrackingManagerAuthorizationStatusDenied;
    if (completion) completion(status);
}

%end

BOOL RBXInstallAppleIdentifierHooks(RBXDeviceProfile *profile) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        (void)profile;
        %init;
        (void)[ASIdentifierManager sharedManager].advertisingIdentifier;
        RBXLog("IDFA/ATT hooks installed for container %@", rbxProfile().containerId);
    });
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallAppleIdentifierHooks(rbxProfile());
    }
}

