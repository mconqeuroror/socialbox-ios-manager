#import "RBXCloneEpoch.h"
#import "RBXAppRegistry.h"
#import "RBXLiveness.h"
#import "RBXHTTPProxy.h"
#import "RBXHookReadiness.h"
#import "RBXNetworkGate.h"
#import "RBXSecureConfig.h"
#import "RBXCloneManager.h"
#import "RBXProcessController.h"
#import "RBXOperationContext.h"
#import "RBXLicenseGuard.h"
#import <netdb.h>
#import <arpa/inet.h>
#import <stdlib.h>
#import <time.h>
#import <math.h>
#import "RBXProc.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static NSString *const kLeasePath =
    @"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist";
static NSString *const kHookReadyPath =
    @"/var/mobile/Library/Preferences/com.redditbox.hook-ready.plist";
static NSString *const kFirewallStatusPath =
    @"/var/mobile/Library/Preferences/com.redditbox.firewall-status.plist";
static NSString *const kFirewallGroupId = @"group.com.redditbox.firewall";
static NSString *sRenewableGeneration;
static RBXOperationContext *sLeaseOwner;

static NSString *RBXBootEpoch(void) {
    return RBXOperationContext.daemonBootEpoch;
}

static NSTimeInterval RBXGateMonotonicTime(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return NAN;
    return value.tv_sec + value.tv_nsec / 1e9;
}

static BOOL RBXGateMutationAllowed(NSError **error) {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (![RBXOperationContext checkSafetyFence:error]) return NO;
    if (!context || context.inspectionOnly) {
        if (error) *error = [NSError errorWithDomain:RBXOperationErrorDomain code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Traffic authorization requires an active mutating operation"}];
        return NO;
    }
    return [context check:error];
}

static BOOL RBXFresh(NSNumber *timestamp) {
    return RBXHeartbeatFresh(timestamp, NSDate.date.timeIntervalSince1970);
}

static BOOL RBXGateEntitlementAllowed(NSError **error) {
    if (RBXLicenseGuard.sharedGuard.trafficEntitlementValid) return YES;
    if (error) *error = [NSError errorWithDomain:@"com.redditbox.license" code:3
        userInfo:@{NSLocalizedDescriptionKey: @"The signed license expired or was revoked before traffic authorization"}];
    return NO;
}

static BOOL RBXProviderAlive(NSDictionary *status) {
    return [status[@"providerBundleId"] isEqualToString:@"com.redditbox.firewall.PacketTunnel"] &&
        [status[@"transport"] isEqualToString:@"app-proxy"] &&
        [status[@"enforced"] boolValue] && RBXFresh(status[@"heartbeatAt"]) &&
        [status[@"bootEpoch"] isEqualToString:RBXBootEpoch()];
}

// FBLIFE-003. Control publication follows the exact registered clone owner.
// CLOSED revocation may have only its previous bundle, so a container ID is
// optional here; whenever present it must derive that same exact bundle.
static RBXCloneManager *RBXGateManagerForProfile(NSDictionary *profile) {
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
    NSString *bundle = app[@"bundleIdentifier"];
    id container = profile[@"containerId"];
    if (!RBXAppOwnsCloneBundleIdentifier(descriptor, bundle) ||
        (container && (![container isKindOfClass:NSString.class] || ![container length] ||
            ![RBXAppBundleIdentifier(descriptor, container) isEqual:bundle]))) return nil;
    return [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"]
        operationContext:RBXOperationContext.currentContext];
}

// Emergency revocation must reach every runnable family without holding a
// process-wait budget inside the gate lock. Exact process filters remain in
// each registered controller; this is a stop attempt, not proof of quiescence.
static void RBXGateStopRunnableApps(void) {
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors())
        if ([descriptor[@"runnable"] boolValue])
            [RBXProcessController killAllProcessesForAppDescriptor:descriptor];
}

