#import <Foundation/Foundation.h>
@class LBXNativeIsolationJournal, LBXNativeBrokerAuthority, LBXNativeControlStore, LBXNativeFamilyStorageLayout, LBXNativeControlLayout, LBXNativeFamilyApplicationGate;
@protocol LBXDrainBackend;
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT double LBXNativeSwitchClock(void);

@protocol LBXNativeSwitchFence <NSObject>
- (BOOL)closeAllBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)openContainerID:(NSString *)containerID beforeDeadline:(double)deadline
         authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@end

// Source-owned switch transaction for official Instagram/Facebook only.
// Close broker admission, drain every listed app, commit one family CID, then
// open every attached storage fence. Missing drain backend, missing Facebook
// fence, Twitter, create/delete or a non-absent drain cannot succeed.
@interface LBXNativeSwitchCoordinator : NSObject
+ (nullable instancetype)openJournal:(LBXNativeIsolationJournal *)journal
                             broker:(LBXNativeBrokerAuthority *)broker
                              store:(LBXNativeControlStore *)store
                              error:(NSError **)error;
- (BOOL)attachFamilyLayout:(LBXNativeFamilyStorageLayout *)layout error:(NSError **)error;
- (BOOL)attachControlLayout:(LBXNativeControlLayout *)layout error:(NSError **)error;
- (BOOL)attachFamilyApplicationGate:(LBXNativeFamilyApplicationGate *)gate error:(NSError **)error;
- (BOOL)attachDrainBackend:(id<LBXDrainBackend>)backend
                    fences:(NSDictionary<NSString *, id<LBXNativeSwitchFence>> *)fences
                     error:(NSError **)error;
- (BOOL)switchToContainerID:(NSString *)containerID
            applicationIDs:(NSArray<NSString *> *)applicationIDs
      familyGroupIdentity:(NSDictionary *)identity
                    nonce:(NSString *)nonce
           beforeDeadline:(double)deadline
            authorization:(BOOL (^)(void))authorization
                    error:(NSError **)error;
- (BOOL)refuseUnsupportedOperation:(NSString *)operation error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_SWITCH_COORDINATOR_TESTING
@interface LBXNativeSwitchCoordinator (Testing)
+ (nullable instancetype)testOpenJournal:(LBXNativeIsolationJournal *)journal
                                 broker:(LBXNativeBrokerAuthority *)broker
                                  store:(LBXNativeControlStore *)store
                                  error:(NSError **)error;
- (void)testSetDrain:(nullable BOOL (^)(NSArray<NSString *> *applicationIDs, NSError **error))drain;
- (void)testSetFence:(nullable BOOL (^)(NSString *containerID, NSError **error))fence;
@end
#endif
NS_ASSUME_NONNULL_END
