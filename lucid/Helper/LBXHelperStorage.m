#import "LBXHelperStorage.h"
#import "LBXHelperProtocol.h"
#import "../Switching/LBXManagedApplications.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

NSString *const LBXHelperStorageRoot = @"/private/var/mobile/Library/SocialBox/Store";
NSString *const LBXHelperSharedStoreKey = @"Shared";

static NSString *const LBXDataContainersRoot = @"/private/var/mobile/Containers/Data/Application";
static NSString *const LBXAppGroupRoot = @"/private/var/mobile/Containers/Shared/AppGroup";
static NSString *const LBXPluginKitRoot = @"/private/var/mobile/Containers/Data/PluginKitPlugin";
static NSString *const LBXDataSlotKey = @"Data";
static NSString *const LBXContainerMetadataName = @".com.apple.mobile_container_manager.metadata.plist";
static NSString *const LBXLoadedMarkerName = @".loaded";
static const long long LBXMaxContainerID = 1000000;
static const uid_t LBXMobileUID = 501;
static const gid_t LBXMobileGID = 501;

static NSArray<NSString *> *LBXAppGroupsForBundle(NSString *bundleID) {
    if ([bundleID isEqualToString:@"com.burbn.instagram"]) return @[ @"group.com.burbn.instagram" ];
    if ([bundleID isEqualToString:@"com.facebook.Facebook"]) return @[ @"group.com.facebook.Facebook" ];
    return @[];
}

static NSArray<NSString *> *LBXSharedGroupIDs(void) {
    return @[
        @"group.com.facebook.family",
        @"group.com.burbn.family",
        @"group.com.metaplatforms.family",
        @"group.com.facebook.msysstorage",
    ];
}

static NSError *LBXStorageError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:LBXHelperErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"storage error"}];
}

static BOOL LBXValidContainerID(long long cid) {
    return cid >= 0 && cid <= LBXMaxContainerID;
}

static BOOL LBXIsStoreKey(NSString *key) {
    return [key isEqualToString:@"com.burbn.instagram"] || [key isEqualToString:@"com.facebook.Facebook"] ||
           [key isEqualToString:LBXHelperSharedStoreKey];
}

static NSString *LBXBundleStoreDir(NSString *bundleID) {
    return [LBXHelperStorageRoot stringByAppendingPathComponent:bundleID];
}

static NSString *LBXSlotDir(NSString *bundleID, long long cid) {
    return [LBXBundleStoreDir(bundleID) stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", cid]];
}

static BOOL LBXIsDirectoryNoFollow(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode);
}

static BOOL LBXEnsurePrivateDir(NSString *path, NSError **error) {
    if (LBXIsDirectoryNoFollow(path)) return YES;
    if (mkdir(path.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
        if (error)
            *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                     [NSString stringWithFormat:@"mkdir %@: %s", path, strerror(errno)]);
        return NO;
    }
    if (!LBXIsDirectoryNoFollow(path)) {
        if (error) *error = LBXStorageError(LBXHelperErrorPathDenied, @"store path is not a directory");
        return NO;
    }
    return YES;
}

static BOOL LBXEnsureSlotKey(NSString *saveSlot, NSString *key, NSError **error) {
    NSString *cursor = saveSlot;
    for (NSString *part in [key pathComponents]) {
        if ([part isEqualToString:@"/"] || [part isEqualToString:@"."] || [part isEqualToString:@".."]) continue;
        cursor = [cursor stringByAppendingPathComponent:part];
        if (!LBXEnsurePrivateDir(cursor, error)) return NO;
    }
    return YES;
}

static BOOL LBXEnsureStoreForBundle(NSString *bundleID, NSError **error) {
    NSString *parent = LBXHelperStorageRoot.stringByDeletingLastPathComponent;
    if (!LBXIsDirectoryNoFollow(parent) && mkdir(parent.fileSystemRepresentation, 0755) != 0 && errno != EEXIST) {
        if (error) *error = LBXStorageError(LBXHelperErrorOperationFailed, @"cannot create store parent");
        return NO;
    }
    return LBXEnsurePrivateDir(LBXHelperStorageRoot, error) &&
           LBXEnsurePrivateDir(LBXBundleStoreDir(bundleID), error);
}

