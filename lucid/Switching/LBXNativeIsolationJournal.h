#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Root-only durable metadata journal. Never supply credentials or account bytes.
// The canonical physical directory and every ancestor are descriptor-pinned.
// A nonblocking exclusive lock is held until close/deallocation. Unknown files
// and interrupted pre-rename stages are refused; there is no cleanup/delete API.
@interface LBXNativeIsolationJournal : NSObject
+ (nullable instancetype)openDirectory:(NSString *)directory create:(BOOL)create error:(NSError **)error;
@property(nonatomic,readonly,copy,nullable) NSDictionary *currentRecord;
// Revalidates live descriptors/lock, known names and the exact cached envelope.
// nil with no error means an intact journal has no record yet.
- (nullable NSDictionary *)validatedCurrentRecord:(NSError **)error;
// expected is the complete previous immutable envelope (nil for first write).
// payload is wrapped as {formatVersion:1,generation:previous+1,payload:payload}.
// A failed write can have reached rename; close/reopen to reconcile. Never infer
// rollback from NO. After a write error this handle accepts no further writes.
- (BOOL)compareRecord:(nullable NSDictionary *)expected replaceWith:(NSDictionary *)payload error:(NSError **)error;
- (void)close;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

#if LBX_NATIVE_ISOLATION_JOURNAL_TESTING
@interface LBXNativeIsolationJournal (Testing)
+ (nullable instancetype)testOpenDirectory:(NSString *)directory create:(BOOL)create error:(NSError **)error;
// Fault stages: stage-created, stage-synced, renamed, parent-synced.
// The callback may terminate the fixture child to exercise actual crash recovery.
+ (void)testSetFault:(nullable void (^)(NSString *stage))fault;
@end
#endif
NS_ASSUME_NONNULL_END
