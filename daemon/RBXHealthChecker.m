#import "RBXHealthChecker.h"
#import "RBXCentralStore.h"
#import "RBXProxyManager.h"
#import "RBXHTTPProxy.h"

// Feature 3.1 implementation. Notes:
//  - unauthenticated about.json via the container's proxy only (never direct IP)
//  - status interpretation driven by health.calibration map in the central store
//  - calibration mode: log + no status change
//  - total_karma parsed from 200 bodies into container.karma

static NSString *const kAboutURLFormat = @"https://www.reddit.com/user/%@/about.json";
static const NSTimeInterval kDefaultInterval = 6 * 60 * 60;

static void rbxHealthDarwinCallback(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo);

@implementation RBXHealthChecker {
    dispatch_source_t _timer;
    RBXProxyManager *_proxies;
    RBXCentralStore *_store;
    dispatch_queue_t _queue;
}

+ (instancetype)sharedChecker {
    static RBXHealthChecker *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}


- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.redditbox.health", DISPATCH_QUEUE_SERIAL);
        _store = [RBXCentralStore sharedStore];
        _proxies = [RBXProxyManager new];
    }
    return self;
}

- (void)start {
    // On-demand doorbell.
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)rbxHealthDarwinCallback,
        CFSTR("com.redditbox.healthCheck"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [self _scheduleTimer];
}

- (void)_scheduleTimer {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    NSDictionary *doc = _store.dictionary;
    NSNumber *interval = doc[@"health"][@"intervalSeconds"];
    NSTimeInterval secs = interval ? interval.doubleValue : kDefaultInterval;
    if (secs < 300) secs = kDefaultInterval;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer,
                             dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                             (uint64_t)(secs * NSEC_PER_SEC),
                             (uint64_t)(30 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        [weakSelf runChecks];
    });
    dispatch_resume(_timer);
}

- (void)runChecks {
    NSDictionary *doc = _store.dictionary;
    NSDictionary *containers = doc[@"containers"];
    if (![containers isKindOfClass:[NSDictionary class]]) return;

    for (NSString *containerId in containers) {
        NSDictionary *c = containers[containerId];
        if (![c isKindOfClass:[NSDictionary class]]) continue;
        if ([c[@"paused"] boolValue]) continue;                       // paused
        NSString *reason = c[@"deathReason"];
        if ([reason isKindOfClass:[NSString class]] && reason.length > 0) continue;  // dead
        NSString *username = c[@"username"];
        if (![username isKindOfClass:[NSString class]] || username.length == 0) continue;
        [self checkContainer:containerId];
    }
}

- (void)checkContainer:(NSString *)containerId {
    [self _checkContainer:containerId fresh:NO];
}

- (void)checkFreshAccount:(NSString *)containerId {
    [self _checkContainer:containerId fresh:YES];
}

