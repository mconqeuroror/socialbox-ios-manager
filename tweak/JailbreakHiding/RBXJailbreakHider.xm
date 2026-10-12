#import "RBXHookInstallation.h"
#import "RBXJailbreakHider.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <string.h>
#import <errno.h>
#import <mach-o/dyld.h>
#import "RBXProc.h"
#import <unistd.h>

// Shadow-class jailbreak hiding, scoped to Reddit processes.
// Covers the common detection families: file existence, URL schemes,
// dynamic-linker inspection, environment, sandbox-write and fork tests.

static NSArray<NSString *> *rbxHiddenPaths() {
    return @[
        @"/Applications/Cydia.app",
        @"/var/jb", @"/var/jb/usr", @"/var/jb/etc/apt",
        @"/private/var/lib/apt", @"/private/var/lib/cydia",
        @"/private/var/mobile/Library/palera1n",
        @"/etc/apt", @"/bin/bash", @"/usr/sbin/sshd", @"/usr/libexec/sftp-server",
        @"/var/checkra1n", @"/var/binpack",
    ];
}

static NSArray<NSString *> *rbxHiddenSchemes() {
    return @[ @"cydia", @"sileo", @"zbra", @"filza" ];
}

// --- file existence -----------------------------------------------------------

static int (*orig_access)(const char *, int);
static int replaced_access(const char *path, int mode) {
    NSString *p = [NSString stringWithUTF8String:path];
    for (NSString *hidden in rbxHiddenPaths()) {
        if ([p hasPrefix:hidden]) { errno = ENOENT; return -1; }
    }
    return orig_access(path, mode);
}

static int (*orig_lstat)(const char *, struct stat *);
static int replaced_lstat(const char *path, struct stat *buf) {
    NSString *p = [NSString stringWithUTF8String:path];
    for (NSString *hidden in rbxHiddenPaths()) {
        if ([p hasPrefix:hidden]) { errno = ENOENT; return -1; }
    }
    return orig_lstat(path, buf);
}

// --- dyld image hiding ---------------------------------------------------------

static const char *(*orig_dyld_get_image_name)(uint32_t);
static uint32_t (*orig_dyld_image_count)(void);
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t);
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t);

static BOOL rbxImageIsHidden(const char *name) {
    if (!name) return NO;
    return strstr(name, "/var/jb/") || strstr(name, "/.jbroot/") ||
        strstr(name, "RedditBox") || strstr(name, "MobileSubstrate") ||
        strstr(name, "Substrate") || strstr(name, "TweakInject") ||
        strstr(name, "Cydia.app") || strstr(name, "Sileo.app") ||
        strstr(name, "palera1n") || strstr(name, "checkra1n");
}

static uint32_t rbxOriginalImageIndex(uint32_t visibleIndex) {
    uint32_t visible = 0;
    uint32_t count = orig_dyld_image_count();
    for (uint32_t original = 0; original < count; original++) {
        if (rbxImageIsHidden(orig_dyld_get_image_name(original))) continue;
        if (visible == visibleIndex) return original;
        visible++;
    }
    return UINT32_MAX;
}

static uint32_t replaced_dyld_image_count(void) {
    uint32_t visible = 0;
    for (uint32_t index = 0; index < orig_dyld_image_count(); index++) {
        if (!rbxImageIsHidden(orig_dyld_get_image_name(index))) visible++;
    }
    return visible;
}

static const char *replaced_dyld_get_image_name(uint32_t index) {
    uint32_t original = rbxOriginalImageIndex(index);
    return original == UINT32_MAX ? NULL : orig_dyld_get_image_name(original);
}

static const struct mach_header *replaced_dyld_get_image_header(uint32_t index) {
    uint32_t original = rbxOriginalImageIndex(index);
    return original == UINT32_MAX ? NULL : orig_dyld_get_image_header(original);
}

static intptr_t replaced_dyld_get_image_vmaddr_slide(uint32_t index) {
    uint32_t original = rbxOriginalImageIndex(index);
    return original == UINT32_MAX ? 0 : orig_dyld_get_image_vmaddr_slide(original);
}

static int (*orig_dladdr)(const void *, Dl_info *);
static int replaced_dladdr(const void *address, Dl_info *info) {
    int result = orig_dladdr(address, info);
    if (result && info && rbxImageIsHidden(info->dli_fname)) {
        memset(info, 0, sizeof(*info));
        return 0;
    }
    return result;
}

// --- URL scheme probing --------------------------------------------------------

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    NSString *scheme = url.scheme.lowercaseString;
    if (scheme && [rbxHiddenSchemes() containsObject:scheme]) return NO;
    return %orig;
}

