#import "LBXProcessDrain.h"
#include <math.h>
#include <string.h>
#include <unistd.h>

@implementation LBXDrainTarget
@end
@implementation LBXDrainProcess
@end

static BOOL LBXPath(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return NO;
    NSString *standard = path.stringByStandardizingPath;
    // iOS Foundation shortens /private/var during lexical standardization too.
    // Accept only that same known system alias; traversal, duplicate separators
    // and unrelated spelling changes must still fail the equality check.
    if ([path hasPrefix:@"/private/var/"] && [standard hasPrefix:@"/var/"])
        standard = [@"/private" stringByAppendingString:standard];
    return [path isKindOfClass:NSString.class] && path.isAbsolutePath && path.length < PROC_PIDPATHINFO_MAXSIZE &&
        [path isEqual:standard] && ![path containsString:@"\0"];
}

static BOOL LBXValidTarget(LBXDrainTarget *target, NSString *bundleID) {
    if (![target isKindOfClass:LBXDrainTarget.class] || ![target.bundleID isEqual:bundleID] ||
        !LBXPath(target.bundlePath) || ![target.bundlePath.pathExtension isEqual:@"app"] ||
        ![target.fingerprint isKindOfClass:NSString.class] || !target.fingerprint.length ||
        ![target.executables isKindOfClass:NSArray.class] || !target.executables.count || target.executables.count > 128)
        return NO;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *path in target.executables) {
        if (!LBXPath(path) || ![path hasPrefix:[target.bundlePath stringByAppendingString:@"/"]] ||
            [seen containsObject:path]) return NO;
        [seen addObject:path];
    }
    return YES;
}

static BOOL LBXSameTarget(LBXDrainTarget *a, LBXDrainTarget *b) {
    return LBXValidTarget(b, a.bundleID) && [a.bundlePath isEqual:b.bundlePath] &&
        [a.fingerprint isEqual:b.fingerprint] && [a.executables isEqual:b.executables];
}

static NSString *LBXIdentityKey(RBXObservedProcess p) {
    return [NSString stringWithFormat:@"%d:%lld:%d:%s", p.pid, (long long)p.startSeconds, p.startMicroseconds, p.executable];
}

static NSArray<LBXDrainProcess *> *LBXMatches(NSArray *snapshot, LBXDrainTarget *target, NSString **failure) {
    if (![snapshot isKindOfClass:NSArray.class] || snapshot.count > 65536) { *failure = @"enumeration_failed"; return nil; }
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableSet *pids = [NSMutableSet set];
    for (id row in snapshot) {
        if (![row isKindOfClass:LBXDrainProcess.class]) { *failure = @"invalid_process_snapshot"; return nil; }
        RBXObservedProcess p = ((LBXDrainProcess *)row).identity;
        size_t length = strnlen(p.executable, sizeof(p.executable));
        NSString *path = length < sizeof(p.executable) ? [NSString stringWithUTF8String:p.executable] : nil;
        if (p.pid <= 1 || p.pid == getpid() || p.startSeconds <= 0 || p.startMicroseconds < 0 ||
            p.startMicroseconds >= 1000000 || !LBXPath(path) || [pids containsObject:@(p.pid)]) {
            *failure = @"invalid_process_snapshot"; return nil;
        }
        [pids addObject:@(p.pid)];
        // Only the platform's known /var alias is canonicalized. Never resolve
        // arbitrary process paths through attacker-mutable symlinks here.
        if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
        if ([target.executables containsObject:path]) {
            LBXDrainProcess *copy = [LBXDrainProcess new]; copy.identity = p;
            [matches addObject:copy];
        }
        else if ([path hasPrefix:[target.bundlePath stringByAppendingString:@"/"]]) {
            // Unknown executable inside the app cannot silently disappear from
            // the evidence. Do not turn a directory prefix into kill authority.
            *failure = @"unregistered_app_process"; return nil;
        }
    }
    return matches;
}

