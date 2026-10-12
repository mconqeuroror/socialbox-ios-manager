#import "RBXLeakMonitor.h"
#import "RBXCentralStore.h"

// Leak monitors. Both checks only consider LIVE containers (not dead, not
// paused) so historical reuse from retired containers does not spam alerts.

static const NSTimeInterval kMonitorInterval = 5 * 60;      // 5 min loop
static const NSTimeInterval kRequestWindow = 10 * 60;        // 10 min overlap window

static BOOL RBXContainerIsLive(NSDictionary *c) {
    if (![c isKindOfClass:[NSDictionary class]]) return NO;
    NSString *reason = c[@"deathReason"];
    if ([reason isKindOfClass:[NSString class]] && reason.length > 0) return NO;
    if ([c[@"paused"] boolValue]) return NO;
    return YES;
}

@implementation RBXLeakMonitor {
    RBXCentralStore *_store;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _store = [RBXCentralStore sharedStore];
        _queue = dispatch_queue_create("com.redditbox.leakmonitor", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (instancetype)sharedMonitor {
    static RBXLeakMonitor *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)start {
    dispatch_async(_queue, ^{
        while (true) {
            @autoreleasepool {
                [self runLeakChecks];
            }
            [NSThread sleepForTimeInterval:kMonitorInterval];
        }
    });
}

- (void)runLeakChecks {
    [self _checkPushLeaks];
    [self _checkIPLinks];
}

- (void)_checkPushLeaks {
    NSDictionary *doc = _store.dictionary;
    NSDictionary *containers = doc[@"containers"];
    if (![containers isKindOfClass:[NSDictionary class]]) return;

    // token -> [containerIds] for live containers with a non-null token
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byToken = [NSMutableDictionary dictionary];
    for (NSString *containerId in containers) {
        NSDictionary *c = containers[containerId];
        if (!RBXContainerIsLive(c)) continue;
        if (![c[@"push"][@"enabled"] boolValue]) continue;   // only containers using push
        NSString *token = c[@"push"][@"token"];
        if (![token isKindOfClass:[NSString class]] || token.length == 0) continue;
        if (!byToken[token]) byToken[token] = [NSMutableArray array];
        [byToken[token] addObject:containerId];
    }

    for (NSString *token in byToken) {
        NSArray *ids = byToken[token];
        if (ids.count < 2) continue;
        NSArray *sorted = [ids sortedArrayUsingSelector:@selector(compare:)];
        NSString *key = [NSString stringWithFormat:@"PUSH|%@", [sorted componentsJoinedByString:@"+"]];

        if ([self _hasAlertType:@"PUSH LEAK" key:key]) continue;
        [_store addAlertType:@"PUSH LEAK"
                containerId:sorted[0]
                    message:[NSString stringWithFormat:
                        @"Containers %@ share one push notification token — Reddit can link them. Turn push off on all but one.", [sorted componentsJoinedByString:@", "]]];
        // Mark the pair on the alert for dedup.
        [_store update:^(NSMutableDictionary *d) {
            NSMutableArray *alerts = [d[@"alerts"] isKindOfClass:[NSArray class]] ?
                [d[@"alerts"] mutableCopy] : [NSMutableArray array];
            if (alerts.count) {
                NSMutableDictionary *last = [alerts[alerts.count - 1] mutableCopy];
                last[@"key"] = key;
                alerts[alerts.count - 1] = last;
            }
            d[@"alerts"] = alerts;
        }];
    }
}

- (void)_checkIPLinks {
    NSDictionary *doc = _store.dictionary;
    NSArray *requests = doc[@"requests"];
    if (![requests isKindOfClass:[NSArray class]]) return;
    NSDictionary *containers = doc[@"containers"];
    if (![containers isKindOfClass:[NSDictionary class]]) return;

    // last request time per (proxyId, container) within the window
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSNumber *> *> *byProxy = [NSMutableDictionary dictionary];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSDictionary *r in requests) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSString *proxyId = r[@"proxyId"];
        NSString *cid = r[@"containerId"];
        if (![proxyId isKindOfClass:[NSString class]] || proxyId.length == 0) continue;
        if (![cid isKindOfClass:[NSString class]]) continue;
        NSNumber *t = r[@"time"];
        if (![t isKindOfClass:[NSNumber class]]) continue;
        if (now - t.doubleValue > kRequestWindow) continue;
        if (!byProxy[proxyId]) byProxy[proxyId] = [NSMutableDictionary dictionary];
        byProxy[proxyId][cid] = t;
    }

    for (NSString *proxyId in byProxy) {
        NSDictionary *users = byProxy[proxyId];
        if (users.count < 2) continue;
        // Both containers must be LIVE.
        NSMutableArray *liveIds = [NSMutableArray array];
        for (NSString *cid in users) {
            if (RBXContainerIsLive(containers[cid])) [liveIds addObject:cid];
        }
        if (liveIds.count < 2) continue;
        NSArray *sorted = [liveIds sortedArrayUsingSelector:@selector(compare:)];
        NSString *key = [NSString stringWithFormat:@"IP|%@|%@", proxyId, [sorted componentsJoinedByString:@"+"]];

        if ([self _hasAlertType:@"IP LINK" key:key]) continue;
        [_store addAlertType:@"IP LINK"
                containerId:sorted[0]
                    message:[NSString stringWithFormat:
                        @"Containers %@ used the same IP (%@) within the last 10 minutes — assign different proxies.", [sorted componentsJoinedByString:@", "], proxyId]];
        [_store update:^(NSMutableDictionary *d) {
            NSMutableArray *alerts = [d[@"alerts"] isKindOfClass:[NSArray class]] ?
                [d[@"alerts"] mutableCopy] : [NSMutableArray array];
            if (alerts.count) {
                NSMutableDictionary *last = [alerts[alerts.count - 1] mutableCopy];
                last[@"key"] = key;
                alerts[alerts.count - 1] = last;
            }
            d[@"alerts"] = alerts;
        }];
    }
}

- (BOOL)_hasAlertType:(NSString *)type key:(NSString *)key {
    for (NSDictionary *a in _store.alerts) {
        if ([a[@"type"] isEqualToString:type] && [a[@"key"] isEqualToString:key]) return YES;
    }
    return NO;
}

@end
