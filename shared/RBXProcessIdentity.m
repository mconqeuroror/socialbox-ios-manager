#import "RBXProcessIdentity.h"
#include <sys/sysctl.h>
#include <sys/proc.h>
#import <Foundation/Foundation.h>
#include <mach/message.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

static RBXProcessIdentityResult RBXReadProcessBirth(pid_t pid, struct kinfo_proc *info) {
    memset(info, 0, sizeof(*info));
    if (pid <= 1 || pid == getpid()) return RBXProcessDenied;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    size_t size = sizeof(*info);
    int rc;
    unsigned attempts = 0;
    do {
        size = sizeof(*info);
        rc = sysctl(mib, 4, info, &size, NULL, 0);
        attempts++;
    } while (rc != 0 && errno == EINTR && attempts < 4);
    if (rc != 0) return errno == ESRCH ? RBXProcessGone : RBXProcessDenied;
    if (size == 0) return RBXProcessGone;
    if (size != sizeof(*info) || info->kp_proc.p_pid != pid) return RBXProcessDenied;
    if (info->kp_proc.p_stat == SZOMB) return RBXProcessGone;
    if (info->kp_proc.p_starttime.tv_sec <= 0 || info->kp_proc.p_starttime.tv_usec < 0 ||
        info->kp_proc.p_starttime.tv_usec >= 1000000) return RBXProcessDenied;
    return RBXProcessObserved;
}

static int RBXSameBirth(const struct kinfo_proc *a, const struct kinfo_proc *b) {
    return a->kp_proc.p_pid == b->kp_proc.p_pid &&
        a->kp_proc.p_starttime.tv_sec == b->kp_proc.p_starttime.tv_sec &&
        a->kp_proc.p_starttime.tv_usec == b->kp_proc.p_starttime.tv_usec;
}

RBXProcessIdentityResult RBXObserveProcess(pid_t pid, RBXObservedProcess *result) {
    if (!result) return RBXProcessDenied;
    memset(result, 0, sizeof(*result));
    struct kinfo_proc before, after;
    RBXProcessIdentityResult status = RBXReadProcessBirth(pid, &before);
    if (status != RBXProcessObserved) return status;
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = proc_pidpath(pid, path, sizeof(path));
    int savedError = errno;
    status = RBXReadProcessBirth(pid, &after);
    if (status != RBXProcessObserved) return status;
    if (!RBXSameBirth(&before, &after)) return RBXProcessChanged;
    if (length <= 0) return savedError == ESRCH ? RBXProcessChanged : RBXProcessDenied;
    size_t count = strnlen(path, sizeof(path));
    if (length >= (int)sizeof(path) || count == 0 || count >= sizeof(path) || path[0] != '/')
        return RBXProcessDenied;
    result->pid = pid;
    result->startSeconds = after.kp_proc.p_starttime.tv_sec;
    result->startMicroseconds = after.kp_proc.p_starttime.tv_usec;
    memcpy(result->executable, path, count + 1);
    return RBXProcessObserved;
}

static int RBXSameObservedProcess(const RBXObservedProcess *a, const RBXObservedProcess *b) {
    return a->pid == b->pid && a->startSeconds == b->startSeconds &&
        a->startMicroseconds == b->startMicroseconds && !strcmp(a->executable, b->executable);
}

// RunningBoard's handle predicate carries both process identity and PID. A PID
// predicate or bundle-wide terminate request is deliberately never constructed.
// The final service-to-kernel dispatch is owned by iOS; this is not a claim of
// an atomic PID-version signal API (that API is absent on iOS 16).
@interface NSObject (RBXRunningBoardStop)
+ (id)identifierWithPid:(int)pid;
+ (id)handleForIdentifier:(id)identifier error:(NSError **)error;
+ (id)predicateMatchingHandle:(id)handle;
+ (id)defaultContextWithExplanation:(NSString *)reason;
- (id)initWithPredicate:(id)predicate context:(id)context;
- (BOOL)execute:(NSError **)error;
- (BOOL)isValid;
- (int)pid;
- (NSString *)executablePath;
- (audit_token_t)auditToken;
@end

static NSString *RBXCanonicalProcessPath(const char *path) {
    NSString *value = path ? [NSString stringWithUTF8String:path] : nil;
    // Only the system /var alias is accepted here; never resolve arbitrary
    // process-controlled symlinks when comparing the independent observations.
    return [value hasPrefix:@"/var/"] ? [@"/private" stringByAppendingString:value] : value;
}

