#import "RBXHookInstallation.h"
#import "RBXNetworkIdentityHooks.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import "RBXSocketGuard.h"
#import <SystemConfiguration/CaptiveNetwork.h>
#import <NetworkExtension/NetworkExtension.h>
#import <ifaddrs.h>
#import <substrate.h>
#import <Network/Network.h>
#import <dlfcn.h>
#import <errno.h>

static BOOL sNetworkMetadataBlocked;
static BOOL sVerified;
static int (*orig_getifaddrs)(struct ifaddrs **);
static CFArrayRef (*orig_CNCopySupportedInterfaces)(void);
static CFDictionaryRef (*orig_CNCopyCurrentNetworkInfo)(CFStringRef);
static nw_path_status_t (*orig_nw_path_get_status)(nw_path_t);
static bool (*orig_nw_path_uses_interface_type)(nw_path_t, nw_interface_type_t);
static bool (*orig_nw_path_is_expensive)(nw_path_t);
static bool (*orig_nw_path_is_constrained)(nw_path_t);

static int replaced_getifaddrs(struct ifaddrs **interfaces) {
    if (!sNetworkMetadataBlocked) return orig_getifaddrs(interfaces);
    if (interfaces) *interfaces = NULL;
    errno = EACCES;
    return -1;
}

static CFArrayRef replaced_CNCopySupportedInterfaces(void) {
    if (!sNetworkMetadataBlocked) return orig_CNCopySupportedInterfaces();
    return (__bridge_retained CFArrayRef)@[];
}

static CFDictionaryRef replaced_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (!sNetworkMetadataBlocked) return orig_CNCopyCurrentNetworkInfo(interfaceName);
    return NULL;
}

static nw_path_status_t replaced_nw_path_get_status(nw_path_t path) {
    if (!sNetworkMetadataBlocked) return orig_nw_path_get_status(path);
    return RBXNetworkLeaseAllowsCurrentContainer()
        ? nw_path_status_satisfied : nw_path_status_unsatisfied;
}

static bool replaced_nw_path_uses_interface_type(
    nw_path_t path, nw_interface_type_t type) {
    if (!sNetworkMetadataBlocked) return orig_nw_path_uses_interface_type(path, type);
    return type == nw_interface_type_cellular;
}

static bool replaced_nw_path_is_expensive(nw_path_t path) {
    return sNetworkMetadataBlocked ? true : orig_nw_path_is_expensive(path);
}

static bool replaced_nw_path_is_constrained(nw_path_t path) {
    return sNetworkMetadataBlocked ? false : orig_nw_path_is_constrained(path);
}

%hook NEHotspotNetwork

+ (void)fetchCurrentWithCompletionHandler:(void (^)(NEHotspotNetwork *currentNetwork))completionHandler {
    if (sNetworkMetadataBlocked) {
        if (completionHandler) completionHandler(nil);
        return;
    }
    %orig;
}

%end

BOOL RBXInstallNetworkIdentityHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *policy = [[RBXContainerManager sharedManager].currentProfile
                            valueForPath:@"security.networkMetadata"];
        sNetworkMetadataBlocked = ![policy isEqualToString:@"enabled"];
        MSHookFunction((void *)getifaddrs, (void *)replaced_getifaddrs,
                       (void **)&orig_getifaddrs);
        MSHookFunction((void *)CNCopySupportedInterfaces,
                       (void *)replaced_CNCopySupportedInterfaces,
                       (void **)&orig_CNCopySupportedInterfaces);
        MSHookFunction((void *)CNCopyCurrentNetworkInfo,
                       (void *)replaced_CNCopyCurrentNetworkInfo,
                       (void **)&orig_CNCopyCurrentNetworkInfo);
        void *pathStatus = dlsym(RTLD_DEFAULT, "nw_path_get_status");
        void *pathType = dlsym(RTLD_DEFAULT, "nw_path_uses_interface_type");
        void *pathExpensive = dlsym(RTLD_DEFAULT, "nw_path_is_expensive");
        void *pathConstrained = dlsym(RTLD_DEFAULT, "nw_path_is_constrained");
        if (pathStatus) MSHookFunction(pathStatus, (void *)replaced_nw_path_get_status,
                                      (void **)&orig_nw_path_get_status);
        if (pathType) MSHookFunction(pathType, (void *)replaced_nw_path_uses_interface_type,
                                    (void **)&orig_nw_path_uses_interface_type);
        if (pathExpensive) MSHookFunction(pathExpensive,
            (void *)replaced_nw_path_is_expensive, (void **)&orig_nw_path_is_expensive);
        if (pathConstrained) MSHookFunction(pathConstrained,
            (void *)replaced_nw_path_is_constrained, (void **)&orig_nw_path_is_constrained);
        %init;
        CFArrayRef interfaces = CNCopySupportedInterfaces();
        struct ifaddrs *addresses = NULL;
        errno = 0; int status = getifaddrs(&addresses);
        sVerified = orig_nw_path_get_status && orig_nw_path_uses_interface_type &&
            orig_nw_path_is_expensive && orig_nw_path_is_constrained &&
            (!sNetworkMetadataBlocked || (interfaces && CFArrayGetCount(interfaces) == 0 &&
                status == -1 && errno == EACCES && !addresses));
        if (addresses) freeifaddrs(addresses);
        if (interfaces) CFRelease(interfaces);
        RBXLog("network metadata isolation %@ policy=%@ container=%@",
               sVerified ? @"READY" : @"NOT_READY",
               sNetworkMetadataBlocked ? @"blocked" : @"enabled",
               [RBXContainerManager sharedManager].containerId);
    });
    return RBXHookInstallationPassed();
}

BOOL RBXNetworkIdentityHooksVerified(void) {
    return sVerified;
}
