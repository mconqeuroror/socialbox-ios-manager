#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@class LBXNativeIsolationJournal;
FOUNDATION_EXPORT double LBXNativeControlClock(void);

// Durable per-app native selection for official Instagram and Facebook only.
// Stores container IDs and shared-group identity (device/inode), never account
// bytes or control-plist contents. A shared family group may admit one CID.
@interface LBXNativeControlStore : NSObject
+ (nullable instancetype)openJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error;
- (nullable NSString *)selectedContainerIDForApplication:(NSString *)applicationID error:(NSError **)error;
- (BOOL)commitContainerID:(NSString *)containerID
            applicationID:(NSString *)applicationID
      familyGroupIdentity:(NSDictionary *)identity
           beforeDeadline:(double)deadline
            authorization:(BOOL (^)(void))authorization
                    error:(NSError **)error;
// One journal write. Every listed app receives the same CID. A peer that already
// shares this family identity with a different CID must be included; otherwise
// the commit is refused so Instagram/Facebook cannot split the group.
- (BOOL)commitContainerID:(NSString *)containerID
          applicationIDs:(NSArray<NSString *> *)applicationIDs
      familyGroupIdentity:(NSDictionary *)identity
           beforeDeadline:(double)deadline
            authorization:(BOOL (^)(void))authorization
                    error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_CONTROL_STORE_TESTING
@interface LBXNativeControlStore (Testing)
+ (nullable instancetype)testOpenJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
