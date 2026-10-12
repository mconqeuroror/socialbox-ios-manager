#import "RBXCentralStore.h"
#import "RBXDataSchema.h"
#ifdef RBX_DAEMON_OPERATION_CONTEXT
#import "RBXOperationContext.h"
#endif
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <errno.h>
#import <fcntl.h>
#import <unistd.h>

// Central store implementation. Concurrency model:
//  - reads/writes through this instance serialize on its queue.
//  - publication uses the shared schema lock and an atomic complete replacement.
//    Expected bytes bind each read-modify-write to the document it read; a
//    concurrent publication fails this operation instead of erasing its fields.
//    Darwin notification refreshes readers; it is not a transaction boundary.

static NSString *const kStorePath =
    @"/var/mobile/Library/Preferences/com.redditbox.store.json";
static NSString *const kStoreChangedNotification = @"com.redditbox.storeChanged";

static const NSInteger kMaxAlerts = 100;
static const NSInteger kMaxRequests = 500;

static NSMutableDictionary *RBXDeepMutable(id value);
static NSMutableDictionary *RBXMutableContainerEntry(NSMutableDictionary *doc, NSString *containerId);

@implementation RBXCentralStore {
    dispatch_queue_t _queue;
}

+ (NSString *)storePath {
    return kStorePath;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.redditbox.centralstore", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (instancetype)sharedStore {
    static RBXCentralStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

#pragma mark - Document

- (NSMutableDictionary *)_readLockedWithError:(NSError **)error {
    return [self _readLockedWithError:error bytes:NULL];
}

- (NSMutableDictionary *)_readLockedWithError:(NSError **)error bytes:(NSData **)bytes {
    BOOL missing = NO;
    NSData *data = RBXSchemaReadBytes(self.class.storePath, &missing, error);
    if (bytes) *bytes = data;
    if (missing) return [self _defaultDocument];
    NSMutableDictionary *document = [RBXSchemaDecode(data, RBXDataStore, error) mutableCopy];
    if (document) [self _backfillDefaults:document];
    return document;
}

- (NSMutableDictionary *)_defaultDocument {
    return [@{
        @"storeVersion": @(RBX_STORE_SCHEMA_VERSION),
        @"device": [@{
            @"attestKeysUsed": [NSMutableArray array],
            @"keyBudget": @100,
            @"attestDefault": @"on",
        } mutableCopy],
        @"containers": [NSMutableDictionary dictionary],
        @"health": [@{
            @"intervalSeconds": @(6 * 60 * 60),
            @"calibrationMode": @NO,
            @"calibration": [@{
                @"200": @"healthy",
                @"403": @"suspended",
                @"404": @"shadowbanned",
            } mutableCopy],
        } mutableCopy],
        @"alerts": [NSMutableArray array],
        @"requests": [NSMutableArray array],
    } mutableCopy];
}

- (void)_backfillDefaults:(NSMutableDictionary *)doc {
    NSMutableDictionary *defaults = [self _defaultDocument];
    for (NSString *key in defaults) {
        if ([key isEqual:@"storeVersion"]) continue; // Missing is legacy 1 until explicit migration.
        if (doc[key] == nil || [NSNull null] == doc[key]) {
            doc[key] = defaults[key];
        }
    }
}

- (BOOL)_writeLocked:(NSMutableDictionary *)doc expected:(NSData *)expected error:(NSError **)error {
#ifdef RBX_DAEMON_OPERATION_CONTEXT
    RBXOperationContext *context = [RBXOperationContext currentContext];
    if (context && ![context check:error]) return NO;
#endif
    if (!RBXSchemaWriteJSONCompared(doc, self.class.storePath, RBXDataStore, expected, !expected, error)) return NO;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kStoreChangedNotification,
        NULL, NULL, TRUE);
    return YES;
}

- (NSMutableDictionary *)dictionaryWithError:(NSError **)error {
    __block NSMutableDictionary *result = nil;
    __block NSError *failure = nil;
    dispatch_sync(_queue, ^{ result = [self _readLockedWithError:&failure]; });
    if (!result && error) *error = failure;
    return result;
}

- (NSMutableDictionary *)dictionary {
    NSError *error = nil;
    NSMutableDictionary *document = [self dictionaryWithError:&error];
    if (!document) NSLog(@"redditboxd: data schema blocked: %@", error.localizedDescription);
    return document;
}

- (void)update:(void (^)(NSMutableDictionary *doc))block {
    NSError *error = nil;
    if (![self update:block error:&error])
        NSLog(@"redditboxd: central store publication failed: %@", error.localizedDescription);
}