NSDictionary *LBXDrainApplication(id<LBXDrainBackend> backend, NSString *bundleID,
                                 NSString *requestID, NSTimeInterval timeout, BOOL terminate) {
    NSMutableDictionary *receipt = [@{@"schemaVersion":@1, @"status":@"failed", @"reason":@"invalid_request",
        @"networkFenced":@NO, @"launchesFenced":@NO, @"reusableAdmission":@NO,
        @"mode":terminate ? @"drain" : @"inspect", @"observedProcesses":@[], @"terminationRequests":@0} mutableCopy];
    if (!backend || !LBXDrainSupportedApplication(bundleID) || ![requestID isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:requestID] || !isfinite(timeout) || timeout < 0.1 || timeout > 5.0) return receipt;
    receipt[@"bundleID"] = bundleID; receipt[@"requestID"] = requestID;
    double started = [backend monotonicTime], previous = started;
    if (!isfinite(started) || started < 0) { receipt[@"reason"] = @"clock_failed"; return receipt; }
    @try {
        NSError *error = nil;
        LBXDrainTarget *resolved = [backend resolve:bundleID error:&error];
        if (!LBXValidTarget(resolved, bundleID)) { receipt[@"reason"] = @"registration_failed"; return receipt; }
        // Freeze all authority before calling another backend operation.
        LBXDrainTarget *target = [LBXDrainTarget new];
        target.bundleID = resolved.bundleID; target.bundlePath = resolved.bundlePath;
        target.executables = resolved.executables; target.fingerprint = resolved.fingerprint;
        receipt[@"registrationFingerprint"] = target.fingerprint;
        NSMutableSet *initial = [NSMutableSet set];
        NSUInteger emptyObservations = 0, requests = 0;
        for (unsigned pass = 0; pass < 256; pass++) {
            double now = [backend monotonicTime];
            if (!isfinite(now) || now < previous) { receipt[@"reason"] = @"clock_failed"; return receipt; }
            previous = now;
            if (now - started >= timeout) { receipt[@"reason"] = @"deadline_exceeded"; return receipt; }
            if (!LBXSameTarget(target, [backend resolve:bundleID error:&error])) {
                receipt[@"reason"] = @"registration_changed"; return receipt;
            }
            NSArray<LBXDrainProcess *> *snapshot = [backend snapshot:&error];
            // Complete-table retries consume this same request deadline. Check
            // before exposing an inspect result or granting any stop authority.
            now = [backend monotonicTime];
            if (!isfinite(now) || now < previous) { receipt[@"reason"] = @"clock_failed"; return receipt; }
            previous = now;
            if (now - started >= timeout) { receipt[@"reason"] = @"deadline_exceeded"; return receipt; }
            NSString *failure = nil;
            NSArray<LBXDrainProcess *> *matches = LBXMatches(snapshot, target, &failure);
            if (!matches) { receipt[@"reason"] = failure; return receipt; }
            if (pass == 0) {
                NSMutableArray *observed = [NSMutableArray array];
                for (LBXDrainProcess *row in matches) {
                    RBXObservedProcess p = row.identity;
                    [initial addObject:LBXIdentityKey(p)];
                    [observed addObject:@{@"pid":@(p.pid), @"startSeconds":@(p.startSeconds),
                        @"startMicroseconds":@(p.startMicroseconds), @"executable":@(p.executable)}];
                }
                receipt[@"observedProcesses"] = observed;
                if (!terminate && matches.count) {
                    receipt[@"status"] = @"observed_running"; receipt[@"reason"] = @"processes_present"; return receipt;
                }
            } else {
                for (LBXDrainProcess *row in matches) if (![initial containsObject:LBXIdentityKey(row.identity)]) {
                    receipt[@"reason"] = @"relaunch_detected"; return receipt;
                }
            }
            if (!matches.count) {
                emptyObservations++;
                if (emptyObservations == 2) {
                    // The second complete observation and the final registration
                    // check must themselves finish before the deadline.
                    if (!LBXSameTarget(target, [backend resolve:bundleID error:&error])) {
                        receipt[@"reason"] = @"registration_changed"; return receipt;
                    }
                    now = [backend monotonicTime];
                    if (!isfinite(now) || now < previous || now - started >= timeout) {
                        receipt[@"reason"] = @"deadline_exceeded"; return receipt;
                    }
                    receipt[@"status"] = @"observed_absent"; receipt[@"reason"] = @"two_complete_absent_snapshots";
                    receipt[@"elapsedSeconds"] = @(now - started); receipt[@"absentObservations"] = @2;
                    return receipt;
                }
            } else {
                emptyObservations = 0;
                if (pass == 0 && terminate) for (LBXDrainProcess *row in matches) {
                    now = [backend monotonicTime];
                    if (!isfinite(now) || now < previous || now - started >= timeout) {
                        receipt[@"reason"] = @"deadline_exceeded"; return receipt;
                    }
                    previous = now;
                    if (!LBXSameTarget(target, [backend resolve:bundleID error:&error])) {
                        receipt[@"reason"] = @"registration_changed"; return receipt;
                    }
                    now = [backend monotonicTime];
                    if (!isfinite(now) || now < previous || now - started >= timeout) {
                        receipt[@"reason"] = @"deadline_exceeded"; return receipt;
                    }
                    previous = now;
                    RBXProcessIdentityResult result = [backend terminate:row.identity];
                    if (result == RBXProcessTerminationRequested) receipt[@"terminationRequests"] = @(++requests);
                    else if (result != RBXProcessGone) {
                        receipt[@"reason"] = result == RBXProcessChanged ? @"process_identity_changed" : @"termination_denied";
                        return receipt;
                    }
                }
            }
            if (![backend pause]) { receipt[@"reason"] = @"pause_failed"; return receipt; }
        }
        receipt[@"reason"] = @"observation_limit";
    } @catch (__unused NSException *exception) {
        receipt[@"status"] = @"failed"; receipt[@"reason"] = @"backend_exception";
    }
    return receipt;
}
