#import <Foundation/Foundation.h>
#import "../../shared/RBXProcessIdentity.h"
#import "LBXManagedApplications.h"

NS_ASSUME_NONNULL_BEGIN

// A registration snapshot produced by the privileged resolver, not a client
// supplied path allowlist. All executables include the main app or an embedded
// extension. The fingerprint changes when registration or bundle files change.
@interface LBXDrainTarget : NSObject
@property(nonatomic, copy) NSString *bundleID;
@property(nonatomic, copy) NSString *bundlePath;
@property(nonatomic, copy) NSArray<NSString *> *executables;
@property(nonatomic, copy) NSString *fingerprint;
@end

@interface LBXDrainProcess : NSObject
@property(nonatomic) RBXObservedProcess identity;
@end

@protocol LBXDrainBackend <NSObject>
- (nullable LBXDrainTarget *)resolve:(NSString *)bundleID error:(NSError **)error;
// A complete snapshot, or nil. An unreadable live process is NOT absence.
- (nullable NSArray<LBXDrainProcess *> *)snapshot:(NSError **)error;
- (RBXProcessIdentityResult)terminate:(RBXObservedProcess)identity;
- (double)monotonicTime;
- (BOOL)pause;
@end

// Serial synchronous operation for a future transaction owner, and the private
// device acceptance CLI. No subprocess, name/PID kill fallback, data mutation,
// launch prevention, network authority or reusable admission token is provided.
// Success is two complete absent observations, NOT a future-launch fence.
FOUNDATION_EXPORT NSDictionary *LBXDrainApplication(id<LBXDrainBackend> backend,
    NSString *bundleID, NSString *requestID, NSTimeInterval timeout, BOOL terminate);
NS_ASSUME_NONNULL_END
