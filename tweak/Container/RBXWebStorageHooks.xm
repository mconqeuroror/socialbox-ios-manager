#import "RBXHookInstallation.h"
#import "RBXWebStorageHooks.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import "RBXSocketGuard.h"
#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <AuthenticationServices/AuthenticationServices.h>
#import <objc/message.h>

static void RBXDisableWebRTCCapabilities(WKPreferences *preferences) {
    // Use the actual WebKit SPI names. The unprefixed methods do not exist on
    // iOS 16, and silently ignoring a failed KVC write did not disable anything.
    for (NSString *name in @[@"_setPeerConnectionEnabled:", @"_setMediaDevicesEnabled:",
                             @"_setWebRTCLegacyAPIEnabled:"]) {
        SEL setter = NSSelectorFromString(name);
        if ([preferences respondsToSelector:setter])
            ((void (*)(id, SEL, BOOL))objc_msgSend)(preferences, setter, NO);
    }
}

%hook WKWebViewConfiguration
- (void)setPreferences:(WKPreferences *)preferences {
    RBXDisableWebRTCCapabilities(preferences);
    %orig(preferences);
}

- (WKPreferences *)preferences {
    WKPreferences *preferences = %orig;
    RBXDisableWebRTCCapabilities(preferences);
    return preferences;
}

%end

%hook WKPreferences
- (BOOL)_peerConnectionEnabled { return NO; }
- (void)_setPeerConnectionEnabled:(BOOL)enabled {
    %orig(NO);
}
- (BOOL)_mediaDevicesEnabled { return NO; }
- (void)_setMediaDevicesEnabled:(BOOL)enabled {
    %orig(NO);
}
%end

%hook WKWebView

- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    if (!RBXNetworkLeaseAllowsCurrentContainer()) {
        RBXLogErr("blocked WKWebView load without active system-firewall lease");
        return nil;
    }
    return %orig;
}

- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    return %orig(string, nil);
}

%end

%hook ASWebAuthenticationSession

- (BOOL)start {
    if (!RBXSystemFirewallCoversOutOfProcessAuth()) {
        RBXLogErr("blocked ASWebAuthenticationSession without managed SafariDomains VPN coverage");
        return NO;
    }
    if ([self respondsToSelector:@selector(setPrefersEphemeralWebBrowserSession:)]) {
        self.prefersEphemeralWebBrowserSession = YES;
    }
    RBXLog("ASWebAuthenticationSession allowed with ephemeral storage and managed VPN coverage");
    return %orig;
}

- (void)setPrefersEphemeralWebBrowserSession:(BOOL)ephemeral {
    %orig(YES);
}

%end

%hook NSUbiquitousKeyValueStore

- (id)objectForKey:(NSString *)aKey { return nil; }
- (NSString *)stringForKey:(NSString *)aKey { return nil; }
- (NSArray *)arrayForKey:(NSString *)aKey { return nil; }
- (NSDictionary *)dictionaryForKey:(NSString *)aKey { return nil; }
- (NSData *)dataForKey:(NSString *)aKey { return nil; }
- (long long)longLongForKey:(NSString *)aKey { return 0; }
- (double)doubleForKey:(NSString *)aKey { return 0; }
- (BOOL)boolForKey:(NSString *)aKey { return NO; }
- (void)setObject:(id)anObject forKey:(NSString *)aKey {}
- (void)setString:(NSString *)aString forKey:(NSString *)aKey {}
- (void)setArray:(NSArray *)anArray forKey:(NSString *)aKey {}
- (void)setDictionary:(NSDictionary *)aDictionary forKey:(NSString *)aKey {}
- (void)setData:(NSData *)aData forKey:(NSString *)aKey {}
- (void)setLongLong:(long long)value forKey:(NSString *)aKey {}
- (void)setDouble:(double)value forKey:(NSString *)aKey {}
- (void)setBool:(BOOL)value forKey:(NSString *)aKey {}
- (void)removeObjectForKey:(NSString *)aKey {}
- (NSDictionary<NSString *, id> *)dictionaryRepresentation { return @{}; }
- (BOOL)synchronize { return NO; }

%end

BOOL RBXInstallWebStorageHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXContainerManager *manager = [RBXContainerManager sharedManager];
        %init;
        RBXLog("WebRTC/iCloud policy hooks active; WebKit storage uses clone OS sandbox for %@",
               manager.containerId);
    });
    return RBXHookInstallationPassed();
}
