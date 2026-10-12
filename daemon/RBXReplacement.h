#import <Foundation/Foundation.h>
@class RBXContainerRegistry, RBXProxyManager, RBXOperationContext;

NS_ASSUME_NONNULL_BEGIN

// Narrow transition interface also used by native fault-injection tests.
@protocol RBXReplacementBackend <NSObject>
- (BOOL)replacementAllowedForContainer:(NSString *)container error:(NSError **)error;
- (nullable NSDictionary *)journalForContainer:(NSString *)container error:(NSError **)error;
- (nullable NSDictionary *)prepareJournalForContainer:(NSString *)container error:(NSError **)error;
- (BOOL)persistJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)establishClosureForJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)createCandidateForJournal:(NSDictionary *)journal error:(NSError **)error;
- (nullable NSString *)rotateCandidateForJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)validateCandidateForJournal:(NSDictionary *)journal error:(NSError **)error;
- (BOOL)deleteOriginalForJournal:(NSDictionary *)journal error:(NSError **)error;
@end

FOUNDATION_EXPORT NSString * _Nullable RBXRunReplacement(NSString *container,
    id<RBXReplacementBackend> backend, NSError **error);

// Pure ownership policy used by the daemon and native fixtures. It validates
// every journal before allowing an unrelated mutation or an exact original retry.
typedef NS_ENUM(NSInteger, RBXReplacementMutation) {
    RBXReplacementUserDelete,
    RBXReplacementStartOrResume,
};
FOUNDATION_EXPORT BOOL RBXReplacementMutationAllowed(id journals, NSString *container,
    RBXReplacementMutation mutation, NSError **error);

@interface RBXReplacement : NSObject
// Call from the daemon's serial transition queue with its current owner.
+ (nullable NSString *)replaceContainer:(NSString *)container
    registry:(RBXContainerRegistry *)registry proxies:(RBXProxyManager *)proxies
    context:(RBXOperationContext *)context error:(NSError **)error;
// nil + nil error is no replacement; malformed state always returns an error.
+ (nullable NSDictionary *)replacementStateForContainer:(NSString *)container error:(NSError **)error;
+ (BOOL)launchAllowedForContainer:(NSString *)container error:(NSError **)error;
+ (BOOL)userDeletionAllowedForContainer:(NSString *)container error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
