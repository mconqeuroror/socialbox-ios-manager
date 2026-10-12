#import "RBXInstallPaths.h"
#import "RBXProcessController.h"
#import "RBXBoundedProcess.h"
#import "RBXOperationContext.h"
#import "RBXAppProcess.h"
#import "RBXProcessIdentity.h"
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import "RBXProc.h"
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <errno.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <time.h>
#import <math.h>

static void RBXProcessError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.proc" code:6
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *RBXProcessBirth(pid_t pid, NSString *executable, NSError **error) {
    RBXObservedProcess observed;
    if (RBXObserveProcess(pid, &observed) != RBXProcessObserved ||
        ![[[NSString stringWithUTF8String:observed.executable] stringByResolvingSymlinksInPath] isEqual:executable]) {
        RBXProcessError(error, @"Application process birth and executable could not be proven");
        return nil;
    }
    return @{@"processStartSeconds":@(observed.startSeconds),
        @"processStartMicroseconds":@(observed.startMicroseconds)};
}

static NSTimeInterval RBXMonotonicTime(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return NAN;
    return value.tv_sec + value.tv_nsec / 1e9;
}

static NSString *RBXRegisteredExecutable(NSString *identifier, NSString *expectedBundle, NSError **error) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW))
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    });
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![cls respondsToSelector:lookup]) {
        RBXProcessError(error, @"LaunchServices lookup is unavailable"); return nil;
    }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(cls, lookup, identifier);
    SEL bundleURL = NSSelectorFromString(@"bundleURL");
    if (![proxy respondsToSelector:bundleURL]) {
        RBXProcessError(error, @"application is not registered with LaunchServices"); return nil;
    }
    id value = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURL);
    NSString *bundle = [value isKindOfClass:NSURL.class] && [value isFileURL]
        ? [[value path] stringByResolvingSymlinksInPath] : nil;
    NSDictionary *info = bundle.length ? [NSDictionary dictionaryWithContentsOfFile:
        [bundle stringByAppendingPathComponent:@"Info.plist"]] : nil;
    NSString *name = [info[@"CFBundleExecutable"] isKindOfClass:NSString.class] ? info[@"CFBundleExecutable"] : nil;
    if (!bundle.isAbsolutePath || ![identifier isEqual:info[@"CFBundleIdentifier"]] ||
        !name.length || ![name isEqualToString:name.lastPathComponent] ||
        [@[@".", @".."] containsObject:name] || [name containsString:@"\\"] ||
        (expectedBundle.length && ![bundle isEqualToString:expectedBundle.stringByResolvingSymlinksInPath])) {
        RBXProcessError(error, @"registered application bundle or executable does not match the requested app"); return nil;
    }
    NSString *executable = [[bundle stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
    if (![executable hasPrefix:[bundle stringByAppendingString:@"/"]] ||
        ![NSFileManager.defaultManager isExecutableFileAtPath:executable]) {
        RBXProcessError(error, @"registered application executable is missing or outside its bundle"); return nil;
    }
    SEL canonical = NSSelectorFromString(@"canonicalExecutablePath");
    if ([proxy respondsToSelector:canonical]) {
        id path = ((id (*)(id, SEL))objc_msgSend)(proxy, canonical);
        if (![path isKindOfClass:NSString.class] ||
            ![[path stringByResolvingSymlinksInPath] isEqualToString:executable]) {
            RBXProcessError(error, @"LaunchServices executable disagrees with the registered bundle"); return nil;
        }
    }
    return executable;
}

// Shared proven kernel snapshot for kill filtering and exact-app launch checks.
// A failed read remains different from a successful snapshot with no matches.
static NSDictionary<NSNumber *, NSString *> *RBXProcessPathsOnce(NSError **error) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    struct kinfo_proc *procs = NULL;
    for (unsigned attempt = 0; attempt < 4; attempt++) {
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 ||
            size == 0 || size > 64 * 1024 * 1024) {
            RBXProcessError(error, @"cannot size the kernel process table"); return nil;
        }
        size_t capacity = size + 64 * sizeof(struct kinfo_proc);
        procs = malloc(capacity);
        if (!procs) { RBXProcessError(error, @"process table allocation failed"); return nil; }
        size = capacity;
        int result = sysctl(mib, 4, procs, &size, NULL, 0);
        int savedError = errno;
        if (result == 0 && size > 0 && size <= capacity && size % sizeof(*procs) == 0) break;
        free(procs); procs = NULL;
        if (result != 0 && savedError != ENOMEM) {
            RBXProcessError(error, @"cannot read the kernel process table"); return nil;
        }
    }
    if (!procs) { RBXProcessError(error, @"process table kept changing after four attempts"); return nil; }
    NSMutableDictionary *paths = [NSMutableDictionary dictionary];
    size_t count = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        pid_t candidate = procs[i].kp_proc.p_pid;
        if (candidate <= 1 || candidate == getpid() || procs[i].kp_proc.p_stat == SZOMB) continue;
        char executablePath[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int pathLength = proc_pidpath(candidate, executablePath, sizeof(executablePath));
        if (pathLength <= 0) {
            // EPERM is not proof that a live process is absent.
            if (kill(candidate, 0) == -1 && errno == ESRCH) continue;
            free(procs); RBXProcessError(error, @"cannot read a live process executable path"); return nil;
        }
        NSString *path = pathLength < sizeof(executablePath)
            ? [NSString stringWithUTF8String:executablePath] : nil;
        if (!path.length) {
            free(procs); RBXProcessError(error, @"invalid or truncated process path"); return nil;
        }
        paths[@(candidate)] = path;
    }
    free(procs);
    return paths;
}