static NSString *LBXFindContainer(NSString *root, NSString *identifier, BOOL *ambiguous) {
    *ambiguous = NO;
    NSArray<NSString *> *uuids = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    NSString *match = nil;
    for (NSString *uuid in uuids) {
        if (![[NSUUID alloc] initWithUUIDString:uuid]) continue;
        NSString *dir = [root stringByAppendingPathComponent:uuid];
        if (!LBXIsDirectoryNoFollow(dir)) continue;
        NSString *metaPath = [dir stringByAppendingPathComponent:LBXContainerMetadataName];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        if (![meta[@"MCMMetadataIdentifier"] isEqual:identifier]) continue;
        if (match) {
            *ambiguous = YES;
            return nil;
        }
        match = dir;
    }
    return match;
}

NSString *LBXHelperLiveDataContainer(NSString *bundleID, NSError **error) {
    if (!LBXDrainSupportedApplication(bundleID)) {
        if (error) *error = LBXStorageError(LBXHelperErrorInvalidArgument, @"unsupported bundle id");
        return nil;
    }
    BOOL ambiguous = NO;
    NSString *match = LBXFindContainer(LBXDataContainersRoot, bundleID, &ambiguous);
    if (!match && error)
        *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                 ambiguous ? @"multiple data containers claim this bundle id"
                                           : @"live data container not found");
    return match;
}

static NSArray<NSArray<NSString *> *> *LBXPrivateRoots(NSString *bundleID, NSError **error) {
    NSString *data = LBXHelperLiveDataContainer(bundleID, error);
    if (!data) return nil;
    NSMutableArray<NSArray<NSString *> *> *roots = [NSMutableArray arrayWithObject:@[ data, LBXDataSlotKey ]];
    for (NSString *group in LBXAppGroupsForBundle(bundleID)) {
        BOOL ambiguous = NO;
        NSString *dir = LBXFindContainer(LBXAppGroupRoot, group, &ambiguous);
        if (ambiguous) {
            if (error)
                *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                         [NSString stringWithFormat:@"multiple containers claim %@", group]);
            return nil;
        }
        if (dir) [roots addObject:@[ dir, group ]];
    }
    return roots;
}

static NSArray<NSArray<NSString *> *> *LBXSharedRoots(NSError **error) {
    NSMutableArray<NSArray<NSString *> *> *roots = [NSMutableArray array];
    for (NSString *group in LBXSharedGroupIDs()) {
        BOOL ambiguous = NO;
        NSString *dir = LBXFindContainer(LBXAppGroupRoot, group, &ambiguous);
        if (ambiguous) {
            if (error)
                *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                         [NSString stringWithFormat:@"multiple containers claim %@", group]);
            return nil;
        }
        if (dir) [roots addObject:@[ dir, group ]];
    }
    NSArray<NSString *> *uuids = [NSFileManager.defaultManager contentsOfDirectoryAtPath:LBXPluginKitRoot error:nil];
    for (NSString *uuid in uuids) {
        if (![[NSUUID alloc] initWithUUIDString:uuid]) continue;
        NSString *dir = [LBXPluginKitRoot stringByAppendingPathComponent:uuid];
        if (!LBXIsDirectoryNoFollow(dir)) continue;
        NSDictionary *meta =
            [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:LBXContainerMetadataName]];
        NSString *identifier = meta[@"MCMMetadataIdentifier"];
        if (![identifier isKindOfClass:NSString.class]) continue;
        BOOL ig = [identifier hasPrefix:@"com.burbn.instagram."];
        BOOL fb = [identifier hasPrefix:@"com.facebook.Facebook."];
        if (!ig && !fb) continue;
        [roots addObject:@[ dir, [@"PluginKit" stringByAppendingPathComponent:identifier] ]];
    }
    return roots;
}

long long LBXHelperLoadedContainerID(NSString *bundleID) {
    if (!LBXIsStoreKey(bundleID)) return -1;
    NSString *marker = [LBXBundleStoreDir(bundleID) stringByAppendingPathComponent:LBXLoadedMarkerName];
    NSString *text = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return -1;
    long long cid = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                        .longLongValue;
    return LBXValidContainerID(cid) ? cid : -1;
}