static BOOL RBXPublishCloneControl(NSDictionary *lease, NSDictionary *status) {
    NSString *bundle = [lease[@"bundleIdentifier"] isKindOfClass:NSString.class] ? lease[@"bundleIdentifier"] : nil;
    if (!bundle.length) return !lease[@"bundleIdentifier"] || [lease[@"bundleIdentifier"] isEqual:@""];
    NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(bundle);
    if (!RBXAppOwnsCloneBundleIdentifier(descriptor, bundle)) return NO;
    NSMutableDictionary *profile = [@{@"appType":descriptor[@"appType"], @"app":@{@"bundleIdentifier":bundle}} mutableCopy];
    if (lease[@"containerId"] && ![lease[@"containerId"] isKindOfClass:NSString.class]) return NO;
    if ([lease[@"containerId"] length]) profile[@"containerId"] = lease[@"containerId"];
    RBXCloneManager *manager = RBXGateManagerForProfile(profile);
    if (!manager) return NO;
    BOOL leaseOK = [manager writeGateControlPlist:lease profile:profile
        name:@"com.redditbox.network-lease.plist" error:nil];
    BOOL statusOK = !status || [manager writeGateControlPlist:status profile:profile
        name:@"com.redditbox.firewall-status.plist" error:nil];
    return leaseOK && statusOK;
}

static NSString *RBXFirewallGroupFile(NSString *name) {
    static NSString *groupDirectory;
    if (!groupDirectory.length) {
        NSString *root = @"/var/mobile/Containers/Shared/AppGroup";
        for (NSString *entry in [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:root error:nil]) {
            NSString *candidate = [root stringByAppendingPathComponent:entry];
            NSString *metadata = [candidate stringByAppendingPathComponent:
                @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *document = [NSDictionary dictionaryWithContentsOfFile:metadata];
            if ([document[@"MCMMetadataIdentifier"] isEqualToString:kFirewallGroupId]) {
                groupDirectory = candidate;
                break;
            }
        }
    }
    return groupDirectory.length ? [groupDirectory stringByAppendingPathComponent:name] : nil;
}

// Publish private control records with permissions established before rename.
static BOOL RBXWritePrivateControl(NSDictionary *document, NSString *path, uid_t owner) {
    if (!path.length) return NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:document
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return NO;
    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    BOOL ok = fchmod(fd, 0600) == 0 && fchown(fd, owner, owner == 0 ? 0 : 501) == 0;
    const unsigned char *bytes = data.bytes;
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t count = write(fd, bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ok = NO; break; }
        offset += count;
    }
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = NO;
    if (ok) ok = rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(temporary.fileSystemRepresentation);
    return ok;
}

static BOOL RBXWriteFirewallLease(NSDictionary *lease) {
    NSString *path = RBXFirewallGroupFile(@"network-lease.plist");
    return RBXWritePrivateControl(lease, path, 501);
}

static NSDictionary *RBXReadFirewallStatus(void) {
    NSString *path = RBXFirewallGroupFile(@"firewall-status.plist");
    NSDictionary *status = path.length
        ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    return [status isKindOfClass:[NSDictionary class]] ? status : nil;
}