// A PID can exit after the kernel table was copied but before proc_pidpath.
// Retry the complete proof, never drop an unreadable live PID from a partial
// result. Persistent denial still blocks after this bounded 40 ms retry window.
static NSDictionary<NSNumber *, NSString *> *RBXProcessPaths(NSError **error) {
    NSError *failure=nil;
    for(unsigned attempt=0;attempt<3;attempt++){
        failure=nil;
        NSDictionary *paths=RBXProcessPathsOnce(&failure);
        if(paths)return paths;
        if(attempt<2)usleep(20000);
    }
    if(error)*error=failure;
    return nil;
}

static NSString *RBXUIOpenPath(NSError **error) {
    for (NSString *candidate in @[RBXInstalledPath(@"/usr/bin/uiopen"), @"/usr/bin/uiopen"]) {
        NSString *path = candidate.stringByResolvingSymlinksInPath;
        struct stat info;
        if (stat(path.fileSystemRepresentation, &info) == 0 && S_ISREG(info.st_mode) &&
            info.st_uid == 0 && !(info.st_mode & 0022) &&
            [NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    RBXProcessError(error, @"a trusted uiopen helper is unavailable; install uikittools 2.1.6 or newer");
    return nil;
}

// Classify the registered executable, never a shared process-name prefix.
static BOOL RBXIsAppExecutable(NSDictionary *descriptor, NSString *processPath, NSError **error) {
    if (!RBXAppProcessDescriptorValid(descriptor)) {
        RBXProcessError(error, @"Process inspection requires a registered app descriptor"); return NO;
    }
    // The daemon is an unbundled executable and cannot qualify as an app.
    // Launcher/firewall identifiers are additionally rejected by the classifier.
    if ([processPath.lastPathComponent isEqual:@"redditboxd"]) return NO;
    NSRange appEnd = [processPath rangeOfString:@".app/"];
    if (appEnd.location == NSNotFound) return NO;
    NSString *bundle = [[processPath substringToIndex:appEnd.location + 4]
        stringByResolvingSymlinksInPath];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundle stringByAppendingPathComponent:@"Info.plist"]];
    NSString *identifier = [info[@"CFBundleIdentifier"] isKindOfClass:NSString.class]
        ? info[@"CFBundleIdentifier"] : nil;
    NSDictionary *marker = [identifier hasPrefix:descriptor[@"cloneBundlePrefix"]]
        ? [NSDictionary dictionaryWithContentsOfFile:
            [bundle stringByAppendingPathComponent:descriptor[@"cloneMarkerName"]]] : nil;
    if (!RBXAppProcessCandidate(descriptor, info, marker, error)) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep the framework loaded for the lifetime of its runtime classes.
        if (!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW))
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    });
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![cls respondsToSelector:lookup]) {
        RBXProcessError(error, @"LaunchServices lookup is unavailable"); return NO;
    }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(cls, lookup, identifier);
    SEL bundleURL = NSSelectorFromString(@"bundleURL");
    if (![proxy respondsToSelector:bundleURL]) {
        RBXProcessError(error, @"cannot query the running app registration"); return NO;
    }
    id registered = ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURL);
    NSString *registeredPath = [registered isKindOfClass:NSURL.class] && [registered isFileURL]
        ? [[registered path] stringByResolvingSymlinksInPath] : nil;
    NSString *resolvedProcess = processPath.stringByResolvingSymlinksInPath;
    // Keep the main-app fast path: polling it does not enumerate plugin files.
    if (RBXAppProcessExecutableName(info[@"CFBundleExecutable"]) &&
        [resolvedProcess isEqual:[bundle stringByAppendingPathComponent:info[@"CFBundleExecutable"]]])
        return RBXAppProcessRegisteredMatch(descriptor, resolvedProcess, bundle, info, marker,
            registeredPath, @[], error);
    // Only extensions actually embedded in the registered source bundle qualify.
    NSString *plugins = [bundle stringByAppendingPathComponent:@"PlugIns"];
    NSMutableArray *extensions = [NSMutableArray array];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        if (![entry.pathExtension isEqualToString:@"appex"]) continue;
        NSString *extension = [plugins stringByAppendingPathComponent:entry];
        NSDictionary *extensionInfo = [NSDictionary dictionaryWithContentsOfFile:
            [extension stringByAppendingPathComponent:@"Info.plist"]];
        [extensions addObject:@{@"bundlePath":extension.stringByResolvingSymlinksInPath,
            @"info":extensionInfo ?: @{}}];
    }
    return RBXAppProcessRegisteredMatch(descriptor, resolvedProcess,
        bundle, info, marker, registeredPath, extensions, error);
}

