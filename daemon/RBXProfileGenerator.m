#import "RBXProfileGenerator.h"
#import "RBXAppRegistry.h"
#import "RBXDeviceCatalog.h"
#import "RBXMGOverrides.h"
#import "RBXProfileIO.h"
#import "RBXDataSchema.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <string.h>

// Generator. Core ideas:
//  - synthetic model/OS tuples from the catalog, independent of physical hardware
//  - iOS version, carrier sampled with diversity across existing containers
//  - all identifiers derived from the family tables (UDID prefix, screen, RAM, chip…)
//  - serials/MACs/UUIDs random but checked against every existing container (no reuse)
//  - geo-derived fields (timezone, locale, carrier, model region suffix, city) from proxy country
//  - profiles are generated ONLY at container creation; existing profiles are
//    never re-randomized, so every field is time-stable

static NSString *randomHex(NSInteger length) {
    static const char hex[] = "0123456789ABCDEF";
    NSMutableString *s = [NSMutableString stringWithCapacity:length];
    for (NSInteger i = 0; i < length; i++) {
        [s appendFormat:@"%c", hex[arc4random_uniform(16)]];
    }
    return s;
}

static NSString *randomDigits(NSInteger length) {
    NSMutableString *s = [NSMutableString stringWithCapacity:length];
    for (NSInteger i = 0; i < length; i++) {
        [s appendFormat:@"%c", (char)('0' + arc4random_uniform(10))];
    }
    return s;
}

static NSString *randomUUID(void) {
    return [[NSUUID UUID] UUIDString].uppercaseString;
}

static NSString *luhnComplete(NSString *first14) {
    // IMEI = 15 digits; check digit computed with doubling applied to even positions
    // counted from the RIGHT of the *complete* number (i.e. positions 14,12,10,...).
    // For the 14 known digits: double digits at indices 0,2,4,... (0-based from left).
    int sum = 0;
    for (NSInteger i = 0; i < (NSInteger)first14.length; i++) {
        int n = [first14 characterAtIndex:i] - '0';
        if (i % 2 == 1) { n *= 2; if (n > 9) n -= 9; }
        sum += n;
    }
    int check = (10 - (sum % 10)) % 10;
    return [first14 stringByAppendingFormat:@"%d", check];
}

static BOOL valueUsed(NSArray<NSDictionary *> *existing, NSString *key, NSString *value) {
    for (NSDictionary *p in existing) {
        id cur = p;
        for (NSString *part in [key componentsSeparatedByString:@"."]) {
            if (![cur isKindOfClass:[NSDictionary class]]) { cur = nil; break; }
            cur = ((NSDictionary *)cur)[part];
        }
        if ([cur isKindOfClass:[NSString class]] && [cur isEqualToString:value]) return YES;
    }
    return NO;
}

// B1 — real ProductType of the physical device. The daemon runs as root, so both
// sysctlbyname and (if linked) MGCopyAnswer would work; sysctl needs no extra
// framework, so it is the primary path. Returns nil if both fail.
static NSString *realProductType(void) {
    char buf[64] = {0};
    size_t len = sizeof(buf) - 1;
    if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0 && len > 0) {
        buf[MIN(len, sizeof(buf) - 1)] = '\0';
        NSString *pt = [[NSString alloc] initWithBytes:buf length:strnlen(buf, sizeof(buf)) encoding:NSUTF8StringEncoding];
        pt = [pt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (pt.length) return pt;
    }
    return nil;
}

@implementation RBXProfileGenerator

+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                          error:(NSError **)error {
    return [self generateProfileForContainerId:containerId proxyCountry:proxyCountry
        existingProfiles:existing productType:nil iosVersion:nil error:error];
}

+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                    productType:(NSString *)requestedProductType
                                     iosVersion:(NSString *)requestedIOSVersion
                                          error:(NSError **)error {
    return [self generateProfileForContainerId:containerId appType:@"reddit" proxyCountry:proxyCountry
        existingProfiles:existing productType:requestedProductType iosVersion:requestedIOSVersion error:error];
}

+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                        appType:(NSString *)appType
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                          error:(NSError **)error {
    return [self generateProfileForContainerId:containerId appType:appType proxyCountry:proxyCountry
        existingProfiles:existing productType:nil iosVersion:nil error:error];
}

