#import "RBXAppRegistry.h"
#import "RBXAppAdmission.h"
#import "RBXAppLifecycle.h"
#import "RBXProfileIdentifier.h"
#import "RBXContainerRegistry.h"
#import "RBXProfileMetadata.h"
#import "RBXDataSchema.h"
#import "RBXOperationContext.h"
#import "RBXConsistencyValidator.h"
#import "RBXProfileGenerator.h"
#import "RBXProfileIO.h"
#import "RBXABTestFramework.h"
#import "RBXCentralStore.h"
#import "RBXIdentityLifecycle.h"
#import "RBXProxyManager.h"
#import "RBXDeviceCatalog.h"
#import "RBXCloneManager.h"
#import "RBXMGOverrides.h"
#import "RBXNetworkGate.h"
#import "RBXRotationSecrets.h"
#import "RBXProfileTransport.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <dirent.h>
#import <string.h>
#import <CommonCrypto/CommonDigest.h>

#ifdef RBX_REGISTRY_TESTING
// Native fault tests include this implementation with isolated temporary roots.
// The production daemon never defines this flag or reads environment overrides.
static NSString *kProfilesDir, *kDeletedContainerIds, *kDeletionRoot, *kActiveBindingPath;
static NSArray *kLegacyDataRoots;
static uid_t RBXDeletionOwner(void) { return geteuid(); }
#else
static NSString *const kProfilesDir = @"/var/mobile/Library/Preferences/com.redditbox.profiles";
static NSString *const kDeletedContainerIds =
    @"/var/mobile/Library/Preferences/com.redditbox.deleted-containers.plist";
static NSString *const kDeletionRoot = @"/var/mobile/Library/RedditBox/deletions";
static NSString *const kActiveBindingPath = @"/var/mobile/Library/Preferences/com.redditbox.activeContainer";
static uid_t RBXDeletionOwner(void) { return 0; }
#endif

static NSError *RBXDeletionError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.deletion" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Deletion could not be completed; retry after reviewing its state"}];
}

static BOOL RBXDeletionID(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length ||
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 180) return NO;
    NSMutableCharacterSet *allowed = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [allowed addCharactersInString:@"-_"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// -2 is a missing directory; -1 is an unsafe or unreadable existing directory.
static int RBXOpenDeletionRoot(BOOL create, NSError **error) {
    if (create) {
        NSString *parentPath = kDeletionRoot.stringByDeletingLastPathComponent;
        if (![NSFileManager.defaultManager createDirectoryAtPath:parentPath
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0755}
            error:error]) return -1;
        int parent = open(parentPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int grandparent = open(parentPath.stringByDeletingLastPathComponent.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        struct stat parentInfo;
        BOOL safe = parent >= 0 && fstat(parent, &parentInfo) == 0 &&
            parentInfo.st_uid == RBXDeletionOwner() && !(parentInfo.st_mode & 0022) &&
            grandparent >= 0 && fsync(grandparent) == 0;
        if (grandparent >= 0) close(grandparent);
        if (safe && mkdirat(parent, kDeletionRoot.lastPathComponent.fileSystemRepresentation, 0700) != 0 && errno != EEXIST)
            safe = NO;
        // The reservation directory's own name must be durable before any
        // journal inside it authorizes destructive cleanup.
        if (safe) safe = fsync(parent) == 0;
        if (parent >= 0) close(parent);
        if (!safe) {
            if (error) *error = RBXDeletionError(@"Deletion journal parent could not be verified or synchronized");
            return -1;
        }
    }
    int fd = open(kDeletionRoot.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) {
        if (!create && errno == ENOENT) return -2;
        if (error) *error = RBXDeletionError(@"Deletion journal directory cannot be opened safely");
        return -1;
    }
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != RBXDeletionOwner() || (info.st_mode & 0077)) {
        close(fd);
        if (error) *error = RBXDeletionError(@"Deletion journal directory ownership or permissions are invalid");
        return -1;
    }
    return fd;
}

static NSDictionary *RBXReadDeletion(int directory, NSString *containerId, NSError **error) {
    if (!RBXDeletionID(containerId)) {
        if (error) *error = RBXDeletionError(@"Container ID is not a safe profile identifier");
        return nil;
    }
    if (directory == -2) return nil;
    NSString *name = [containerId stringByAppendingPathExtension:@"plist"];
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) {
        if (errno != ENOENT && error) *error = RBXDeletionError(@"Deletion journal cannot be read safely");
        return nil;
    }
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == RBXDeletionOwner() &&
        info.st_nlink == 1 && !(info.st_mode & 0077) && info.st_size > 0 && info.st_size <= 2 * 1024 * 1024;
    NSMutableData *data = [NSMutableData data];
    unsigned char bytes[8192];
    while (valid) {
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (count == 0) break;
        [data appendBytes:bytes length:(NSUInteger)count];
        if (data.length > 2 * 1024 * 1024) valid = NO;
    }
    close(fd);
    id value = valid ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:nil] : nil;
    NSArray *phases = @[@"prepared", @"keychain-cleared", @"uninstalled", @"cleanup-complete", @"committed"];
    if (![value isKindOfClass:NSDictionary.class] ||
        !RBXAppDeletionJournalDescriptor(value) || ![value[@"containerId"] isEqual:containerId] ||
        ![value[@"phase"] isKindOfClass:NSString.class] || ![phases containsObject:value[@"phase"]] ||
        ![value[@"target"] isKindOfClass:NSDictionary.class] ||
        (value[@"profileEvidence"] && ![value[@"profileEvidence"] isKindOfClass:NSData.class]) ||
        (value[@"finalProfileEvidence"] && ![value[@"finalProfileEvidence"] isKindOfClass:NSData.class]) ||
        ![value[@"createdAt"] isKindOfClass:NSNumber.class] ||
        ![value[@"updatedAt"] isKindOfClass:NSNumber.class]) {
        if (error) *error = RBXDeletionError(@"Deletion journal is corrupt or untrusted; retain it for recovery");
        return nil;
    }
    return value;
}

