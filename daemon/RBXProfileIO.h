#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const RBXProfileIOErrorDomain;
typedef NS_ENUM(NSInteger, RBXProfileIOErrorCode) {
    RBXProfileIOInvalidIdentifier = 1,
    RBXProfileIOMissing = 2,
    RBXProfileIORead = 3,
    RBXProfileIOEmpty = 4,
    RBXProfileIOParse = 5,
    RBXProfileIORoot = 6,
    RBXProfileIOSection = 7,
    RBXProfileIOIdentityMismatch = 8,
};

// Checked I/O and structural validation only. Policy validation and deletion
// reservations remain the caller's responsibility.
@interface RBXProfileIO : NSObject
+ (BOOL)isSafeContainerIdentifier:(id)value;
// Read only ownership metadata even if another profile section is corrupt.
+ (nullable NSDictionary *)readProfileOwnershipForContainer:(NSString *)containerId error:(NSError **)error;
+ (nullable NSDictionary *)loadProfileForContainer:(NSString *)containerId error:(NSError **)error;
+ (nullable NSDictionary *)profileDictionaryFromData:(NSData *)data containerId:(NSString *)containerId error:(NSError **)error;
+ (BOOL)writeProfile:(NSDictionary *)profile containerId:(NSString *)containerId toPath:(NSString *)path error:(NSError **)error;
+ (nullable NSDictionary *)readJSONDictionaryAtPath:(NSString *)path error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
