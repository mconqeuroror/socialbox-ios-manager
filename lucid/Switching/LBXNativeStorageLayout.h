#import <Foundation/Foundation.h>
@class LBXNativeStorageInventory;
NS_ASSUME_NONNULL_BEGIN

// Converts an authoritative read-only inventory into a storage protection plan.
// It does not change permissions or authorize launch. Default (CID 0) owns the
// ordinary root/Library entries; numbered stores retain their observed IDs.
@interface LBXNativeStorageLayout : NSObject
+ (nullable instancetype)layoutForInventory:(LBXNativeStorageInventory *)inventory error:(NSError **)error;
@property(nonatomic, readonly, copy) NSDictionary *privateDictionary;
@property(nonatomic, readonly, copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
#if LBX_NATIVE_STORAGE_LAYOUT_TESTING
@interface LBXNativeStorageLayout (Testing)
+ (nullable instancetype)testLayoutForSnapshot:(NSDictionary *)snapshot error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
