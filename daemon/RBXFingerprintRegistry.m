#import "RBXFingerprintRegistry.h"
#import "RBXCentralStore.h"
#import "RBXProfileIO.h"
#import "RBXContainerRegistry.h"
#import <math.h>

// FNV-1a 64-bit (no external deps; CommonCrypto deliberately avoided).
// The generator (RBXProfileGenerator) keeps profiles diverse; this registry is
// the verification layer that catches a collision if it ever happens.

static NSString *RBXFNV1a64(NSString *input) {
    const char *bytes = input.UTF8String;
    if (!bytes) return @"0000000000000000";
    uint64_t hash = 0xcbf29ce484222325ULL;
    for (const char *p = bytes; *p; p++) {
        hash ^= (uint8_t)*p;
        hash *= 0x100000001b3ULL;
    }
    return [NSString stringWithFormat:@"%016llX", hash];
}

@implementation RBXFingerprintRegistry

+ (NSString *)hashString:(NSString *)input {
    return RBXFNV1a64(input ?: @"");
}

+ (NSString *)bundleHashForProfile:(NSDictionary *)profile observedUA:(NSString *)userAgent {
    if (![profile isKindOfClass:NSDictionary.class] ||
        ![profile[@"device"] isKindOfClass:NSDictionary.class] ||
        (userAgent && ![userAgent isKindOfClass:NSString.class])) return nil;
    NSDictionary *device = profile[@"device"];
    for (NSString *key in @[@"productType", @"locale", @"timezone"]) {
        if (![device[key] isKindOfClass:NSString.class] || ![device[key] length]) return nil;
    }
    NSDictionary *profileScreen = device[@"screen"];
    if (![profileScreen isKindOfClass:NSDictionary.class] || !profileScreen.count) return nil;
    for (NSString *key in @[@"w", @"h", @"scale", @"fps"]) {
        if (![profileScreen[key] isKindOfClass:NSString.class]) return nil;
        NSScanner *scanner = [NSScanner scannerWithString:profileScreen[key]];
        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value <= 0) return nil;
    }
    for (id key in profileScreen) {
        if (![key isKindOfClass:NSString.class] ||
            (![profileScreen[key] isKindOfClass:NSNumber.class] &&
             ![profileScreen[key] isKindOfClass:NSString.class])) return nil;
    }
    // Fields: userAgent|model|screen|locale|timezone, sorted then joined.
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (userAgent.length) [parts addObject:[NSString stringWithFormat:@"userAgent:%@", userAgent]];

    NSString *model = profile[@"device"][@"productType"];
    if (model.length) [parts addObject:[NSString stringWithFormat:@"model:%@", model]];

    NSDictionary *screen = profile[@"device"][@"screen"];
    if ([screen isKindOfClass:[NSDictionary class]]) {
        NSArray *sortedKeys = [screen.allKeys sortedArrayUsingSelector:@selector(compare:)];
        NSMutableString *s = [NSMutableString string];
        for (NSString *k in sortedKeys) {
            [s appendFormat:@"%@=%@;", k, screen[k]];
        }
        [parts addObject:[NSString stringWithFormat:@"screen:%@", s]];
    }

    NSString *locale = profile[@"device"][@"locale"];
    if (locale.length) [parts addObject:[NSString stringWithFormat:@"locale:%@", locale]];

    NSString *timezone = profile[@"device"][@"timezone"];
    if (timezone.length) [parts addObject:[NSString stringWithFormat:@"timezone:%@", timezone]];

    [parts sortUsingSelector:@selector(compare:)];
    return RBXFNV1a64([parts componentsJoinedByString:@"|"]);
}

