#import "RBXPathHooks.h"
#import "RBXContainerManager.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <substrate.h>
#import <dispatch/dispatch.h>
#import <dirent.h>
#import <fcntl.h>
#import <limits.h>
#import <os/lock.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <sys/errno.h>
#import <unistd.h>
#import <copyfile.h>

// Data-container redirection + sibling hiding.
//
// Per-container data lives at <real home>/redditbox/containers/<container-id>/...
// - Paths under the real home are REWRITTEN into the container dir, so all app data
//   (UserDefaults, caches, cookies, SQLite, WKWebsiteDataStore…) lands in the container.
// - The redditbox/ tree itself and sibling containers are HIDDEN from existence checks
//   and directory listings, so the app can't see it shares the sandbox with 49 siblings.

static NSString *sRealHome;      // e.g. /var/mobile/Containers/Data/Application/UUID
static NSString *sContainerHome; // .../redditbox/containers/<container-id>
static NSString *sRbxRoot;       // .../redditbox
static NSString *sTempDirectory;
static NSString *sContainerIdentifier;
static NSArray<NSArray<NSString *> *> *sGroupScopes;
static os_unfair_lock sGroupScopesLock = OS_UNFAIR_LOCK_INIT;
static __thread unsigned sPathHookDepth;
static __thread unsigned sTrustedControlFileDepth;

void RBXBeginInternalControlFileAccess(void) {
    sTrustedControlFileDepth++;
}

void RBXEndInternalControlFileAccess(void) {
    if (sTrustedControlFileDepth) sTrustedControlFileDepth--;
}

#define RBX_LOG_HOOK_ONCE(hookName) do { \
    static dispatch_once_t onceToken; \
    dispatch_once(&onceToken, ^{ RBXLog("storage hook entered: " hookName); }); \
} while (0)

#define RBX_LOG_FOUNDATION_HOOK_ONCE(hookName) do { \
    if (!sPathHookDepth) { \
        sPathHookDepth++; \
        RBX_LOG_HOOK_ONCE(hookName); \
        sPathHookDepth--; \
    } \
} while (0)

static BOOL rbxPathIsEqualOrChild(NSString *path, NSString *root) {
    if (!path || !root) return NO;
    return [path isEqualToString:root] ||
           [path hasPrefix:[root stringByAppendingString:@"/"]];
}

static BOOL rbxIsJailbreakArtifact(NSString *path) {
    NSArray<NSString *> *roots = @[
        @"/var/jb", @"/.jbroot", @"/Applications/Cydia.app",
        @"/Applications/Sileo.app", @"/Library/MobileSubstrate",
        @"/usr/lib/TweakInject", @"/usr/lib/libsubstrate.dylib",
        @"/private/var/lib/apt", @"/private/var/lib/cydia",
        @"/var/mobile/Library/palera1n", @"/var/checkra1n"
    ];
    for (NSString *root in roots) {
        if (rbxPathIsEqualOrChild(path, root)) return YES;
    }
    return NO;
}

static NSString *rbxNormalizeMobileAlias(NSString *path) {
    if ([path hasPrefix:@"/private/var/mobile"]) {
        return [@"/var/mobile" stringByAppendingString:
                [path substringFromIndex:@"/private/var/mobile".length]];
    }
    return path;
}

static NSArray<NSArray<NSString *> *> *rbxGroupScopesSnapshot(void) {
    os_unfair_lock_lock(&sGroupScopesLock);
    NSArray<NSArray<NSString *> *> *snapshot = sGroupScopes;
    os_unfair_lock_unlock(&sGroupScopesLock);
    return snapshot;
}

static BOOL rbxPathHasManagedBase(NSString *path) {
    path = rbxNormalizeMobileAlias(path);
    NSString *realHome = rbxNormalizeMobileAlias(sRealHome);
    if (rbxPathIsEqualOrChild(path, realHome)) return YES;
    for (NSArray<NSString *> *scope in rbxGroupScopesSnapshot()) {
        if (rbxPathIsEqualOrChild(path, rbxNormalizeMobileAlias(scope[0]))) return YES;
    }
    return NO;
}

