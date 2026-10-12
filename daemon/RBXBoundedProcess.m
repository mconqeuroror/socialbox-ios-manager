#import "RBXInstallPaths.h"
#import "RBXBoundedProcess.h"
#import "RBXOperationContext.h"
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <pthread.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <time.h>
#import <unistd.h>

NSString *const RBXBoundedProcessErrorDomain = @"com.redditbox.bounded-process";

static double RBXProcessClock(void) {
    struct timespec now;
    return clock_gettime(CLOCK_MONOTONIC, &now) == 0
        ? now.tv_sec + now.tv_nsec / 1e9 : -1;
}

static NSError *RBXChildError(NSInteger code, NSString *message, BOOL quiescent) {
    return [NSError errorWithDomain:RBXBoundedProcessErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message,
                   @"childQuiescent": @(quiescent), @"childStarted": @NO}];
}

// The unreaped leader reserves the group ID until all other members have
// stopped. A failed enumeration is never equivalent to an empty process group.
static BOOL RBXGroupStopped(pid_t leader, NSError **error) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, leader};
    for (NSUInteger attempt = 0; attempt < 4; attempt++) {
        size_t size = 0;
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size > 64 * 1024 * 1024) break;
        size_t capacity = size + 16 * sizeof(struct kinfo_proc);
        struct kinfo_proc *records = calloc(1, capacity);
        if (!records) break;
        size_t used = capacity;
        int result = sysctl(mib, 4, records, &used, NULL, 0);
        int saved = errno;
        if (result == 0 && used <= capacity && used % sizeof(*records) == 0) {
            BOOL stopped = YES, foundLeader = NO;
            for (size_t i = 0; i < used / sizeof(*records); i++) {
                if (records[i].kp_proc.p_pid == leader) foundLeader = YES;
                if (records[i].kp_proc.p_pid != leader && records[i].kp_proc.p_stat != SZOMB)
                    stopped = NO;
            }
            free(records);
            if (!foundLeader) {
                if (error) *error = RBXChildError(6, @"Helper left its owned process group or the group snapshot was incomplete", NO);
                return NO;
            }
            return stopped;
        }
        free(records);
        if (result == 0 || saved != ENOMEM) break;
    }
    if (error) *error = RBXChildError(6, @"Could not prove that the helper process group stopped", NO);
    return NO;
}

@interface RBXOwnedChild : NSObject {
@public
    pthread_mutex_t lock;
    pid_t pid;
    BOOL anchored;
}
@end
@implementation RBXOwnedChild
- (instancetype)init { if ((self = [super init])) pthread_mutex_init(&lock, NULL); return self; }
- (void)dealloc { pthread_mutex_destroy(&lock); }
@end

