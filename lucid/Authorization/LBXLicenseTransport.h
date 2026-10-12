#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Own HTTPS transport for the signed SocialBox exchange. A verified receipt is
// not admission to the retained engine. Pairing/storage/admission remain owned
// by the caller, which must recheck its operation before committing a receipt.
@interface LBXLicenseTransport : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
// The provider runs on the private serial delegate queue. It must return a
// thread-safe snapshot of current trusted configuration, never server fields.
// Completion runs once on that queue; response dictionaries contain secrets.
+ (nullable instancetype)startWithConfiguration:(NSDictionary *)configuration
    claim:(BOOL)claim currentConfiguration:(NSDictionary * _Nullable (^)(void))provider
    completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion
    error:(NSError **)error;
- (void)cancel;
- (NSDictionary *)safeStatus;
@end

#if LBX_LICENSE_TRANSPORT_TESTING
@interface LBXLicenseTransport (Testing)
+ (nullable instancetype)testStartWithConfiguration:(NSDictionary *)configuration
    claim:(BOOL)claim currentConfiguration:(NSDictionary * _Nullable (^)(void))provider
    protocolClass:(Class)protocolClass publicKeyDER:(NSData *)key keyID:(NSString *)keyID
    completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion
    error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
