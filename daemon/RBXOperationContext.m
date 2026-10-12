#import "RBXOperationContext.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <time.h>
#import <math.h>
#import <dirent.h>
#import <string.h>

NSString * const RBXOperationErrorDomain = @"com.redditbox.operation";
static NSString * const RBXContextTLSKey = @"com.redditbox.operation.current";
#ifdef RBX_OPERATION_TESTING
static NSString *RBXFenceDirectory;
static uid_t RBXFenceOwner(void) { return geteuid(); }
#else
static NSString * const RBXFenceDirectory = @"/var/mobile/Library/RedditBox/operations";
static uid_t RBXFenceOwner(void) { return 0; }
#endif
static NSDictionary *RBXUnsafeInMemory;

static NSTimeInterval RBXOperationNow(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return NAN;
    return value.tv_sec + value.tv_nsec / 1e9;
}
static NSError *RBXOperationError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:RBXOperationErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Operation cannot proceed"}];
}
static dispatch_queue_t RBXOperationSupervisor(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.redditbox.operation.supervisor", DISPATCH_QUEUE_CONCURRENT); });
    return queue;
}
static dispatch_queue_t RBXOperationCancellationDelivery(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.redditbox.operation.cancellation", DISPATCH_QUEUE_CONCURRENT); });
    return queue;
}

// Missing is -2; unsafe/unreadable is -1. A bad existing fence fails closed.
static int RBXOpenFenceDirectory(BOOL create, NSError **error) {
    if (!RBXFenceDirectory.length) {
        if (error) *error = RBXOperationError(5, @"Operation fence path is unavailable");
        return -1;
    }
    if (create) {
        NSString *parentPath = RBXFenceDirectory.stringByDeletingLastPathComponent;
        if (![NSFileManager.defaultManager createDirectoryAtPath:parentPath withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions: @0755} error:error]) return -1;
        int parent = open(parentPath.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int grandparent = open(parentPath.stringByDeletingLastPathComponent.fileSystemRepresentation,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        struct stat info;
        BOOL safe = parent >= 0 && fstat(parent, &info) == 0 && info.st_uid == RBXFenceOwner() &&
            !(info.st_mode & 0022) && grandparent >= 0 && fsync(grandparent) == 0;
        if (grandparent >= 0) close(grandparent);
        if (safe && mkdirat(parent, RBXFenceDirectory.lastPathComponent.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) safe = NO;
        if (safe) safe = fsync(parent) == 0;
        if (parent >= 0) close(parent);
        if (!safe) {
            if (error) *error = RBXOperationError(5, @"Operation fence directory could not be durably prepared");
            return -1;
        }
    }
    int directory = open(RBXFenceDirectory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (directory < 0) {
        if (!create && errno == ENOENT) return -2;
        if (error) *error = RBXOperationError(5, @"Operation fence directory cannot be opened safely");
        return -1;
    }
    struct stat info;
    if (fstat(directory, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != RBXFenceOwner() || (info.st_mode & 0077)) {
        close(directory);
        if (error) *error = RBXOperationError(5, @"Operation fence directory ownership or permissions are invalid");
        return -1;
    }
    return directory;
}

static NSDictionary *RBXReadOperationRecord(int directory, NSString *name, BOOL unsafe, NSError **error) {
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int saved = errno;
    if (fd < 0) {
        if (saved != ENOENT && error) *error = RBXOperationError(5, @"Operation safety fence cannot be read");
        return nil;
    }
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == RBXFenceOwner() &&
        !(info.st_mode & 0077) && info.st_nlink == 1 && info.st_size > 0 && info.st_size <= 16384;
    NSMutableData *bytes = [NSMutableData data];
    unsigned char buffer[4096];
    while (valid) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) break;
        [bytes appendBytes:buffer length:(NSUInteger)count];
        if (bytes.length > 16384) valid = NO;
    }
    close(fd);
    id record = valid ? [NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:NULL error:nil] : nil;
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"formatVersion"] isEqual:@1] ||
        ![record[@"unsafe"] isEqual:@(unsafe)] || ![record[@"requestID"] isKindOfClass:NSString.class] ||
        ![record[@"token"] isKindOfClass:NSString.class] || ![record[@"bootEpoch"] isKindOfClass:NSString.class] ||
        ![record[@"message"] isKindOfClass:NSString.class] || ![record[@"createdAt"] isKindOfClass:NSNumber.class]) {
        if (error) *error = RBXOperationError(5, @"Operation safety fence is corrupt; recovery is required");
        return nil;
    }
    return record;
}

