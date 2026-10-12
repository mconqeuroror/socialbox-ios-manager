#import <Foundation/Foundation.h>
@class LBXNativeStorageInventory,LBXNativeApplicationGate,LBXNativeIsolationJournal;
NS_ASSUME_NONNULL_BEGIN

// Privileged transaction component for native Instagram or Facebook data. Captures exact
// inodes from an observed inventory, journals originals before permission
// effects, drains through the captured execution gate, and freezes namespaces.
// It never invokes the old engine or treats its callback as switch completion.
@interface LBXNativeStorageFence : NSObject
+ (nullable instancetype)captureInventory:(LBXNativeStorageInventory *)inventory
                         applicationGate:(LBXNativeApplicationGate *)gate
                                 journal:(LBXNativeIsolationJournal *)journal error:(NSError **)error;
+ (nullable instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal
                             beforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)closeAllBeforeDeadline:(double)deadline error:(NSError **)error;
// authorization must validate the caller's current durable native selection.
// Opening data does not restore execution. All default roots stay closed for
// nonzero CIDs; only observed numbered roots bearing that exact CID open.
- (BOOL)openContainerID:(NSString *)containerID beforeDeadline:(double)deadline
         authorization:(BOOL (^)(void))authorization error:(NSError **)error;
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline
                        authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end
#if LBX_NATIVE_STORAGE_FENCE_TESTING
@interface LBXNativeStorageFence (Testing)
+ (void)testUseRoot:(NSString *)root;
// Host fixtures retain descriptors before closing mode0000; production UID0
// opens directly without changing permissions. Returned fixture FD is borrowed.
+ (void)testSetReopenDescriptor:(nullable int (^)(NSString *path))provider;
+ (void)testSetCheckpoint:(nullable void (^)(NSString *stage))checkpoint;
@end
#endif
NS_ASSUME_NONNULL_END
