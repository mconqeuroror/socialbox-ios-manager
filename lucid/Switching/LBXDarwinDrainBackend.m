#import "LBXDarwinDrainBackend.h"
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <sys/proc.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <math.h>

static void LBXError(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"SocialBox.ProcessDrain" code:1
        userInfo:@{NSLocalizedDescriptionKey:reason}];
}
static NSString *LBXDigest(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString string];
    for (size_t i = 0; i < sizeof(digest); i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}
static BOOL LBXName(id name) {
    return [name isKindOfClass:NSString.class] && [name length] && [name length] < 256 &&
        ![name containsString:@"\0"] && ![name containsString:@"/"] && ![name containsString:@"\\"] &&
        ![@[@".", @".."] containsObject:name];
}
static NSString *LBXResolvedInstallationPath(id path) {
    if (![path isKindOfClass:NSString.class]) return nil;
    NSString *resolved = [path stringByResolvingSymlinksInPath];
    // iOS Foundation can shorten the resolved /private/var path back to /var.
    // Normalize only that documented system alias, as the process classifier
    // does. Exact installation layout and trusted-node checks still follow.
    return [resolved hasPrefix:@"/var/"] ? [@"/private" stringByAppendingString:resolved] : resolved;
}
static BOOL LBXTrustedNode(NSString *path, BOOL directory, NSMutableArray *identities) {
    struct stat info;
    // Original installed application bundles are owned by root or installd.
    // No broad writable /var/mobile, user-chosen path, or symlink authority.
    if (lstat(path.fileSystemRepresentation, &info) ||
        (directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode)) ||
        (info.st_uid != 0 && info.st_uid != 33) || (info.st_mode & 0022)) return NO;
    if (directory) {
        // Parent directory timestamps change when unrelated apps/logs change.
        // Pin its inode and permissions; enumerate the relevant children below.
        [identities addObject:[NSString stringWithFormat:@"%@:%llu:%llu:%u:%u", path,
            (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, info.st_uid, info.st_mode]];
        return YES;
    }
    [identities addObject:[NSString stringWithFormat:@"%@:%llu:%llu:%u:%u:%lld:%lld:%ld:%lld:%ld", path,
        (unsigned long long)info.st_dev, (unsigned long long)info.st_ino, info.st_uid, info.st_mode,
        (long long)info.st_size, (long long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec,
        (long long)info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]];
    return YES;
}
static NSDictionary *LBXReadInfo(NSString *bundle, NSMutableArray *identities) {
    NSString *path = [bundle stringByAppendingPathComponent:@"Info.plist"];
    if (!LBXTrustedNode(path, NO, identities)) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat before, after;
    NSMutableData *bytes = nil;
    if (!fstat(fd, &before) && S_ISREG(before.st_mode) && (before.st_uid == 0 || before.st_uid == 33) &&
        !(before.st_mode & 0022) && before.st_size > 0 && before.st_size <= 1024 * 1024) {
        bytes = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
        size_t offset = 0; unsigned interruptions = 0;
        while (offset < bytes.length) {
            ssize_t count = read(fd, (char *)bytes.mutableBytes + offset, bytes.length - offset);
            if (count < 0 && errno == EINTR && ++interruptions <= 4) continue;
            if (count <= 0) { bytes = nil; break; }
            offset += (size_t)count;
        }
        if (fstat(fd, &after) || before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
            before.st_size != after.st_size || before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
            before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
            before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec ||
            before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec) bytes = nil;
    }
    close(fd);
    if (!bytes) return nil;
    id info = [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];
    if (![info isKindOfClass:NSDictionary.class]) return nil;
    [identities addObject:LBXDigest(bytes)]; return info;
}

static NSArray<LBXDrainProcess *> *LBXSnapshotOnce(NSError **error, BOOL *retryable) {
    *retryable = NO;
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    struct kinfo_proc *table = NULL; size_t bytes = 0;
    for (unsigned attempt = 0; attempt < 4; attempt++) {
        bytes = 0;
        if (sysctl(mib, 4, NULL, &bytes, NULL, 0) || !bytes || bytes > 32 * 1024 * 1024) {
            if (errno == EINTR) continue;
            LBXError(error, @"Process enumeration sizing failed"); return nil;
        }
        size_t capacity = bytes + 64 * sizeof(*table); table = calloc(1, capacity);
        if (!table) return nil;
        bytes = capacity;
        int rc = sysctl(mib, 4, table, &bytes, NULL, 0), saved = errno;
        if (!rc && bytes && bytes <= capacity && !(bytes % sizeof(*table))) break;
        free(table); table = NULL;
        if (!rc || (saved != ENOMEM && saved != EINTR)) { LBXError(error, @"Process enumeration failed"); return nil; }
    }
    if (!table) { LBXError(error, @"Process enumeration unstable"); return nil; }
    NSMutableArray *result = [NSMutableArray array];
    for (size_t index = 0; index < bytes / sizeof(*table); index++) {
        pid_t pid = table[index].kp_proc.p_pid;
        if (pid <= 1 || pid == getpid() || table[index].kp_proc.p_stat == SZOMB) continue;
        RBXObservedProcess observed;
        RBXProcessIdentityResult status = RBXObserveProcess(pid, &observed);
        if (status == RBXProcessGone) continue;
        if (status != RBXProcessObserved) {
            free(table); *retryable = YES;
            LBXError(error, @"Live process identity unreadable or changed"); return nil;
        }
        // Keep the raw path for later kernel revalidation and the task right.
        // The classifier recognizes the documented /var alias separately.
        LBXDrainProcess *row = [LBXDrainProcess new]; row.identity = observed;
        [result addObject:row];
    }
    free(table); return result;
}

@implementation LBXDarwinDrainBackend
- (LBXDrainTarget *)resolve:(NSString *)bundleID error:(NSError **)error {
    if (!LBXDrainSupportedApplication(bundleID)) { LBXError(error, @"Unsupported source application"); return nil; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW))
            dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    });
    Class cls = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    SEL bundleURL = NSSelectorFromString(@"bundleURL");
    if (![cls respondsToSelector:lookup]) { LBXError(error, @"LaunchServices unavailable"); return nil; }
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(cls, lookup, bundleID);
    id url = [proxy respondsToSelector:bundleURL] ? ((id (*)(id, SEL))objc_msgSend)(proxy, bundleURL) : nil;
    NSString *bundle = [url isKindOfClass:NSURL.class] && [url isFileURL] ? LBXResolvedInstallationPath([url path]) : nil;
    NSString *root = @"/private/var/containers/Bundle/Application";
    NSString *parent = bundle.stringByDeletingLastPathComponent;
    // Exact current iOS installation layout. Other layouts require a reviewed
    // resolver; never fall back to an executable name or filesystem search.
    if (!bundle.isAbsolutePath || ![parent.stringByDeletingLastPathComponent isEqual:root] ||
        ![[NSUUID alloc] initWithUUIDString:parent.lastPathComponent] || ![bundle.pathExtension isEqual:@"app"]) {
        LBXError(error, @"Unrecognized installed application path"); return nil;
    }
    NSMutableArray *identities = [NSMutableArray arrayWithObject:bundleID];
    NSString *component = @"/";
    for (NSString *part in bundle.pathComponents) {
        if ([part isEqual:@"/"]) continue;
        component = [component stringByAppendingPathComponent:part];
        if (!LBXTrustedNode(component, YES, identities)) { LBXError(error, @"Untrusted application path"); return nil; }
    }
    NSDictionary *info = LBXReadInfo(bundle, identities);
    NSString *executable = LBXName(info[@"CFBundleExecutable"]) ? [bundle stringByAppendingPathComponent:info[@"CFBundleExecutable"]] : nil;
    if (![info[@"CFBundleIdentifier"] isEqual:bundleID] || !executable || !LBXTrustedNode(executable, NO, identities) ||
        access(executable.fileSystemRepresentation, X_OK)) { LBXError(error, @"Application metadata mismatch"); return nil; }
    SEL canonical = NSSelectorFromString(@"canonicalExecutablePath");
    id registered = [proxy respondsToSelector:canonical] ? ((id (*)(id, SEL))objc_msgSend)(proxy, canonical) : nil;
    if (![LBXResolvedInstallationPath(registered) isEqual:executable]) {
        LBXError(error, @"LaunchServices executable mismatch"); return nil;
    }
    NSMutableArray *executables = [NSMutableArray arrayWithObject:executable];
    NSString *plugins = [bundle stringByAppendingPathComponent:@"PlugIns"];
    struct stat pluginsInfo;
    if (!lstat(plugins.fileSystemRepresentation, &pluginsInfo)) {
        if (!LBXTrustedNode(plugins, YES, identities)) { LBXError(error, @"Untrusted PlugIns directory"); return nil; }
        NSArray *children = [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:error];
        if (!children || children.count > 128) { LBXError(error, @"Cannot inventory embedded extensions"); return nil; }
        for (NSString *child in [children sortedArrayUsingSelector:@selector(compare:)]) {
            if (![child.pathExtension isEqual:@"appex"] || !LBXName(child)) { LBXError(error, @"Unknown embedded bundle"); return nil; }
            NSString *extension = [plugins stringByAppendingPathComponent:child];
            if (!LBXTrustedNode(extension, YES, identities)) { LBXError(error, @"Untrusted embedded extension path"); return nil; }
            NSDictionary *extensionInfo = LBXReadInfo(extension, identities);
            NSString *identifier = extensionInfo[@"CFBundleIdentifier"];
            if (![identifier isKindOfClass:NSString.class] || ![identifier hasPrefix:[bundleID stringByAppendingString:@"."]] ||
                ![extensionInfo[@"NSExtension"] isKindOfClass:NSDictionary.class] || !LBXName(extensionInfo[@"CFBundleExecutable"])) {
                LBXError(error, @"Invalid embedded extension"); return nil;
            }
            NSString *binary = [extension stringByAppendingPathComponent:extensionInfo[@"CFBundleExecutable"]];
            // Installed bundles can retain an optional extension as a read-only
            // file without execute permission on this OS. Inventory its exact
            // trusted metadata path anyway; this operation only observes/stops
            // matching existing processes and never launches that executable.
            // Missing, writable, user-owned or symlink files still fail.
            if (!LBXTrustedNode(binary, NO, identities)) { LBXError(error, @"Untrusted embedded extension executable"); return nil; }
            [executables addObject:binary];
        }
    } else if (errno != ENOENT) { LBXError(error, @"Cannot enumerate embedded extensions"); return nil; }
    LBXDrainTarget *result = [LBXDrainTarget new];
    result.bundleID = bundleID; result.bundlePath = bundle; result.executables = executables;
    result.fingerprint = LBXDigest([NSPropertyListSerialization dataWithPropertyList:identities
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]);
    return result;
}
- (NSArray<LBXDrainProcess *> *)snapshot:(NSError **)error {
    // A process can exit or change identity while the kernel table is read.
    // Retry the entire observation, never reuse partial rows or reinterpret an
    // unreadable live process as absent. Persistent uncertainty still fails.
    for (unsigned attempt = 0; attempt < 3; attempt++) {
        BOOL retryable = NO; NSError *failure = nil;
        NSArray<LBXDrainProcess *> *complete = LBXSnapshotOnce(&failure, &retryable);
        if (complete) return complete;
        if (!retryable || attempt == 2) {
            if (error) *error = failure;
            return nil;
        }
        if (![self pause]) { LBXError(error, @"Process enumeration retry pause failed"); return nil; }
    }
    return nil;
}
- (RBXProcessIdentityResult)terminate:(RBXObservedProcess)identity { return RBXTerminateObservedProcess(&identity); }
- (double)monotonicTime {
    struct timespec time;
    return clock_gettime(CLOCK_MONOTONIC, &time) ? NAN : time.tv_sec + time.tv_nsec / 1e9;
}
- (BOOL)pause {
    struct timespec duration = {.tv_sec=0, .tv_nsec=20000000}, remaining;
    for (unsigned attempt = 0; attempt < 4; attempt++) {
        if (!nanosleep(&duration, &remaining)) return YES;
        if (errno != EINTR) return NO;
        duration = remaining;
    }
    return NO;
}
@end
