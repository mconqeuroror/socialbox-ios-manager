#import "RBXAppRuntime.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import "RBXIdentityEngine.h"
#import "RBXAppleIdentifierHooks.h"
#import "RBXDeviceHooks.h"
#import "RBXSysctlHooks.h"
#import "RBXIOKitHooks.h"
#import "RBXTelephonyHooks.h"
#import "RBXLocaleHooks.h"
#import "RBXTimezoneHooks.h"
#import "RBXLocationHooks.h"
#import "RBXBatteryHooks.h"
#import "RBXRuntimeHooks.h"
#import "RBXSensorHooks.h"
#import "RBXGPUHooks.h"
#import "RBXPathHooks.h"
#import "RBXKeychainHooks.h"
#import "RBXFacebookStorageHooks.h"
#import "RBXWebStorageHooks.h"
#import "RBXPasteboardHooks.h"
#import "RBXProxyHooks.h"
#import "RBXSocketGuard.h"
#import "RBXNetworkIdentityHooks.h"
#import "RBXRedditAPIHooks.h"
#import "RBXFacebookUserAgentHooks.h"
#import "RBXJailbreakHider.h"
#import "RBXAppAttestHooks.h"
#import "RBXPushHooks.h"
#import "RBXRequestAudit.h"
#import "RBXNotificationHooks.h"
#import <Foundation/Foundation.h>

#import "RBXHookReadiness.h"
#import "RBXExceptionPortGuard.h"
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>

extern "C" void RBXInstallIsolationSentinel(void);