static BOOL RBXWriteDeletion(int directory, NSMutableDictionary *journal,
                             NSString *phase, NSError **error) {
    NSMutableDictionary *next = [journal mutableCopy];
    next[@"phase"] = phase;
    next[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
    if (!RBXAppDeletionJournalDescriptor(next) ||
        ![@[@"prepared", @"keychain-cleared", @"uninstalled", @"cleanup-complete", @"committed"] containsObject:phase ?: @""]) {
        if (error) *error = RBXDeletionError(@"Deletion owner or phase is invalid; the previous checkpoint is preserved");
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:next
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    if (data.length > 2 * 1024 * 1024) {
        if (error) *error = RBXDeletionError(@"Deletion target exceeds the journal limit; retain its evidence for manual recovery");
        return NO;
    }
    NSString *name = [next[@"containerId"] stringByAppendingPathExtension:@"plist"];
    NSString *temporary = [NSString stringWithFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = openat(directory, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    BOOL ok = fd >= 0;
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t written = write(fd, (const unsigned char *)data.bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        offset += (NSUInteger)written;
    }
    if (ok) ok = fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (ok) ok = renameat(directory, temporary.fileSystemRepresentation,
        directory, name.fileSystemRepresentation) == 0;
    if (ok) ok = fsync(directory) == 0;
    if (!ok) {
        unlinkat(directory, temporary.fileSystemRepresentation, 0);
        if (error) *error = RBXDeletionError(@"Deletion phase could not be durably published; retain its journal and retry cleanup");
        return NO;
    }
    NSDictionary *verified = RBXReadDeletion(directory, next[@"containerId"], error);
    if (![verified isEqualToDictionary:next]) {
        if (error) *error = RBXDeletionError(@"Deletion journal verification failed");
        return NO;
    }
    [journal setDictionary:next];
    return YES;
}

// Convert recovery authority into a permanent tombstone only after durable
// profile absence. A failed publication leaves the caller's evidence intact.
static BOOL RBXCommitDeletion(int directory, NSMutableDictionary *journal, NSError **error) {
    NSString *containerId = journal[@"containerId"];
    if (!RBXDeletionID(containerId)) {
        if (error) *error = RBXDeletionError(@"Deletion tombstone has an invalid profile identity");
        return NO;
    }
    NSString *path = [[kProfilesDir stringByAppendingPathComponent:containerId] stringByAppendingPathExtension:@"json"];
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) == 0 || errno != ENOENT) {
        if (error) *error = RBXDeletionError(@"Profile absence could not be verified before deletion commit");
        return NO;
    }
    int profilesFD = open(kProfilesDir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (profilesFD < 0 && errno == ENOENT) {
        // If the whole profile directory disappeared, synchronize its existing
        // preferences parent so that absence is also a durable fact.
        profilesFD = open(kProfilesDir.stringByDeletingLastPathComponent.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    }
    BOOL durable = profilesFD >= 0 && fsync(profilesFD) == 0;
    if (profilesFD >= 0) close(profilesFD);
    if (!durable) {
        if (error) *error = RBXDeletionError(@"Profile removal durability could not be verified");
        return NO;
    }
    NSMutableDictionary *tombstone = [journal mutableCopy];
    [tombstone removeObjectsForKeys:@[@"profileEvidence", @"finalProfileEvidence", @"profileReadError", @"lastError"]];
    if (!RBXWriteDeletion(directory, tombstone, @"committed", error)) return NO;
    [journal setDictionary:tombstone];
    return YES;
}

static NSArray *RBXLegacyRetiredIDs(NSError **error) {
    struct stat info;
    if (lstat(kDeletedContainerIds.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) return @[];
        if (error) *error = RBXDeletionError(@"Legacy retirement records cannot be read");
        return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_uid != RBXDeletionOwner() || (info.st_mode & 0022)) {
        if (error) *error = RBXDeletionError(@"Legacy retirement records are not a regular file");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:kDeletedContainerIds options:0 error:error];
    if (!data) return nil;
    id value = data.length ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:error] : nil;
    if (![value isKindOfClass:NSArray.class]) {
        if (error) *error = RBXDeletionError(@"Legacy retirement records are corrupt; container reuse is blocked");
        return nil;
    }
    for (id identifier in value) if (!RBXDeletionID(identifier)) {
        if (error) *error = RBXDeletionError(@"Legacy retirement records contain an invalid container ID");
        return nil;
    }
    return value;
}

static NSDictionary *RBXDeletionSummary(NSString *identifier, NSDictionary *journal, NSError *error) {
    NSString *phase = journal[@"phase"] ?: @"recovery-required";
    NSString *message = error.localizedDescription ?: journal[@"lastError"];
    if ([phase isEqual:@"committed"]) {
        NSString *path = [[kProfilesDir stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"json"];
        struct stat info;
        int result = lstat(path.fileSystemRepresentation, &info);
        if (result == 0 || errno != ENOENT) {
            phase = result == 0 ? @"cleanup-complete" : @"recovery-required";
            message = result == 0 ? @"A profile remains after deletion; retry Delete to finish cleanup"
                : @"Profile absence could not be verified; retry deletion after resolving the read error";
        } else if (journal[@"profileEvidence"] || journal[@"finalProfileEvidence"] || journal[@"profileReadError"]) {
            phase = @"cleanup-complete";
            message = @"Deletion recovery evidence remains; retry Delete to finish cleanup";
        }
    }
    BOOL complete = [phase isEqual:@"committed"];
    if (![message isKindOfClass:NSString.class] || !message.length)
        message = complete ? @"Container deletion completed" : @"Deletion is incomplete; retry Delete to finish cleanup";
    return @{@"containerId": identifier ?: @"", @"phase": phase,
        @"completed": @(complete), @"retryable": @(!complete), @"message": message,
        @"updatedAt": journal[@"updatedAt"] ?: @0};
}

// Remove only the already opened, exact legacy subtree. Never follow a link or
// recurse into another app/container; verify inode identity before unlinking.
static BOOL RBXRemoveLegacyTree(int parent, const char *name, NSError **error) {
    struct stat before;
    if (fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) return YES;
        if (error) *error = RBXDeletionError(@"Legacy container data could not be inspected");
        return NO;
    }
    if (!S_ISREG(before.st_mode) && !S_ISDIR(before.st_mode)) {
        if (error) *error = RBXDeletionError(@"Legacy container data contains a link or unsupported file; retain it for recovery");
        return NO;
    }
    if (S_ISDIR(before.st_mode)) {
        int child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        struct stat opened;
        if (child < 0 || fstat(child, &opened) != 0 || before.st_dev != opened.st_dev || before.st_ino != opened.st_ino) {
            if (child >= 0) close(child);
            if (error) *error = RBXDeletionError(@"Legacy container directory changed during cleanup");
            return NO;
        }
        DIR *listing = fdopendir(dup(child));
        BOOL ok = listing != NULL;
        if (listing) {
            errno = 0;
            struct dirent *entry;
            while ((entry = readdir(listing))) {
                if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
                if (!RBXRemoveLegacyTree(child, entry->d_name, error)) { ok = NO; break; }
                errno = 0;
            }
            if (ok && errno) ok = NO;
            closedir(listing);
        }
        if (ok) ok = fsync(child) == 0;
        close(child);
        if (!ok) {
            if (error && !*error) *error = RBXDeletionError(@"Legacy data enumeration or cleanup durability failed");
            return NO;
        }
    }
    struct stat current;
    if (fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) != 0 ||
        before.st_dev != current.st_dev || before.st_ino != current.st_ino ||
        unlinkat(parent, name, S_ISDIR(before.st_mode) ? AT_REMOVEDIR : 0) != 0 || fsync(parent) != 0) {
        if (error) *error = RBXDeletionError(@"Legacy data removal could not be verified; retry cleanup");
        return NO;
    }
    return YES;
}

static BOOL RBXCleanupLegacyData(NSString *identifier, NSError **error) {
    NSMutableSet *visited = [NSMutableSet set];
#ifdef RBX_REGISTRY_TESTING
    NSArray *roots = kLegacyDataRoots;
#else
    NSArray *roots = @[@"/var/mobile/Containers/Data/Application", @"/var/containers/Data/Application"];
#endif
    for (NSString *sourceRoot in roots) {
        NSString *root = sourceRoot.stringByResolvingSymlinksInPath;
        if ([visited containsObject:root]) continue;
        [visited addObject:root];
        int rootFD = open(root.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (rootFD < 0) {
            if (errno == ENOENT) continue;
            if (error) *error = RBXDeletionError(@"Legacy application containers could not be enumerated");
            return NO;
        }
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:error];
        if (!entries) { close(rootFD); return NO; }
        BOOL ok = YES;
        for (NSString *entry in entries) {
            if (![[NSUUID alloc] initWithUUIDString:entry]) continue;
            int app = openat(rootFD, entry.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (app < 0) { if (errno == ENOENT) continue; ok = NO; break; }
            int rbx = openat(app, "redditbox", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (rbx < 0) { int saved = errno; close(app); if (saved == ENOENT) continue; ok = NO; break; }
            int containers = openat(rbx, "containers", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            close(rbx);
            if (containers < 0) { int saved = errno; close(app); if (saved == ENOENT) continue; ok = NO; break; }
            struct stat target;
            if (fstatat(containers, identifier.fileSystemRepresentation, &target, AT_SYMLINK_NOFOLLOW) != 0) {
                int saved = errno;
                BOOL absentDurable = saved == ENOENT && fsync(containers) == 0;
                close(containers); close(app);
                if (absentDurable) continue;
                ok = NO; break;
            }
            struct stat owner, metadata;
            NSString *metadataPath = [[root stringByAppendingPathComponent:entry]
                stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            BOOL trusted = fstat(app, &owner) == 0 && owner.st_uid == 501 &&
                fstatat(app, ".com.apple.mobile_container_manager.metadata.plist", &metadata, AT_SYMLINK_NOFOLLOW) == 0 &&
                S_ISREG(metadata.st_mode) && metadata.st_nlink == 1 && S_ISDIR(target.st_mode);
            NSDictionary *document = trusted ? [NSDictionary dictionaryWithContentsOfFile:metadataPath] : nil;
            NSString *bundle = [document[@"MCMMetadataIdentifier"] isKindOfClass:NSString.class]
                ? document[@"MCMMetadataIdentifier"] : @"";
            // Residue predates multi-app support and remains Reddit-only.
            NSDictionary *descriptor = RBXRedditAppDescriptor();
            BOOL ownBundle = [bundle isEqual:descriptor[@"sourceBundleIdentifier"]] ||
                RBXAppOwnsCloneBundleIdentifier(descriptor, bundle);
            ok = trusted && ownBundle && RBXRemoveLegacyTree(containers, identifier.fileSystemRepresentation, error);
            close(containers); close(app);
            if (!ok) break;
        }
        close(rootFD);
        if (!ok) {
            if (error && !*error) *error = RBXDeletionError(@"Legacy residue ownership could not be proven; unrelated application data was preserved");
            return NO;
        }
    }
    return YES;
}

static NSString *RBXRegistryValue(NSDictionary *profile, NSString *path) {
    id value = profile;
    for (NSString *part in [path componentsSeparatedByString:@"."]) {
        if (![value isKindOfClass:[NSDictionary class]]) return nil;
        value = value[part];
    }
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

// Read exact bytes through the validated filename. Malformed JSON is still
// evidence for explicit deletion, but links, unreadable files and oversized
// files never become an unchecked path or an empty successful read.
static NSData *RBXDeletionProfileData(NSString *containerId, BOOL *missing, NSError **error) {
    if (missing) *missing = NO;
    if (!RBXDeletionID(containerId)) {
        if (error) *error = RBXDeletionError(@"Container ID is not a safe profile identifier");
        return nil;
    }
    int directory = open(kProfilesDir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory < 0) {
        if (errno == ENOENT) { if (missing) *missing = YES; return nil; }
        if (error) *error = RBXDeletionError(@"Profile directory cannot be opened safely for deletion");
        return nil;
    }
    NSString *name = [containerId stringByAppendingPathExtension:@"json"];
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int saved = errno;
    close(directory);
    if (fd < 0) {
        if (saved == ENOENT) { if (missing) *missing = YES; return nil; }
        if (error) *error = RBXDeletionError(@"Profile cannot be read safely for deletion");
        return nil;
    }
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 &&
        info.st_size >= 0 && info.st_size <= 2 * 1024 * 1024;
    NSMutableData *data = [NSMutableData data];
    unsigned char bytes[8192];
    while (valid) {
        ssize_t count = read(fd, bytes, sizeof(bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) break;
        [data appendBytes:bytes length:(NSUInteger)count];
        if (data.length > 2 * 1024 * 1024) valid = NO;
    }
    close(fd);
    if (!valid) {
        if (error) *error = RBXDeletionError(@"Profile is unreadable, unsafe, or too large for deletion evidence; retain it for recovery");
        return nil;
    }
    return data;
}

#ifndef RBX_REGISTRY_JOURNAL_TESTING

static NSDictionary *RBXIdentityHashes(NSDictionary *profile) {
    NSMutableDictionary *hashes = [NSMutableDictionary dictionary];
    for (NSString *path in @[@"serials.udid", @"serials.serialNumber", @"serials.imei1",
        @"serials.wifiMac", @"serials.btMac", @"serials.platformUUID", @"serials.mlb",
        @"serials.uniqueChipId", @"ids.idfa", @"ids.idfv", @"reddit.installId", @"reddit.externalInstallationId"]) {
        id value = profile;
        for (NSString *part in [path componentsSeparatedByString:@"."])
            value = [value isKindOfClass:NSDictionary.class] ? value[part] : nil;
        NSString *string = [value isKindOfClass:NSString.class] ? value :
            ([value isKindOfClass:NSNumber.class] ? [value stringValue] : nil);
        if (!string.length || ([path isEqual:@"ids.idfa"] &&
            [string isEqual:@"00000000-0000-0000-0000-000000000000"])) continue;
        NSData *bytes = [[NSString stringWithFormat:@"%@:%@", path, string.lowercaseString]
            dataUsingEncoding:NSUTF8StringEncoding];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes.bytes, (CC_LONG)bytes.length, digest);
        NSMutableString *hash = [NSMutableString string];
        for (NSUInteger index = 0; index < sizeof(digest); index++) [hash appendFormat:@"%02x", digest[index]];
        hashes[hash] = path;
    }
    return hashes;
}

// Recovery may restore deliberately malformed evidence. Publish only into an
// absent pathname: never overwrite a newer or independently restored profile.
static BOOL RBXRestoreDeletionEvidence(NSData *data, NSString *path) {
    NSString *temporary = [path stringByAppendingFormat:@".%@.restore", NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    BOOL ok = fd >= 0; NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t count = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (NSUInteger)count;
    }
    if (ok) ok = fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (ok) ok = link(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    unlink(temporary.fileSystemRepresentation);
    if (ok) {
        int parent = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        ok = parent >= 0 && fsync(parent) == 0;
        if (parent >= 0) close(parent);
    }
    return ok && [[NSData dataWithContentsOfFile:path] isEqual:data];
}

static BOOL RBXIdentityReservationsValid(id reservations) {
    if (!reservations) return YES;
    if (![reservations isKindOfClass:NSDictionary.class]) return NO;
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    for (id hash in reservations) {
        if (![hash isKindOfClass:NSString.class] || [hash length] != 64 ||
            [hash rangeOfCharacterFromSet:nonHex].location != NSNotFound ||
            !RBXCanonicalProfileIdentifier(reservations[hash])) return NO;
    }
    return YES;
}

static NSDictionary *RBXCheckedIdentityReservations(NSError **error) {
    struct stat info;
    if (lstat(RBXCentralStore.storePath.fileSystemRepresentation, &info) != 0 && errno == ENOENT) return @{};
    NSDictionary *store = [RBXProfileIO readJSONDictionaryAtPath:RBXCentralStore.storePath error:error];
    if (!store) return nil;
    id reservations = store[@"identityReservations"];
    if (!RBXIdentityReservationsValid(reservations)) {
        if (error) *error = RBXDeletionError(@"Identity reservation history is corrupt; identities remain blocked");
        return nil;
    }
    return reservations ?: @{};
}
static BOOL RBXRegistryCheckOperation(BOOL mutation, NSError **error) {
    RBXOperationContext *context = [RBXOperationContext currentContext];
    if (context && ![context check:error]) return NO;
    if (mutation && !context) {
        if (error) *error = [NSError errorWithDomain:RBXOperationErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Profile mutation has no operation owner"}];
        return NO;
    }
    return !mutation || [RBXOperationContext checkSafetyFence:error];
}

@implementation RBXContainerRegistry

- (NSDictionary *)deletionIdentityForContainer:(NSString *)containerId error:(NSError **)error {
    if (!RBXDeletionID(containerId)) {
        if (error) *error = RBXDeletionError(@"Deletion identity requires a safe container ID"); return nil;
    }
    int directory = RBXOpenDeletionRoot(NO, error);
    if (directory < 0) return nil;
    NSDictionary *journal = nil;
    @try { journal = RBXReadDeletion(directory, containerId, error); }
    @finally { close(directory); }
    NSDictionary *descriptor = RBXAppDeletionJournalDescriptor(journal);
    return descriptor ? RBXAppDeletionTargetIdentity(descriptor, containerId) : nil;
}

- (NSDictionary *)deletionStateForContainer:(NSString *)containerId {
    NSError *error = nil;
    if (!RBXDeletionID(containerId)) return RBXDeletionSummary(containerId, nil,
        RBXDeletionError(@"Container ID is not a safe profile identifier"));
    int directory = RBXOpenDeletionRoot(NO, &error);
    NSDictionary *journal = directory != -1 ? RBXReadDeletion(directory, containerId, &error) : nil;
    if (directory >= 0) close(directory);
    if (journal || error) return RBXDeletionSummary(containerId, journal, error);
    NSDictionary *retired = [[RBXCentralStore sharedStore] dictionary][@"cloudRetiredContainers"];
    if ([retired isKindOfClass:NSDictionary.class] && retired[containerId]) {
        return @{@"containerId": containerId, @"phase": @"cloud-retired", @"completed": @NO,
            @"retryable": @YES, @"message": @"Cloud deleted this profile; local cleanup is pending", @"updatedAt": @0};
    }
    NSArray *legacy = RBXLegacyRetiredIDs(&error);
    if (error) return RBXDeletionSummary(containerId, nil, error);
    if ([legacy containsObject:containerId]) return RBXDeletionSummary(containerId, nil,
        RBXDeletionError(@"Previous deletion has no verified keychain cleanup receipt; retry Delete"));
    return nil;
}

- (NSArray<NSDictionary *> *)cloudDeletionRecordsWithError:(NSError **)error {
    int directory = RBXOpenDeletionRoot(NO, error);
    if (directory == -2) return @[];
    if (directory < 0) return nil;
    NSMutableArray *records = [NSMutableArray array];
    @try {
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:kDeletionRoot error:error];
        if (!files) return nil;
        for (NSString *file in files) {
            if (![file.pathExtension isEqual:@"plist"]) continue;
            NSString *identifier = file.stringByDeletingPathExtension;
            NSDictionary *journal = RBXReadDeletion(directory, identifier, error);
            if (!journal) return nil;
            id binding = journal[@"cloudBinding"];
            // Old unbound receipts still prohibit local reuse, but cannot
            // authorize a deletion in a possibly different paired account.
            if (!binding) continue;
            if (![binding isKindOfClass:NSDictionary.class] ||
                ![binding[@"serverURL"] isKindOfClass:NSString.class] || ![binding[@"serverURL"] length] ||
                ![binding[@"deviceId"] isKindOfClass:NSString.class] || ![binding[@"deviceId"] length] ||
                !RBXCanonicalProfileIdentifier(identifier)) {
                if (error) *error = RBXDeletionError(@"Cloud deletion binding is invalid; retained for recovery");
                return nil;
            }
            [records addObject:@{@"containerId": identifier, @"binding": binding}];
        }
        return records;
    } @finally { close(directory); }
}

- (BOOL)recordRemoteRetirementForContainer:(NSString *)identifier binding:(NSDictionary *)binding error:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error) || !RBXCanonicalProfileIdentifier(identifier)) return NO;
    NSArray *localIds = [self containerIdsWithError:error];
    if (!localIds) return NO;
    __block BOOL conflict = NO;
    BOOL written = [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        id raw = doc[@"cloudProfileBindings"], retiredRaw = doc[@"cloudRetiredContainers"];
        if ((raw && ![raw isKindOfClass:NSDictionary.class]) ||
            (retiredRaw && ![retiredRaw isKindOfClass:NSDictionary.class])) { conflict = YES; return; }
        NSDictionary *bindings = raw ?: @{};
        if ((bindings[identifier] && ![bindings[identifier] isEqual:binding]) ||
            (!bindings[identifier] && [localIds containsObject:identifier])) { conflict = YES; return; }
        for (NSString *local in localIds) if ([local.lowercaseString isEqual:identifier.lowercaseString] &&
            ![local isEqual:identifier]) { conflict = YES; return; }
        NSMutableDictionary *retired = retiredRaw ? [retiredRaw mutableCopy] : [NSMutableDictionary dictionary];
        if (retired[identifier] && ![retired[identifier] isEqual:binding]) { conflict = YES; return; }
        retired[identifier] = binding;
        doc[@"cloudRetiredContainers"] = retired;
    } error:error];
    if (conflict && error) *error = RBXDeletionError(@"Cloud retirement conflicts with an unbound or different-device local record; local data was preserved");
    if (!written || conflict) return NO;
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXNetworkGate.leasePath];
    if ([localIds containsObject:identifier] && (!lease || [lease[@"containerId"] isEqual:identifier])) {
        NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"active cloud profile retired" error:error];
        BOOL stopped = [[RBXAppProcessCoordinator new] killAllAndWait:8.0];
        if (!generation || !stopped || ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:1.0]) {
            if (error && !*error) *error = RBXDeletionError(@"Cloud profile retired; CLOSED/process termination needs recovery");
            return NO;
        }
    }
    return YES;
}

- (NSArray<NSDictionary *> *)pendingDeletionStates {
    NSError *error = nil;
    NSMutableSet *identifiers = [NSMutableSet set];
    NSArray *legacy = RBXLegacyRetiredIDs(&error);
    if (legacy) [identifiers addObjectsFromArray:legacy];
    NSDictionary *cloudRetired = [[RBXCentralStore sharedStore] dictionary][@"cloudRetiredContainers"];
    if ([cloudRetired isKindOfClass:NSDictionary.class]) {
        NSArray *local = [self containerIdsWithError:&error];
        for (NSString *identifier in local) if (cloudRetired[identifier]) [identifiers addObject:identifier];
    }
    NSError *directoryError = nil;
    int directory = RBXOpenDeletionRoot(NO, &directoryError);
    if (directory >= 0) {
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:kDeletionRoot error:&directoryError];
        for (NSString *file in files) {
            if ([file.pathExtension isEqual:@"plist"] && RBXDeletionID(file.stringByDeletingPathExtension))
                [identifiers addObject:file.stringByDeletingPathExtension];
        }
        close(directory);
    }
    NSMutableArray *states = [NSMutableArray array];
    for (NSString *identifier in [[identifiers allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *state = [self deletionStateForContainer:identifier];
        if (state && ![state[@"completed"] boolValue]) [states addObject:state];
    }
    if (error || directoryError) {
        NSMutableDictionary *failure = [RBXDeletionSummary(@"", nil, error ?: directoryError) mutableCopy];
        failure[@"globalError"] = @YES;
        [states addObject:failure];
    }
    return states;
}

- (BOOL)_allowsContainer:(NSString *)containerId error:(NSError **)error {
    if (!RBXRegistryCheckOperation(NO, error)) return NO;
    if (![RBXProfileIO isSafeContainerIdentifier:containerId]) {
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIOInvalidIdentifier
            userInfo:@{NSLocalizedDescriptionKey: @"Profile identifier is unsafe"}];
        return NO;
    }
    NSDictionary *state = [self deletionStateForContainer:containerId];
    if (!state) return YES;
    if (error) *error = RBXDeletionError([state[@"completed"] boolValue]
        ? @"This container ID is permanently retired; create a new container ID"
        : state[@"message"]);
    return NO;
}

- (BOOL)_writeProfile:(NSDictionary *)profile
             container:(NSString *)containerId
                 error:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error)) return NO;
    if (![self _allowsContainer:containerId error:error]) return NO;
    NSString *path = [[kProfilesDir stringByAppendingPathComponent:containerId]
                      stringByAppendingPathExtension:@"json"];
    return RBXRegistryCheckOperation(YES, error) &&
        [RBXProfileIO writeProfile:RBXProfileForTransport(profile) containerId:containerId toPath:path error:error];
}