static BOOL LBXWriteLoadedMarker(NSString *bundleID, long long cid, NSError **error) {
    NSString *marker = [LBXBundleStoreDir(bundleID) stringByAppendingPathComponent:LBXLoadedMarkerName];
    NSString *tmp = [marker stringByAppendingString:@".tmp"];
    NSData *data = [[NSString stringWithFormat:@"%lld\n", cid] dataUsingEncoding:NSUTF8StringEncoding];
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:error]) return NO;
    if (rename(tmp.fileSystemRepresentation, marker.fileSystemRepresentation) != 0) {
        if (error) *error = LBXStorageError(LBXHelperErrorOperationFailed, @"cannot commit loaded marker");
        return NO;
    }
    return YES;
}

static NSArray<NSString *> *LBXPayloadChildren(NSString *dir, NSError **error) {
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:error];
    if (!names) return nil;
    NSMutableArray<NSString *> *payload = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name isEqualToString:LBXContainerMetadataName]) continue;
        if ([name isEqualToString:LBXLoadedMarkerName]) continue;
        [payload addObject:name];
    }
    return payload;
}

static BOOL LBXJournaledRename(NSString *from, NSString *to, NSMutableArray<NSArray<NSString *> *> *journal,
                               NSError **error) {
    struct stat info;
    if (lstat(to.fileSystemRepresentation, &info) == 0) {
        if (error)
            *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                     [NSString stringWithFormat:@"refusing to overwrite %@", to]);
        return NO;
    }
    if (rename(from.fileSystemRepresentation, to.fileSystemRepresentation) != 0) {
        if (error)
            *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                     [NSString stringWithFormat:@"rename %@ -> %@: %s", from, to, strerror(errno)]);
        return NO;
    }
    [journal addObject:@[ from, to ]];
    return YES;
}

static void LBXRollback(NSArray<NSArray<NSString *> *> *journal) {
    for (NSArray<NSString *> *move in journal.reverseObjectEnumerator) {
        rename(move[1].fileSystemRepresentation, move[0].fileSystemRepresentation);
    }
}

static BOOL LBXMoveChildren(NSString *fromDir, NSString *toDir, NSMutableArray *journal, NSError **error) {
    NSArray<NSString *> *children = LBXPayloadChildren(fromDir, error);
    if (!children) return NO;
    for (NSString *name in children) {
        if (!LBXJournaledRename([fromDir stringByAppendingPathComponent:name],
                                [toDir stringByAppendingPathComponent:name], journal, error)) {
            return NO;
        }
    }
    return YES;
}

static BOOL LBXCreateFreshSkeleton(NSString *live, NSMutableArray<NSString *> *created, NSError **error) {
    for (NSString *rel in
         @[ @"Documents", @"Library", @"Library/Caches", @"Library/Preferences", @"tmp", @"SystemData" ]) {
        NSString *path = [live stringByAppendingPathComponent:rel];
        if (LBXIsDirectoryNoFollow(path)) continue;
        if (mkdir(path.fileSystemRepresentation, 0755) != 0 ||
            chown(path.fileSystemRepresentation, LBXMobileUID, LBXMobileGID) != 0) {
            if (error)
                *error = LBXStorageError(LBXHelperErrorOperationFailed,
                                         [NSString stringWithFormat:@"skeleton %@: %s", rel, strerror(errno)]);
            return NO;
        }
        [created addObject:path];
    }
    return YES;
}

// One SIGTERM of launchd's cfprefsd. The apps have already been drained, so
// this flushes leftover writes. launchd relaunches it on the next read; we
// do not kill it a second time after the moves.
static BOOL LBXRestartPreferencesDaemon(NSError **error) {
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, 0};
    size_t bytes = 0;
    if (sysctl(mib, 4, NULL, &bytes, NULL, 0) != 0 || bytes == 0) {
        if (error) *error = LBXStorageError(LBXHelperErrorOperationFailed, @"process enumeration failed");
        return NO;
    }
    bytes += 32 * sizeof(struct kinfo_proc);
    struct kinfo_proc *procs = calloc(1, bytes);
    if (!procs || sysctl(mib, 4, procs, &bytes, NULL, 0) != 0) {
        free(procs);
        if (error) *error = LBXStorageError(LBXHelperErrorOperationFailed, @"process enumeration failed");
        return NO;
    }
    pid_t targets[8];
    size_t count = 0;
    for (size_t i = 0; i < bytes / sizeof(struct kinfo_proc) && count < 8; i++) {
        struct kinfo_proc *proc = &procs[i];
        if (proc->kp_eproc.e_ppid != 1 || strncmp(proc->kp_proc.p_comm, "cfprefsd", MAXCOMLEN) != 0) continue;
        if (kill(proc->kp_proc.p_pid, SIGTERM) == 0) targets[count++] = proc->kp_proc.p_pid;
    }
    free(procs);
    for (int attempt = 0; attempt < 100; attempt++) {
        BOOL alive = NO;
        for (size_t i = 0; i < count; i++) {
            if (kill(targets[i], 0) == 0 || errno != ESRCH) alive = YES;
        }
        if (!alive) return YES;
        usleep(50000);
    }
    if (error) *error = LBXStorageError(LBXHelperErrorOperationFailed, @"cfprefsd did not exit");
    return NO;
}