+ (NSDictionary *)generateProfileForContainerId:(NSString *)containerId
                                        appType:(NSString *)appType
                                   proxyCountry:(NSString *)proxyCountry
                                existingProfiles:(NSArray<NSDictionary *> *)existing
                                    productType:(NSString *)requestedProductType
                                     iosVersion:(NSString *)requestedIOSVersion
                                          error:(NSError **)error {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:13
            userInfo:@{NSLocalizedDescriptionKey:@"Unknown app type; no identity was generated."}];
        return nil;
    }
    if (![RBXProfileIO isSafeContainerIdentifier:containerId] ||
        ![proxyCountry isKindOfClass:NSString.class] || !proxyCountry.length) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:10
            userInfo:@{NSLocalizedDescriptionKey: @"safe container identifier and proxy country required"}];
        return nil;
    }
    if (![RBXDeviceCatalog validateAvailability:error] ||
        ![RBXDeviceCatalog validateCountry:proxyCountry error:error]) return nil;
    if (![existing isKindOfClass:NSArray.class]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:12
            userInfo:@{NSLocalizedDescriptionKey: @"Existing profile identities could not be checked"}];
        return nil;
    }
    for (id previous in existing) {
        BOOL valid = [previous isKindOfClass:NSDictionary.class] && RBXAppDescriptorForProfile(previous) &&
            [previous[@"device"] isKindOfClass:NSDictionary.class] &&
            [previous[@"device"][@"productType"] isKindOfClass:NSString.class] &&
            [previous[@"serials"] isKindOfClass:NSDictionary.class] &&
            [previous[@"reddit"] isKindOfClass:NSDictionary.class];
        if (valid) for (NSString *key in @[@"serialNumber", @"udid", @"imei1", @"wifiMac", @"btMac"])
            if (![previous[@"serials"][key] isKindOfClass:NSString.class]) valid = NO;
        if (valid) for (NSString *key in @[@"installId", @"externalInstallationId"])
            if (![previous[@"reddit"][key] isKindOfClass:NSString.class]) valid = NO;
        if (!valid) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:12
                userInfo:@{NSLocalizedDescriptionKey: @"An existing profile has malformed identity fields; repair it before generating another"}];
            return nil;
        }
    }

    // Synthetic catalog identity; physical hardware is diagnostic context only.
    NSDictionary *catalogModels = [RBXDeviceCatalog allModels];
    NSArray *productTypes = catalogModels.allKeys;
    if (requestedProductType != nil) {
        if (![requestedProductType isKindOfClass:NSString.class] || !catalogModels[requestedProductType]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity" code:422
                userInfo:@{NSLocalizedDescriptionKey:@"Unknown device type"}];
            return nil;
        }
        productTypes = @[requestedProductType];
    }
    if (productTypes.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:11
                                             userInfo:@{NSLocalizedDescriptionKey: @"catalog empty"}];
        return nil;
    }

    NSLog(@"redditboxd: generating synthetic catalog identity (host %@)", realProductType() ?: @"unknown");
    NSString *productType = nil;
    {
        // Weighted diversity spread across catalog families
        NSMutableDictionary<NSString *, NSNumber *> *useCount = [NSMutableDictionary dictionary];
        for (NSString *pt in productTypes) useCount[pt] = @0;
        for (NSDictionary *p in existing) {
            NSString *pt = p[@"device"][@"productType"];
            if (pt && useCount[pt]) useCount[pt] = @([useCount[pt] integerValue] + 1);
        }
        NSInteger minCount = NSIntegerMax;
        for (NSString *pt in productTypes) {
            minCount = MIN(minCount, [useCount[pt] integerValue]);
        }
        NSMutableArray *candidates = [NSMutableArray array];
        for (NSString *pt in productTypes) {
            if ([useCount[pt] integerValue] <= minCount + 1) [candidates addObject:pt];
        }
        productType = candidates[arc4random_uniform((u_int32_t)candidates.count)];
    }
    NSDictionary *model = catalogModels[productType];

    // Select the OS/build/kernel tuple offered for the synthetic model.
    NSArray *supportedVersions = model[@"iosVersions"];
    if (![supportedVersions isKindOfClass:[NSArray class]] || !supportedVersions.count) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"model has no supported synthetic OS"}];
        return nil;
    }
    if (requestedIOSVersion != nil && (![requestedIOSVersion isKindOfClass:NSString.class] ||
        ![supportedVersions containsObject:requestedIOSVersion])) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity" code:422
            userInfo:@{NSLocalizedDescriptionKey:@"Selected iOS version is not supported by the synthetic model"}];
        return nil;
    }
    NSString *iosVersion = requestedIOSVersion ?: supportedVersions[arc4random_uniform((uint32_t)supportedVersions.count)];
    NSString *buildVersion = [RBXDeviceCatalog buildForIOS:iosVersion];
    NSString *darwinRelease = [RBXDeviceCatalog darwinForIOS:iosVersion];
    if (!buildVersion.length || !darwinRelease.length) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Catalog model has no complete synthetic OS tuple"}];
        return nil;
    }

    // 3) geo-derived fields
    NSArray<NSDictionary *> *carriers = [RBXDeviceCatalog carriersForCountry:proxyCountry];
    NSString *regionSuffix = [RBXDeviceCatalog regionSuffixForCountry:proxyCountry];

    // C3 — GPS city from the proxy country (lat/lon stay strings in the profile;
    // CLLocation gets doubles at hook time). A missing pool is an error.
    NSArray<NSDictionary *> *cities = [RBXDeviceCatalog citiesForCountry:proxyCountry];
    NSArray *ouiList = [RBXDeviceCatalog appleOUIs].allKeys;
    if (!carriers.count || !cities.count || !ouiList.count || !regionSuffix.length) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Catalog identity pools are incomplete"}];
        return nil;
    }
    NSDictionary *carrier = carriers[arc4random_uniform((u_int32_t)carriers.count)];
    NSDictionary *city = cities[arc4random_uniform((u_int32_t)cities.count)];
    double cityLat = [city[@"lat"] doubleValue];
    double cityLon = [city[@"lon"] doubleValue];
    double latJitter = ((NSInteger)arc4random_uniform(6001) - 3000) / 100000.0;
    double lonJitter = ((NSInteger)arc4random_uniform(6001) - 3000) / 100000.0;

    // Language follows the geo locale (proxy DE -> de) so locale/preferredLanguages
    // stay consistent with the timezone/city.
    NSString *geoLocale = [RBXDeviceCatalog localeForCountry:proxyCountry];
    NSString *geoTimezone = city[@"timezone"];
    NSString *language = [geoLocale componentsSeparatedByString:@"_"].firstObject ?: @"en";

    // 4) identifiers with no-reuse guarantees
    NSString *serial = nil;
    do { serial = [randomDigits(2) stringByAppendingString:randomHex(8)]; } while (valueUsed(existing, @"serials.serialNumber", serial));

    NSString *boardPrefix = model[@"boardUdidPrefix"];
    if (!boardPrefix.length) boardPrefix = randomHex(8); // Synthetic format, not an asserted Apple prefix.
    NSString *udid = nil;
    do { udid = [NSString stringWithFormat:@"%@-%@", boardPrefix, randomHex(16)]; } while (valueUsed(existing, @"serials.udid", udid));

    NSString *imei = @"";
    NSString *tac = model[@"tac"];
    if (tac.length == 8) {
        do { imei = luhnComplete([tac stringByAppendingString:randomDigits(6)]); } while (valueUsed(existing, @"serials.imei1", imei));
    }

    NSString *wifiMac = nil;
    do {
        NSString *oui = ouiList[arc4random_uniform((u_int32_t)ouiList.count)];
        wifiMac = [NSString stringWithFormat:@"%@:%@:%@:%@",
                   oui, randomHex(2), randomHex(2), randomHex(2)];
    } while (valueUsed(existing, @"serials.wifiMac", wifiMac));

    // separate sample for BT MAC (same Apple OUI family is fine and realistic)
    NSString *btMac = nil;
    do {
        NSString *oui = ouiList[arc4random_uniform((u_int32_t)ouiList.count)];
        btMac = [NSString stringWithFormat:@"%@:%@:%@:%@",
                 oui, randomHex(2), randomHex(2), randomHex(2)];
    } while (valueUsed(existing, @"serials.btMac", btMac) || [btMac isEqualToString:wifiMac]);

    // 5) IDs with per-container, per-posture IDFA (A5/A6):
    //    random  -> stable per-container UUID, ATT authorized
    //    zero    -> all-zeros UUID, ATT denied (matches a real user who hit
    //               "Ask App not to Track": ASIdentifierManager then answers zero)
    NSString *idfaPosture = arc4random_uniform(2) ? @"zeroWithATTDenied" : @"random";
    NSString *idfa = [idfaPosture isEqualToString:@"zeroWithATTDenied"]
                     ? @"00000000-0000-0000-0000-000000000000"
                     : randomUUID();

    // Legacy schema compatibility only for non-Reddit drafts. These values do
    // not represent or cover Facebook/Meta persisted installation identifiers.
    NSString *redditInstallId = nil;
    do { redditInstallId = randomUUID(); } while (valueUsed(existing, @"reddit.installId", redditInstallId));
    NSString *redditExternalId = nil;
    do { redditExternalId = randomUUID(); } while (valueUsed(existing, @"reddit.externalInstallationId", redditExternalId)
                                                    || [redditExternalId isEqualToString:redditInstallId]);

    // Install time is older than "now" so 50 containers created tonight don't
    // share one timestamp. Stable once written.
    NSTimeInterval ageDays = 7.0 + (NSTimeInterval)arc4random_uniform(173);
    NSTimeInterval ageSecs = ageDays * 86400.0 + (NSTimeInterval)arc4random_uniform(86400);
    long long installTsMs = (long long)(([[NSDate date] timeIntervalSince1970] - ageSecs) * 1000.0);

    NSDictionary *screen = [model[@"screen"] isKindOfClass:[NSDictionary class]] ? model[@"screen"] : @{};
    NSInteger screenW = [screen[@"w"] integerValue];
    NSInteger screenH = [screen[@"h"] integerValue];
    NSArray<NSString *> *fontSizes = @[@"16", @"17", @"19"];
    NSString *fontSize = fontSizes[arc4random_uniform((u_int32_t)fontSizes.count)];
    uint32_t syntheticUptime = 3600 +
        arc4random_uniform(60 * 60 * 24 * 14 - 3600);

    NSMutableDictionary *profile = [@{
        @"profileVersion": @(RBX_PROFILE_SCHEMA_VERSION),
        @"identityPolicy": @"synthetic-catalog-v1",
        @"containerId": containerId,
        @"identityCustomization": @{
            @"mode": @"random",
            @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        },
        @"device": @{
            @"productType": productType,
            @"marketingName": model[@"marketingName"] ?: @"iPhone",
            @"modelNumber": [model[@"modelBase"] length] ? [model[@"modelBase"] stringByAppendingString:regionSuffix] : @"",
            @"hwModelStr": model[@"hwModelStr"] ?: @"",
            @"regulatoryModel": model[@"regulatoryModel"] ?: @"",
            @"iosVersion": iosVersion,
            @"buildVersion": buildVersion ?: @"",
            @"darwinRelease": darwinRelease ?: @"",
            @"ramBytes": model[@"ramBytes"] ?: @"",
            @"gpuName": [NSString stringWithFormat:@"Apple %@ GPU", model[@"chip"] ?: @"GPU"],
            @"deviceName": @"iPhone",   // TODO: human-plausible name pool per language
            @"deviceClass": @"iPhone",
            @"regionCode": proxyCountry,
            @"simStatus": @"kCTSIMSupportSIMStatusReady",
            @"screen": model[@"screen"] ?: @{},
            @"language": language,
            @"locale": geoLocale,
            @"timezone": geoTimezone,
            @"carrier": carrier,
            @"location": @{
                @"city": city[@"city"] ?: @"",
                @"lat": city.count ? [NSString stringWithFormat:@"%.5f", cityLat + latJitter] : @"0",
                @"lon": city.count ? [NSString stringWithFormat:@"%.5f", cityLon + lonJitter] : @"0",
            },
        },
        @"serials": @{
            @"serialNumber": serial,
            @"udid": udid,
            @"imei1": imei,
            @"wifiMac": wifiMac,
            @"btMac": btMac,
            @"platformUUID": randomUUID(),
            @"mlb": [randomHex(4) stringByAppendingString:randomDigits(1)],
            @"uniqueChipId": @(((unsigned long long)arc4random() << 32) | arc4random()),
        },
        @"ids": @{
            @"posture": idfaPosture,
            @"idfa": idfa,
            @"idfv": randomUUID(),
        },
        @"timing": @{
            // Hook-consumed numerics are strings: RBXProfile valueForPath: only
            // resolves NSString values.
            @"bootTimeOffsetSeconds": [NSString stringWithFormat:@"%u",
                syntheticUptime], // migration/diagnostic compatibility
            @"syntheticBootEpoch": [NSString stringWithFormat:@"%.0f",
                NSDate.date.timeIntervalSince1970 - syntheticUptime],
            // B5 — stable per-container battery offset (-8...+8): 50 accounts with
            // a perfectly synchronized battery level is a soft cross-link
            @"batteryOffsetPercent": [NSString stringWithFormat:@"%ld", (long)((NSInteger)arc4random_uniform(17) - 8)],
        },
        @"security": @{
            @"appAttest": @"blocked",
            @"deviceCheck": @"blocked",
            @"localNetworking": @"blocked",
            @"sensorAccess": @"blocked",
            @"networkMetadata": @"blocked",
            @"thirdPartyNetwork": @"blocked",
            @"strictTiming": @"enabled",
            @"systemClipboard": @"blocked",
        },
        @"proxy": @{
            @"url": @"",   // assigned by proxy manager at activation
            @"country": proxyCountry,
        },
        @"reddit": @{
            @"installId": redditInstallId,
            @"installTimestampMs": [NSString stringWithFormat:@"%lld", installTsMs],
            @"deviceName": [NSString stringWithFormat:@"Apple;%@", productType],
            @"externalInstallationId": redditExternalId,
            @"screenWidth": screenW > 0 ? [NSString stringWithFormat:@"%ld", (long)screenW] : @"",
            @"screenHeight": screenH > 0 ? [NSString stringWithFormat:@"%ld", (long)screenH] : @"",
            @"fontSize": fontSize,
        },
        @"validation": @{
            @"proxyCountry": proxyCountry,
            @"geoConsistent": @YES,
        },
    } mutableCopy];
    if (![descriptor[@"appType"] isEqual:@"reddit"]) profile[@"appType"] = descriptor[@"appType"];
    profile[@"mgOverrides"] = RBXBuildMGOverrides(profile);
    return profile;
}