- (void)migrateProfilesIfNeeded {
    NSError *error = nil;
    if (![self migrateProfilesWithError:&error]) NSLog(@"redditboxd: profile migration incomplete: %@", error.localizedDescription);
}

- (BOOL)migrateProfilesWithError:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error)) return NO;
    NSError *inventoryError = nil;
    NSArray *identifiers = [self containerIdsWithError:&inventoryError];
    if (!identifiers) { if (error) *error = inventoryError; return NO; }
    for (NSString *containerId in identifiers) {
        if (!RBXRegistryCheckOperation(YES, error)) return NO;
        if ([self deletionStateForContainer:containerId]) continue;
        if (![self _allowsContainer:containerId error:error]) return NO;
        NSError *loadError = nil;
        NSDictionary *profile = [self _load:containerId error:&loadError];
        if (!profile) {
            NSLog(@"redditboxd: PROFILE MIGRATION BLOCKED container=%@ reason=%@", containerId, loadError.localizedDescription);
            if (error) *error = loadError;
            return NO;
        }

        NSDictionary *redacted = [RBXRotationSecrets migrateLegacyProfile:profile error:&loadError];
        if (!redacted) { if (error) *error = loadError; return NO; }
        if (![redacted isEqual:profile]) {
            if (![self _writeProfile:redacted container:containerId error:error]) return NO;
            profile = redacted;
        }

        NSMutableDictionary *updated = [profile mutableCopy];
        NSMutableDictionary *device = [profile[@"device"] mutableCopy] ?:
            [NSMutableDictionary dictionary];
        NSMutableDictionary *serials = [profile[@"serials"] mutableCopy] ?:
            [NSMutableDictionary dictionary];
        NSMutableDictionary *reddit = [profile[@"reddit"] mutableCopy] ?:
            [NSMutableDictionary dictionary];
        NSMutableDictionary *security = [profile[@"security"] mutableCopy] ?:
            [NSMutableDictionary dictionary];
        NSMutableDictionary *timing = [profile[@"timing"] mutableCopy] ?:
            [NSMutableDictionary dictionary];
        NSDictionary *identityCustomization =
            [profile[@"identityCustomization"] isKindOfClass:[NSDictionary class]]
                ? profile[@"identityCustomization"] : @{
                    @"mode": @"random",
                    @"updatedAt": @(NSDate.date.timeIntervalSince1970),
                };
        if (![security[@"appAttest"] length]) security[@"appAttest"] = @"blocked";
        if (![security[@"deviceCheck"] length]) security[@"deviceCheck"] = @"blocked";
        if (![security[@"localNetworking"] length]) security[@"localNetworking"] = @"blocked";
        if (![security[@"sensorAccess"] length]) security[@"sensorAccess"] = @"blocked";
        if (![security[@"networkMetadata"] length]) security[@"networkMetadata"] = @"blocked";
        if (![security[@"thirdPartyNetwork"] length]) security[@"thirdPartyNetwork"] = @"blocked";
        if (![security[@"strictTiming"] length]) security[@"strictTiming"] = @"enabled";
        if (![security[@"systemClipboard"] length]) security[@"systemClipboard"] = @"blocked";
        if (![timing[@"syntheticBootEpoch"] length]) {
            NSTimeInterval uptime = MAX(3600.0,
                [timing[@"bootTimeOffsetSeconds"] doubleValue]);
            timing[@"syntheticBootEpoch"] = [NSString stringWithFormat:@"%.0f",
                NSDate.date.timeIntervalSince1970 - uptime];
        }
        NSString *country = RBXRegistryValue(profile, @"proxy.country") ?: @"US";
        if (![device[@"regionCode"] length]) device[@"regionCode"] = country;
        if (![device[@"deviceClass"] length]) device[@"deviceClass"] = @"iPhone";
        if (![device[@"simStatus"] length])
            device[@"simStatus"] = @"kCTSIMSupportSIMStatusReady";
        NSDictionary *model = [RBXDeviceCatalog modelForProductType:device[@"productType"]];
        if (![device[@"gpuName"] length] && [model[@"chip"] length]) {
            device[@"gpuName"] = [NSString stringWithFormat:@"Apple %@ GPU", model[@"chip"]];
        }
        // Never rewrite a persisted identity from the host OS during migration.
        if (!serials[@"uniqueChipId"]) {
            serials[@"uniqueChipId"] =
                @(((unsigned long long)arc4random() << 32) | arc4random());
        }
        updated[@"device"] = device;
        updated[@"serials"] = serials;
        if ([device[@"screen"][@"w"] length]) reddit[@"screenWidth"] = device[@"screen"][@"w"];
        if ([device[@"screen"][@"h"] length]) reddit[@"screenHeight"] = device[@"screen"][@"h"];
        updated[@"reddit"] = reddit;
        updated[@"security"] = security;
        updated[@"timing"] = timing;
        updated[@"identityCustomization"] = identityCustomization;

        NSDictionary *rebuilt = RBXBuildMGOverrides(updated);
        NSDictionary *current = [profile[@"mgOverrides"] isKindOfClass:[NSDictionary class]]
            ? profile[@"mgOverrides"] : @{};
        BOOL profileFieldsChanged =
            ![profile[@"device"] isEqual:device] ||
            ![profile[@"serials"] isEqual:serials] ||
            ![profile[@"reddit"] isEqual:reddit] ||
            ![profile[@"security"] isEqual:security] ||
            ![profile[@"timing"] isEqual:timing] ||
            ![profile[@"identityCustomization"] isEqual:identityCustomization];
        if (![self reserveIdentityForProfile:profile error:&loadError] ||
            ![self reserveIdentityForProfile:updated error:&loadError]) {
            if (error) *error = loadError; return NO;
        }
        if (!profileFieldsChanged && [current isEqualToDictionary:rebuilt]) continue;

        updated[@"mgOverrides"] = rebuilt;
        if ([self _writeProfile:updated container:containerId error:&loadError]) {
            NSLog(@"redditboxd: migrated MobileGestalt overrides for %@ (%lu keys)",
                  containerId, (unsigned long)rebuilt.count);
        } else {
            NSLog(@"redditboxd: PROFILE MIGRATION WRITE FAILED container=%@ reason=%@", containerId, loadError.localizedDescription);
            if (error) *error = loadError;
            return NO;
        }
    }
    return YES;
}

- (void)migrateAppClonesIfNeeded {
    NSError *error = nil;
    if (![self migrateAppClonesWithError:&error]) NSLog(@"redditboxd: clone migration incomplete: %@", error.localizedDescription);
}

- (BOOL)migrateAppClonesWithError:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error)) return NO;
    // A pending deletion must not trigger an install rollback that restores it.
    // Explicit deletion reports unresolved install recovery without erasing it.
    if (!self.pendingDeletionStates.count && ![RBXCloneManager
        recoverAllInterruptedTransactionsWithContext:[RBXOperationContext currentContext] error:error]) return NO;
    NSError *inventoryError = nil;
    NSArray *identifiers = [self containerIdsWithError:&inventoryError];
    if (!identifiers) { if (error) *error = inventoryError; return NO; }
    for (NSString *containerId in identifiers) {
        if (!RBXRegistryCheckOperation(YES, error)) return NO;
        if ([self deletionStateForContainer:containerId]) continue;
        if (![self ensureAppCloneForContainer:containerId error:error]) {
            NSLog(@"redditboxd: CLONE MIGRATION BLOCKED container=%@ reason=%@",
                  containerId, error ? (*error).localizedDescription : @"unknown");
            return NO;
        }
    }
    return YES;
}

- (NSArray<NSString *> *)containerIds {
    return [self containerIdsWithError:nil] ?: @[];
}

- (NSArray<NSString *> *)containerIdsWithError:(NSError **)error {
    int directory = open(kProfilesDir.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory < 0) {
        int saved = errno;
        if (saved == ENOENT) return @[];
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIORead
            userInfo:@{NSLocalizedDescriptionKey: @"Profile inventory cannot be opened safely",
                NSUnderlyingErrorKey: [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil]}];
        return nil;
    }
    DIR *stream = fdopendir(directory);
    if (!stream) {
        close(directory);
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIORead
            userInfo:@{NSLocalizedDescriptionKey: @"Profile inventory cannot be enumerated"}];
        return nil;
    }
    NSMutableArray *ids = [NSMutableArray array];
    int readError = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(stream);
        if (!entry) { readError = errno; break; }
        NSString *file = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if ([file hasSuffix:@".json"]) [ids addObject:file.stringByDeletingPathExtension];
    }
    closedir(stream);
    if (readError) {
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIORead
            userInfo:@{NSLocalizedDescriptionKey: @"Profile inventory enumeration failed",
                NSUnderlyingErrorKey: [NSError errorWithDomain:NSPOSIXErrorDomain code:readError userInfo:nil]}];
        return nil;
    }
    return [ids sortedArrayUsingSelector:@selector(compare:)];
}

- (NSDictionary *)_load:(NSString *)containerId error:(NSError **)error {
    return [RBXProfileIO loadProfileForContainer:containerId error:error];
}

- (NSArray<NSDictionary *> *)_otherProfilesExcluding:(NSString *)containerId error:(NSError **)error {
    NSArray *identifiers = [self containerIdsWithError:error];
    if (!identifiers) return nil;
    NSMutableArray *profiles = [NSMutableArray array];
    for (NSString *otherId in identifiers) {
        if (!RBXRegistryCheckOperation(NO, error)) return nil;
        if ([otherId isEqualToString:containerId]) continue;
        // A malformed filename cannot silently disappear from uniqueness checks.
        if (![RBXProfileIO isSafeContainerIdentifier:otherId]) {
            [RBXProfileIO loadProfileForContainer:otherId error:error];
            return nil;
        }
        if ([self deletionStateForContainer:otherId]) continue;
        NSDictionary *other = [self _load:otherId error:error];
        if (!other) return nil;
        [profiles addObject:other];
    }
    return profiles;
}

- (BOOL)_checkIdentityChoices:(NSDictionary *)choices error:(NSError **)error {
    BOOL valid = [choices isKindOfClass:NSDictionary.class];
    if (valid && choices[@"deviceName"]) {
        id name = choices[@"deviceName"];
        if (![name isKindOfClass:NSString.class] || [name length] > 64 ||
            ![[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) {
            if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIOSection
                userInfo:@{NSLocalizedDescriptionKey:@"Device name must contain 1–64 characters and cannot be blank"}];
            return NO;
        }
    }
    if (valid) for (NSString *key in @[@"mode", @"idfaPosture"]) {
        if (choices[key] && ![choices[key] isKindOfClass:NSString.class]) valid = NO;
    }
    if (valid && choices[@"securityOnly"] && ![choices[@"securityOnly"] isKindOfClass:NSNumber.class]) valid = NO;
    if (valid && ![choices[@"securityOnly"] boolValue] && ![choices[@"mode"] isEqual:@"random"]) {
        NSString *additionalError = RBXAdditionalIdentityInputError(choices);
        if (additionalError) {
            if (error) *error = RBXDeletionError(additionalError);
            return NO;
        }
        // Omission retains the saved value for legacy partial requests. An
        // explicit blank manual control must not silently retain that value.
        // Random and security-only requests do not consume these controls.
        for (NSString *key in @[@"serialNumber", @"udid", @"wifiMac", @"btMac", @"platformUUID",
                                 @"idfv", @"installId", @"externalInstallationId", @"idfa"]) {
            id value = choices[key];
            if (!value) continue;
            BOOL derivedZero = [key isEqual:@"idfa"] && [choices[@"idfaPosture"] isEqual:@"zeroWithATTDenied"];
            if (![value isKindOfClass:NSString.class] ||
                (!derivedZero && ![[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length])) {
                if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIOSection
                    userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:
                        @"Manual identifier %@ cannot be blank or have an invalid type", key]}];
                return NO;
            }
        }
    }
    if (valid && choices[@"batteryOffsetPercent"] &&
        ![choices[@"batteryOffsetPercent"] isKindOfClass:NSString.class] &&
        ![choices[@"batteryOffsetPercent"] isKindOfClass:NSNumber.class]) valid = NO;
    if (valid && choices[@"batteryOffsetPercent"]) {
        id raw = choices[@"batteryOffsetPercent"];
        NSString *number = [raw isKindOfClass:NSNumber.class] ? [raw stringValue] : raw;
        number = [number stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        // integerValue accepts arbitrary suffixes and turns empty/nonnumeric
        // input into zero. Reject those edits before building a candidate.
        if ([number rangeOfString:@"^[+-]?[0-9]+$" options:NSRegularExpressionSearch].location == NSNotFound ||
            number.doubleValue < -8 || number.doubleValue > 8) {
            if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIOSection
                userInfo:@{NSLocalizedDescriptionKey:@"Battery offset must be a whole number between -8 and +8"}];
            return NO;
        }
    }
    if (valid && choices[@"security"] && ![choices[@"security"] isKindOfClass:NSDictionary.class]) valid = NO;
    if (!valid && error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIOSection
        userInfo:@{NSLocalizedDescriptionKey: @"Identity choices contain invalid field types"}];
    return valid;
}

