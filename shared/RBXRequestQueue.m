#import "RBXRequestQueue.h"
#import <dirent.h>
#import <errno.h>
#import <fcntl.h>
#import <math.h>
#import <stdio.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const RBXQueueRoot = @"/var/mobile/Library/RedditBox/IPC";
static const NSUInteger RBXMaximumRecordBytes = 256 * 1024;

static NSError *RBXQueueError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.request-queue" code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *RBXString(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static BOOL RBXValidRequestID(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 36) return NO;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    return [uuid.UUIDString isEqualToString:value];
}

static NSString *RBXRecordName(NSString *requestID) {
    return [requestID stringByAppendingPathExtension:@"plist"];
}

static NSString *RBXIDFromName(NSString *name) {
    NSString *identifier = name.stringByDeletingPathExtension;
    return [name.pathExtension isEqualToString:@"plist"] && RBXValidRequestID(identifier)
        ? identifier : nil;
}

static BOOL RBXValidAction(NSString *action) {
    if (![action isKindOfClass:NSString.class] || !action.length || action.length > 80) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [action rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

static BOOL RBXCheckDirectory(int fd, uid_t owner, mode_t mode, NSError **error) {
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0 || !S_ISDIR(st.st_mode) || st.st_uid != owner ||
        (st.st_mode & 0777) != mode) {
        if (error) *error = RBXQueueError(1, @"request queue directory has unsafe ownership or permissions");
        return NO;
    }
    return YES;
}

static NSArray<NSString *> *RBXRecordNames(int fd, NSError **error) {
    // A fresh open description avoids reusing a directory stream's old offset.
    int copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    DIR *directory = copy >= 0 ? fdopendir(copy) : NULL;
    if (!directory) {
        if (copy >= 0) close(copy);
        if (error) *error = RBXQueueError(2, @"cannot enumerate the request queue");
        return nil;
    }
    NSMutableArray *names = [NSMutableArray array];
    struct dirent *entry;
    int savedError = 0;
    while (YES) {
        errno = 0;
        entry = readdir(directory);
        if (!entry) { savedError = errno; break; }
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (RBXIDFromName(name)) [names addObject:name];
    }
    closedir(directory);
    if (savedError) {
        if (error) *error = RBXQueueError(2, @"request queue enumeration failed");
        return nil;
    }
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

static NSDictionary *RBXReadRecord(int directory, NSString *name, uid_t owner,
                                  uid_t alternateOwner, NSError **error) {
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        if (errno != ENOENT && error) *error = RBXQueueError(3, @"cannot safely read a request queue record");
        return nil;
    }
    struct stat before, after;
    BOOL valid = fstat(fd, &before) == 0 && S_ISREG(before.st_mode) && before.st_nlink == 1 && !(before.st_mode & 0022) &&
        (before.st_uid == owner || before.st_uid == alternateOwner) &&
        before.st_size > 0 && (uint64_t)before.st_size <= RBXMaximumRecordBytes;
    NSMutableData *data = valid ? [NSMutableData dataWithLength:(NSUInteger)before.st_size] : nil;
    NSUInteger offset = 0;
    while (valid && offset < data.length) {
        ssize_t count = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { valid = NO; break; }
        offset += (NSUInteger)count;
    }
    char extra;
    valid = valid && read(fd, &extra, 1) == 0 && fstat(fd, &after) == 0 &&
        before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec;
    close(fd);
    if (!valid) {
        if (error) *error = RBXQueueError(4, @"request queue record is unsafe, oversized, truncated or changed while reading");
        return nil;
    }
    id record = [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:nil error:error];
    if (![record isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = RBXQueueError(5, @"request queue record must be a dictionary");
        return nil;
    }
    return record;
}

static BOOL RBXIsTerminal(NSDictionary *record, NSString *requestID) {
    return [RBXString(record[@"requestId"]) isEqualToString:requestID] &&
        [@[@"succeeded", @"failed", @"interrupted"] containsObject:RBXString(record[@"state"])] &&
        [record[@"ok"] isKindOfClass:NSNumber.class] &&
        [record[@"updatedAt"] isKindOfClass:NSNumber.class] &&
        [record[@"details"] isKindOfClass:NSDictionary.class];
}

@implementation RBXRequestQueue {
    NSString *_rootDirectory;
    uid_t _daemonUID;
    uid_t _clientUID;
    int _rootFD, _inboxFD, _processingFD, _resultsFD, _lockFD;
    BOOL _prepared;
    NSMutableDictionary<NSString *, NSDictionary *> *_activeRequests;
    NSMutableDictionary<NSString *, NSDictionary *> *_pendingResults;
}

+ (instancetype)defaultQueue {
    static RBXRequestQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [[self alloc] initWithRootDirectory:RBXQueueRoot daemonUID:0 clientUID:501];
    });
    return queue;
}

