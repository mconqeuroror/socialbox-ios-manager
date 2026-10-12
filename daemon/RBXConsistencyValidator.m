#import "RBXConsistencyValidator.h"
#import "RBXDeviceCatalog.h"
#import "RBXMGOverrides.h"
#import "RBXKeychainSyncPolicy.h"
#import <Foundation/Foundation.h>
#import <sys/sysctl.h>

// Every hard rule from PLAN.md §13.1. Fails closed: anything nonsensical blocks launch.

static NSString *pathIn(NSDictionary *d, NSString *p) {
    NSArray *parts = [p componentsSeparatedByString:@"."];
    id cur = d;
    for (NSString *part in parts) {
        if (![cur isKindOfClass:[NSDictionary class]]) return nil;
        cur = cur[part];
    }
    return [cur isKindOfClass:[NSString class]] ? cur : nil;
}

static BOOL luhn(NSString *digits) {
    // IMEI check: the LAST digit is the check digit and is NOT doubled; doubling
    // starts at the second-to-last digit and moves left.
    if (!digits || digits.length < 2) return NO;
    int sum = 0;
    BOOL alt = NO;
    for (NSInteger i = digits.length - 1; i >= 0; i--) {
        unichar c = [digits characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
        int n = c - '0';
        if (alt) { n *= 2; if (n > 9) n -= 9; }
        sum += n;
        alt = !alt;
    }
    return (sum % 10) == 0;
}

static BOOL isValidUUID(NSString *s) {
    return s && [[NSUUID alloc] initWithUUIDString:s] != nil;
}

@implementation RBXConsistencyValidator

+ (NSDictionary *)validatedProfile:(NSDictionary *)profile error:(NSError **)error {
    if (![profile isKindOfClass:NSDictionary.class]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox" code:100
            userInfo:@{NSLocalizedDescriptionKey: @"Profile root is not a dictionary"}];
        return nil;
    }
    if (![RBXDeviceCatalog validateAvailability:error]) return nil;
    NSMutableArray *problems = [NSMutableArray array];

    NSString *productType = pathIn(profile, @"device.productType");
    NSString *iosVersion = pathIn(profile, @"device.iosVersion");
    NSString *buildVersion = pathIn(profile, @"device.buildVersion");
    NSString *serial = pathIn(profile, @"serials.serialNumber");
    NSString *udid = pathIn(profile, @"serials.udid");
    NSString *imei = pathIn(profile, @"serials.imei1");
    NSString *idfa = pathIn(profile, @"ids.idfa");
    NSString *idfv = pathIn(profile, @"ids.idfv");
    NSString *wifiMac = pathIn(profile, @"serials.wifiMac");
    NSString *btMac = pathIn(profile, @"serials.btMac");
    NSString *mcc = pathIn(profile, @"device.carrier.mcc");
    NSString *mnc = pathIn(profile, @"device.carrier.mnc");
    NSString *carrier = pathIn(profile, @"device.carrier.name");
    NSString *tz = pathIn(profile, @"device.timezone");
    NSString *locale = pathIn(profile, @"device.locale");
    NSString *proxyCountry = pathIn(profile, @"validation.proxyCountry");
    if (![RBXDeviceCatalog validateCountry:proxyCountry error:error]) return nil;

    NSDictionary<NSString *, NSString *> *required = @{
        @"containerId": @"container id",
        @"device.productType": @"product type",
        @"device.iosVersion": @"iOS version",
        @"device.buildVersion": @"build version",
        @"device.locale": @"locale",
        @"device.language": @"language",
        @"device.timezone": @"timezone",
        @"device.regionCode": @"region code",
        @"device.gpuName": @"GPU name",
        @"device.location.city": @"location city",
        @"device.location.lat": @"location latitude",
        @"device.location.lon": @"location longitude",
        @"serials.udid": @"UDID",
        @"serials.serialNumber": @"serial",
        @"serials.wifiMac": @"Wi-Fi MAC",
        @"serials.btMac": @"Bluetooth MAC",
        @"serials.platformUUID": @"platform UUID",
        @"ids.idfa": @"IDFA",
        @"ids.idfv": @"IDFV",
        @"timing.syntheticBootEpoch": @"synthetic boot epoch",
        @"reddit.installId": @"Reddit install id",
    };
    [required enumerateKeysAndObjectsUsingBlock:^(NSString *path, NSString *label, BOOL *stop) {
        if (![pathIn(profile, path) length]) {
            [problems addObject:[NSString stringWithFormat:@"missing %@", label]];
        }
    }];

    // --- model / hardware coherence (catalog tables) ---
    NSDictionary *model = [RBXDeviceCatalog modelForProductType:productType];
    if (!model) {
        [problems addObject:@"unknown ProductType"];
    } else {
        NSString *boardPrefix = model[@"boardUdidPrefix"];
        if (boardPrefix.length && udid && ![udid hasPrefix:boardPrefix]) {
            [problems addObject:@"UDID prefix does not match model"];
        }
        NSString *expectedRam = model[@"ramBytes"];
        if (expectedRam && ![pathIn(profile, @"device.ramBytes") isEqualToString:expectedRam]) {
            [problems addObject:@"RAM does not match model"];
        }
        if ([model[@"hwModelStr"] length] &&
            ![pathIn(profile, @"device.hwModelStr") isEqualToString:model[@"hwModelStr"]]) {
            [problems addObject:@"HWModelStr does not match model"];
        }
        if ([model[@"regulatoryModel"] length] &&
            ![pathIn(profile, @"device.regulatoryModel") isEqualToString:model[@"regulatoryModel"]]) {
            [problems addObject:@"regulatory model does not match product type"];
        }
        NSDictionary *screen = model[@"screen"];
        if (screen) {
            if (![pathIn(profile, @"device.screen.w") isEqualToString:screen[@"w"]] ||
                ![pathIn(profile, @"device.screen.h") isEqualToString:screen[@"h"]] ||
                ![pathIn(profile, @"device.screen.fps") isEqualToString:screen[@"fps"]] ||
                ![pathIn(profile, @"device.screen.scale") isEqualToString:screen[@"scale"]]) {
                [problems addObject:@"screen metrics do not match model"];
            }
        }
        NSArray *allowedVersions = model[@"iosVersions"];
        if (allowedVersions && iosVersion && ![allowedVersions containsObject:iosVersion]) {
            [problems addObject:@"iOS version not offered for model"];
        }
        NSString *tac = model[@"tac"];
        if (tac.length == 8 && imei.length &&
            ![imei hasPrefix:tac]) {
            [problems addObject:@"IMEI TAC does not match model"];
        }
    }

    // --- build consistency ---
    if (iosVersion && buildVersion) {
        NSString *expectedBuild = [RBXDeviceCatalog buildForIOS:iosVersion];
        if (!expectedBuild || ![buildVersion isEqualToString:expectedBuild]) {
            [problems addObject:@"build number does not match iOS version"];
        }
    }

    if (![[RBXDeviceCatalog darwinForIOS:iosVersion] isEqualToString:pathIn(profile, @"device.darwinRelease")]) {
        [problems addObject:@"Darwin release does not match synthetic iOS version"];
    }
    if (model && ![pathIn(profile, @"device.gpuName") isEqualToString:
        [NSString stringWithFormat:@"Apple %@ GPU", model[@"chip"] ?: @""]]) {
        [problems addObject:@"GPU name does not match synthetic model"];
    }

    // --- identifiers ---
    if (udid && [udid rangeOfString:@"^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{16}$"
        options:NSRegularExpressionSearch].location == NSNotFound) [problems addObject:@"UDID must be 8 hexadecimal characters, a dash, then 16 hexadecimal characters"];
    if (serial && serial.length != 10) [problems addObject:@"serial not 10 chars"];
    if (serial && [serial rangeOfString:@"^[A-Z0-9]{10}$"
        options:NSRegularExpressionSearch].location == NSNotFound) {
        [problems addObject:@"serial has invalid characters"];
    }
    BOOL omittedGenericIMEI = [model[@"identifierTemplate"] isEqual:@"generic-synthetic"] && !imei.length;
    if (!omittedGenericIMEI && !luhn(imei)) [problems addObject:@"IMEI fails Luhn"];
    if (idfa && !isValidUUID(idfa)) [problems addObject:@"IDFA not a UUID"];
    if (idfv && !isValidUUID(idfv)) [problems addObject:@"IDFV not a UUID"];
    NSString *posture = pathIn(profile, @"ids.posture");
    if ([posture isEqualToString:@"zeroWithATTDenied"]) {
        if (![idfa isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
            [problems addObject:@"denied ATT posture must use zero IDFA"];
        }
    } else if (![posture isEqualToString:@"random"]) {
        [problems addObject:@"unknown IDFA posture"];
    } else if ([idfa isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        [problems addObject:@"random IDFA posture cannot use zero IDFA"];
    }
    NSString *redditInstallId = pathIn(profile, @"reddit.installId");
    if (redditInstallId && !isValidUUID(redditInstallId)) {
        [problems addObject:@"reddit.installId not a UUID"];
    }
    if (![pathIn(profile, @"reddit.deviceName")
          isEqualToString:[NSString stringWithFormat:@"Apple;%@", productType ?: @""]]) {
        [problems addObject:@"Reddit device name does not match product type"];
    }
    if (![pathIn(profile, @"reddit.screenWidth")
          isEqualToString:pathIn(profile, @"device.screen.w")] ||
        ![pathIn(profile, @"reddit.screenHeight")
          isEqualToString:pathIn(profile, @"device.screen.h")]) {
        [problems addObject:@"Reddit screen metrics do not match device"];
    }
    if (wifiMac && ![RBXDeviceCatalog isAppleMAC:wifiMac]) {
        [problems addObject:@"WiFi MAC not in Apple OUI pool"];
    }
    if (btMac && ![RBXDeviceCatalog isAppleMAC:btMac]) {
        [problems addObject:@"Bluetooth MAC not in Apple OUI pool"];
    }
    if (wifiMac.length && [wifiMac isEqualToString:btMac]) {
        [problems addObject:@"WiFi and Bluetooth MAC addresses must differ"];
    }
    if (!isValidUUID(pathIn(profile, @"serials.platformUUID"))) {
        [problems addObject:@"platform UUID is invalid"];
    }
    if (!isValidUUID(pathIn(profile, @"reddit.externalInstallationId"))) {
        [problems addObject:@"Reddit external installation id is invalid"];
    }
    for (NSString *policyPath in @[
            @"security.appAttest", @"security.deviceCheck",
            @"security.localNetworking", @"security.sensorAccess",
            @"security.networkMetadata", @"security.thirdPartyNetwork",
            @"security.strictTiming"]) {
        NSString *policy = pathIn(profile, policyPath);
        if (!([policy isEqualToString:@"blocked"] || [policy isEqualToString:@"enabled"])) {
            [problems addObject:[NSString stringWithFormat:@"%@ policy is invalid", policyPath]];
        }
    }

    id clipboardPolicy = profile[@"security"][@"systemClipboard"];
    if (clipboardPolicy && ![@[@"blocked", @"enabled"] containsObject:clipboardPolicy])
        [problems addObject:@"security.systemClipboard policy is invalid"];
    if (!RBXKeychainSyncPolicyValid(profile[@"security"][@"keychainSync"]))
        [problems addObject:@"security.keychainSync must be unchanged or local-only"];
    NSDictionary *mg = RBXBuildMGOverrides(profile);
    NSDictionary *mgExpected = @{
        @"UniqueDeviceID": udid ?: @"",
        @"SerialNumber": serial ?: @"",
        @"WifiAddress": wifiMac ?: @"",
        @"BluetoothAddress": pathIn(profile, @"serials.btMac") ?: @"",
        @"IOPlatformUUID": pathIn(profile, @"serials.platformUUID") ?: @"",
        @"ProductType": productType ?: @"",
        @"HWModelStr": pathIn(profile, @"device.hwModelStr") ?: @"",
        @"ProductVersion": iosVersion ?: @"",
        @"BuildVersion": buildVersion ?: @"",
        @"RegionCode": pathIn(profile, @"device.regionCode") ?: @"",
        @"IDFA": idfa ?: @"",
        @"IDFV": idfv ?: @"",
    };
    [mgExpected enumerateKeysAndObjectsUsingBlock:
        ^(NSString *key, NSString *expected, BOOL *stop) {
        if (!expected.length || ![mg[key] isEqual:expected]) {
            [problems addObject:[NSString stringWithFormat:
                @"MobileGestalt %@ contradicts profile", key]];
        }
    }];

    // --- geo coherence ---
    if (proxyCountry) {
        NSString *regionCode = pathIn(profile, @"device.regionCode");
        NSString *language = pathIn(profile, @"device.language");
        if (![regionCode isEqualToString:proxyCountry]) {
            [problems addObject:@"region code does not match proxy country"];
        }
        if (language.length && locale.length && ![locale hasPrefix:language]) {
            [problems addObject:@"language does not match locale"];
        }
        NSString *tzCountry = [RBXDeviceCatalog countryForTimezone:tz];
        if (!tzCountry || ![tzCountry isEqualToString:proxyCountry]) {
            [problems addObject:@"timezone country does not match proxy country"];
        }
        NSString *localeCountry = [RBXDeviceCatalog countryForLocale:locale];
        if (!localeCountry || ![localeCountry isEqualToString:proxyCountry]) {
            [problems addObject:@"locale country does not match proxy country"];
        }
        if (mcc.length && mnc.length) {
            BOOL carrierOk = NO;
            for (NSDictionary *c in [RBXDeviceCatalog carriersForCountry:proxyCountry]) {
                if ([c isKindOfClass:[NSDictionary class]] &&
                    [[NSString stringWithFormat:@"%@", c[@"mcc"]] isEqualToString:mcc] &&
                    [[NSString stringWithFormat:@"%@", c[@"mnc"]] isEqualToString:mnc]) {
                    carrierOk = YES;
                    break;
                }
            }
            if (!carrierOk) {
                [problems addObject:@"carrier (mcc/mnc) not available in proxy country"];
            }
        }
        NSString *city = pathIn(profile, @"device.location.city");
        BOOL cityKnown = NO;
        for (NSDictionary *candidate in [RBXDeviceCatalog citiesForCountry:proxyCountry]) {
            if ([candidate[@"city"] isEqualToString:city]) {
                cityKnown = YES;
                break;
            }
        }
        if (!cityKnown) [problems addObject:@"location city does not match proxy country"];
    }

    if (problems.count > 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox" code:100
                                     userInfo:@{NSLocalizedDescriptionKey: [problems componentsJoinedByString:@"; "]}];
        }
        return nil;
    }
    return profile;
}

