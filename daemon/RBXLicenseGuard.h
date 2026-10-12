#import <Foundation/Foundation.h>
@class RBXOperationContext;
NS_ASSUME_NONNULL_BEGIN
@interface RBXLicenseGuard : NSObject
+ (instancetype)sharedGuard;
// Main owns scheduling and CLOSED enforcement on its serial transition queue.
- (void)start;
- (BOOL)isUnlocked;
// Fast lease-path queries: clocks and verified in-memory grant only; no I/O.
- (BOOL)trafficEntitlementValid;
- (NSTimeInterval)trafficEntitlementExpiresAt;
- (BOOL)validationDue;
- (NSDictionary *)safeStatus;
- (nullable NSString *)deviceIdentityWithContext:(RBXOperationContext *)context error:(NSError **)error;
- (void)activateWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString * _Nullable))done;
- (void)validateWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString * _Nullable))done;
- (void)validateAndThen:(void (^)(BOOL))done;
- (void)invalidatePendingValidation;
// Persists a lock only. Caller immediately closes traffic and stops clones.
- (BOOL)enforceLockWithContext:(RBXOperationContext *)context error:(NSError **)error;
- (void)enforceLock;
@end
NS_ASSUME_NONNULL_END