static NSArray<NSString *> *RBXResolveURLIPs(NSString *urlText) {
    NSURL *url = [NSURL URLWithString:urlText];
    if (!url.host.length) return @[];
    NSString *hostname = url.host;
    if ([hostname hasPrefix:@"["] && [hostname hasSuffix:@"]"])
        hostname = [hostname substringWithRange:NSMakeRange(1, hostname.length - 2)];
    struct addrinfo hints = {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *results = NULL;
    if (getaddrinfo(hostname.UTF8String, NULL, &hints, &results) != 0) return @[];
    NSMutableOrderedSet<NSString *> *addresses = [NSMutableOrderedSet orderedSet];
    for (struct addrinfo *item = results; item; item = item->ai_next) {
        char host[INET6_ADDRSTRLEN] = {0};
        const void *bytes = NULL;
        if (item->ai_family == AF_INET && item->ai_addrlen >= sizeof(struct sockaddr_in))
            bytes = &((const struct sockaddr_in *)item->ai_addr)->sin_addr;
        if (item->ai_family == AF_INET6 && item->ai_addrlen >= sizeof(struct sockaddr_in6) &&
            ((const struct sockaddr_in6 *)item->ai_addr)->sin6_scope_id == 0)
            bytes = &((const struct sockaddr_in6 *)item->ai_addr)->sin6_addr;
        if (bytes && inet_ntop(item->ai_family, bytes, host, sizeof(host))) {
            [addresses addObject:[NSString stringWithUTF8String:host]];
        }
        if (addresses.count > 32) { [addresses removeAllObjects]; break; }
    }
    freeaddrinfo(results);
    return addresses.array;
}

// A timed-out libc lookup can remain blocked. Permit only one outstanding lookup
// so repeated requests cannot accumulate resolver threads.
static NSArray<NSString *> *RBXResolveURLsWithDeadline(NSArray<NSString *> *urls) {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!context || ![context check:nil]) return nil;
    static dispatch_semaphore_t resolverSlot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ resolverSlot = dispatch_semaphore_create(1); });
    if (dispatch_semaphore_wait(resolverSlot, DISPATCH_TIME_NOW) != 0) return nil;
    if (![context beginWork:nil]) { dispatch_semaphore_signal(resolverSlot); return nil; }
    NSObject *lock = [NSObject new];
    __block NSArray *result = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @try { [context performBlock:^{
            NSMutableOrderedSet *addresses = [NSMutableOrderedSet orderedSet];
            for (NSString *url in urls) {
                if (![context check:nil]) break;
                [addresses addObjectsFromArray:RBXResolveURLIPs(url)];
            }
            if ([context check:nil]) { @synchronized (lock) { result = addresses.array; } }
        }]; } @finally {
            [context endWork];
            dispatch_semaphore_signal(resolverSlot);
            dispatch_semaphore_signal(done);
        }
    });
    NSTimeInterval wait = MIN(3.0, context.remainingTime);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(wait * NSEC_PER_SEC))) != 0) {
        [context cancelWithReason:@"Control address resolution did not finish within its deadline"];
        return nil;
    }
    @synchronized (lock) { return result; }
}

static NSArray<NSString *> *RBXControlIPs(NSArray<NSString *> *existing) {
    NSMutableOrderedSet<NSString *> *addresses =
        [NSMutableOrderedSet orderedSetWithArray:existing ?: @[]];
    NSMutableArray<NSString *> *urls = [NSMutableArray array];
    const char *rotationEnvironment = getenv("RBX_ROTATION_URL");
    if (rotationEnvironment && rotationEnvironment[0]) {
        [urls addObject:[NSString stringWithUTF8String:rotationEnvironment]];
    }
    NSDictionary *secureRotation = [RBXSecureConfig rotationConfiguration:nil];
    if ([secureRotation[@"rotationURL"] isKindOfClass:[NSString class]])
        [urls addObject:secureRotation[@"rotationURL"]];
    NSDictionary *rotation = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.rotation.plist"];
    if ([rotation[@"rotationURL"] isKindOfClass:[NSString class]])
        [urls addObject:rotation[@"rotationURL"]];
    NSDictionary *cloud = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.cloud.plist"];
    if ([cloud[@"serverURL"] isKindOfClass:[NSString class]])
        [urls addObject:cloud[@"serverURL"]];
    NSArray *resolved = RBXResolveURLsWithDeadline(urls);
    if (!resolved) return nil;
    [addresses addObjectsFromArray:resolved];
    return addresses.array;
}

static BOOL RBXPersistLease(NSDictionary *lease, NSError **error) {
    // Attempt BOTH writes even when one fails: every reachable consumer must
    // receive revocation. Atomic plist writes leave the previous file on failure.
    BOOL localOK = RBXWritePrivateControl(lease, kLeasePath, 0);
    NSString *groupPath = RBXFirewallGroupFile(@"network-lease.plist");
    // Before explicit VPN setup there is no App Group. Only CLOSED may be
    // persisted locally; ARMED/OPEN still require both verified stores.
    BOOL localOnly = !groupPath.length && [lease[@"state"] isEqualToString:@"closed"];
    BOOL groupOK = localOnly || RBXWriteFirewallLease(lease);
    BOOL verified = localOK && groupOK &&
        [[NSDictionary dictionaryWithContentsOfFile:kLeasePath] isEqualToDictionary:lease] &&
        (localOnly || [[NSDictionary dictionaryWithContentsOfFile:groupPath]
            isEqualToDictionary:lease]);
    if (!verified && error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate"
        code:9 userInfo:@{NSLocalizedDescriptionKey:
            @"network lease could not be written and verified in both stores"}];
    return verified;
}

@implementation RBXNetworkGate

+ (NSString *)leasePath {
    return kLeasePath;
}

