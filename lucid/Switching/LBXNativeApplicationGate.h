#import <Foundation/Foundation.h>
#if LBX_NATIVE_APPLICATION_GATE_TESTING
#import "LBXProcessDrain.h"
#endif
NS_ASSUME_NONNULL_BEGIN
@class LBXNativeIsolationJournal;
FOUNDATION_EXPORT double LBXNativeApplicationGateClock(void);

// Root-service-only captured official Instagram or Facebook execution gate. No
// supplied path/PID/receipt/binding can create one. It changes only executable
// mode bits. The owning transaction must persist privateJournalRecord before
// close, keep storage/network closed, and supply fresh authorization when
// restoring code. A successful drain is process absence, not account/data/network
// isolation.
@interface LBXNativeApplicationGate : NSObject
+ (nullable instancetype)captureOfficialInstagramBeforeDeadline:(double)deadline error:(NSError **)error;
+ (nullable instancetype)captureOfficialFacebookBeforeDeadline:(double)deadline error:(NSError **)error;
// Recovery accepts only a live, validated root-owned journal. It never opens
// an executable merely to observe a crash-closed installation.
+ (nullable instancetype)recoverFromJournal:(LBXNativeIsolationJournal *)journal
                             beforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)closeExecutionBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)closeAndDrainBeforeDeadline:(double)deadline error:(NSError **)error;
- (BOOL)restoreExecutionBeforeDeadline:(double)deadline
                       authorization:(BOOL (^)(void))authorization error:(NSError **)error;
// A failed restore seals captured code again, but a process could have started
// during partial admission. Close and drain again before further storage work.
// Private immutable data for the durable root owner, never a permit.
// No restoration-from-dictionary API exists. Do not log/export this snapshot.
@property(nonatomic,readonly,copy) NSDictionary *privateJournalRecord;
@property(nonatomic,readonly,copy) NSDictionary *safeStatus;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_APPLICATION_GATE_TESTING
@interface LBXNativeApplicationGate (Testing)
// Test-only OS boundaries. Real bindings/FDs/mode effects remain mandatory.
+ (void)testUseBackend:(nullable id<LBXDrainBackend>)backend registration:(nullable NSDictionary *)registration;
// Mutation/failure seam; cannot provide a binding, FD, grant or result receipt.
+ (void)testBeforeModeChange:(nullable BOOL (^)(NSString *path, mode_t mode))callback;
@end
#endif
#if LBX_PRIVATE_GATE_ABORT_RECOVERY
// Private acceptance-probe rescue only. This API is absent from normal builds.
// Restores exact original code after an unstarted probe, with no storage or
// selection transaction, and cannot report isolation or process-drain success.
@interface LBXNativeApplicationGate (PrivateProbeAbort)
- (BOOL)restoreOriginalExecutionForUnstartedProbe:(LBXNativeIsolationJournal *)journal
                                  beforeDeadline:(double)deadline
                                   authorization:(BOOL (^)(void))authorization error:(NSError **)error;
@end
#endif
NS_ASSUME_NONNULL_END