static NSString *const kBindingFile = @"/var/mobile/Library/Preferences/com.redditbox.activeContainer";
static NSString *const kNetworkLeaseFile =
    @"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist";

@implementation RBXProcessController {
    NSDictionary *_appDescriptor;
    NSDictionary *_activeIdentity;
    dispatch_source_t _watchTimer;
    NSString *_watchToken;
    NSUInteger _terminationObservationInFlight;
}

- (instancetype)init { return [self initWithAppDescriptor:RBXRedditAppDescriptor()]; }

- (instancetype)initWithAppDescriptor:(NSDictionary *)descriptor {
    if (!RBXAppProcessDescriptorValid(descriptor)) return nil;
    if ((self = [super init])) _appDescriptor = [descriptor copy];
    return self;
}

- (NSDictionary *)appDescriptor { return _appDescriptor; }

- (BOOL)_matchesProfileApp:(NSDictionary *)profile error:(NSError **)error {
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!descriptor || ![descriptor isEqual:_appDescriptor]) {
        RBXProcessError(error, @"Profile app does not match the process controller"); return NO;
    }
    return YES;
}

- (pid_t)activeClonePID { @synchronized (self) { return [_activeIdentity[@"pid"] intValue]; } }
- (NSDictionary *)activeCloneIdentity { @synchronized (self) { return [_activeIdentity copy]; } }
- (NSUInteger)terminationObservationInFlight { @synchronized (self) { return _terminationObservationInFlight; } }

- (void)_setActiveCloneIdentity:(NSDictionary *)identity {
    @synchronized (self) { _activeIdentity = [identity copy]; }
}

- (void)stopWatchingAppTermination {
    @synchronized (self) {
        _watchToken = nil;
        if (_watchTimer) dispatch_source_cancel(_watchTimer);
        _watchTimer = nil;
    }
}

- (BOOL)isProfileStopped:(NSDictionary *)profile error:(NSError **)error {
    if (![self _matchesProfileApp:profile error:error]) return NO;
    NSString *identifier = [profile[@"app"][@"bundleIdentifier"] isKindOfClass:NSString.class]
        ? profile[@"app"][@"bundleIdentifier"] : nil;
    NSString *container = [profile[@"containerId"] isKindOfClass:NSString.class] ? profile[@"containerId"] : nil;
    if (!container.length || ![identifier isEqual:RBXAppBundleIdentifier(_appDescriptor, container)]) {
        RBXProcessError(error, @"Replacement target has no verified clone identity"); return NO;
    }
    NSString *bundlePath = [profile[@"app"][@"bundlePath"] isKindOfClass:NSString.class]
        ? profile[@"app"][@"bundlePath"] : nil;
    NSString *executable = RBXRegisteredExecutable(identifier, bundlePath, error);
    if (!executable) return NO;
    NSDictionary *paths = RBXProcessPaths(error);
    if (!paths) return NO;
    NSString *bundle = executable.stringByDeletingLastPathComponent;
    for (NSString *path in paths.allValues) {
        NSString *resolved = path.stringByResolvingSymlinksInPath;
        if ([resolved isEqual:executable] || [resolved hasPrefix:[bundle stringByAppendingString:@"/"]]) {
            NSError *identityError = nil;
            BOOL appProcess = RBXIsAppExecutable(_appDescriptor, path, &identityError);
            if (identityError) { if (error) *error = identityError; return NO; }
            if (appProcess) { RBXProcessError(error, @"Replacement refused: the target clone is running; close it first"); return NO; }
            RBXProcessError(error, @"A live executable in the target bundle cannot be classified"); return NO;
        }
    }
    return YES;
}

