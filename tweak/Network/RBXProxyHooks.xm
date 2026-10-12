#import "RBXHTTPProxy.h"
#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXProxyHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import "RBXSocketGuard.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CFNetwork/CFNetwork.h>
#import <substrate.h>

// Per-container proxy enforcement, in-process layer.
// All NSURLSession traffic is forced through the container's upstream (HTTP or SOCKS5).
// The daemon's Network-Extension kill switch is the second layer: anything that somehow
// bypasses these hooks is dropped instead of leaking the real IP.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static BOOL RBXCriticalHostAllowed(NSString *host) {
    // A missing legacy appType is Reddit; a malformed/unknown appType admits no hosts.
    return RBXAppRuntimeCriticalHostAllowed(
        RBXAppDescriptorForType(rbxProfile().rawProfile[@"appType"]), host);
}

static BOOL RBXThirdPartyNetworkAllowed(void) {
    return [[[rbxProfile() valueForPath:@"security.thirdPartyNetwork"] lowercaseString]
            isEqualToString:@"enabled"];
}

static BOOL RBXRequestDestinationAllowed(NSURLRequest *request) {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return !([scheme isEqual:@"http"] || [scheme isEqual:@"https"]) ||
        RBXThirdPartyNetworkAllowed() || RBXCriticalHostAllowed(request.URL.host);
}

static NSDictionary *RBXConnectionProxyDictionary(void) {
    NSDictionary *endpoint = RBXParseHTTPProxyURL(RBXNetworkLeaseProxyURL());
    if (!endpoint) return nil;
    NSString *address = RBXNetworkLeaseProxyAddress();
    if (!address.length) return nil;
    NSMutableDictionary *numeric = [endpoint mutableCopy]; numeric[@"host"] = address;
    return RBXHTTPProxySettings(numeric);
}

static NSDictionary *RBXCurrentProxyCredentials(void) {
    // Called for each challenge, so revocation or replacement invalidates auth.
    if (!RBXNetworkLeaseAllowsCurrentContainer()) return nil;
    NSMutableDictionary *endpoint = [RBXParseHTTPProxyURL(RBXNetworkLeaseProxyURL()) mutableCopy];
    NSString *address = RBXNetworkLeaseProxyAddress();
    if (!endpoint || !address.length) return nil;
    endpoint[@"host"] = address;
    return endpoint;
}

static CFDictionaryRef (*orig_CFNetworkCopySystemProxySettings)(void);
static CFDictionaryRef replaced_CFNetworkCopySystemProxySettings(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXLog("CFNetwork proxy settings hook active for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
    NSDictionary *forced = RBXConnectionProxyDictionary();
    return forced ? (__bridge_retained CFDictionaryRef)forced
                  : (__bridge_retained CFDictionaryRef)@{};
}

void RBXApplyProxyToConfiguration(NSURLSessionConfiguration *cfg) {
    if (!cfg) return;
    NSDictionary *dict = RBXConnectionProxyDictionary();
    if (!dict) {
        RBXLogErr("no valid process proxy for container %@; socket guard will deny egress",
                  rbxProfile().containerId);
        return;
    }
    cfg.connectionProxyDictionary = dict;
    cfg.URLCredentialStorage = nil;
    RBXLogDebug("proxy applied to session config for container %@",
                rbxProfile().containerId);
}

static void RBXDisableBypassTransports(NSURLSessionConfiguration *cfg) {
    if (!cfg || !rbxProfile()) return;

    SEL http3 = NSSelectorFromString(@"setHTTP3Enabled:");
    if ([cfg respondsToSelector:http3]) {
        @try {
            [cfg setValue:@NO forKey:@"HTTP3Enabled"];
        } @catch (NSException *ex) {
            (void)ex;
        }
    }
}

static void RBXPrepareSessionConfiguration(NSURLSessionConfiguration *cfg) {
    RBXApplyProxyToConfiguration(cfg);
    RBXDisableBypassTransports(cfg);
}

%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    RBXPrepareSessionConfiguration(cfg);
    return cfg;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    RBXPrepareSessionConfiguration(cfg);
    return cfg;
}

+ (NSURLSessionConfiguration *)backgroundSessionConfigurationWithIdentifier:(NSString *)identifier {
    // Background configurations execute in shared nsurlsessiond, outside this
    // process's hook/storage boundary. Downgrade to an in-process ephemeral
    // session; foreground Reddit operations continue to work.
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    RBXPrepareSessionConfiguration(cfg);
    RBXLog("blocked shared background URL session identifier for container %@",
           rbxProfile().containerId);
    return cfg;
}

- (void)setConnectionProxyDictionary:(NSDictionary *)dictionary {
    NSDictionary *forced = RBXConnectionProxyDictionary();
    %orig(forced ?: @{});
}

%end

%hook NSURLSession

+ (NSURLSession *)sharedSession {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        session = [self sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    });
    return session;
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    RBXPrepareSessionConfiguration(configuration);
    return [self sessionWithConfiguration:configuration delegate:nil delegateQueue:nil];
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                  delegate:(id)delegate
                             delegateQueue:(NSOperationQueue *)queue {
    RBXPrepareSessionConfiguration(configuration);
    id wrapped = [[RBXHTTPProxyDelegate alloc] initWithDelegate:delegate
        endpoint:^{ return RBXCurrentProxyCredentials(); }
        requestAllowed:^BOOL(NSURLRequest *request) { return RBXRequestDestinationAllowed(request); }];
    return %orig(configuration, wrapped, queue);
}

%end

%hook NSURLSessionTask

- (void)resume {
    NSURLRequest *request = self.currentRequest ?: self.originalRequest;
    if (!RBXRequestDestinationAllowed(request)) {
        RBXLogErr("blocked non-critical third-party network host");
        [self cancel];
        return;
    }
    %orig;
}

%end

BOOL RBXInstallProxyHooks(RBXDeviceProfile *profile) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        (void)profile;
        %init;
        MSHookFunction((void *)CFNetworkCopySystemProxySettings,
                       (void *)replaced_CFNetworkCopySystemProxySettings,
                       (void **)&orig_CFNetworkCopySystemProxySettings);
        RBXLog("process proxy hooks installed for container %@",
               [RBXContainerManager sharedManager].containerId);
    });
    return RBXHookInstallationPassed();
}

BOOL RBXVerifyProxyHooks(void) {
    NSDictionary *expected = RBXConnectionProxyDictionary();
    if (!expected.count || !RBXHookInstallationPassed()) return NO;
    NSDictionary *system = CFBridgingRelease(CFNetworkCopySystemProxySettings());
    NSURLSessionConfiguration *standard = NSURLSessionConfiguration.defaultSessionConfiguration;
    NSURLSessionConfiguration *ephemeral = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    BOOL ok = [system isEqual:expected] && [standard.connectionProxyDictionary isEqual:expected] &&
        [ephemeral.connectionProxyDictionary isEqual:expected];
    standard.connectionProxyDictionary = @{};
    return ok && [standard.connectionProxyDictionary isEqual:expected];
}
