#import <Foundation/Foundation.h>
@class LBXNativeStorageLayout;
NS_ASSUME_NONNULL_BEGIN

// Combines official Instagram and Facebook storage plans. Shared family
// containers are the intersection of observed CIDs. This is not a fence,
// launch grant or isolation claim.
@interface LBXNativeFamilyStorageLayout : NSObject
+ (nullable instancetype)layoutWithInstagram:(LBXNativeStorageLayout *)instagram
                                   facebook:(LBXNativeStorageLayout *)facebook
                                      error:(NSError **)error;
- (BOOL)allowsContainerID:(NSString *)containerID error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
NS_ASSUME_NONNULL_END
