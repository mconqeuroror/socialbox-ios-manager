#import <Foundation/Foundation.h>
@interface RBXProxyLibrary : NSObject
+ (NSArray<NSDictionary *> *)entries:(NSError **)error;
+ (NSString *)selectedIdentifier:(NSError **)error;
+ (NSString *)normalizedURL:(NSString *)input;
+ (BOOL)saveEntry:(NSDictionary *)entry error:(NSError **)error;
+ (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error;
+ (BOOL)deleteIdentifier:(NSString *)identifier error:(NSError **)error;
// The preview is private, ephemeral UI state: it includes proxy credentials.
// No write, selection, network request or clipboard read occurs during parsing.
+ (NSDictionary *)importPreviewForText:(NSString *)text error:(NSError **)error;
// Revalidates the reviewed preview against the current library, then stores all
// new rows in one secure-record update. Does not select or test an imported row.
+ (BOOL)importText:(NSString *)text reviewedPreview:(NSDictionary *)preview error:(NSError **)error;
@end
