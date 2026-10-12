#import "RBXProfile.h"
#import "RBXMGOverrides.h"

// Stable fallback when an older profile has no reddit.* section. New profiles
// get random values at generation time; this only keeps pre-existing containers
// from minting a fresh UUID every launch.
static NSString *RBXStableUUID(NSString *seed) {
    NSData *d = [seed dataUsingEncoding:NSUTF8StringEncoding];
    uint64_t h1 = 14695981039346656037ULL;
    uint64_t h2 = 1099511628211ULL;
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        h1 ^= b[i];
        h1 *= 1099511628211ULL;
        h2 ^= b[d.length - 1 - i];
        h2 *= 14695981039346656037ULL;
    }
    return [[NSString stringWithFormat:@"%08x-%04x-%04x-%04x-%012llx",
             (unsigned)(h1 >> 32),
             (unsigned)((h1 >> 16) & 0xffff),
             (unsigned)((h1 & 0x0fff) | 0x4000),
             (unsigned)(((h2 >> 48) & 0x3fff) | 0x8000),
             (unsigned long long)(h2 & 0xffffffffffffULL)] uppercaseString];
}

@implementation RBXDeviceProfile

// Flatten profile into a single key -> value map once, then answer from it.
// MG keys may appear in several places (root, device.*, serials.*, ids.*); the daemon
// generates a combined "mgOverrides" dictionary to keep lookup O(1) and exhaustive.

+ (NSString *)profilesDirectory {
    // Container profiles live in the jailbreak's prefs area, invisible to the app itself
    // (jailbreak hiding keeps this path out of the app's reach).
    return @"/var/mobile/Library/Preferences/com.redditbox.profiles";
}

- (instancetype)initWithDictionary:(NSDictionary *)dict error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    if (![dict isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"profile is not a dictionary"}];
        return nil;
    }
    _rawProfile = dict;
    _containerId = dict[@"containerId"];

    if (!_containerId || ![_containerId isKindOfClass:[NSString class]]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"profile missing containerId"}];
        return nil;
    }
    return self;
}

- (NSDictionary *)overrides {
    // Build from nested fields as a fail-safe for legacy/imported profiles. Explicit
    // unknown mgOverrides are retained; canonical nested identity fields win.
    return RBXBuildMGOverrides(_rawProfile);
}

- (id)mgAnswer:(NSString *)key {
    id value = [self overrides][key];
    if ([key isEqualToString:@"UniqueDeviceIDData"] ||
        [key isEqualToString:@"WifiAddressData"] ||
        [key isEqualToString:@"BluetoothAddressData"]) {
        if ([value isKindOfClass:[NSData class]]) return value;
        NSString *source = nil;
        if ([key isEqualToString:@"UniqueDeviceIDData"])
            source = [self valueForPath:@"serials.udid"];
        else if ([key isEqualToString:@"WifiAddressData"])
            source = [self valueForPath:@"serials.wifiMac"];
        else
            source = [self valueForPath:@"serials.btMac"];
        NSString *hex = [[[source stringByReplacingOccurrencesOfString:@"-" withString:@""]
                          stringByReplacingOccurrencesOfString:@":" withString:@""]
                         uppercaseString];
        if (hex.length % 2 != 0) return nil;
        NSMutableData *data = [NSMutableData dataWithCapacity:hex.length / 2];
        for (NSUInteger index = 0; index < hex.length; index += 2) {
            unsigned int byte = 0;
            NSScanner *scanner = [NSScanner scannerWithString:
                [hex substringWithRange:NSMakeRange(index, 2)]];
            if (![scanner scanHexInt:&byte]) return nil;
            uint8_t valueByte = (uint8_t)byte;
            [data appendBytes:&valueByte length:1];
        }
        return data;
    }
    return value;
}

- (NSString *)valueForPath:(NSString *)dotPath {
    if (!dotPath) return nil;
    NSArray *parts = [dotPath componentsSeparatedByString:@"."];
    NSDictionary *cur = _rawProfile;
    for (NSString *part in parts) {
        if (![cur isKindOfClass:[NSDictionary class]]) return nil;
        cur = cur[part];
    }
    if ([cur isKindOfClass:[NSString class]]) return (NSString *)cur;
    if ([cur isKindOfClass:[NSNumber class]]) return [(NSNumber *)cur stringValue];
    return nil;
}