- (instancetype)init {
    return [self initWithRootDirectory:RBXQueueRoot daemonUID:0 clientUID:501];
}

- (instancetype)initWithRootDirectory:(NSString *)path daemonUID:(uid_t)daemonUID clientUID:(uid_t)clientUID {
    if ((self = [super init])) {
        _rootDirectory = [path copy]; _daemonUID = daemonUID; _clientUID = clientUID;
        _rootFD = _inboxFD = _processingFD = _resultsFD = _lockFD = -1;
        _activeRequests = [NSMutableDictionary dictionary];
        _pendingResults = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    if (_lockFD >= 0) { flock(_lockFD, LOCK_UN); close(_lockFD); }
    if (_rootFD >= 0) close(_rootFD);
    if (_inboxFD >= 0) close(_inboxFD);
    if (_processingFD >= 0) close(_processingFD);
    if (_resultsFD >= 0) close(_resultsFD);
}

- (BOOL)_syncDescriptor:(int)fd operation:(NSString *)operation error:(NSError **)error {
    if (fsync(fd) == 0) return YES;
    if (error) *error = RBXQueueError(6, [NSString stringWithFormat:
        @"request queue persistence failed during %@; queued records were retained", operation]);
    return NO;
}

- (int)_openRootCreating:(BOOL)create error:(NSError **)error {
    if (!_rootDirectory.isAbsolutePath || [_rootDirectory isEqualToString:@"/"] ||
        ![_rootDirectory isEqualToString:_rootDirectory.stringByStandardizingPath] ||
        ![_rootDirectory.lastPathComponent length]) {
        if (error) *error = RBXQueueError(7, @"request queue root path is invalid"); return -1;
    }
    NSString *parentPath = _rootDirectory.stringByDeletingLastPathComponent;
    int parent = open(parentPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (parent < 0 || fstat(parent, &st) != 0 || st.st_uid != _daemonUID || (st.st_mode & 0022)) {
        if (parent >= 0) close(parent);
        if (error) *error = RBXQueueError(7, @"request queue parent must be daemon-owned and not writable by other users");
        return -1;
    }
    const char *name = _rootDirectory.lastPathComponent.fileSystemRepresentation;
    if (create && mkdirat(parent, name, 0755) != 0 && errno != EEXIST) {
        close(parent);
        if (error) *error = RBXQueueError(8, @"cannot create the request queue directory"); return -1;
    }
    int fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (create && fd >= 0) {
        struct stat rootStat;
        if (fstat(fd, &rootStat) == 0 && rootStat.st_uid == _daemonUID && !(rootStat.st_mode & 0022))
            fchmod(fd, 0755);
    }
    BOOL valid = RBXCheckDirectory(fd, _daemonUID, 0755, error);
    if (valid && create) valid = [self _syncDescriptor:parent operation:@"queue creation" error:error];
    close(parent);
    if (!valid) { if (fd >= 0) close(fd); return -1; }
    return fd;
}

- (int)_openDirectory:(NSString *)name root:(int)root owner:(uid_t)owner mode:(mode_t)mode
               create:(BOOL)create error:(NSError **)error {
    if (create && mkdirat(root, name.fileSystemRepresentation, mode) != 0 && errno != EEXIST) {
        if (error) *error = RBXQueueError(8, @"cannot create request queue subdirectories"); return -1;
    }
    int fd = openat(root, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (create && fd >= 0 && fstat(fd, &st) == 0 &&
        (st.st_uid == owner || st.st_uid == _daemonUID)) {
        // Also repairs a crash between mkdir and assigning Inbox to mobile.
        if ((st.st_uid != owner && fchown(fd, owner, (gid_t)-1) != 0) || fchmod(fd, mode) != 0) {
            close(fd);
            if (error) *error = RBXQueueError(9, @"cannot establish request queue access permissions"); return -1;
        }
    }
    if (!RBXCheckDirectory(fd, owner, mode, error)) { if (fd >= 0) close(fd); return -1; }
    return fd;
}

- (BOOL)prepareDaemon:(NSError **)error {
    @synchronized (self) {
        if (_prepared) return YES;
        if (geteuid() != _daemonUID) {
            if (error) *error = RBXQueueError(10, @"only the daemon may prepare or claim requests"); return NO;
        }
        int root = [self _openRootCreating:YES error:error];
        if (root < 0) return NO;
        int lock = openat(root, ".daemon.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
        struct stat st;
        BOOL locked = lock >= 0 && fstat(lock, &st) == 0 && S_ISREG(st.st_mode) &&
            st.st_nlink == 1 && st.st_uid == _daemonUID && flock(lock, LOCK_EX | LOCK_NB) == 0;
        if (!locked) {
            if (lock >= 0) close(lock); close(root);
            if (error) *error = RBXQueueError(11, @"another daemon owns the request queue, or its lock is unsafe"); return NO;
        }
        int inbox = [self _openDirectory:@"Inbox" root:root owner:_clientUID mode:0700 create:YES error:error];
        int processing = [self _openDirectory:@"Processing" root:root owner:_daemonUID mode:0700 create:YES error:error];
        int results = [self _openDirectory:@"Results" root:root owner:_daemonUID mode:0755 create:YES error:error];
        if (inbox < 0 || processing < 0 || results < 0 ||
            ![self _syncDescriptor:root operation:@"queue setup" error:error]) {
            if (inbox >= 0) close(inbox); if (processing >= 0) close(processing); if (results >= 0) close(results);
            flock(lock, LOCK_UN); close(lock); close(root); return NO;
        }
        _rootFD = root; _inboxFD = inbox; _processingFD = processing; _resultsFD = results; _lockFD = lock;
        _prepared = YES;
        return YES;
    }
}

- (BOOL)_writeRecord:(NSDictionary *)record directory:(int)directory name:(NSString *)name
               owner:(uid_t)owner mode:(mode_t)mode replace:(BOOL)replace
           published:(BOOL *)published error:(NSError **)error {
    if (published) *published = NO;
    if (![NSPropertyListSerialization propertyList:record isValidForFormat:NSPropertyListBinaryFormat_v1_0]) {
        if (error) *error = RBXQueueError(12, @"request or response contains unsupported values"); return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data.length || data.length > RBXMaximumRecordBytes) {
        if (error) *error = RBXQueueError(12, @"request or response exceeds the 256 KiB limit"); return NO;
    }
    NSString *temporary = [@".tmp-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(directory, temporary.fileSystemRepresentation,
        O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { if (error) *error = RBXQueueError(13, @"cannot stage request queue data"); return NO; }
    NSUInteger offset = 0;
    BOOL ok = YES;
    while (offset < data.length) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (NSUInteger)count;
    }
    struct stat st;
    ok = ok && fstat(fd, &st) == 0 && (st.st_uid == owner || fchown(fd, owner, (gid_t)-1) == 0) &&
        fchmod(fd, mode) == 0 && [self _syncDescriptor:fd operation:@"record data" error:error];
    close(fd);
    if (ok) {
        int status = replace
            ? renameat(directory, temporary.fileSystemRepresentation, directory, name.fileSystemRepresentation)
            : renameatx_np(directory, temporary.fileSystemRepresentation, directory, name.fileSystemRepresentation, RENAME_EXCL);
        ok = status == 0;
        if (ok && published) *published = YES;
    }
    if (!ok) {
        unlinkat(directory, temporary.fileSystemRepresentation, 0);
        if (error && !*error) *error = RBXQueueError(13, @"request queue publication failed; existing records were preserved");
        return NO;
    }
    return [self _syncDescriptor:directory operation:@"record publication" error:error];
}

- (NSString *)enqueueAction:(NSString *)action values:(NSDictionary *)values error:(NSError **)error {
    @synchronized (self) {
        if (!RBXValidAction(action) || ![values isKindOfClass:NSDictionary.class] ||
            (geteuid() != _clientUID && geteuid() != _daemonUID)) {
            if (error) *error = RBXQueueError(14, @"invalid launcher request"); return nil;
        }
        int root = [self _openRootCreating:NO error:error];
        if (root < 0) return nil;
        int inbox = [self _openDirectory:@"Inbox" root:root owner:_clientUID mode:0700 create:NO error:error];
        close(root);
        if (inbox < 0) return nil;
        NSArray *queued = RBXRecordNames(inbox, error);
        if (!queued || queued.count >= 1024) {
            close(inbox);
            if (queued && error) *error = RBXQueueError(15, @"request queue is full; wait for pending operations"); return nil;
        }
        NSString *requestID = NSUUID.UUID.UUIDString;
        NSMutableDictionary *request = [values mutableCopy];
        request[@"formatVersion"] = @1; request[@"requestId"] = requestID;
        request[@"action"] = action; request[@"requestedAt"] = @(NSDate.date.timeIntervalSince1970);
        BOOL published = NO;
        BOOL ok = [self _writeRecord:request directory:inbox name:RBXRecordName(requestID)
            owner:_clientUID mode:0600 replace:NO published:&published error:error];
        close(inbox);
        // A failure after rename cannot safely be treated as unsent: the daemon
        // may already own this request. Return its ID even when sync failed.
        return ok || published ? requestID : nil;
    }
}

- (NSDictionary *)resultForRequestID:(NSString *)requestID error:(NSError **)error {
    @synchronized (self) {
        if (!RBXValidRequestID(requestID)) {
            if (error) *error = RBXQueueError(16, @"invalid request identifier"); return nil;
        }
        int root = [self _openRootCreating:NO error:error];
        if (root < 0) return nil;
        int results = [self _openDirectory:@"Results" root:root owner:_daemonUID mode:0755 create:NO error:error];
        close(root);
        if (results < 0) return nil;
        NSDictionary *record = RBXReadRecord(results, RBXRecordName(requestID), _daemonUID, _daemonUID, error);
        close(results);
        if (record && !RBXIsTerminal(record, requestID)) {
            if (error) *error = RBXQueueError(17, @"terminal request result is corrupt"); return nil;
        }
        return record;
    }
}

- (NSDictionary *)_terminalForRequest:(NSDictionary *)request ok:(BOOL)ok state:(NSString *)state
                               message:(NSString *)message details:(NSDictionary *)details {
    NSString *container = RBXString(details[@"containerId"]);
    if (!container.length) container = RBXString(request[@"container"]);
    if (!container.length) container = RBXString(request[@"containerId"]);
    return @{@"requestId": RBXString(request[@"requestId"]), @"action": RBXString(request[@"action"]),
        @"containerId": container,
        @"ok": @(ok), @"message": RBXString(message), @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        @"state": state, @"details": details ?: @{}};
}

- (BOOL)_persistResult:(NSDictionary *)result error:(NSError **)error {
    NSString *requestID = result[@"requestId"];
    NSString *name = RBXRecordName(requestID);
    NSError *readError = nil;
    NSDictionary *existing = RBXReadRecord(_resultsFD, name, _daemonUID, _daemonUID, &readError);
    if (readError || (existing && !RBXIsTerminal(existing, requestID))) {
        if (error) *error = readError ?: RBXQueueError(17, @"existing terminal result is corrupt; claim retained"); return NO;
    }
    if (!existing) {
        BOOL published = NO;
        if (![self _writeRecord:result directory:_resultsFD name:name owner:_daemonUID mode:0644
            replace:NO published:&published error:error]) return NO;
    } else if (![self _syncDescriptor:_resultsFD operation:@"terminal result verification" error:error]) {
        return NO;
    }
    // An immutable terminal receipt is durable before any claim is discarded.
    if (unlinkat(_processingFD, name.fileSystemRepresentation, 0) != 0 && errno != ENOENT) {
        if (error) *error = RBXQueueError(18, @"terminal result saved, but claim cleanup must be retried"); return NO;
    }
    if (![self _syncDescriptor:_processingFD operation:@"claim cleanup" error:error]) return NO;
    [_activeRequests removeObjectForKey:requestID];
    [_pendingResults removeObjectForKey:requestID];
    return YES;
}

- (BOOL)finishRequest:(NSDictionary *)request ok:(BOOL)ok message:(NSString *)message
               values:(NSDictionary *)values error:(NSError **)error {
    @synchronized (self) {
        NSString *requestID = [request isKindOfClass:NSDictionary.class] ? RBXString(request[@"requestId"]) : @"";
        if (!_prepared || !RBXValidRequestID(requestID)) {
            if (error) *error = RBXQueueError(19, @"request is not owned by this daemon"); return NO;
        }
        NSDictionary *active = _activeRequests[requestID];
        NSDictionary *pending = _pendingResults[requestID];
        if (!active && !pending) {
            NSDictionary *existing = RBXReadRecord(_resultsFD, RBXRecordName(requestID), _daemonUID, _daemonUID, error);
            if (RBXIsTerminal(existing, requestID)) return [self _persistResult:existing error:error];
            if (error && !*error) *error = RBXQueueError(19, @"request is not owned by this daemon"); return NO;
        }
        if (!pending) {
            NSDictionary *details = [values isKindOfClass:NSDictionary.class] ? values : @{};
            pending = [self _terminalForRequest:active ok:ok state:ok ? @"succeeded" : @"failed"
                message:message details:details];
            // An unserializable/oversized response must itself reach a terminal
            // failure rather than leaving the accepted request pending forever.
            NSData *encoded = [NSPropertyListSerialization propertyList:pending isValidForFormat:NSPropertyListBinaryFormat_v1_0]
                ? [NSPropertyListSerialization dataWithPropertyList:pending format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] : nil;
            if (!encoded.length || encoded.length > RBXMaximumRecordBytes)
                pending = [self _terminalForRequest:active ok:NO state:@"failed"
                    message:@"Operation completed, but its response could not be encoded; verify the current state before retrying" details:@{}];
            else
                pending = [NSPropertyListSerialization propertyListWithData:encoded
                    options:NSPropertyListImmutable format:nil error:nil];
            _pendingResults[requestID] = pending;
        }
        return [self _persistResult:pending error:error];
    }
}

- (BOOL)retryPendingResultsAndRecoverAbandonedClaims:(NSError **)error {
    @synchronized (self) {
        if (!_prepared) {
            if (error) *error = RBXQueueError(20, @"request queue has not been prepared by the daemon"); return NO;
        }
        for (NSString *requestID in [_pendingResults.allKeys copy])
            if (![self _persistResult:_pendingResults[requestID] error:error]) return NO;
        NSArray *names = RBXRecordNames(_processingFD, error);
        if (!names) return NO;
        for (NSString *name in names) {
            NSString *requestID = RBXIDFromName(name);
            if (_activeRequests[requestID] || _pendingResults[requestID]) continue;
            NSDictionary *request = RBXReadRecord(_processingFD, name, _daemonUID, _clientUID, nil);
            NSMutableDictionary *safe = [NSMutableDictionary dictionary];
            safe[@"requestId"] = requestID; safe[@"action"] = RBXString(request[@"action"]);
            safe[@"container"] = RBXString(request[@"container"]);
            NSDictionary *result = [self _terminalForRequest:safe ok:NO state:@"interrupted"
                message:@"Daemon stopped before a terminal result was recorded. The action was not replayed; verify its current state before retrying."
                details:@{}];
            _pendingResults[requestID] = result;
            if (![self _persistResult:result error:error]) return NO;
        }
        return YES;
    }
}

- (NSDictionary *)claimNextRequest:(NSError **)error {
    @synchronized (self) {
        if (![self retryPendingResultsAndRecoverAbandonedClaims:error]) return nil;
        NSArray *names = RBXRecordNames(_inboxFD, error);
        if (!names) return nil;
        NSMutableDictionary *publishedAt = [NSMutableDictionary dictionary];
        for (NSString *name in names) {
            NSDictionary *record = RBXReadRecord(_inboxFD, name, _clientUID, _daemonUID, nil);
            double timestamp = [record[@"requestedAt"] isKindOfClass:NSNumber.class]
                ? [record[@"requestedAt"] doubleValue] : NAN;
            if (!isfinite(timestamp)) {
                struct stat st;
                timestamp = fstatat(_inboxFD, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) == 0
                    ? (double)st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9 : INFINITY;
            }
            publishedAt[name] = @(timestamp);
        }
        // Preserve sequential user actions (A then B), independently of random
        // UUID ordering. Equal publication timestamps use a stable filename tie.
        NSArray *ordered = [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSComparisonResult result = [publishedAt[a] compare:publishedAt[b]];
            return result == NSOrderedSame ? [a compare:b] : result;
        }];
        for (NSString *name in ordered) {
            NSString *requestID = RBXIDFromName(name);
            int moved = renameatx_np(_inboxFD, name.fileSystemRepresentation,
                _processingFD, name.fileSystemRepresentation, RENAME_EXCL);
            if (moved != 0) {
                if (errno == ENOENT || errno == EEXIST) continue;
                if (error) *error = RBXQueueError(21, @"could not claim a queued request; it remains queued"); return nil;
            }
            NSError *claimError = nil;
            BOOL durable = [self _syncDescriptor:_processingFD operation:@"request claim" error:&claimError] &&
                [self _syncDescriptor:_inboxFD operation:@"inbox claim removal" error:&claimError];
            NSDictionary *request = durable ? RBXReadRecord(_processingFD, name, _clientUID, _daemonUID, &claimError) : nil;
            BOOL valid = request && [RBXString(request[@"requestId"]) isEqualToString:requestID] &&
                RBXValidAction(request[@"action"]) && [request[@"formatVersion"] isEqual:@1] &&
                [request[@"requestedAt"] isKindOfClass:NSNumber.class] &&
                isfinite([request[@"requestedAt"] doubleValue]);
            NSMutableDictionary *snapshot = valid ? [request mutableCopy] : [NSMutableDictionary dictionary];
            snapshot[@"requestId"] = requestID;
            if (!valid) snapshot[@"action"] = @"unknown";
            snapshot[@"claimedAt"] = @(NSDate.date.timeIntervalSince1970);
            NSError *resultError = nil;
            NSDictionary *existing = RBXReadRecord(_resultsFD, name, _daemonUID, _daemonUID, &resultError);
            if (resultError || (existing && !RBXIsTerminal(existing, requestID))) {
                if (error) *error = resultError ?: RBXQueueError(17, @"existing terminal result is corrupt; request was not replayed");
                return nil;
            }
            if (existing && RBXIsTerminal(existing, requestID)) {
                _pendingResults[requestID] = existing;
                if (![self _persistResult:existing error:error]) return nil;
                continue; // A repeated UUID can never replay an already finished operation.
            }
            BOOL published = NO;
            if (valid) valid = [self _writeRecord:snapshot directory:_processingFD name:name
                owner:_daemonUID mode:0600 replace:YES published:&published error:&claimError];
            if (!valid) {
                NSDictionary *result = [self _terminalForRequest:snapshot ok:NO state:@"failed"
                    message:claimError.localizedDescription ?: @"Request was rejected because its payload was invalid"
                    details:@{}];
                _pendingResults[requestID] = result;
                if (![self _persistResult:result error:error]) return nil;
                continue;
            }
            // Replacing the inode prevents a client that retained an open fd to
            // its submitted file from mutating the owned execution snapshot.
            NSDictionary *owned = [snapshot copy];
            _activeRequests[requestID] = owned;
            return owned;
        }
        return nil;
    }
}
@end
