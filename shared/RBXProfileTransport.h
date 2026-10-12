#pragma once
#import <Foundation/Foundation.h>

// A clone needs proxy connection parameters, never rotation/control credentials.
// Apply at every profile boundary, including legacy backups and signed bundles.
static inline NSDictionary *RBXProfileForTransport(NSDictionary *profile) {
    if (![profile isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *safe = [profile mutableCopy];
    [safe removeObjectsForKeys:@[@"rotationAuth", @"rotationAuthHeader", @"rotationAuthValue",
        @"rotationURL", @"authorization", @"authHeader", @"accessKey", @"deviceToken", @"passphrase"]];
    NSMutableDictionary *proxy = [NSMutableDictionary dictionary];
    if ([profile[@"proxy"] isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[@"url", @"country", @"proxyId"])
            if (profile[@"proxy"][key]) proxy[key] = profile[@"proxy"][key];
        safe[@"proxy"] = proxy;
    }
    return safe;
}