- (NSString *)udid {
    // Prefer full override; fall back to serials section (schema mirrors profiles/schema.json)
    return [self mgAnswer:@"UniqueDeviceID"] ?: [self valueForPath:@"serials.udid"];
}
- (NSString *)serialNumber {
    return [self mgAnswer:@"SerialNumber"] ?: [self valueForPath:@"serials.serialNumber"];
}
- (NSString *)wifiMac {
    return [self mgAnswer:@"WifiAddress"] ?: [self valueForPath:@"serials.wifiMac"];
}
- (NSString *)btMac {
    return [self mgAnswer:@"BluetoothAddress"] ?: [self valueForPath:@"serials.btMac"];
}
- (NSString *)imei1 {
    return [self mgAnswer:@"InternationalMobileEquipmentIdentity"] ?: [self valueForPath:@"serials.imei1"];
}
- (NSString *)productType {
    return [self mgAnswer:@"ProductType"] ?: [self valueForPath:@"device.productType"];
}
- (NSString *)iosVersion {
    return [self mgAnswer:@"ProductVersion"] ?: [self valueForPath:@"device.iosVersion"];
}
- (NSString *)deviceName {
    return [self mgAnswer:@"DeviceName"] ?: [self valueForPath:@"device.deviceName"];
}
- (NSString *)idfa {
    return [self mgAnswer:@"IDFA"] ?: [self valueForPath:@"ids.idfa"];
}
- (NSString *)idfv {
    return [self mgAnswer:@"IDFV"] ?: [self valueForPath:@"ids.idfv"];
}
- (NSString *)redditInstallId {
    NSString *v = [self valueForPath:@"reddit.installId"];
    if (v.length) return v;
    return RBXStableUUID([NSString stringWithFormat:@"install:%@", _containerId ?: @""]);
}
- (NSString *)redditInstallTimestampMs {
    NSString *v = [self valueForPath:@"reddit.installTimestampMs"];
    if (v.length) return v;
    NSString *uuid = [self redditInstallId];
    uint64_t h = 14695981039346656037ULL;
    const char *c = uuid.UTF8String ?: "";
    while (*c) { h ^= (uint8_t)*c++; h *= 1099511628211ULL; }
    // Stable epoch in 2023–2024 so old containers don't all share "now".
    uint64_t ms = 1672531200000ULL + (h % (86400000ULL * 400ULL));
    return [NSString stringWithFormat:@"%llu", (unsigned long long)ms];
}
- (NSString *)redditDeviceName {
    NSString *v = [self valueForPath:@"reddit.deviceName"];
    if (v.length) return v;
    NSString *pt = self.productType;
    return pt.length ? [NSString stringWithFormat:@"Apple;%@", pt] : @"Apple;iPhone";
}
- (NSString *)redditUserAgent {
    return [self valueForPath:@"reddit.userAgent"];
}
- (NSString *)redditScreenWidth {
    NSString *v = [self valueForPath:@"reddit.screenWidth"];
    if (v.length) return v;
    return [self valueForPath:@"device.screen.w"];
}
- (NSString *)redditScreenHeight {
    NSString *v = [self valueForPath:@"reddit.screenHeight"];
    if (v.length) return v;
    return [self valueForPath:@"device.screen.h"];
}
- (NSString *)redditFontSize {
    NSString *v = [self valueForPath:@"reddit.fontSize"];
    return v.length ? v : @"17";
}
- (NSString *)redditExternalInstallationId {
    NSString *v = [self valueForPath:@"reddit.externalInstallationId"];
    if (v.length) return v;
    return RBXStableUUID([NSString stringWithFormat:@"ext-install:%@", _containerId ?: @""]);
}
- (NSString *)proxyURL {
    return [self valueForPath:@"proxy.url"];
}
- (NSString *)timezone {
    return [self valueForPath:@"device.timezone"];
}
- (NSString *)carrierName {
    return [self valueForPath:@"device.carrier.name"];
}
- (NSString *)mcc {
    return [self valueForPath:@"device.carrier.mcc"];
}
- (NSString *)mnc {
    return [self valueForPath:@"device.carrier.mnc"];
}

- (double)bootTimeOffsetSeconds {
    return [self valueForPath:@"timing.bootTimeOffsetSeconds"].doubleValue;
}

- (RBXIDFAPosture)idfaPosture {
    NSString *p = [self valueForPath:@"ids.posture"];
    if ([p isEqualToString:@"zeroWithATTDenied"]) return RBXIDFAPostureZeroWithATTDenied;
    return RBXIDFAPostureRandom;
}

- (BOOL)isGeoConsistent {
    return [self valueForPath:@"validation.geoConsistent"].boolValue;
}

@end