- (NSArray<NSNumber *> *)appPids:(NSError **)error {
    NSDictionary<NSNumber *, NSString *> *paths = RBXProcessPaths(error);
    if (!paths) return nil;
    NSMutableArray *pids = [NSMutableArray array];
    for (NSNumber *pid in paths) {
        NSError *identityError = nil;
        if (RBXIsAppExecutable(_appDescriptor, paths[pid], &identityError)) [pids addObject:pid];
        if (identityError) { if (error) *error = identityError; return nil; }
    }
    return pids;
}

+ (pid_t)launchRegisteredBundleIdentifier:(NSString *)bundleIdentifier
                      expectedBundlePath:(NSString *)bundlePath
                                 timeout:(NSTimeInterval)timeout
                                   error:(NSError **)error {
    return [self launchRegisteredBundleIdentifier:bundleIdentifier expectedBundlePath:bundlePath
        timeout:timeout context:RBXOperationContext.currentContext error:error];
}

+ (pid_t)launchRegisteredBundleIdentifier:(NSString *)bundleIdentifier
                      expectedBundlePath:(NSString *)bundlePath
                                 timeout:(NSTimeInterval)timeout
                                 context:(RBXOperationContext *)context
                                   error:(NSError **)error {
    BOOL setupHost = [bundleIdentifier isEqualToString:@"com.redditbox.firewall"];
    if (!context || (context.inspectionOnly && !setupHost)) {
        RBXProcessError(error, @"A bounded mutating context is required to launch this application"); return -1;
    }
    if (![context beginWork:error]) return -1;
    @try {
        if (![bundleIdentifier isKindOfClass:NSString.class] || !bundleIdentifier.length ||
            (bundlePath && (![bundlePath isKindOfClass:NSString.class] || !bundlePath.isAbsolutePath)) ||
            !isfinite(timeout) || timeout <= 0) {
            RBXProcessError(error, @"invalid registered application launch request"); return -1;
        }
        NSString *executable = RBXRegisteredExecutable(bundleIdentifier, bundlePath, error);
        if (!executable) return -1;
        NSString *helper = RBXUIOpenPath(error);
        if (!helper) return -1;
        NSTimeInterval started = RBXMonotonicTime();
        if (!isfinite(started)) { RBXProcessError(error, @"cannot measure the app launch deadline"); return -1; }
        NSTimeInterval deadline = MIN(context.deadlineMonotonic, started + MIN(timeout, 30.0));
        BOOL requested = NO;
        BOOL proven = NO;
        @try {
            requested = YES;
            NSError *helperError = nil;
            if (![RBXBoundedProcess runExecutable:helper arguments:@[@"--bundleid", bundleIdentifier]
                context:context maximumDuration:MIN(5.0, deadline - started)
                outputPath:nil maximumOutputBytes:0 error:&helperError]) {
                if ([@NO isEqual:helperError.userInfo[@"childStarted"]]) requested = NO;
                if (error) *error = helperError;
                return -1;
            }
            do {
                if (![context check:error]) return -1;
                NSDictionary<NSNumber *, NSString *> *paths = RBXProcessPaths(error);
                if (!paths) return -1;
                for (NSNumber *pidNumber in paths) {
                    if (![[paths[pidNumber] stringByResolvingSymlinksInPath] isEqualToString:executable]) continue;
                    // Registration and the PID can change during the helper call or
                    // snapshot. Check both again immediately before accepting this app.
                    NSString *registered = RBXRegisteredExecutable(bundleIdentifier, bundlePath, error);
                    if (!registered) return -1;
                    if (![registered isEqualToString:executable]) {
                        RBXProcessError(error, @"application registration changed during launch"); return -1;
                    }
                    char actualPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
                    pid_t pid = pidNumber.intValue;
                    int length = proc_pidpath(pid, actualPath, sizeof(actualPath));
                    if (length <= 0) {
                        if (kill(pid, 0) == -1 && errno == ESRCH) continue;
                        RBXProcessError(error, @"cannot verify the launched application's executable path"); return -1;
                    }
                    NSString *actual = length < sizeof(actualPath) ? [NSString stringWithUTF8String:actualPath] : nil;
                    if (!actual.length) { RBXProcessError(error, @"launched application path is invalid or truncated"); return -1; }
                    if ([actual.stringByResolvingSymlinksInPath isEqualToString:executable] && [context check:error]) { proven = YES; return pid; }
                }
                [NSThread sleepForTimeInterval:0.05];
            } while (RBXMonotonicTime() < deadline);
            RBXProcessError(error, @"uiopen returned, but the exact registered application process did not appear before the launch deadline");
            return -1;
        } @finally {
            if (requested && !proven) [context markUnsafeWithReason:
                @"App launch may already be queued in SpringBoard; exact launch completion was not proven" error:nil];
        }
    } @finally { [context endWork]; }
}

