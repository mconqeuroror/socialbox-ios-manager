#pragma once
#import <Foundation/Foundation.h>
#import "RBXProfileIdentifier.h"
#import <archive.h>
#import <archive_entry.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

// LIFE-015: bounds apply to declared and actual expansion, never just gzip size.
#ifndef RBX_BACKUP_MAX_FILE_BYTES
#define RBX_BACKUP_MAX_FILE_BYTES (1024ULL * 1024 * 1024)
#endif
#ifndef RBX_BACKUP_MAX_TOTAL_BYTES
#define RBX_BACKUP_MAX_TOTAL_BYTES (3ULL * 1024 * 1024 * 1024)
#endif
#ifndef RBX_BACKUP_MAX_ENTRIES
#define RBX_BACKUP_MAX_ENTRIES 65536
#endif

static BOOL RBXBackupArchiveFailure(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.backup-archive" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

typedef struct {
    int descriptor;
    __unsafe_unretained BOOL (^continueWork)(NSError **);
    NSError *__strong *error;
    unsigned char bytes[65536];
} RBXBackupArchiveInput;

static la_ssize_t RBXBackupArchiveRead(struct archive *reader, void *opaque, const void **buffer) {
    RBXBackupArchiveInput *input = opaque;
    for (;;) {
        NSError *failure = nil;
        if (!input->continueWork(&failure)) {
            if (input->error) *input->error = failure;
            archive_set_error(reader, ECANCELED, "Backup extraction operation was cancelled");
            return -1;
        }
        ssize_t count = read(input->descriptor, input->bytes, sizeof(input->bytes));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) archive_set_error(reader, errno, "Backup archive read failed");
        *buffer = input->bytes;
        return count;
    }
}

// Resolve every parent relative to an already opened private stage. Archive
// links, ownership, ACLs and special modes never enter this filesystem walk.
static int RBXBackupArchiveDirectory(int root, NSArray<NSString *> *parts,
                                    NSUInteger count, NSError **error) {
    int directory = dup(root);
    for (NSUInteger index = 0; directory >= 0 && index < count; index++) {
        const char *name = parts[index].fileSystemRepresentation;
        if (mkdirat(directory, name, 0700) != 0 && errno != EEXIST) {
            close(directory); directory = -1; break;
        }
        int child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(directory); directory = child;
        struct stat info;
        if (directory >= 0 && (fstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) ||
            info.st_uid != geteuid() || (info.st_mode & 0077))) {
            close(directory); directory = -1;
        }
    }
    if (directory < 0) RBXBackupArchiveFailure(error, @"Backup parent directory is unsafe or unavailable");
    return directory;
}