- (void)_checkContainer:(NSString *)containerId fresh:(BOOL)fresh {
    dispatch_async(_queue, ^{
        NSDictionary *doc = self->_store.dictionary;
        NSDictionary *c = doc[@"containers"][containerId];
        NSString *username = c[@"username"];
        if (![username isKindOfClass:[NSString class]] || username.length == 0) return;

        // Proxy enforcement: no upstream -> skip, never direct.
        NSString *upstream = [self->_proxies nextUpstreamForContainer:containerId];
        if (!upstream.length) {
            NSLog(@"redditboxd: health check for %@ SKIPPED — no proxy configured (refusing to use direct IP)", containerId);
            return;
        }

        NSDictionary *endpoint = RBXParseHTTPProxyURL(upstream);
        if (!endpoint) {
            NSLog(@"redditboxd: health check for %@ SKIPPED — unsupported proxy configuration", containerId);
            return;
        }
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.connectionProxyDictionary = RBXHTTPProxySettings(endpoint);
        cfg.URLCredentialStorage = nil;
        RBXHTTPProxyDelegate *authentication = [[RBXHTTPProxyDelegate alloc]
            initWithDelegate:nil endpoint:^{ return endpoint; }];

        BOOL calibration = [doc[@"health"][@"calibrationMode"] boolValue];
        NSString *escaped = [username stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLPathAllowedCharacterSet]];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:kAboutURLFormat, escaped]];
        if (!url) return;

        __block NSInteger statusCode = 0;
        __block NSData *body = nil;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:authentication delegateQueue:nil];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"GET";
        req.timeoutInterval = 30;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [session dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (err) {
                    NSLog(@"redditboxd: health check for %@ failed: %@", containerId, err.localizedDescription);
                } else {
                    NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
                    statusCode = http.statusCode;
                    body = data;
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        long waitResult = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));
        [session invalidateAndCancel];
        if (waitResult != 0) return;

        if (statusCode == 0) return;   // network failure — leave status untouched

        NSString *result = [self _resultForStatus:statusCode doc:doc];
        NSInteger karma = 0;
        if (statusCode == 200 && body) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
            NSNumber *totalKarma = json[@"data"][@"total_karma"];
            if ([totalKarma isKindOfClass:[NSNumber class]]) karma = totalKarma.integerValue;
        }

        if (calibration) {
            NSLog(@"redditboxd: CALIBRATION container=%@ status=%ld result=%@",
                  containerId, (long)statusCode, result);
            return;   // calibration mode: no status change
        }

        NSString *status = @"yellow";
        if ([result isEqualToString:@"healthy"]) status = @"green";
        else if ([result isEqualToString:@"suspended"] || [result isEqualToString:@"shadowbanned"]) status = @"red";

        NSString *deathReason = @"";
        if ([status isEqualToString:@"red"]) {
            if (fresh && [result isEqualToString:@"shadowbanned"]) {
                deathReason = @"shadowban";
            } else if ([result isEqualToString:@"shadowbanned"]) {
                deathReason = @"shadowban";
            } else if ([result isEqualToString:@"suspended"]) {
                deathReason = @"ban";
            }
        }

        BOOL newlyShadowbannedFromDayOne = fresh && [result isEqualToString:@"shadowbanned"];

        [self->_store update:^(NSMutableDictionary *d) {
            NSMutableDictionary *cont = d[@"containers"][containerId];
            if (![cont isKindOfClass:[NSMutableDictionary class]]) cont = [NSMutableDictionary dictionary];
            cont[@"status"] = status;
            cont[@"lastHealth"] = @{
                @"checkedAt": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
                @"code": @(statusCode),
                @"result": result ?: @"unknown",
            };
            if (statusCode == 200) cont[@"karma"] = @(karma);
            if (deathReason.length > 0) {
                cont[@"deathReason"] = deathReason;
                cont[@"diedAt"] = @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]);
            }
            ((NSMutableDictionary *)d[@"containers"])[containerId] = cont;

            if (newlyShadowbannedFromDayOne) {
                NSMutableArray *alerts = [d[@"alerts"] isKindOfClass:[NSArray class]] ?
                    [d[@"alerts"] mutableCopy] : [NSMutableArray array];
                [alerts addObject:@{
                    @"type": @"FRESH ACCOUNT BANNED",
                    @"containerId": containerId,
                    @"message": [NSString stringWithFormat:
                        @"New account %@ was shadowbanned from day one. Do not invest time in it.", username],
                    @"timestamp": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
                }];
                if (alerts.count > 100) {
                    [alerts removeObjectsInRange:NSMakeRange(0, alerts.count - 100)];
                }
                d[@"alerts"] = alerts;
            }
        }];
        [self->_store evaluateKeyBudget];

        NSLog(@"redditboxd: health %@ container=%@ code=%ld fresh=%d",
              result, containerId, (long)statusCode, fresh);
    });
}

- (NSString *)_resultForStatus:(NSInteger)statusCode doc:(NSDictionary *)doc {
    NSDictionary *calibration = doc[@"health"][@"calibration"];
    NSString *mapped = nil;
    if ([calibration isKindOfClass:[NSDictionary class]]) {
        mapped = calibration[[NSString stringWithFormat:@"%ld", (long)statusCode]];
    }
    if ([mapped isKindOfClass:[NSString class]] && mapped.length > 0) return mapped;
    return @"unknown";
}

@end

static void rbxHealthDarwinCallback(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    // The daemon holds no shared state here; the notification is enough to
    // trigger a check pass. (RBXHealthChecker instance is looked up via
    // the singleton below to avoid re-reading the class registry.)
    [[RBXHealthChecker sharedChecker] runChecks];
}