+ (void)killAllRedditProcesses {
    [self killAllProcessesForAppDescriptor:RBXRedditAppDescriptor()];
}

+ (void)killAllProcessesForAppDescriptor:(NSDictionary *)descriptor {
    RBXProcessController *controller = [[self alloc] initWithAppDescriptor:descriptor];
    if (!controller) { NSLog(@"redditboxd: process kill refused: unknown app descriptor"); return; }
    [controller killAppProcesses];
}

- (void)killReddit { [self killAppProcesses]; }

- (void)killAppProcesses {
    NSError *error = nil;
    NSArray *pids = [self appPids:&error];
    if (!pids) { NSLog(@"redditboxd: process enumeration FAILED: %@", error); return; }
    // Capture the whole batch before any termination. A PID from the earlier
    // ownership snapshot is only a candidate, never a durable process identity.
    NSMutableArray<NSData *> *identities = [NSMutableArray array];
    for (NSNumber *pid in pids) {
        RBXObservedProcess identity;
        RBXProcessIdentityResult result = RBXObserveProcess(pid.intValue, &identity);
        if (result == RBXProcessGone || result == RBXProcessChanged) continue;
        if (result != RBXProcessObserved) {
            NSLog(@"redditboxd: process identity observation FAILED; stop remains unverified");
            return;
        }
        [identities addObject:[NSData dataWithBytes:&identity length:sizeof(identity)]];
    }
    if (!identities.count) return;
    // Recheck registered app ownership after capture. The termination primitive
    // then checks birth/path again before and after obtaining the stable task
    // right. A stale PID, changed executable, or denied task right has no kill()
    // fallback. killAllAndWait still independently proves exit/socket absence.
    NSArray *authorized = [self appPids:&error];
    if (!authorized) { NSLog(@"redditboxd: process reauthorization FAILED: %@", error); return; }
    NSSet *members = [NSSet setWithArray:authorized];
    for (NSData *value in identities) {
        RBXObservedProcess identity;
        [value getBytes:&identity length:sizeof(identity)];
        if (![members containsObject:@(identity.pid)]) continue;
        RBXProcessIdentityResult result = RBXTerminateObservedProcess(&identity);
        if (result == RBXProcessDenied) {
            NSLog(@"redditboxd: task termination denied; stop remains unverified");
            return;
        }
    }
}

- (BOOL)verifyNoRedditSocketsForInterval:(NSTimeInterval)interval
                                   error:(NSError **)error {
    return [self verifyNoAppSocketsForInterval:interval error:error];
}

- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval error:(NSError **)error {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (context && ![context check:error]) return NO;
    NSTimeInterval now = RBXMonotonicTime();
    NSTimeInterval deadline = now + MAX(interval + 2.0, 3.0);
    if (context) deadline = MIN(deadline, context.deadlineMonotonic);
    return [self _verifyNoAppSocketsForInterval:interval deadline:deadline context:context error:error];
}

- (BOOL)_verifyNoAppSocketsForInterval:(NSTimeInterval)interval
    deadline:(NSTimeInterval)deadline context:(RBXOperationContext *)context error:(NSError **)error {
    NSTimeInterval cleanSince = 0;
    while (RBXMonotonicTime() < deadline) {
        if (context && ![context check:error]) return NO;
        NSArray<NSNumber *> *pids = [self appPids:error];
        if (!pids) return NO;
        BOOL clean = pids.count == 0;
        for (NSNumber *pidNumber in pids) {
            pid_t pid = pidNumber.intValue;
            int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
            if (bytes <= 0) {
                if (!(kill(pid, 0) == -1 && errno == ESRCH)) {
                    if (error) *error = [NSError errorWithDomain:@"com.redditbox.proc"
                        code:2 userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"cannot inspect a live %@ process fd table", _appDescriptor[@"displayName"]]}];
                    return NO;
                }
                continue;
            }
            struct proc_fdinfo *fds = malloc((size_t)bytes);
            if (!fds) {
                if (error) *error = [NSError errorWithDomain:@"com.redditbox.proc"
                    code:3 userInfo:@{NSLocalizedDescriptionKey: @"fd table allocation failed"}];
                return NO;
            }
            int readBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
            if (readBytes <= 0 && !(kill(pid, 0) == -1 && errno == ESRCH)) {
                free(fds);
                if (error) *error = [NSError errorWithDomain:@"com.redditbox.proc"
                    code:4 userInfo:@{NSLocalizedDescriptionKey:
                        @"kernel fd table changed during socket verification"}];
                return NO;
            }
            int count = readBytes / (int)sizeof(struct proc_fdinfo);
            for (int index = 0; index < count; index++) {
                if (fds[index].proc_fdtype == PROX_FDTYPE_SOCKET) {
                    clean = NO;
                    break;
                }
            }
            free(fds);
        }
        if (clean) {
            if (!cleanSince) cleanSince = RBXMonotonicTime();
            if ((RBXMonotonicTime() - cleanSince) >= interval) {
                NSLog(@"redditboxd: KERNEL SOCKET TABLE CLEAN for %.2fs", interval);
                return YES;
            }
        } else {
            cleanSince = 0;
        }
        [NSThread sleepForTimeInterval:0.05];
    }
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.proc" code:5
        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ sockets did not reach a stable clean state", _appDescriptor[@"displayName"]]}];
    return NO;
}

