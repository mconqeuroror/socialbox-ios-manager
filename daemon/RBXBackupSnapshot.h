#import <Foundation/Foundation.h>
@class RBXOperationContext;
@interface RBXBackupSnapshot : NSObject
// Caller must hold serialized operation ownership and prove CLOSED/no processes.
+ (BOOL)copyQuiescentTree:(NSString *)source to:(NSString *)destination
    context:(RBXOperationContext *)context error:(NSError **)error;
+ (BOOL)validateDatabasesInTree:(NSString *)root context:(RBXOperationContext *)context error:(NSError **)error;
@end