+ (NSArray<NSString *> *)warningsForProfile:(NSDictionary *)profile {
    NSError *catalogError = nil;
    if (![RBXDeviceCatalog validateAvailability:&catalogError])
        return @[catalogError.localizedDescription ?: @"Device catalog is unavailable"];
    NSMutableArray *warnings = [NSMutableArray array];
    if ([pathIn(profile, @"security.systemClipboard") isEqual:@"enabled"])
        [warnings addObject:@"System clipboard enabled: copied content and pasteboard metadata can link this profile to other apps/profiles. Disable after pasting credentials and clear the clipboard yourself."];
    // §13.2 — warning-level checks are heuristic; kept minimal here, extended with real
    // usage data. Language vs region, unusual carriers, ASN reputation.
    NSString *language = pathIn(profile, @"device.language");
    NSString *locale = pathIn(profile, @"device.locale");
    if (language && locale && ![locale hasPrefix:language]) {
        [warnings addObject:@"language does not match locale region"];
    }
    // C3 — the GPS city should be a known city of the proxy country (warning
    // only: an unknown city might just be a catalog that hasn't been updated).
    NSString *city = pathIn(profile, @"device.location.city");
    NSString *proxyCountry = pathIn(profile, @"validation.proxyCountry");
    if (city.length && proxyCountry.length) {
        BOOL known = NO;
        for (NSDictionary *c in [RBXDeviceCatalog citiesForCountry:proxyCountry]) {
            if ([c isKindOfClass:[NSDictionary class]] && [c[@"city"] isEqualToString:city]) {
                known = YES;
                break;
            }
        }
        if (!known) {
            [warnings addObject:[NSString stringWithFormat:
                @"location city %@ is not in the catalog for %@", city, proxyCountry]];
        }
    }
    return warnings;
}

@end
