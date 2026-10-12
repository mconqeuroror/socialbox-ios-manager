#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

// UI-only preview of the existing daemon's city/coordinate constraint. The
// daemon remains authoritative at Check/Save; this performs no geo lookup.
static inline BOOL RBXLocationNumber(id value, double *out) {
    if (![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class]) return NO;
    if ([value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    NSString *text = [[value description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double number = 0;
    if (!text.length || ![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number)) return NO;
    if (out) *out = number;
    return YES;
}

static inline NSDictionary *RBXLocationDraft(NSDictionary *catalog, NSString *country,
    id latitude, id longitude, NSString *proxyCountry, NSString *observedCountry, BOOL locked) {
    double lat = 0, lon = 0;
    NSString *reason = nil;
    NSDictionary *city = nil;
    if (!RBXLocationNumber(latitude, &lat) || !RBXLocationNumber(longitude, &lon) ||
        fabs(lat) > 90 || fabs(lon) > 180) reason = @"Enter valid latitude (−90…90) and longitude (−180…180).";
    else {
        // Check the same six-decimal representation returned below. Otherwise
        // rounding a point on the city boundary can pass here and fail Save.
        lat=[[NSString stringWithFormat:@"%.6f",lat] doubleValue];
        lon=[[NSString stringWithFormat:@"%.6f",lon] doubleValue];
        double nearest = INFINITY;
        for (id item in catalog[@"countryCities"][country] ?: @[]) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            double a = 0, b = 0;
            if (!RBXLocationNumber(item[@"lat"], &a) || !RBXLocationNumber(item[@"lon"], &b) ||
                ![item[@"city"] isKindOfClass:NSString.class] || ![item[@"timezone"] isKindOfClass:NSString.class]) continue;
            double dy = fabs(lat-a), dx = fabs(lon-b), distance = dx*dx+dy*dy;
            if (dy <= .031 && dx <= .031 && distance < nearest) { nearest = distance; city = item; }
        }
        if (!city) reason = @"Outside a supported city area. Search a catalog city, then place the pin nearby (within 0.031° of its center).";
    }
    if (locked) reason = @"This identity is locked after first use. The map is a preview; create a new container to change its location.";
    else if (proxyCountry.length && ![country isEqual:proxyCountry])
        reason = [NSString stringWithFormat:@"Region %@ differs from configured proxy country %@. Correct the region or proxy before using this location.", country, proxyCountry];
    else if (observedCountry.length && ![country isEqual:observedCountry])
        reason = [NSString stringWithFormat:@"Last observed proxy country %@ differs from region %@. Recheck the proxy; this map cannot change its exit country.", observedCountry, country];
    return @{@"valid":@(reason == nil), @"reason":reason ?: @"Location fits a supported catalog city. This is a draft, not a live GPS or proxy verification.",
        @"country":country ?: @"", @"city":city[@"city"] ?: @"", @"timezone":city[@"timezone"] ?: @"",
        @"latitude":[NSString stringWithFormat:@"%.6f",lat], @"longitude":[NSString stringWithFormat:@"%.6f",lon]};
}
