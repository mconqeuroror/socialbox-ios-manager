#import "RBXInstallPaths.h"
#import "RBXDeviceCatalog.h"
#import "RBXProfileIO.h"
#import <math.h>

static NSError *RBXCatalogError(NSString *field) {
    return [NSError errorWithDomain:@"com.redditbox.catalog" code:1
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"Device catalog is unavailable: %@ is missing, invalid, or inconsistent", field]}];
}

static BOOL RBXCatalogString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}

static BOOL RBXCatalogNumber(id value, double minimum, double maximum) {
    if (!RBXCatalogString(value)) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double number;
    return [scanner scanDouble:&number] && scanner.isAtEnd && isfinite(number) &&
        number >= minimum && number <= maximum;
}

static BOOL RBXCatalogStrings(NSDictionary *entry, NSArray<NSString *> *keys) {
    if (![entry isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in keys) if (!RBXCatalogString(entry[key])) return NO;
    return YES;
}

// Validate the complete known schema once. Do not silently filter malformed
// entries and leave a partial catalog that appears to describe a coherent tuple.
static NSDictionary *RBXValidateCatalog(NSDictionary *root, NSError **error) {
    NSArray *maps = @[@"models", @"iosBuilds", @"darwinReleases", @"regionSuffixes",
        @"appleOUIs", @"countryTimezones", @"countryLocales", @"timezoneCountry",
        @"localeCountry", @"carriers", @"countryCities"];
    for (NSString *name in maps) {
        id map = root[name];
        if (![map isKindOfClass:NSDictionary.class] || ![map count]) {
            if (error) *error = RBXCatalogError(name); return nil;
        }
        for (id key in map) {
            if (!RBXCatalogString(key)) { if (error) *error = RBXCatalogError(name); return nil; }
            if (![@[@"models", @"carriers", @"countryCities"] containsObject:name] && !RBXCatalogString(map[key])) {
                if (error) *error = RBXCatalogError([name stringByAppendingFormat:@".%@", key]); return nil;
            }
        }
    }
    for (NSString *product in root[@"models"]) {
        NSDictionary *model = root[@"models"][product];
        NSString *field = [@"models." stringByAppendingString:product];
        if (!RBXCatalogStrings(model, @[@"marketingName", @"hwModelStr",
            @"regulatoryModel", @"chip", @"ramBytes"]) ||
            !RBXCatalogNumber(model[@"ramBytes"], 1, 1e15)) {
            if (error) *error = RBXCatalogError(field); return nil;
        }
        // New hardware facts do not establish a retail SKU, assigned IMEI TAC
        // or a manufacturer UDID prefix. Generic templates explicitly omit them.
        BOOL generic = [model[@"identifierTemplate"] isEqual:@"generic-synthetic"];
        for (NSString *key in @[@"modelBase", @"boardUdidPrefix", @"tac"]) {
            id value = model[key];
            if (![value isKindOfClass:NSString.class] ||
                (generic ? [value length] != 0 : ![value length])) {
                if (error) *error = RBXCatalogError([field stringByAppendingFormat:@".%@", key]); return nil;
            }
        }
        NSDictionary *screen = model[@"screen"];
        if (!RBXCatalogStrings(screen, @[@"w", @"h", @"scale", @"fps"])) {
            if (error) *error = RBXCatalogError([field stringByAppendingString:@".screen"]); return nil;
        }
        for (NSString *key in @[@"w", @"h", @"scale", @"fps"]) {
            if (!RBXCatalogNumber(screen[key], 1, 10000)) {
                if (error) *error = RBXCatalogError([field stringByAppendingFormat:@".screen.%@", key]); return nil;
            }
        }
        id versions = model[@"iosVersions"];
        if (![versions isKindOfClass:NSArray.class] || ![versions count]) {
            if (error) *error = RBXCatalogError([field stringByAppendingString:@".iosVersions"]); return nil;
        }
        for (id version in versions) {
            if (!RBXCatalogString(version) || !root[@"iosBuilds"][version] || !root[@"darwinReleases"][version]) {
                if (error) *error = RBXCatalogError([field stringByAppendingString:@".iosVersions tuple"]); return nil;
            }
            if (model[@"minimumIOS"] && (!RBXCatalogString(model[@"minimumIOS"]) ||
                [version compare:model[@"minimumIOS"] options:NSNumericSearch] == NSOrderedAscending)) {
                if (error) *error = RBXCatalogError([field stringByAppendingString:@".minimumIOS"]); return nil;
            }
        }
    }
    for (NSString *prefix in root[@"appleOUIs"]) {
        if ([prefix rangeOfString:@"^[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2}$"
            options:NSRegularExpressionSearch].location == NSNotFound) {
            if (error) *error = RBXCatalogError(@"appleOUIs prefix"); return nil;
        }
    }
    for (NSString *name in @[@"carriers", @"countryCities"]) {
        for (NSString *country in root[name]) {
            id entries = root[name][country];
            NSString *field = [name stringByAppendingFormat:@".%@", country];
            if (![entries isKindOfClass:NSArray.class] || ![entries count]) {
                if (error) *error = RBXCatalogError(field); return nil;
            }
            for (id entry in entries) {
                if ([name isEqual:@"carriers"]) {
                    if (!RBXCatalogStrings(entry, @[@"name", @"mcc", @"mnc"])) {
                        if (error) *error = RBXCatalogError(field); return nil;
                    }
                } else if (!RBXCatalogStrings(entry, @[@"city", @"lat", @"lon", @"timezone"]) ||
                    ![root[@"timezoneCountry"][entry[@"timezone"]] isEqual:country] ||
                    !RBXCatalogNumber(entry[@"lat"], -90, 90) || !RBXCatalogNumber(entry[@"lon"], -180, 180)) {
                    if (error) *error = RBXCatalogError(field); return nil;
                }
            }
        }
    }
    return root;
}

static NSDictionary *RBXLoadCatalog(NSArray<NSString *> *paths, NSError **error) {
    NSError *failure = nil;
    for (NSString *path in paths) {
        failure = nil;
        NSDictionary *root = [RBXProfileIO readJSONDictionaryAtPath:path error:&failure];
        if (root) return RBXValidateCatalog(root, error);
        if (![failure.domain isEqual:RBXProfileIOErrorDomain] || failure.code != RBXProfileIOMissing) {
            if (error) *error = failure; return nil;
        }
    }
    if (error) *error = failure ?: RBXCatalogError(@"installation path");
    return nil;
}

#ifdef RBX_CATALOG_TESTING
// Native fixtures supply isolated files; production has no path override.
static NSArray<NSString *> *RBXCatalogTestPaths;
#endif

static NSDictionary *catalog(NSError **error) {
#ifdef RBX_CATALOG_TESTING
    return RBXLoadCatalog(RBXCatalogTestPaths, error);
#else
    static NSDictionary *cached;
    static NSError *failure;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *loadError = nil;
        cached = RBXLoadCatalog(@[RBXInstalledPath(@"/usr/share/redditbox/catalog.json")], &loadError);
        failure = loadError;
    });
    if (!cached && error) *error = failure;
    return cached;
