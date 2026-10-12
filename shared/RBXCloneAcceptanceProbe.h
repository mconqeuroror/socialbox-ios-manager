#pragma once
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <limits.h>
#import <stdlib.h>

// OS-008/009/033/035. Operator-requested canaries, never an automatic launch
// prerequisite. No caller-selected filenames, executable commands or app data.
typedef struct {
    OSStatus (*add)(CFDictionaryRef, CFTypeRef *);
    OSStatus (*copy)(CFDictionaryRef, CFTypeRef *);
    OSStatus (*remove)(CFDictionaryRef);
    // Optional own-domain marker, only during the explicitly requested SSH seed/cleanup.
    BOOL (*defaultsCanary)(NSString *nonce, BOOL cleanup);
} RBXAcceptanceSecurity;

static inline BOOL RBXAcceptanceUUID(id value) {
    return [value isKindOfClass:NSString.class] && [value length] == 36 &&
        [[[[NSUUID alloc] initWithUUIDString:value] UUIDString] isEqual:value];
}
static inline BOOL RBXAcceptanceBundle(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 180 ||
        ![value hasPrefix:@"com.redditbox.profile.p"] || [value length] <= 22) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}
static inline int RBXAcceptanceDirectory(int parent, NSString *component) {
    return openat(parent, component.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}
static inline int RBXAcceptanceDescend(int parent, NSArray<NSString *> *components) {
    int fd = dup(parent);
    for (NSString *component in components) {
        int next = fd < 0 ? -1 : RBXAcceptanceDirectory(fd, component);
        int saved = errno; if (fd >= 0) close(fd); fd = next; errno = saved;
        if (fd < 0) break;
    }
    return fd;
}
static inline BOOL RBXAcceptanceDirectoryOwner(int fd, uid_t owner, mode_t forbidden) {
    struct stat st;
    return fd >= 0 && !fstat(fd, &st) && S_ISDIR(st.st_mode) &&
        st.st_uid == owner && !(st.st_mode & forbidden);
}
static inline NSData *RBXAcceptanceRead(int dir, NSString *name, uid_t owner, NSUInteger limit) {
    int fd = openat(dir, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
        st.st_uid != owner || (st.st_mode & 0022) || st.st_size < 0 || (uint64_t)st.st_size > limit) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return nil; }
        offset += (NSUInteger)n;
    }
    char extra; ssize_t trailing = read(fd, &extra, 1);
    close(fd);
    return trailing == 0 ? data : nil;
}
static inline BOOL RBXAcceptanceWrite(int fd, NSData *data) {
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t n = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        offset += (NSUInteger)n;
    }
    return fsync(fd) == 0;
}
static inline BOOL RBXAcceptancePublish(int dir, NSString *name, NSDictionary *report) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
    if (!data || data.length > 16384) return NO;
    NSString *temporary = [@".probe-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(dir, temporary.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return NO;
    BOOL ok = RBXAcceptanceWrite(fd, data); close(fd);
    // linkat cannot replace an existing result or follow a destination symlink.
    if (ok) ok = linkat(dir, temporary.fileSystemRepresentation, dir, name.fileSystemRepresentation, 0) == 0;
    unlinkat(dir, temporary.fileSystemRepresentation, 0);
    if (ok) fsync(dir);
    return ok;
}
static inline NSDictionary *RBXAcceptanceCheck(NSString *identifier, NSArray *rows,
                                               NSString *status, NSString *detail, NSInteger code) {
    return @{@"id": identifier, @"surfaceRows": rows, @"status": status,
             @"detail": detail, @"statusCode": @(code)};
}
static inline BOOL RBXAcceptanceRequest(id request, NSString *bundle, NSString *ownUUID, NSTimeInterval now) {
    NSArray *keys = @[@"schemaVersion", @"nonce", @"operation", @"targetBundleId",
        @"sourceBundleId", @"sourceDataUUID", @"expiresAt"];
    if (![request isKindOfClass:NSDictionary.class] || [request count] != keys.count) return NO;
    for (id key in request) if (![keys containsObject:key]) return NO;
    if (![request[@"schemaVersion"] isEqual:@1] || !RBXAcceptanceUUID(request[@"nonce"]) ||
        !RBXAcceptanceUUID(ownUUID) || !RBXAcceptanceUUID(request[@"sourceDataUUID"]) ||
        !RBXAcceptanceBundle(bundle) || ![request[@"targetBundleId"] isEqual:bundle] ||
        !RBXAcceptanceBundle(request[@"sourceBundleId"]) ||
        ![@[@"seed", @"verify", @"cleanup"] containsObject:request[@"operation"]] ||
        ![request[@"expiresAt"] isKindOfClass:NSNumber.class]) return NO;
    double expiry = [request[@"expiresAt"] doubleValue];
    if (!isfinite(expiry) || expiry <= now || expiry > now + 86400) return NO;
    BOOL ownBundle = [request[@"sourceBundleId"] isEqual:bundle];
    BOOL ownPath = [request[@"sourceDataUUID"] isEqual:ownUUID];
    return [request[@"operation"] isEqual:@"verify"] ? (!ownBundle && !ownPath) : (ownBundle && ownPath);
}

