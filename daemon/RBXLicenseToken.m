#import "RBXLicenseToken.h"
#import "RBXLicensePin.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSError *RBXTokenError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.license-token" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSData *RBXTokenDecode(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length || value.length % 4 == 1 ||
        [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet]].location != NSNotFound) return nil;
    NSMutableString *base = [[[value stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
        stringByReplacingOccurrencesOfString:@"_" withString:@"/"] mutableCopy];
    while (base.length % 4) [base appendString:@"="];
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:base options:0];
    NSString *canonical = [[[decoded base64EncodedStringWithOptions:0]
        stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    canonical = [canonical stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return [canonical isEqual:value] ? decoded : nil;
}
static BOOL RBXTokenInteger(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == floor([value doubleValue]) &&
        [value doubleValue] >= 0 && [value doubleValue] < 9007199254740992.0;
}
@implementation RBXLicenseToken
+ (NSString *)fingerprint:(NSString *)value {
    NSData *bytes = [value dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [hex appendFormat:@"%02x", digest[index]];
    return hex;
}
+ (NSString *)canonicalServer:(NSString *)server {
    if (![server isKindOfClass:NSString.class]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:
        [server stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if (![parts.scheme.lowercaseString isEqual:@"https"] || !parts.host.length || parts.user || parts.password ||
        parts.query || parts.fragment || (parts.path.length && ![parts.path isEqual:@"/"]) ||
        (parts.port && (parts.port.integerValue < 1 || parts.port.integerValue > 65535))) return nil;
    parts.scheme = @"https"; parts.host = parts.host.lowercaseString; parts.path = @"";
    if (parts.port.integerValue == 443) parts.port = nil;
    return parts.URL.absoluteString;
}
+ (NSDictionary *)verifyToken:(NSString *)token expected:(NSDictionary *)expected
    nonce:(NSString *)nonce now:(NSTimeInterval)now error:(NSError **)error {
    NSData *key = [[NSData alloc] initWithBase64EncodedString:@RBX_LICENSE_PUBLIC_KEY_DER_BASE64 options:0];
    if (!key.length || ![@RBX_LICENSE_KEY_ID length]) {
        if (error) *error = RBXTokenError(@"This build has no deployment license public-key pin"); return nil;
    }
    return [self verifyToken:token publicKeyDER:key keyID:@RBX_LICENSE_KEY_ID expected:expected nonce:nonce now:now error:error];
}
+ (NSDictionary *)verifyToken:(NSString *)token publicKeyDER:(NSData *)key keyID:(NSString *)keyID
    expected:(NSDictionary *)expected nonce:(NSString *)nonce now:(NSTimeInterval)now error:(NSError **)error {
    if (![token isKindOfClass:NSString.class] || token.length > 16384 || !isfinite(now) || now <= 0) {
        if (error) *error = RBXTokenError(@"License token or device time is invalid"); return nil;
    }
    NSArray *parts = [token componentsSeparatedByString:@"."];
    if (parts.count != 3) { if (error) *error = RBXTokenError(@"License token is not a signed JWT"); return nil; }
    NSData *headerData = RBXTokenDecode(parts[0]), *payloadData = RBXTokenDecode(parts[1]), *signature = RBXTokenDecode(parts[2]);
    NSDictionary *header = headerData ? [NSJSONSerialization JSONObjectWithData:headerData options:0 error:nil] : nil;
    NSDictionary *claims = payloadData ? [NSJSONSerialization JSONObjectWithData:payloadData options:0 error:nil] : nil;
    if (![header isKindOfClass:NSDictionary.class] || ![claims isKindOfClass:NSDictionary.class] ||
        ![header[@"alg"] isEqual:@"RS256"] || ![header[@"typ"] isEqual:@"JWT"] ||
        ![header[@"kid"] isEqual:keyID] || header[@"crit"] || header[@"jku"] || header[@"jwk"] ||
        !key.length || !signature.length) {
        if (error) *error = RBXTokenError(@"License signature format or pinned key ID is invalid"); return nil;
    }
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(key.bytes, (CC_LONG)key.length, hash);
    NSMutableString *keyHash = [NSMutableString string];
    for (NSUInteger index = 0; index < sizeof(hash); index++) [keyHash appendFormat:@"%02x", hash[index]];
    if (![keyHash isEqual:keyID]) { if (error) *error = RBXTokenError(@"License public-key pin is inconsistent"); return nil; }
    CFErrorRef keyError = NULL;
    SecKeyRef publicKey = SecKeyCreateWithData((__bridge CFDataRef)key, (__bridge CFDictionaryRef)@{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic}, &keyError);
    if (keyError) CFRelease(keyError);
    if (!publicKey) { if (error) *error = RBXTokenError(@"License public key cannot be imported"); return nil; }
    NSData *message = [[NSString stringWithFormat:@"%@.%@", parts[0], parts[1]] dataUsingEncoding:NSASCIIStringEncoding];
    BOOL valid = SecKeyGetBlockSize(publicKey) >= 256 && SecKeyVerifySignature(publicKey,
        kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, (__bridge CFDataRef)message,
        (__bridge CFDataRef)signature, NULL);
    CFRelease(publicKey);
    if (!valid) { if (error) *error = RBXTokenError(@"License signature verification failed"); return nil; }
    for (NSString *field in @[@"server", @"deviceId", @"deviceBinding", @"keyFingerprint"]) {
        if (![expected[field] isKindOfClass:NSString.class] || ![expected[field] length]) {
            if (error) *error = RBXTokenError(@"License device or deployment binding is incomplete"); return nil;
        }
    }
    if (!RBXTokenInteger(claims[@"v"]) || ![claims[@"v"] isEqual:@1] || ![claims[@"aud"] isEqual:@"redditbox-device"] ||
        ![claims[@"iss"] isEqual:expected[@"server"]] || ![claims[@"sub"] isEqual:expected[@"deviceId"]] ||
        ![claims[@"deviceBinding"] isEqual:expected[@"deviceBinding"]] ||
        ![claims[@"keyFingerprint"] isEqual:expected[@"keyFingerprint"]] ||
        (nonce && ![claims[@"nonce"] isEqual:nonce]) ||
        ![@[@"active", @"revoked", @"expired", @"invalid"] containsObject:claims[@"status"]] ||
        !RBXTokenInteger(claims[@"iat"]) || !RBXTokenInteger(claims[@"exp"]) ||
        [claims[@"iat"] doubleValue] <= 0 || [claims[@"iat"] doubleValue] > now + 120 ||
        ([claims[@"status"] isEqual:@"active"] && [claims[@"exp"] doubleValue] <= [claims[@"iat"] doubleValue]) ||
        [claims[@"exp"] doubleValue] > [claims[@"iat"] doubleValue] + 72 * 3600) {
        if (error) *error = RBXTokenError(@"License claims, request nonce, expiry or device binding do not match"); return nil;
    }
    return claims; // Signed denials and elapsed expiries remain readable diagnostics.
}
@end
