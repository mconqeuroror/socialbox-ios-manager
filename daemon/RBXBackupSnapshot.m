#import "RBXBackupSnapshot.h"
#import "RBXOperationContext.h"
#import <CommonCrypto/CommonDigest.h>
#import <sqlite3.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

static NSError *RBXSnapshotError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.backup" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL RBXSnapshotCheck(RBXOperationContext *context, NSError **error) {
    if (context && !context.inspectionOnly) return [context check:error];
    if (error) *error = RBXSnapshotError(@"Backup has no mutation operation owner"); return NO;
}
static NSDictionary *RBXTreeInventory(NSString *root, RBXOperationContext *context, NSError **error) {
    struct stat rootInfo;
    if (lstat(root.fileSystemRepresentation, &rootInfo) != 0 || !S_ISDIR(rootInfo.st_mode)) {
        if (error) *error = RBXSnapshotError(@"Backup root is not a real directory"); return nil;
    }
    // Match the physical paths returned by NSURL enumeration (e.g. /private/var).
    char *resolved = realpath(root.fileSystemRepresentation, NULL);
    if (!resolved) { if (error) *error = RBXSnapshotError(@"Backup root could not be resolved"); return nil; }
    root = [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    free(resolved);
    __block NSError *scanError = nil;
    NSDirectoryEnumerator *entries = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root]
        includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *failure) {
            (void)url; scanError = failure; return NO;
        }];
    if (!entries) { if (error) *error = RBXSnapshotError(@"Backup tree could not be enumerated"); return nil; }
    NSMutableDictionary *content = [NSMutableDictionary dictionary], *identity = [NSMutableDictionary dictionary];
    NSString *prefix = [root stringByAppendingString:@"/"];
    for (NSURL *url in entries) {
        if (!RBXSnapshotCheck(context, error)) return nil;
        NSString *path = url.path;
        if (![path hasPrefix:prefix]) { scanError = RBXSnapshotError(@"Backup entry escaped its root"); break; }
        NSString *relative = [path substringFromIndex:prefix.length];
        struct stat info;
        if (lstat(path.fileSystemRepresentation, &info) != 0 ||
            (!S_ISDIR(info.st_mode) && !S_ISREG(info.st_mode)) || (S_ISREG(info.st_mode) && info.st_nlink != 1)) {
            scanError = RBXSnapshotError(@"Backup contains an unreadable entry, link or special file"); break;
        }
        identity[relative] = @[@(info.st_dev), @(info.st_ino), @(info.st_size),
            @(info.st_mtimespec.tv_sec), @(info.st_mtimespec.tv_nsec),
            @(info.st_ctimespec.tv_sec), @(info.st_ctimespec.tv_nsec)];
        if (S_ISDIR(info.st_mode)) { content[relative] = @"directory"; continue; }
        int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        struct stat opened;
        if (fd < 0 || fstat(fd, &opened) != 0 || opened.st_ino != info.st_ino || opened.st_dev != info.st_dev) {
            if (fd >= 0) close(fd);
            scanError = RBXSnapshotError(@"Backup source changed during inspection"); break;
        }
        CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
        unsigned char buffer[65536], digest[CC_SHA256_DIGEST_LENGTH];
        ssize_t count;
        while ((count = read(fd, buffer, sizeof(buffer))) > 0) {
            if (!RBXSnapshotCheck(context, &scanError)) break;
            CC_SHA256_Update(&hash, buffer, (CC_LONG)count);
        }
        close(fd);
        if (count < 0 && !scanError) scanError = RBXSnapshotError(@"Backup file read failed");
        if (scanError) break;
        CC_SHA256_Final(digest, &hash);
        content[relative] = [NSData dataWithBytes:digest length:sizeof(digest)];
    }
    if (scanError) { if (error) *error = scanError; return nil; }
    return @{@"content": content, @"identity": identity};
}
static int RBXSnapshotSQLProgress(void *opaque) {
    return !RBXSnapshotCheck((__bridge RBXOperationContext *)opaque, nil);
}
@implementation RBXBackupSnapshot
+ (BOOL)copyQuiescentTree:(NSString *)source to:(NSString *)destination
    context:(RBXOperationContext *)context error:(NSError **)error {
    if (!RBXSnapshotCheck(context, error)) return NO;
    NSDictionary *before = RBXTreeInventory(source, context, error);
    if (!before || ![NSFileManager.defaultManager copyItemAtPath:source toPath:destination error:error]) return NO;
    NSDictionary *after = RBXTreeInventory(source, context, error);
    NSDictionary *copy = after ? RBXTreeInventory(destination, context, error) : nil;
    if (!copy || ![before isEqual:after] || ![before[@"content"] isEqual:copy[@"content"]]) {
        if (error && !*error) *error = RBXSnapshotError(@"App data changed during backup; snapshot retained for recovery, nothing uploaded");
        return NO;
    }
    return [self validateDatabasesInTree:destination context:context error:error];
}
+ (BOOL)validateDatabasesInTree:(NSString *)root context:(RBXOperationContext *)context error:(NSError **)error {
    NSDictionary *inventory = RBXTreeInventory(root, context, error);
    if (!inventory) return NO;
    for (NSString *relative in inventory[@"content"]) {
        if (!RBXSnapshotCheck(context, error)) return NO;
        if ([inventory[@"content"][relative] isEqual:@"directory"]) continue;
        NSString *path = [root stringByAppendingPathComponent:relative];
        int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        char header[16] = {0}; ssize_t count = fd >= 0 ? read(fd, header, sizeof(header)) : -1;
        if (fd >= 0) close(fd);
        if (count < 0) { if (error) *error = RBXSnapshotError(@"Cannot inspect staged database header"); return NO; }
        BOOL sqliteHeader = count == sizeof(header) && memcmp(header, "SQLite format 3\0", sizeof(header)) == 0;
        if (!sqliteHeader && ![@[@"db", @"sqlite", @"sqlite3"] containsObject:relative.pathExtension.lowercaseString]) continue;
        sqlite3 *db = NULL; sqlite3_stmt *statement = NULL;
        BOOL valid = sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK;
        if (valid) {
            sqlite3_busy_timeout(db, 1000);
            sqlite3_progress_handler(db, 1000, RBXSnapshotSQLProgress, (__bridge void *)context);
            sqlite3_exec(db, "PRAGMA trusted_schema=OFF", NULL, NULL, NULL);
            valid = sqlite3_prepare_v2(db, "PRAGMA quick_check(1)", -1, &statement, NULL) == SQLITE_OK &&
                sqlite3_step(statement) == SQLITE_ROW &&
                sqlite3_column_text(statement, 0) != NULL &&
                strcmp((const char *)sqlite3_column_text(statement, 0), "ok") == 0 &&
                sqlite3_step(statement) == SQLITE_DONE;
        }
        if (statement) sqlite3_finalize(statement);
        if (db) sqlite3_close(db);
        if (!valid) {
            if (error) *error = RBXSnapshotError([NSString stringWithFormat:@"Staged database %@ is corrupt, busy, encrypted or unsupported; restore was not committed", relative]);
            return NO;
        }
    }
    return RBXSnapshotCheck(context, error);
}
@end
