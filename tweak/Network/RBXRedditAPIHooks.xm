#import "RBXAppRuntime.h"
#import "RBXHookInstallation.h"
#import "RBXRedditAPIHooks.h"
#import "RBXProfile.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import "RBXAppleIdentifierHooks.h"
#import "RBXDeviceHooks.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <string.h>

// API payload layer. OS-level spoofs (MG/IDFA/IDFV/locale/tz) are not enough:
// Reddit iOS still puts Client-Vendor-ID, x-reddit-device-id, X-Dev-Ad-Id,
// Device-Name, User-Agent, install timestamps and analytics device fields on
// the wire. Those must be unique per container or Reddit clusters accounts
// on one phone. Server-issued loid/session/Authorization are isolated, not
// minted here.

static RBXDeviceProfile *rbxProfile(void) {
    return [RBXContainerManager sharedManager].currentProfile;
}

static BOOL RBXIsRedditAPIHost(NSString *host) {
    if (!host.length) return NO;
    NSString *h = host.lowercaseString;
    // WIRE-001: DNS-label boundaries for domain families observed in the IPA.
    // New domains need binary/network evidence and an explicit inventory delta.
    for (NSString *domain in @[@"reddit.com", @"redditmedia.com", @"redditstatic.com", @"redd.it"]) {
        if ([h isEqualToString:domain] || [h hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    }
    return NO;
}

static NSString *RBXRealRedditVersion(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSString *ver = [b objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return ver.length ? ver : @"2025.30.0";
}

static NSString *RBXRealRedditBuild(void) {
    NSBundle *b = [NSBundle mainBundle];
    NSString *build = [b objectForInfoDictionaryKey:@"CFBundleVersion"];
    return build.length ? build : @"1";
}

static NSString *RBXBuiltUserAgent(RBXDeviceProfile *p) {
    NSString *stored = [p redditUserAgent];
    if (stored.length) return stored;
    NSString *ios = p.iosVersion.length ? p.iosVersion : @"17.0";
    NSString *pt = p.productType.length ? p.productType : @"iPhone";
    NSString *scale = [p valueForPath:@"device.screen.scale"] ?: @"3";
    return [NSString stringWithFormat:@"Reddit/%@/%@ (iPhone; iOS %@; Scale/%@.00; %@)",
            RBXRealRedditVersion(), RBXRealRedditBuild(), ios, scale, pt];
}

static NSString *RBXHeaderCanon(NSString *field) {
    return [[field lowercaseString] stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
}

// YES = we force this header from the profile. loid/session/auth are excluded.
static NSString *RBXForcedHeaderValue(NSString *field, RBXDeviceProfile *p) {
    if (!field.length || !p) return nil;
    NSString *k = RBXHeaderCanon(field);
    if ([k isEqualToString:@"client-vendor-id"]
        || [k isEqualToString:@"x-reddit-device-id"]
        || [k isEqualToString:@"x-redditdevice-id"]) {
        return [p redditInstallId];
    }
    if ([k isEqualToString:@"user-agent"]) {
        return RBXBuiltUserAgent(p);
    }
    if ([k isEqualToString:@"x-dev-ad-id"] || [k isEqualToString:@"x-dev-adid"]) {
        return p.idfa;
    }
    if ([k isEqualToString:@"device-name"]) {
        return [p redditDeviceName];
    }
    if ([k isEqualToString:@"accept-language"]) {
        NSString *locale = [p valueForPath:@"device.locale"];
        return [locale stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    }
    return nil;
}

static void RBXApplyRedditHeaders(NSMutableURLRequest *req) {
    RBXDeviceProfile *p = rbxProfile();
    if (!req || !p) return;
    NSString *installId = [p redditInstallId];
    if (installId.length) {
        [req setValue:installId forHTTPHeaderField:@"Client-Vendor-ID"];
        [req setValue:installId forHTTPHeaderField:@"x-reddit-device-id"];
        [req setValue:installId forHTTPHeaderField:@"x-redditdevice-id"];
    }
    NSString *ua = RBXBuiltUserAgent(p);
    if (ua.length) [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    if (p.idfa.length) [req setValue:p.idfa forHTTPHeaderField:@"X-Dev-Ad-Id"];
    NSString *dn = [p redditDeviceName];
    if (dn.length) [req setValue:dn forHTTPHeaderField:@"Device-Name"];
    NSString *locale = [[p valueForPath:@"device.locale"]
                        stringByReplacingOccurrencesOfString:@"_" withString:@"-"];
    if (locale.length) {
        [req setValue:[NSString stringWithFormat:@"%@,en;q=0.8", locale]
            forHTTPHeaderField:@"Accept-Language"];
    }
}

static BOOL RBXIsPassThroughKey(NSString *key) {
    if (!key.length) return NO;
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"authorization"]
        || [k isEqualToString:@"access_token"]
        || [k isEqualToString:@"refresh_token"]
        || [k isEqualToString:@"bearer"]
        || [k isEqualToString:@"loid"]
        || [k isEqualToString:@"loids"]
        || [k isEqualToString:@"anonymous_loid"]
        || [k isEqualToString:@"reddit_loid"]
        || [k isEqualToString:@"x_reddit_loid"]
        || [k isEqualToString:@"session"]
        || [k isEqualToString:@"reddit_session"]
        || [k isEqualToString:@"x_reddit_session"]
        || [k isEqualToString:@"x_redditsession"]
        || [k isEqualToString:@"reddit_user_id"]
        || [k isEqualToString:@"user_id"]
        || [k isEqualToString:@"account_id"];
}

static BOOL RBXIsInstallIdKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"device_id"]
        || [k isEqualToString:@"deviceid"]
        || [k isEqualToString:@"installation_id"]
        || [k isEqualToString:@"installationid"]
        || [k isEqualToString:@"install_id"]
        || [k isEqualToString:@"client_vendor_id"]
        || [k isEqualToString:@"clientvendorid"]
        || [k isEqualToString:@"reddit_device_id"]
        || [k isEqualToString:@"redditdeviceid"]
        || [k isEqualToString:@"vendor_id"]
        || [k isEqualToString:@"idfv"]
        || [k isEqualToString:@"identifierforvendor"];
}

static BOOL RBXIsExternalInstallKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"external_installation_id"]
        || [k isEqualToString:@"externalinstallationid"];
}

static BOOL RBXIsAdIdKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"advertising_id"]
        || [k isEqualToString:@"advertisingid"]
        || [k isEqualToString:@"aaid"]
        || [k isEqualToString:@"google_aaid"]
        || [k isEqualToString:@"idfa"]
        || [k isEqualToString:@"reddaid"]
        || [k isEqualToString:@"adid"]
        || [k isEqualToString:@"ad_id"];
}