+ (NSDictionary *)_lease {
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:kLeasePath];
    return [lease isKindOfClass:[NSDictionary class]] ? lease : @{};
}

+ (NSString *)closeTrafficWithReason:(NSString *)reason {
    NSError *error = nil;
    NSString *generation = [self closeTrafficWithReason:reason error:&error];
    if (!generation) NSLog(@"redditboxd: NETWORK CLOSE FAILED: %@", error.localizedDescription);
    return generation;
}

+ (NSDictionary *)setupStatus {
    NSDictionary *status = RBXReadFirewallStatus();
    BOOL ready = RBXProviderAlive(status) && [status[@"scope"] isEqualToString:@"per-app"];
    return @{@"state": ready ? @"ready" : @"not-configured", @"ready": @(ready),
        @"message": ready ? @"Per-app firewall available; each clone still requires managed VPN assignment." :
            @"VPN setup is deferred. Settings, source import and profiles are available. Clone traffic stays closed until managed per-app setup is complete."};
}

+ (NSArray<NSString *> *)proxyAddressesForURL:(NSString *)url {
    return RBXParseHTTPProxyURL(url) ? RBXResolveURLsWithDeadline(@[url]) : nil;
}

+ (BOOL)waitForMaintenanceClosure:(NSString *)generation timeout:(NSTimeInterval)timeout {
    NSDictionary *lease = [self _lease];
    if (!generation.length || ![lease[@"state"] isEqualToString:@"closed"] ||
        ![lease[@"generation"] isEqualToString:generation] ||
        ![lease[@"bootEpoch"] isEqualToString:RBXBootEpoch()]) return NO;
    // Callers already proved no clone/source process exists. An absent or
    // stopped provider cannot prevent offline maintenance. A live provider
    // must acknowledge revocation. Launch always uses the strict method below.
    if (!RBXFresh(RBXReadFirewallStatus()[@"heartbeatAt"])) return YES;
    return [self waitForSystemFirewallState:@"closed" container:nil generation:generation timeout:timeout];
}

+ (NSString *)closeTrafficWithReason:(NSString *)reason error:(NSError **)error {
    @synchronized (self) {
    sRenewableGeneration = nil; // Stop renewal even if revocation cannot be persisted.
    sLeaseOwner = nil;
    NSDictionary *previous = [self _lease];
    NSString *lastExit = [self lastExitIP];
    NSMutableDictionary *closed = [@{
        @"state": @"closed",
        @"bootEpoch": RBXBootEpoch(),
        @"generation": NSUUID.UUID.UUIDString,
        @"changedAt": @([NSDate.date timeIntervalSince1970]),
        @"heartbeatAt": @([NSDate.date timeIntervalSince1970]),
    } mutableCopy];
    if (lastExit.length) closed[@"lastExitIP"] = lastExit;
    for (NSString *key in @[@"containerId", @"bundleIdentifier"])
        if (previous[key]) closed[key] = previous[key];
    // Never resolve names on the revocation path, including on first launch.
    closed[@"controlIPs"] = [self _lease][@"controlIPs"] ?: @[];
    @synchronized (self) {
        BOOL persisted = RBXPersistLease(closed, error);
        BOOL cloneOK = RBXPublishCloneControl(closed, nil);
        if (!persisted || !cloneOK) {
            if (cloneOK == NO && error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate"
                code:11 userInfo:@{NSLocalizedDescriptionKey: @"could not revoke clone-local lease"}];
            RBXGateStopRunnableApps();
            return nil;
        }
        sRenewableGeneration = closed[@"generation"];
    }
    [[NSFileManager defaultManager] removeItemAtPath:kHookReadyPath error:nil];
    NSLog(@"redditboxd: NETWORK CLOSED (%@)", reason.length ? reason : @"policy");
    [self startDaemonHeartbeat]; // Also covers first successful close after MDM setup.
    RBXOperationContext *refresh = RBXOperationContext.currentContext;
    BOOL detached = refresh == nil;
    if (detached) refresh = [RBXOperationContext contextWithRequestID:@"control-address-refresh"
        bootEpoch:RBXBootEpoch() timeout:4.0];
    [refresh dispatchAsyncOnQueue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) block:^{
        NSError *lookupError = nil;
        if (![self refreshControlAddresses:&lookupError] && lookupError)
            NSLog(@"redditboxd: control address refresh failed: %@", lookupError.localizedDescription);
    }];
    if (detached) [refresh finishWhenQuiescent];
    return closed[@"generation"];
    }
}

