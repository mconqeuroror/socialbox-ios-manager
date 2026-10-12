#import <Foundation/Foundation.h>

@interface RBXRotationSecrets : NSObject
// nil + no error means no stored override. An empty dictionary is an explicit
// clear and prevents an old plaintext copy from being migrated back into use.
+ (NSDictionary *)overrideForProfile:(NSString *)identifier error:(NSError **)error;
+ (BOOL)saveOverride:(NSDictionary *)override profile:(NSString *)identifier error:(NSError **)error;
+ (BOOL)removeProfile:(NSString *)identifier error:(NSError **)error;
+ (NSDictionary *)migrateLegacyProfile:(NSDictionary *)profile error:(NSError **)error;
@end
