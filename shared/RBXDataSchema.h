#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import "RBXAppLifecycle.h"

// Shared by daemon, preference panes, and injected readers. Unknown fields are
// preserved. A missing version is the original version 1, never a fresh store.
#define RBX_STORE_SCHEMA_VERSION 2
#define RBX_PROFILE_SCHEMA_VERSION 2
typedef NS_ENUM(NSInteger, RBXDataDocumentKind) { RBXDataStore, RBXDataProfile };

static inline NSError *RBXSchemaError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.data-schema" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}
static inline BOOL RBXSchemaInteger(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]) && [value doubleValue] == floor([value doubleValue]);
}
static inline NSInteger RBXSchemaReadVersion(NSDictionary *document, NSString *key,
                                            NSInteger current, BOOL legacy, NSError **error) {
    id value = document[key];
    if (!value && legacy) return 1;
    if (!RBXSchemaInteger(value) || [value integerValue] < 1) {
        if (error) *error = RBXSchemaError([NSString stringWithFormat:@"%@ is corrupt; original data retained", key]);
        return 0;
    }
    NSInteger version = [value integerValue];
    if (version > current) {
        if (error) *error = RBXSchemaError([NSString stringWithFormat:
            @"%@ %ld is newer than this build supports (%ld). Install the matching or newer build; original data retained",
            key, (long)version, (long)current]);
        return 0;
    }
    return version;
}
static inline BOOL RBXSchemaFields(id dictionary, NSArray *keys, Class type) {
    if (![dictionary isKindOfClass:NSDictionary.class]) return dictionary == nil;
    for (NSString *key in keys) if (dictionary[key] && ![dictionary[key] isKindOfClass:type]) return NO;
    return YES;
}
static inline BOOL RBXSchemaValidate(id document, RBXDataDocumentKind kind, NSError **error) {
    if (![document isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXSchemaError(@"Data document is corrupt; expected an object and retained original bytes");
        return NO;
    }
    NSString *versionKey = kind == RBXDataStore ? @"storeVersion" : @"profileVersion";
    if (!RBXSchemaReadVersion(document, versionKey, 2, YES, error)) return NO;
    BOOL valid = YES;
    if (kind == RBXDataStore) {
        valid = RBXSchemaFields(document, @[@"device", @"containers", @"health", @"replacements", @"identityReservations"], NSDictionary.class) &&
            RBXSchemaFields(document, @[@"alerts", @"requests"], NSArray.class);
        if (valid) for (id key in document[@"containers"]) {
            id entry = document[@"containers"][key];
            if (![key isKindOfClass:NSString.class] || ![entry isKindOfClass:NSDictionary.class] ||
                !RBXSchemaFields(entry, @[@"attest", @"push", @"fingerprint", @"lastHealth"], NSDictionary.class)) { valid = NO; break; }
        }
        if (valid) for (NSString *section in @[@"alerts", @"requests"])
            for (id entry in document[section]) if (![entry isKindOfClass:NSDictionary.class]) valid = NO;
        if (valid && !RBXSchemaFields(document[@"device"], @[@"attestKeysUsed"], NSArray.class)) valid = NO;
        if (valid) for (id entry in document[@"device"][@"attestKeysUsed"])
            if (![entry isKindOfClass:NSDictionary.class]) valid = NO;
        if (valid) for (id key in document[@"identityReservations"])
            if (![key isKindOfClass:NSString.class] || [key length] != 64 ||
                ![document[@"identityReservations"][key] isKindOfClass:NSString.class]) valid = NO;
        if (valid) for (id key in document[@"replacements"]) {
            id entry = document[@"replacements"][key];
            NSInteger replacementVersion = 1;
            if ([entry isKindOfClass:NSDictionary.class] && entry[@"appType"] &&
                ![entry[@"appType"] isEqual:@"reddit"]) {
                if (!RBXAppReplacementJournalDescriptor(entry)) {
                    if(error)*error=RBXSchemaError(@"Replacement app ownership is invalid; original bytes retained");
                    return NO;
                }
                replacementVersion = 2;
            }
            if (![entry isKindOfClass:NSDictionary.class] ||
                !RBXSchemaReadVersion(entry, @"formatVersion", replacementVersion, NO, error)) return NO;
            if (![entry[@"oldId"] isEqual:key] || ![entry[@"newId"] isKindOfClass:NSString.class] ||
                ![@[@"prepared", @"created", @"rotated", @"deleting", @"committed"] containsObject:entry[@"phase"]]) valid = NO;
        }
    } else {
        valid = [document[@"containerId"] isKindOfClass:NSString.class] && [document[@"containerId"] length] &&
            RBXSchemaFields(document, @[@"device", @"serials", @"ids", @"timing", @"security", @"proxy", @"reddit", @"validation", @"mgOverrides", @"app", @"identityCustomization"], NSDictionary.class) &&
            RBXSchemaFields(document, @[@"role", @"notes"], NSString.class);
        if (valid && document[@"metadataRevision"] &&
            (!RBXSchemaInteger(document[@"metadataRevision"]) || [document[@"metadataRevision"] longLongValue] < 0)) valid = NO;
    }
    if (!valid && error) *error = RBXSchemaError(@"Data document has a corrupt section; original data retained");
    return valid;
}
static inline NSMutableDictionary *RBXSchemaMigrate(NSDictionary *document, RBXDataDocumentKind kind, NSError **error) {
    if (!RBXSchemaValidate(document, kind, error)) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:0 error:error];
    NSMutableDictionary *next = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] : nil;
    NSString *key = kind == RBXDataStore ? @"storeVersion" : @"profileVersion";
    NSInteger version = next[key] ? [next[key] integerValue] : 1;
    while (next && version < 2) {
        // 1 -> 2 introduces explicit metadata defaults. Identity, IDs, login,
        // proxy, journals, reservations and unknown fields remain untouched.
        if (kind == RBXDataProfile) {
            if (!next[@"role"]) next[@"role"] = @"default";
            if (!next[@"notes"]) next[@"notes"] = @"";
            if (!next[@"metadataRevision"]) next[@"metadataRevision"] = @0;
        }
        next[key] = @(++version);
    }
    return next;
}
static inline NSData *RBXSchemaReadBytes(NSString *path, BOOL *missing, NSError **error) {
    if (missing) *missing = NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) {
        if (errno == ENOENT) { if (missing) *missing = YES; return nil; }
        if (error) *error = RBXSchemaError(@"Data file cannot be read safely; original data retained");
        return nil;
    }
    struct stat info;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 &&
        info.st_size > 0 && info.st_size <= 32 * 1024 * 1024;
    NSMutableData *data = [NSMutableData data]; unsigned char buffer[16384];
    while (valid) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { valid = NO; break; }
        if (!count) break;
        [data appendBytes:buffer length:(NSUInteger)count];
        if (data.length > 32 * 1024 * 1024) valid = NO;
    }
    close(fd);
    if (!valid || !data.length) {
        if (error) *error = RBXSchemaError(@"Data file is empty, corrupt or unsafe; original data retained");
        return nil;
    }
    return data;
}
static inline NSDictionary *RBXSchemaDecode(NSData *data, RBXDataDocumentKind kind, NSError **error) {
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] : nil;
    return RBXSchemaValidate(value, kind, error) ? value : nil;
}
// Every writer uses the same stable lock, checks the existing version under it,
// and stages complete bytes before atomic rename. Migration supplies expected
// bytes so an intervening publication is retried instead of overwritten.
static inline BOOL RBXSchemaWriteJSONCompared(NSDictionary *document, NSString *path,
        RBXDataDocumentKind kind, NSData *expected, BOOL expectMissing, NSError **error) {
    NSMutableDictionary *next = RBXSchemaMigrate(document, kind, error);
    NSData *json = next ? [NSJSONSerialization dataWithJSONObject:next options:NSJSONWritingSortedKeys error:error] : nil;
    if (!json) return NO;
    NSString *lockPath = [path stringByAppendingString:@".schema-lock"];
    int lock = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0666);
    struct stat lockInfo;
    BOOL ok = lock >= 0 && fstat(lock, &lockInfo) == 0 && S_ISREG(lockInfo.st_mode) &&
        lockInfo.st_nlink == 1 && flock(lock, LOCK_EX | LOCK_NB) == 0;
    if (!ok) {
        if (lock >= 0) close(lock);
        if (error) *error = RBXSchemaError(@"Another data publication is running or its lock is unsafe; retry");
        return NO;
    }
    if (geteuid() == 0) fchmod(lock, 0666);
    BOOL missing = NO;
    NSData *old = RBXSchemaReadBytes(path, &missing, error);
    NSDictionary *existing = old ? RBXSchemaDecode(old, kind, error) : nil;
    ok = (missing || existing);
    if (ok && ((expectMissing && !missing) || (expected && ![old isEqual:expected]))) {
        ok = NO;
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.data-schema" code:2
            userInfo:@{NSLocalizedDescriptionKey:@"Data changed after it was read; original data retained and operation must be retried"}];
    }
    if (ok && existing && kind == RBXDataProfile &&
        ![existing[@"containerId"] isEqual:next[@"containerId"]]) ok = NO;
    if (!ok && error && !*error) *error = RBXSchemaError(@"Data changed after preflight; retained both versions and retry required");
    NSString *temporary = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%@.tmp", path.lastPathComponent, NSUUID.UUID.UUIDString]];
    struct stat oldInfo; BOOL existed = lstat(path.fileSystemRepresentation, &oldInfo) == 0;
    int fd = ok ? open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) : -1;
    if (ok) ok = fd >= 0;
    NSUInteger offset = 0;
    while (ok && offset < json.length) {
        ssize_t count = write(fd, (const char *)json.bytes + offset, json.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += (NSUInteger)count;
    }
    if (ok) ok = fchmod(fd, existed ? oldInfo.st_mode & 0777 : 0644) == 0;
    if (ok && existed && geteuid() == 0) ok = fchown(fd, oldInfo.st_uid, oldInfo.st_gid) == 0;
    if (ok) ok = fsync(fd) == 0;
    if (fd >= 0 && close(fd) != 0) ok = NO;
    if (ok) ok = rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (ok) {
        int parent = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        ok = parent >= 0 && fsync(parent) == 0;
        if (parent >= 0) close(parent);
    }
    if (ok) ok = [RBXSchemaReadBytes(path, NULL, error) isEqual:json];
    if (!ok) {
        unlink(temporary.fileSystemRepresentation);
        if (error && !*error) *error = RBXSchemaError(@"Atomic data publication or verification failed; retain data and retry");
    }
    flock(lock, LOCK_UN); close(lock);
    return ok;
}
static inline BOOL RBXSchemaWriteJSONExpected(NSDictionary *document, NSString *path,
        RBXDataDocumentKind kind, NSData *expected, NSError **error) {
    return RBXSchemaWriteJSONCompared(document, path, kind, expected, NO, error);
}
static inline BOOL RBXSchemaWriteJSON(NSDictionary *document, NSString *path, RBXDataDocumentKind kind, NSError **error) {
    return RBXSchemaWriteJSONExpected(document, path, kind, nil, error);
}
