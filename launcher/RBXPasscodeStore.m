#import "RBXPasscodeStore.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString *const RBXPasscodeService = @"com.redditbox.launcher.passcode";
static NSString *const RBXPasscodeAccessGroup =
    @"RBXBOXCFG.com.redditbox.launcher";

static NSDictionary *RBXPasscodeQuery(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: RBXPasscodeService,
        (__bridge id)kSecAttrAccount: @"owner",
        (__bridge id)kSecAttrAccessGroup: RBXPasscodeAccessGroup,
    };
}

static NSData *RBXPasscodeDigest(NSString *passcode, NSData *salt) {
    NSMutableData *input = [salt mutableCopy];
    [input appendData:[passcode dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSDictionary *RBXPasscodeRecord(OSStatus *readStatus) {
    NSMutableDictionary *query = [RBXPasscodeQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (readStatus) *readStatus = status;
    if (status != errSecSuccess) {
        if (result) CFRelease(result);
        return nil;
    }
    id data = CFBridgingRelease(result);
    id record = [data isKindOfClass:NSData.class] ?
        [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    if (![record isKindOfClass:NSDictionary.class] ||
        ![record[@"salt"] isKindOfClass:NSData.class] || [record[@"salt"] length] != 16 ||
        ![record[@"digest"] isKindOfClass:NSData.class] || [record[@"digest"] length] != CC_SHA256_DIGEST_LENGTH) {
        if (readStatus) *readStatus = errSecDecode;
        return nil;
    }
    return record;
}

@implementation RBXPasscodeStore

+ (BOOL)hasPasscode {
    OSStatus status = errSecNotAvailable;
    RBXPasscodeRecord(&status);
    // Denied, unavailable or malformed storage cannot prove the gate is absent.
    return status != errSecItemNotFound;
}

+ (BOOL)verifyPasscode:(NSString *)passcode {
    NSDictionary *record = RBXPasscodeRecord(NULL);
    NSData *salt = record[@"salt"];
    NSData *expected = record[@"digest"];
    if (![salt isKindOfClass:[NSData class]] ||
        ![expected isKindOfClass:[NSData class]]) return NO;
    NSData *actual = RBXPasscodeDigest(passcode ?: @"", salt);
    if (actual.length != expected.length) return NO;
    const uint8_t *left = actual.bytes;
    const uint8_t *right = expected.bytes;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < actual.length; index++) {
        difference |= left[index] ^ right[index];
    }
    return difference == 0;
}

+ (BOOL)setPasscode:(NSString *)passcode error:(NSError **)error {
    if (passcode.length < 4 || passcode.length > 32) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.launcher"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"Passcode must contain 4–32 characters."}];
        return NO;
    }
    NSMutableData *salt = [NSMutableData dataWithLength:16];
    if (SecRandomCopyBytes(kSecRandomDefault, salt.length, salt.mutableBytes) != errSecSuccess) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.launcher"
            code:2 userInfo:@{NSLocalizedDescriptionKey: @"Cannot generate passcode salt."}];
        return NO;
    }
    NSDictionary *record = @{@"salt": salt, @"digest": RBXPasscodeDigest(passcode, salt)};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSDictionary *identity = RBXPasscodeQuery();
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    };
    // Keep the old gate intact if a replacement write is denied or fails.
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)identity,
        (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *add = [identity mutableCopy];
        [add addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
        if (status == errSecDuplicateItem) {
            // Another writer inserted the item after our not-found result.
            // Retry one update; never delete that writer's record on failure.
            status = SecItemUpdate((__bridge CFDictionaryRef)identity,
                (__bridge CFDictionaryRef)attributes);
        }
    }
    if (status != errSecSuccess && error) {
        *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    }
    return status == errSecSuccess;
}

+ (BOOL)clearPasscode:(NSError **)error {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)RBXPasscodeQuery());
    if (status == errSecSuccess || status == errSecItemNotFound) return YES;
    if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return NO;
}

@end
