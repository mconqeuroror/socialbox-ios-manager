#pragma once
#import <Foundation/Foundation.h>
#include <errno.h>
#include <stdlib.h>
#include <math.h>

// EDIT-012: non-derived generated values must survive Auto -> review -> Save.
// These remain private editor inputs, never launcher-state or receipt fields.
static inline NSDictionary *RBXAdditionalIdentityFields(void) {
    return @{@"mlb":@"serials.mlb", @"uniqueChipId":@"serials.uniqueChipId",
        @"bootTimeOffsetSeconds":@"timing.bootTimeOffsetSeconds",
        @"syntheticBootEpoch":@"timing.syntheticBootEpoch",
        @"installTimestampMs":@"reddit.installTimestampMs",
        @"latitude":@"device.location.lat", @"longitude":@"device.location.lon"};
}

static inline NSString *RBXAdditionalIdentityInputError(NSDictionary *choices) {
    for (NSString *key in RBXAdditionalIdentityFields()) {
        id raw = choices[key];
        if (!raw) continue; // Existing partial clients retain saved values.
        if (![raw isKindOfClass:NSString.class] || ![raw length] || [raw length] > 32)
            return [NSString stringWithFormat:@"%@ must contain a valid value", key];
        NSString *pattern = [key isEqual:@"mlb"] ? @"^[0-9A-Fa-f]{4}[0-9]$" :
            ([@[@"latitude",@"longitude"] containsObject:key] ? @"^-?[0-9]+(?:\\.[0-9]+)?$" : @"^[0-9]+$");
        BOOL valid = [raw rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
        if (valid && [key isEqual:@"uniqueChipId"]) {
            errno = 0; char *end = NULL;
            unsigned long long number = strtoull([raw UTF8String], &end, 10);
            valid = errno != ERANGE && end && !*end && number > 0;
        } else if (valid && ![key isEqual:@"mlb"]) {
            double number = [raw doubleValue], now = NSDate.date.timeIntervalSince1970;
            if ([key isEqual:@"latitude"]) valid = fabs(number) <= 90;
            else if ([key isEqual:@"longitude"]) valid = fabs(number) <= 180;
            else if ([key isEqual:@"bootTimeOffsetSeconds"]) valid = number >= 0 && number <= 1209600;
            else if ([key isEqual:@"syntheticBootEpoch"]) valid = number >= 946684800 && number <= now;
            else if ([key isEqual:@"installTimestampMs"]) valid = number >= 946684800000 && number <= now * 1000;
            valid = valid && isfinite(number);
        }
        if (!valid) return [NSString stringWithFormat:@"%@ has an invalid format or range", key];
    }
    if ((choices[@"latitude"] != nil) != (choices[@"longitude"] != nil))
        return @"Latitude and longitude must be supplied together";
    return nil;
}

static inline void RBXAddAdditionalIdentityFields(NSMutableDictionary *draft, NSDictionary *profile) {
    [RBXAdditionalIdentityFields() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *path, BOOL *stop) {
        id value = profile;
        for (NSString *part in [path componentsSeparatedByString:@"."])
            value = [value isKindOfClass:NSDictionary.class] ? value[part] : nil;
        if ([value isKindOfClass:NSNumber.class]) value = [value stringValue];
        if ([value isKindOfClass:NSString.class]) draft[key] = value;
    }];
}

static inline void RBXApplyAdditionalIdentityFields(NSMutableDictionary *profile, NSDictionary *choices) {
    [RBXAdditionalIdentityFields() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *path, BOOL *stop) {
        if (!choices[key]) return;
        NSArray *parts = [path componentsSeparatedByString:@"."];
        NSMutableDictionary *cursor = profile;
        for (NSUInteger i = 0; i + 1 < parts.count; i++) {
            NSMutableDictionary *child = [cursor[parts[i]] mutableCopy] ?: [NSMutableDictionary dictionary];
            cursor[parts[i]] = child; cursor = child;
        }
        id value = choices[key];
        if ([key isEqual:@"uniqueChipId"]) value = @(strtoull([value UTF8String], NULL, 10));
        if ([key isEqual:@"mlb"]) value = [value uppercaseString];
        cursor[parts.lastObject] = value;
    }];
}