static BOOL RBXIsDeviceNameKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"device_name"]
        || [k isEqualToString:@"devicename"];
}

static BOOL RBXIsInstallTsKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"install_timestamp"]
        || [k isEqualToString:@"installtimestamp"]
        || [k isEqualToString:@"install_timestamp_ms"]
        || [k isEqualToString:@"installation_id_creation_time"]
        || [k isEqualToString:@"installation_creation_time"];
}

static BOOL RBXIsOsVersionKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"os_version"]
        || [k isEqualToString:@"osversion"]
        || [k isEqualToString:@"ios_version"]
        || [k isEqualToString:@"system_version"];
}

static BOOL RBXIsAppVersionKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"app_version"]
        || [k isEqualToString:@"appversion"];
}

static BOOL RBXIsBuildNumberKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"build_number"]
        || [k isEqualToString:@"buildnumber"]
        || [k isEqualToString:@"app_build"];
}

static BOOL RBXIsLanguageKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"primary_language"]
        || [k isEqualToString:@"language"]
        || [k isEqualToString:@"locale"];
}

static BOOL RBXIsLanguageListKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"language_list"]
        || [k isEqualToString:@"languagelist"]
        || [k isEqualToString:@"preferred_languages"];
}

static BOOL RBXIsUtcOffsetKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"utc_offset"]
        || [k isEqualToString:@"utcoffset"]
        || [k isEqualToString:@"timezone_offset"];
}

static BOOL RBXIsPushTokenKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"pushnotificationid"]
        || [k isEqualToString:@"push_notification_id"]
        || [k isEqualToString:@"push_token"]
        || [k isEqualToString:@"devicetoken"]
        || [k isEqualToString:@"device_token"]
        || [k isEqualToString:@"apns_token"]
        || [k isEqualToString:@"apnstoken"];
}

static BOOL RBXIsDeviceContext(NSString *parent) {
    if (!parent.length) return YES;
    NSString *p = parent.lowercaseString;
    return [p isEqualToString:@"platform"] || [p isEqualToString:@"app"]
        || [p isEqualToString:@"device"] || [p isEqualToString:@"client"]
        || [p isEqualToString:@"context"] || [p isEqualToString:@"variables"]
        || [p isEqualToString:@"input"];
}