static BOOL LBXSwitchRoots(NSArray<NSArray<NSString *> *> *roots, NSString *bundleID, long long current,
                           long long toContainerID, NSMutableArray *journal, NSMutableArray *created,
                           NSError **error) {
    if (current == toContainerID) return YES;
    NSString *saveSlot = LBXSlotDir(bundleID, current);
    NSString *loadSlot = LBXSlotDir(bundleID, toContainerID);
    if (!LBXEnsurePrivateDir(saveSlot, error)) return NO;
    for (NSArray<NSString *> *root in roots) {
        if (!LBXEnsureSlotKey(saveSlot, root[1], error)) return NO;
    }
    for (NSArray<NSString *> *root in roots) {
        if (!LBXMoveChildren(root[0], [saveSlot stringByAppendingPathComponent:root[1]], journal, error)) return NO;
    }
    for (NSArray<NSString *> *root in roots) {
        NSString *slot = [loadSlot stringByAppendingPathComponent:root[1]];
        if (LBXIsDirectoryNoFollow(slot)) {
            if (!LBXMoveChildren(slot, root[0], journal, error)) return NO;
        } else if ([root[1] isEqualToString:LBXDataSlotKey]) {
            if (!LBXCreateFreshSkeleton(root[0], created, error)) return NO;
        }
    }
    return YES;
}

BOOL LBXHelperSwitchContainerStorage(NSString *bundleID, long long fromContainerID, long long toContainerID,
                                     NSError **error) {
    if (geteuid() != 0) {
        if (error) *error = LBXStorageError(LBXHelperErrorUnauthorized, @"storage switch requires root");
        return NO;
    }
    if (!LBXDrainSupportedApplication(bundleID) || !LBXValidContainerID(fromContainerID) ||
        !LBXValidContainerID(toContainerID)) {
        if (error) *error = LBXStorageError(LBXHelperErrorInvalidArgument, @"invalid switch arguments");
        return NO;
    }
    NSArray<NSArray<NSString *> *> *roots = LBXPrivateRoots(bundleID, error);
    if (!roots) return NO;
    if (!LBXEnsureStoreForBundle(bundleID, error)) return NO;
    long long loaded = LBXHelperLoadedContainerID(bundleID);
    long long current = loaded >= 0 ? loaded : fromContainerID;
    if (current == toContainerID) {
        return loaded >= 0 ? YES : LBXWriteLoadedMarker(bundleID, toContainerID, error);
    }
    if (!LBXRestartPreferencesDaemon(error)) return NO;
    NSMutableArray *journal = [NSMutableArray array];
    NSMutableArray *created = [NSMutableArray array];
    BOOL ok = LBXSwitchRoots(roots, bundleID, current, toContainerID, journal, created, error);
    if (ok) ok = LBXWriteLoadedMarker(bundleID, toContainerID, error);
    if (!ok) {
        for (NSString *path in created.reverseObjectEnumerator) rmdir(path.fileSystemRepresentation);
        LBXRollback(journal);
        return NO;
    }
    return YES;
}

