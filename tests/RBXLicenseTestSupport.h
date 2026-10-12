#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import "../daemon/RBXLicenseToken.h"

static SecKeyRef TestLicensePrivateKey(void) {
    static SecKeyRef privateKey; static dispatch_once_t once;
    dispatch_once(&once, ^{
        privateKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)@{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
            (__bridge id)kSecAttrKeySizeInBits: @2048}, NULL);
        NSCAssert(privateKey, @"Could not generate temporary test signing key");
    });
    return privateKey;
}
static NSData *TestLicensePublicDER(void) {
    SecKeyRef key = SecKeyCopyPublicKey(TestLicensePrivateKey());
    NSData *data = CFBridgingRelease(SecKeyCopyExternalRepresentation(key, NULL));
    CFRelease(key); return data;
}
static NSString *TestLicenseKeyID(void) {
    NSData *data = TestLicensePublicDER(); unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
    NSMutableString *value = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(bytes); index++) [value appendFormat:@"%02x", bytes[index]];
    return value;
}
static NSString *TestLicenseEncode(NSData *data) {
    return [[[[data base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"=" withString:@""];
}
static NSString *TestLicenseJWT(NSDictionary *claims, NSDictionary *headerOverride) {
    NSMutableDictionary *header = [@{@"alg": @"RS256", @"typ": @"JWT", @"kid": TestLicenseKeyID()} mutableCopy];
    [header addEntriesFromDictionary:headerOverride ?: @{}];
    NSString *message = [NSString stringWithFormat:@"%@.%@",
        TestLicenseEncode([NSJSONSerialization dataWithJSONObject:header options:0 error:nil]),
        TestLicenseEncode([NSJSONSerialization dataWithJSONObject:claims options:0 error:nil])];
    NSData *signature = CFBridgingRelease(SecKeyCreateSignature(TestLicensePrivateKey(),
        kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
        (__bridge CFDataRef)[message dataUsingEncoding:NSASCIIStringEncoding], NULL));
    NSCAssert(signature, @"Test signature failed");
    return [message stringByAppendingFormat:@".%@", TestLicenseEncode(signature)];
}
static NSString *const TestLicenseIdentity = @"00000000-1111-4222-8333-444444444444";
static NSDictionary *TestLicenseExpected(NSString *key) {
    return @{@"server": @"https://license.example.test", @"deviceId": @"fixture-device",
        @"deviceBinding": [RBXLicenseToken fingerprint:TestLicenseIdentity],
        @"keyFingerprint": [RBXLicenseToken fingerprint:key.length ? key : @"admin:fixture-device"]};
}
static NSMutableDictionary *TestLicenseClaims(NSString *key, NSString *nonce, NSTimeInterval now) {
    NSDictionary *expected = TestLicenseExpected(key);
    return [@{@"v": @1, @"aud": @"redditbox-device", @"iss": expected[@"server"],
        @"sub": expected[@"deviceId"], @"deviceBinding": expected[@"deviceBinding"],
        @"keyFingerprint": expected[@"keyFingerprint"], @"status": @"active",
        @"iat": @((long long)now), @"exp": @((long long)now + 72 * 3600), @"nonce": nonce} mutableCopy];
}
