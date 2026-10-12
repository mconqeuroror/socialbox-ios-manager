#pragma once
#import "RBXAppRegistry.h"

// FBRUN-002: only the observed FBUserAgent producer structure is accepted.
// App/server metadata is preserved; this is not a general HTTP header rewriter.
static inline BOOL RBXFacebookUAMatches(id value, NSString *pattern) {
    if (![value isKindOfClass:NSString.class] || ![value length]) return NO;
    NSRange match = [value rangeOfString:pattern options:NSRegularExpressionSearch];
    return match.location == 0 && match.length == [value length];
}

static inline BOOL RBXFacebookUAValuesValid(NSDictionary *values) {
    if (![values isKindOfClass:NSDictionary.class] || values.count != 9) return NO;
    return [values[@"FBMD"] isEqual:@"iPhone"] && [values[@"FBSN"] isEqual:@"iOS"] &&
        [values[@"FBID"] isEqual:@"phone"] &&
        RBXFacebookUAMatches(values[@"FBDV"], @"^iPhone[0-9]{1,3},[0-9]{1,3}$") &&
        RBXFacebookUAMatches(values[@"FBSV"], @"^[0-9]{1,3}\\.[0-9]{1,3}(?:\\.[0-9]{1,3})?$") &&
        RBXFacebookUAMatches(values[@"FBLC"], @"^[a-z]{2,3}_[A-Z]{2}$") &&
        RBXFacebookUAMatches(values[@"FBSS"], @"^[23]$") &&
        RBXFacebookUAMatches(values[@"mobileBuild"], @"^[0-9]{2}[A-Z][0-9]{1,5}[a-z]?$") &&
        [values[@"mozillaOS"] isEqual:[values[@"FBSV"] stringByReplacingOccurrencesOfString:@"." withString:@"_"]];
}

static inline NSDictionary *RBXFacebookUAValuesForProfile(NSDictionary *profile) {
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (![descriptor[@"appType"] isEqual:@"facebook"]) return nil;
    NSDictionary *device = [profile[@"device"] isKindOfClass:NSDictionary.class] ? profile[@"device"] : nil;
    NSDictionary *screen = [device[@"screen"] isKindOfClass:NSDictionary.class] ? device[@"screen"] : nil;
    id scale = screen[@"scale"], ios = device[@"iosVersion"];
    if (!RBXFacebookUAMatches(scale, @"^[23](?:\\.0)?$") || ![ios isKindOfClass:NSString.class]) return nil;
    NSDictionary *values = @{
        @"FBDV":device[@"productType"] ?: @"", @"FBMD":@"iPhone", @"FBSN":@"iOS",
        @"FBSV":ios, @"FBSS":[scale substringToIndex:1], @"FBID":@"phone",
        @"FBLC":device[@"locale"] ?: @"", @"mobileBuild":device[@"buildVersion"] ?: @"",
        @"mozillaOS":[ios stringByReplacingOccurrencesOfString:@"." withString:@"_"]
    };
    return RBXFacebookUAValuesValid(values) ? values : nil;
}

// Nil means unsupported/malformed input. Callers must not fall back to an
// unmodified physical-device UA after installing this policy for a clone.
static inline NSString *RBXRewriteFacebookUserAgent(NSString *original, NSDictionary *values) {
    if (![original isKindOfClass:NSString.class] || original.length > 4096 ||
        !RBXFacebookUAValuesValid(values)) return nil;
    NSData *ascii = [original dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO];
    if (!ascii) return nil;
    const unsigned char *bytes = (const unsigned char *)ascii.bytes;
    for (NSUInteger i = 0; i < ascii.length; i++) if (bytes[i] < 0x20 || bytes[i] > 0x7e) return nil;
    static NSRegularExpression *format;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        format = [NSRegularExpression regularExpressionWithPattern:
            @"^Mozilla/([0-9]+(?:\\.[0-9]+)*) \\(iPhone; CPU iPhone OS ([0-9]+(?:_[0-9]+){1,2}) like Mac OS X\\) AppleWebKit/([0-9]+(?:\\.[0-9]+)*) \\(KHTML, like Gecko\\) Mobile/([0-9]{2}[A-Z][0-9]{1,5}[a-z]?) \\[FBAN/FBIOS;([^\\]\\r\\n]*)\\]$"
            options:0 error:nil];
    });
    NSTextCheckingResult *match = [format firstMatchInString:original options:0 range:NSMakeRange(0, original.length)];
    if (!match || match.range.location != 0 || match.range.length != original.length) return nil;
    NSString *body = [original substringWithRange:[match rangeAtIndex:5]];
    NSArray *parts = [body componentsSeparatedByString:@";"];
    if (parts.count > 64) return nil;
    NSSet *fields = [NSSet setWithArray:@[@"FBDV", @"FBMD", @"FBSN", @"FBSV", @"FBSS", @"FBID", @"FBLC"]];
    NSMutableSet *seen = [NSMutableSet setWithObject:@"FBAN"];
    NSMutableArray *rewritten = [NSMutableArray arrayWithCapacity:parts.count];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = parts[i];
        if (!part.length && i == parts.count - 1) { [rewritten addObject:part]; continue; }
        NSRange slash = [part rangeOfString:@"/"];
        if (slash.location == NSNotFound || slash.location == part.length - 1) return nil;
        NSString *key = [part substringToIndex:slash.location];
        if (!RBXFacebookUAMatches(key, @"^[A-Z][A-Z0-9_]{0,31}$") || [seen containsObject:key]) return nil;
        [seen addObject:key];
        [rewritten addObject:[fields containsObject:key]
            ? [NSString stringWithFormat:@"%@/%@", key, values[key]] : part];
    }
    if (![fields isSubsetOfSet:seen]) return nil;
    NSMutableString *result = [original mutableCopy];
    // Descending source ranges keep later replacements from shifting earlier ones.
    [result replaceCharactersInRange:[match rangeAtIndex:5] withString:[rewritten componentsJoinedByString:@";"]];
    [result replaceCharactersInRange:[match rangeAtIndex:4] withString:values[@"mobileBuild"]];
    [result replaceCharactersInRange:[match rangeAtIndex:2] withString:values[@"mozillaOS"]];
    return result.copy;
}
