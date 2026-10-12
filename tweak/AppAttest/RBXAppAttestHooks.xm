#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXDataSchema.h"
#import "RBXAppAttestHooks.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import "RBXPathHooks.h"
#import <Foundation/Foundation.h>
#import <DeviceCheck/DeviceCheck.h>
#import <substrate.h>

// App Attest + DeviceCheck hooks.
//
// Toggle semantics:
//  - OFF  : all DCAppAttestService calls complete with a DeviceCheck-style error
//           (domain com.apple.devicecheck.error, code DCErrorUnknownSystemFailure). Reddit's SDK
//           treats this like an iPhone that cannot attest (iOS 13 era) and skips it.
//  - ON   : calls pass through; a successful generateKey records
//           {containerId, keyId, timestamp} in the central store (budget tracking).
//
// The effective mode is resolved per call so prefs changes take effect on the next
// call without a relaunch. Cache refresh happens on the storeChanged notification.

static NSString *sContainerId;
static NSString *sEffectiveMode;   // cached "on"/"off"
static BOOL sDeviceCheckDisabled;  // 2.2: DCDevice.generateToken default OFF

static NSData *RBXReadControlData(NSString *path) {
    RBXBeginInternalControlFileAccess();
    NSData *data = [NSData dataWithContentsOfFile:path];
    RBXEndInternalControlFileAccess();
    return data;
}

static NSDictionary *RBXReadControlPlist(NSString *path) {
    RBXBeginInternalControlFileAccess();
    NSDictionary *value = [NSDictionary dictionaryWithContentsOfFile:path];
    RBXEndInternalControlFileAccess();
    return value;
}

static void RBXWriteControlData(NSData *data, NSString *path, NSData *expected) {
    RBXBeginInternalControlFileAccess();
    NSDictionary *document = RBXSchemaDecode(data, RBXDataStore, nil);
    if (document) RBXSchemaWriteJSONExpected(document, path, RBXDataStore, expected, nil);
    RBXEndInternalControlFileAccess();
}

// Logos %hook blocks install their own constructors, which may run before
// RBXInstallAppAttestHooks() gets called; resolve lazily so the statics are
// always valid on the first hooked call.
static NSString *RBXContainerId(void) {
    if (!sContainerId) {
        sContainerId = [RBXContainerManager sharedManager].containerId;
    }
    return sContainerId;
}

NSString *const RBXDeviceCheckErrorDomain = @"com.apple.devicecheck.error";

static NSError *RBXAttestError(void) {
    return [NSError errorWithDomain:RBXDeviceCheckErrorDomain
                               code:DCErrorUnknownSystemFailure
                           userInfo:@{NSLocalizedDescriptionKey: @"App Attest unavailable"}];
}

static void RBXRefreshEffectiveMode(void) {
    // Read the shared central store file (same schema as daemon/RBXCentralStore;
    // re-implemented locally so the tweak does not link the daemon target).
    sEffectiveMode = nil;   // force re-read below

    NSString *path = @"/var/mobile/Library/Preferences/com.redditbox.store.json";
    NSData *data = RBXReadControlData(path);
    if (!data.length) {
        // Missing/empty/unreadable state is not permission to create keys.
        sEffectiveMode = @"off";
        return;
    }
    id doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!RBXSchemaValidate(doc, RBXDataStore, nil)) {
        sEffectiveMode = @"off";
        return;
    }
    NSDictionary *cont = doc[@"containers"][sContainerId];
    NSString *mode = cont[@"attest"][@"mode"];
    if ([mode isKindOfClass:[NSString class]]) {
        if ([mode isEqualToString:@"on"] || [mode isEqualToString:@"off"]) {
            sEffectiveMode = mode;
            return;
        }
    }
    // auto / missing -> A/B group default (A=on, B=off)
    NSString *group = cont[@"attest"][@"group"];
    if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
        sEffectiveMode = [group isEqualToString:@"A"] ? @"on" : @"off";
        return;
    }
    // -> global default
    sEffectiveMode = [doc[@"device"][@"attestDefault"] isEqualToString:@"off"] ? @"off" : @"on";
}

static BOOL RBXAttestBlocked(void) {
    // Container explicitly blocked (duplicate keyId etc.) -> behave like OFF, but
    // the store lookup is cheap and only needed when attest would otherwise run.
    NSString *path = @"/var/mobile/Library/Preferences/com.redditbox.store.json";
    NSData *data = RBXReadControlData(path);
    if (!data.length) return YES;
    id doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!RBXSchemaValidate(doc, RBXDataStore, nil)) return YES;
    NSDictionary *attest = doc[@"containers"][sContainerId][@"attest"];
    return [attest isKindOfClass:[NSDictionary class]] && [attest[@"blocked"] boolValue];
}

