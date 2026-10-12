#import <Foundation/Foundation.h>
@class LBXLicenseVault;
NS_ASSUME_NONNULL_BEGIN
// Called only after the service authenticates the kernel audit token. This
// owner never receives a client-supplied receipt or installation identity.
@interface LBXLicenseOwner : NSObject
- (instancetype)initWithVault:(LBXLicenseVault *)vault;
- (void)handleRequest:(NSDictionary *)request completion:(void (^)(NSDictionary *))completion;
// Instantaneous internal check for buildable source-owned consumers. Recheck
// under the caller's operation/launch fence before each protected side effect.
// No transferable permit, recovered-engine flag or offline authorization.
// New owners start closed; any online attempt closes the previous assessment.
- (BOOL)sourceAuthorizationCurrent;
// Narrow synchronous-context check for trusted root-local consumers already
// inside THIS owner's performSourceOperation block. The deadline must exactly
// match that active fence; another queue, owner, thread or deadline is refused.
// This starts no operation and provides no transferable or lasting grant.
- (BOOL)sourceOperationCurrentBeforeDeadline:(NSTimeInterval)deadline;
// Exact in-process assembly only; not a grant or pairing-status projection.
- (BOOL)usesVault:(LBXLicenseVault *)vault;
// Immutable PRIVATE installation context, only on this owner's active source
// queue/fence and exact deadline with a fresh signed paired admission. Production
// requires real/effective UID0. No credentials, changing revision or state-file
// inode is returned. Never serialize/log/export this context or accept it from
// a client as authority; reobserve it before every protected effect.
- (nullable NSDictionary *)sourcePairingContextBeforeDeadline:(NSTimeInterval)deadline error:(NSError **)error;
// Trusted in-process consumer only; never expose a caller-selected block via IPC.
// Synchronously runs one short, bounded effect on the owner's serial queue.
// beforeDeadline is an absolute LBXLicenseIPCClock() deadline, at most 25 seconds
// away when submitted; waiting does not renew it. Reentrant calls are rejected.
// Live signed admission and the deadline are checked immediately before calling
// the effect and again before reporting success. The effect must not escape,
// start asynchronous work, wait for this owner, or assume a lifetime grant.
// A failed final check cannot undo an effect already performed: the integrating
// consumer still owns rollback, ongoing process/traffic closure and recovery.
// This API does not cancel a handler or impose a hard queue-wait watchdog.
// A handler failure/exception or failed final check closes admission; revalidate
// before retrying. A trusted handler's NSError is private in-process data and
// must not be forwarded verbatim to mobile IPC, logs or exported diagnostics.
- (BOOL)performSourceOperation:(BOOL (^ _Nullable)(NSError * _Nullable * _Nullable))operation
    beforeDeadline:(NSTimeInterval)deadline error:(NSError * _Nullable * _Nullable)error;
@end
#if LBX_LICENSE_OWNER_TESTING
@interface LBXLicenseOwner (Testing)
- (void)testUseProtocol:(Class)protocol publicKey:(NSData *)key keyID:(NSString *)keyID;
- (void)testUseAuthorizationClock:(NSTimeInterval (^)(BOOL continuous))clock;
@end
#endif
NS_ASSUME_NONNULL_END