- (BOOL)update:(void (^)(NSMutableDictionary *doc))block error:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
#ifdef RBX_DAEMON_OPERATION_CONTEXT
    RBXOperationContext *context = [RBXOperationContext currentContext];
#endif
    dispatch_block_t mutation = ^{
#ifdef RBX_DAEMON_OPERATION_CONTEXT
        if (context && ![context check:&failure]) return;
#endif
        NSData *expected = nil;
        NSMutableDictionary *doc = [self _readLockedWithError:&failure bytes:&expected];
        if (!doc) return;
        if (block) block(doc);
        ok = [self _writeLocked:doc expected:expected error:&failure];
    };
    dispatch_sync(_queue, ^{
#ifdef RBX_DAEMON_OPERATION_CONTEXT
        if (context) [context performBlock:mutation]; else mutation();
#else
        mutation();
#endif
    });
    if (!ok && error) *error = failure;
    return ok;
}

- (void)addAlertType:(NSString *)type
         containerId:(NSString *)containerId
             message:(NSString *)message {
    [self update:^(NSMutableDictionary *doc) {
        NSMutableArray *alerts = [doc[@"alerts"] isKindOfClass:[NSArray class]] ?
            [doc[@"alerts"] mutableCopy] : [NSMutableArray array];
        [alerts addObject:@{
            @"type": type ?: @"",
            @"containerId": containerId ?: @"",
            @"message": message ?: @"",
            @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
        }];
        if (alerts.count > kMaxAlerts) {
            [alerts removeObjectsInRange:NSMakeRange(0, alerts.count - kMaxAlerts)];
        }
        doc[@"alerts"] = alerts;
    }];
}

- (BOOL)hasAlertType:(NSString *)type containerId:(NSString *)containerId {
    NSMutableDictionary *doc = self.dictionary;
    for (NSDictionary *a in (doc[@"alerts"] ?: @[])) {
        NSString *t = a[@"type"];
        NSString *c = a[@"containerId"] ?: @"";
        if ([t isEqualToString:type] && [c isEqualToString:(containerId ?: @"")]) {
            return YES;
        }
    }
    return NO;
}

- (NSArray<NSDictionary *> *)alerts {
    return self.dictionary[@"alerts"] ?: @[];
}

#pragma mark - Requests ring buffer

- (void)addRequestForContainer:(NSString *)containerId
                          host:(NSString *)host
                       proxyId:(NSString *)proxyId {
    [self update:^(NSMutableDictionary *doc) {
        NSMutableArray *requests = [doc[@"requests"] isKindOfClass:[NSArray class]] ?
            [doc[@"requests"] mutableCopy] : [NSMutableArray array];
        [requests addObject:@{
            @"containerId": containerId ?: @"",
            @"host": host ?: @"",
            @"time": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
            @"proxyId": proxyId ?: @"",
        }];
        if (requests.count > kMaxRequests) {
            [requests removeObjectsInRange:NSMakeRange(0, requests.count - kMaxRequests)];
        }
        doc[@"requests"] = requests;
    }];
}

- (NSArray<NSDictionary *> *)requests {
    return self.dictionary[@"requests"] ?: @[];
}

#pragma mark - Containers

- (NSMutableDictionary *)container:(NSString *)containerId {
    NSMutableDictionary *doc = self.dictionary;
    return RBXMutableContainerEntry(doc, containerId);
}

- (void)pruneInvalidContainers {
    [self update:^(NSMutableDictionary *doc) {
        NSDictionary *containers = doc[@"containers"];
        if (![containers isKindOfClass:[NSDictionary class]]) {
            doc[@"containers"] = [NSMutableDictionary dictionary];
            return;
        }
        NSMutableDictionary *clean = [NSMutableDictionary dictionary];
        for (NSString *key in containers) {
            id v = containers[key];
            if ([v isKindOfClass:[NSDictionary class]]) clean[key] = v;
        }
        doc[@"containers"] = clean;
    }];
}

- (NSString *)effectiveAttestModeForContainer:(NSString *)containerId {
    NSMutableDictionary *doc = self.dictionary;
    NSDictionary *cont = doc[@"containers"][containerId];
    NSString *mode = cont[@"attest"][@"mode"];
    if ([mode isKindOfClass:[NSString class]]) {
        if ([mode isEqualToString:@"on"]) return @"on";
        if ([mode isEqualToString:@"off"]) return @"off";
    }
    // "auto" (or missing): resolve via A/B group default (A=on, B=off).
    NSString *group = cont[@"attest"][@"group"];
    if ([group isKindOfClass:[NSString class]] && [group length] > 0) {
        return [group isEqualToString:@"A"] ? @"on" : @"off";
    }
    // No group either: fall back to the global default.
    NSString *def = doc[@"device"][@"attestDefault"];
    return [def isEqualToString:@"off"] ? @"off" : @"on";
}

