#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class LBXNativeIsolationJournal;

// Root-only, read-only inventory for the installed original Instagram or Facebook engine.
// Lists shallow directory entries and stat metadata, never account file bytes.
// This is an observation, not permission to switch, chmod, launch or admit traffic.
@interface LBXNativeStorageInventory : NSObject
+ (nullable instancetype)observeOfficialInstagram:(NSError **)error;
+ (nullable instancetype)observeOfficialFacebook:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *privateDictionary;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
// Re-queries only LS registrations against the saved installed component map.
// No executable X_OK, permission rescan, grant or launch authority is involved.
- (BOOL)matchesCurrentRegistration:(NSError **)error;
// Closure recovery only. Reconstitutes the root journal's prior observation
// after validating its held lock/record and current LS registration. The gate
// must separately validate original installation/inodes against its journal.
+ (nullable instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_STORAGE_INVENTORY_TESTING
@interface LBXNativeStorageInventory (Testing)
+ (nullable instancetype)testObserveRegistration:(NSDictionary *)registration
                                  installation:(NSDictionary *)installation
                                      dataRoot:(NSString *)dataRoot
                                     groupRoot:(NSString *)groupRoot
                                    afterScan:(nullable void (^)(void))afterScan
                                         error:(NSError **)error;
- (BOOL)testMatchesRegistration:(NSDictionary *)registration error:(NSError **)error;
+ (NSDictionary *)testClassifySnapshot:(NSDictionary *)snapshot metadata:(NSDictionary *)metadata;
@end
#endif
NS_ASSUME_NONNULL_END