- (BOOL)verifyNoAppSocketsForInterval:(NSTimeInterval)interval
                            deadline:(NSTimeInterval)deadline error:(NSError **)error {
    NSTimeInterval now = RBXMonotonicTime();
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (context && ![context check:error]) return NO;
    if (context) deadline = MIN(deadline, context.deadlineMonotonic);
    if (!isfinite(now) || !isfinite(interval) || interval < 0 ||
        !isfinite(deadline) || deadline <= now || interval > deadline - now) {
        RBXProcessError(error, @"Socket verification has no valid remaining monotonic budget");
        return NO;
    }
    return [self _verifyNoAppSocketsForInterval:interval deadline:deadline context:context error:error];
}

- (BOOL)killAllAndWait:(NSTimeInterval)timeout {
    NSError *bindingError = nil;
    BOOL bindingRevoked = [@"__blocked__" writeToFile:kBindingFile atomically:YES
                       encoding:NSUTF8StringEncoding error:&bindingError] &&
        [[NSString stringWithContentsOfFile:kBindingFile encoding:NSUTF8StringEncoding error:&bindingError]
            isEqual:@"__blocked__"];
    if (!bindingRevoked) NSLog(@"redditboxd: launch binding revocation could not be verified: %@", bindingError.localizedDescription);
    NSLog(@"redditboxd: %@ launch binding revoked; terminating all processes", _appDescriptor[@"displayName"]);
    NSTimeInterval deadline = RBXMonotonicTime() + (isfinite(timeout) ? MIN(30.0, MAX(0.1, timeout)) : 0.1);
    RBXOperationContext *context = RBXOperationContext.currentContext;
    // Ordinary transitions share their aggregate deadline. An explicit stop
    // after cancellation still gets the caller's bounded cleanup allowance.
    if (context && !context.cancelled) deadline = MIN(deadline, context.deadlineMonotonic);
    do {
        [self killAppProcesses];
        NSError *enumerationError = nil;
        NSArray *remaining = [self appPids:&enumerationError];
        if (!remaining) {
            NSLog(@"redditboxd: transition aborted: %@", enumerationError); return NO;
        }
        if (remaining.count == 0) {
            NSError *socketError = nil;
            if ([self _verifyNoAppSocketsForInterval:1.0 deadline:deadline context:nil error:&socketError]) {
                NSLog(@"redditboxd: all %@ traffic owners terminated", _appDescriptor[@"displayName"]);
                // Stopping processes does not excuse an unproven durable binding.
                return bindingRevoked;
            }
            NSLog(@"redditboxd: kernel socket verification not clean yet (%@)",
                  socketError.localizedDescription);
        }
        [NSThread sleepForTimeInterval:0.05];
    } while (RBXMonotonicTime() < deadline);
    NSLog(@"redditboxd: process termination verification FAILED");
    return NO;
}

- (BOOL)launchRedditCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    return [self launchCloneForProfile:profile error:error];
}

