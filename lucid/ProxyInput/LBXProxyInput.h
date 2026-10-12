#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// A local input plan, never a connection test or an isolation/admission grant.
// Endpoint records contain credentials; description/safeStatus redact them.
@interface LBXProxyInputPlan : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic, readonly) BOOL useOriginalInput;
@property(nonatomic, readonly, copy, nullable) NSString *issue;
@property(nonatomic, readonly, copy) NSArray<NSDictionary *> *endpoints;
- (NSDictionary *)safeStatus;
@end
FOUNDATION_EXPORT LBXProxyInputPlan *LBXPlanProxyInput(id input);
// Only the pinned original ProxyViewController methods in the main executable
// are called. Checks the whole plan before the first add, then preserves each
// original method's error/reporting behavior. Backend writes are NOT atomic.
FOUNDATION_EXPORT BOOL LBXDispatchProxyInput(id receiver, LBXProxyInputPlan *plan, NSError **error);
NS_ASSUME_NONNULL_END