static BOOL RBXExtractBackupArchive(NSString *archivePath, NSString *stage,
    NSString *legacyContainerId, BOOL (^continueWork)(NSError **), NSError **error) {
    if (!continueWork || !continueWork(error)) return NO;
    if (!RBXCanonicalProfileIdentifier(legacyContainerId))
        return RBXBackupArchiveFailure(error, @"Backup legacy container identity is invalid");
    int root = open(stage.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    int input = open(archivePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat rootInfo, inputInfo;
    BOOL safe = root >= 0 && input >= 0 && fstat(root, &rootInfo) == 0 &&
        S_ISDIR(rootInfo.st_mode) && rootInfo.st_uid == geteuid() && !(rootInfo.st_mode & 0077) &&
        fstat(input, &inputInfo) == 0 && S_ISREG(inputInfo.st_mode) && inputInfo.st_nlink == 1 &&
        inputInfo.st_uid == geteuid() && inputInfo.st_size > 0 &&
        (uint64_t)inputInfo.st_size <= 3ULL * 1024 * 1024 * 1024;
    if (!safe) {
        if (root >= 0) close(root);
        if (input >= 0) close(input);
        return RBXBackupArchiveFailure(error, @"Backup archive or private extraction stage is unsafe");
    }
    struct archive *reader = archive_read_new();
    if (!reader) {
        close(root); close(input);
        return RBXBackupArchiveFailure(error, @"Cannot allocate backup archive reader");
    }
    archive_read_support_format_tar(reader);
    archive_read_support_filter_gzip(reader);
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary *spellings = [NSMutableDictionary dictionary];
    NSString *selectedRoot = nil;
    NSString *failure = nil;
    // Retain callback/errors across each entry's autorelease pool. The caller's
    // autoreleasing error pointer is written only after all pools have drained.
    NSError *operationError = nil;
    uint64_t expanded = 0;
    NSUInteger entries = 0;
    int result = ARCHIVE_FATAL;
    BOOL cancelled = NO;
    RBXBackupArchiveInput inputContext = { .descriptor = input, .continueWork = continueWork, .error = &operationError };
    if (archive_read_open(reader, &inputContext, NULL, RBXBackupArchiveRead, NULL) != ARCHIVE_OK) {
        failure = @"Backup is not a readable gzip tar archive";
    } else {
        struct archive_entry *entry = NULL;
        while ((result = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
          @autoreleasepool {
            if (!continueWork(&operationError)) { cancelled = YES; break; }
            const char *raw = archive_entry_pathname_utf8(entry);
            NSString *relative = raw ? [NSString stringWithUTF8String:raw] : nil;
            if ([relative hasSuffix:@"/"]) relative = [relative substringToIndex:relative.length - 1];
            NSArray<NSString *> *parts = [relative componentsSeparatedByString:@"/"];
            BOOL invalid = !relative.length || relative.length > 2048 ||
                [relative hasPrefix:@"/"] || [relative containsString:@"\\"] || [relative containsString:@":"] ||
                [relative rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound;
            for (NSString *part in parts)
                invalid |= !part.length || [part isEqual:@"."] || [part isEqual:@".."];
            NSString *top = parts.firstObject;
            invalid |= !([top isEqual:@"AppData"] || [top isEqual:legacyContainerId]) ||
                (selectedRoot && ![selectedRoot isEqual:top]);
            mode_t type = archive_entry_filetype(entry);
            int64_t size = archive_entry_size(entry);
            invalid |= (type != AE_IFREG && type != AE_IFDIR) ||
                (parts.count == 1 && type != AE_IFDIR) || archive_entry_symlink(entry) != NULL ||
                archive_entry_hardlink(entry) != NULL || archive_entry_sparse_count(entry) > 0 ||
                archive_entry_is_encrypted(entry) > 0 || size < 0 || (type == AE_IFDIR && size != 0) ||
                (uint64_t)size > RBX_BACKUP_MAX_FILE_BYTES ||
                (uint64_t)size > RBX_BACKUP_MAX_TOTAL_BYTES - expanded ||
                ++entries > RBX_BACKUP_MAX_ENTRIES;
            NSString *canonical = relative.precomposedStringWithCanonicalMapping.lowercaseString;
            invalid |= canonical && [seen containsObject:canonical];
            // Include implicit parents, so Library/a + library/b cannot alias
            // the same directory on the device's case-insensitive filesystem.
            for (NSUInteger index = 1; !invalid && index <= parts.count; index++) {
                NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, index)] componentsJoinedByString:@"/"];
                NSString *key = prefix.precomposedStringWithCanonicalMapping.lowercaseString;
                if (spellings[key] && ![spellings[key] isEqual:prefix]) invalid = YES;
                else spellings[key] = prefix;
            }
            if (invalid) { failure = @"Backup has an unsafe, duplicate, linked, mixed-root or oversized archive entry"; break; }
            selectedRoot = top;
            [seen addObject:canonical];
            int parent = RBXBackupArchiveDirectory(root, parts,
                type == AE_IFDIR ? parts.count : parts.count - 1, &operationError);
            if (parent < 0) { failure = @"Backup parent could not be safely created"; break; }
            if (type == AE_IFDIR) { close(parent); continue; }
            int output = openat(parent, parts.lastObject.fileSystemRepresentation,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            close(parent);
            if (output < 0) { failure = @"Backup file already exists or cannot be created safely"; break; }
            uint64_t written = 0;
            char buffer[65536];
            la_ssize_t count = 0;
            while ((count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                if (!continueWork(&operationError)) { cancelled = YES; break; }
                if ((uint64_t)count > (uint64_t)size - written) {
                    failure = @"Backup entry exceeds its declared expansion size"; break;
                }
                la_ssize_t offset = 0;
                while (offset < count) {
                    if (!continueWork(&operationError)) { cancelled = YES; break; }
                    ssize_t n = write(output, buffer + offset, (size_t)(count - offset));
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) { failure = @"Backup write failed; partial stage retained"; break; }
                    offset += n;
                }
                if (failure || cancelled) break;
                written += (uint64_t)count;
            }
            if (!failure && !cancelled && (count < 0 || written != (uint64_t)size ||
                fchmod(output, 0600 | (archive_entry_perm(entry) & 0111)) != 0 || fsync(output) != 0))
                failure = @"Backup entry is truncated, corrupt or could not be persisted";
            close(output);
            if (failure || cancelled) break;
            expanded += written;
          }
        }
    }
    BOOL ok = result == ARCHIVE_EOF && entries > 0 && !failure && !cancelled && continueWork(&operationError);
    if (archive_read_close(reader) != ARCHIVE_OK) ok = NO;
    archive_read_free(reader); close(input); close(root);
    if (!ok) {
        if (operationError && error) *error = operationError;
        else RBXBackupArchiveFailure(error, failure ?: @"Backup archive is empty, malformed, cancelled or truncated");
    }
    return ok;
}
