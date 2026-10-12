#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface RBXDataMigration : NSObject
// Run after CLOSED is established and before registry recovery, metadata sync,
// profile migration, publishers or periodic services can write any data.
// Preflights the entire set first. A partial forward migration is idempotent.
+ (BOOL)preflightAndMigrateWithError:(NSError **)error;
+ (NSDictionary *)currentVersions;
@end
NS_ASSUME_NONNULL_END