- (NSDictionary *)validatedProfileForContainer:(NSString *)containerId error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return nil;
    NSDictionary *profile = [self _load:containerId error:error];
    if (!profile) return nil;
    return [self _validatedCandidate:profile container:containerId error:error];
}

- (NSDictionary *)validatedImportedProfile:(NSDictionary *)profile error:(NSError **)error {
    NSString *identifier = [profile isKindOfClass:NSDictionary.class] ? profile[@"containerId"] : nil;
    if (!RBXRegistryCheckOperation(YES, error) || ![self _allowsContainer:identifier error:error]) return nil;
    NSArray *identifiers = [self containerIdsWithError:error];
    if (!identifiers) return nil;
    for (NSString *existing in identifiers) if ([existing.lowercaseString isEqual:identifier.lowercaseString]) {
        if (error) *error = RBXDeletionError(@"Restore would replace an existing local profile; choose a new destination"); return nil;
    }
    return [self _validatedCandidate:profile container:identifier error:error];
}

- (NSDictionary *)_validatedCandidate:(NSDictionary *)profile container:(NSString *)containerId error:(NSError **)error {
    NSDictionary *validated = [RBXConsistencyValidator validatedProfile:profile error:error];
    if (!validated) return nil;

    NSDictionary *reservations = RBXCheckedIdentityReservations(error);
    if (!reservations) return nil;
    NSDictionary *hashes = RBXIdentityHashes(validated);
    for (NSString *hash in hashes) if (reservations[hash] && ![reservations[hash] isEqual:containerId]) {
        if (error) *error = RBXDeletionError([NSString stringWithFormat:
            @"%@ was already reserved by another profile; choose fresh identifiers", hashes[hash]]);
        return nil;
    }

    NSArray *uniquePaths = @[@"serials.udid", @"serials.serialNumber",
                             @"serials.imei1", @"serials.wifiMac",
                             @"serials.btMac", @"serials.platformUUID",
                             @"ids.idfa", @"ids.idfv", @"reddit.installId",
                             @"reddit.externalInstallationId"];
    NSArray *others = [self _otherProfilesExcluding:containerId error:error];
    if (!others) return nil;
    for (NSDictionary *other in others) {
        NSString *otherId = other[@"containerId"];
        for (NSString *path in uniquePaths) {
            NSString *value = RBXRegistryValue(validated, path);
            if ([path isEqualToString:@"ids.idfa"] &&
                [value isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
                continue;
            }
            if (value.length && [value isEqualToString:RBXRegistryValue(other, path)]) {
                if (error) {
                    *error = [NSError errorWithDomain:@"com.redditbox" code:409
                                             userInfo:@{NSLocalizedDescriptionKey:
                         [NSString stringWithFormat:@"%@ duplicates %@ from profile %@",
                          path, value, otherId]}];
                }
                return nil;
            }
        }
    }
    return validated;
}

- (BOOL)reserveIdentityForProfile:(NSDictionary *)profile error:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error)) return NO;
    NSString *identifier = profile[@"containerId"];
    if (!RBXCanonicalProfileIdentifier(identifier)) {
        if (error) *error = RBXDeletionError(@"Identity reservation has an invalid profile ID"); return NO;
    }
    NSDictionary *hashes = RBXIdentityHashes(profile);
    __block NSString *failure = nil;
    BOOL saved = [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        if (!RBXIdentityReservationsValid(doc[@"identityReservations"])) {
            failure = @"Identity reservation history is corrupt; no identifier was released"; return;
        }
        NSMutableDictionary *reservations = [doc[@"identityReservations"] mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *hash in hashes) if (reservations[hash] && ![reservations[hash] isEqual:identifier]) {
            failure = @"An identifier is already reserved by another profile"; return;
        }
        for (NSString *hash in hashes) reservations[hash] = identifier;
        doc[@"identityReservations"] = reservations;
    } error:error];
    if (failure && error) *error = RBXDeletionError(failure);
    return saved && !failure;
}

- (NSArray<NSString *> *)warningsForContainer:(NSString *)containerId {
    NSDictionary *deletion = [self deletionStateForContainer:containerId];
    if (deletion) return @[deletion[@"message"]];
    NSError *error = nil;
    NSDictionary *profile = [self _load:containerId error:&error];
    if (!profile) return @[error.localizedDescription ?: @"Profile cannot be checked"];
    return [RBXConsistencyValidator warningsForProfile:profile];
}

- (BOOL)ensureAppCloneForContainer:(NSString *)containerId error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return NO;
    NSDictionary *profile = [self _load:containerId error:error];
    if (!profile) return NO;
    NSString *nickname = [[RBXCentralStore sharedStore] dictionary]
        [@"containers"][containerId][@"nickname"];
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!descriptor) {
        if (error) *error = RBXDeletionError(@"Profile app type is unknown; clone ownership cannot be established.");
        return NO;
    }
    RBXCloneManager *clones = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
        operationContext:RBXOperationContext.currentContext];
    NSDictionary *app = [clones ensureCloneForContainer:containerId
        profile:profile nickname:nickname error:error];
    if (!app) return NO;
    NSMutableDictionary *updated = [profile mutableCopy];
    updated[@"app"] = app;
    if (![self _writeProfile:updated container:containerId error:error]) {
        // ensureClone may have reused a working installation. A failed profile
        // publication never authorizes uninstalling it outside its transaction.
        // The previous profile and installed clone remain available for retry.
        return NO;
    }
    // LaunchServices may allocate the data container asynchronously. The signed
    // bootstrap profile remains available in the app bundle for its first launch.
    NSError *syncError = nil;
    if (![clones syncProfile:updated error:&syncError]) {
        NSLog(@"redditboxd: clone %@ awaits first OS data-container allocation",
              app[@"bundleIdentifier"]);
    }
    return YES;
}

- (BOOL)syncProfileToCloneForContainer:(NSString *)containerId error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return NO;
    NSDictionary *profile = [self _load:containerId error:error];
    if (!profile) return NO;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!descriptor) {
        if (error) *error = RBXDeletionError(@"Profile app type is unknown; clone ownership cannot be established.");
        return NO;
    }
    RBXCloneManager *clones = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
        operationContext:RBXOperationContext.currentContext];
    if (![clones validateCloneForProfile:profile error:error]) return NO;
    return [clones syncProfile:profile error:error];
}

- (NSDictionary *)_validatedIdentityCandidate:(NSDictionary *)candidate
                                     excluding:(NSString *)containerId
                                         error:(NSError **)error {
    NSDictionary *validated =
        [RBXConsistencyValidator validatedProfile:candidate error:error];
    if (!validated) return nil;
    NSArray *uniquePaths = @[@"serials.udid", @"serials.serialNumber",
        @"serials.imei1", @"serials.wifiMac", @"serials.btMac",
        @"serials.platformUUID", @"ids.idfa", @"ids.idfv",
        @"reddit.installId", @"reddit.externalInstallationId"];
    NSArray *others = [self _otherProfilesExcluding:containerId error:error];
    if (!others) return nil;
    for (NSDictionary *other in others) {
        for (NSString *path in uniquePaths) {
            NSString *value = RBXRegistryValue(validated, path);
            if ([path isEqualToString:@"ids.idfa"] &&
                [value isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
                continue;
            }
            if (value.length && [value isEqualToString:RBXRegistryValue(other, path)]) {
                if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                    code:409 userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:
                            @"%@ duplicates another container", path]}];
                return nil;
            }
        }
    }
    return validated;
}

- (NSDictionary *)_identityCandidateForContainer:(NSString *)containerId
                                          choices:(NSDictionary *)choices
                                            error:(NSError **)error {
    NSDictionary *original = [self _load:containerId error:error];
    return original ? [self _identityCandidateForProfile:original choices:choices error:error] : nil;
}