- (void)refreshAndCheck {
    RBXCentralStore *store = [RBXCentralStore sharedStore];
    NSDictionary *doc = store.dictionary;
    NSDictionary *containers = doc[@"containers"];
    if (![containers isKindOfClass:[NSDictionary class]]) return;

    __block NSMutableDictionary<NSString *, NSString *> *hashes = [NSMutableDictionary dictionary];
    RBXContainerRegistry *registry = [RBXContainerRegistry new];

    // The deletion lookup reads the central store. Resolve it before entering
    // its serial write queue; a nested synchronous read traps at startup.
    NSMutableDictionary<NSString *, NSNumber *> *retirement = [NSMutableDictionary dictionary];
    for (NSString *containerId in containers) {
        if ([RBXProfileIO isSafeContainerIdentifier:containerId])
            retirement[containerId] = @([registry deletionStateForContainer:containerId] != nil);
    }

    [store update:^(NSMutableDictionary *d) {
        NSDictionary *conts = d[@"containers"];
        if (![conts isKindOfClass:[NSDictionary class]]) return;

        for (NSString *containerId in conts.allKeys) {
            if (![RBXProfileIO isSafeContainerIdentifier:containerId]) continue;
            NSDictionary *c = conts[containerId];
            if (![c isKindOfClass:[NSDictionary class]]) continue;

            NSError *profileError = nil;
            // New rows that appeared after inspection wait for the next scan.
            if (!retirement[containerId]) continue;
            BOOL retired = [retirement[containerId] boolValue] ||
                ([d[@"cloudRetiredContainers"] isKindOfClass:NSDictionary.class] &&
                 d[@"cloudRetiredContainers"][containerId] != nil);
            NSDictionary *profile = retired ? nil :
                [RBXProfileIO loadProfileForContainer:containerId error:&profileError];
            NSDictionary *existingFingerprint = [c[@"fingerprint"] isKindOfClass:NSDictionary.class]
                ? c[@"fingerprint"] : @{};
            NSString *ua = existingFingerprint[@"userAgent"];
            NSString *hash = [RBXFingerprintRegistry bundleHashForProfile:profile observedUA:ua];

            NSMutableDictionary *cont = [c mutableCopy];
            NSMutableDictionary *fp = [cont[@"fingerprint"] isKindOfClass:[NSDictionary class]] ?
                [cont[@"fingerprint"] mutableCopy] : [NSMutableDictionary dictionary];
            if (hash) {
                hashes[containerId] = hash;
                fp[@"bundleHash"] = hash;
                [fp removeObjectForKey:@"validationError"];
                fp[@"model"] = profile[@"device"][@"productType"] ?: @"";
                fp[@"locale"] = profile[@"device"][@"locale"] ?: @"";
                fp[@"timezone"] = profile[@"device"][@"timezone"] ?: @"";
            } else {
                // An unavailable identity is not an empty, colliding identity.
                [fp removeObjectForKey:@"bundleHash"];
                fp[@"validationError"] = retired ? @"Profile is reserved for deletion." :
                    (profileError.localizedDescription ?: @"Required fingerprint fields are missing or malformed.");
            }
            cont[@"fingerprint"] = fp;
            ((NSMutableDictionary *)conts)[containerId] = cont;
        }
    }];

    // Duplicate detection among LIVE containers.
    __block NSMutableArray<NSString *> *pairs = [NSMutableArray array];
    [store update:^(NSMutableDictionary *d) {
        NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byHash = [NSMutableDictionary dictionary];
        NSDictionary *conts = d[@"containers"];
        if (![conts isKindOfClass:[NSDictionary class]]) return;

        for (NSString *containerId in conts) {
            NSDictionary *c = conts[containerId];
            if (![c isKindOfClass:[NSDictionary class]]) continue;
            // LIVE = not dead, not paused
            NSString *reason = c[@"deathReason"];
            if ([reason isKindOfClass:[NSString class]] && reason.length > 0) continue;
            id paused = c[@"paused"];
            if (paused && (![paused isKindOfClass:NSNumber.class] || [paused boolValue])) continue;
            NSString *h = hashes[containerId];
            if (!h) continue;
            if (!byHash[h]) byHash[h] = [NSMutableArray array];
            [byHash[h] addObject:containerId];
        }

        NSMutableArray *alerts = [d[@"alerts"] isKindOfClass:[NSArray class]] ?
            [d[@"alerts"] mutableCopy] : [NSMutableArray array];
        for (NSString *h in byHash) {
            NSArray *ids = byHash[h];
            if (ids.count < 2) continue;
            NSArray *sorted = [ids sortedArrayUsingSelector:@selector(compare:)];
            NSString *pair = [sorted componentsJoinedByString:@"+"];
            if ([pairs containsObject:pair]) continue;
            [pairs addObject:pair];
            if ([self _hasAlert:alerts type:@"FINGERPRINT DUP" key:pair]) continue;
            [alerts addObject:@{
                @"type": @"FINGERPRINT DUP",
                @"containerId": sorted[0],
                @"message": [NSString stringWithFormat:
                    @"Containers %@ and %@ look like the same phone to Reddit (identical browser fingerprint). Tell the admin to regenerate one of them.", sorted[0], sorted[1]],
                @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
                @"key": pair,
            }];
        }
        if (alerts.count > 100) {
            [alerts removeObjectsInRange:NSMakeRange(0, alerts.count - 100)];
        }
        d[@"alerts"] = alerts;
    }];
}

- (BOOL)_hasAlert:(NSArray *)alerts type:(NSString *)type key:(NSString *)key {
    for (NSDictionary *a in alerts) {
        if ([a isKindOfClass:NSDictionary.class] &&
            [a[@"type"] isKindOfClass:NSString.class] &&
            [a[@"key"] isKindOfClass:NSString.class] &&
            [a[@"type"] isEqualToString:type] && [a[@"key"] isEqualToString:key]) return YES;
    }
    return NO;
}

@end
