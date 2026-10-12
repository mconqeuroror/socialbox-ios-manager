#import "RBXRotationSecrets.h"
#import "RBXProfileIdentifier.h"
#import "RBXProfileTransport.h"
#import <Security/Security.h>

static NSError *RBXRotationSecretError(OSStatus status) {
    return [NSError errorWithDomain:@"com.redditbox.rotation-secret" code:status userInfo:
        @{NSLocalizedDescriptionKey: @"Daemon-only rotation credentials could not be validated or persisted; unlock the device and check daemon entitlements"}];
}

static NSMutableDictionary *RBXRotationSecretQuery(NSString *identifier, NSError **error) {
    // Keychain account names are opaque, not paths. Permit legacy profile IDs
    // here so upgrade migration/deletion can preserve their existing identity.
    if (![identifier isKindOfClass:NSString.class] || !identifier.length ||
        [identifier lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) {
        if (error) *error = RBXRotationSecretError(errSecParam); return nil;
    }
    return [@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.redditbox.daemon.profile-rotation",
        (__bridge id)kSecAttrAccount: identifier,
        (__bridge id)kSecAttrAccessGroup: @"RBXBOXCFG.com.redditbox.daemon-control",
        (__bridge id)kSecAttrSynchronizable: @NO} mutableCopy];
}

static BOOL RBXValidRotationOverride(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    if (!value.count) return YES;
    if (value.count != 2 || ![value[@"header"] isKindOfClass:NSString.class] ||
        ![value[@"value"] isKindOfClass:NSString.class]) return NO;
    NSString *header = value[@"header"], *secret = value[@"value"];
    NSCharacterSet *headerChars = [NSCharacterSet characterSetWithCharactersInString:
        @"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"];
    return header.length && header.length <= 128 && secret.length && secret.length <= 4096 &&
        [header rangeOfCharacterFromSet:headerChars.invertedSet].location == NSNotFound &&
        [secret rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

@implementation RBXRotationSecrets
+ (NSDictionary *)overrideForProfile:(NSString *)identifier error:(NSError **)error {
    NSMutableDictionary *query = RBXRotationSecretQuery(identifier, error);
    if (!query) return nil;
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) { if (result) CFRelease(result); return nil; }
    if (status != errSecSuccess || !result || CFGetTypeID(result) != CFDataGetTypeID()) {
        if (result) CFRelease(result);
        if (error) *error = RBXRotationSecretError(status == errSecSuccess ? errSecDecode : status); return nil;
    }
    NSData *data = CFBridgingRelease(result);
    id record = data.length ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:error] : nil;
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"formatVersion"] isEqual:@1] ||
        ![record[@"profileId"] isEqual:identifier] || !RBXValidRotationOverride(record[@"override"])) {
        if (error) *error = RBXRotationSecretError(errSecDecode); return nil;
    }
    return record[@"override"];
}

+ (BOOL)saveOverride:(NSDictionary *)override profile:(NSString *)identifier error:(NSError **)error {
    NSMutableDictionary *query = RBXRotationSecretQuery(identifier, error);
    if (!query) return NO;
    if (!RBXValidRotationOverride(override)) { if (error) *error = RBXRotationSecretError(errSecParam); return NO; }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:
        @{@"formatVersion": @1, @"profileId": identifier, @"override": override}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        [query addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    if (status != errSecSuccess) { if (error) *error = RBXRotationSecretError(status); return NO; }
    NSError *readError = nil;
    NSDictionary *observed = [self overrideForProfile:identifier error:&readError];
    if (readError || ![observed isEqual:override]) {
        if (error) *error = readError ?: RBXRotationSecretError(errSecDecode); return NO;
    }
    return YES;
}

+ (BOOL)removeProfile:(NSString *)identifier error:(NSError **)error {
    NSMutableDictionary *query = RBXRotationSecretQuery(identifier, error);
    if (!query) return NO;
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) *error = RBXRotationSecretError(status); return NO;
    }
    NSError *readError = nil;
    NSDictionary *remaining = [self overrideForProfile:identifier error:&readError];
    if (remaining || readError) { if (error) *error = readError ?: RBXRotationSecretError(errSecDuplicateItem); return NO; }
    return YES;
}

+ (NSDictionary *)migrateLegacyProfile:(NSDictionary *)profile error:(NSError **)error {
    NSDictionary *proxy = [profile[@"proxy"] isKindOfClass:NSDictionary.class] ? profile[@"proxy"] : nil;
    if (proxy[@"rotationAuthHeader"] || proxy[@"rotationAuthValue"]) {
        NSString *identifier = profile[@"containerId"];
        NSError *readError = nil;
        NSDictionary *existing = [self overrideForProfile:identifier error:&readError];
        if (readError) { if (error) *error = readError; return nil; }
        if (!existing) {
            NSDictionary *legacy = @{@"header": proxy[@"rotationAuthHeader"] ?: @"Authorization",
                @"value": proxy[@"rotationAuthValue"] ?: @""};
            if (![self saveOverride:legacy profile:identifier error:error]) return nil;
        }
    }
    return RBXProfileForTransport(profile);
}
@end
