#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface RBXLicenseToken : NSObject
+ (NSString *)fingerprint:(NSString *)value;
+ (nullable NSString *)canonicalServer:(NSString *)server;
+ (nullable NSDictionary *)verifyToken:(NSString *)token expected:(NSDictionary *)expected
    nonce:(nullable NSString *)nonce now:(NSTimeInterval)now error:(NSError **)error;
// Explicit public-key injection supports native test vectors. Production Guard
// calls the pinned overload above, never accepts a key from a response or plist.
+ (nullable NSDictionary *)verifyToken:(NSString *)token publicKeyDER:(NSData *)key
    keyID:(NSString *)keyID expected:(NSDictionary *)expected nonce:(nullable NSString *)nonce
    now:(NSTimeInterval)now error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