// Shared construction has no saved-profile or publication dependency. Both the
// existing editor and an uncommitted creation draft use the same validation.
- (NSDictionary *)_identityCandidateForProfile:(NSDictionary *)original
                                      choices:(NSDictionary *)choices error:(NSError **)error {
    NSString *containerId = original[@"containerId"];
    NSDictionary *descriptor = RBXAppDescriptorForProfile(original);
    if (!descriptor) {
        if (error) *error = RBXDeletionError(@"Profile app type is unknown; identity ownership cannot be changed.");
        return nil;
    }
    if (![self _checkIdentityChoices:choices error:error]) return nil;
    if (choices[@"appType"] && ![choices[@"appType"] isEqual:descriptor[@"appType"]]) {
        if (error) *error = RBXDeletionError(@"Identity editing cannot change a profile's app type.");
        return nil;
    }
    NSString *mode = [choices[@"mode"] isEqualToString:@"random"]
        ? @"random" : @"manual";
    BOOL securityOnly = [choices[@"securityOnly"] boolValue];
    NSString *proxyCountry = [RBXRegistryValue(original, @"proxy.country")
        uppercaseString] ?: [RBXRegistryValue(original, @"validation.proxyCountry")
        uppercaseString];
    NSString *requestedCountry = [choices[@"country"] isKindOfClass:[NSString class]]
        ? choices[@"country"] : proxyCountry;
    NSString *country = requestedCountry.uppercaseString;
    if (country.length != 2) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
            code:400 userInfo:@{NSLocalizedDescriptionKey:
                @"Country must be a two-letter code"}];
        return nil;
    }
    BOOL assignedProxy = [RBXRegistryValue(original, @"proxy.url") length] > 0;
    if (assignedProxy && proxyCountry.length && ![country isEqualToString:proxyCountry]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
            code:422 userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"Proxy country is %@, but the identity requests %@. Change the proxy assignment first or use %@.",
                    proxyCountry, country, proxyCountry]}];
        return nil;
    }
    NSString *observedCountry =
        RBXRegistryValue(original, @"validation.observedProxyCountry");
    if ([original[@"validation"][@"checkedAt"] doubleValue] > 0 &&
        ![original[@"validation"][@"geoConsistent"] boolValue] &&
        observedCountry.length) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
            code:422 userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"The last live proxy exit was %@ but this container requires %@. Fix/rotate the proxy and successfully retry opening before changing identity.",
                    observedCountry, proxyCountry]}];
        return nil;
    }

    NSMutableDictionary *candidate = nil;
    if (securityOnly) {
        candidate = [original mutableCopy];
    } else if ([mode isEqualToString:@"random"]) {
        NSArray *existing = [self _otherProfilesExcluding:containerId error:error];
        if (!existing) return nil;
        NSDictionary *generated = [RBXProfileGenerator
            generateProfileForContainerId:containerId appType:descriptor[@"appType"] proxyCountry:country
            existingProfiles:existing productType:choices[@"productType"]
            iosVersion:choices[@"iosVersion"] error:error];
        if (!generated) return nil;
        // Randomizing an identity does not replace the container document.
        // Keep operator metadata, ownership and policies outside this editor.
        candidate = [original mutableCopy];
        for (NSString *key in @[@"identityPolicy", @"device", @"serials", @"ids",
                                 @"timing", @"reddit"]) candidate[key] = generated[key];
        NSMutableDictionary *policies = [generated[@"security"] mutableCopy];
        [policies addEntriesFromDictionary:original[@"security"] ?: @{}];
        candidate[@"security"] = policies;
    } else {
        candidate = [original mutableCopy];
        NSMutableDictionary *device = [original[@"device"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        NSString *productType = [choices[@"productType"] isKindOfClass:[NSString class]]
            && [choices[@"productType"] length] ? choices[@"productType"]
            : device[@"productType"];
        NSString *iosVersion = [choices[@"iosVersion"] isKindOfClass:[NSString class]]
            && [choices[@"iosVersion"] length] ? choices[@"iosVersion"]
            : device[@"iosVersion"];
        NSDictionary *model = [RBXDeviceCatalog modelForProductType:productType];
        if (!model) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    @"Unknown device type"}];
            return nil;
        }
        if (![model[@"iosVersions"] containsObject:iosVersion]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    @"Selected iOS version is not supported by the synthetic model"}];
            return nil;
        }
        device[@"productType"] = productType;
        device[@"marketingName"] = model[@"marketingName"] ?: @"iPhone";
        device[@"modelNumber"] = [model[@"modelBase"] length] ?
            [model[@"modelBase"] stringByAppendingString:[RBXDeviceCatalog regionSuffixForCountry:country] ?: @"LL/A"] : @"";
        device[@"hwModelStr"] = model[@"hwModelStr"] ?: @"";
        device[@"regulatoryModel"] = model[@"regulatoryModel"] ?: @"";
        device[@"ramBytes"] = model[@"ramBytes"] ?: @"";
        device[@"gpuName"] = [NSString stringWithFormat:@"Apple %@ GPU",
            model[@"chip"] ?: @"GPU"];
        device[@"screen"] = model[@"screen"] ?: @{};
        device[@"iosVersion"] = iosVersion;
        device[@"buildVersion"] = [RBXDeviceCatalog buildForIOS:iosVersion] ?: @"";
        device[@"darwinRelease"] = [RBXDeviceCatalog darwinForIOS:iosVersion] ?: @"";
        device[@"regionCode"] = country;

        NSString *locale = [choices[@"locale"] isKindOfClass:[NSString class]]
            && [choices[@"locale"] length] ? choices[@"locale"]
            : [RBXDeviceCatalog localeForCountry:country];
        NSString *timezone = [choices[@"timezone"] isKindOfClass:[NSString class]]
            && [choices[@"timezone"] length] ? choices[@"timezone"]
            : [RBXDeviceCatalog timezoneForCountry:country];
        if (![[RBXDeviceCatalog countryForLocale:locale] isEqualToString:country]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    @"Locale does not belong to the selected/proxy country"}];
            return nil;
        }
        if (![[RBXDeviceCatalog countryForTimezone:timezone] isEqualToString:country]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    @"Timezone does not belong to the selected/proxy country"}];
            return nil;
        }
        device[@"locale"] = locale ?: @"";
        device[@"language"] = [locale componentsSeparatedByString:@"_"].firstObject ?: @"";
        device[@"timezone"] = timezone ?: @"";

        NSArray *carriers = [RBXDeviceCatalog carriersForCountry:country];
        NSString *carrierCode = [choices[@"carrierCode"] isKindOfClass:[NSString class]]
            ? choices[@"carrierCode"] : @"";
        NSDictionary *carrier = nil;
        for (NSDictionary *item in carriers) {
            NSString *code = [NSString stringWithFormat:@"%@-%@",
                item[@"mcc"] ?: @"", item[@"mnc"] ?: @""];
            if (!carrierCode.length || [code isEqualToString:carrierCode]) {
                carrier = item;
                if (carrierCode.length) break;
            }
        }
        if (carrierCode.length && !carrier) {
            NSMutableArray *available = [NSMutableArray array];
            for (NSDictionary *item in carriers) {
                [available addObject:[NSString stringWithFormat:@"%@-%@",
                    item[@"mcc"] ?: @"", item[@"mnc"] ?: @""]];
            }
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Carrier is not valid for %@. Available: %@",
                        country, [available componentsJoinedByString:@", "]]}];
            return nil;
        }
        if (!carrier && carriers.count) carrier = carriers.firstObject;
        device[@"carrier"] = carrier ?: @{};

        NSArray *cities = [RBXDeviceCatalog citiesForCountry:country];
        NSString *cityName = [choices[@"city"] isKindOfClass:[NSString class]]
            ? choices[@"city"] : @"";
        NSDictionary *city = nil;
        for (NSDictionary *item in cities) {
            if (!cityName.length || [item[@"city"] isEqualToString:cityName]) {
                city = item;
                if (cityName.length) break;
            }
        }
        if (cityName.length && !city) {
            NSArray *available = [cities valueForKey:@"city"];
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"City is not valid for %@. Available: %@",
                        country, [available componentsJoinedByString:@", "]]}];
            return nil;
        }
        if (!city && cities.count) city = cities.firstObject;
        if (city && ![city[@"timezone"] isEqual:timezone]) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity" code:422
                userInfo:@{NSLocalizedDescriptionKey:@"City and timezone do not match. Choose the city again or use Set from proxy."}];
            return nil;
        }
        BOOL sameLocation = [RBXRegistryValue(original, @"device.regionCode") isEqual:country] &&
            [RBXRegistryValue(original, @"device.timezone") isEqual:timezone] &&
            [RBXRegistryValue(original, @"device.location.city") isEqual:city[@"city"]] &&
            [RBXRegistryValue(original, @"device.location.lat") length] &&
            [RBXRegistryValue(original, @"device.location.lon") length];
        // Checking or editing an unrelated field must not move an unchanged
        // location. New city selections still receive fresh bounded jitter.
        if (city && !sameLocation) {
            double latJitter = ((NSInteger)arc4random_uniform(6001) - 3000) / 100000.0;
            double lonJitter = ((NSInteger)arc4random_uniform(6001) - 3000) / 100000.0;
            device[@"location"] = @{
                @"city": city[@"city"] ?: @"",
                @"lat": [NSString stringWithFormat:@"%.5f",
                    [city[@"lat"] doubleValue] + latJitter],
                @"lon": [NSString stringWithFormat:@"%.5f",
                    [city[@"lon"] doubleValue] + lonJitter],
            };
        }
        if ([choices[@"deviceName"] isKindOfClass:[NSString class]] &&
            [choices[@"deviceName"] length] <= 64 && [choices[@"deviceName"] length]) {
            device[@"deviceName"] = choices[@"deviceName"];
        }
        candidate[@"device"] = device;

        NSMutableDictionary *serials = [original[@"serials"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        NSDictionary *serialChoiceMap = @{
            @"serialNumber": @"serialNumber",
            @"udid": @"udid",
            @"imei1": @"imei1",
            @"wifiMac": @"wifiMac",
            @"btMac": @"btMac",
            @"platformUUID": @"platformUUID",
        };
        [serialChoiceMap enumerateKeysAndObjectsUsingBlock:
            ^(NSString *choiceKey, NSString *profileKey, BOOL *stop) {
                NSString *value = [choices[choiceKey] isKindOfClass:[NSString class]]
                    ? [choices[choiceKey] stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
                if (value.length) serials[profileKey] = value.uppercaseString;
                else if ([choiceKey isEqual:@"imei1"] && [choices[choiceKey] isEqual:@""] &&
                    [model[@"identifierTemplate"] isEqual:@"generic-synthetic"]) serials[profileKey] = @"";
            }];
        candidate[@"serials"] = serials;

        NSMutableDictionary *ids = [original[@"ids"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        NSString *posture = [choices[@"idfaPosture"] isEqualToString:
            @"zeroWithATTDenied"] ? @"zeroWithATTDenied" : @"random";
        ids[@"posture"] = posture;
        if ([posture isEqualToString:@"zeroWithATTDenied"]) {
            ids[@"idfa"] = @"00000000-0000-0000-0000-000000000000";
        } else {
            NSString *manualIDFA = [choices[@"idfa"] isKindOfClass:[NSString class]]
                ? [choices[@"idfa"] stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
            if (manualIDFA.length) ids[@"idfa"] = manualIDFA.uppercaseString;
            else if ([ids[@"idfa"] isEqualToString:
                      @"00000000-0000-0000-0000-000000000000"]) {
                ids[@"idfa"] = NSUUID.UUID.UUIDString.uppercaseString;
            }
        }
        NSString *manualIDFV = [choices[@"idfv"] isKindOfClass:[NSString class]]
            ? [choices[@"idfv"] stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
        if (manualIDFV.length) ids[@"idfv"] = manualIDFV.uppercaseString;
        candidate[@"ids"] = ids;

        NSMutableDictionary *reddit = [original[@"reddit"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        // An opaque legacy override cannot be safely rewritten for a new UA
        // tuple. Let the existing runtime builder use the selected identity
        // and installed app version/build; unrelated edits retain the override.
        if ([descriptor[@"appType"] isEqual:@"reddit"]) {
            for (NSString *path in @[@"device.productType", @"device.iosVersion", @"device.screen.scale"]) {
                if (![RBXRegistryValue(original, path) isEqualToString:RBXRegistryValue(candidate, path)]) {
                    [reddit removeObjectForKey:@"userAgent"];
                    break;
                }
            }
        }
        reddit[@"deviceName"] = [NSString stringWithFormat:@"Apple;%@", productType];
        reddit[@"screenWidth"] = model[@"screen"][@"w"] ?: @"";
        reddit[@"screenHeight"] = model[@"screen"][@"h"] ?: @"";
        NSString *fontSize = [choices[@"fontSize"] isKindOfClass:[NSString class]]
            ? choices[@"fontSize"] : reddit[@"fontSize"];
        if (![@[@"16", @"17", @"19"] containsObject:fontSize]) fontSize = @"17";
        reddit[@"fontSize"] = fontSize;
        for (NSString *key in @[@"installId", @"externalInstallationId"]) {
            NSString *value = [choices[key] isKindOfClass:[NSString class]]
                ? [choices[key] stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
            if (value.length) reddit[key] = value.uppercaseString;
        }
        candidate[@"reddit"] = reddit;

        NSMutableDictionary *timing = [original[@"timing"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        NSInteger battery = [choices[@"batteryOffsetPercent"] integerValue];
        if (battery < -8 || battery > 8) {
            if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
                code:422 userInfo:@{NSLocalizedDescriptionKey:
                    @"Battery offset must be between -8 and +8"}];
            return nil;
        }
        timing[@"batteryOffsetPercent"] =
            [NSString stringWithFormat:@"%ld", (long)battery];
        candidate[@"timing"] = timing;
        if (choices[@"latitude"]) {
            // Editor coordinates must describe its selected catalog city. A
            // country label alone is insufficient evidence of a coherent fix.
            if (!city || fabs([choices[@"latitude"] doubleValue] - [city[@"lat"] doubleValue]) > 0.031 ||
                fabs([choices[@"longitude"] doubleValue] - [city[@"lon"] doubleValue]) > 0.031) {
                if (error) *error = RBXDeletionError(@"Coordinates do not match the selected city. Choose the city again or fill automatically.");
                return nil;
            }
        }
        RBXApplyAdditionalIdentityFields(candidate, choices);
    }

    NSMutableDictionary *security = [candidate[@"security"] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    NSDictionary *securityChoices = [choices[@"security"] isKindOfClass:[NSDictionary class]]
        ? choices[@"security"] : @{};
    for (NSString *key in @[@"appAttest", @"deviceCheck", @"localNetworking",
                             @"sensorAccess", @"networkMetadata",
                             @"thirdPartyNetwork", @"strictTiming", @"systemClipboard"]) {
        if ([securityChoices[key] isKindOfClass:[NSNumber class]]) {
            security[key] = [securityChoices[key] boolValue] ? @"enabled" : @"blocked";
        }
    }
    candidate[@"security"] = security;
    if (!securityOnly) {
        if (!assignedProxy) {
            // This is the requested region for an unassigned container. The
            // cloud still owns its eventual proxy URL and launch authorization.
            NSMutableDictionary *proxy = [candidate[@"proxy"] mutableCopy] ?: [NSMutableDictionary dictionary];
            proxy[@"country"] = country;
            candidate[@"proxy"] = proxy;
            NSMutableDictionary *validation = [candidate[@"validation"] mutableCopy] ?: [NSMutableDictionary dictionary];
            validation[@"proxyCountry"] = country;
            candidate[@"validation"] = validation;
        }
        candidate[@"identityCustomization"] = @{
            @"mode": mode,
            @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        };
    }
    candidate[@"mgOverrides"] = RBXBuildMGOverrides(candidate);
    return [self _validatedIdentityCandidate:candidate
                                    excluding:containerId error:error];
}

- (NSDictionary *)identityEditorStateForContainer:(NSString *)containerId
                                             error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return nil;
    NSDictionary *profile = [self _load:containerId error:error];
    if (!profile) return nil;
    NSDictionary *device = profile[@"device"] ?: @{};
    NSDictionary *carrier = device[@"carrier"] ?: @{};
    NSDictionary *store = [[RBXCentralStore sharedStore] dictionaryWithError:error];
    if (!store) return nil;
    NSDictionary *stored = store[@"containers"][containerId];
    BOOL locked = RBXIdentityEntryIsFrozen(stored);
    return @{
        @"containerId": containerId,
        @"mode": profile[@"identityCustomization"][@"mode"] ?: @"coherent",
        @"locked": @(locked),
        @"proxyAssigned": @([RBXRegistryValue(profile, @"proxy.url") length] > 0),
        @"lockReason": locked
            ? @"Identity is frozen after first use. Create a new container to avoid fingerprint drift."
            : @"",
        @"productType": device[@"productType"] ?: @"",
        @"marketingName": device[@"marketingName"] ?: @"",
        @"iosVersion": device[@"iosVersion"] ?: @"",
        @"country": device[@"regionCode"] ?: @"",
        @"proxyCountry": RBXRegistryValue(profile, @"proxy.country")
            ?: RBXRegistryValue(profile, @"validation.proxyCountry") ?: @"",
        @"observedProxyCountry":
            RBXRegistryValue(profile, @"validation.observedProxyCountry") ?: @"",
        @"proxyCountrySource":
            ([profile[@"validation"][@"checkedAt"] doubleValue] > 0 &&
             [RBXRegistryValue(profile, @"validation.observedProxyCountry") length])
                ? @"observed" : @"configured",
        @"proxyMismatch": @(
            [RBXRegistryValue(profile, @"validation.observedProxyCountry") length] &&
            ![RBXRegistryValue(profile, @"validation.observedProxyCountry")
                isEqualToString:RBXRegistryValue(profile, @"proxy.country")]),
        @"locale": device[@"locale"] ?: @"",
        @"timezone": device[@"timezone"] ?: @"",
        @"carrierCode": [NSString stringWithFormat:@"%@-%@",
            carrier[@"mcc"] ?: @"", carrier[@"mnc"] ?: @""],
        @"carrierName": carrier[@"name"] ?: @"",
        @"city": device[@"location"][@"city"] ?: @"",
        @"idfaPosture": profile[@"ids"][@"posture"] ?: @"random",
        @"fontSize": profile[@"reddit"][@"fontSize"] ?: @"17",
        @"batteryOffsetPercent": profile[@"timing"][@"batteryOffsetPercent"] ?: @"0",
        @"security": profile[@"security"] ?: @{},
    };
}

- (NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)containerId randomize:(BOOL)randomize selection:(NSDictionary *)selection error:(NSError **)error {
    return [self privateIdentityEditorDraftForContainer:containerId randomize:randomize
        selection:selection regionSuggestion:nil error:error];
}

- (NSDictionary *)privateIdentityEditorDraftForContainer:(NSString *)containerId randomize:(BOOL)randomize selection:(NSDictionary *)selection regionSuggestion:(NSDictionary *)region error:(NSError **)error {
    NSDictionary *state = [self identityEditorStateForContainer:containerId error:error];
    if (!state) return nil;
    if (randomize && [state[@"locked"] boolValue]) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox.identity" code:423 userInfo:@{NSLocalizedDescriptionKey:state[@"lockReason"] ?: @"Identity is locked"}];
        }
        return nil;
    }
    id automaticValue = selection[@"automatic"];
    if (automaticValue && (![automaticValue isKindOfClass:NSNumber.class] ||
        (![automaticValue isEqual:@YES] && ![automaticValue isEqual:@NO]))) {
        if (error) {
            *error = RBXDeletionError(@"Automatic draft selection must be a boolean.");
        }
        return nil;
    }
    BOOL automatic = [automaticValue isEqual:@YES];
    NSDictionary *regionCity = nil, *regionCarrier = nil;
    if (automatic) {
        BOOL valid = randomize && [region isKindOfClass:NSDictionary.class] && [region[@"ok"] isEqual:@YES];
        for (NSString *key in @[@"country", @"locale", @"timezone", @"city", @"carrierCode"])
            valid = valid && [region[key] isKindOfClass:NSString.class] && [region[key] length] > 0;
        if (valid) {
            NSString *country = region[@"country"];
            valid = [RBXDeviceCatalog validateCountry:country error:nil] &&
                [[RBXDeviceCatalog countryForLocale:region[@"locale"]] isEqual:country] &&
                [[RBXDeviceCatalog countryForTimezone:region[@"timezone"]] isEqual:country];
            for (NSDictionary *city in [RBXDeviceCatalog citiesForCountry:country])
                if ([city[@"city"] isEqual:region[@"city"]] && [city[@"timezone"] isEqual:region[@"timezone"]]) regionCity = city;
            for (NSDictionary *carrier in [RBXDeviceCatalog carriersForCountry:country])
                if ([[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]] isEqual:region[@"carrierCode"]]) regionCarrier = carrier;
            NSTimeInterval observed = [region[@"checkedAt"] isKindOfClass:NSNumber.class] ? [region[@"checkedAt"] doubleValue] : 0;
            NSTimeInterval now = NSDate.date.timeIntervalSince1970;
            valid = valid && regionCity && regionCarrier && observed > 0 && now >= observed && now - observed <= 60;
        }
        if (!valid) {
            if (error) {
                *error = RBXDeletionError(@"Automatic fill requires a fresh, coherent region detected through the actual proxy. No draft was changed.");
            }
            return nil;
        }
    }
    NSMutableDictionary *policies = [NSMutableDictionary dictionary];
    [state[@"security"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        policies[key] = @([value isEqual:@"enabled"]);
    }];
    NSMutableDictionary *choices = [@{@"mode":@"random", @"security":policies,
        @"country":automatic ? region[@"country"] : (state[@"proxyCountry"] ?: state[@"country"] ?: @"")} mutableCopy];
    if (!automatic) {
        choices[@"productType"] = selection[@"productType"] ?: state[@"productType"] ?: @"";
        choices[@"iosVersion"] = selection[@"iosVersion"] ?: state[@"iosVersion"] ?: @"";
    }
    NSDictionary *profile = randomize ? [self _identityCandidateForContainer:containerId choices:choices error:error] : [self _load:containerId error:error];
    if (!profile) return nil;
    if (automatic) {
        NSMutableDictionary *adjusted = [profile mutableCopy], *device = [profile[@"device"] mutableCopy];
        device[@"locale"] = region[@"locale"];
        device[@"language"] = [region[@"locale"] componentsSeparatedByString:@"_"].firstObject;
        device[@"timezone"] = region[@"timezone"];
        device[@"carrier"] = regionCarrier;
        NSMutableDictionary *location = [regionCity mutableCopy]; [location removeObjectForKey:@"timezone"];
        device[@"location"] = location;
        adjusted[@"device"] = device; adjusted[@"mgOverrides"] = RBXBuildMGOverrides(adjusted);
        profile = [self _validatedIdentityCandidate:adjusted excluding:containerId error:error];
        if (!profile) return nil;
    }
    NSMutableDictionary *draft = [state mutableCopy];
    RBXAddAdditionalIdentityFields(draft, profile);
    NSDictionary *device = profile[@"device"] ?: @{}, *carrier = device[@"carrier"] ?: @{};
    [draft addEntriesFromDictionary:@{
        @"mode":@"manual", @"productType":device[@"productType"] ?: @"", @"marketingName":device[@"marketingName"] ?: @"",
        @"iosVersion":device[@"iosVersion"] ?: @"", @"country":device[@"regionCode"] ?: @"", @"locale":device[@"locale"] ?: @"",
        @"timezone":device[@"timezone"] ?: @"", @"city":device[@"location"][@"city"] ?: @"", @"deviceName":device[@"deviceName"] ?: @"",
        @"carrierCode":[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"] ?: @"",carrier[@"mnc"] ?: @""],
        @"idfaPosture":profile[@"ids"][@"posture"] ?: @"random", @"fontSize":profile[@"reddit"][@"fontSize"] ?: @"17",
        @"batteryOffsetPercent":profile[@"timing"][@"batteryOffsetPercent"] ?: @"0", @"security":profile[@"security"] ?: @{}
    }];
    for (NSString *key in @[@"serialNumber",@"udid",@"imei1",@"wifiMac",@"btMac",@"platformUUID"])
        draft[key] = profile[@"serials"][key] ?: @"";
    for (NSString *key in @[@"idfa",@"idfv"]) draft[key] = profile[@"ids"][key] ?: @"";
    for (NSString *key in @[@"installId",@"externalInstallationId"]) draft[key] = profile[@"reddit"][key] ?: @"";
    if (automatic) {
        NSMutableDictionary *provenance = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"country",@"locale",@"timezone",@"city",@"carrierCode",@"countrySource",@"localeSource",
            @"timezoneSource",@"citySource",@"carrierSource",@"proxySource",@"checkedAt"])
            if (region[key]) provenance[key] = region[key];
        draft[@"draftSource"] = @"automatic"; draft[@"automaticRegion"] = provenance;
        draft[@"proxyCountry"] = region[@"country"]; draft[@"observedProxyCountry"] = region[@"country"];
        draft[@"proxyCountrySource"] = @"observed"; draft[@"proxyMismatch"] = @NO;
    }
    return draft;
}

- (NSDictionary *)previewIdentityChoices:(NSDictionary *)choices
                             forContainer:(NSString *)containerId
                                     error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return nil;
    NSDictionary *candidate = [self _identityCandidateForContainer:containerId
                                                           choices:choices error:error];
    if (!candidate) return nil;
    NSDictionary *device = candidate[@"device"];
    return @{
        @"ok": @YES,
        @"containerId": containerId,
        @"message": [choices[@"mode"] isEqualToString:@"random"]
            ? @"Coherent random policy passed; final identifiers are generated on Apply"
            : @"Identity and proxy-country consistency checks passed",
        @"summary": @{
            @"device": device[@"marketingName"] ?: device[@"productType"] ?: @"",
            @"productType": device[@"productType"] ?: @"",
            @"iosVersion": device[@"iosVersion"] ?: @"",
            @"country": device[@"regionCode"] ?: @"",
            @"locale": device[@"locale"] ?: @"",
            @"timezone": device[@"timezone"] ?: @"",
            @"carrier": device[@"carrier"][@"name"] ?: @"",
            @"city": device[@"location"][@"city"] ?: @"",
        },
    };
}

- (BOOL)applyIdentityChoices:(NSDictionary *)choices
                 toContainer:(NSString *)containerId
                       error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return NO;
    if (![self _checkIdentityChoices:choices error:error]) return NO;
    NSDictionary *store = [[RBXCentralStore sharedStore] dictionaryWithError:error];
    if (!store) return NO;
    NSDictionary *stored = store[@"containers"][containerId];
    BOOL locked = RBXIdentityEntryIsFrozen(stored);
    BOOL securityOnly = [choices[@"securityOnly"] boolValue];
    if (locked && !securityOnly) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
            code:423 userInfo:@{NSLocalizedDescriptionKey:
                @"Identity is frozen after first use. Create a new container instead of changing a fingerprint Reddit has already observed."}];
        return NO;
    }
    NSDictionary *original = [self _load:containerId error:error];
    if (!original) return NO;
    NSDictionary *candidate = [self _identityCandidateForContainer:containerId
                                                           choices:choices error:error];
    if (!candidate) return NO;
    if (![self reserveIdentityForProfile:original error:error] ||
        ![self reserveIdentityForProfile:candidate error:error]) return NO;
    if (![self _writeProfile:candidate container:containerId error:error]) return NO;
    // ensureClone detects signed identity changes and backs up the existing
    // installation before replacement. Never pre-uninstall here: that destroys
    // the very app/data which the transaction must preserve.
    if (![self ensureAppCloneForContainer:containerId error:error]) {
        NSError *originalError = error ? *error : nil;
        NSError *recoveryError = nil;
        BOOL restored = [self _writeProfile:original container:containerId error:&recoveryError] &&
            [self ensureAppCloneForContainer:containerId error:&recoveryError];
        if (!restored && error) *error = [NSError errorWithDomain:@"com.redditbox.identity"
            code:500 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                @"Identity update failed (%@); restoration requires recovery (%@). Traffic remains closed and install backups are retained when recovery fails.",
                originalError.localizedDescription ?: @"unknown error",
                recoveryError.localizedDescription ?: @"restoration not proven"]}];
        return NO;
    }
    if (securityOnly && ![self syncProfileToCloneForContainer:containerId error:error]) return NO;
    return YES;
}

