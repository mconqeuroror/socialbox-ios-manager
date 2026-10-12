#import <Foundation/Foundation.h>
#import "RBXOperationContext.h"
#import <errno.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <time.h>
#import <unistd.h>

static BOOL failGroupSnapshot;
static int TestSysctl(int *name, u_int count, void *old, size_t *size, void *value, size_t length) {
    if (failGroupSnapshot && count == 4 && name[0] == CTL_KERN &&
        name[1] == KERN_PROC && name[2] == KERN_PROC_PGRP) { errno = EIO; return -1; }
    return sysctl(name, count, old, size, value, length);
}
// Include the actual helper, replacing only one kernel failure seam. Every
// successful spawn, pipe, signal, group enumeration and reap is real Darwin.
#define sysctl TestSysctl
#import "../daemon/RBXBoundedProcess.m"
#undef sysctl

static void Require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static double Clock(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static RBXOperationContext *Context(double timeout) {
    return [RBXOperationContext contextWithRequestID:NSUUID.UUID.UUIDString
        bootEpoch:RBXOperationContext.daemonBootEpoch timeout:timeout];
}
static NSString *Output(NSString *root) { return [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString]; }
static void RequireTermination(NSError *error, NSNumber *exitCode, NSNumber *terminationSignal) {
    Require(exitCode ? [error.userInfo[@"exitCode"] isEqual:exitCode] : !error.userInfo[@"exitCode"],
        @"exit code exists only for an actually reaped normally exited child");
    Require(terminationSignal ? [error.userInfo[@"terminationSignal"] isEqual:terminationSignal] :
        !error.userInfo[@"terminationSignal"], @"termination signal exists only for an actually reaped signaled child");
    NSSet *allowed = [NSSet setWithArray:@[NSLocalizedDescriptionKey, @"childQuiescent", @"childStarted",
        @"exitCode", @"terminationSignal"]];
    for (NSString *key in error.userInfo) Require([allowed containsObject:key], @"child errors expose only bounded status metadata");
}

int main(int argc, const char **argv) { @autoreleasepool {
    Require(argc == 2, @"fixture executable argument");
    NSString *fixture = [NSString stringWithUTF8String:argv[1]];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"redditbox-child-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Require([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:NO
        attributes:@{NSFilePosixPermissions: @0700} error:nil], @"private test directory");
    [RBXOperationContext setSafetyFenceDirectoryForTesting:[root stringByAppendingPathComponent:@"fences"]];
    NSError *error = nil;
    RBXOperationContext *context = Context(5);
    NSString *output = Output(root);
    Require([RBXBoundedProcess runExecutable:fixture arguments:@[@"success"] context:context
        outputPath:output maximumOutputBytes:64 error:&error], @"successful child completes");
    Require([[NSString stringWithContentsOfFile:output encoding:NSUTF8StringEncoding error:nil]
        isEqual:@"bounded-output\n"], @"capture contains exact output");
    Require([context waitForQuiescence:0], @"successful child ownership drained"); [context finish];

    context = Context(5); error = nil;
    Require(![RBXBoundedProcess runExecutable:fixture arguments:@[@"failure", @"private-helper-argument"] context:context
        outputPath:nil maximumOutputBytes:0 error:&error] && [error.userInfo[@"childQuiescent"] boolValue] &&
        [error.userInfo[@"childStarted"] boolValue],
        @"nonzero status fails with proven reap");
    RequireTermination(error, @19, nil);
    Require(![error.description containsString:fixture] &&
        ![error.description containsString:@"private-helper-argument"] &&
        ![error.description containsString:@"private-helper-output"], @"child status excludes invocation and output data");
    Require([context waitForQuiescence:0], @"nonzero child ownership drained"); [context finish];

    context = Context(5); error = nil;
    Require(![RBXBoundedProcess runExecutable:fixture arguments:@[@"signal"] context:context
        outputPath:nil maximumOutputBytes:0 error:&error] && [error.userInfo[@"childQuiescent"] boolValue] &&
        [error.userInfo[@"childStarted"] boolValue], @"signal termination fails with proven reap");
    RequireTermination(error, nil, @(SIGTERM));
    Require([context waitForQuiescence:0], @"signaled child ownership drained"); [context finish];

    context = Context(5); error = nil;
    NSString *missing = [root stringByAppendingPathComponent:@"missing-log-tool"];
    Require(![RBXBoundedProcess runExecutable:missing arguments:@[] context:context
        outputPath:nil maximumOutputBytes:0 error:&error], @"missing helper fails without starting a child");
    Require([error.localizedDescription containsString:@"missing-log-tool"] &&
        [error.localizedDescription containsString:[NSString stringWithUTF8String:strerror(ENOENT)]],
        @"spawn failure identifies the helper and operating-system error");
    Require([error.userInfo[@"childQuiescent"] boolValue] &&
        [@NO isEqual:error.userInfo[@"childStarted"]] && [context waitForQuiescence:0],
        @"missing helper leaves no owned child or recovery fence");
    RequireTermination(error, nil, nil);
    [context finish];

    context = Context(5); output = Output(root); error = nil;
    Require(![RBXBoundedProcess runExecutable:fixture arguments:@[@"flood"] context:context
        outputPath:output maximumOutputBytes:8192 error:&error], @"continuous output fails its cap");
    Require([[[NSFileManager.defaultManager attributesOfItemAtPath:output error:nil]
        objectForKey:NSFileSize] unsignedLongLongValue] <= 8192, @"capture never exceeds cap");
    Require([error.userInfo[@"childQuiescent"] boolValue] && [context waitForQuiescence:0], @"flood child is stopped and reaped");
    [context finish];

    for (NSString *mode in @[@"descendant", @"orphan"]) {
        context = Context(5); output = Output(root); error = nil;
        NSString *lateWrite = Output(root);
        double started = Clock();
        BOOL ok = [RBXBoundedProcess runExecutable:fixture arguments:@[mode, lateWrite] context:context
            maximumDuration:0.2 outputPath:output maximumOutputBytes:1024 error:&error];
        Require(!ok && Clock() - started < 2.0, @"TERM-ignoring process group has bounded teardown");
        Require([error.userInfo[@"childQuiescent"] boolValue] && [context waitForQuiescence:0],
            @"leader and descendant stopped before ownership release");
        if ([mode isEqual:@"orphan"]) RequireTermination(error, @0, nil);
        else RequireTermination(error, nil, @(SIGKILL));
        Require(context.cancelled, @"reaped exit zero never turns canceled descendant cleanup into success");
        NSString *ids = [NSString stringWithContentsOfFile:output encoding:NSUTF8StringEncoding error:nil];
        int leader = -1, child = -1;
        Require(sscanf(ids.UTF8String ?: "", "leader=%d child=%d", &leader, &child) == 2,
            @"fixture actually created a descendant");
        int status = 0; errno = 0;
        Require(waitpid(leader, &status, WNOHANG) == -1 && errno == ECHILD, @"leader was reaped");
        usleep(2100000);
        Require(![NSFileManager.defaultManager fileExistsAtPath:lateWrite], @"descendant cannot mutate after return");
        Require([RBXOperationContext checkSafetyFence:nil], @"proven group teardown requires no unsafe fence");
        [context finish];
    }

    // Recovery and subsequent requests use the same absolute budget, including
    // time already consumed before a nested child stage starts.
    context = Context(0.15); usleep(200000); output = Output(root); error = nil;
    Require(![RBXBoundedProcess runExecutable:fixture arguments:@[@"success"] context:context
        outputPath:output maximumOutputBytes:64 error:&error], @"expired recovery never starts a fresh child budget");
    Require(![NSFileManager.defaultManager fileExistsAtPath:output], @"expired owner cannot spawn or open capture");
    Require([@NO isEqual:error.userInfo[@"childStarted"]], @"pre-spawn cancellation is distinguished from service uncertainty");
    RequireTermination(error, nil, nil);
    [context finish];

    // Failed kernel proof must retain both the count and sticky fence. A real
    // successful leader is used; the test explicitly reaps it after assertions.
    context = Context(5); output = Output(root); error = nil; failGroupSnapshot = YES;
    Require(![RBXBoundedProcess runExecutable:fixture arguments:@[@"success"] context:context
        outputPath:output maximumOutputBytes:64 error:&error], @"enumeration failure is not an empty group");
    failGroupSnapshot = NO;
    Require(![error.userInfo[@"childQuiescent"] boolValue] && ![context waitForQuiescence:0],
        @"unproven child remains owned");
    RequireTermination(error, nil, nil);
    RBXOperationContext *next = Context(5);
    Require(![next beginWork:nil], @"next mutating operation is refused by sticky fence");
    int status; while (waitpid(-1, &status, WNOHANG) > 0) {}
    Require(![RBXOperationContext checkSafetyFence:nil], @"late reap alone never clears unsafe fence");
    [context finish]; [next finish];
    Require([root.lastPathComponent hasPrefix:@"redditbox-child-test-"] &&
        [root.stringByDeletingLastPathComponent isEqual:NSTemporaryDirectory().stringByStandardizingPath], @"test cleanup remains scoped");
    Require([NSFileManager.defaultManager removeItemAtPath:root error:nil], @"remove only synthetic test files");
    puts("Bounded process tests passed (real Darwin child groups; no iOS services invoked)");
    return 0;
} }