+ (BOOL)refreshControlAddresses:(NSError **)error {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!context || ![context check:error]) return NO;
    NSDictionary *before = [self _lease];
    NSArray *addresses = RBXControlIPs(before[@"controlIPs"]);
    if (!addresses) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:10
            userInfo:@{NSLocalizedDescriptionKey: @"control DNS lookup timed out or is busy"}];
        return NO;
    }
    @synchronized (self) {
        if (![context check:error]) return NO;
        NSMutableDictionary *latest = [[self _lease] mutableCopy];
        if (![latest[@"generation"] isEqual:before[@"generation"]]) return NO;
        if (![latest[@"state"] isEqual:@"closed"] && !RBXGateMutationAllowed(error)) return NO;
        latest[@"controlIPs"] = addresses;
        return RBXPersistLease(latest, error);
    }
}

+ (BOOL)armTrafficForContainer:(NSString *)containerId
              bundleIdentifier:(NSString *)bundleIdentifier
                      proxyURL:(NSString *)proxyURL
                        exitIP:(NSString *)exitIP
                    generation:(NSString *)generation
                         error:(NSError **)error {
    if (!RBXGateMutationAllowed(error) || !RBXGateEntitlementAllowed(error)) return NO;
    if (!containerId.length || !bundleIdentifier.length || !proxyURL.length ||
        !exitIP.length || !generation.length) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"incomplete armed lease"}];
        return NO;
    }
    NSURL *proxy = [NSURL URLWithString:proxyURL];
    if (!proxy.host.length || proxy.port.integerValue < 1 || proxy.port.integerValue > 65535 ||
        !RBXParseHTTPProxyURL(proxy.absoluteString)) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"Proxy endpoint needs a supported scheme, host and explicit port"}];
        return NO;
    }
    [[NSFileManager defaultManager] removeItemAtPath:kHookReadyPath error:nil];
    NSArray<NSString *> *proxyIPs = RBXResolveURLsWithDeadline(@[proxyURL]);
    if (proxyIPs.count == 0) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"proxy host has no firewall addresses"}];
        return NO;
    }
    NSDictionary *armed = @{
        @"state": @"armed",
        @"bootEpoch": RBXBootEpoch(),
        @"containerId": containerId,
        @"bundleIdentifier": bundleIdentifier,
        @"proxyURL": proxyURL,
        @"exitIP": exitIP,
        @"proxyIPs": proxyIPs,
        @"controlIPs": [self _lease][@"controlIPs"] ?: @[],
        @"generation": generation,
        @"openedAt": @([NSDate.date timeIntervalSince1970]),
        @"heartbeatAt": @([NSDate.date timeIntervalSince1970]),
        @"expiresAt": @(MIN([NSDate.date timeIntervalSince1970] + 5 * 60,
            RBXLicenseGuard.sharedGuard.trafficEntitlementExpiresAt)),
    };
    BOOL ok = NO;
    @synchronized (self) {
        if (!RBXGateMutationAllowed(error) || !RBXGateEntitlementAllowed(error)) return NO;
        NSDictionary *current = [self _lease];
        ok = [current[@"state"] isEqualToString:@"closed"] &&
            [current[@"bootEpoch"] isEqualToString:RBXBootEpoch()] &&
            [current[@"generation"] isEqualToString:sRenewableGeneration] &&
            RBXPersistLease(armed, error);
        if (ok) { sRenewableGeneration = generation; sLeaseOwner = RBXOperationContext.currentContext; }
    }
    NSLog(@"redditboxd: NETWORK ARMED container=%@ generation=%@",
          containerId, [generation substringToIndex:MIN((NSUInteger)8, generation.length)]);
    return ok;
}

