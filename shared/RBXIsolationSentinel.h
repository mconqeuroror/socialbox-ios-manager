#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <math.h>
#include <errno.h>

// Observer policy is separate from identity, compatibility flags and gate state.
static inline NSDictionary *RBXSentinelSettings(id raw) {
    NSDictionary *off = @{@"enabled":@NO, @"intervalMinutes":@15, @"clipboardChallenge":@NO};
    if (!raw) return off;
    if (![raw isKindOfClass:NSDictionary.class] || [raw count] != 3) return nil;
    for (NSString *key in @[@"enabled", @"clipboardChallenge"])
        if (!raw[key] || CFGetTypeID((__bridge CFTypeRef)raw[key]) != CFBooleanGetTypeID()) return nil;
    id minutes = raw[@"intervalMinutes"];
    if (![minutes isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)minutes) == CFBooleanGetTypeID()) return nil;
    double n = [minutes doubleValue];
    return isfinite(n) && n >= 1 && n <= 1440 && floor(n) == n ? [raw copy] : nil;
}

static inline BOOL RBXSentinelFresh(id timestamp, NSTimeInterval now, NSTimeInterval age) {
    if (![timestamp isKindOfClass:NSNumber.class]) return NO;
    double t = [timestamp doubleValue];
    return isfinite(t) && isfinite(now) && t > 0 && t <= now && now - t <= age;
}

static inline NSDictionary *RBXSentinelRow(NSString *probe, NSString *target, NSString *status,
                                         NSString *detail, NSInteger code) {
    return @{@"probe":probe, @"target":target, @"status":status, @"detail":detail, @"code":@(code)};
}

// These callbacks are the real public API boundaries in the tweak and mocks in
// host tests. No original IMP, internal path override, raw syscall or entitlement
// bypass belongs here. A successful foreign read is a LEAK regardless of bytes.
typedef struct {
    OSStatus (^keychain)(NSDictionary *query);
    NSDictionary *(^attributes)(NSString *path, NSError **error);
    BOOL (^openReadOnly)(NSString *path, NSError **error);
    id (^defaults)(NSString *suite, NSString *key);
    BOOL (^clipboardHasContent)(void);
} RBXSentinelAPIs;

static inline NSString *RBXSentinelFileObservation(NSError *error) {
    if ([error.domain isEqual:NSPOSIXErrorDomain]) {
        if (error.code == ENOENT) return @"absent";
        if (error.code == EACCES || error.code == EPERM) return @"denied";
    }
    if ([error.domain isEqual:NSCocoaErrorDomain]) {
        if (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) return @"absent";
        if (error.code == NSFileReadNoPermissionError) return @"denied";
    }
    return @"unknown";
}

static inline BOOL RBXSentinelCloseReadHandle(NSFileHandle *handle) {
    if (!handle) return NO;
    // The public factory already opened the foreign path. Cleanup failure
    // cannot retract that positive observation or turn it into NOT_RUN.
    @try { [handle closeFile]; }
    @catch (__unused NSException *cleanupError) { }
    return YES;
}

static inline id RBXSentinelReadDefaults(NSUserDefaults *defaults, NSString *suite, NSString *key) {
    // Messaging a nil receiver would otherwise masquerade as a successful
    // absent-key observation. The caller classifies exceptions as NOT_RUN.
    if (!defaults) @throw [NSException exceptionWithName:@"RBXSentinelDefaultsUnavailable" reason:nil userInfo:nil];
    id value = nil;
    @try {
        [defaults addSuiteNamed:suite];
        value = [defaults objectForKey:key];
    } @finally {
        @try { [defaults removeSuiteNamed:suite]; }
        @catch (NSException *cleanupError) {
            // Always attempt cleanup, but preserve a successful foreign read.
            // Without a value, cleanup failure makes absence inconclusive.
            if (!value) @throw cleanupError;
        }
    }
    return value;
}

static inline NSDictionary *RBXSentinelClipboardChallenge(BOOL shared, BOOL available, BOOL visible) {
    if (shared) return RBXSentinelRow(@"pasteboard-challenge",@"system",@"NOT_RUN",
        @"Shared clipboard mode: marker write skipped to preserve user content.",0);
    return RBXSentinelRow(@"pasteboard-challenge",@"system",available && visible ? @"LEAK" : @"NOT_RUN",
        !available ? @"Optional pasteboard challenge was unavailable or raised an exception." :
        (visible ? @"Optional marker became visible despite blocked clipboard policy." :
            @"Own marker was not visible; write success and a sibling marker witness are unverified."),0);
}

