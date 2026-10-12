#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// One SocialBox cloud exchange, not an authorization grant for recovered code.
// No network, storage, original-app calls, offline cache or admission side effects.
@interface LBXLicenseExchange : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
+ (nullable instancetype)exchangeWithConfiguration:(NSDictionary *)configuration
    claim:(BOOL)claim error:(NSError **)error;
// Send only using an ephemeral HTTPS session that refuses ALL redirects and
// cookies. The caller owns transport, cancellation and durable private storage.
@property(nonatomic, readonly, copy) NSURLRequest *request;
- (void)cancel;
// Consumes this exchange exactly once, including errors. Re-read configuration
// from its trusted owner before calling on that owner's serialized operation.
// The owner must recheck its actual configuration/revision, cancellation and
// expiry before any durable pairing/admission: this object cannot observe a
// replacement configuration object that the owner has not supplied. A final
// check of the supplied snapshot is not a global atomic authorization commit.
// No reply is persisted here.
// Result contains credentials: NEVER log/share it or treat it as engine readiness.
- (nullable NSDictionary *)consumeResponse:(NSHTTPURLResponse *)response data:(NSData *)data
    currentConfiguration:(NSDictionary *)configuration error:(NSError **)error;
- (NSDictionary *)safeStatus;
@end

#if LBX_LICENSE_EXCHANGE_TESTING
@interface LBXLicenseExchange (Testing)
+ (nullable instancetype)testExchangeWithConfiguration:(NSDictionary *)configuration
    claim:(BOOL)claim publicKeyDER:(NSData *)key keyID:(NSString *)keyID error:(NSError **)error;
// Deterministic native test seam. Resets the start instant to this clock;
// the one-shot checkpoint runs after initial response admission, before verify.
- (void)testUseClock:(NSTimeInterval (^)(BOOL uptime))clock
    beforeVerification:(nullable void (^)(void))checkpoint;
@end
#endif
NS_ASSUME_NONNULL_END
