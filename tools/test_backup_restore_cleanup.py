#!/usr/bin/env python3
"""Run the shipped restore copy/cleanup with temporary files and injected faults.

No account, network, phone, or user data is involved. Only the operation context,
ownership change, and selected filesystem failures are replaced by test seams.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXCloudSync.m').read_text()


def function(name):
    start = source.index('static ', source.index(name) - 28)
    return source[start:source.index('\n}\n', start) + 3]


functions = function('RBXCloudInputError') + '\n' + function('RBXCloudRestoreDataContents')

fixture = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
@interface RBXOperationContext : NSObject
@property BOOL cancelled;
@end
@implementation RBXOperationContext
@end
static BOOL RBXCloudCheck(RBXOperationContext *context, NSError **error) {
    if (context && !context.cancelled) return YES;
    if (error) *error = [NSError errorWithDomain:@"fixture.cancelled" code:1 userInfo:nil];
    return NO;
}
static NSString *faultPath;
static NSString *faultMode;
static RBXOperationContext *currentContext;
static NSUInteger cases, failures;
static void Check(BOOL value, NSString *label) {
    cases++; if (!value) { failures++; fprintf(stderr,"FAIL: %s\n",label.UTF8String); }
}
@interface FixtureFileManager : NSFileManager
+ (instancetype)defaultManager;
@end
@implementation FixtureFileManager
+ (instancetype)defaultManager { static FixtureFileManager *fm; if (!fm) fm = [self new]; return fm; }
- (BOOL)removeItemAtPath:(NSString *)path error:(NSError **)error {
    if ([path isEqual:faultPath]) {
        if ([faultMode isEqual:@"deny"]) {
            if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil];
            return NO;
        }
        if ([faultMode isEqual:@"noop"]) return YES;
        if ([faultMode isEqual:@"cancel"]) currentContext.cancelled = YES;
    }
    return [super removeItemAtPath:path error:error];
}
@end
static int FixtureLstat(const char *path, struct stat *info) {
    if ([faultMode isEqual:@"inspect"] && [[NSString stringWithUTF8String:path] isEqual:faultPath]) {
        errno = EACCES; return -1;
    }
    return lstat(path, info);
}
// The production call runs as root; do not change ownership in this host fixture.
static int FixtureChown(const char *path, uid_t uid, gid_t gid) { return 0; }
#define NSFileManager FixtureFileManager
#define lstat FixtureLstat
#define lchown FixtureChown
__FUNCTIONS__
#undef NSFileManager
#undef lstat
#undef lchown
static void Write(NSString *path, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    Check([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil], @"fixture file created");
}
static NSArray *Controls(void) {
    return @[@"Library/Preferences/com.redditbox.network-lease.plist",
        @"Library/Preferences/com.redditbox.firewall-status.plist",
        @"Library/Preferences/com.redditbox.hook-ready.plist",
        @"Library/Application Support/RedditBox/profile.json"];
}
static BOOL Restore(NSString *source, NSString *destination, NSError **error) {
    currentContext = [RBXOperationContext new];
    return RBXCloudRestoreDataContents(source,destination,currentContext,error);
}
int main(int argc, char **argv) { @autoreleasepool {
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSString *source = [root stringByAppendingPathComponent:@"source"];
    NSString *destination = [root stringByAppendingPathComponent:@"destination"];
    NSString *metadata = @".com.apple.mobile_container_manager.metadata.plist";
    Write([source stringByAppendingPathComponent:metadata], @"archived-owner");
    Write([source stringByAppendingPathComponent:@"Documents/session.bin"], @"synthetic-app-state");
    Write([destination stringByAppendingPathComponent:metadata], @"new-owner");
    for (NSString *relative in Controls()) Write([source stringByAppendingPathComponent:relative], @"synthetic-archived-control");
    NSError *error = nil;
    Check(Restore(source,destination,&error) && !error, @"ordinary restore with removable legacy controls succeeds");
    for (NSString *relative in Controls())
        Check(![NSFileManager.defaultManager fileExistsAtPath:[destination stringByAppendingPathComponent:relative]], @"all legacy controls absent");
    Check([[NSString stringWithContentsOfFile:[destination stringByAppendingPathComponent:metadata]
        encoding:NSUTF8StringEncoding error:nil] isEqual:@"new-owner"], @"OS ownership metadata retained");
    Check([[NSString stringWithContentsOfFile:[destination stringByAppendingPathComponent:@"Documents/session.bin"]
        encoding:NSUTF8StringEncoding error:nil] isEqual:@"synthetic-app-state"], @"app data bytes retained");
    for (NSString *relative in Controls()) {
        faultPath = [destination stringByAppendingPathComponent:relative];
        for (NSString *mode in @[@"deny",@"noop",@"inspect"]) {
            faultMode = mode; error = nil;
            Check(!Restore(source,destination,&error) && error,
                [NSString stringWithFormat:@"%@ failure for %@ cannot report restore success",mode,relative]);
            // A failure must leave evidence for the caller's existing rollback
            // or retained recovery path, rather than claiming it was removed.
            Check([NSFileManager.defaultManager fileExistsAtPath:faultPath], @"failed cleanup remains observable");
        }
    }
    faultPath = [destination stringByAppendingPathComponent:Controls().lastObject];
    faultMode = @"cancel"; error = nil;
    Check(!Restore(source,destination,&error) && error, @"cancellation during final removal cannot return success");
    faultPath = nil; faultMode = nil;
    // No controls is valid for recent archives; ENOENT is the only accepted
    // absence result. An invalid ancestor yields ENOTDIR and must fail closed.
    for (NSString *relative in Controls())
        [NSFileManager.defaultManager removeItemAtPath:[source stringByAppendingPathComponent:relative] error:nil];
    error = nil;
    Check(Restore(source,destination,&error) && !error, @"already absent controls remain a valid restore");
    [NSFileManager.defaultManager removeItemAtPath:[source stringByAppendingPathComponent:@"Library/Preferences"] error:nil];
    Write([source stringByAppendingPathComponent:@"Library/Preferences"], @"invalid-directory");
    error = nil;
    Check(!Restore(source,destination,&error) && error, @"uninspectable control ancestry cannot count as verified absence");
    printf("%s: %lu restore cleanup cases\n", failures ? "FAIL" : "PASS", (unsigned long)cases);
    return failures ? 1 : 0;
} }
'''
with tempfile.TemporaryDirectory(prefix='rbx-restore-cleanup-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(fixture.replace('__FUNCTIONS__', functions))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-deprecated-declarations',
                    '-framework', 'Foundation', str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path / 'data')], check=True)