static BOOL rbxShouldHide(NSString *path) {
    if (!path) return NO;
    if (rbxPathIsEqualOrChild(path, sRbxRoot)) {
        return !rbxPathIsEqualOrChild(path, sContainerHome);
    }
    for (NSArray<NSString *> *scope in rbxGroupScopesSnapshot()) {
        NSString *groupRoot = scope[1];
        NSString *groupHome = scope[2];
        if (rbxPathIsEqualOrChild(path, groupRoot)) {
            return !rbxPathIsEqualOrChild(path, groupHome);
        }
    }
    return NO;
}

static NSString *rbxRedirect(NSString *path) {
    if (!path || !sRealHome || !sContainerHome) return path;
    if (rbxPathIsEqualOrChild(path, sRealHome)) {
        // Inside metadata or the active home: pass through (hiding handles siblings).
        if (rbxPathIsEqualOrChild(path, sRbxRoot)) return path;
        NSString *suffix = [path substringFromIndex:sRealHome.length];
        return suffix.length ? [sContainerHome stringByAppendingString:suffix]
                             : sContainerHome;
    }

    for (NSArray<NSString *> *scope in rbxGroupScopesSnapshot()) {
        NSString *groupBase = scope[0];
        NSString *groupRoot = scope[1];
        NSString *groupHome = scope[2];
        if (!rbxPathIsEqualOrChild(path, groupBase)) continue;
        if (rbxPathIsEqualOrChild(path, groupRoot)) return path;
        NSString *groupSuffix = [path substringFromIndex:groupBase.length];
        return [groupHome stringByAppendingString:groupSuffix];
    }
    return path;
}

static NSString *rbxManagedDestinationRoot(NSString *path) {
    if (rbxPathIsEqualOrChild(path, sContainerHome)) return sContainerHome;
    for (NSArray<NSString *> *scope in rbxGroupScopesSnapshot()) {
        if (rbxPathIsEqualOrChild(path, scope[2])) return scope[2];
    }
    return nil;
}

// Follow existing symlinks (or the nearest existing parent for creates) and
// ensure the kernel cannot escape the active container after our lexical rewrite.
static BOOL rbxResolvedPathStaysInContainer(NSString *path) {
    NSString *root = rbxManagedDestinationRoot(path);
    if (!root) return YES;

    char rootBuffer[PATH_MAX] = {0};
    NSString *existingRoot = root;
    while (!realpath(existingRoot.fileSystemRepresentation, rootBuffer)) {
        NSString *parent = existingRoot.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:existingRoot]) return NO;
        existingRoot = parent;
    }
    NSString *resolvedRoot = [NSString stringWithUTF8String:rootBuffer];

    NSString *candidate = path;
    while (candidate.length >= root.length) {
        char candidateBuffer[PATH_MAX] = {0};
        if (realpath(candidate.fileSystemRepresentation, candidateBuffer)) {
            NSString *resolved = [NSString stringWithUTF8String:candidateBuffer];
            return rbxPathIsEqualOrChild(resolved, resolvedRoot);
        }
        NSString *parent = candidate.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:candidate]) break;
        candidate = parent;
    }
    return NO;
}