%end

// --- environment scrub ---------------------------------------------------------

static char *(*orig_getenv)(const char *);
static char *replaced_getenv(const char *name) {
    if (name) {
        if (strncmp(name, "DYLD_", 5) == 0 ||
            strcmp(name, "_MSSafeMode") == 0) {
            return NULL;
        }
    }
    return orig_getenv(name);
}

static pid_t (*orig_fork)(void);
static pid_t replaced_fork(void) {
    errno = EPERM;
    return -1;
}

static pid_t (*orig_vfork)(void);
static pid_t replaced_vfork(void) {
    errno = EPERM;
    return -1;
}

static void *(*orig_dlopen)(const char *, int);
static void *replaced_dlopen(const char *path, int mode) {
    if (path && rbxImageIsHidden(path)) {
        return NULL;
    }
    return orig_dlopen(path, mode);
}

static char *(*orig_realpath)(const char *, char *);
static char *replaced_realpath(const char *path, char *resolved) {
    if (path && rbxImageIsHidden(path)) {
        errno = ENOENT;
        return NULL;
    }
    return orig_realpath(path, resolved);
}

static int (*orig_proc_listallpids)(void *, int);
static int replaced_proc_listallpids(void *buffer, int bufferSize) {
    if (!buffer || bufferSize < (int)sizeof(pid_t)) return 1;
    ((pid_t *)buffer)[0] = getpid();
    return 1;
}

static int (*orig_proc_pidpath)(int, void *, uint32_t);
static int replaced_proc_pidpath(int pid, void *buffer, uint32_t bufferSize) {
    if (pid != getpid()) { errno = ESRCH; return 0; }
    return orig_proc_pidpath(pid, buffer, bufferSize);
}

%hook NSProcessInfo

- (NSDictionary<NSString *, NSString *> *)environment {
    NSDictionary *original = %orig;
    NSMutableDictionary *environment = [original mutableCopy];
    for (NSString *key in environment.allKeys) {
        if ([key hasPrefix:@"DYLD_"] || [key isEqualToString:@"_MSSafeMode"]) {
            [environment removeObjectForKey:key];
        }
    }
    return environment;
}

%end

BOOL RBXInstallJailbreakHider(void) {
    MSHookFunction((void *)access, (void *)replaced_access, (void **)&orig_access);
    MSHookFunction((void *)lstat, (void *)replaced_lstat, (void **)&orig_lstat);
    MSHookFunction((void *)getenv, (void *)replaced_getenv, (void **)&orig_getenv);
    MSHookFunction((void *)fork, (void *)replaced_fork, (void **)&orig_fork);
    void *vforkSymbol = dlsym(RTLD_DEFAULT, "vfork");
    if (vforkSymbol) {
        MSHookFunction(vforkSymbol, (void *)replaced_vfork, (void **)&orig_vfork);
    }
    MSHookFunction((void *)dlopen, (void *)replaced_dlopen, (void **)&orig_dlopen);
    MSHookFunction((void *)realpath, (void *)replaced_realpath, (void **)&orig_realpath);
    orig_dyld_image_count = _dyld_image_count;
    orig_dyld_get_image_header = _dyld_get_image_header;
    orig_dyld_get_image_vmaddr_slide = _dyld_get_image_vmaddr_slide;
    MSHookFunction((void *)_dyld_image_count, (void *)replaced_dyld_image_count,
                   (void **)&orig_dyld_image_count);
    MSHookFunction((void *)_dyld_get_image_name, (void *)replaced_dyld_get_image_name,
                   (void **)&orig_dyld_get_image_name);
    MSHookFunction((void *)_dyld_get_image_header, (void *)replaced_dyld_get_image_header,
                   (void **)&orig_dyld_get_image_header);
    MSHookFunction((void *)_dyld_get_image_vmaddr_slide,
                   (void *)replaced_dyld_get_image_vmaddr_slide,
                   (void **)&orig_dyld_get_image_vmaddr_slide);
    MSHookFunction((void *)dladdr, (void *)replaced_dladdr, (void **)&orig_dladdr);
    MSHookFunction((void *)proc_listallpids, (void *)replaced_proc_listallpids,
                   (void **)&orig_proc_listallpids);
    MSHookFunction((void *)proc_pidpath, (void *)replaced_proc_pidpath,
                   (void **)&orig_proc_pidpath);
    %init;
    RBXLog("jailbreak/process visibility hooks installed");
    return RBXHookInstallationPassed();
}
