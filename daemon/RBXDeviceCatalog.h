#import <Foundation/Foundation.h>

// On-device lookup tables: models, builds, carriers, timezones, locales, OUIs.
// Backed by profiles/catalog.json at this package variant's resolved install root.

@interface RBXDeviceCatalog : NSObject

// Missing, malformed or unreadable installed catalogs fail; there is no fallback
// to another package variant. Call before generation or consistency validation.
+ (BOOL)validateAvailability:(NSError **)error;
+ (BOOL)validateCountry:(NSString *)country error:(NSError **)error;

+ (NSDictionary *)modelForProductType:(NSString *)productType;
+ (NSDictionary *)allModels;
+ (NSString *)buildForIOS:(NSString *)iosVersion;
+ (NSString *)darwinForIOS:(NSString *)iosVersion;
+ (NSString *)regionSuffixForCountry:(NSString *)country;
+ (NSDictionary *)appleOUIs;
+ (NSString *)timezoneForCountry:(NSString *)country;
+ (NSString *)localeForCountry:(NSString *)country;
+ (BOOL)isAppleMAC:(NSString *)mac;
+ (NSString *)countryForTimezone:(NSString *)timezone;
+ (NSString *)countryForLocale:(NSString *)locale;
+ (NSArray<NSDictionary *> *)carriersForCountry:(NSString *)country;

// C3 â€” major cities per country ({ city, lat, lon }) for the GPS spoof.
+ (NSArray<NSDictionary *> *)citiesForCountry:(NSString *)country;

@end