// Call with sPathHookDepth held. A NULL return means the path must appear absent.
// Relative paths are made absolute only when their base is inside the app sandbox;
// this preserves normal system-relative I/O while closing "../" sibling escapes.
static const char *rbxPreparePathAt(const char *input, int relativeToFD,
                                    char output[PATH_MAX]) {
    if (!input) return input;
    NSString *path = [NSString stringWithUTF8String:input];
    if (!path) return input;
    if (!sTrustedControlFileDepth && rbxIsJailbreakArtifact(path)) {
        errno = ENOENT;
        return NULL;
    }
    if (!sTrustedControlFileDepth &&
        ([path hasPrefix:@"/var/mobile/Library/Preferences/com.redditbox."] ||
         [path hasPrefix:@"/private/var/mobile/Library/Preferences/com.redditbox."])) {
        errno = ENOENT;
        return NULL;
    }
    if (![path isAbsolutePath]) {
        char base[PATH_MAX] = {0};
        BOOL foundBase = relativeToFD == AT_FDCWD
            ? getcwd(base, sizeof(base)) != NULL
            : fcntl(relativeToFD, F_GETPATH, base) == 0;
        if (foundBase) {
            NSString *basePath = [NSString stringWithUTF8String:base];
            if (rbxPathHasManagedBase(basePath)) {
                path = [[basePath stringByAppendingPathComponent:path] stringByStandardizingPath];
            } else if (!sTrustedControlFileDepth &&
                       [rbxNormalizeMobileAlias(basePath) hasPrefix:@"/var/mobile"]) {
                errno = EACCES;
                return NULL;
            }
        }
    }
    if ([path isAbsolutePath]) {
        BOOL beganInManagedScope = rbxPathHasManagedBase(path);
        NSString *standardized = [path stringByStandardizingPath];
        if (beganInManagedScope && !rbxPathHasManagedBase(standardized)) {
            errno = ENOENT;
            return NULL;
        }
        path = standardized;
    }
    NSArray<NSString *> *sharedTempRoots =
        @[@"/tmp", @"/private/tmp", @"/var/tmp", @"/private/var/tmp",
          @"/var/folders", @"/private/var/folders"];
    for (NSString *tempRoot in sharedTempRoots) {
        if (rbxPathIsEqualOrChild(path, tempRoot)) {
            NSString *suffix = [path substringFromIndex:tempRoot.length];
            path = [[sContainerHome stringByAppendingPathComponent:@"tmp"]
                    stringByAppendingPathComponent:
                        [suffix stringByTrimmingCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@"/"]]];
            break;
        }
    }
    NSString *mobilePath = rbxNormalizeMobileAlias(path);
    if ([mobilePath hasPrefix:@"/var/mobile"] &&
        !sTrustedControlFileDepth && !rbxPathHasManagedBase(path)) {
        errno = EACCES;
        return NULL;
    }
    if (rbxShouldHide(path)) {
        errno = ENOENT;
        return NULL;
    }
    NSString *redirected = rbxRedirect(path);
    if (!rbxResolvedPathStaysInContainer(redirected)) {
        errno = EACCES;
        return NULL;
    }
    const char *utf8 = redirected.fileSystemRepresentation;
    if (!utf8) return input;
    if (strlcpy(output, utf8, PATH_MAX) >= PATH_MAX) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    return output;
}

static const char *rbxPreparePath(const char *input, char output[PATH_MAX]) {
    return rbxPreparePathAt(input, AT_FDCWD, output);
}

// --- existence + metadata syscalls --------------------------------------------

static int (*orig_stat)(const char *, struct stat *);
static int (*orig_lstat)(const char *, struct stat *);
static int (*orig_access)(const char *, int);
static int (*orig_faccessat)(int, const char *, int, int);
static int (*orig_fstatat)(int, const char *, struct stat *, int);