+ (BOOL)openTrafficForContainer:(NSString *)containerId
               bundleIdentifier:(NSString *)bundleIdentifier
                       proxyURL:(NSString *)proxyURL
                         exitIP:(NSString *)exitIP
                     generation:(NSString *)generation
                          error:(NSError **)error {
    if (!RBXGateMutationAllowed(error) || !RBXGateEntitlementAllowed(error)) return NO;
    if (!containerId.length || !bundleIdentifier.length || !proxyURL.length ||
        !exitIP.length || !generation.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"incomplete network lease"}];
        }
        return NO;
    }
    NSDictionary *current = [self _lease];
    if (![current[@"state"] isEqualToString:@"armed"] ||
        ![current[@"containerId"] isEqualToString:containerId] ||
        ![current[@"bundleIdentifier"] isEqualToString:bundleIdentifier] ||
        ![current[@"generation"] isEqualToString:generation] ||
        ![current[@"proxyURL"] isEqualToString:proxyURL]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"armed lease changed before open"}];
        return NO;
    }
    NSDictionary *open = @{
        @"state": @"open",
        @"bootEpoch": RBXBootEpoch(),
        @"containerId": containerId,
        @"bundleIdentifier": bundleIdentifier,
        @"proxyURL": proxyURL,
        @"exitIP": exitIP,
        @"proxyIPs": current[@"proxyIPs"] ?: @[],
        @"controlIPs": current[@"controlIPs"] ?: @[],
        @"generation": generation,
        @"openedAt": @([NSDate.date timeIntervalSince1970]),
        @"heartbeatAt": @([NSDate.date timeIntervalSince1970]),
        @"expiresAt": @(MIN([NSDate.date timeIntervalSince1970] + 8 * 60 * 60,
            RBXLicenseGuard.sharedGuard.trafficEntitlementExpiresAt)),
    };
    BOOL ok = NO;
    @synchronized (self) {
        if (!RBXGateMutationAllowed(error) || !RBXGateEntitlementAllowed(error)) return NO;
        NSDictionary *latest = [self _lease];
        if ([latest[@"state"] isEqualToString:@"armed"] &&
            [latest[@"bootEpoch"] isEqualToString:RBXBootEpoch()] &&
            [latest[@"generation"] isEqualToString:sRenewableGeneration] &&
            [latest[@"bundleIdentifier"] isEqualToString:bundleIdentifier] &&
            [latest[@"generation"] isEqualToString:generation]) {
            ok = RBXPersistLease(open, error);
        }
    }
    if (!ok) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         @"cannot persist network lease"}];
        }
        [self closeTrafficWithReason:@"lease write failed"];
        return NO;
    }
    if (![self waitForSystemFirewallState:@"open" container:containerId
                               generation:generation timeout:8.0]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:4
            userInfo:@{NSLocalizedDescriptionKey:
                @"system firewall did not acknowledge the open lease"}];
        [self closeTrafficWithReason:@"system firewall open acknowledgement failed"];
        return NO;
    }
    NSLog(@"redditboxd: NETWORK OPEN container=%@ generation=%@ request=%@",
          containerId, generation, RBXOperationContext.currentContext.requestID ?: @"none");
    return YES;
}

+ (BOOL)waitForSystemFirewallState:(NSString *)state
                         container:(NSString *)containerId
                        generation:(NSString *)generation
                           timeout:(NSTimeInterval)timeout {
    if (!generation.length) return NO; // CLOSED persistence failed; never acknowledge it.
    BOOL closing = [state isEqual:@"closed"];
    NSTimeInterval deadline = RBXGateMonotonicTime() + MAX(0, timeout);
    do {
        if (!closing && !RBXGateMutationAllowed(nil)) return NO;
        NSDictionary *status = RBXReadFirewallStatus();
        BOOL containerMatches = containerId.length == 0 ||
            [status[@"containerId"] isEqualToString:containerId];
        BOOL scopeMatches = [state isEqualToString:@"closed"] ||
            [status[@"scope"] isEqualToString:@"per-app"];
        if (RBXProviderAlive(status) &&
            scopeMatches &&
            [status[@"state"] isEqualToString:state] &&
            [status[@"generation"] isEqualToString:generation] &&
            (!containerId.length ||
             [status[@"bundleIdentifier"] isEqualToString:
                [self _lease][@"bundleIdentifier"]]) &&
            containerMatches) {
            if (!closing && !RBXGateMutationAllowed(nil)) return NO;
            [status writeToFile:kFirewallStatusPath atomically:YES];
            NSLog(@"redditboxd: SYSTEM FIREWALL ACK state=%@ generation=%@ request=%@",
                  state, generation, RBXOperationContext.currentContext.requestID ?: @"none");
            return YES;
        }
        [NSThread sleepForTimeInterval:0.05];
    } while (RBXGateMonotonicTime() < deadline);
    NSLog(@"redditboxd: SYSTEM FIREWALL ACK TIMEOUT state=%@", state);
    return NO;
}

