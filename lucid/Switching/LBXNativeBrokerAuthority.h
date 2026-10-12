#import <Foundation/Foundation.h>
#include <mach/message.h>
NS_ASSUME_NONNULL_BEGIN
@class LBXNativeIsolationJournal, LBXNativeBrokerCodeBinding, LBXNativeBrokerProcess;
FOUNDATION_EXPORT double LBXNativeBrokerClock(void);

// Immutable root-observed registration and code bytes. Supports only official
// Instagram/Facebook and their exact registered embedded executables. Capture
// after code admission; observation never creates a container assignment.
@interface LBXNativeBrokerCodeBinding : NSObject
+ (nullable instancetype)observeApplication:(NSString *)bundleID error:(NSError **)error;
- (BOOL)matchesCurrentCode:(NSError **)error;
@property(nonatomic,readonly,copy) NSString *applicationID;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// The token must come from the kernel message or root launch observer. The root
// independently checks the same token, birth and registered executable before
// and after verification. No dictionary/path/PID constructor exists.
@interface LBXNativeBrokerProcess : NSObject
+ (nullable instancetype)observeAuditToken:(audit_token_t)token
                             codeBinding:(LBXNativeBrokerCodeBinding *)binding error:(NSError **)error;
- (BOOL)matchesCurrentProcess:(NSError **)error;
@property(nonatomic,readonly,copy) NSString *applicationID;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface LBXNativeBrokerEpoch : NSObject
@property(nonatomic,readonly,copy) NSString *containerID;
@property(nonatomic,readonly,copy) NSString *epochID;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

@interface LBXNativeBrokerLease : NSObject
@property(nonatomic,readonly,copy) NSString *containerID;
@property(nonatomic,readonly,copy) NSString *epochID;
@property(nonatomic,readonly,copy) NSString *applicationID;
@property(nonatomic,readonly,copy) NSString *leaseID;
// Explicit completion only. Dropping a lease does not assert an asynchronous
// broker operation has ended; a lost lease keeps the close barrier unsatisfied.
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// Dedicated child journal only: never share the storage-fence journal. Every
// restart durably closes admission; prior assignments remain lifetime
// tombstones. The coordinator binds this child's inode and epoch in its own
// transaction. This component alone does not fence files, launches or brokers.
@interface LBXNativeBrokerAuthority : NSObject
+ (nullable instancetype)openJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error;
- (nullable LBXNativeBrokerEpoch *)prepareContainerID:(NSString *)containerID
                                      beforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)admitEpoch:(LBXNativeBrokerEpoch *)epoch beforeDeadline:(double)deadline
    authorization:(BOOL (^)(void))authorization error:(NSError **)error;
// Coordinator-only launch assignment. The authorization callback must verify
// committed storage/selection, the exact launch observation and this epoch.
// An existing process can never be relabelled, including after restart.
- (BOOL)assignVerifiedLaunch:(LBXNativeBrokerProcess *)process epoch:(LBXNativeBrokerEpoch *)epoch
             beforeDeadline:(double)deadline authorization:(BOOL (^)(void))authorization error:(NSError **)error;
- (nullable LBXNativeBrokerLease *)beginRequestForProcess:(LBXNativeBrokerProcess *)process
                                        beforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)endRequest:(LBXNativeBrokerLease *)lease error:(NSError **)error;
// Closing admission is immediate. Waiting is a separate bounded operation on
// the coordinator queue; never wait on a broker's IPC/completion queue. Lease
// completion needs no journal/control lock and can always make progress.
- (BOOL)closeAdmissionBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)waitForLeasesBeforeDeadline:(double)deadline error:(NSError **)error;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_BROKER_TESTING
@interface LBXNativeBrokerCodeBinding (Testing)
+ (nullable instancetype)testObserveApplication:(NSString *)bundleID executable:(NSString *)path error:(NSError **)error;
@end
@interface LBXNativeBrokerProcess (Testing)
+ (void)testSetKernelObservation:(nullable NSDictionary *(^)(audit_token_t token))observer;
+ (void)testSetBootIdentity:(nullable NSString *)boot;
@end
@interface LBXNativeBrokerAuthority (Testing)
+ (nullable instancetype)testOpenJournal:(LBXNativeIsolationJournal *)journal error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