static int replaced_stat(const char *path, struct stat *buf) {
    if (!path || sPathHookDepth) return orig_stat(path, buf);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("stat");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    int result = resolved ? orig_stat(resolved, buf) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_lstat(const char *path, struct stat *buf) {
    if (!path || sPathHookDepth) return orig_lstat(path, buf);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("lstat");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    int result = resolved ? orig_lstat(resolved, buf) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_access(const char *path, int mode) {
    if (!path || sPathHookDepth) return orig_access(path, mode);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("access");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    int result = resolved ? orig_access(resolved, mode) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_faccessat(int dirfdValue, const char *path, int mode, int flags) {
    if (!path || sPathHookDepth) return orig_faccessat(dirfdValue, path, mode, flags);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(path, dirfdValue, rewritten);
    int result = resolved ? orig_faccessat(dirfdValue, resolved, mode, flags) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_fstatat(int dirfdValue, const char *path, struct stat *buf, int flags) {
    if (!path || sPathHookDepth) return orig_fstatat(dirfdValue, path, buf, flags);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(path, dirfdValue, rewritten);
    int result = resolved ? orig_fstatat(dirfdValue, resolved, buf, flags) : -1;
    sPathHookDepth--;
    return result;
}

// --- real I/O ------------------------------------------------------------------

static int (*orig_open)(const char *, int, ...);
static int (*orig_openat)(int, const char *, int, ...);
static FILE *(*orig_fopen)(const char *, const char *);
static DIR *(*orig_opendir)(const char *);
static int (*orig_rename)(const char *, const char *);
static int (*orig_renameat)(int, const char *, int, const char *);
static int (*orig_unlink)(const char *);
static int (*orig_unlinkat)(int, const char *, int);
static int (*orig_mkdir)(const char *, mode_t);
static int (*orig_mkdirat)(int, const char *, mode_t);
static ssize_t (*orig_readlink)(const char *, char *, size_t);
static ssize_t (*orig_readlinkat)(int, const char *, char *, size_t);
static int (*orig_symlink)(const char *, const char *);
static int (*orig_symlinkat)(const char *, int, const char *);
static int (*orig_link)(const char *, const char *);
static int (*orig_linkat)(int, const char *, int, const char *, int);
static int (*orig_copyfile)(const char *, const char *, copyfile_state_t, copyfile_flags_t);

static int replaced_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (!path || sPathHookDepth) {
        return (flags & O_CREAT) ? orig_open(path, flags, mode) : orig_open(path, flags);
    }
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("open");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    int result = -1;
    if (resolved) {
        result = (flags & O_CREAT) ? orig_open(resolved, flags, mode)
                                   : orig_open(resolved, flags);
    }
    sPathHookDepth--;
    return result;
}

static int replaced_openat(int dirfdValue, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    if (!path || sPathHookDepth) {
        return (flags & O_CREAT) ? orig_openat(dirfdValue, path, flags, mode)
                                 : orig_openat(dirfdValue, path, flags);
    }
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("openat");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(path, dirfdValue, rewritten);
    int result = -1;
    if (resolved) {
        result = (flags & O_CREAT) ? orig_openat(dirfdValue, resolved, flags, mode)
                                   : orig_openat(dirfdValue, resolved, flags);
    }
    sPathHookDepth--;
    return result;
}

static FILE *replaced_fopen(const char *path, const char *mode) {
    if (!path || sPathHookDepth) return orig_fopen(path, mode);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("fopen");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    FILE *result = resolved ? orig_fopen(resolved, mode) : NULL;
    sPathHookDepth--;
    return result;
}

static DIR *replaced_opendir(const char *path) {
    if (!path || sPathHookDepth) return orig_opendir(path);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("opendir");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    DIR *result = resolved ? orig_opendir(resolved) : NULL;
    sPathHookDepth--;
    return result;
}

static int replaced_rename(const char *oldPath, const char *newPath) {
    if (!oldPath || !newPath || sPathHookDepth) return orig_rename(oldPath, newPath);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("rename");
    char oldRewritten[PATH_MAX], newRewritten[PATH_MAX];
    const char *oldResolved = rbxPreparePath(oldPath, oldRewritten);
    const char *newResolved = oldResolved ? rbxPreparePath(newPath, newRewritten) : NULL;
    int result = (oldResolved && newResolved) ? orig_rename(oldResolved, newResolved) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_renameat(int oldFD, const char *oldPath, int newFD, const char *newPath) {
    if (!oldPath || !newPath || sPathHookDepth)
        return orig_renameat(oldFD, oldPath, newFD, newPath);
    sPathHookDepth++;
    char oldRewritten[PATH_MAX], newRewritten[PATH_MAX];
    const char *oldResolved = rbxPreparePathAt(oldPath, oldFD, oldRewritten);
    const char *newResolved = oldResolved
        ? rbxPreparePathAt(newPath, newFD, newRewritten) : NULL;
    int result = (oldResolved && newResolved)
        ? orig_renameat(oldFD, oldResolved, newFD, newResolved) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_unlink(const char *path) {
    if (!path || sPathHookDepth) return orig_unlink(path);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("unlink");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    int result = resolved ? orig_unlink(resolved) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_unlinkat(int dirfdValue, const char *path, int flags) {
    if (!path || sPathHookDepth) return orig_unlinkat(dirfdValue, path, flags);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(path, dirfdValue, rewritten);
    int result = resolved ? orig_unlinkat(dirfdValue, resolved, flags) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_mkdir(const char *path, mode_t mode) {
    if (!path || sPathHookDepth) return orig_mkdir(path, mode);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("mkdir");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    int result = resolved ? orig_mkdir(resolved, mode) : -1;
    sPathHookDepth--;
    return result;
}

static int replaced_mkdirat(int dirfdValue, const char *path, mode_t mode) {
    if (!path || sPathHookDepth) return orig_mkdirat(dirfdValue, path, mode);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(path, dirfdValue, rewritten);
    int result = resolved ? orig_mkdirat(dirfdValue, resolved, mode) : -1;
    sPathHookDepth--;
    return result;
}

static ssize_t replaced_readlink(const char *path, char *buffer, size_t size) {
    if (!path || !buffer || sPathHookDepth) return orig_readlink(path, buffer, size);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("readlink");
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(path, rewritten);
    if (!resolved) {
        sPathHookDepth--;
        return -1;
    }
    if (size == 0) {
        ssize_t result = orig_readlink(resolved, buffer, size);
        sPathHookDepth--;
        return result;
    }

    char target[PATH_MAX];
    ssize_t length = orig_readlink(resolved, target, sizeof(target) - 1);
    if (length < 0) {
        sPathHookDepth--;
        return length;
    }
    target[length] = '\0';
    NSString *targetPath = [NSString stringWithUTF8String:target];
    NSString *redirectedTarget = targetPath ? rbxRedirect(targetPath) : nil;
    const char *resultTarget = redirectedTarget ? redirectedTarget.fileSystemRepresentation : target;
    size_t resultLength = strlen(resultTarget);
    size_t copied = resultLength < size ? resultLength : size;
    if (copied) memcpy(buffer, resultTarget, copied);
    sPathHookDepth--;
    return (ssize_t)copied;
}

static ssize_t replaced_readlinkat(int dirfdValue, const char *path,
                                   char *buffer, size_t size) {
    if (!path || !buffer || sPathHookDepth)
        return orig_readlinkat(dirfdValue, path, buffer, size);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(path, dirfdValue, rewritten);
    if (!resolved) {
        sPathHookDepth--;
        return -1;
    }
    char target[PATH_MAX];
    ssize_t length = orig_readlinkat(dirfdValue, resolved, target, sizeof(target) - 1);
    if (length < 0 || size == 0) {
        sPathHookDepth--;
        return length;
    }
    target[length] = '\0';
    NSString *targetPath = [NSString stringWithUTF8String:target];
    NSString *redirectedTarget = targetPath ? rbxRedirect(targetPath) : nil;
    const char *resultTarget = redirectedTarget ? redirectedTarget.fileSystemRepresentation : target;
    size_t resultLength = strlen(resultTarget);
    size_t copied = resultLength < size ? resultLength : size;
    if (copied) memcpy(buffer, resultTarget, copied);
    sPathHookDepth--;
    return (ssize_t)copied;
}

static int replaced_symlink(const char *target, const char *linkPath) {
    if (!linkPath || sPathHookDepth) return orig_symlink(target, linkPath);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePath(linkPath, rewritten);
    BOOL managed = resolved && rbxManagedDestinationRoot(
        [NSString stringWithUTF8String:resolved]) != nil;
    sPathHookDepth--;
    if (managed || !resolved) {
        errno = EACCES;
        return -1;
    }
    return orig_symlink(target, resolved);
}

static int replaced_symlinkat(const char *target, int dirfdValue, const char *linkPath) {
    if (!linkPath || sPathHookDepth) return orig_symlinkat(target, dirfdValue, linkPath);
    sPathHookDepth++;
    char rewritten[PATH_MAX];
    const char *resolved = rbxPreparePathAt(linkPath, dirfdValue, rewritten);
    BOOL managed = resolved && rbxManagedDestinationRoot(
        [NSString stringWithUTF8String:resolved]) != nil;
    sPathHookDepth--;
    if (managed || !resolved) {
        errno = EACCES;
        return -1;
    }
    return orig_symlinkat(target, dirfdValue, resolved);
}

static BOOL rbxLinkRootsCompatible(const char *oldPath, const char *newPath) {
    NSString *oldRoot = rbxManagedDestinationRoot(
        [NSString stringWithUTF8String:oldPath]);
    NSString *newRoot = rbxManagedDestinationRoot(
        [NSString stringWithUTF8String:newPath]);
    return (!oldRoot && !newRoot) || (oldRoot && [oldRoot isEqualToString:newRoot]);
}

static int replaced_link(const char *oldPath, const char *newPath) {
    if (!oldPath || !newPath || sPathHookDepth) return orig_link(oldPath, newPath);
    sPathHookDepth++;
    char oldRewritten[PATH_MAX], newRewritten[PATH_MAX];
    const char *oldResolved = rbxPreparePath(oldPath, oldRewritten);
    const char *newResolved = rbxPreparePath(newPath, newRewritten);
    BOOL allowed = oldResolved && newResolved &&
        rbxLinkRootsCompatible(oldResolved, newResolved);
    int result = allowed ? orig_link(oldResolved, newResolved) : -1;
    if (!allowed) errno = EACCES;
    sPathHookDepth--;
    return result;
}

static int replaced_linkat(int oldFD, const char *oldPath, int newFD,
                           const char *newPath, int flags) {
    if (!oldPath || !newPath || sPathHookDepth)
        return orig_linkat(oldFD, oldPath, newFD, newPath, flags);
    sPathHookDepth++;
    char oldRewritten[PATH_MAX], newRewritten[PATH_MAX];
    const char *oldResolved = rbxPreparePathAt(oldPath, oldFD, oldRewritten);
    const char *newResolved = rbxPreparePathAt(newPath, newFD, newRewritten);
    BOOL allowed = oldResolved && newResolved &&
        rbxLinkRootsCompatible(oldResolved, newResolved);
    int result = allowed ? orig_linkat(oldFD, oldResolved, newFD, newResolved, flags) : -1;
    if (!allowed) errno = EACCES;
    sPathHookDepth--;
    return result;
}

static int replaced_copyfile(const char *from, const char *to,
                             copyfile_state_t state, copyfile_flags_t flags) {
    if (!from || !to || sPathHookDepth) return orig_copyfile(from, to, state, flags);
    sPathHookDepth++;
    char fromRewritten[PATH_MAX], toRewritten[PATH_MAX];
    const char *fromResolved = rbxPreparePath(from, fromRewritten);
    const char *toResolved = rbxPreparePath(to, toRewritten);
    int result = fromResolved && toResolved
        ? orig_copyfile(fromResolved, toResolved, state, flags) : -1;
    sPathHookDepth--;
    return result;
}

// --- directory enumeration hiding ---------------------------------------------

static struct dirent *(*orig_readdir)(DIR *);

static struct dirent *replaced_readdir(DIR *dirp) {
    if (!dirp || sPathHookDepth) return orig_readdir(dirp);
    sPathHookDepth++;
    RBX_LOG_HOOK_ONCE("readdir");
    struct dirent *entry = orig_readdir(dirp);
    char directoryPath[PATH_MAX] = {0};
    BOOL knowsDirectory = fcntl(dirfd(dirp), F_GETPATH, directoryPath) == 0;
    while (entry) {
        BOOL hide = strcmp(entry->d_name, "redditbox") == 0;
        if (!hide && knowsDirectory) {
            NSString *parent = [NSString stringWithUTF8String:directoryPath];
            NSString *name = [NSString stringWithUTF8String:entry->d_name];
            hide = parent && name && rbxShouldHide([parent stringByAppendingPathComponent:name]);
        }
        if (!hide) break;
        entry = orig_readdir(dirp);
    }
    sPathHookDepth--;
    return entry;
}

// --- Foundation home, search-path, and App Group redirection -------------------

static NSString *(*orig_NSHomeDirectory)(void);
static NSString *(*orig_NSTemporaryDirectory)(void);
static NSArray<NSString *> *(*orig_NSSearchPathForDirectoriesInDomains)(
    NSSearchPathDirectory, NSSearchPathDomainMask, BOOL);

static NSString *replaced_NSHomeDirectory(void) {
    RBX_LOG_FOUNDATION_HOOK_ONCE("NSHomeDirectory");
    return sContainerHome ?: orig_NSHomeDirectory();
}

static NSString *replaced_NSTemporaryDirectory(void) {
    RBX_LOG_FOUNDATION_HOOK_ONCE("NSTemporaryDirectory");
    return sTempDirectory ?: orig_NSTemporaryDirectory();
}

static NSArray<NSString *> *replaced_NSSearchPathForDirectoriesInDomains(
    NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask, BOOL expandTilde) {
    RBX_LOG_FOUNDATION_HOOK_ONCE("NSSearchPathForDirectoriesInDomains");
    NSArray<NSString *> *paths =
        orig_NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
    if (!(domainMask & NSUserDomainMask) || !sContainerHome) return paths;
    NSMutableArray<NSString *> *redirected = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) [redirected addObject:rbxRedirect(path)];
    return redirected;
}

static NSURL *rbxScopedDirectoryURL(NSSearchPathDirectory directory) {
    NSString *relative = nil;
    switch (directory) {
        case NSDocumentDirectory: relative = @"Documents"; break;
        case NSLibraryDirectory: relative = @"Library"; break;
        case NSCachesDirectory: relative = @"Library/Caches"; break;
        case NSApplicationSupportDirectory: relative = @"Library/Application Support"; break;
        default: return nil;
    }
    return [NSURL fileURLWithPath:[sContainerHome stringByAppendingPathComponent:relative]
                     isDirectory:YES];
}

%hook NSFileManager

- (NSString *)currentHomeDirectoryForCurrentUser {
    RBX_LOG_FOUNDATION_HOOK_ONCE("-[NSFileManager currentHomeDirectoryForCurrentUser]");
    return sContainerHome ?: %orig;
}

- (NSArray<NSURL *> *)URLsForDirectory:(NSSearchPathDirectory)directory
                             inDomains:(NSSearchPathDomainMask)domainMask {
    RBX_LOG_FOUNDATION_HOOK_ONCE("-[NSFileManager URLsForDirectory:inDomains:]");
    NSURL *scoped = domainMask == NSUserDomainMask ? rbxScopedDirectoryURL(directory) : nil;
    return scoped ? @[scoped] : %orig;
}

- (NSURL *)URLForDirectory:(NSSearchPathDirectory)directory
                  inDomain:(NSSearchPathDomainMask)domain
         appropriateForURL:(NSURL *)url
                    create:(BOOL)shouldCreate
                     error:(NSError **)error {
    RBX_LOG_FOUNDATION_HOOK_ONCE(
        "-[NSFileManager URLForDirectory:inDomain:appropriateForURL:create:error:]");
    NSURL *scoped = domain == NSUserDomainMask ? rbxScopedDirectoryURL(directory) : nil;
    if (!scoped) return %orig;
    if (shouldCreate &&
        ![self createDirectoryAtURL:scoped
        withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }
    return scoped;
}

- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    RBX_LOG_FOUNDATION_HOOK_ONCE(
        "-[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]");
    NSURL *systemGroupURL = %orig;
    if (!systemGroupURL || !sContainerIdentifier) return systemGroupURL;

    NSString *groupBase = systemGroupURL.path;
    NSString *groupRoot = [groupBase stringByAppendingPathComponent:@"redditbox"];
    NSString *groupHome = [[groupRoot stringByAppendingPathComponent:@"containers"]
                           stringByAppendingPathComponent:sContainerIdentifier];
    NSArray<NSString *> *newScope = @[groupBase, groupRoot, groupHome];
    NSURL *scoped = [NSURL fileURLWithPath:groupHome isDirectory:YES];

    os_unfair_lock_lock(&sGroupScopesLock);
    BOOL known = [sGroupScopes containsObject:newScope];
    if (!known) {
        sGroupScopes = [(sGroupScopes ?: @[]) arrayByAddingObject:newScope];
    }
    os_unfair_lock_unlock(&sGroupScopesLock);
    [self createDirectoryAtURL:scoped
   withIntermediateDirectories:YES attributes:nil error:nil];
    return scoped;
}

- (NSURL *)URLForUbiquityContainerIdentifier:(NSString *)containerIdentifier {
    // iCloud containers are device/account scoped and cannot be safely
    // namespaced by this tweak.
    return nil;
}

%end

void RBXInstallPathHooks(RBXContainerManager *mgr) {
    if (!mgr) return;
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    sRealHome = NSHomeDirectory();
    sContainerHome = mgr.containerDataDirectory;
    sRbxRoot = [sRealHome stringByAppendingPathComponent:@"redditbox"];
    sTempDirectory = [sContainerHome stringByAppendingPathComponent:@"tmp"];
    sContainerIdentifier = mgr.containerId;

    // Seed paths consumed directly by Foundation/CFNetwork/WebKit. Keeping those
    // services persistent (rather than forcing ephemeral stores) preserves login.
    NSArray<NSString *> *seedDirectories = @[
        sContainerHome,
        sTempDirectory,
        [sContainerHome stringByAppendingPathComponent:@"Documents"],
        [sContainerHome stringByAppendingPathComponent:@"Library/Caches"],
        [sContainerHome stringByAppendingPathComponent:@"Library/Cookies"],
        [sContainerHome stringByAppendingPathComponent:@"Library/WebKit"],
        [sContainerHome stringByAppendingPathComponent:@"Library/Application Support"],
        [sContainerHome stringByAppendingPathComponent:@"Library/Group Containers"],
    ];
    for (NSString *directory in seedDirectories) {
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }

    // Apply redirection to the process environment early so C code reading $HOME
    // (SQLite temp dirs, etc.) also resolves into the container.
    setenv("HOME", sContainerHome.UTF8String, 1);
    NSString *tmpWithSlash = [sTempDirectory stringByAppendingString:@"/"];
    setenv("TMPDIR", tmpWithSlash.UTF8String, 1);

    %init;
    MSHookFunction((void *)NSHomeDirectory, (void *)replaced_NSHomeDirectory,
                   (void **)&orig_NSHomeDirectory);
    MSHookFunction((void *)NSTemporaryDirectory, (void *)replaced_NSTemporaryDirectory,
                   (void **)&orig_NSTemporaryDirectory);
    MSHookFunction((void *)NSSearchPathForDirectoriesInDomains,
                   (void *)replaced_NSSearchPathForDirectoriesInDomains,
                   (void **)&orig_NSSearchPathForDirectoriesInDomains);
    MSHookFunction((void *)stat, (void *)replaced_stat, (void **)&orig_stat);
    MSHookFunction((void *)lstat, (void *)replaced_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)access, (void *)replaced_access, (void **)&orig_access);
    MSHookFunction((void *)faccessat, (void *)replaced_faccessat, (void **)&orig_faccessat);
    MSHookFunction((void *)fstatat, (void *)replaced_fstatat, (void **)&orig_fstatat);
    MSHookFunction((void *)open, (void *)replaced_open, (void **)&orig_open);
    MSHookFunction((void *)openat, (void *)replaced_openat, (void **)&orig_openat);
    MSHookFunction((void *)fopen, (void *)replaced_fopen, (void **)&orig_fopen);
    MSHookFunction((void *)opendir, (void *)replaced_opendir, (void **)&orig_opendir);
    MSHookFunction((void *)rename, (void *)replaced_rename, (void **)&orig_rename);
    MSHookFunction((void *)renameat, (void *)replaced_renameat, (void **)&orig_renameat);
    MSHookFunction((void *)unlink, (void *)replaced_unlink, (void **)&orig_unlink);
    MSHookFunction((void *)unlinkat, (void *)replaced_unlinkat, (void **)&orig_unlinkat);
    MSHookFunction((void *)mkdir, (void *)replaced_mkdir, (void **)&orig_mkdir);
    MSHookFunction((void *)mkdirat, (void *)replaced_mkdirat, (void **)&orig_mkdirat);
    MSHookFunction((void *)readlink, (void *)replaced_readlink, (void **)&orig_readlink);
    MSHookFunction((void *)readlinkat, (void *)replaced_readlinkat, (void **)&orig_readlinkat);
    MSHookFunction((void *)symlink, (void *)replaced_symlink, (void **)&orig_symlink);
    MSHookFunction((void *)symlinkat, (void *)replaced_symlinkat, (void **)&orig_symlinkat);
    MSHookFunction((void *)link, (void *)replaced_link, (void **)&orig_link);
    MSHookFunction((void *)linkat, (void *)replaced_linkat, (void **)&orig_linkat);
    MSHookFunction((void *)copyfile, (void *)replaced_copyfile, (void **)&orig_copyfile);
    MSHookFunction((void *)readdir, (void *)replaced_readdir, (void **)&orig_readdir);
    RBXLog("storage isolation hooks installed");
}
