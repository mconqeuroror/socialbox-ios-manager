// Actual snapshot/hash/SQLite implementation. Synthetic files and context only.
#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import "RBXOperationContext.h"
static BOOL Cancelled, MutateCopy;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXOperationContext
- (BOOL)check:(NSError **)error {
    if (Cancelled && error) *error = [NSError errorWithDomain:@"Fixture" code:1 userInfo:nil];
    return !Cancelled;
}
- (BOOL)inspectionOnly { return NO; }
@end
#pragma clang diagnostic pop
@interface NSFileManager (CopyFixture)
- (BOOL)rbx_testCopyItemAtPath:(NSString *)source toPath:(NSString *)destination error:(NSError **)error;
@end
@implementation NSFileManager (CopyFixture)
- (BOOL)rbx_testCopyItemAtPath:(NSString *)source toPath:(NSString *)destination error:(NSError **)error {
    BOOL result = [self copyItemAtPath:source toPath:destination error:error];
    if (result && MutateCopy) [@"modified" writeToFile:[source stringByAppendingPathComponent:@"plain"]
        atomically:YES encoding:NSUTF8StringEncoding error:error];
    return result;
}
@end
#define copyItemAtPath rbx_testCopyItemAtPath
#import "../daemon/RBXBackupSnapshot.m"
#undef copyItemAtPath
static void Check(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}
int main(void) {
    @autoreleasepool {
        NSString *root = [[NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rbx-snapshot-test-" stringByAppendingString:NSUUID.UUID.UUIDString]] stringByResolvingSymlinksInPath];
        NSFileManager *fm = NSFileManager.defaultManager;
        sqlite3 *live = NULL;
        int result = 0;
        @try {
            NSString *source = [root stringByAppendingPathComponent:@"source"];
            Check([fm createDirectoryAtPath:source withIntermediateDirectories:YES attributes:nil error:nil], @"fixture root");
            Check([@"unchanged" writeToFile:[source stringByAppendingPathComponent:@"plain"] atomically:YES
                encoding:NSUTF8StringEncoding error:nil], @"plain fixture");
            NSString *database = [source stringByAppendingPathComponent:@"state.sqlite"];
            Check(sqlite3_open(database.fileSystemRepresentation, &live) == SQLITE_OK, @"fixture database open");
            Check(sqlite3_exec(live, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE state(value); INSERT INTO state VALUES(42);", NULL, NULL, NULL) == SQLITE_OK, @"uncheckpointed WAL fixture");
            RBXOperationContext *context = [RBXOperationContext new];
            NSError *error = nil;
            NSString *snapshot = [root stringByAppendingPathComponent:@"snapshot"];
            Check([RBXBackupSnapshot copyQuiescentTree:source to:snapshot context:context error:&error], error.localizedDescription ?: @"stable WAL snapshot");
            sqlite3 *restored = NULL; sqlite3_stmt *stmt = NULL;
            Check(sqlite3_open_v2([[snapshot stringByAppendingPathComponent:@"state.sqlite"] fileSystemRepresentation], &restored, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK, @"snapshot opens");
            Check(sqlite3_prepare_v2(restored, "SELECT value FROM state", -1, &stmt, NULL) == SQLITE_OK &&
                sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 42, @"WAL commit survives snapshot");
            sqlite3_finalize(stmt); sqlite3_close(restored);
            MutateCopy = YES; error = nil;
            Check(![RBXBackupSnapshot copyQuiescentTree:source to:[root stringByAppendingPathComponent:@"changed"] context:context error:&error] && error, @"source changes during copy rejected");
            MutateCopy = NO; Cancelled = YES; error = nil;
            Check(![RBXBackupSnapshot validateDatabasesInTree:snapshot context:context error:&error] && error, @"cancelled owner rejected");
            Cancelled = NO;
            Check([fm createSymbolicLinkAtPath:[source stringByAppendingPathComponent:@"link"] withDestinationPath:database error:nil], @"symlink fixture");
            Check(![RBXBackupSnapshot copyQuiescentTree:source to:[root stringByAppendingPathComponent:@"linked"] context:context error:nil], @"symlink cannot enter snapshot");
            [fm removeItemAtPath:[source stringByAppendingPathComponent:@"link"] error:nil];
            NSString *corrupt = [root stringByAppendingPathComponent:@"corrupt"];
            [fm createDirectoryAtPath:corrupt withIntermediateDirectories:YES attributes:nil error:nil];
            [@"not-a-database" writeToFile:[corrupt stringByAppendingPathComponent:@"state.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            Check(![RBXBackupSnapshot validateDatabasesInTree:corrupt context:context error:nil], @"corrupt database rejected before restore");
            puts("PASS: WAL snapshot contents, source-change detection, cancellation, links and corrupt databases");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); result = 1;
        } @finally {
            if (live) sqlite3_close(live);
            [fm removeItemAtPath:root error:nil];
        }
        return result;
    }
}