BOOL LBXHelperSwitchPhoneStorage(long long fromContainerID, long long toContainerID, NSError **error) {
    if (geteuid() != 0) {
        if (error) *error = LBXStorageError(LBXHelperErrorUnauthorized, @"storage switch requires root");
        return NO;
    }
    if (!LBXValidContainerID(fromContainerID) || !LBXValidContainerID(toContainerID)) {
        if (error) *error = LBXStorageError(LBXHelperErrorInvalidArgument, @"invalid switch arguments");
        return NO;
    }
    NSArray<NSString *> *apps = @[ @"com.burbn.instagram", @"com.facebook.Facebook" ];
    NSMutableDictionary<NSString *, NSArray *> *privateRoots = [NSMutableDictionary dictionary];
    for (NSString *bundleID in apps) {
        NSArray *roots = LBXPrivateRoots(bundleID, error);
        if (!roots) return NO;
        privateRoots[bundleID] = roots;
        if (!LBXEnsureStoreForBundle(bundleID, error)) return NO;
    }
    NSArray *sharedRoots = LBXSharedRoots(error);
    if (!sharedRoots) return NO;
    if (!LBXEnsureStoreForBundle(LBXHelperSharedStoreKey, error)) return NO;

    long long igCurrent = LBXHelperLoadedContainerID(@"com.burbn.instagram");
    long long fbCurrent = LBXHelperLoadedContainerID(@"com.facebook.Facebook");
    long long sharedCurrent = LBXHelperLoadedContainerID(LBXHelperSharedStoreKey);
    if (igCurrent < 0) igCurrent = fromContainerID;
    if (fbCurrent < 0) fbCurrent = fromContainerID;
    if (sharedCurrent < 0) sharedCurrent = fromContainerID;
    if (igCurrent == toContainerID && fbCurrent == toContainerID && sharedCurrent == toContainerID) {
        BOOL marks = YES;
        if (LBXHelperLoadedContainerID(@"com.burbn.instagram") < 0)
            marks = LBXWriteLoadedMarker(@"com.burbn.instagram", toContainerID, error);
        if (marks && LBXHelperLoadedContainerID(@"com.facebook.Facebook") < 0)
            marks = LBXWriteLoadedMarker(@"com.facebook.Facebook", toContainerID, error);
        if (marks && LBXHelperLoadedContainerID(LBXHelperSharedStoreKey) < 0)
            marks = LBXWriteLoadedMarker(LBXHelperSharedStoreKey, toContainerID, error);
        return marks;
    }

    if (!LBXRestartPreferencesDaemon(error)) return NO;

    NSMutableArray *journal = [NSMutableArray array];
    NSMutableArray *created = [NSMutableArray array];
    BOOL ok = LBXSwitchRoots(privateRoots[@"com.burbn.instagram"], @"com.burbn.instagram", igCurrent, toContainerID,
                             journal, created, error);
    if (ok)
        ok = LBXSwitchRoots(privateRoots[@"com.facebook.Facebook"], @"com.facebook.Facebook", fbCurrent, toContainerID,
                            journal, created, error);
    if (ok)
        ok = LBXSwitchRoots(sharedRoots, LBXHelperSharedStoreKey, sharedCurrent, toContainerID, journal, created,
                            error);
    if (ok) ok = LBXWriteLoadedMarker(@"com.burbn.instagram", toContainerID, error);
    if (ok) ok = LBXWriteLoadedMarker(@"com.facebook.Facebook", toContainerID, error);
    if (ok) ok = LBXWriteLoadedMarker(LBXHelperSharedStoreKey, toContainerID, error);
    if (!ok) {
        for (NSString *path in created.reverseObjectEnumerator) rmdir(path.fileSystemRepresentation);
        LBXRollback(journal);
        return NO;
    }
    return YES;
}

static BOOL LBXPathUnderStore(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return NO;
    NSString *root = LBXHelperStorageRoot;
    return [path isEqual:root] || [path hasPrefix:[root stringByAppendingString:@"/"]];
}

BOOL LBXHelperDeleteContainerStorage(long long containerID, NSError **error) {
    if (geteuid() != 0) {
        if (error) *error = LBXStorageError(LBXHelperErrorUnauthorized, @"delete requires root");
        return NO;
    }
    if (!LBXValidContainerID(containerID) || containerID < 1) {
        if (error) *error = LBXStorageError(LBXHelperErrorInvalidArgument, @"invalid container id");
        return NO;
    }
    NSArray<NSString *> *keys = @[ @"com.burbn.instagram", @"com.facebook.Facebook", LBXHelperSharedStoreKey ];
    for (NSString *key in keys) {
        long long loaded = LBXHelperLoadedContainerID(key);
        if (loaded == containerID) {
            if (error)
                *error = LBXStorageError(LBXHelperErrorRefused,
                                         @"refusing to delete the container that is currently loaded");
            return NO;
        }
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *key in keys) {
        NSString *slot = LBXSlotDir(key, containerID);
        if (!LBXPathUnderStore(slot) || [slot isEqual:LBXHelperStorageRoot] ||
            [slot isEqual:LBXBundleStoreDir(key)]) {
            if (error) *error = LBXStorageError(LBXHelperErrorPathDenied, @"delete path refused");
            return NO;
        }
        if (!LBXIsDirectoryNoFollow(slot)) continue;
        NSError *local = nil;
        if (![fm removeItemAtPath:slot error:&local]) {
            if (error) *error = local ?: LBXStorageError(LBXHelperErrorOperationFailed, @"could not remove slot");
            return NO;
        }
    }
    return YES;
}