#endif
}

static NSDictionary *dictionarySection(NSString *name) {
    id value = catalog(NULL)[name];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static id sectionValue(NSString *name, NSString *key, Class expected) {
    if (!RBXCatalogString(key)) return nil;
    id value = dictionarySection(name)[key];
    return [value isKindOfClass:expected] ? value : nil;
}

@implementation RBXDeviceCatalog

+ (BOOL)validateAvailability:(NSError **)error { return catalog(error) != nil; }

+ (BOOL)validateCountry:(NSString *)country error:(NSError **)error {
    NSDictionary *root = catalog(error);
    if (!root) return NO;
    if (!RBXCatalogString(country) || !root[@"regionSuffixes"][country] ||
        !root[@"countryTimezones"][country] || !root[@"countryLocales"][country] ||
        ![root[@"carriers"][country] count] || ![root[@"countryCities"][country] count] ||
        ![root[@"timezoneCountry"][root[@"countryTimezones"][country]] isEqual:country] ||
        ![root[@"localeCountry"][root[@"countryLocales"][country]] isEqual:country]) {
        if (error) *error = RBXCatalogError(@"requested country tuple"); return NO;
    }
    return YES;
}

+ (NSDictionary *)modelForProductType:(NSString *)productType { return sectionValue(@"models", productType, NSDictionary.class); }
+ (NSDictionary *)allModels { return dictionarySection(@"models") ?: @{}; }
+ (NSString *)buildForIOS:(NSString *)iosVersion { return sectionValue(@"iosBuilds", iosVersion, NSString.class); }
+ (NSString *)darwinForIOS:(NSString *)iosVersion { return sectionValue(@"darwinReleases", iosVersion, NSString.class); }
+ (NSString *)regionSuffixForCountry:(NSString *)country { return sectionValue(@"regionSuffixes", country, NSString.class); }
+ (NSDictionary *)appleOUIs { return dictionarySection(@"appleOUIs") ?: @{}; }
+ (NSString *)timezoneForCountry:(NSString *)country { return sectionValue(@"countryTimezones", country, NSString.class); }
+ (NSString *)localeForCountry:(NSString *)country { return sectionValue(@"countryLocales", country, NSString.class); }
+ (NSString *)countryForTimezone:(NSString *)timezone { return sectionValue(@"timezoneCountry", timezone, NSString.class); }
+ (NSString *)countryForLocale:(NSString *)locale { return sectionValue(@"localeCountry", locale, NSString.class); }
+ (NSArray<NSDictionary *> *)carriersForCountry:(NSString *)country { return sectionValue(@"carriers", country, NSArray.class) ?: @[]; }
+ (NSArray<NSDictionary *> *)citiesForCountry:(NSString *)country { return sectionValue(@"countryCities", country, NSArray.class) ?: @[]; }

+ (BOOL)isAppleMAC:(NSString *)mac {
    if (!RBXCatalogString(mac) || [mac rangeOfString:@"^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"
        options:NSRegularExpressionSearch].location == NSNotFound) return NO;
    return [self appleOUIs][[mac substringToIndex:8].uppercaseString] != nil;
}

@end
