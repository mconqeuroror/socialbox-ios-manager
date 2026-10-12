#import <Foundation/Foundation.h>
#import "RBXPFPolicyPlan.h"
#import "RBXPFKernelABI.h"

NS_ASSUME_NONNULL_BEGIN
typedef NS_ENUM(NSUInteger, RBXPFKernelMode) { RBXPFKernelEmpty, RBXPFKernelClosed, RBXPFKernelProxy };

// Compiler and readback only; neither opens /dev/pf nor installs a policy.
// These images may be consumed by a future independently supervised writer.
@interface RBXPFKernelPolicy : NSObject
@property(nonatomic,readonly,copy) NSArray<NSData *> *closedRuleImages;
@property(nonatomic,readonly,copy) NSArray<NSData *> *proxyRuleImages;
@property(nonatomic,readonly,copy) NSString *closedDigest;
@property(nonatomic,readonly,copy) NSString *proxyDigest;
+ (nullable instancetype)policyWithPlan:(RBXPFPolicyPlan *)plan error:(NSError **)error;
- (BOOL)matchesImages:(NSArray<NSData *> *)images mode:(RBXPFKernelMode)mode creatorPID:(pid_t)pid;
@end

// A reviewed transport performs one ioctl. Tests supply an inert transport.
// Kernel pointers/counters are never emitted in a successful summary.
typedef int (^RBXPFReadIO)(unsigned long command,void *argument);
typedef double (^RBXPFMonotonicClock)(void);
@interface RBXPFKernelReader : NSObject
- (instancetype)initWithIO:(RBXPFReadIO)io clock:(RBXPFMonotonicClock)clock;
// Two complete bounded observations must agree. Still NOT an atomic kernel
// transaction, physical traffic proof, source-app attribution or launch grant.
// Empty mode requires disabled PF with no rules/anchors/states/source nodes.
// Closed/proxy mode requires enabled PF and exact compiled rules/creator PID.
- (nullable NSDictionary *)verifyPolicy:(nullable RBXPFKernelPolicy *)policy
                                  mode:(RBXPFKernelMode)mode creatorPID:(pid_t)pid
                       requireNoStates:(BOOL)requireNoStates error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