+ (BOOL)syncCurrentLeaseToProfile:(NSDictionary *)profile error:(NSError **)error {
    @synchronized (self) {
    NSDictionary *lease = [self _lease];
    if (![lease[@"state"] isEqual:@"closed"] && !RBXGateMutationAllowed(error)) return NO;
    NSString *expectedBundle = profile[@"app"][@"bundleIdentifier"];
    if (!expectedBundle.length ||
        ![lease[@"bundleIdentifier"] isEqualToString:expectedBundle] ||
        ![lease[@"containerId"] isEqualToString:profile[@"containerId"]]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"lease does not belong to this app clone"}];
        return NO;
    }
    return [RBXGateManagerForProfile(profile) writeGateControlPlist:lease profile:profile
        name:@"com.redditbox.network-lease.plist" error:error];
    }
}

+ (BOOL)syncFirewallStatusToProfile:(NSDictionary *)profile error:(NSError **)error {
    @synchronized (self) {
    NSDictionary *status = RBXReadFirewallStatus();
    if (![status[@"state"] isEqual:@"closed"] && !RBXGateMutationAllowed(error)) return NO;
    NSString *expectedBundle = profile[@"app"][@"bundleIdentifier"];
    if (!RBXProviderAlive(status) ||
        ![status[@"bundleIdentifier"] isEqualToString:expectedBundle] ||
        ![status[@"containerId"] isEqualToString:profile[@"containerId"]] ||
        ![status[@"enforced"] boolValue]) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.network-gate" code:8
            userInfo:@{NSLocalizedDescriptionKey: @"firewall status is not bound to this clone"}];
        return NO;
    }
    return [RBXGateManagerForProfile(profile) writeGateControlPlist:status profile:profile
        name:@"com.redditbox.firewall-status.plist" error:error];
    }
}