static inline NSArray *RBXSentinelProbe(NSArray *targets, BOOL clipboardShared,
                                      NSTimeInterval now, RBXSentinelAPIs api) {
    NSMutableArray *rows = [NSMutableArray array];
    if (!targets.count) {
        for (NSString *probe in @[@"keychain-default", @"keychain-group", @"filesystem", @"defaults"])
            [rows addObject:RBXSentinelRow(probe, @"none", @"NOT_RUN", @"No verified sibling target is available.", 0)];
    }
    NSUInteger index = 0;
    for (NSDictionary *target in targets) {
        NSString *label = [NSString stringWithFormat:@"sibling-%lu", (unsigned long)++index];
        NSString *bundle = target[@"bundleIdentifier"], *nonce = target[@"nonce"];
        BOOL witnessed = RBXSentinelFresh(target[@"witnessAt"], now, 60) &&
            [target[@"expiresAt"] doubleValue] > now;
        for (NSString *probe in @[@"keychain-default", @"keychain-group"]) {
            if (!nonce.length || ![target[@"keychainSeeded"] isEqual:@YES]) {
                [rows addObject:RBXSentinelRow(probe,label,@"NOT_RUN",@"Prepare an SSH acceptance canary in the sibling first.",0)]; continue;
            }
            NSMutableDictionary *query = [@{
                (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService:@"com.redditbox.acceptance.canary.v1",
                (__bridge id)kSecAttrAccount:nonce,
                (__bridge id)kSecAttrSynchronizable:@NO,
                (__bridge id)kSecReturnAttributes:@YES,
                (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne,
                (__bridge id)kSecUseAuthenticationUI:(__bridge id)kSecUseAuthenticationUIFail
            } mutableCopy];
            if ([probe isEqual:@"keychain-group"])
                query[(__bridge id)kSecAttrAccessGroup] = [@"RBXCLONE00." stringByAppendingString:bundle];
            @try {
                OSStatus status = api.keychain(query);
                // The daemon freshly witnesses a file/defaults marker but only
                // re-reads a historical Keychain seed receipt. Not-found can
                // mean that the source item was deleted; it is not denial proof.
                BOOL denied = [probe isEqual:@"keychain-group"] && status == errSecMissingEntitlement;
                [rows addObject:RBXSentinelRow(probe,label,status == errSecSuccess ? @"LEAK" :
                    (denied && witnessed ? @"PASS" : @"NOT_RUN"),
                    status == errSecSuccess ? @"A sibling canary was readable. Review before opening network access." :
                    (denied && witnessed ? @"Security explicitly denied the requested sibling access group." :
                        (status == errSecItemNotFound ? @"Canary was absent; current source Keychain presence is not independently witnessed." :
                            @"No current seed witness or Security returned an inconclusive error.")),status)];
            } @catch (__unused NSException *e) {
                [rows addObject:RBXSentinelRow(probe,label,@"NOT_RUN",@"Security probe raised an exception.",0)];
            }
        }
        NSString *home = [@"/var/mobile/Containers/Data/Application" stringByAppendingPathComponent:target[@"dataUUID"]];
        NSString *path = nonce.length ? [home stringByAppendingPathComponent:[NSString stringWithFormat:
            @"Library/Application Support/RedditBox/acceptance/results/%@.sentinel",nonce]] : home;
        BOOL visible = NO, readable = NO;
        @try {
            NSError *statError = nil, *readError = nil;
            visible = api.attributes(home, &statError) != nil;
            readable = api.openReadOnly(path, &readError);
            NSString *statObservation = RBXSentinelFileObservation(statError);
            NSString *readObservation = RBXSentinelFileObservation(readError);
            BOOL negative = ![statObservation isEqual:@"unknown"] && ![readObservation isEqual:@"unknown"];
            [rows addObject:RBXSentinelRow(@"filesystem",label,visible || readable ? @"LEAK" :
                (negative && witnessed ? @"PASS" : @"NOT_RUN"), visible || readable ?
                @"Sibling storage metadata or a read handle was accessible. Review before opening network access." :
                (negative && witnessed ? [NSString stringWithFormat:@"Witnessed paths through Foundation: metadata %@; read handle %@.",statObservation,readObservation] :
                    @"No current path witness or filesystem error was inconclusive."),readError.code)];
        } @catch (__unused NSException *e) {
            // A later failed probe cannot retract visibility already observed.
            [rows addObject:RBXSentinelRow(@"filesystem",label,visible || readable ? @"LEAK" : @"NOT_RUN",
                visible || readable ? @"Sibling storage was accessible before a later filesystem exception." :
                    @"Filesystem probe raised an exception.",0)];
        }
        if (!nonce.length || ![target[@"defaultsSeeded"] isEqual:@YES]) {
            [rows addObject:RBXSentinelRow(@"defaults",label,@"NOT_RUN",@"No verified sibling defaults canary is available.",0)];
        } else @try {
            id value = api.defaults(bundle, [@"RBXAcceptanceCanary." stringByAppendingString:nonce]);
            [rows addObject:RBXSentinelRow(@"defaults",label,value ? @"LEAK" : (witnessed ? @"PASS" : @"NOT_RUN"),
                value ? @"A sibling suite canary was visible through addSuiteNamed." :
                (witnessed ? @"Known sibling suite canary was absent." : @"Sibling defaults witness expired."),0)];
        } @catch (__unused NSException *e) {
            [rows addObject:RBXSentinelRow(@"defaults",label,@"NOT_RUN",@"Defaults probe raised an exception.",0)];
        }
    }
    if (clipboardShared) {
        [rows addObject:RBXSentinelRow(@"pasteboard",@"system",@"NOT_RUN",@"Shared clipboard compatibility is enabled; clipboard isolation is not asserted.",0)];
    } else @try {
        BOOL visible = api.clipboardHasContent();
        [rows addObject:RBXSentinelRow(@"pasteboard",@"system",visible ? @"LEAK" : @"NOT_RUN",visible ?
            @"Clipboard data is visible despite the blocked clipboard policy." :
            @"No clipboard content was observed; no independent sibling marker witness establishes isolation.",0)];
    } @catch (__unused NSException *e) {
        [rows addObject:RBXSentinelRow(@"pasteboard",@"system",@"NOT_RUN",@"Pasteboard probe raised an exception.",0)];
    }
    return rows;
}

static inline BOOL RBXSentinelHasLeak(NSArray *rows) {
    for (NSDictionary *row in rows) if ([row[@"status"] isEqual:@"LEAK"]) return YES;
    return NO;
}

// Used by registration tests as well as production. OFF does not even allocate
// a dispatch source, observer, queue or probe thread.
static inline BOOL RBXSentinelRegister(NSDictionary *settings, BOOL ready, dispatch_block_t install) {
    if (!ready || ![RBXSentinelSettings(settings)[@"enabled"] isEqual:@YES]) return NO;
    install(); return YES;
}
