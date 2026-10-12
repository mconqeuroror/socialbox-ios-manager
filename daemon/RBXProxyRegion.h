#pragma once
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import "RBXDeviceCatalog.h"

// IP geolocation is an observation. Locale, SIM carrier and an unavailable city
// are catalog suggestions, never evidence of the proxy's or phone's SIM.
static inline NSDictionary *RBXProxyRegionSuggestion(id value, NSError **error) {
    NSString *failure = nil;
    if (![value isKindOfClass:NSDictionary.class]) failure = @"Proxy location response is not an object.";
    NSDictionary *json = failure ? @{} : value;
    for (NSString *key in @[@"ip", @"country", @"city", @"timezone", @"org"]) {
        id field = json[key];
        if (field && (![field isKindOfClass:NSString.class] || [field length] > 160 ||
            [field rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound))
            failure = @"Proxy location response contains an invalid field.";
    }
    if (failure) { if (error) *error = [NSError errorWithDomain:@"com.redditbox.proxy-region" code:422 userInfo:@{NSLocalizedDescriptionKey:failure}]; return nil; }
    unsigned char address[16];
    NSString *ip = json[@"ip"] ?: @"";
    if (inet_pton(AF_INET, ip.UTF8String, address) != 1 && inet_pton(AF_INET6, ip.UTF8String, address) != 1)
        failure = @"Proxy location response has no valid exit IP.";
    NSString *country = [json[@"country"] uppercaseString] ?: @"";
    if (![RBXDeviceCatalog validateCountry:country error:nil]) failure = [NSString stringWithFormat:
        @"Proxy country %@ is not supported by the identity catalog. Choose another proxy or configure a supported region manually.", country.length ? country : @"(missing)"];
    NSString *observedTimezone = json[@"timezone"] ?: @"";
    NSString *timezone = observedTimezone.length ? observedTimezone : [RBXDeviceCatalog timezoneForCountry:country];
    if (observedTimezone.length && ![[RBXDeviceCatalog countryForTimezone:timezone] isEqual:country])
        failure = @"The proxy's timezone is unsupported or does not match its country. No region was applied.";
    NSString *observedCity = json[@"city"] ?: @"";
    NSDictionary *city = nil;
    for (NSDictionary *item in [RBXDeviceCatalog citiesForCountry:country]) {
        if (![item[@"timezone"] isEqual:timezone]) continue;
        if (!city) city = item;
        if ([item[@"city"] caseInsensitiveCompare:observedCity] == NSOrderedSame) { city = item; break; }
    }
    if (!city) failure = failure ?: @"No catalog city matches the proxy's timezone. No region was applied.";
    if (failure) { if (error) *error = [NSError errorWithDomain:@"com.redditbox.proxy-region" code:422 userInfo:@{NSLocalizedDescriptionKey:failure}]; return nil; }
    NSDictionary *carrier = [RBXDeviceCatalog carriersForCountry:country].firstObject;
    return @{@"country":country, @"locale":[RBXDeviceCatalog localeForCountry:country],
        @"timezone":timezone, @"city":city[@"city"],
        @"carrierCode":[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]],
        @"carrierName":carrier[@"name"], @"carrierSource":@"catalog-suggestion",
        @"localeSource":@"catalog-suggestion", @"countrySource":@"ip-geolocation",
        @"timezoneSource":observedTimezone.length ? @"ip-geolocation" : @"catalog-suggestion",
        @"citySource":observedCity.length && [city[@"city"] caseInsensitiveCompare:observedCity] == NSOrderedSame ? @"ip-geolocation" : @"catalog-suggestion",
        @"observedCity":observedCity, @"observedTimezone":observedTimezone,
        @"networkName":json[@"org"] ?: @"", @"checkedAt":@(NSDate.date.timeIntervalSince1970)};
}
