#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonHMAC.h>

// Only daemon code knows the raw boot epoch. Each clone receives a distinct
// restart token, so its own readable control files cannot link sibling profiles.
static NSString *RBXEpochForClone(NSString *bootEpoch, NSString *bundle) {
    if (![bootEpoch isKindOfClass:NSString.class] || !bootEpoch.length ||
        ![bundle isKindOfClass:NSString.class] || !bundle.length) return nil;
    NSData *key = [bootEpoch dataUsingEncoding:NSUTF8StringEncoding];
    NSData *message = [[@"redditbox-clone-epoch-v1:" stringByAppendingString:bundle]
        dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:sizeof(digest) * 2];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [result appendFormat:@"%02x", digest[i]];
    return result;
}