// Shared: run completion off-main? No — DeviceCheck expects the caller's queue.
static void RBXRecordKeyIfNew(NSString *keyId) {
    if (!keyId.length || !sContainerId.length) return;

    // Update the shared store file (read-modify-write, same format as daemon).
    // Only the daemon initializes the store after the complete schema preflight.
    NSString *path = @"/var/mobile/Library/Preferences/com.redditbox.store.json";
    NSData *raw = RBXReadControlData(path);
    id parsed = raw.length ? [NSJSONSerialization JSONObjectWithData:raw
                                                             options:NSJSONReadingMutableContainers
                                                               error:nil] : nil;
    if (!RBXSchemaValidate(parsed, RBXDataStore, nil)) return;
    NSMutableDictionary *doc = [parsed isKindOfClass:[NSMutableDictionary class]] ?
        parsed : [NSMutableDictionary dictionary];
    if (![doc[@"device"] isKindOfClass:[NSMutableDictionary class]]) {
        doc[@"device"] = [NSMutableDictionary dictionaryWithDictionary:@{
            @"keyBudget": @100, @"attestDefault": @"on"}];
    }
    if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) {
        doc[@"containers"] = [NSMutableDictionary dictionary];
    }

    // 1) dedup guard: key already used by a different container?
    BOOL duplicate = NO;
    for (NSDictionary *e in (doc[@"device"][@"attestKeysUsed"] ?: @[])) {
        if ([e isKindOfClass:[NSDictionary class]] &&
            [e[@"keyId"] isEqualToString:keyId] &&
            ![(NSString *)e[@"containerId"] isEqualToString:sContainerId]) {
            duplicate = YES;
            break;
        }
    }
    if (!duplicate) {
        NSDictionary *containers = doc[@"containers"];
        if ([containers isKindOfClass:[NSDictionary class]]) {
            for (NSString *other in containers) {
                if ([other isEqualToString:sContainerId]) continue;
                NSArray *ids = containers[other][@"attest"][@"keyIds"];
                if ([ids isKindOfClass:[NSArray class]] && [ids containsObject:keyId]) {
                    duplicate = YES;
                    break;
                }
            }
        }
    }
    if (duplicate) {
        RBXLogErr("DUPLICATE KEYID detected for container %@ — blocking attest", sContainerId);
        NSMutableDictionary *cont = ((NSMutableDictionary *)doc[@"containers"][sContainerId] ?: [NSMutableDictionary dictionary]);
        NSMutableDictionary *attest = [cont[@"attest"] isKindOfClass:[NSDictionary class]] ?
            [cont[@"attest"] mutableCopy] : [NSMutableDictionary dictionary];
        attest[@"duplicateKey"] = @YES;
        attest[@"blocked"] = @YES;
        cont[@"attest"] = attest;
        ((NSMutableDictionary *)doc[@"containers"])[sContainerId] = cont;

        NSMutableArray *alerts = [doc[@"alerts"] isKindOfClass:[NSArray class]] ?
            [doc[@"alerts"] mutableCopy] : [NSMutableArray array];
        [alerts addObject:@{
            @"type": @"DUPLICATE KEYID",
            @"containerId": sContainerId,
            @"message": [NSString stringWithFormat:
                @"Container %@ reuses an App Attest key from another container — attestation blocked so Reddit cannot link them.", sContainerId],
            @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
        }];
        doc[@"alerts"] = alerts;
    } else {
        // 2) record the key for budget tracking
        NSMutableArray *used = [doc[@"device"][@"attestKeysUsed"] isKindOfClass:[NSArray class]] ?
            [doc[@"device"][@"attestKeysUsed"] mutableCopy] : [NSMutableArray array];
        BOOL already = NO;
        for (NSDictionary *e in used) {
            if ([e isKindOfClass:[NSDictionary class]] &&
                [e[@"keyId"] isEqualToString:keyId] &&
                [(NSString *)e[@"containerId"] isEqualToString:sContainerId]) {
                already = YES;
                break;
            }
        }
        if (!already) {
            [used addObject:@{
                @"containerId": sContainerId,
                @"keyId": keyId,
                @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
            }];
            ((NSMutableDictionary *)doc[@"device"])[@"attestKeysUsed"] = used;
        }

        // 3) also remember it in the container's own keyIds list
        NSMutableDictionary *cont = ((NSMutableDictionary *)doc[@"containers"][sContainerId] ?: [NSMutableDictionary dictionary]);
        NSMutableDictionary *attest = [cont[@"attest"] isKindOfClass:[NSDictionary class]] ?
            [cont[@"attest"] mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableArray *ids = [attest[@"keyIds"] isKindOfClass:[NSArray class]] ?
            [attest[@"keyIds"] mutableCopy] : [NSMutableArray array];
        if (![ids containsObject:keyId]) [ids addObject:keyId];
        attest[@"keyIds"] = ids;
        cont[@"attest"] = attest;
        ((NSMutableDictionary *)doc[@"containers"])[sContainerId] = cont;
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
    if (json) RBXWriteControlData(json, path, raw);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                        CFSTR("com.redditbox.storeChanged"), NULL, NULL, TRUE);
}