+ (NSDictionary *)autofixProfile:(NSDictionary *)profile proxyCountry:(NSString *)country {
    if (![profile isKindOfClass:NSDictionary.class] ||
        ![profile[@"device"] isKindOfClass:NSDictionary.class] ||
        ![RBXDeviceCatalog validateCountry:country error:nil]) return nil;
    NSMutableDictionary *p = [profile mutableCopy];
    NSMutableDictionary *device = [(p[@"device"] ?: @{}) mutableCopy];
    device[@"timezone"] = [RBXDeviceCatalog timezoneForCountry:country];
    NSString *locale = [RBXDeviceCatalog localeForCountry:country];
    device[@"locale"] = locale;
    if (locale.length) device[@"language"] = [locale componentsSeparatedByString:@"_"].firstObject;
    // Re-pin the GPS city so location follows the corrected geo too.
    NSArray<NSDictionary *> *cities = [RBXDeviceCatalog citiesForCountry:country];
    if (cities.count) {
        NSDictionary *city = cities[arc4random_uniform((u_int32_t)cities.count)];
        device[@"timezone"] = city[@"timezone"];
        double latJitter = ((NSInteger)arc4random_uniform(6001) - 3000) / 100000.0;
        double lonJitter = ((NSInteger)arc4random_uniform(6001) - 3000) / 100000.0;
        device[@"location"] = @{
            @"city": city[@"city"] ?: @"",
            @"lat": [NSString stringWithFormat:@"%.5f",
                     [city[@"lat"] doubleValue] + latJitter],
            @"lon": [NSString stringWithFormat:@"%.5f",
                     [city[@"lon"] doubleValue] + lonJitter],
        };
    }
    p[@"device"] = device;
    return p;
}

@end