- (BOOL)updateMetadata:(NSDictionary *)metadata forContainer:(NSString *)containerId
                 local:(BOOL)local error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return NO;
    if (![metadata isKindOfClass:NSDictionary.class] ||
        (!metadata[@"nickname"] && !metadata[@"role"] && !metadata[@"notes"]) ||
        (metadata[@"nickname"] && !RBXProfileNicknameValid(metadata[@"nickname"])) ||
        (metadata[@"role"] && ![RBXProfileRoles() containsObject:metadata[@"role"]]) ||
        (metadata[@"notes"] && !RBXProfileNotesValid(metadata[@"notes"])) ||
        (!local && (!metadata[@"role"] || !metadata[@"notes"]))) {
        if (error) *error = RBXDeletionError(@"Use a name of 1–120 characters, a supported role, and at most 200 characters of notes");
        return NO;
    }
    NSMutableDictionary *profile = [[RBXProfileIO loadProfileForContainer:containerId error:error] mutableCopy];
    if (!profile) return NO;
    if (!local && (![metadata[@"metadataRevision"] isKindOfClass:NSNumber.class] ||
        [metadata[@"metadataRevision"] longLongValue] < 0)) {
        if (error) *error = RBXDeletionError(@"Cloud metadata revision is invalid"); return NO;
    }
    if (metadata[@"role"]) profile[@"role"] = metadata[@"role"];
    if (metadata[@"notes"]) profile[@"notes"] = metadata[@"notes"];
    if (metadata[@"nickname"]) profile[@"nickname"] = metadata[@"nickname"];
    else if (!local) [profile removeObjectForKey:@"nickname"]; // Explicitly accepted legacy cloud snapshot.
    profile[@"metadataRevision"] = local ? RBXProfileMetadata(profile)[@"metadataRevision"] : metadata[@"metadataRevision"];
    profile[@"metadataDirty"] = @(local);
    return [self _writeProfile:profile container:containerId error:error];
}

- (BOOL)discardMetadataChangesForContainer:(NSString *)containerId error:(NSError **)error {
    if (![self _allowsContainer:containerId error:error]) return NO;
    NSMutableDictionary *profile = [[RBXProfileIO loadProfileForContainer:containerId error:error] mutableCopy];
    if (!profile) return NO;
    profile[@"metadataDirty"] = @NO;
    return [self _writeProfile:profile container:containerId error:error];
}

- (NSString *)createContainerWithId:(NSString *)containerId
                       proxyCountry:(NSString *)country
                           proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname
                              error:(NSError **)error {
    return [self createContainerWithId:containerId proxyCountry:country proxyURL:proxyURL
        nickname:nickname regionSuggestion:nil error:error];
}

- (NSString *)createContainerWithId:(NSString *)containerId
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region
                              error:(NSError **)error {
    return [self createContainerWithId:containerId appType:@"reddit" proxyCountry:country proxyURL:proxyURL
        nickname:nickname regionSuggestion:region error:error];
}

- (BOOL)canCreateContainerForAppType:(NSString *)appType error:(NSError **)error {
    NSDictionary *descriptor = [appType isKindOfClass:NSString.class] ? RBXAppDescriptorForType(appType) : nil;
    if (!descriptor) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.app" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"Unknown app type; no container was created."}];
        return NO;
    }
    // Reddit keeps its established daemon/clone admission sequence unchanged.
    if ([descriptor[@"appType"] isEqual:@"reddit"]) return YES;
    RBXCloneManager *clones = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
        operationContext:RBXOperationContext.currentContext];
    BOOL sourceReady = [[clones sourceStatus][@"decrypted"] boolValue];
    NSString *blocked = RBXAppCloneBlockReason(descriptor, @{@"appType":descriptor[@"appType"]}, sourceReady);
    if (!blocked && !sourceReady) blocked = [NSString stringWithFormat:
        @"No %@ source imported. Import a decrypted %@ IPA before creating a container.",
        descriptor[@"displayName"], descriptor[@"displayName"]];
    if (blocked) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.app" code:2
            userInfo:@{NSLocalizedDescriptionKey:blocked}];
        return NO;
    }
    return YES;
}

- (NSString *)createContainerWithId:(NSString *)containerId appType:(NSString *)appType
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname error:(NSError **)error {
    return [self createContainerWithId:containerId appType:appType proxyCountry:country proxyURL:proxyURL
        nickname:nickname regionSuggestion:nil error:error];
}

- (NSString *)createContainerWithId:(NSString *)containerId appType:(NSString *)appType
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region
                              error:(NSError **)error {
    return [self createContainerWithId:containerId appType:appType proxyCountry:country proxyURL:proxyURL
        nickname:nickname regionSuggestion:region preparedProfile:nil error:error];
}