static BOOL RBXDeviceCheckShouldBlock(void) {
    NSString *mode = [[RBXContainerManager sharedManager].currentProfile
                      valueForPath:@"security.deviceCheck"];
    return ![mode isEqualToString:@"enabled"];
}

static BOOL RBXAppAttestShouldBlock(void) {
    NSString *mode = [[RBXContainerManager sharedManager].currentProfile
                      valueForPath:@"security.appAttest"];
    return ![mode isEqualToString:@"enabled"] || RBXAttestBlocked();
}

static void RBXLogAttestEntry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        RBXLog("App Attest/DeviceCheck hooks active for container %@ (profile policy enforced)",
               RBXContainerId());
    });
}

%hook DCAppAttestService

- (BOOL)isSupported {
    RBXLogAttestEntry();
    return RBXAppAttestShouldBlock() ? NO : %orig;
}

- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyId, NSError *error))handler {
    RBXLogAttestEntry();
    if (RBXAppAttestShouldBlock()) {
        if (handler) handler(nil, RBXAttestError());
        return;
    }
    %orig(^(NSString *keyId, NSError *error) {
        if (keyId.length && !error) RBXRecordKeyIfNew(keyId);
        if (handler) handler(keyId, error);
    });
}

- (void)attestKey:(NSString *)keyId
       clientDataHash:(NSData *)clientDataHash
    completionHandler:(void (^)(NSData *attestationObject, NSError *error))handler {
    RBXLogAttestEntry();
    if (RBXAppAttestShouldBlock()) {
        if (handler) handler(nil, RBXAttestError());
        return;
    }
    %orig;
}

- (void)generateAssertion:(NSString *)keyId
          clientDataHash:(NSData *)clientDataHash
        completionHandler:(void (^)(NSData *assertion, NSError *error))handler {
    RBXLogAttestEntry();
    if (RBXAppAttestShouldBlock()) {
        if (handler) handler(nil, RBXAttestError());
        return;
    }
    %orig;
}

%end

// --- Feature 2.2: DCDevice token monitor -------------------------------------

%hook DCDevice

- (BOOL)isSupported {
    RBXLogAttestEntry();
    return RBXDeviceCheckShouldBlock() ? NO : %orig;
}

- (void)generateTokenWithCompletionHandler:(void (^)(NSData *token, NSError *error))handler {
    RBXLogAttestEntry();
    if (RBXDeviceCheckShouldBlock()) {
        if (handler) handler(nil, RBXAttestError());
        return;
    }
    %orig;
}

%end

// --- Installs + cache refresh -------------------------------------------------

static void storeChangedCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    RBXRefreshEffectiveMode();
}

static void sDeviceCheckPrefRefresh(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    NSDictionary *prefs = RBXReadControlPlist(
        @"/var/mobile/Library/Preferences/com.redditbox.prefs.plist");
    sDeviceCheckDisabled = prefs[@"devicecheckEnabled"] ? ![prefs[@"devicecheckEnabled"] boolValue] : YES;
}

BOOL RBXInstallAppAttestHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      sContainerId = [RBXContainerManager sharedManager].containerId;
      %init;

      sDeviceCheckDisabled = YES;
      sEffectiveMode = @"off";

      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL, storeChangedCallback,
        CFSTR("com.redditbox.storeChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        sDeviceCheckPrefRefresh,
        CFSTR("com.redditbox.prefsChanged"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

      RBXLog("AppAttest policy=%@ DeviceCheck policy=%@ container=%@",
             RBXAppAttestShouldBlock() ? @"blocked" : @"enabled",
             RBXDeviceCheckShouldBlock() ? @"blocked" : @"enabled", sContainerId);
    });
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallAppAttestHooks();
    }
}

@implementation RBXAppAttestHooks

+ (NSString *)effectiveMode {
    return RBXAppAttestShouldBlock() ? @"off" : @"on";
}

+ (NSInteger)attestKeyCount {
    NSString *path = @"/var/mobile/Library/Preferences/com.redditbox.store.json";
    NSDictionary *doc = [NSJSONSerialization JSONObjectWithData:
        RBXReadControlData(path) options:0 error:nil];
    if (!RBXSchemaValidate(doc, RBXDataStore, nil)) return 0;
    NSArray *used = doc[@"device"][@"attestKeysUsed"];
    return [used isKindOfClass:[NSArray class]] ? used.count : 0;
}

@end