static NSDictionary *RBXRunBehaviorChecks(void) {
    RBXContainerManager *manager = RBXContainerManager.sharedManager;
    RBXDeviceProfile *profile = manager.currentProfile;
    BOOL identifiers = [ASIdentifierManager.sharedManager.advertisingIdentifier
        isEqual:[[NSUUID alloc] initWithUUIDString:profile.idfa]] &&
        [UIDevice.currentDevice.identifierForVendor isEqual:[[NSUUID alloc] initWithUUIDString:profile.idfv]] &&
        [UIDevice.currentDevice.name isEqual:profile.deviceName] &&
        [UIDevice.currentDevice.systemVersion isEqual:profile.iosVersion] &&
        ATTrackingManager.trackingAuthorizationStatus ==
            (profile.idfaPosture == RBXIDFAPostureRandom ? ATTrackingManagerAuthorizationStatusAuthorized :
                ATTrackingManagerAuthorizationStatusDenied);
    BOOL facebook = [RBXAppDescriptorForProfile(profile.rawProfile)[@"appType"] isEqual:@"facebook"];
    BOOL regional = [NSLocale.currentLocale.localeIdentifier isEqual:[profile valueForPath:@"device.locale"]] &&
        [NSTimeZone.systemTimeZone.name isEqual:profile.timezone] &&
        [NSTimeZone.localTimeZone.name isEqual:profile.timezone] &&
        [NSTimeZone.defaultTimeZone.name isEqual:profile.timezone];
    return @{
        @"pasteboard": @(RBXVerifyPasteboardHooks()),
        @"profile-entitlements-keychain": @(manager.validatedProfileLoaded),
        @"mobilegestalt": @(RBXMobileGestaltHookVerified()),
        @"sysctl-uname": @(RBXVerifySysctlHooks()), @"iokit": @(RBXVerifyIOKitHooks()),
        @"idfa-idfv-device": @(identifiers), @"locale-timezone": @(regional),
        @"runtime-timing": @(RBXRuntimeHooksVerified()), @"sensors-display": @(RBXSensorHooksVerified()),
        @"metal-gpu": @(RBXGPUHooksVerified()), @"network-metadata": @(RBXNetworkIdentityHooksVerified()),
        @"process-proxy": @(RBXVerifyProxyHooks()), @"socket-guard": @(RBXVerifySocketGuard(NULL) && (!facebook || RBXExceptionPortGuardVerified()))
    };
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXContainerManager *mgr = RBXContainerManager.sharedManager;
        // Install before granting readiness, including when profile validation
        // fails. Every required installer contributes checked evidence.
        NSMutableDictionary *installed = [NSMutableDictionary dictionary];
        installed[@"keychain-sync-policy"] = @(RBXInstallKeychainSyncPolicy(mgr));
        if ([RBXAppDescriptorForProfile(mgr.currentProfile.rawProfile)[@"appType"] isEqual:@"facebook"])
            installed[@"facebook-storage"] = @(RBXInstallFacebookStorageHooks(mgr));
        installed[@"web-policy"] = @(RBXInstallWebStorageHooks());
        installed[@"pasteboard"] = @(RBXInstallPasteboardHooks());
        installed[@"mobilegestalt"] = @(RBXInstallMobileGestaltHooks());
        installed[@"idfa-idfv"] = @(RBXInstallAppleIdentifierHooks(mgr.currentProfile));
        installed[@"device"] = @(RBXInstallDeviceHooks(mgr.currentProfile));
        installed[@"sysctl-uname"] = @(RBXInstallSysctlHooks(mgr.currentProfile));
        installed[@"runtime-timing"] = @(RBXInstallRuntimeHooks());
        installed[@"iokit"] = @(RBXInstallIOKitHooks(mgr.currentProfile));
        installed[@"telephony"] = @(RBXInstallTelephonyHooks());
        installed[@"locale"] = @(RBXInstallLocaleHooks());
        installed[@"timezone"] = @(RBXInstallTimezoneHooks());
        installed[@"location"] = @(RBXInstallLocationHooks());
        installed[@"battery"] = @(RBXInstallBatteryHooks());
        installed[@"sensors-display"] = @(RBXInstallSensorHooks());
        installed[@"metal-gpu"] = @(RBXInstallGPUHooks());
        installed[@"process-proxy"] = @(RBXInstallProxyHooks(mgr.currentProfile));
        installed[@"socket-guard"] = @(RBXInstallSocketGuard());
        if ([RBXAppDescriptorForProfile(mgr.currentProfile.rawProfile)[@"appType"] isEqual:@"facebook"]) {
            BOOL compatible = RBXInstallExceptionPortGuard();
            installed[@"facebook-breakpoint-compatibility"] = @(compatible);
            installed[@"socket-guard"] = @([installed[@"socket-guard"] boolValue] && compatible);
        }
        installed[@"network-metadata"] = @(RBXInstallNetworkIdentityHooks());
        NSDictionary *app = RBXAppDescriptorForProfile(mgr.currentProfile.rawProfile);
        if (RBXAppRuntimeWirePolicyAudited(app)) {
            installed[@"defaults-wire"] = @(RBXInstallRedditAPIHooks(mgr.currentProfile));
        } else {
            // The OS layer can install successfully without proving SDK-specific
            // family/machine ID isolation. Never turn that gap into a PASS receipt.
            installed[@"defaults-wire"] = @NO;
            if ([app[@"appType"] isEqual:@"facebook"]) {
                BOOL producer = RBXInstallFacebookUserAgentHooks(mgr.currentProfile);
                installed[@"facebook-ua-producer"] = @(producer);
                RBXLog("RBX_SELF_REPORT group=facebook-ua-producer evidence=installation status=%@ container=%@",
                    producer ? @"CHECKED" : @"FAILED", mgr.containerId);
            }
            RBXLogErr("app-specific identity readiness denied for %@: SDK persistence/wire policy is not verified",
                      app[@"appType"] ?: @"unknown");
        }
        installed[@"jailbreak-hiding"] = @(RBXInstallJailbreakHider());
        installed[@"appattest-devicecheck"] = @(RBXInstallAppAttestHooks());
        installed[@"push"] = @(RBXInstallPushHooks());
        installed[@"notifications"] = @(RBXInstallNotificationHooks());
        for (NSString *group in RBXRequiredHookGroups()) {
            RBXLog("RBX_SELF_REPORT group=%@ evidence=installation status=%@ container=%@",
                group, [installed[group] isEqual:@YES] ? @"CHECKED" : @"FAILED", mgr.containerId);
        }
        // The container manager checks effective entitlements and a clone-group
        // keychain round trip. This is not a blanket sandbox isolation proof.
        // UIKit behavior probes must not run under dyld's initializer lock.
        // All hooks are installed synchronously; the socket gate remains closed
        // until the deferred behavior checks and the daemon's lease agree.
        dispatch_async(dispatch_get_main_queue(), ^{
            RBXMarkAllHooksReady(installed, ^{ return RBXRunBehaviorChecks(); });
            [mgr runAcceptanceProbeIfRequested];
            RBXInstallIsolationSentinel();
        });
    }
}
