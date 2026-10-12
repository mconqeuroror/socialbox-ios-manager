#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RBXSecureConfig : NSObject

// Private, expiring per-request cloud UI channel. Never stored in IPC receipts.
+ (BOOL)saveCloudVaultPayload:(NSDictionary *)payload identifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error;
+ (nullable NSDictionary *)cloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error;
+ (void)clearCloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response;
+ (NSString *)accessGroup;
+ (nullable NSDictionary *)rotationConfiguration:(NSError **)error;
+ (NSDictionary *)effectiveRotationConfiguration:(nullable NSDictionary *)configuration;
+ (BOOL)saveRotationConfiguration:(NSDictionary *)configuration
                             error:(NSError **)error;
+ (BOOL)clearRotationConfiguration:(NSError **)error;
+ (nullable NSString *)accessKey:(NSError **)error;
+ (BOOL)saveAccessKey:(NSString *)accessKey error:(NSError **)error;
+ (NSDictionary *)safeSummary;
// One bounded, request-bound editor draft in a separate private Keychain item.
+ (BOOL)saveIdentityEditorDraft:(NSDictionary *)draft requestID:(NSString *)requestID error:(NSError **)error;
+ (nullable NSDictionary *)identityEditorDraftForRequestID:(NSString *)requestID container:(NSString *)container error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