static NSDictionary *LBXHelperKeychainPartitionReport(void) {
    NSData *data = [NSData dataWithContentsOfFile:@"/private/var/tmp/socialbox_keychain_partition.json"];
    NSDictionary *sidecar = data.length
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (![sidecar isKindOfClass:NSDictionary.class]) {
        BOOL shipped = [[NSFileManager defaultManager]
            fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/SocialBoxAppKeychain.dylib"] ||
            [[NSFileManager defaultManager]
                fileExistsAtPath:@"/var/jb/usr/lib/TweakInject/SocialBoxAppKeychain.dylib"];
        return @{
            @"separated" : @NO,
            @"status" : shipped ? @"SHIPPED_UNPROBED" : @"NOT_SEPARATED",
            @"reason" : shipped
                ? @"Client-side partition is installed. Launch Instagram or Facebook once so the in-process canary can write its sidecar."
                : @"Client-side keychain partition is not installed.",
            @"hookShipped" : @(shipped),
        };
    }
    BOOL separated = [sidecar[@"separated"] boolValue] && [sidecar[@"status"] isEqual:@"SEPARATED"];
    NSMutableDictionary *out = [sidecar mutableCopy];
    out[@"separated"] = @(separated);
    out[@"status"] = separated ? @"SEPARATED" : (sidecar[@"status"] ?: @"NOT_SEPARATED");
    out[@"hookShipped"] = @YES;
    return out;
}

NSDictionary *LBXHelperDataSeparationReport(long long containerID) {
    NSMutableArray *sharedPresent = [NSMutableArray array];
    NSMutableArray *pluginKit = [NSMutableArray array];
    NSArray *roots = LBXSharedRoots(NULL) ?: @[];
    for (NSArray<NSString *> *root in roots) {
        if ([root[1] hasPrefix:@"PluginKit/"]) {
            [pluginKit addObject:root[1]];
        } else {
            [sharedPresent addObject:root[1]];
        }
    }
    NSString *igLive = LBXHelperLiveDataContainer(@"com.burbn.instagram", NULL);
    NSString *fbLive = LBXHelperLiveDataContainer(@"com.facebook.Facebook", NULL);
    long long ig = LBXHelperLoadedContainerID(@"com.burbn.instagram");
    long long fb = LBXHelperLoadedContainerID(@"com.facebook.Facebook");
    long long shared = LBXHelperLoadedContainerID(LBXHelperSharedStoreKey);
    BOOL igSlot = LBXIsDirectoryNoFollow(LBXSlotDir(@"com.burbn.instagram", containerID));
    BOOL fbSlot = LBXIsDirectoryNoFollow(LBXSlotDir(@"com.facebook.Facebook", containerID));
    BOOL sharedSlot = LBXIsDirectoryNoFollow(LBXSlotDir(LBXHelperSharedStoreKey, containerID));
    BOOL loadedHere = (ig == containerID && fb == containerID && (shared == containerID || shared < 0));
    BOOL parked = !loadedHere && (igSlot || fbSlot || sharedSlot);
    return @{
        @"containerID" : @(containerID),
        @"loadedInstagram" : @(ig),
        @"loadedFacebook" : @(fb),
        @"loadedShared" : @(shared),
        @"instagramLive" : igLive ?: @"",
        @"facebookLive" : fbLive ?: @"",
        @"instagramSlotPresent" : @(igSlot),
        @"facebookSlotPresent" : @(fbSlot),
        @"sharedSlotPresent" : @(sharedSlot),
        @"sharedGroupsPresent" : sharedPresent,
        @"pluginKitPresent" : pluginKit,
        @"phoneLoadedHere" : @(loadedHere),
        @"parkedSlotPresent" : @(parked),
        @"keychain" : LBXHelperKeychainPartitionReport(),
        @"isolationVerified" : @NO,
    };
}
