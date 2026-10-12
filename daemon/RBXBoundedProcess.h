#import <Foundation/Foundation.h>
@class RBXOperationContext;

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const RBXBoundedProcessErrorDomain;
// Errors include childStarted and childQuiescent. A false quiescence result
// retains output/recovery evidence and the operation's persistent safety fence.
// Only an actually reaped child adds numeric exitCode or terminationSignal.
// These describe its termination, not operation success: exitCode may be zero
// when the operation failed or its descendants required cancellation.
@interface RBXBoundedProcess : NSObject
+ (BOOL)runExecutable:(NSString *)executable
             arguments:(NSArray<NSString *> *)arguments
               context:(RBXOperationContext *)context
            outputPath:(nullable NSString *)outputPath
    maximumOutputBytes:(NSUInteger)limit
                 error:(NSError **)error;
// Optional shorter stage bound; never extends the operation's deadline.
+ (BOOL)runExecutable:(NSString *)executable
             arguments:(NSArray<NSString *> *)arguments
               context:(RBXOperationContext *)context
       maximumDuration:(NSTimeInterval)duration
            outputPath:(nullable NSString *)outputPath
    maximumOutputBytes:(NSUInteger)limit
                 error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