static BOOL RBXRequestIdentityScopedStop(const RBXObservedProcess *expected) {
    static dispatch_once_t once;
    static void *framework;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/RunningBoardServices.framework/RunningBoardServices", RTLD_NOW | RTLD_LOCAL);
    });
    if (!framework) return NO;
    Class identifierClass = NSClassFromString(@"RBSProcessIdentifier");
    Class handleClass = NSClassFromString(@"RBSProcessHandle");
    Class predicateClass = NSClassFromString(@"RBSProcessPredicate");
    Class contextClass = NSClassFromString(@"RBSTerminateContext");
    Class requestClass = NSClassFromString(@"RBSTerminateRequest");
    int (*pathForToken)(audit_token_t *, void *, uint32_t) = dlsym(RTLD_DEFAULT, "proc_pidpath_audittoken");
    if (!pathForToken || ![identifierClass respondsToSelector:@selector(identifierWithPid:)] ||
        ![handleClass respondsToSelector:@selector(handleForIdentifier:error:)] ||
        ![predicateClass respondsToSelector:@selector(predicateMatchingHandle:)] ||
        ![contextClass respondsToSelector:@selector(defaultContextWithExplanation:)] ||
        ![requestClass instancesRespondToSelector:@selector(initWithPredicate:context:)] ||
        ![requestClass instancesRespondToSelector:@selector(execute:)]) return NO;
    @try {
        NSError *error = nil;
        id identifier = [identifierClass identifierWithPid:expected->pid];
        NSObject *handle = identifier ? [handleClass handleForIdentifier:identifier error:&error] : nil;
        if (!handle || error || ![handle respondsToSelector:@selector(isValid)] ||
            ![handle respondsToSelector:@selector(pid)] ||
            ![handle respondsToSelector:@selector(executablePath)] ||
            ![handle respondsToSelector:@selector(auditToken)] || !handle.isValid ||
            handle.pid != expected->pid) return NO;
        NSString *expectedPath = RBXCanonicalProcessPath(expected->executable);
        NSString *handlePath = handle.executablePath;
        // RunningBoard omits executablePath for anonymous and some extension
        // handles. The mandatory token-bound kernel lookup below remains the
        // authority; a present, conflicting service path is still rejected.
        if (handlePath && (![handlePath isKindOfClass:NSString.class] ||
            ![RBXCanonicalProcessPath(handlePath.UTF8String) isEqual:expectedPath])) return NO;
        audit_token_t token = handle.auditToken;
        // Darwin audit_token_t val[5] is PID; val[7] is the exec/PID version.
        // libproc validates the token against the current kernel process.
        if (token.val[5] != (uint32_t)expected->pid) return NO;
        char tokenPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
        int length = pathForToken(&token, tokenPath, sizeof(tokenPath));
        if (length <= 0 || length >= (int)sizeof(tokenPath) ||
            strnlen(tokenPath, sizeof(tokenPath)) >= sizeof(tokenPath) ||
            ![RBXCanonicalProcessPath(tokenPath) isEqual:expectedPath]) return NO;
        id predicate = [predicateClass predicateMatchingHandle:handle];
        id context = [contextClass defaultContextWithExplanation:@"SocialBox container switch: stop verified application instance"];
        NSObject *request = predicate && context ? [[requestClass alloc] initWithPredicate:predicate context:context] : nil;
        if (!request) return NO;
        RBXObservedProcess current;
        if (RBXObserveProcess(expected->pid, &current) != RBXProcessObserved ||
            !RBXSameObservedProcess(expected, &current)) return NO;
        // This is an acknowledgement only. The coordinator must independently
        // observe complete process/socket drain before changing any container.
        error = nil;
        return [request execute:&error] && !error;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

RBXProcessIdentityResult RBXTerminateObservedProcess(const RBXObservedProcess *expected) {
    if (!expected || expected->pid <= 1 || expected->pid == getpid() || expected->startSeconds <= 0 ||
        expected->startMicroseconds < 0 || expected->startMicroseconds >= 1000000 ||
        expected->executable[0] != '/' || strnlen(expected->executable, sizeof(expected->executable)) >= sizeof(expected->executable))
        return RBXProcessDenied;
    RBXObservedProcess current;
    RBXProcessIdentityResult status = RBXObserveProcess(expected->pid, &current);
    if (status != RBXProcessObserved) return status;
    if (!RBXSameObservedProcess(expected, &current)) return RBXProcessChanged;
    if (RBXRequestIdentityScopedStop(expected)) return RBXProcessTerminationRequested;
    status = RBXObserveProcess(expected->pid, &current);
    if (status != RBXProcessObserved) return status;
    return RBXSameObservedProcess(expected, &current) ? RBXProcessDenied : RBXProcessChanged;
}