static BOOL RBXDictHasRedditSignal(id obj, int depth) {
    if (depth > 8 || !obj) return NO;
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)obj) {
            if (RBXDictHasRedditSignal(item, depth + 1)) return YES;
        }
        return NO;
    }
    if (![obj isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = obj;
    for (id k in dict) {
        if (![k isKindOfClass:[NSString class]]) continue;
        NSString *lk = [[k lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        if ([lk isEqualToString:@"device_id"] || [lk isEqualToString:@"deviceid"]
            || [lk isEqualToString:@"installation_id"] || [lk isEqualToString:@"client_vendor_id"]
            || [lk isEqualToString:@"advertising_id"] || [lk isEqualToString:@"google_aaid"]
            || [lk isEqualToString:@"reddaid"] || [lk isEqualToString:@"aaid"]
            || [lk isEqualToString:@"install_timestamp"] || [lk isEqualToString:@"install_timestamp_ms"]
            || [lk isEqualToString:@"external_installation_id"]
            || [lk isEqualToString:@"x_dev_ad_id"]) {
            return YES;
        }
        if (RBXDictHasRedditSignal(dict[k], depth + 1)) return YES;
    }
    return NO;
}

static BOOL RBXIsFontSizeKey(NSString *key) {
    NSString *k = [[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    return [k isEqualToString:@"font_size"]
        || [k isEqualToString:@"fontsize"]
        || [k isEqualToString:@"text_size"]
        || [k isEqualToString:@"content_size_category"];
}

static NSNumber *RBXUtcOffsetMatching(id original, RBXDeviceProfile *p) {
    NSTimeZone *tz = nil;
    if (p.timezone.length) tz = [NSTimeZone timeZoneWithName:p.timezone];
    if (!tz) tz = [NSTimeZone localTimeZone];
    NSInteger secs = [tz secondsFromGMT];
    double orig = 0;
    if ([original isKindOfClass:[NSNumber class]]) orig = [(NSNumber *)original doubleValue];
    else if ([original isKindOfClass:[NSString class]]) orig = [(NSString *)original doubleValue];
    double mag = fabs(orig);
    if (mag <= 14.0 && mag > 0) return @((double)secs / 3600.0);
    if (mag <= 14.0 * 60.0 && mag > 0) return @((double)secs / 60.0);
    return @(secs);
}

static id RBXRewriteJSONValue(id obj, NSString *key, NSString *parent, RBXDeviceProfile *p);

static NSDictionary *RBXRewriteJSONDict(NSDictionary *dict, NSString *parent, RBXDeviceProfile *p) {
    if (![dict isKindOfClass:[NSDictionary class]] || !p) return dict;
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:dict.count];
    BOOL changed = NO;
    for (id rawKey in dict) {
        NSString *k = [rawKey isKindOfClass:[NSString class]] ? rawKey : nil;
        id v = dict[rawKey];
        id nv = RBXRewriteJSONValue(v, k, parent, p);
        if (!nv) nv = v;
        out[rawKey] = nv;
        if (nv != v && ![nv isEqual:v]) changed = YES;
    }
    return changed ? [out copy] : dict;
}

static id RBXRewriteJSONValue(id obj, NSString *key, NSString *parent, RBXDeviceProfile *p) {
    if (!obj || !p) return obj;
    // WIRE-002: server-owned values are opaque, including nested objects/arrays.
    if (RBXIsPassThroughKey(key)) return obj;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        return RBXRewriteJSONDict((NSDictionary *)obj, key, p);
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
        BOOL changed = NO;
        for (id item in (NSArray *)obj) {
            id nv = RBXRewriteJSONValue(item, key, parent, p);
            [arr addObject:nv ?: item];
            if (nv != item && ![nv isEqual:item]) changed = YES;
        }
        return changed ? [arr copy] : obj;
    }

    // session.id / session.created_timestamp stay whatever the container persisted
    // (already isolated). Do not mint a new session per request.
    NSString *parentL = parent.lowercaseString;
    if ([parentL isEqualToString:@"session"]
        && ([[[key lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@"_"] isEqualToString:@"id"]
            || [[key lowercaseString] containsString:@"created"])) {
        return obj;
    }

    if (RBXIsInstallIdKey(key)) {
        if ([key.lowercaseString isEqualToString:@"idfv"]
            || [key.lowercaseString isEqualToString:@"identifierforvendor"]
            || [key.lowercaseString isEqualToString:@"vendor_id"]) {
            return p.idfv.length ? p.idfv : obj;
        }
        NSString *v = [p redditInstallId];
        return v.length ? v : obj;
    }
    if (RBXIsExternalInstallKey(key)) {
        NSString *v = [p redditExternalInstallationId];
        return v.length ? v : obj;
    }
    if (RBXIsAdIdKey(key)) {
        return p.idfa.length ? p.idfa : obj;
    }
    if (RBXIsDeviceNameKey(key)) {
        NSString *v = [p redditDeviceName];
        return v.length ? v : obj;
    }
    if (RBXIsInstallTsKey(key)) {
        NSString *v = [p redditInstallTimestampMs];
        if (!v.length) return obj;
        if ([obj isKindOfClass:[NSNumber class]]) {
            return @((long long)v.longLongValue);
        }
        return v;
    }
    if (RBXIsDeviceContext(parent) && RBXIsOsVersionKey(key)) {
        return p.iosVersion.length ? p.iosVersion : obj;
    }
    if (RBXIsDeviceContext(parent) && RBXIsAppVersionKey(key)) {
        return RBXRealRedditVersion();
    }
    if (RBXIsDeviceContext(parent) && RBXIsBuildNumberKey(key)) {
        return RBXRealRedditBuild();
    }
    if (RBXIsDeviceContext(parent) && RBXIsLanguageListKey(key)) {
        NSString *lang = [p valueForPath:@"device.language"];
        if (!lang.length) {
            NSString *locale = [p valueForPath:@"device.locale"];
            lang = [locale componentsSeparatedByString:@"_"].firstObject;
        }
        if (lang.length) return @[lang];
        return obj;
    }
    if (RBXIsDeviceContext(parent) && RBXIsLanguageKey(key)) {
        NSString *lang = [p valueForPath:@"device.language"];
        if (!lang.length) {
            NSString *locale = [p valueForPath:@"device.locale"];
            lang = [locale componentsSeparatedByString:@"_"].firstObject;
        }
        return lang.length ? lang : obj;
    }
    if (RBXIsDeviceContext(parent) && RBXIsUtcOffsetKey(key)) {
        return RBXUtcOffsetMatching(obj, p);
    }
    if (RBXIsPushTokenKey(key)) {
        // Push is blocked; never create a synthetic server-side registration.
        if ([obj isKindOfClass:[NSString class]]) return @"";
        return [NSNull null];
    }
    if (RBXIsFontSizeKey(key)) {
        NSString *v = [p redditFontSize];
        if (!v.length) return obj;
        if ([obj isKindOfClass:[NSNumber class]]) return @(v.integerValue);
        return v;
    }

    // screen.width / screen.height (and w/h) under a screen-ish parent only.
    if ([parentL isEqualToString:@"screen"] || [parentL isEqualToString:@"display"]
        || [parentL isEqualToString:@"viewport"]) {
        NSString *k = [key lowercaseString];
        if ([k isEqualToString:@"width"] || [k isEqualToString:@"w"]) {
            NSString *v = [p redditScreenWidth];
            if (v.length) {
                return [obj isKindOfClass:[NSNumber class]] ? @(v.integerValue) : v;
            }
        }
        if ([k isEqualToString:@"height"] || [k isEqualToString:@"h"]) {
            NSString *v = [p redditScreenHeight];
            if (v.length) {
                return [obj isKindOfClass:[NSNumber class]] ? @(v.integerValue) : v;
            }
        }
    }

    return obj;
}

static BOOL RBXLooksLikeJSONObject(NSData *data) {
    if (data.length < 2) return NO;
    const uint8_t *b = (const uint8_t *)data.bytes;
    NSUInteger i = 0;
    while (i < data.length && (b[i] == ' ' || b[i] == '\n' || b[i] == '\r' || b[i] == '\t')) i++;
    if (i >= data.length) return NO;
    return b[i] == '{' || b[i] == '[';
}

static NSData *RBXRewriteJSONData(NSData *data, BOOL *changed) {
    if (changed) *changed = NO;
    RBXDeviceProfile *p = rbxProfile();
    if (!p || !RBXLooksLikeJSONObject(data)) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (!obj || !RBXDictHasRedditSignal(obj, 0)) return data;
    id rewritten = RBXRewriteJSONValue(obj, nil, nil, p);
    if (rewritten == obj || [rewritten isEqual:obj]) return data;
    NSData *out = [NSJSONSerialization dataWithJSONObject:rewritten options:0 error:nil];
    if (!out.length) return data;
    if (changed) *changed = YES;
    return out;
}

static NSData *RBXRewriteFormBody(NSData *data, BOOL *changed) {
    if (changed) *changed = NO;
    RBXDeviceProfile *p = rbxProfile();
    if (!p || !data.length) return data;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s.length || [s containsString:@"{"] ) return data;
    if (![s containsString:@"="]) return data;
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.percentEncodedQuery = s;
    NSArray<NSURLQueryItem *> *items = c.queryItems;
    if (!items.count) return data;
    NSMutableArray<NSURLQueryItem *> *out = [NSMutableArray arrayWithCapacity:items.count];
    BOOL did = NO;
    for (NSURLQueryItem *item in items) {
        id nv = RBXRewriteJSONValue(item.value, item.name, nil, p);
        NSString *val = [nv isKindOfClass:[NSString class]] ? nv :
            [nv isKindOfClass:[NSNumber class]] ? [(NSNumber *)nv stringValue] : item.value;
        if (val && item.value && ![val isEqualToString:item.value]) did = YES;
        [out addObject:[NSURLQueryItem queryItemWithName:item.name value:val]];
    }
    if (!did) return data;
    c.queryItems = out;
    NSString *q = c.percentEncodedQuery;
    if (!q.length) return data;
    if (changed) *changed = YES;
    return [q dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL RBXLooksLikeForm(NSData *data) {
    if (data.length < 3 || data.length > 1 << 20) return NO;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s.length || [s containsString:@"{"]) return NO;
    return [s containsString:@"="];
}

static BOOL RBXLooksLikeMedia(NSData *data) {
    if (data.length < 4) return NO;
    const uint8_t *b = (const uint8_t *)data.bytes;
    if (b[0] == 0xFF && b[1] == 0xD8) return YES;
    if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return YES;
    if (b[0] == 'G' && b[1] == 'I' && b[2] == 'F') return YES;
    if (b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F') return YES;
    if (b[0] == '%' && b[1] == 'P' && b[2] == 'D' && b[3] == 'F') return YES;
    if (data.length > 8 && b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') return YES;
    return NO;
}

static BOOL RBXIsPrintableASCII(uint8_t c) {
    return c >= 0x20 && c <= 0x7E;
}

static void RBXReplaceAllSameLength(NSMutableData *m, NSData *needle, NSData *repl) {
    if (!m || !needle.length || needle.length != repl.length) return;
    if (needle.length > m.length) return;
    uint8_t *b = (uint8_t *)m.mutableBytes;
    const uint8_t *n = (const uint8_t *)needle.bytes;
    const uint8_t *r = (const uint8_t *)repl.bytes;
    NSUInteger nlen = needle.length;
    NSUInteger end = m.length;
    NSUInteger i = 0;
    while (i + nlen <= end) {
        if (memcmp(b + i, n, nlen) == 0) {
            memcpy(b + i, r, nlen);
            i += nlen;
        } else {
            i++;
        }
    }
}

static void RBXAddSameLengthPair(NSMutableArray<NSArray<NSData *> *> *pairs, NSString *from, NSString *to) {
    if (!from.length || !to.length || from.length != to.length) return;
    if ([from isEqualToString:to]) return;
    NSData *a = [from dataUsingEncoding:NSUTF8StringEncoding];
    NSData *b = [to dataUsingEncoding:NSUTF8StringEncoding];
    if (a.length != b.length || !a.length) return;
    [pairs addObject:@[a, b]];
}

// Same-length UTF-8 swap of real-device IDs → profile values, plus a bounded
// lookahead after known ASCII keys (map<string,string> / proto-lite). Length
// is never changed so protobuf varint prefixes stay valid. Unknown binary
// (media, huge blobs) is passed through. No crash path — memcmp only.
static NSData *RBXRewriteProtobufData(NSData *data, BOOL *changed) {
    if (changed) *changed = NO;
    RBXDeviceProfile *p = rbxProfile();
    if (!p || !data.length || data.length > 2 * 1024 * 1024) return data;
    if (RBXLooksLikeJSONObject(data) || RBXLooksLikeMedia(data)) return data;

    NSMutableArray<NSArray<NSData *> *> *pairs = [NSMutableArray array];
    RBXAddSameLengthPair(pairs, RBXRealIDFAString(), p.idfa);
    RBXAddSameLengthPair(pairs, RBXRealIDFVString(), p.idfv);
    NSString *install = [p redditInstallId];
    NSString *ext = [p redditExternalInstallationId];
    // If a real IDFA/IDFV was also used as an install-shaped UUID, the pair
    // list already covers it. Profile-only values are applied via key lookahead.

    NSMutableData *m = [data mutableCopy];
    BOOL did = NO;
    for (NSArray<NSData *> *pair in pairs) {
        NSData *before = [m copy];
        RBXReplaceAllSameLength(m, pair[0], pair[1]);
        if (![m isEqualToData:before]) did = YES;
    }

    NSArray<NSArray<NSString *> *> *keys = @[
        @[@"device_id", install ?: @""],
        @[@"deviceId", install ?: @""],
        @[@"installation_id", install ?: @""],
        @[@"installationid", install ?: @""],
        @[@"client_vendor_id", install ?: @""],
        @[@"reddit_device_id", install ?: @""],
        @[@"external_installation_id", ext ?: @""],
        @[@"advertising_id", p.idfa ?: @""],
        @[@"advertisingid", p.idfa ?: @""],
        @[@"aaid", p.idfa ?: @""],
        @[@"google_aaid", p.idfa ?: @""],
        @[@"idfa", p.idfa ?: @""],
        @[@"reddaid", p.idfa ?: @""],
        @[@"idfv", p.idfv ?: @""],
        @[@"vendor_id", p.idfv ?: @""],
        @[@"push_token", @""],
        @[@"push_notification_id", @""],
        @[@"device_token", @""],
        @[@"apns_token", @""],
    ];

    uint8_t *bytes = (uint8_t *)m.mutableBytes;
    NSUInteger end = m.length;
    for (NSArray<NSString *> *entry in keys) {
        NSString *key = entry[0];
        NSString *repl = entry[1];
        if (!key.length || !repl.length) continue;
        const char *kutf = key.UTF8String;
        const char *rutf = repl.UTF8String;
        if (!kutf || !rutf) continue;
        NSUInteger klen = strlen(kutf);
        NSUInteger rlen = strlen(rutf);
        if (!klen || rlen != repl.length) continue;
        NSUInteger i = 0;
        while (i + klen <= end) {
            if (memcmp(bytes + i, kutf, klen) == 0) {
                NSUInteger scan = i + klen;
                NSUInteger limit = end < scan + 96 ? end : scan + 96;
                while (scan + rlen <= limit) {
                    if (RBXIsPrintableASCII(bytes[scan])) {
                        BOOL allPrint = YES;
                        for (NSUInteger k = 0; k < rlen; k++) {
                            if (!RBXIsPrintableASCII(bytes[scan + k])) {
                                allPrint = NO;
                                break;
                            }
                        }
                        BOOL bounded = (scan + rlen >= end) || !RBXIsPrintableASCII(bytes[scan + rlen]);
                        if (allPrint && bounded && memcmp(bytes + scan, rutf, rlen) != 0) {
                            memcpy(bytes + scan, rutf, rlen);
                            did = YES;
                            break;
                        }
                    }
                    scan++;
                }
                i += klen;
            } else {
                i++;
            }
        }
    }

    if (!did) return data;
    if (changed) *changed = YES;
    return m;
}

static NSData *RBXRewriteBodyData(NSData *data, NSString *contentType, BOOL *changed) {
    if (changed) *changed = NO;
    if (!data.length || !rbxProfile()) return data;
    NSString *ctype = contentType.lowercaseString ?: @"";
    if ([ctype containsString:@"json"] || RBXLooksLikeJSONObject(data)) {
        NSData *out = RBXRewriteJSONData(data, changed);
        if (changed && *changed) return out;
        if (RBXLooksLikeJSONObject(data)) return data;
    }
    if ([ctype containsString:@"www-form-urlencoded"] || RBXLooksLikeForm(data)) {
        return RBXRewriteFormBody(data, changed);
    }
    if ([ctype containsString:@"protobuf"] || [ctype containsString:@"grpc"]
        || [ctype containsString:@"octet-stream"] || [ctype containsString:@"x-protobuf"]
        || (!ctype.length && !RBXLooksLikeMedia(data))) {
        return RBXRewriteProtobufData(data, changed);
    }
    if (!RBXLooksLikeMedia(data) && !RBXLooksLikeJSONObject(data)) {
        return RBXRewriteProtobufData(data, changed);
    }
    return data;
}

// WIRE-005: without a verified signing schema, preserve the complete signed
// request. Do not strip authentication, guess signed fields, or forge a signature.
static BOOL RBXHeadersHaveBodyAuthentication(NSDictionary *headers) {
    for (id field in headers) {
        if (![field isKindOfClass:NSString.class]) return YES;
        NSString *name = [field lowercaseString];
        if ([@[@"x-hmac-signed-body", @"x-hmac-signed-result", @"signature",
               @"signature-input", @"digest", @"content-digest"] containsObject:name]) {
            id value = headers[field];
            if (![value isKindOfClass:NSString.class] || [value length]) return YES;
        }
    }
    return NO;
}

static BOOL RBXRequestHasBodyAuthentication(NSURLRequest *request) {
    return RBXHeadersHaveBodyAuthentication(request.allHTTPHeaderFields);
}

// WIRE-003/004/006/009: mutate at the request boundary, where destination
// ownership is known. Serialization and body assignment are not that boundary.
static NSData *RBXRewriteBodyForRequest(NSURLRequest *request, NSData *data, BOOL *changed) {
    if (changed) *changed = NO;
    if (!RBXIsRedditAPIHost(request.URL.host) || RBXRequestHasBodyAuthentication(request)) return data;
    return RBXRewriteBodyData(data, [request valueForHTTPHeaderField:@"Content-Type"], changed);
}

static BOOL RBXRewriteRequestBody(NSMutableURLRequest *req) {
    NSData *body = req.HTTPBody;
    if (!body.length) return NO;
    BOOL changed = NO;
    NSData *out = RBXRewriteBodyForRequest(req, body, &changed);
    if (changed && out) {
        req.HTTPBody = out;
        return YES;
    }
    return NO;
}

static NSURL *RBXRewriteUploadFile(NSURL *fileURL, NSURLRequest *request) {
    if (!fileURL || !rbxProfile() || !RBXIsRedditAPIHost(request.URL.host) ||
        RBXRequestHasBodyAuthentication(request)) return fileURL;
    NSData *data = [NSData dataWithContentsOfURL:fileURL];
    if (!data.length) return fileURL;
    BOOL changed = NO;
    NSData *out = RBXRewriteBodyForRequest(request, data, &changed);
    if (!changed || !out.length) return fileURL;
    NSString *dir = NSTemporaryDirectory();
    NSString *name = [NSString stringWithFormat:@"rbx.upload.%@", [NSUUID UUID].UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:name];
    if (![out writeToFile:path atomically:YES]) return fileURL;
    return [NSURL fileURLWithPath:path];
}

static void RBXRecordAuthenticatedActivity(NSURLRequest *request) {
    NSString *authorization = [request valueForHTTPHeaderField:@"Authorization"];
    if (!authorization.length || !RBXIsRedditAPIHost(request.URL.host)) return;
    static NSTimeInterval lastWrite = 0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    @synchronized (RBXContainerManager.class) {
        if (now - lastWrite < 300) return;
        lastWrite = now;
    }
    RBXContainerManager *manager = RBXContainerManager.sharedManager;
    NSString *containerId = manager.containerId;
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!containerId.length || !bundleIdentifier.length) return;
    NSString *directory = [NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Preferences"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    [@{
        @"containerId": containerId,
        @"bundleIdentifier": bundleIdentifier,
        @"lastLoginAt": @(now),
    } writeToFile:[directory stringByAppendingPathComponent:
        @"com.redditbox.login-status.plist"] atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.redditbox.loginActivity"), NULL, NULL, TRUE);
}

static NSURLRequest *RBXRewriteRequest(NSURLRequest *req) {
    RBXDeviceProfile *p = rbxProfile();
    if (!req || !p) return req;
    BOOL redditHost = RBXIsRedditAPIHost(req.URL.host);
    if (!redditHost) return req;
    RBXRecordAuthenticatedActivity(req);
    if (RBXRequestHasBodyAuthentication(req)) return req;
    NSMutableURLRequest *m = [req mutableCopy];
    if (redditHost) RBXApplyRedditHeaders(m);
    RBXRewriteRequestBody(m);
    return m;
}

// --- UserDefaults isolation (loid / installation_id / session) -----------------

static NSSet<NSString *> *RBXIsolatedDefaultsKeys(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[
            @"installation_id", @"installationid", @"installation_id_creation_time",
            @"external_installation_id", @"externalinstallationid",
            @"loid", @"loids", @"anonymous_loid", @"reddit_loid", @"x-reddit-loid",
            @"redditloid", @"device_id", @"deviceid", @"reddit_device_id",
            @"client_vendor_id", @"clientvendorid", @"reddaid",
            @"install_timestamp", @"install_timestamp_ms",
            @"reddit_session", @"x-reddit-session", @"x-redditsession",
            @"push_token", @"push_notification_id", @"devicetoken",
            @"device_token", @"apns_token", @"apnstoken",
        ]];
    });
    return s;
}

static BOOL RBXIsIsolatedDefaultsKey(NSString *key) {
    if (!key.length) return NO;
    return [RBXIsolatedDefaultsKeys() containsObject:key.lowercaseString];
}

static BOOL RBXIsSystemSuite(NSString *suite) {
    if (!suite.length) return YES;
    if ([suite isEqualToString:NSGlobalDomain]) return YES;
    if ([suite isEqualToString:NSArgumentDomain]) return YES;
    if ([suite isEqualToString:NSRegistrationDomain]) return YES;
    NSString *s = suite.lowercaseString;
    if ([s hasPrefix:@"com.apple."]) return YES;
    if ([s hasPrefix:@"apple global"]) return YES;
    if ([s isEqualToString:@"kcfpreferencesanyapplication"]) return YES;
    return NO;
}

// Reddit process only. Remap every non-Apple suite — app groups, Branch,
// Firebase, Google, Crashlytics, Adjust, AppsFlyer, Kochava, and anything
// else — onto a container-local name so the shared App Group / SDK plist
// cannot join accounts. Path hooks already isolate the container home.
static BOOL RBXShouldRemapSuite(NSString *suite) {
    return !RBXIsSystemSuite(suite);
}

static NSMutableDictionary *sIsolated;
static NSString *sIsolatedPath;
static dispatch_queue_t sIsolatedQueue;

static void RBXIsolatedLoad(void) {
    if (sIsolated) return;
    sIsolatedQueue = dispatch_queue_create("com.redditbox.isolated-defaults", DISPATCH_QUEUE_SERIAL);
    NSString *dir = [RBXContainerManager sharedManager].containerDataDirectory;
    NSString *prefDir = [dir stringByAppendingPathComponent:@"Library/Preferences"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefDir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    sIsolatedPath = [prefDir stringByAppendingPathComponent:@"rbx.reddit.session.plist"];
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:sIsolatedPath];
    sIsolated = [disk isKindOfClass:[NSDictionary class]] ? [disk mutableCopy] : [NSMutableDictionary dictionary];
}

static void RBXIsolatedSave(void) {
    if (!sIsolatedPath) return;
    NSDictionary *snap = nil;
    @synchronized (sIsolated) {
        snap = [sIsolated copy];
    }
    dispatch_async(sIsolatedQueue, ^{
        [snap writeToFile:sIsolatedPath atomically:YES];
    });
}

static id RBXIsolatedRead(NSString *key) {
    if (!key.length || !rbxProfile()) return nil;
    RBXIsolatedLoad();
    id v = nil;
    @synchronized (sIsolated) {
        v = sIsolated[key];
    }
    if (v) return v;
    NSString *lk = key.lowercaseString;
    RBXDeviceProfile *p = rbxProfile();
    if ([lk isEqualToString:@"installation_id"] || [lk isEqualToString:@"installationid"]
        || [lk isEqualToString:@"device_id"] || [lk isEqualToString:@"deviceid"]
        || [lk isEqualToString:@"client_vendor_id"] || [lk isEqualToString:@"clientvendorid"]
        || [lk isEqualToString:@"reddit_device_id"]) {
        v = [p redditInstallId];
    } else if ([lk isEqualToString:@"external_installation_id"]
               || [lk isEqualToString:@"externalinstallationid"]) {
        v = [p redditExternalInstallationId];
    } else if ([lk isEqualToString:@"install_timestamp"]
               || [lk isEqualToString:@"install_timestamp_ms"]
               || [lk isEqualToString:@"installation_id_creation_time"]) {
        v = [p redditInstallTimestampMs];
    } else if ([lk isEqualToString:@"reddaid"]) {
        v = p.idfa;
    }
    if (v) {
        @synchronized (sIsolated) {
            sIsolated[key] = v;
        }
        RBXIsolatedSave();
    }
    return v;
}

static void RBXIsolatedWrite(NSString *key, id value) {
    if (!key.length || !rbxProfile()) return;
    RBXIsolatedLoad();
    @synchronized (sIsolated) {
        if (value) sIsolated[key] = value;
        else [sIsolated removeObjectForKey:key];
    }
    RBXIsolatedSave();
}

static NSString *RBXCFPreferencesKey(CFStringRef key, CFStringRef applicationID) {
    if (!key) return nil;
    NSString *app = applicationID ? [(__bridge id)applicationID description] : @"current";
    return [NSString stringWithFormat:@"cfprefs:%@:%@", app ?: @"current",
                                      (__bridge NSString *)key];
}

static CFPropertyListRef (*orig_CFPreferencesCopyAppValue)(CFStringRef, CFStringRef);
static void (*orig_CFPreferencesSetAppValue)(CFStringRef, CFPropertyListRef, CFStringRef);
static CFPropertyListRef (*orig_CFPreferencesCopyValue)(
    CFStringRef, CFStringRef, CFStringRef, CFStringRef);
static void (*orig_CFPreferencesSetValue)(
    CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef);
static Boolean (*orig_CFPreferencesSynchronize)(CFStringRef, CFStringRef, CFStringRef);

static CFPropertyListRef replaced_CFPreferencesCopyAppValue(
    CFStringRef key, CFStringRef applicationID) {
    id value = RBXIsolatedRead(RBXCFPreferencesKey(key, applicationID));
    return value ? CFRetain((__bridge CFTypeRef)value) : NULL;
}

static void replaced_CFPreferencesSetAppValue(
    CFStringRef key, CFPropertyListRef value, CFStringRef applicationID) {
    RBXIsolatedWrite(RBXCFPreferencesKey(key, applicationID), (__bridge id)value);
}

static CFPropertyListRef replaced_CFPreferencesCopyValue(
    CFStringRef key, CFStringRef applicationID, CFStringRef user, CFStringRef host) {
    (void)user; (void)host;
    return replaced_CFPreferencesCopyAppValue(key, applicationID);
}

static void replaced_CFPreferencesSetValue(
    CFStringRef key, CFPropertyListRef value, CFStringRef applicationID,
    CFStringRef user, CFStringRef host) {
    (void)user; (void)host;
    replaced_CFPreferencesSetAppValue(key, value, applicationID);
}

static Boolean replaced_CFPreferencesSynchronize(
    CFStringRef applicationID, CFStringRef user, CFStringRef host) {
    (void)applicationID; (void)user; (void)host;
    RBXIsolatedSave();
    return true;
}

// --- hooks -------------------------------------------------------------------

// Request builders remain native: URL and authentication headers may be assigned
// in any order. Only the dispatch adapters below may transform a request.

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    return %orig(RBXRewriteRequest(request));
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    return %orig(RBXRewriteRequest(request), handler);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    RBXDeviceProfile *p = rbxProfile();
    if (p && RBXIsRedditAPIHost(url.host)) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        RBXApplyRedditHeaders(req);
        return [self dataTaskWithRequest:req];
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    RBXDeviceProfile *p = rbxProfile();
    if (p && RBXIsRedditAPIHost(url.host)) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        RBXApplyRedditHeaders(req);
        return [self dataTaskWithRequest:req completionHandler:handler];
    }
    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    NSURLRequest *rewritten = RBXRewriteRequest(request);
    BOOL changed = NO;
    NSData *body = RBXRewriteBodyForRequest(request, bodyData, &changed);
    return %orig(rewritten, body);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *rewritten = RBXRewriteRequest(request);
    BOOL changed = NO;
    NSData *body = RBXRewriteBodyForRequest(request, bodyData, &changed);
    return %orig(rewritten, body, handler);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromFile:(NSURL *)fileURL {
    NSURLRequest *rewritten = RBXRewriteRequest(request);
    return %orig(rewritten, RBXRewriteUploadFile(fileURL, rewritten));
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromFile:(NSURL *)fileURL
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURLRequest *rewritten = RBXRewriteRequest(request);
    return %orig(rewritten, RBXRewriteUploadFile(fileURL, rewritten), handler);
}

- (NSURLSessionUploadTask *)uploadTaskWithStreamedRequest:(NSURLRequest *)request {
    return %orig(RBXRewriteRequest(request));
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request {
    return %orig(RBXRewriteRequest(request));
}

- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request
                                    completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))handler {
    return %orig(RBXRewriteRequest(request), handler);
}

%end

BOOL RBXInstallRedditAPIHooks(RBXDeviceProfile *profile) {
    // A Facebook process must never install Reddit payload/defaults adapters,
    // including through this file's independent Logos constructor.
    if (!RBXAppRuntimeWirePolicyAudited(RBXAppDescriptorForProfile(profile.rawProfile))) return NO;
    static BOOL installed = NO;
    if (installed) return RBXHookInstallationPassed();
    installed = YES;
    %init;
    if (!profile) {
        RBXLog("Reddit API rewrite installed (pass-through — no profile)");
        return NO;
    }
    RBXLog("Reddit API rewrite active; defaults/CFPreferences use clone OS sandbox for %@",
           profile.containerId);
    return RBXHookInstallationPassed();
}

%ctor {
    @autoreleasepool {
        if (!RBXAppRuntimeHooksEnabled()) return;
        RBXInstallRedditAPIHooks([RBXContainerManager sharedManager].currentProfile);
    }
}