// Nonces are public test data. No token, user ID, item contents or arbitrary
// filesystem contents are included in the receipt.
static inline OSStatus RBXAcceptanceReadKey(RBXAcceptanceSecurity api, NSDictionary *identity,
                                           NSString *group, NSData *expected, BOOL *matches) {
    NSMutableDictionary *query = identity.mutableCopy;
    if (group) query[(__bridge id)kSecAttrAccessGroup] = group;
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef value = NULL;
    OSStatus status = api.copy((__bridge CFDictionaryRef)query, &value);
    *matches = status == errSecSuccess && value &&
        CFGetTypeID(value) == CFDataGetTypeID() && [(__bridge NSData *)value isEqual:expected];
    if (value) CFRelease(value);
    return status;
}

// The production caller supplies the actual clone home/bundle/uid/pid and the
// constant iOS container root/root request owner. Parameters permit host fixtures
// to exercise this same implementation with fake Security, never real secrets.
static inline BOOL RBXAcceptanceRun(NSString *home, NSString *bundle, NSString *ownGroup,
    NSString *containerRoot, uid_t requestOwner, uid_t processUID, pid_t processPID,
    NSTimeInterval now, RBXAcceptanceSecurity api) {
    if (!RBXAcceptanceBundle(bundle) || ![ownGroup isEqual:[@"RBXCLONE00." stringByAppendingString:bundle]] ||
        !api.add || !api.copy || !api.remove) return NO;
    char resolved[PATH_MAX];
    if (!realpath(home.fileSystemRepresentation, resolved)) return NO;
    NSString *canonical = [NSString stringWithUTF8String:resolved];
    if (![[canonical stringByDeletingLastPathComponent] isEqual:containerRoot]) return NO;
    int homeFD = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (homeFD < 0) return NO;
    int dir = RBXAcceptanceDescend(homeFD, @[@"Library", @"Application Support", @"RedditBox", @"acceptance"]);
    if (!RBXAcceptanceDirectoryOwner(dir, requestOwner, 0022)) { if (dir >= 0) close(dir); close(homeFD); return NO; }
    NSData *requestBytes = RBXAcceptanceRead(dir, @"request.json", requestOwner, 4096);
    id request = requestBytes ? [NSJSONSerialization JSONObjectWithData:requestBytes options:0 error:nil] : nil;
    if (!RBXAcceptanceRequest(request, bundle, canonical.lastPathComponent, now)) { close(dir); close(homeFD); return NO; }
    int results = RBXAcceptanceDirectory(dir, @"results"); close(dir);
    if (!RBXAcceptanceDirectoryOwner(results, processUID, 0077)) { if (results >= 0) close(results); close(homeFD); return NO; }
    NSString *nonce = request[@"nonce"], *operation = request[@"operation"];
    NSString *receiptName = [NSString stringWithFormat:@"%@-%@.json", nonce, operation];
    struct stat existing;
    if (!fstatat(results, receiptName.fileSystemRepresentation, &existing, AT_SYMLINK_NOFOLLOW) || errno != ENOENT) {
        close(results); close(homeFD); return NO;
    }
    int prefs = RBXAcceptanceDirectory(homeFD, @"Library");
    int prefFiles = prefs < 0 ? -1 : RBXAcceptanceDirectory(prefs, @"Preferences");
    if (prefs >= 0) close(prefs);
    NSData *readyData = prefFiles < 0 ? nil : RBXAcceptanceRead(prefFiles, @"com.redditbox.hook-ready.plist", processUID, 65536);
    if (prefFiles >= 0) close(prefFiles);
    id ready = readyData ? [NSPropertyListSerialization propertyListWithData:readyData options:0 format:NULL error:nil] : nil;
    close(homeFD);
    if (![ready isKindOfClass:NSDictionary.class] || ![ready[@"bundleIdentifier"] isEqual:bundle] ||
        ![ready[@"allHooksInstalled"] isEqual:@YES] ||
        ![ready[@"pid"] isEqual:@(processPID)] || ![ready[@"generation"] isKindOfClass:NSString.class] ||
        ![ready[@"bootEpoch"] isKindOfClass:NSString.class] || [ready[@"generation"] length] > 128 ||
        [ready[@"bootEpoch"] length] > 128 || ![ready[@"generation"] length] || ![ready[@"bootEpoch"] length] ||
        ![ready[@"timestamp"] isKindOfClass:NSNumber.class] || !isfinite([ready[@"timestamp"] doubleValue]) ||
        fabs(now - [ready[@"timestamp"] doubleValue]) > 300) { close(results); return NO; }
    NSData *value = [nonce dataUsingEncoding:NSUTF8StringEncoding];
    NSString *sentinel = [nonce stringByAppendingString:@".sentinel"];
    NSDictionary *identity = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.redditbox.acceptance.canary.v1",
        (__bridge id)kSecAttrAccount: nonce, (__bridge id)kSecAttrSynchronizable: @NO};
    NSMutableArray *checks = [NSMutableArray array];
    BOOL matches = NO; OSStatus status;
    if ([operation isEqual:@"seed"]) {
        NSMutableDictionary *add = identity.mutableCopy;
        add[(__bridge id)kSecValueData] = value;
        add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = api.add((__bridge CFDictionaryRef)add, NULL);
        OSStatus readStatus = RBXAcceptanceReadKey(api, identity, nil, value, &matches);
        [checks addObject:RBXAcceptanceCheck(@"keychain-seed-default", @[@"OS-009"],
            status == errSecSuccess && readStatus == errSecSuccess && matches ? @"PASS" : @"FAIL",
            @"New local canary added and read in the clone default namespace", status ?: readStatus)];
        status = RBXAcceptanceReadKey(api, identity, ownGroup, value, &matches);
        [checks addObject:RBXAcceptanceCheck(@"keychain-seed-own-group", @[@"OS-008"],
            status == errSecSuccess && matches ? @"PASS" : @"FAIL", @"Own explicit group reads the same test canary", status)];
        int fd = openat(results, sentinel.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        int code = fd < 0 ? errno : 0;
        BOOL wrote = fd >= 0 && RBXAcceptanceWrite(fd, value); if (fd >= 0) close(fd);
        BOOL readBack = [RBXAcceptanceRead(results, sentinel, processUID, 128) isEqual:value];
        [checks addObject:RBXAcceptanceCheck(@"storage-seed", @[@"OS-033", @"OS-035"],
            wrote && readBack ? @"PASS" : @"FAIL", @"New nonce sentinel created and read in own sandbox", code)];
    } else if ([operation isEqual:@"verify"]) {
        status = RBXAcceptanceReadKey(api, identity, nil, value, &matches);
        [checks addObject:RBXAcceptanceCheck(@"keychain-default-absent", @[@"OS-009"],
            status == errSecItemNotFound ? @"PASS" : @"FAIL", @"A test canary absent from B default namespace", status)];
        NSString *foreignGroup = [@"RBXCLONE00." stringByAppendingString:request[@"sourceBundleId"]];
        status = RBXAcceptanceReadKey(api, identity, foreignGroup, value, &matches);
        [checks addObject:RBXAcceptanceCheck(@"keychain-foreign-group-denied", @[@"OS-008"],
            status == errSecMissingEntitlement ? @"PASS" : @"FAIL", @"Explicit A access group denied to B", status)];
        int fd = openat(results, sentinel.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
        int code = fd < 0 ? errno : 0; if (fd >= 0) close(fd);
        [checks addObject:RBXAcceptanceCheck(@"storage-own-absent", @[@"OS-033"],
            code == ENOENT ? @"PASS" : @"FAIL", @"A nonce sentinel absent in B own sandbox", code)];
        NSString *foreign = [containerRoot stringByAppendingPathComponent:request[@"sourceDataUUID"]];
        int foreignHome = open(foreign.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int foreignResults = foreignHome < 0 ? -1 : RBXAcceptanceDescend(foreignHome,
            @[@"Library", @"Application Support", @"RedditBox", @"acceptance", @"results"]);
        code = foreignHome < 0 || foreignResults < 0 ? errno : 0;
        if (foreignHome >= 0) close(foreignHome);
        if (foreignResults >= 0) {
            fd = openat(foreignResults, sentinel.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            code = fd < 0 ? errno : 0;
            if (fd >= 0) close(fd); close(foreignResults);
        }
        [checks addObject:RBXAcceptanceCheck(@"storage-foreign-denied", @[@"OS-033", @"OS-035"],
            code == EACCES || code == EPERM ? @"PASS" : (code == ENOENT ? @"NOT_RUN" : @"FAIL"),
            @"Foreign path must be access-denied; missing A seed is not isolation evidence", code)];
    } else {
        status = RBXAcceptanceReadKey(api, identity, nil, value, &matches);
        BOOL absent = status == errSecItemNotFound;
        [checks addObject:RBXAcceptanceCheck(@"keychain-before-cleanup", @[@"OS-008", @"OS-009"],
            status == errSecSuccess && matches ? @"PASS" : (absent ? @"NOT_RUN" : @"FAIL"),
            @"A still holds the exact seeded canary after B verification, before deletion", status)];
        if (status == errSecSuccess && matches) status = api.remove((__bridge CFDictionaryRef)identity);
        BOOL removed = absent || (matches && status == errSecSuccess);
        if (removed) status = RBXAcceptanceReadKey(api, identity, nil, value, &matches);
        [checks addObject:RBXAcceptanceCheck(@"keychain-cleanup", @[@"OS-009"],
            removed && status == errSecItemNotFound ? @"PASS" : @"FAIL",
            @"Only own service and nonce account removed after matching test bytes", status)];
        NSData *stored = RBXAcceptanceRead(results, sentinel, processUID, 128);
        int code = 0; BOOL cleaned = NO;
        if ([stored isEqual:value]) { cleaned = unlinkat(results, sentinel.fileSystemRepresentation, 0) == 0; code = cleaned ? 0 : errno; }
        else {
            cleaned = fstatat(results, sentinel.fileSystemRepresentation, &existing, AT_SYMLINK_NOFOLLOW) < 0 && errno == ENOENT;
            code = cleaned ? ENOENT : EINVAL;
        }
        [checks addObject:RBXAcceptanceCheck(@"storage-cleanup", @[@"OS-033", @"OS-035"],
            cleaned ? @"PASS" : @"FAIL", @"Only own nonce sentinel removed after content and ownership validation", code)];
    }
    BOOL defaultsSeeded = NO;
    if (api.defaultsCanary && ([operation isEqual:@"seed"] || [operation isEqual:@"cleanup"]))
        defaultsSeeded = api.defaultsCanary(nonce, [operation isEqual:@"cleanup"]);
    NSTimeInterval completedAt = NSDate.date.timeIntervalSince1970;
    // A stalled Security provider does not extend operator authorization. Exact
    // partial canaries may need a later explicit cleanup request.
    if (completedAt > [request[@"expiresAt"] doubleValue]) { close(results); return NO; }
    NSDictionary *report = @{@"schemaVersion": @1, @"nonce": nonce, @"operation": operation,
        @"bundleIdentifier": bundle, @"pid": @(processPID), @"uid": @(processUID),
        @"timestamp": @(completedAt), @"generation": ready[@"generation"],
        @"bootEpoch": ready[@"bootEpoch"], @"checks": checks, @"defaultsSeeded": @(defaultsSeeded && [operation isEqual:@"seed"])};
    BOOL published = RBXAcceptancePublish(results, receiptName, report); close(results);
    return published;
}
