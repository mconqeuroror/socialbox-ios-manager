#import "LBXHelperPaths.h"
#import "LBXHelperProtocol.h"
#import "../Switching/LBXSocialBoxProduct.h"
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <errno.h>
#include <string.h>

static NSError *LBXPathError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LBXHelperErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

BOOL LBXHelperIsIGOrFB(NSString *bundleID) {
    return [bundleID isEqualToString:@"com.burbn.instagram"] ||
           [bundleID isEqualToString:@"com.facebook.Facebook"];
}

BOOL LBXHelperIsNumericContainerID(long long containerID) {
    return containerID >= 1 && containerID <= 999999;
}

NSString *LBXHelperProfileStoreRoot(void) {
    return [@"/var/jb/var/mobile/Library" stringByAppendingPathComponent:@LBX_SOCIALBOX_PROFILE_STORE];
}

NSString *LBXHelperContainerTreePath(NSString *bundleID, long long containerID) {
    (void)bundleID;
    return [LBXHelperProfileStoreRoot()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", containerID]];
}

// Map /var ↔ /private/var and reject path-escape after standardization.
static NSString *LBXPrivateForm(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return nil;
    if ([path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    if ([path containsString:@"\0"]) return nil;
    NSString *raw = path;
    if ([raw hasPrefix:@"/var/"]) raw = [@"/private" stringByAppendingString:raw];
    NSString *standard = raw.stringByStandardizingPath;
    if ([standard hasPrefix:@"/var/"]) standard = [@"/private" stringByAppendingString:standard];
    // Standardization must not escape the private-form lexical root of the input.
    if (![standard isEqual:raw] && ![standard hasPrefix:[raw stringByAppendingString:@"/"]] &&
        ![raw hasPrefix:[standard stringByAppendingString:@"/"]] && ![standard isEqual:raw]) {
        // Allow only collapsing of `.` segments within the same prefix family.
        NSString *collapsed = raw.stringByStandardizingPath;
        if ([collapsed hasPrefix:@"/var/"]) collapsed = [@"/private" stringByAppendingString:collapsed];
        if (![standard isEqual:collapsed]) return nil;
    }
    return standard;
}

NSString *LBXHelperStandardizeAllowedPath(NSString *path) {
    NSString *standard = LBXPrivateForm(path);
    if (!standard || !LBXHelperPathUnderControlTree(standard)) return nil;
    return standard;
}

BOOL LBXHelperPathUnderControlTree(NSString *path) {
    NSString *standard = LBXPrivateForm(path);
    if (!standard) return NO;
    NSArray<NSString *> *roots = @[
        LBXPrivateForm(@LBX_SOCIALBOX_CONTROL_CONTAINERS),
        LBXPrivateForm(@LBX_SOCIALBOX_CONTROL_RUNTIME),
        LBXPrivateForm(LBXHelperProfileStoreRoot()),
    ];
    for (NSString *root in roots) {
        if (!root) continue;
        if ([standard isEqual:root]) return YES;
        if ([standard hasPrefix:[root stringByAppendingString:@"/"]]) return YES;
    }
    return NO;
}

static BOOL LBXMkdirParents(NSString *path, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir) return YES;
        if (error) *error = LBXPathError(LBXHelperErrorOperationFailed, @"path exists as file");
        return NO;
    }
    NSError *local = nil;
    if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions : @0755}
                             error:&local]) {
        if (error) *error = local ?: LBXPathError(LBXHelperErrorOperationFailed, @"mkdir failed");
        return NO;
    }
    return YES;
}

BOOL LBXHelperBootstrapContainerTree(NSString *bundleID, long long containerID, NSError **error) {
    if (!LBXHelperIsIGOrFB(bundleID) || !LBXHelperIsNumericContainerID(containerID)) {
        if (error) *error = LBXPathError(LBXHelperErrorInvalidArgument, @"IG/FB numeric CID required");
        return NO;
    }
    NSString *root = LBXHelperContainerTreePath(bundleID, containerID);
    NSString *controlBundle =
        [[@LBX_SOCIALBOX_CONTROL_CONTAINERS stringByAppendingPathComponent:bundleID]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", containerID]];
    for (NSString *base in @[ root, controlBundle ]) {
        for (NSString *leaf in @[ @"Library/Preferences", @"Library/Caches", @"Documents", @"tmp" ]) {
            if (!LBXMkdirParents([base stringByAppendingPathComponent:leaf], error)) return NO;
        }
    }
    return YES;
}

BOOL LBXHelperTeardownContainerTree(NSString *bundleID, long long containerID, NSError **error) {
    if (!LBXHelperIsIGOrFB(bundleID) || !LBXHelperIsNumericContainerID(containerID)) {
        if (error) *error = LBXPathError(LBXHelperErrorInvalidArgument, @"IG/FB numeric CID required");
        return NO;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *paths = @[
        LBXHelperContainerTreePath(bundleID, containerID),
        [[@LBX_SOCIALBOX_CONTROL_CONTAINERS stringByAppendingPathComponent:bundleID]
            stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", containerID]],
    ];
    for (NSString *path in paths) {
        if (!LBXHelperPathUnderControlTree(path)) {
            // Parent profile-store / control root may not exist yet; allow exact CID leaf
            // when its private form sits under a known root prefix string.
            NSString *privatePath = LBXPrivateForm(path);
            if (!privatePath || !LBXHelperPathUnderControlTree(privatePath)) {
                if (error) *error = LBXPathError(LBXHelperErrorPathDenied, @"teardown path denied");
                return NO;
            }
        }
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
        NSError *local = nil;
        if (![fm removeItemAtPath:path error:&local]) {
            if (error) *error = local ?: LBXPathError(LBXHelperErrorOperationFailed, @"teardown failed");
            return NO;
        }
    }
    return YES;
}

static BOOL LBXChownNode(const char *path, uid_t uid, gid_t gid) {
    return lchown(path, uid, gid) == 0 || errno == ENOENT;
}

static BOOL LBXChownWalk(NSString *path, uid_t uid, gid_t gid, NSError **error) {
    const char *cpath = path.fileSystemRepresentation;
    struct stat st;
    if (lstat(cpath, &st)) {
        if (errno == ENOENT) return YES;
        if (error) *error = LBXPathError(LBXHelperErrorOperationFailed, @"lstat failed");
        return NO;
    }
    if (!LBXChownNode(cpath, uid, gid)) {
        if (error) *error = LBXPathError(LBXHelperErrorOperationFailed, @"chown failed");
        return NO;
    }
    if (!S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return YES;

    DIR *dir = opendir(cpath);
    if (!dir) {
        if (error) *error = LBXPathError(LBXHelperErrorOperationFailed, @"opendir failed");
        return NO;
    }
    BOOL ok = YES;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        NSString *child = [path stringByAppendingPathComponent:@(entry->d_name)];
        if (!LBXChownWalk(child, uid, gid, error)) {
            ok = NO;
            break;
        }
    }
    closedir(dir);
    return ok;
}

BOOL LBXHelperChownRecursiveToMobile(NSString *path, NSError **error) {
    NSString *allowed = LBXHelperStandardizeAllowedPath(path);
    if (!allowed) {
        if (error) *error = LBXPathError(LBXHelperErrorPathDenied, @"path outside SocialBox trees");
        return NO;
    }
    if (geteuid() != 0) {
        if (error) *error = LBXPathError(LBXHelperErrorUnauthorized, @"chown requires root helper");
        return NO;
    }
    return LBXChownWalk(allowed, 501, 501, error);
}