@implementation RBXBoundedProcess
+ (BOOL)runExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
               context:(RBXOperationContext *)context outputPath:(NSString *)outputPath
    maximumOutputBytes:(NSUInteger)limit error:(NSError **)error {
    return [self runExecutable:executable arguments:arguments context:context
        maximumDuration:0 outputPath:outputPath maximumOutputBytes:limit error:error];
}
+ (BOOL)runExecutable:(NSString *)executable arguments:(NSArray<NSString *> *)arguments
               context:(RBXOperationContext *)context maximumDuration:(NSTimeInterval)duration
            outputPath:(NSString *)outputPath maximumOutputBytes:(NSUInteger)limit error:(NSError **)error {
    NSError *entryError = nil;
    if (!context || ![context beginWork:&entryError]) {
        if (error) *error = RBXChildError(1, entryError ? entryError.localizedDescription :
            @"A bounded operation context is required", YES);
        return NO;
    }
    RBXOwnedChild *child = [RBXOwnedChild new];
    NSString *registration = nil;
    int capture = -1, readFD = -1, writeFD = -1;
    BOOL success = NO, quiescent = YES, spawned = NO;
    BOOL exitStatusReaped = NO;
    int exitStatus = -1;
    NSError *failure = nil;
    double started = RBXProcessClock();
    double stageDeadline = isfinite(duration) && duration > 0
        ? MIN(context.deadlineMonotonic, started + duration) : context.deadlineMonotonic;
    @try {
        if (started < 0) { failure = RBXChildError(4, @"Helper deadline clock failed", YES); return NO; }
        if (![executable isKindOfClass:NSString.class] || !executable.isAbsolutePath ||
            ![arguments isKindOfClass:NSArray.class] || (outputPath &&
            (![outputPath isKindOfClass:NSString.class] || !outputPath.isAbsolutePath || !limit))) {
            failure = RBXChildError(1, @"Invalid bounded helper invocation", YES);
            return NO;
        }
        for (id argument in arguments) {
            if (![argument isKindOfClass:NSString.class] ||
                [argument rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound) {
                failure = RBXChildError(1, @"Invalid helper argument", YES); return NO;
            }
        }
        if (outputPath) {
            capture = open(outputPath.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            int descriptors[2];
            if (capture < 0 || pipe(descriptors) != 0) {
                failure = RBXChildError(2, @"Could not create private helper output", YES); return NO;
            }
            readFD = descriptors[0]; writeFD = descriptors[1];
            if (fcntl(readFD, F_SETFL, O_NONBLOCK) < 0 ||
                fcntl(readFD, F_SETFD, FD_CLOEXEC) < 0 || fcntl(writeFD, F_SETFD, FD_CLOEXEC) < 0) {
                failure = RBXChildError(2, @"Could not configure bounded helper output", YES); return NO;
            }
        }
        registration = [context registerCancellationHandler:^{
            // posix_spawn itself can stall while holding the ownership lock.
            // Cancellation must still return so its supervisor can close/fence.
            // The runner observes the canceled context as soon as spawn returns.
            if (pthread_mutex_trylock(&child->lock) != 0) return;
            if (child->anchored) kill(-child->pid, SIGTERM);
            pthread_mutex_unlock(&child->lock);
        }];
        posix_spawnattr_t attributes;
        posix_spawn_file_actions_t actions;
        int setup = posix_spawnattr_init(&attributes);
        if (setup != 0) { failure = RBXChildError(3, @"Could not initialize helper attributes", YES); return NO; }
        int actionsSetup = posix_spawn_file_actions_init(&actions);
        if (actionsSetup != 0) {
            posix_spawnattr_destroy(&attributes);
            failure = RBXChildError(3, @"Could not initialize helper descriptors", YES); return NO;
        }
        setup = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
        if (!setup) setup = posix_spawnattr_setpgroup(&attributes, 0);
        if (!setup) setup = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        if (!setup) setup = outputPath
            ? posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
            : posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        if (!setup) setup = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        char **argv = calloc(arguments.count + 2, sizeof(char *));
        if (!argv) setup = ENOMEM;
        if (argv) {
            argv[0] = (char *)executable.fileSystemRepresentation;
            for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = (char *)arguments[i].UTF8String;
        }
        NSString *searchPath = [NSString stringWithFormat:@"PATH=%@:%@:/usr/bin:/bin",
            RBXInstalledPath(@"/usr/bin"), RBXInstalledPath(@"/bin")];
        char *environment[] = {(char *)searchPath.UTF8String, NULL};
        if (!setup && ![context check:&failure]) setup = ECANCELED;
        pthread_mutex_lock(&child->lock);
        if (!setup && !context.cancelled) {
            setup = posix_spawn(&child->pid, executable.fileSystemRepresentation, &actions, &attributes, argv, environment);
            if (!setup) child->anchored = spawned = YES;
        } else if (!setup) setup = ECANCELED;
        pthread_mutex_unlock(&child->lock);
        free(argv);
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attributes);
        if (writeFD >= 0) { close(writeFD); writeFD = -1; }
        if (setup) {
            if (!failure) failure = RBXChildError(3,
                [NSString stringWithFormat:@"Could not spawn %@: %s", executable.lastPathComponent, strerror(setup)], YES);
            return NO;
        }

        NSUInteger captured = 0;
        BOOL terminating = NO, killed = NO, pipeEnded = !outputPath;
        double cleanupStarted = 0;
        for (;;) {
            double now = RBXProcessClock();
            if (!terminating && now >= stageDeadline)
                [context cancelWithReason:@"Helper stage deadline expired"];
            if (!terminating && (now < 0 || ![context check:&failure])) {
                if (!failure) failure = RBXChildError(4, @"Helper deadline clock failed", NO);
                terminating = YES; cleanupStarted = now;
                kill(-child->pid, SIGTERM);
            }
            if (readFD >= 0 && !pipeEnded) {
                // Each poll has a finite read budget, even when a child writes continuously.
                for (NSUInteger block = 0; block < 16; block++) {
                    char bytes[4096]; ssize_t count = read(readFD, bytes, sizeof(bytes));
                    if (count == 0) { pipeEnded = YES; break; }
                    if (count < 0) {
                        if (errno == EINTR) continue;
                        if (errno != EAGAIN && errno != EWOULDBLOCK)
                            failure = RBXChildError(5, @"Could not read helper output", NO);
                        break;
                    }
                    if ((NSUInteger)count > limit - captured) {
                        failure = RBXChildError(5, @"Helper output exceeded its byte limit", NO); break;
                    }
                    ssize_t offset = 0;
                    while (offset < count) {
                        ssize_t written = write(capture, bytes + offset, (size_t)(count - offset));
                        if (written < 0 && errno == EINTR) continue;
                        if (written <= 0) { failure = RBXChildError(5, @"Could not save helper output", NO); break; }
                        offset += written;
                    }
                    captured += (NSUInteger)count;
                    if (failure) break;
                }
            }
            if (failure && !terminating) {
                terminating = YES; cleanupStarted = now;
                kill(-child->pid, SIGTERM);
            }
            siginfo_t info = {};
            int observed = waitid(P_PID, (id_t)child->pid, &info, WEXITED | WNOHANG | WNOWAIT);
            if (observed < 0 && errno != EINTR) {
                failure = RBXChildError(6, @"Lost ownership of helper exit status", NO); break;
            }
            if (observed == 0 && info.si_pid == child->pid) {
                NSError *groupError = nil;
                BOOL stopped = RBXGroupStopped(child->pid, &groupError);
                if (groupError) { failure = groupError; break; }
                if (stopped && (pipeEnded || terminating)) {
                    pthread_mutex_lock(&child->lock);
                    pid_t reaped = waitpid(child->pid, &exitStatus, WNOHANG);
                    if (reaped == child->pid) {
                        child->anchored = NO;
                        exitStatusReaped = YES;
                    }
                    pthread_mutex_unlock(&child->lock);
                    quiescent = reaped == child->pid;
                    if (!quiescent) failure = RBXChildError(6, @"Could not reap helper", NO);
                    if (quiescent && !failure && WIFEXITED(exitStatus) && WEXITSTATUS(exitStatus) == 0)
                        success = YES;
                    else if (quiescent && !failure) failure = RBXChildError(7, @"Helper exited unsuccessfully", YES);
                    break;
                }
                // A successful leader may leave descendants; they remain owned
                // until they exit or the original operation deadline expires.
            }
            if (terminating) {
                if (!killed && (now < 0 || now - cleanupStarted >= 0.25)) {
                    kill(-child->pid, SIGKILL); killed = YES;
                }
                if (now < 0 || now - cleanupStarted >= 1.25) {
                    failure = RBXChildError(6, @"Helper did not reach a proven stopped state after cancellation", NO); break;
                }
            }
            usleep(10000);
        }
        if (success && capture >= 0 && fsync(capture) != 0) {
            success = NO; failure = RBXChildError(5, @"Could not flush helper output", YES);
        }
        if (success && ![context check:&failure]) success = NO;
        return success;
    } @finally {
        if (spawned && child->anchored) {
            quiescent = NO;
            pthread_mutex_lock(&child->lock);
            kill(-child->pid, SIGKILL);
            // Keep the leader unreaped: its reserved PID anchors the group.
            // A daemon restart/recovery boundary is required before new work.
            pthread_mutex_unlock(&child->lock);
            [context markUnsafeWithReason:[NSString stringWithFormat:
                @"Helper process group %d could not be proven stopped; preserve its operation recovery evidence", child->pid] error:nil];
        }
        if (registration) [context unregisterCancellationHandler:registration];
        if (writeFD >= 0) close(writeFD);
        if (readFD >= 0) close(readFD);
        if (capture >= 0) close(capture);
        if (!success && error) {
            NSMutableDictionary *details = [failure.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
            details[NSLocalizedDescriptionKey] = failure.localizedDescription ?: @"Bounded helper failed";
            details[@"childQuiescent"] = @(quiescent);
            details[@"childStarted"] = @(spawned);
            [details removeObjectForKey:@"exitCode"];
            [details removeObjectForKey:@"terminationSignal"];
            if (exitStatusReaped) {
                if (WIFEXITED(exitStatus)) details[@"exitCode"] = @(WEXITSTATUS(exitStatus));
                else if (WIFSIGNALED(exitStatus)) details[@"terminationSignal"] = @(WTERMSIG(exitStatus));
            }
            *error = [NSError errorWithDomain:failure.domain ?: RBXBoundedProcessErrorDomain
                code:failure ? failure.code : 1 userInfo:details];
        }
        // Unsafe child ownership remains counted as well as durably fenced.
        if (quiescent) [context endWork];
    }
}
@end
