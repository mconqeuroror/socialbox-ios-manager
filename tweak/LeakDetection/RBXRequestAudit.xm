#import "RBXRequestAudit.h"
#import "RBXDataSchema.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXLog.h"
#import "RBXPathHooks.h"
#import "RBXSocketGuard.h"
#import <Foundation/Foundation.h>

// Request audit (Feature 2.3). Every NSURLSession data task whose URL host
// contains "reddit.com" appends to the central store's requests ring buffer.
// The store write is async + coalesced (at most one write per 2 seconds) to
// avoid hammering the JSON file on busy GraphQL sessions.

static NSString *sContainerId;
static NSString *sExitIP;
static NSString *sGeneration;

static dispatch_queue_t sAuditQueue;
static NSMutableArray<NSDictionary *> *sPending;
static NSString *const kCentralStorePath =
    @"/var/mobile/Library/Preferences/com.redditbox.store.json";

static NSMutableDictionary *RBXReadAuditStore(NSData **bytes) {
    RBXBeginInternalControlFileAccess();
    NSData *data = [NSData dataWithContentsOfFile:kCentralStorePath];
    if (bytes) *bytes = data;
    RBXEndInternalControlFileAccess();
    id value = data.length ? [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingMutableContainers error:nil] : nil;
    return RBXSchemaValidate(value, RBXDataStore, nil) ? [value mutableCopy] : nil;
}

static void RBXWriteAuditStore(NSDictionary *document, NSData *expected) {
    RBXBeginInternalControlFileAccess();
    RBXSchemaWriteJSONExpected(document, kCentralStorePath, RBXDataStore, expected, nil);
    RBXEndInternalControlFileAccess();
}

static void RBXFlushPendingRequests(void) {
    if (!sPending.count) return;
    NSArray<NSDictionary *> *batch = sPending;
    sPending = [NSMutableArray array];

    NSData *expected = nil;
    NSMutableDictionary *doc = RBXReadAuditStore(&expected);
    if (!doc) return; // Missing, corrupt or newer data must not be reconstructed by audit.
    NSMutableArray *requests = [doc[@"requests"] isKindOfClass:[NSArray class]] ?
        [doc[@"requests"] mutableCopy] : [NSMutableArray array];
    [requests addObjectsFromArray:batch];
    if (requests.count > 500) {
        [requests removeObjectsInRange:NSMakeRange(0, requests.count - 500)];
    }
    doc[@"requests"] = requests;
    RBXWriteAuditStore(doc, expected);
}

static void RBXRecordRequest(NSString *host, NSString *userAgent) {
    if (!host.length) return;
    if (!sAuditQueue) {
        sAuditQueue = dispatch_queue_create("com.redditbox.audit", DISPATCH_QUEUE_SERIAL);
        sPending = [NSMutableArray array];
    }
    NSDictionary *entry = @{
        @"containerId": sContainerId ?: @"",
        @"host": host,
        @"time": @((NSTimeInterval)[[NSDate date] timeIntervalSince1970]),
        @"exitIP": sExitIP ?: @"",
        @"generation": sGeneration ?: @"",
    };
    dispatch_async(sAuditQueue, ^{
        [sPending addObject:entry];

        // User-Agent -> container fingerprint (for daemon fingerprint registry).
        if (userAgent.length) {
            NSData *expected = nil;
            NSMutableDictionary *doc = RBXReadAuditStore(&expected);
            if ([doc isKindOfClass:[NSMutableDictionary class]]) {
                if (![doc[@"containers"] isKindOfClass:[NSMutableDictionary class]]) {
                    doc[@"containers"] = [NSMutableDictionary dictionary];
                }
                NSMutableDictionary *cont = ((NSMutableDictionary *)doc[@"containers"])[sContainerId];
                if (![cont isKindOfClass:[NSMutableDictionary class]]) {
                    cont = [NSMutableDictionary dictionary];
                    ((NSMutableDictionary *)doc[@"containers"])[sContainerId] = cont;
                }
                NSMutableDictionary *fp = [cont[@"fingerprint"] isKindOfClass:[NSDictionary class]] ?
                    [cont[@"fingerprint"] mutableCopy] : [NSMutableDictionary dictionary];
                fp[@"userAgent"] = userAgent;
                cont[@"fingerprint"] = fp;
                RBXWriteAuditStore(doc, expected);
            }
        }

        // Coalesce: flush when the batch has been open for a moment.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       sAuditQueue, ^{
            if (sPending.count) RBXFlushPendingRequests();
        });
    });
}

static BOOL RBXIsRedditHost(NSString *host) {
    NSString *h = host.lowercaseString;
    return h.length && ([h containsString:@"reddit.com"] ||
                        [h containsString:@"redditmedia"] ||
                        [h containsString:@"redditstatic"] ||
                        [h containsString:@"snooguts"] ||
                        [h hasSuffix:@".redd.it"] ||
                        [h isEqualToString:@"redd.it"]);
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                             completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    NSURL *url = request.URL;
    if (url && RBXIsRedditHost(url.host)) {
        if (!sContainerId) {
            sContainerId = [RBXContainerManager sharedManager].containerId;
            sExitIP = RBXNetworkLeaseExitIP();
            sGeneration = RBXNetworkLeaseGeneration();
        }
        RBXRecordRequest(url.host, request.allHTTPHeaderFields[@"User-Agent"]);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))handler {
    if (RBXIsRedditHost(url.host)) {
        if (!sContainerId) {
            sContainerId = [RBXContainerManager sharedManager].containerId;
            sExitIP = RBXNetworkLeaseExitIP();
            sGeneration = RBXNetworkLeaseGeneration();
        }
        RBXRecordRequest(url.host, nil);
    }
    return %orig;
}

%end

void RBXInstallRequestAudit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
    %init;
    sContainerId = [RBXContainerManager sharedManager].containerId;
    sExitIP = RBXNetworkLeaseExitIP();
    sGeneration = RBXNetworkLeaseGeneration();
    sAuditQueue = dispatch_queue_create("com.redditbox.audit", DISPATCH_QUEUE_SERIAL);
    sPending = [NSMutableArray array];
    RBXLog("request audit active for container %@ (validated exit present: %d)",
           sContainerId, sExitIP.length > 0);
    });
}