- (NSDictionary *)_launchNetworkLease { return [NSDictionary dictionaryWithContentsOfFile:kNetworkLeaseFile]; }
- (NSString *)_launchExecutableForIdentifier:(NSString *)identifier bundlePath:(NSString *)path error:(NSError **)error {
    return RBXRegisteredExecutable(identifier, path, error);
}
- (BOOL)_writeLaunchBinding:(NSString *)binding error:(NSError **)error {
    return [binding writeToFile:kBindingFile atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (BOOL)launchCloneForProfile:(NSDictionary *)profile error:(NSError **)error {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!context || context.inspectionOnly || ![context check:error]) {
        if (!context || context.inspectionOnly) RBXProcessError(error, @"Clone launch requires an active mutating operation");
        return NO;
    }

    if (![profile isKindOfClass:NSDictionary.class]) {
        RBXProcessError(error, @"clone launch refused: profile is unavailable"); return NO;
    }
    if (![self _matchesProfileApp:profile error:error]) return NO;
    NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
    NSString *containerId = [profile[@"containerId"] isKindOfClass:NSString.class] ? profile[@"containerId"] : nil;
    NSString *bundleIdentifier = [app[@"bundleIdentifier"] isKindOfClass:NSString.class] ? app[@"bundleIdentifier"] : nil;
    NSString *bundlePath = [app[@"bundlePath"] isKindOfClass:NSString.class] ? app[@"bundlePath"] : nil;
    if (!containerId.length || !bundleIdentifier.length || !bundlePath.isAbsolutePath ||
        ![bundleIdentifier isEqualToString:RBXAppBundleIdentifier(_appDescriptor, containerId)] ||
        ![@"clonedApp-v2" isEqual:app[@"architecture"]] ||
        ![@"ready" isEqual:app[@"cloneState"]] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:
            [bundlePath stringByAppendingPathComponent:_appDescriptor[@"cloneMarkerName"]]]) {
        RBXProcessError(error, @"clone launch refused: profile has no verified app clone");
        return NO;
    }
    NSArray *remaining = [self appPids:error];
    if (!remaining) return NO;
    if (remaining.count > 0) {
        RBXProcessError(error, [NSString stringWithFormat:@"clone launch refused: an old %@ process still exists", _appDescriptor[@"displayName"]]);
        return NO;
    }
    if (![context check:error]) return NO;
    NSDictionary *lease = [self _launchNetworkLease];
    if (![lease[@"state"] isEqual:@"armed"] ||
        ![lease[@"containerId"] isEqual:containerId] ||
        ![lease[@"bundleIdentifier"] isEqual:bundleIdentifier] ||
        ![lease[@"bootEpoch"] isEqual:RBXOperationContext.daemonBootEpoch] ||
        ![lease[@"generation"] isKindOfClass:NSString.class]) {
        RBXProcessError(error, @"Clone launch requires its current ARMED lease"); return NO;
    }
    NSString *executable = [self _launchExecutableForIdentifier:bundleIdentifier bundlePath:bundlePath error:error];
    if (!executable) return NO;
    [self _setActiveCloneIdentity:nil];

    // SpringBoard does not propagate the helper's environment to the app.
    // This binding is daemon bookkeeping; clone identity comes from its signed
    // bundle/profile and never from the shared binding file.
    if (![self _writeLaunchBinding:containerId error:error]) {
        [self _setActiveCloneIdentity:nil];
        return NO;
    }

    // Small settle so the killed process releases its container state before relaunch.
    [NSThread sleepForTimeInterval:0.3];
    NSError *launchError = nil;
    pid_t pid = [self.class launchRegisteredBundleIdentifier:bundleIdentifier
        expectedBundlePath:bundlePath timeout:15.0 error:&launchError];
    NSDictionary *birth = pid > 1 ? RBXProcessBirth(pid, executable, &launchError) : nil;
    if (!birth || ![context check:&launchError]) {
        if (pid > 1) [context markUnsafeWithReason:
            @"Launched app process identity changed before admission" error:nil];
        NSError *rollbackError = nil;
        BOOL revoked = [self _writeLaunchBinding:@"__blocked__" error:&rollbackError];
        [self _setActiveCloneIdentity:nil];
        if (!revoked) {
            RBXProcessError(error, [NSString stringWithFormat:@"%@; launch binding revocation also failed: %@",
                launchError.localizedDescription ?: @"clone launch failed", rollbackError.localizedDescription]);
        } else if (error) *error = launchError;
        return NO;
    }
    [self _setActiveCloneIdentity:@{@"containerId": containerId, @"bundleIdentifier": bundleIdentifier,
        @"executable": executable, @"pid": @(pid), @"generation": lease[@"generation"],
        @"bootEpoch": lease[@"bootEpoch"], @"processStartSeconds":birth[@"processStartSeconds"],
        @"processStartMicroseconds":birth[@"processStartMicroseconds"]}];
    NSLog(@"redditboxd: verified clone %@ PID %d for container %@ after network arm",
          bundleIdentifier, pid, containerId);
    return YES;
}

- (void)watchRedditTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit {
    [self watchAppTerminationOnQueue:queue onExit:onExit];
}

- (void)watchAppTerminationOnQueue:(dispatch_queue_t)queue
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit {
    if (!queue) { [self stopWatchingAppTermination]; return; }
    NSString *token = NSUUID.UUID.UUIDString;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 10, NSEC_PER_MSEC * 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) self = weakSelf;
        if (!self) return;
        @autoreleasepool {
            [self _sampleAppTerminationWithToken:token onExit:onExit];
        }
    });
    @synchronized (self) {
        if (_watchTimer) dispatch_source_cancel(_watchTimer);
        _watchToken = token; _watchTimer = timer;
    }
    // A concurrent cancel may precede resume. The invalid token still prevents
    // a later event from entering the handler; every source is resumed once.
    dispatch_resume(timer);
}

