#import "RBXHookInstallation.h"
#import "RBXTelephonyHooks.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

static RBXDeviceProfile *RBXCarrierProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static void RBXLogCarrierEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXLog("CoreTelephony hook active for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
}

%hook CTCarrier

- (NSString *)carrierName {
    RBXLogCarrierEntry();
    NSString *value = RBXCarrierProfile().carrierName;
    return value.length ? value : nil;
}

- (NSString *)mobileCountryCode {
    RBXLogCarrierEntry();
    NSString *value = RBXCarrierProfile().mcc;
    return value.length ? value : nil;
}

- (NSString *)mobileNetworkCode {
    RBXLogCarrierEntry();
    NSString *value = RBXCarrierProfile().mnc;
    return value.length ? value : nil;
}

- (NSString *)isoCountryCode {
    RBXLogCarrierEntry();
    NSString *locale = [RBXCarrierProfile() valueForPath:@"device.locale"];
    NSArray *parts = [locale componentsSeparatedByString:@"_"];
    return parts.count > 1 ? [parts.lastObject lowercaseString] : nil;
}

%end

static NSString *RBXServiceIdentifier(void) {
    return [NSString stringWithFormat:@"rbx-%016llx",
            (unsigned long long)RBXCarrierProfile().containerId.hash];
}

%hook CTTelephonyNetworkInfo

- (NSString *)currentRadioAccessTechnology {
    return CTRadioAccessTechnologyLTE;
}

- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology {
    return @{ RBXServiceIdentifier(): CTRadioAccessTechnologyLTE };
}

- (NSString *)dataServiceIdentifier {
    return RBXServiceIdentifier();
}

- (NSDictionary<NSString *, CTCarrier *> *)serviceSubscriberCellularProviders {
    CTCarrier *carrier = self.subscriberCellularProvider;
    return carrier ? @{ RBXServiceIdentifier(): carrier } : @{};
}

- (void)setSubscriberCellularProviderDidUpdateNotifier:(void (^)(CTCarrier *))notifier {
    // Real SIM changes and radio transitions are shared hardware events.
}

- (void)setServiceSubscriberCellularProvidersDidUpdateNotifier:
    (void (^)(NSString *))notifier {
    // Suppress real service/SIM change notifications.
}

%end

BOOL RBXInstallTelephonyHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        %init;
        RBXLog("CoreTelephony hooks installed for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
    return RBXHookInstallationPassed();
}