#pragma mark - Key registry

- (NSInteger)attestKeyCount {
    NSMutableDictionary *doc = self.dictionary;
    NSArray *used = doc[@"device"][@"attestKeysUsed"];
    return [used isKindOfClass:[NSArray class]] ? used.count : 0;
}

- (void)recordAttestKeyForContainer:(NSString *)containerId keyId:(NSString *)keyId {
    [self update:^(NSMutableDictionary *doc) {
        NSMutableArray *used = [doc[@"device"][@"attestKeysUsed"] isKindOfClass:[NSArray class]] ?
            [doc[@"device"][@"attestKeysUsed"] mutableCopy] : [NSMutableArray array];
        for (NSDictionary *e in used) {
            if ([e isKindOfClass:[NSDictionary class]] &&
                [e[@"keyId"] isEqualToString:keyId] &&
                [e[@"containerId"] isEqualToString:containerId]) {
                return;  // already recorded
            }
        }
        [used addObject:@{
            @"containerId": containerId,
            @"keyId": keyId,
            @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
        }];
        NSMutableDictionary *device = [doc[@"device"] mutableCopy] ?: [NSMutableDictionary dictionary];
        device[@"attestKeysUsed"] = used;
        doc[@"device"] = device;
    }];
}

- (NSArray<NSString *> *)keyIdsForContainer:(NSString *)containerId {
    NSMutableDictionary *doc = self.dictionary;
    NSArray *ids = doc[@"containers"][containerId][@"attest"][@"keyIds"];
    if (![ids isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id k in ids) {
        if ([k isKindOfClass:[NSString class]]) [out addObject:k];
    }
    return out;
}

- (void)observeKeyForContainer:(NSString *)containerId keyId:(NSString *)keyId {
    [self update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *cont = RBXMutableContainerEntry(doc, containerId);
        NSMutableDictionary *attest = [cont[@"attest"] isKindOfClass:[NSDictionary class]] ?
            [cont[@"attest"] mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableArray *ids = [attest[@"keyIds"] isKindOfClass:[NSArray class]] ?
            [attest[@"keyIds"] mutableCopy] : [NSMutableArray array];
        if (![ids containsObject:keyId]) {
            [ids addObject:keyId];
            attest[@"keyIds"] = ids;
            cont[@"attest"] = attest;
        }
    }];
}

- (BOOL)markDuplicateKeyIfUsedElsewhere:(NSString *)containerId keyId:(NSString *)keyId {
    __block BOOL duplicate = NO;
    [self update:^(NSMutableDictionary *doc) {
        NSArray *used = doc[@"device"][@"attestKeysUsed"];
        if ([used isKindOfClass:[NSArray class]]) {
            for (NSDictionary *e in used) {
                if (![e isKindOfClass:[NSDictionary class]]) continue;
                NSString *k = e[@"keyId"];
                NSString *c = e[@"containerId"];
                if ([k isEqualToString:keyId] && ![c isEqualToString:containerId]) {
                    duplicate = YES;
                    break;
                }
            }
        }
        // Also treat a keyId listed under a *different* container's attest.keyIds
        // as reuse (covers cloned keychain from a template container even when the
        // key was never successfully (re)attested from here).
        if (!duplicate) {
            NSDictionary *containers = doc[@"containers"];
            if ([containers isKindOfClass:[NSDictionary class]]) {
                for (NSString *other in containers) {
                    if ([other isEqualToString:containerId]) continue;
                    NSDictionary *c = containers[other];
                    NSArray *ids = c[@"attest"][@"keyIds"];
                    if ([ids isKindOfClass:[NSArray class]] && [ids containsObject:keyId]) {
                        duplicate = YES;
                        break;
                    }
                }
            }
        }
        if (duplicate) {
            NSMutableDictionary *cont = RBXMutableContainerEntry(doc, containerId);
            NSMutableDictionary *attest = [cont[@"attest"] isKindOfClass:[NSDictionary class]] ?
                [cont[@"attest"] mutableCopy] : [NSMutableDictionary dictionary];
            attest[@"duplicateKey"] = @YES;
            attest[@"blocked"] = @YES;
            cont[@"attest"] = attest;

            NSMutableArray *alerts = [doc[@"alerts"] isKindOfClass:[NSArray class]] ?
                [doc[@"alerts"] mutableCopy] : [NSMutableArray array];
            [alerts addObject:@{
                @"type": @"DUPLICATE KEYID",
                @"containerId": containerId,
                @"message": [NSString stringWithFormat:
                    @"Container %@ reuses an App Attest key from another container — attestation blocked so Reddit cannot link them.", containerId],
                @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
            }];
            if (alerts.count > kMaxAlerts) {
                [alerts removeObjectsInRange:NSMakeRange(0, alerts.count - kMaxAlerts)];
            }
            doc[@"alerts"] = alerts;
        }
    }];
    return duplicate;
}

- (BOOL)attestBlockedForContainer:(NSString *)containerId {
    NSMutableDictionary *doc = self.dictionary;
    NSDictionary *attest = doc[@"containers"][containerId][@"attest"];
    return [attest isKindOfClass:[NSDictionary class]] && [attest[@"blocked"] boolValue];
}

#pragma mark - Threshold helpers

- (void)evaluateKeyBudget {
    [self update:^(NSMutableDictionary *doc) {
        NSInteger budget = 100;
        if ([doc[@"device"][@"keyBudget"] isKindOfClass:[NSNumber class]]) {
            budget = [doc[@"device"][@"keyBudget"] integerValue];
        }
        if (budget <= 0) budget = 100;
        NSArray *used = doc[@"device"][@"attestKeysUsed"];
        NSInteger count = [used isKindOfClass:[NSArray class]] ? used.count : 0;

        // Only alert when a threshold is newly crossed: an alert exists for the
        // lower threshold but the count has now passed the higher one, or no
        // alert exists at all for this budget level.
        BOOL hasRed = [self _hasBudgetAlert:doc level:@"red"];
        BOOL hasYellow = [self _hasBudgetAlert:doc level:@"yellow"];
        NSMutableArray *alerts = [doc[@"alerts"] isKindOfClass:[NSArray class]] ?
            [doc[@"alerts"] mutableCopy] : [NSMutableArray array];

        if (count >= (NSInteger)(0.95 * budget) && !hasRed) {
            [alerts addObject:@{
                @"type": @"KEY BUDGET",
                @"containerId": @"",
                @"message": [NSString stringWithFormat:
                    @"Attest key budget critical: %ld of ~%ld used. Stop creating new containers or Reddit/Apple may flag the device.", (long)count, (long)budget],
                @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
                @"level": @"red",
            }];
            doc[@"alerts"] = alerts;
        } else if (count >= (NSInteger)(0.80 * budget) && !hasYellow && !hasRed) {
            [alerts addObject:@{
                @"type": @"KEY BUDGET",
                @"containerId": @"",
                @"message": [NSString stringWithFormat:
                    @"Attest key budget high: %ld of ~%ld used.", (long)count, (long)budget],
                @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
                @"level": @"yellow",
            }];
            doc[@"alerts"] = alerts;
        }
        if (alerts.count > kMaxAlerts) {
            [alerts removeObjectsInRange:NSMakeRange(0, alerts.count - kMaxAlerts)];
        }
    }];
}

- (BOOL)_hasBudgetAlert:(NSMutableDictionary *)doc level:(NSString *)level {
    for (NSDictionary *a in (doc[@"alerts"] ?: @[])) {
        if ([a[@"type"] isEqualToString:@"KEY BUDGET"] && [a[@"level"] isEqualToString:level]) {
            return YES;
        }
    }
    return NO;
}

@end

#pragma mark - Helpers

static NSMutableDictionary *RBXDeepMutable(id value) {
    if ([value isKindOfClass:[NSMutableDictionary class]]) return value;
    if ([value isKindOfClass:[NSDictionary class]]) return [value mutableCopy];
    return [NSMutableDictionary dictionary];
}

static NSMutableDictionary *RBXMutableContainerEntry(NSMutableDictionary *doc, NSString *containerId) {
    if (!doc) return nil;
    NSMutableDictionary *containers = RBXDeepMutable(doc[@"containers"]);
    NSMutableDictionary *cont = RBXDeepMutable(containers[containerId]);
    if (![containers[containerId] isKindOfClass:[NSDictionary class]]) {
        cont = [NSMutableDictionary dictionary];
    }
    containers[containerId] = cont;
    doc[@"containers"] = containers;
    return cont;
}