- (NSString *)createContainerWithId:(NSString *)containerId appType:(NSString *)appType
                       proxyCountry:(NSString *)country proxyURL:(NSString *)proxyURL
                           nickname:(NSString *)nickname regionSuggestion:(NSDictionary *)region
                    preparedProfile:(NSDictionary *)prepared error:(NSError **)error {
    if (![self canCreateContainerForAppType:appType error:error]) return nil;
    NSDictionary *descriptor = RBXAppDescriptorForType(appType);
    if (!RBXRegistryCheckOperation(YES, error)) return nil;
    if ((containerId && ![containerId isKindOfClass:NSString.class]) ||
        (country && ![country isKindOfClass:NSString.class]) ||
        (proxyURL && ![proxyURL isKindOfClass:NSString.class]) ||
        (nickname && ![nickname isKindOfClass:NSString.class])) {
        if (error) *error = [NSError errorWithDomain:RBXProfileIOErrorDomain code:RBXProfileIOSection
            userInfo:@{NSLocalizedDescriptionKey: @"Container creation fields must be strings"}];
        return nil;
    }
    NSString *cid = containerId.length ? containerId :
        [@"c-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    if (!RBXCanonicalProfileIdentifier(cid)) {
        if (error) *error = RBXDeletionError(@"Profile IDs must be 1–128 ASCII letters, digits, underscores or hyphens; IDs are never rewritten");
        return nil;
    }
    NSArray *identifiers = [self containerIdsWithError:error];
    if (!identifiers) return nil;
    BOOL collision = NO;
    for (NSString *identifier in identifiers)
        if ([identifier.lowercaseString isEqual:cid.lowercaseString]) collision = YES;
    if (collision) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox" code:409
                                     userInfo:@{NSLocalizedDescriptionKey: @"container already exists"}];
        }
        return nil;
    }
    NSError *retiredError = nil;
    NSArray *retiredFiles = [NSFileManager.defaultManager contentsOfDirectoryAtPath:kDeletionRoot error:&retiredError];
    if (!retiredFiles && retiredError.code != NSFileReadNoSuchFileError) { if (error) *error = retiredError; return nil; }
    NSArray *legacyRetired = RBXLegacyRetiredIDs(&retiredError);
    if (!legacyRetired) { if (error) *error = retiredError; return nil; }
    NSMutableArray *retiredIds = [legacyRetired mutableCopy];
    for (NSString *file in retiredFiles) if ([file.pathExtension isEqual:@"plist"])
        [retiredIds addObject:file.stringByDeletingPathExtension];
    id remoteRetired = [[RBXCentralStore sharedStore] dictionary][@"cloudRetiredContainers"];
    if ([remoteRetired isKindOfClass:NSDictionary.class]) [retiredIds addObjectsFromArray:[remoteRetired allKeys]];
    for (NSString *retiredId in retiredIds) if ([retiredId.lowercaseString isEqual:cid.lowercaseString]) {
        if (error) *error = RBXDeletionError(@"Profile ID is permanently retired (case-insensitive); choose a new ID");
        return nil;
    }
    if (![self _allowsContainer:cid error:error]) return nil;

    NSString *cc = country.length ? country : @"US";
    NSArray *existing = [self _otherProfilesExcluding:cid error:error];
    if (!existing) return nil;

    // A prepared candidate is daemon-owned authority, never a profile supplied
    // by launcher IPC. Reject stale/wrong-owner/now-conflicting drafts before
    // any reservations, profile writes, pool registration or clone work.
    NSDictionary *profile = nil;
    if (prepared) {
        if (region || proxyURL.length) {
            if (error) *error = RBXDeletionError(@"Prepared creation cannot replace its reviewed region or proxy assignment.");
            return nil;
        }
        profile = [self _validatedCreationEnvelope:prepared container:cid appType:appType country:cc error:error];
        if (!profile) return nil;
    }
    // Preserve identifiers of every surviving profile before publishing a new
    // one. Retired reservations are checked independently of live profiles.
    for (NSDictionary *other in existing)
        if (![self reserveIdentityForProfile:other error:error]) return nil;
    NSError *generationError = nil;
    for (NSUInteger attempt = 0; attempt < 8 && !profile; attempt++) {
        NSDictionary *candidate = [RBXProfileGenerator generateProfileForContainerId:cid appType:descriptor[@"appType"]
            proxyCountry:cc existingProfiles:existing error:&generationError];
        if (!candidate) break;
        if (region) {
            NSMutableDictionary *adjusted = [candidate mutableCopy];
            NSMutableDictionary *device = [candidate[@"device"] mutableCopy];
            device[@"locale"] = region[@"locale"] ?: @"";
            device[@"language"] = [device[@"locale"] componentsSeparatedByString:@"_"].firstObject ?: @"";
            device[@"timezone"] = region[@"timezone"] ?: @"";
            for (NSDictionary *carrier in [RBXDeviceCatalog carriersForCountry:cc])
                if ([[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]] isEqual:region[@"carrierCode"]]) device[@"carrier"] = carrier;
            for (NSDictionary *city in [RBXDeviceCatalog citiesForCountry:cc])
                if ([city[@"city"] isEqual:region[@"city"]]) {
                    NSMutableDictionary *location = [city mutableCopy];
                    [location removeObjectForKey:@"timezone"];
                    device[@"location"] = location;
                }
            adjusted[@"device"] = device;
            adjusted[@"mgOverrides"] = RBXBuildMGOverrides(adjusted);
            candidate = adjusted;
        }
        profile = [self _validatedCandidate:candidate container:cid error:&generationError];
    }
    if (!profile && error) *error = generationError;
    if (!profile) return nil;

    NSMutableDictionary *mut = [profile mutableCopy];
    mut[@"role"] = @"default";
    mut[@"notes"] = @"";
    mut[@"metadataRevision"] = @0;
    mut[@"metadataDirty"] = @YES;
    if (proxyURL.length) {
        NSMutableDictionary *proxy = [mut[@"proxy"] isKindOfClass:[NSDictionary class]]
            ? [mut[@"proxy"] mutableCopy] : [NSMutableDictionary dictionary];
        proxy[@"url"] = proxyURL;
        proxy[@"country"] = cc;
        mut[@"proxy"] = proxy;
        [RBXProxyManager registerUpstream:proxyURL forContainer:cid];
    }

    mut[@"mgOverrides"] = RBXBuildMGOverrides(mut);
    NSDictionary *validated = [RBXConsistencyValidator validatedProfile:mut error:error];
    if (!validated) return nil;
    if (![self reserveIdentityForProfile:validated error:error]) return nil;

    if (![NSFileManager.defaultManager createDirectoryAtPath:kProfilesDir
        withIntermediateDirectories:YES attributes:nil error:error] ||
        ![self _writeProfile:validated container:cid error:error]) return nil;

    RBXCloneManager *clones = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
        operationContext:RBXOperationContext.currentContext];
    NSDictionary *app = [clones ensureCloneForContainer:cid
        profile:validated nickname:(nickname.length ? nickname : cid) error:error];
    if (!app) {
        // Retain the profile that identifies any installed or journaled clone.
        // Recovery may still need it after an interrupted installation.
        return nil;
    }
    NSMutableDictionary *withApp = [validated mutableCopy];
    withApp[@"app"] = app;
    if (![self _writeProfile:withApp container:cid error:error]) {
        // Do not destroy an installation (possibly recovered/reused) because
        // its metadata publication failed. Keep the initial profile for retry.
        return nil;
    }

    [RBXABTestFramework assignGroupForContainer:cid];
    NSString *nick = nickname.length ? nickname : cid;
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) {
            doc[@"containers"] = [NSMutableDictionary dictionary];
        }
        NSMutableDictionary *entry = [@{
            @"nickname": nick,
            @"username": @"",
            @"status": @"yellow",
            @"createdAt": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
            @"push": @{ @"enabled": @NO },
        } mutableCopy];
        if (![descriptor[@"appType"] isEqual:@"reddit"]) entry[@"appType"] = descriptor[@"appType"];
        doc[@"containers"][cid] = entry;
    }];
    NSLog(@"redditboxd: created container %@", cid);
    return cid;
}

// CREATE-001: Preparing or editing a new identity has no profile, reservation,
// clone, selected-container or network side effects. The caller stores this
// envelope in daemon-only memory and separately binds proxy/source evidence.
- (NSDictionary *)_creationReviewForProfile:(NSDictionary *)profile {
    NSDictionary *device = profile[@"device"] ?: @{}, *carrier = device[@"carrier"] ?: @{};
    return @{@"containerId":profile[@"containerId"] ?: @"",
        @"appType":RBXAppDescriptorForProfile(profile)[@"appType"] ?: @"",
        @"productType":device[@"productType"] ?: @"", @"marketingName":device[@"marketingName"] ?: @"",
        @"iosVersion":device[@"iosVersion"] ?: @"", @"country":device[@"regionCode"] ?: @"",
        @"locale":device[@"locale"] ?: @"", @"timezone":device[@"timezone"] ?: @"",
        @"city":device[@"location"][@"city"] ?: @"", @"carrierName":carrier[@"name"] ?: @"",
        @"carrierCode":[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"] ?: @"",carrier[@"mnc"] ?: @""]};
}

- (NSDictionary *)_validatedCreationEnvelope:(NSDictionary *)prepared container:(NSString *)containerId
                                     appType:(NSString *)appType country:(NSString *)country error:(NSError **)error {
    NSDictionary *profile = [prepared isKindOfClass:NSDictionary.class] &&
        [prepared[@"profile"] isKindOfClass:NSDictionary.class] ? prepared[@"profile"] : nil;
    NSNumber *time = [prepared isKindOfClass:NSDictionary.class] &&
        [prepared[@"preparedAt"] isKindOfClass:NSNumber.class] ? prepared[@"preparedAt"] : nil;
    NSTimeInterval age = time ? NSDate.date.timeIntervalSince1970 - time.doubleValue : -1;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!profile || ![prepared[@"formatVersion"] isEqual:@1] || !(age >= 0 && age <= 300) ||
        !RBXCanonicalProfileIdentifier(containerId) || ![profile[@"containerId"] isEqual:containerId] ||
        ![descriptor[@"appType"] isEqual:appType] ||
        ![RBXRegistryValue(profile,@"device.regionCode") isEqual:country] ||
        ![RBXRegistryValue(profile,@"proxy.country") isEqual:country] ||
        ![RBXRegistryValue(profile,@"validation.proxyCountry") isEqual:country] ||
        profile[@"app"] || [RBXRegistryValue(profile,@"proxy.url") length]) {
        if (error) *error = RBXDeletionError(@"Creation draft is expired or no longer matches its app, container and proxy region. Prepare it again.");
        return nil;
    }
    return [self _validatedCandidate:profile container:containerId error:error];
}

- (NSDictionary *)prepareCreationForContainer:(NSString *)containerId appType:(NSString *)appType
                                proxyCountry:(NSString *)country regionSuggestion:(NSDictionary *)region
                                       error:(NSError **)error {
    if (![self canCreateContainerForAppType:appType error:error] || !RBXRegistryCheckOperation(NO,error)) return nil;
    if (!RBXCanonicalProfileIdentifier(containerId) || ![RBXDeviceCatalog validateCountry:country error:error] ||
        ![self _allowsContainer:containerId error:error]) {
        if (error && !*error) *error = RBXDeletionError(@"A new container needs a valid identifier and supported proxy country.");
        return nil;
    }
    NSArray *identifiers = [self containerIdsWithError:error];
    if (!identifiers) return nil;
    for (NSString *identifier in identifiers) if ([identifier.lowercaseString isEqual:containerId.lowercaseString]) {
        if (error) *error = RBXDeletionError(@"Container already exists; preparation cannot edit a saved identity.");
        return nil;
    }
    NSDictionary *regionCity = nil, *regionCarrier = nil;
    if (region) {
        if (![region isKindOfClass:NSDictionary.class]) {
            if (error) *error = RBXDeletionError(@"Creation region observation is malformed.");
            return nil;
        }
        BOOL valid = [region[@"ok"] isEqual:@YES];
        for (NSString *key in @[@"country",@"locale",@"timezone",@"city",@"carrierCode"])
            valid = valid && [region[key] isKindOfClass:NSString.class] && [region[key] length] > 0;
        NSTimeInterval observed = [region[@"checkedAt"] isKindOfClass:NSNumber.class] ? [region[@"checkedAt"] doubleValue] : 0;
        NSTimeInterval age = NSDate.date.timeIntervalSince1970 - observed;
        valid = valid && observed > 0 && age >= 0 && age <= 60 && [region[@"country"] isEqual:country] &&
            [[RBXDeviceCatalog countryForLocale:region[@"locale"]] isEqual:country] &&
            [[RBXDeviceCatalog countryForTimezone:region[@"timezone"]] isEqual:country];
        if (valid) {
            for (NSDictionary *city in [RBXDeviceCatalog citiesForCountry:country])
                if ([city[@"city"] isEqual:region[@"city"]] && [city[@"timezone"] isEqual:region[@"timezone"]]) regionCity = city;
            for (NSDictionary *carrier in [RBXDeviceCatalog carriersForCountry:country])
                if ([[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]] isEqual:region[@"carrierCode"]]) regionCarrier = carrier;
        }
        if (!valid || !regionCity || !regionCarrier) {
            if (error) *error = RBXDeletionError(@"Creation requires a fresh, coherent region observed through the selected proxy.");
            return nil;
        }
    }
    NSArray *existing = [self _otherProfilesExcluding:containerId error:error];
    if (!existing) return nil;
    NSDictionary *profile = nil;
    NSError *generationError = nil;
    for (NSUInteger attempt = 0; attempt < 8 && !profile; attempt++) {
        NSDictionary *candidate = [RBXProfileGenerator generateProfileForContainerId:containerId appType:appType
            proxyCountry:country existingProfiles:existing error:&generationError];
        if (!candidate) break;
        if (region) {
            NSMutableDictionary *adjusted = [candidate mutableCopy], *device = [candidate[@"device"] mutableCopy];
            device[@"locale"] = region[@"locale"];
            device[@"language"] = [region[@"locale"] componentsSeparatedByString:@"_"].firstObject;
            device[@"timezone"] = region[@"timezone"]; device[@"carrier"] = regionCarrier;
            NSMutableDictionary *location = [regionCity mutableCopy]; [location removeObjectForKey:@"timezone"];
            device[@"location"] = location;
            adjusted[@"device"] = device; adjusted[@"mgOverrides"] = RBXBuildMGOverrides(adjusted);
            candidate = adjusted;
        }
        profile = [self _validatedCandidate:candidate container:containerId error:&generationError];
    }
    if (!profile) { if (error) *error = generationError; return nil; }
    return @{@"formatVersion":@1,@"preparedAt":@(NSDate.date.timeIntervalSince1970),
        @"profile":profile,@"review":[self _creationReviewForProfile:profile]};
}

- (NSDictionary *)creationIdentityEditorDraftForProfile:(NSDictionary *)profile error:(NSError **)error {
    NSDictionary *validated = [RBXConsistencyValidator validatedProfile:profile error:error];
    if (!validated || !RBXAppDescriptorForProfile(validated)) return nil;
    NSDictionary *device = validated[@"device"], *carrier = device[@"carrier"];
    NSMutableDictionary *draft = [[self _creationReviewForProfile:validated] mutableCopy];
    [draft addEntriesFromDictionary:@{@"mode":@"manual", @"locked":@NO, @"lockReason":@"",
        @"proxyAssigned":@NO, @"proxyCountry":device[@"regionCode"], @"proxyCountrySource":@"configured",
        @"observedProxyCountry":@"", @"proxyMismatch":@NO,
        @"deviceName":device[@"deviceName"] ?: @"", @"carrierCode":[NSString stringWithFormat:@"%@-%@",carrier[@"mcc"],carrier[@"mnc"]],
        @"idfaPosture":validated[@"ids"][@"posture"] ?: @"random", @"fontSize":validated[@"reddit"][@"fontSize"] ?: @"17",
        @"batteryOffsetPercent":validated[@"timing"][@"batteryOffsetPercent"] ?: @"0", @"security":validated[@"security"] ?: @{}}];
    RBXAddAdditionalIdentityFields(draft,validated);
    for (NSString *key in @[@"serialNumber",@"udid",@"imei1",@"wifiMac",@"btMac",@"platformUUID"])
        draft[key] = validated[@"serials"][key] ?: @"";
    for (NSString *key in @[@"idfa",@"idfv"]) draft[key] = validated[@"ids"][key] ?: @"";
    for (NSString *key in @[@"installId",@"externalInstallationId"]) draft[key] = validated[@"reddit"][key] ?: @"";
    return draft;
}