+ (BOOL)waitForHookReadinessForProfile:(NSDictionary *)profile
                              expectedPID:(pid_t)expectedPID
                             generation:(NSString *)generation
                                 timeout:(NSTimeInterval)timeout {
    if (expectedPID <= 1) return NO;
    NSString *bundlePath = profile[@"app"][@"bundlePath"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *executable = [bundlePath stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: @""];
    NSString *containerId = profile[@"containerId"];
    RBXCloneManager *manager = RBXGateManagerForProfile(profile);
    if (!manager) return NO;
    NSString *dataContainer = [manager
        dataContainerForBundleIdentifier:profile[@"app"][@"bundleIdentifier"]];
    NSString *readyPath = [dataContainer stringByAppendingPathComponent:
        @"Library/Preferences/com.redditbox.hook-ready.plist"];
    NSTimeInterval deadline = RBXGateMonotonicTime() + MAX(0, timeout);
    do {
        if (!RBXGateMutationAllowed(nil)) return NO;
        NSDictionary *ready = readyPath.length
            ? [NSDictionary dictionaryWithContentsOfFile:readyPath] : nil;
        char processPath[PROC_PIDPATHINFO_MAXSIZE] = {0};
        BOOL matchingPID = [ready[@"pid"] intValue] == expectedPID &&
            proc_pidpath(expectedPID, processPath, sizeof(processPath)) > 0 &&
            [[NSString stringWithUTF8String:processPath] isEqual:executable];
        NSDictionary *lease = [self _lease];
        BOOL currentLease = [lease[@"state"] isEqual:@"armed"] &&
            [lease[@"containerId"] isEqual:containerId] &&
            [lease[@"bundleIdentifier"] isEqual:profile[@"app"][@"bundleIdentifier"]] &&
            [lease[@"generation"] isEqual:generation] && [lease[@"bootEpoch"] isEqual:RBXBootEpoch()];
        if (currentLease && matchingPID && [ready[@"containerId"] isEqualToString:containerId] &&
            [ready[@"bundleIdentifier"] isEqualToString:
                profile[@"app"][@"bundleIdentifier"]] &&
            [ready[@"generation"] isEqualToString:generation] &&
            [ready[@"bootEpoch"] isEqualToString:RBXEpochForClone(RBXBootEpoch(), profile[@"app"][@"bundleIdentifier"])] &&
            RBXHookReceiptTimeMatchesLease(ready, lease, NSDate.date.timeIntervalSince1970) &&
            [ready[@"allHooksInstalled"] isEqual:@YES] && [ready[@"evidenceVersion"] isEqual:@1] &&
            RBXRequiredChecksPassed(ready[@"installedGroups"], RBXRequiredHookGroups()) &&
            RBXRequiredChecksPassed(ready[@"behaviorChecks"], RBXRequiredBehaviorChecks())) {
            NSLog(@"redditboxd: HOOK READINESS VERIFIED container=%@ generation=%@ request=%@ pid=%@",
                  containerId, generation, RBXOperationContext.currentContext.requestID ?: @"none", ready[@"pid"] ?: @0);
            return YES;
        }
        [NSThread sleepForTimeInterval:0.05];
    } while (RBXGateMonotonicTime() < deadline);
    NSLog(@"redditboxd: HOOK READINESS TIMEOUT container=%@", containerId);
    return NO;
}

+ (NSString *)lastExitIP {
    NSDictionary *lease = [self _lease];
    NSString *value = [lease[@"exitIP"] isKindOfClass:[NSString class]]
        ? lease[@"exitIP"] : lease[@"lastExitIP"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (void)startDaemonHeartbeat {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create(
            "com.redditbox.firewall-heartbeat", DISPATCH_QUEUE_SERIAL);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            @synchronized (self) {
                NSMutableDictionary *lease = [[self _lease] mutableCopy];
                // Never renew an inherited, externally replaced or failed lease.
                if (!sRenewableGeneration.length ||
                    ![lease[@"generation"] isEqualToString:sRenewableGeneration] ||
                    ![lease[@"bootEpoch"] isEqualToString:RBXBootEpoch()]) return;
                NSDictionary *status = RBXReadFirewallStatus();
                BOOL validStatus = RBXProviderAlive(status);
                BOOL active = ![lease[@"state"] isEqualToString:@"closed"];
                if (active && (!RBXLicenseGuard.sharedGuard.trafficEntitlementValid ||
                        ![RBXOperationContext checkSafetyFence:nil] || !sLeaseOwner || sLeaseOwner.cancelled ||
                        !validStatus || !RBXFresh(lease[@"heartbeatAt"]) ||
                        [lease[@"expiresAt"] doubleValue] <= NSDate.date.timeIntervalSince1970)) {
                    [self closeTrafficWithReason:@"heartbeat, lease or signed license expired"];
                    RBXGateStopRunnableApps();
                    return;
                }
                NSDictionary *mirror = validStatus ? status : @{
                    @"state": @"closed", @"enforced": @NO, @"scope": @"none",
                    @"generation": lease[@"generation"], @"bootEpoch": RBXBootEpoch(),
                    @"containerId": lease[@"containerId"] ?: @"",
                    @"bundleIdentifier": lease[@"bundleIdentifier"] ?: @"",
                    @"heartbeatAt": @(NSDate.date.timeIntervalSince1970), @"policyAppliedAt": @0,
                };
                // During ARMED/OPEN acknowledgement the provider may still
                // publish the previous generation/state. Do not mirror that
                // stale receipt into the new clone or revoke a valid handshake.
                BOOL mirrorMatches = YES;
                for (NSString *key in @[@"state", @"generation", @"bootEpoch", @"containerId", @"bundleIdentifier"])
                    if (![lease[key] isEqual:mirror[key]]) mirrorMatches = NO;
                BOOL statusWritten = RBXWritePrivateControl(mirror, kFirewallStatusPath, 0);
                lease[@"heartbeatAt"] = @([NSDate.date timeIntervalSince1970]);
                if (!RBXPersistLease(lease, nil) || !statusWritten || !RBXPublishCloneControl(lease, mirrorMatches ? mirror : nil)) {
                    [self closeTrafficWithReason:@"heartbeat publication failed"];
                    RBXGateStopRunnableApps();
                }
            }
        });
        dispatch_resume(timer);
    });
}

@end