// Small overridable I/O boundaries retain the original production behavior and
// let native tests block the actual timer handler without kernel/device effects.
- (NSDictionary *)_terminationProcessPaths:(NSError **)error { return RBXProcessPaths(error); }
- (NSDictionary *)_terminationProcessBirthForIdentity:(NSDictionary *)identity error:(NSError **)error {
    return RBXProcessBirth([identity[@"pid"] intValue], identity[@"executable"], error);
}
- (NSDictionary *)_terminationNetworkLease { return [NSDictionary dictionaryWithContentsOfFile:kNetworkLeaseFile]; }
- (BOOL)_terminationMatchesProcessPath:(NSString *)path error:(NSError **)error {
    return RBXIsAppExecutable(_appDescriptor, path, error);
}
- (BOOL)_revokeTerminationBinding:(NSError **)error {
    return [@"__blocked__" writeToFile:kBindingFile atomically:YES encoding:NSUTF8StringEncoding error:error];
}
- (BOOL)_terminationToken:(NSString *)token matchesIdentity:(NSDictionary *)identity {
    @synchronized (self) {
        return [_watchToken isEqual:token] && (_activeIdentity == identity || [_activeIdentity isEqual:identity]);
    }
}

- (void)_sampleAppTerminationWithToken:(NSString *)token
    onExit:(void (^)(NSDictionary *identity, NSString *reason))onExit {
    NSDictionary *identity;
    @synchronized (self) {
        if (![_watchToken isEqual:token]) return;
        _terminationObservationInFlight++;
        identity = [_activeIdentity copy];
    }
    @try {
        NSError *failure = nil;
        NSDictionary *paths = [self _terminationProcessPaths:&failure];
        NSDictionary *lease = [self _terminationNetworkLease];
        BOOL authorized = identity &&
            ([lease[@"state"] isEqual:@"open"] || [lease[@"state"] isEqual:@"armed"]) &&
            [lease[@"expiresAt"] doubleValue] > NSDate.date.timeIntervalSince1970;
        for (NSString *key in @[@"containerId", @"bundleIdentifier", @"generation", @"bootEpoch"])
            authorized = authorized && [identity[key] isEqual:lease[key]];
        NSUInteger count = 0;
        BOOL matches = identity && [[paths[identity[@"pid"]] stringByResolvingSymlinksInPath] isEqual:identity[@"executable"]];
        if (matches) {
            NSDictionary *birth = [self _terminationProcessBirthForIdentity:identity error:&failure];
            matches = birth && [birth[@"processStartSeconds"] isEqual:identity[@"processStartSeconds"]] &&
                [birth[@"processStartMicroseconds"] isEqual:identity[@"processStartMicroseconds"]];
        }
        for (NSNumber *pid in paths) {
            NSError *classificationError = nil;
            if ([self _terminationMatchesProcessPath:paths[pid] error:&classificationError]) {
                count++;
                if (![pid isEqual:identity[@"pid"]] ||
                    ![[paths[pid] stringByResolvingSymlinksInPath] isEqual:identity[@"executable"]]) matches = NO;
            }
            if (classificationError) failure = classificationError;
        }
        if (![self _terminationToken:token matchesIdentity:identity]) return;
        if (!failure && !identity && count == 0) return;
        if (!failure && authorized && matches && count == 1) return;
        NSString *reason = failure ? @"Process enumeration could not be proven" :
            (count == 0 ? @"Active clone exited" : @"Unauthorized clone process or expired lease");
        // Notify synchronously before killing: traffic must close even when
        // enumeration or termination fails. The consumer checks generation.
        if (onExit) onExit(identity ?: lease ?: @{}, reason);
        if (![self _terminationToken:token matchesIdentity:identity]) return;
        NSError *bindingError = nil;
        if (![self _revokeTerminationBinding:&bindingError])
            NSLog(@"redditboxd: exit binding revocation failed: %@", bindingError.localizedDescription);
        [self killAppProcesses];
        // Retain identity while kernel state is unknown; retry each sample.
        @synchronized (self) {
            if (!failure && count == 0 && !bindingError && [_watchToken isEqual:token] &&
                (_activeIdentity == identity || [_activeIdentity isEqual:identity])) _activeIdentity = nil;
        }
    } @finally {
        // Count through the callback and binding/kill effects. A cancel after
        // the last token check cannot make global drain succeed before those
        // old effects finish. No state lock is held during I/O or callbacks.
        @synchronized (self) { _terminationObservationInFlight--; }
    }
}

@end
