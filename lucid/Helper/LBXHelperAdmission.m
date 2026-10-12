#import "LBXHelperAdmission.h"
#import "../Switching/LBXSocialBoxProduct.h"
#import "../HelperSafety/LBXCallerFile.h"
#import "../../shared/RBXProc.h"
#include <dlfcn.h>
#include <sys/stat.h>
#include <string.h>

static NSString *LBXCanonicalPath(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return nil;
    if ([path hasPrefix:@"/var/"]) return [@"/private" stringByAppendingString:path];
    return path;
}

static BOOL LBXOwnedExecutable(NSString *path) {
    struct stat node;
    if (lstat(path.fileSystemRepresentation, &node)) return NO;
    return S_ISREG(node.st_mode) && node.st_uid == 0 && !(node.st_mode & 0022);
}

BOOL LBXHelperAdmitAuditToken(audit_token_t token) {
    uid_t euid = token.val[1];
    pid_t pid = (pid_t)token.val[5];
    if ((euid != 0 && euid != 501) || pid <= 1) return NO;

    typedef int (*PathFunction)(audit_token_t *, void *, uint32_t);
    PathFunction getPath = (PathFunction)dlsym(RTLD_DEFAULT, "proc_pidpath_audittoken");
    if (!getPath) return NO;

    char pathBuf[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int length = getPath(&token, pathBuf, sizeof(pathBuf));
    if (length <= 0 || (size_t)length >= sizeof(pathBuf) || !memchr(pathBuf, 0, sizeof(pathBuf)))
        return NO;

    NSString *observed = LBXCanonicalPath([NSString stringWithUTF8String:pathBuf]);
    // Manager (mobile/root) + CLI (root) are hash-pinned when digests are non-zero.
    // Helper self-admission is path+ownership only so embedding HELPER_SHA256 does
    // not create a fixed-point against this binary's own digest.
    NSMutableDictionary *callers = [@{
        @LBX_SOCIALBOX_MANAGER_PATH : @[ @(LBX_SOCIALBOX_MANAGER_SIZE), @LBX_SOCIALBOX_MANAGER_SHA256 ]
    } mutableCopy];
    if (euid == 0) {
        callers[@LBX_SOCIALBOX_HELPER_PATH] = @[ @0, @"0" ];
        callers[@LBX_SOCIALBOX_CLI_PATH] =
            @[ @(LBX_SOCIALBOX_CLI_SIZE), @LBX_SOCIALBOX_CLI_SHA256 ];
    }

    for (NSString *candidate in callers) {
        NSString *expected = LBXCanonicalPath(candidate.stringByResolvingSymlinksInPath);
        if (![observed isEqual:expected] || !LBXOwnedExecutable(expected)) continue;

        NSArray *pin = callers[candidate];
        off_t size = [pin[0] longLongValue];
        NSString *digest = pin[1];
        BOOL skipHash = [candidate isEqual:@LBX_SOCIALBOX_HELPER_PATH];
        if (!skipHash && size > 0 && ![digest hasPrefix:@"00000000"]) {
            if (!LBXVerifyCallerFile(expected, size, digest)) return NO;
        }

        memset(pathBuf, 0, sizeof(pathBuf));
        length = getPath(&token, pathBuf, sizeof(pathBuf));
        if (length <= 0 || (size_t)length >= sizeof(pathBuf) || !memchr(pathBuf, 0, sizeof(pathBuf)))
            return NO;
        NSString *current = LBXCanonicalPath([NSString stringWithUTF8String:pathBuf]);
        return [current isEqual:expected];
    }
    return NO;
}