- (NSDictionary *)creationProfileByApplyingChoices:(NSDictionary *)choices
                               toPreparedProfile:(NSDictionary *)prepared error:(NSError **)error {
    NSDictionary *raw = [prepared isKindOfClass:NSDictionary.class] &&
        [prepared[@"profile"] isKindOfClass:NSDictionary.class] ? prepared[@"profile"] : nil;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(raw);
    NSString *country = RBXRegistryValue(raw,@"device.regionCode");
    if (![self canCreateContainerForAppType:descriptor[@"appType"] error:error] || !RBXRegistryCheckOperation(NO,error)) return nil;
    NSDictionary *original = [self _validatedCreationEnvelope:prepared container:raw[@"containerId"]
        appType:descriptor[@"appType"] country:country error:error];
    if (!original || ![choices isKindOfClass:NSDictionary.class]) return nil;
    if ((choices[@"country"] && ![choices[@"country"] isEqual:country]) || [choices[@"securityOnly"] boolValue]) {
        if (error) *error = RBXDeletionError(@"This draft must keep its observed proxy country. Prepare again after choosing another proxy.");
        return nil;
    }
    NSDictionary *candidate = [self _identityCandidateForProfile:original choices:choices error:error];
    if (!candidate) return nil;
    if ([choices[@"mode"] isEqual:@"random"]) {
        // A model/iOS picker may request fresh compatible identifiers. Keep
        // the already reviewed geography; only an explicit geography edit or
        // a fresh proxy preparation may change it in this creation flow.
        NSMutableDictionary *adjusted = [candidate mutableCopy], *device = [candidate[@"device"] mutableCopy];
        for (NSString *key in @[@"locale",@"language",@"timezone",@"carrier",@"location"])
            device[key] = original[@"device"][key];
        adjusted[@"device"] = device; adjusted[@"mgOverrides"] = RBXBuildMGOverrides(adjusted);
        candidate = adjusted;
    }
    candidate = [self _validatedCandidate:candidate container:original[@"containerId"] error:error];
    if (!candidate) return nil;
    NSMutableDictionary *next = [prepared mutableCopy];
    next[@"profile"] = candidate; next[@"review"] = [self _creationReviewForProfile:candidate];
    // Review edits do not renew the lifetime of proxy/source observations.
    return next;
}

- (BOOL)deleteContainer:(NSString *)containerId error:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error)) return NO;
    @synchronized (RBXContainerRegistry.class) {
        if (!RBXDeletionID(containerId)) {
            if (error) *error = RBXDeletionError(@"Container ID is not a safe profile identifier");
            return NO;
        }
        NSError *failure = nil;
        int directory = RBXOpenDeletionRoot(YES, &failure);
        if (directory < 0) { if (error) *error = failure; return NO; }
        int lock = openat(directory, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
        struct stat lockInfo;
        BOOL locked = lock >= 0 && fstat(lock, &lockInfo) == 0 && S_ISREG(lockInfo.st_mode) &&
            lockInfo.st_uid == RBXDeletionOwner() && lockInfo.st_nlink == 1 && !(lockInfo.st_mode & 0077) &&
            flock(lock, LOCK_EX | LOCK_NB) == 0;
        if (!locked) {
            if (lock >= 0) close(lock);
            close(directory);
            if (error) *error = RBXDeletionError(@"Another deletion is running, or its journal lock is unsafe; retry later");
            return NO;
        }
        NSMutableDictionary *journal = nil;
        BOOL ok = NO;
        @try {
            NSDictionary *existing = RBXReadDeletion(directory, containerId, &failure);
            if (failure) return NO;
            journal = [existing mutableCopy];
            if (journal) {
                BOOL missing = NO;
                NSData *retryProfile = RBXDeletionProfileData(containerId, &missing, &failure);
                if ((!retryProfile && !missing) || !RBXAppDeletionEvidenceOwnerMatches(journal, retryProfile)) {
                    failure = failure ?: RBXDeletionError(@"Profile ownership changed after deletion began; preserve the new profile and retained journal for inspection"); return NO;
                }
            }
            if ([journal[@"phase"] isEqual:@"committed"]) {
                // A committed receipt is sufficient only while no profile has
                // reappeared (including best-effort restoration after fsync failure).
                NSString *path = [[kProfilesDir stringByAppendingPathComponent:containerId]
                    stringByAppendingPathExtension:@"json"];
                struct stat info;
                if (lstat(path.fileSystemRepresentation, &info) != 0 && errno == ENOENT) {
                    journal[@"phase"] = @"cleanup-complete";
                    ok = RBXCommitDeletion(directory, journal, &failure);
                    return ok;
                }
                journal[@"phase"] = @"cleanup-complete";
            }
            if (![self _deletionIsClosed:containerId establish:YES error:&failure]) return NO;
            RBXCloneManager *clones = nil;
            if (!journal) {
                NSArray *legacy = RBXLegacyRetiredIDs(&failure);
                if (!legacy) return NO;
                BOOL missing = NO;
                NSData *rawProfile = RBXDeletionProfileData(containerId, &missing, &failure);
                if (!rawProfile && !missing) return NO;
                NSError *profileError = nil;
                NSDictionary *profile = rawProfile ? [RBXProfileIO profileDictionaryFromData:rawProfile
                    containerId:containerId error:&profileError] : nil;
                // Resolve ownership independently of corrupt profile sections.
                // Never guess Reddit for an unparseable Facebook document.
                id rawOwner = rawProfile ? [NSJSONSerialization JSONObjectWithData:rawProfile options:0 error:nil] : nil;
                NSDictionary *store = [[RBXCentralStore sharedStore] dictionaryWithError:&failure];
                if (!store) return NO;
                NSDictionary *entries = [store[@"containers"] isKindOfClass:NSDictionary.class] ? store[@"containers"] : nil;
                id storedEntry = entries[containerId];
                NSDictionary *storedOwner = [storedEntry isKindOfClass:NSDictionary.class] ? RBXAppDescriptorForProfile(storedEntry) : nil;
                BOOL parsedOwner = [rawOwner isKindOfClass:NSDictionary.class];
                NSDictionary *descriptor = parsedOwner ? RBXAppDescriptorForProfile(rawOwner) : storedOwner;
                if (!descriptor && !parsedOwner && !storedEntry && [legacy containsObject:containerId]) descriptor = RBXRedditAppDescriptor();
                if (!descriptor || (storedEntry && !storedOwner) || (storedOwner && ![storedOwner isEqual:descriptor])) {
                    failure = RBXDeletionError(@"Deletion app owner is unknown or conflicting; retain the profile and recovery evidence for inspection"); return NO;
                }
                clones = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
                    operationContext:RBXOperationContext.currentContext];
                // Permanent hashed history survives deletion, even though raw
                // profile evidence is removed from the committed tombstone.
                if (profile && ![self reserveIdentityForProfile:profile error:&failure]) return NO;
                // An invalid profile supplies no paths, bundle name or group.
                // The backend derives and independently verifies the exact
                // signed clone from this already checked filename identity.
                if (!profile) profile = [descriptor[@"appType"] isEqual:@"reddit"] ? @{@"containerId":containerId}
                    : @{@"containerId":containerId, @"appType":descriptor[@"appType"]};
                NSDictionary *target = [clones prepareDeletionForProfile:profile error:&failure];
                if (!target) return NO;
                if (missing && ![legacy containsObject:containerId] && !target[@"installation"] &&
                    ![target[@"transactions"] count] && !target[@"ipa"] && !target[@"sharedExport"]) {
                    if (![entries[containerId] isKindOfClass:NSDictionary.class]) {
                        failure = RBXDeletionError(@"Profile is missing and no registered clone, stored container or prior deletion proves ownership; retain state for recovery");
                        return NO;
                    }
                }
                journal = [RBXAppDeletionJournalIdentity(target) mutableCopy];
                if (!journal) { failure = RBXDeletionError(@"Deletion backend returned an invalid app identity"); return NO; }
                journal[@"createdAt"] = @(NSDate.date.timeIntervalSince1970);
                NSDictionary *bindings = [[RBXCentralStore sharedStore] dictionary][@"cloudProfileBindings"];
                NSDictionary *binding = [bindings isKindOfClass:NSDictionary.class] &&
                    [bindings[containerId] isKindOfClass:NSDictionary.class] ? bindings[containerId] : nil;
                if (binding) journal[@"cloudBinding"] = binding;
                if (rawProfile) journal[@"profileEvidence"] = rawProfile;
                if (profileError) journal[@"profileReadError"] = profileError.localizedDescription;
                if (!RBXWriteDeletion(directory, journal, @"prepared", &failure)) return NO;
            } else {
                clones = [[RBXCloneManager alloc] initWithAppType:RBXAppDeletionJournalDescriptor(journal)[@"appType"]
                    operationContext:RBXOperationContext.currentContext];
                // A previous rename may have succeeded while its fsync failed.
                // Re-establish a durable checkpoint before replaying any effect.
                if (!RBXWriteDeletion(directory, journal, journal[@"phase"], &failure)) return NO;
            }
            NSDictionary *target = journal[@"target"];
            if ([journal[@"phase"] isEqual:@"prepared"]) {
                if (![self _deletionIsClosed:containerId establish:NO error:&failure] ||
                    ![clones eraseKeychainForDeletionTarget:target error:&failure] ||
                    !RBXWriteDeletion(directory, journal, @"keychain-cleared", &failure)) return NO;
            }
            if ([journal[@"phase"] isEqual:@"keychain-cleared"]) {
                if (![self _deletionIsClosed:containerId establish:NO error:&failure] ||
                    ![clones uninstallDeletionTarget:target error:&failure] ||
                    !RBXWriteDeletion(directory, journal, @"uninstalled", &failure)) return NO;
            }
            if ([journal[@"phase"] isEqual:@"uninstalled"]) {
                if (![self _deletionIsClosed:containerId establish:NO error:&failure] ||
                    ![clones cleanupArtifactsForDeletionTarget:target error:&failure] ||
                    !RBXCleanupLegacyData(containerId, &failure) ||
                    ![RBXProxyManager removeUpstreamForContainer:containerId error:&failure] ||
                    ![RBXRotationSecrets removeProfile:containerId error:&failure]) return NO;
                if (![[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
                    [doc[@"containers"] removeObjectForKey:containerId];
                } error:&failure]) return NO;
                if (!RBXWriteDeletion(directory, journal, @"cleanup-complete", &failure)) return NO;
            }
            if (![self _deletionIsClosed:containerId establish:NO error:&failure]) return NO;
            NSString *profilePath = [[kProfilesDir stringByAppendingPathComponent:containerId]
                stringByAppendingPathExtension:@"json"];
            BOOL missing = NO;
            NSData *restoreData = RBXDeletionProfileData(containerId, &missing, &failure);
            if (!restoreData && !missing) return NO;
            if (!RBXAppDeletionEvidenceOwnerMatches(journal, restoreData)) {
                failure = RBXDeletionError(@"Profile ownership changed during deletion; preserve its bytes and retained journal for inspection"); return NO;
            }
            id schemaEvidence = restoreData ? [NSJSONSerialization JSONObjectWithData:restoreData options:0 error:nil] : nil;
            if ([schemaEvidence isKindOfClass:NSDictionary.class] && schemaEvidence[@"profileVersion"] &&
                !RBXSchemaReadVersion(schemaEvidence, @"profileVersion", RBX_PROFILE_SCHEMA_VERSION, YES, &failure)) return NO;
            if (restoreData && ![restoreData isEqual:journal[@"profileEvidence"]] &&
                ![restoreData isEqual:journal[@"finalProfileEvidence"]]) {
                // Preserve reappeared/changed bytes, including malformed JSON,
                // before the final filesystem removal. Retain exact bytes on a
                // failed commit instead of trying to reserialize invalid data.
                journal[@"finalProfileEvidence"] = restoreData;
                if (!RBXWriteDeletion(directory, journal, @"cleanup-complete", &failure)) return NO;
            }
            if (restoreData && ![NSFileManager.defaultManager removeItemAtPath:profilePath error:&failure]) return NO;
            ok = RBXCommitDeletion(directory, journal, &failure);
            if (!ok && restoreData) {
                if (!RBXRestoreDeletionEvidence(restoreData, profilePath))
                    failure = RBXDeletionError(@"Deletion commit failed and the profile could not be restored; the retained journal must finish recovery");
            }
            return ok;
        } @finally {
            if (!ok) {
                failure = failure ?: RBXDeletionError(@"Deletion did not finish; retry using its retained state");
                if (journal[@"phase"]) {
                    journal[@"lastError"] = failure.localizedDescription;
                    // Never advance a failed phase while recording its error.
                    RBXWriteDeletion(directory, journal, journal[@"phase"], nil);
                }
                if (error) *error = failure;
            }
            flock(lock, LOCK_UN);
            close(lock);
            close(directory);
        }
    }
}

- (BOOL)_deletionIsClosed:(NSString *)containerId establish:(BOOL)establish error:(NSError **)error {
    if (!RBXRegistryCheckOperation(YES, error)) return NO;
    NSString *bindingPath = kActiveBindingPath;
    NSError *readError = nil;
    NSString *active = [NSString stringWithContentsOfFile:bindingPath encoding:NSUTF8StringEncoding error:&readError];
    if (!active && !([readError.domain isEqual:NSCocoaErrorDomain] && readError.code == NSFileReadNoSuchFileError)) {
        if (error) *error = RBXDeletionError(@"Active container binding could not be checked");
        return NO;
    }
    active = [active stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([active isEqual:containerId] && !establish) {
        if (error) *error = RBXDeletionError(@"Deletion is paused because the active binding has not been revoked");
        return NO;
    }
    if (establish && ![RBXNetworkGate closeTrafficWithReason:@"container deletion" error:error]) return NO;
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXNetworkGate.leasePath];
    NSString *generation = [lease[@"generation"] isKindOfClass:NSString.class] ? lease[@"generation"] : nil;
    if (![lease[@"state"] isEqual:@"closed"] || !generation.length ||
        ![[RBXAppProcessCoordinator new] killAllAndWait:RBXGlobalProcessStopBudget()] ||
        ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:1.0]) {
        if (error) *error = RBXDeletionError(@"Deletion requires verified CLOSED traffic and stopped clone processes; retry after closure");
        return NO;
    }
    return YES;
}

@end
#endif