static BOOL RBXWriteOperationRecord(NSDictionary *record, NSString *name, BOOL unsafe, NSError **error) {
    int directory = RBXOpenFenceDirectory(YES, error);
    if (directory < 0) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    NSString *temporary = [NSString stringWithFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = data.length && data.length <= 16384 ? openat(directory, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
    BOOL ok = fd >= 0;
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t count = write(fd, (const unsigned char *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (NSUInteger)count;
    }
    if (ok) ok = fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (ok) ok = renameat(directory, temporary.fileSystemRepresentation, directory, name.fileSystemRepresentation) == 0;
    if (ok) ok = fsync(directory) == 0;
    if (!ok) unlinkat(directory, temporary.fileSystemRepresentation, 0);
    if (ok) ok = [RBXReadOperationRecord(directory, name, unsafe, nil) isEqual:record];
    close(directory);
    if (!ok && error) *error = RBXOperationError(5, @"Operation journal could not be durably written and verified; effects are blocked");
    return ok;
}

static NSDictionary *RBXReadFence(NSError **error) {
    int directory = RBXOpenFenceDirectory(NO, error);
    if (directory < 0) return nil;
    NSDictionary *unsafe = RBXReadOperationRecord(directory, @"unsafe.plist", YES, error);
    if (unsafe || (error && *error)) { close(directory); return unsafe; }
    int listingFD = dup(directory);
    DIR *listing = listingFD >= 0 ? fdopendir(listingFD) : NULL;
    if (!listing) {
        if (listingFD >= 0) close(listingFD);
        close(directory);
        if (error) *error = RBXOperationError(5, @"Active operation journal cannot be enumerated");
        return nil;
    }
    NSDictionary *fence = nil;
    NSUInteger entries = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(listing);
        if (!entry) {
            if (errno && error) *error = RBXOperationError(5, @"Active operation journal enumeration failed");
            break;
        }
        if (++entries > 4096) {
            if (error) *error = RBXOperationError(5, @"Operation journal exceeds its bounded inspection limit; recovery is required");
            break;
        }
        NSString *name = [NSFileManager.defaultManager stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (![name hasPrefix:@"active-"] || ![name hasSuffix:@".plist"]) continue;
        NSDictionary *record = RBXReadOperationRecord(directory, name, NO, error);
        if (error && *error) break;
        if (!record) continue; // A same-process completed owner may just unlink it.
        NSString *expectedName = [NSString stringWithFormat:@"active-%@.plist", record[@"token"]];
        if (![name isEqual:expectedName] || ![[NSUUID alloc] initWithUUIDString:record[@"token"]]) {
            if (error) *error = RBXOperationError(5, @"Active operation journal identity is invalid");
            break;
        }
        if (![record[@"bootEpoch"] isEqual:RBXOperationContext.daemonBootEpoch]) {
            NSMutableDictionary *recovery = [record mutableCopy];
            recovery[@"unsafe"] = @YES;
            recovery[@"message"] = @"A previous daemon stopped with an active operation; verify owned work and recovery journals before continuing";
            fence = recovery;
            break;
        }
    }
    closedir(listing);
    close(directory);
    return fence;
}

@interface RBXOperationContext () {
    NSLock *_lock;
    NSLock *_markerLock;
    dispatch_group_t _work;
    NSUInteger _workCount;
    BOOL _cancelled, _sealed;
    BOOL _markerPublished;
    NSString *_cancelReason;
    NSMutableSet<NSURLSessionTask *> *_tasks;
    NSMutableSet<NSURLSession *> *_sessions;
    NSMutableDictionary<NSString *, dispatch_block_t> *_handlers;
    dispatch_source_t _deadlineTimer;
}
@property(nonatomic, readwrite, copy) NSString *requestID;
@property(nonatomic, readwrite, copy) NSString *token;
@property(nonatomic, readwrite, copy) NSString *bootEpoch;
@property(nonatomic, readwrite) NSTimeInterval deadlineMonotonic;
@property(nonatomic, readwrite) BOOL inspectionOnly;
@end

@implementation RBXOperationContext
+ (instancetype)contextWithRequestID:(NSString *)requestID bootEpoch:(NSString *)bootEpoch timeout:(NSTimeInterval)timeout {
    return [self contextWithRequestID:requestID bootEpoch:bootEpoch timeout:timeout inspectionOnly:NO];
}
+ (instancetype)contextWithRequestID:(NSString *)requestID bootEpoch:(NSString *)bootEpoch timeout:(NSTimeInterval)timeout inspectionOnly:(BOOL)inspectionOnly {
    RBXOperationContext *context = [self new];
    context.requestID = [requestID isKindOfClass:NSString.class] ? requestID : @"";
    context.token = NSUUID.UUID.UUIDString;
    context.bootEpoch = [bootEpoch isKindOfClass:NSString.class] && bootEpoch.length ? bootEpoch : self.daemonBootEpoch;
    context.inspectionOnly = inspectionOnly;
    context->_lock = [NSLock new];
    context->_markerLock = [NSLock new];
    context->_work = dispatch_group_create();
    context->_tasks = [NSMutableSet set];
    context->_sessions = [NSMutableSet set];
    context->_handlers = [NSMutableDictionary dictionary];
    NSTimeInterval now = RBXOperationNow();
    NSTimeInterval duration = isfinite(timeout) && timeout > 0 ? MIN(timeout, 3600.0) : 0;
    context.deadlineMonotonic = isfinite(now) ? now + duration : 0;
    if (duration <= 0 || !isfinite(now)) {
        [context cancelWithReason:@"Operation deadline is invalid or expired"];
    } else {
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, RBXOperationSupervisor());
        context->_deadlineTimer = timer;
        __weak RBXOperationContext *weakContext = context;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 0);
        dispatch_source_set_event_handler(timer, ^{ [weakContext cancelWithReason:@"Operation deadline expired"]; });
        dispatch_resume(timer);
    }
    return context;
}
+ (NSString *)daemonBootEpoch {
    static NSString *epoch;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ epoch = NSUUID.UUID.UUIDString; });
    return epoch;
}
+ (RBXOperationContext *)currentContext { return NSThread.currentThread.threadDictionary[RBXContextTLSKey]; }
- (void)performBlock:(dispatch_block_t)block {
    NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
    id previous = thread[RBXContextTLSKey];
    thread[RBXContextTLSKey] = self;
    @try { if (block) block(); }
    @finally { if (previous) thread[RBXContextTLSKey] = previous; else [thread removeObjectForKey:RBXContextTLSKey]; }
}
- (NSTimeInterval)remainingTime {
    [_lock lock]; BOOL stopped = _cancelled || _sealed; [_lock unlock];
    NSTimeInterval now = RBXOperationNow();
    return !stopped && isfinite(now) ? MAX(0, self.deadlineMonotonic - now) : 0;
}
- (BOOL)isCancelled { [_lock lock]; BOOL value = _cancelled; [_lock unlock]; return value; }
- (BOOL)check:(NSError **)error {
    NSTimeInterval now = RBXOperationNow();
    [_lock lock];
    BOOL sealed = _sealed;
    BOOL expired = !sealed && (!isfinite(now) || now >= self.deadlineMonotonic);
    [_lock unlock];
    if (expired) [self cancelWithReason:@"Operation deadline expired"];
    if (![self.bootEpoch isEqual:self.class.daemonBootEpoch])
        [self cancelWithReason:@"Operation belongs to a previous daemon boot"];
    [_lock lock]; BOOL canceled = _cancelled; NSString *reason = _cancelReason; [_lock unlock];
    if (sealed || canceled) {
        if (error) *error = RBXOperationError(sealed ? 3 : 1, reason ?: (sealed ? @"Operation has finished" : @"Operation was canceled"));
        return NO;
    }
    if (self.inspectionOnly) return YES;
    NSError *fenceError = nil;
    if ([self.class checkSafetyFence:&fenceError]) return YES;
    [self cancelWithReason:fenceError.localizedDescription];
    if (error) *error = fenceError;
    return NO;
}
- (BOOL)_ensureActiveMarker:(NSError **)error {
    if (self.inspectionOnly) return YES;
    [_markerLock lock];
    if (_markerPublished) { [_markerLock unlock]; return YES; }
    [_lock lock]; BOOL stopped = _sealed || _cancelled; [_lock unlock];
    if (stopped) {
        [_markerLock unlock];
        if (error) *error = RBXOperationError(1, @"Canceled work cannot establish new operation ownership");
        return NO;
    }
    NSString *name = [NSString stringWithFormat:@"active-%@.plist", self.token];
    NSDictionary *record = @{@"formatVersion": @1, @"unsafe": @NO, @"requestID": self.requestID,
        @"token": self.token, @"bootEpoch": self.bootEpoch, @"message": @"Operation is running",
        @"createdAt": @(NSDate.date.timeIntervalSince1970)};
    BOOL published = RBXWriteOperationRecord(record, name, NO, error);
    _markerPublished = published;
    [_lock lock]; stopped = _sealed || _cancelled; BOOL finishedQuiet = _sealed && !_workCount; [_lock unlock];
    [_markerLock unlock];
    if (!published) {
        [self cancelWithReason:@"Active operation marker could not be durably published"];
        return NO;
    }
    if (finishedQuiet) [self _removeActiveMarker];
    if (stopped && error) *error = RBXOperationError(1, @"Operation ended while ownership was being established");
    return !stopped;
}
- (void)_removeActiveMarker {
    if (self.inspectionOnly) return;
    [_markerLock lock];
    if (!_markerPublished) { [_markerLock unlock]; return; }
    NSError *error = nil;
    int directory = RBXOpenFenceDirectory(NO, &error);
    NSString *name = [NSString stringWithFormat:@"active-%@.plist", self.token];
    NSDictionary *record = directory >= 0 ? RBXReadOperationRecord(directory, name, NO, &error) : nil;
    BOOL ok = record && [record[@"token"] isEqual:self.token] && [record[@"bootEpoch"] isEqual:self.bootEpoch] &&
        unlinkat(directory, name.fileSystemRepresentation, 0) == 0 && fsync(directory) == 0;
    if (directory >= 0) close(directory);
    if (ok) _markerPublished = NO;
    [_markerLock unlock];
    if (!ok) [self markUnsafeWithReason:@"Completed operation ownership could not be durably retired; recovery is required" error:nil];
}
- (BOOL)beginWork:(NSError **)error {
    if (![self check:error]) return NO;
    if (![self _ensureActiveMarker:error]) return NO;
    [_lock lock];
    BOOL accepted = !_cancelled && !_sealed && RBXOperationNow() < self.deadlineMonotonic;
    if (accepted) { _workCount++; dispatch_group_enter(_work); }
    [_lock unlock];
    if (!accepted && error) *error = RBXOperationError(1, @"Operation ended before work could start");
    return accepted;
}
- (void)endWork {
    [_lock lock];
    BOOL balanced = _workCount > 0;
    if (balanced) { _workCount--; dispatch_group_leave(_work); }
    [_lock unlock];
    if (!balanced) [self markUnsafeWithReason:@"Operation work accounting was unbalanced; recovery is required" error:nil];
}
- (BOOL)beginCancellationCleanup {
    [_lock lock];
    BOOL accepted = _cancelled && !_sealed && !self.inspectionOnly;
    if (accepted) { _workCount++; dispatch_group_enter(_work); }
    [_lock unlock];
    return accepted;
}
- (void)cancelWithReason:(NSString *)reason {
    [_lock lock];
    if (_cancelled || _sealed) { [_lock unlock]; return; }
    _cancelled = YES;
    _cancelReason = [reason isKindOfClass:NSString.class] && reason.length ? [reason copy] : @"Operation was canceled";
    NSArray *tasks = _tasks.allObjects, *sessions = _sessions.allObjects, *handlers = _handlers.allValues;
    dispatch_source_t timer = _deadlineTimer;
    _deadlineTimer = nil;
    [_lock unlock];
    if (timer) dispatch_source_cancel(timer);
    // Never call external resource/child cancellation inline: an internal
    // framework lock must not delay another handler scheduling the watchdog.
    // Deliver each independently, without borrowing a caller's TLS owner.
    for (dispatch_block_t handler in handlers) [self _deliverCancellation:handler];
    for (NSURLSessionTask *task in tasks) [self _deliverCancellation:^{ [task cancel]; }];
    for (NSURLSession *session in sessions) [self _deliverCancellation:^{ [session invalidateAndCancel]; }];
}
- (void)_deliverCancellation:(dispatch_block_t)handler {
    dispatch_async(RBXOperationCancellationDelivery(), ^{
        @try { handler(); }
        @catch (NSException *exception) {
            [self markUnsafeWithReason:@"Operation cancellation handler failed; recovery is required" error:nil];
        }
    });
}
- (BOOL)waitForQuiescence:(NSTimeInterval)timeout {
    NSTimeInterval duration = isfinite(timeout) && timeout > 0 ? MIN(timeout, 3602.0) : 0;
    return dispatch_group_wait(_work, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC))) == 0;
}
- (void)finish {
    // Observe a deadline which fired just before a successful-looking finish.
    [self check:nil];
    [_lock lock];
    BOOL outstanding = _workCount != 0;
    _sealed = YES;
    dispatch_source_t timer = _deadlineTimer;
    _deadlineTimer = nil;
    NSArray *sessions = _sessions.allObjects;
    [_sessions removeAllObjects];
    [_handlers removeAllObjects];
    [_lock unlock];
    if (timer) dispatch_source_cancel(timer);
    for (NSURLSession *session in sessions) [session invalidateAndCancel];
    if (outstanding) [self markUnsafeWithReason:@"Operation was sealed before its work stopped; recovery is required" error:nil];
    else {
        BOOL fenced;
        @synchronized (RBXOperationContext.class) { fenced = RBXUnsafeInMemory != nil; }
        // An unsafe.plist write may have failed. Retain the already durable
        // active marker so a restart cannot silently forget this fence.
        if (!fenced) [self _removeActiveMarker];
    }
}
- (BOOL)sealCompletedWork {
    [_lock lock];
    BOOL accepted = !_sealed && !_cancelled && !_workCount &&
        RBXOperationNow() < self.deadlineMonotonic;
    dispatch_source_t timer = nil;
    if (accepted) { _sealed = YES; timer = _deadlineTimer; _deadlineTimer = nil; }
    [_lock unlock];
    if (timer) dispatch_source_cancel(timer);
    return accepted;
}
- (void)finishWhenQuiescent {
    dispatch_async(RBXOperationSupervisor(), ^{
        if (![self waitForQuiescence:self.remainingTime]) {
            [self cancelWithReason:@"Operation deadline expired"];
            if (![self waitForQuiescence:2.0]) [self markUnsafeWithReason:@"Canceled background work did not stop; recovery is required" error:nil];
        }
        [self finish];
    });
}
- (BOOL)dispatchAsyncOnQueue:(dispatch_queue_t)queue block:(dispatch_block_t)block {
    if (![self beginWork:nil]) return NO;
    dispatch_async(queue, ^{
        @try { [self performBlock:block]; }
        @catch (NSException *exception) { [self cancelWithReason:@"Operation worker raised an exception"]; }
        @finally { [self endWork]; }
    });
    return YES;
}
- (BOOL)dispatchAfter:(NSTimeInterval)delay queue:(dispatch_queue_t)queue block:(dispatch_block_t)block {
    if (![self beginWork:nil]) return NO;
    if (!isfinite(delay) || delay < 0 || delay > self.remainingTime) {
        [self endWork];
        [self cancelWithReason:@"The required delay does not fit within the operation deadline"];
        return NO;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), queue,
        ^{
            @try { [self performBlock:block]; }
            @catch (NSException *exception) { [self cancelWithReason:@"Operation worker raised an exception"]; }
            @finally { [self endWork]; }
        });
    return YES;
}
- (void)trackTask:(NSURLSessionTask *)task {
    if (!task) return;
    NSError *markerError = nil;
    if (![self check:&markerError] || ![self _ensureActiveMarker:&markerError])
        [self cancelWithReason:markerError.localizedDescription ?: @"HTTP task could not establish operation ownership"];
    [_lock lock];
    BOOL sealed = _sealed;
    BOOL cancel = _cancelled || sealed;
    if (![_tasks containsObject:task]) { [_tasks addObject:task]; _workCount++; dispatch_group_enter(_work); }
    [_lock unlock];
    if (cancel) [self _deliverCancellation:^{ [task cancel]; }];
    if (sealed) [self markUnsafeWithReason:@"An HTTP task escaped its finished operation; recovery is required" error:nil];
}
- (void)untrackTask:(NSURLSessionTask *)task {
    if (!task) return;
    [_lock lock];
    BOOL tracked = [_tasks containsObject:task];
    if (tracked) { [_tasks removeObject:task]; _workCount--; dispatch_group_leave(_work); }
    [_lock unlock];
}
- (void)trackSession:(NSURLSession *)session {
    if (!session) return;
    [_lock lock]; [_sessions addObject:session]; BOOL cancel = _cancelled || _sealed; [_lock unlock];
    if (cancel) [self _deliverCancellation:^{ [session invalidateAndCancel]; }];
}
- (void)untrackSession:(NSURLSession *)session { [_lock lock]; if (session) [_sessions removeObject:session]; [_lock unlock]; }
- (NSString *)registerCancellationHandler:(dispatch_block_t)handler {
    NSString *token = NSUUID.UUID.UUIDString;
    [_lock lock]; BOOL canceled = _cancelled || _sealed;
    if (!canceled && handler) _handlers[token] = [handler copy];
    [_lock unlock];
    if (canceled && handler) [self _deliverCancellation:handler];
    return token;
}
- (void)unregisterCancellationHandler:(NSString *)handlerToken {
    [_lock lock]; if (handlerToken) [_handlers removeObjectForKey:handlerToken]; [_lock unlock];
}
- (NSDictionary *)fenceInMemoryWithReason:(NSString *)reason {
    NSString *message = [reason isKindOfClass:NSString.class] && reason.length ? reason : @"Operation could not be proven stopped; recovery is required";
    if (message.length > 1024) message = [message substringToIndex:1024];
    NSDictionary *record = @{@"formatVersion": @1, @"unsafe": @YES, @"requestID": self.requestID,
        @"token": self.token, @"bootEpoch": self.bootEpoch, @"message": message,
        @"createdAt": @(NSDate.date.timeIntervalSince1970)};
    @synchronized (RBXOperationContext.class) { if (!RBXUnsafeInMemory) RBXUnsafeInMemory = record; else record = RBXUnsafeInMemory; }
    return record;
}
- (BOOL)markUnsafeWithReason:(NSString *)reason error:(NSError **)error {
    NSDictionary *record = [self fenceInMemoryWithReason:reason];
    BOOL ok = RBXWriteOperationRecord(record, @"unsafe.plist", YES, error);
    if (!ok && error) *error = RBXOperationError(5, @"Unsafe work is fenced in memory, but the persistent fence could not be verified; keep the daemon stopped for recovery");
    return ok;
}
+ (NSDictionary *)safetyFenceStatus {
    @synchronized (RBXOperationContext.class) { if (RBXUnsafeInMemory) return RBXUnsafeInMemory; }
    NSError *error = nil;
    NSDictionary *record = RBXReadFence(&error);
    if (error) return @{@"unsafe": @YES, @"message": error.localizedDescription, @"recoveryRequired": @YES};
    if (record) { @synchronized (RBXOperationContext.class) { RBXUnsafeInMemory = record; } }
    return record;
}
+ (BOOL)checkSafetyFence:(NSError **)error {
    NSDictionary *record = self.safetyFenceStatus;
    if (!record) return YES;
    if (error) *error = RBXOperationError(5, record[@"message"] ?: @"Unsafe previous operation requires recovery");
    return NO;
}
#ifdef RBX_OPERATION_TESTING
+ (void)setSafetyFenceDirectoryForTesting:(NSString *)directory {
    @synchronized (RBXOperationContext.class) { RBXFenceDirectory = [directory copy]; RBXUnsafeInMemory = nil; }
}
#endif
- (void)dealloc { if (_deadlineTimer) dispatch_source_cancel(_deadlineTimer); }
@end
