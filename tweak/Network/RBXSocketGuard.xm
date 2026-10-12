#import "RBXLiveness.h"
#import "RBXHookInstallation.h"
#import "RBXHookReadiness.h"
#import "RBXHTTPProxy.h"
#import "RBXSocketGuard.h"
#import "RBXContainerManager.h"
#import "RBXProfile.h"
#import "RBXPathHooks.h"
#import "RBXLog.h"
#import <Foundation/Foundation.h>
#import <CFNetwork/CFHost.h>
#import <substrate.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/uio.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <dns_sd.h>
#import <errno.h>
#import <string.h>
#import <dlfcn.h>
#import <unistd.h>
#import <math.h>
#import <stddef.h>
#import <fcntl.h>

static BOOL sSocketGuardInstalled;
#ifdef RBX_SOCKET_GUARD_TESTING
static NSDictionary *sTestLease, *sTestFirewall;
#define RBX_GUARD_BUNDLE @"com.redditbox.profile.pfixture"
#else
#define RBX_GUARD_BUNDLE NSBundle.mainBundle.bundleIdentifier
#endif
static NSDictionary *RBXValidatedLease(BOOL allowArmed);
static NSArray<NSData *> *RBXLeaseEndpoints(NSDictionary *lease);
static NSString *RBXControlPath(NSString *name) {
    return [NSHomeDirectory() stringByAppendingPathComponent:
        [@"Library/Preferences" stringByAppendingPathComponent:name]];
}

static NSDictionary *RBXCurrentLease(void) {
#ifdef RBX_SOCKET_GUARD_TESTING
    return sTestLease;
#else
    RBXBeginInternalControlFileAccess();
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:
        RBXControlPath(@"com.redditbox.network-lease.plist")];
    RBXEndInternalControlFileAccess();
    return [lease isKindOfClass:[NSDictionary class]] ? lease : nil;
#endif
}

static NSDictionary *RBXCurrentFirewallStatus(void) {
#ifdef RBX_SOCKET_GUARD_TESTING
    return sTestFirewall;
#else
    RBXBeginInternalControlFileAccess();
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:
        RBXControlPath(@"com.redditbox.firewall-status.plist")];
    RBXEndInternalControlFileAccess();
    return [status isKindOfClass:[NSDictionary class]] ? status : nil;
#endif
}

static BOOL RBXString(id value) { return [value isKindOfClass:NSString.class] && [value length] > 0; }
static BOOL RBXFreshValue(id value, NSTimeInterval now) {
    return RBXHeartbeatFresh(value, now);
}
static NSDictionary *RBXValidatedLease(BOOL allowArmed) {
    NSDictionary *lease = RBXCurrentLease(), *firewall = RBXCurrentFirewallStatus();
    RBXContainerManager *manager = RBXContainerManager.sharedManager;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!([lease[@"state"] isEqual:@"open"] || (allowArmed && [lease[@"state"] isEqual:@"armed"])) ||
        !RBXFreshValue(lease[@"heartbeatAt"], now) || !RBXFreshValue(firewall[@"heartbeatAt"], now) ||
        !RBXString(lease[@"bootEpoch"]) || !RBXString(lease[@"generation"]) ||
        ![lease[@"containerId"] isEqual:manager.containerId] ||
        ![lease[@"bundleIdentifier"] isEqual:RBX_GUARD_BUNDLE] ||
        ![lease[@"expiresAt"] isKindOfClass:NSNumber.class] ||
        !isfinite([lease[@"expiresAt"] doubleValue]) || [lease[@"expiresAt"] doubleValue] <= now ||
        ![firewall[@"providerBundleId"] isEqual:@"com.redditbox.firewall.PacketTunnel"] ||
        ![firewall[@"enforced"] isEqual:@YES] || ![firewall[@"scope"] isEqual:@"per-app"] ||
        ![firewall[@"transport"] isEqual:@"app-proxy"]) return nil;
    for (NSString *key in @[@"bootEpoch", @"generation", @"state", @"containerId", @"bundleIdentifier"])
        if (![lease[key] isEqual:firewall[key]]) return nil;
    return RBXParseHTTPProxyURL(lease[@"proxyURL"]) && RBXLeaseEndpoints(lease).count ? lease : nil;
}
static BOOL RBXLeaseMatchesCurrentContainer(BOOL allowArmed) { return RBXValidatedLease(allowArmed) != nil; }

BOOL RBXNetworkLeaseAllowsCurrentContainer(void) {
    return RBXLeaseMatchesCurrentContainer(NO);
}

BOOL RBXSystemFirewallMatchesCurrentLease(void) {
    return RBXLeaseMatchesCurrentContainer(YES);
}

BOOL RBXSystemFirewallCoversOutOfProcessAuth(void) {
    if (!RBXLeaseMatchesCurrentContainer(NO)) return NO;
    NSDictionary *status = RBXCurrentFirewallStatus();
    // The supervised VPN payload includes SafariDomains for Reddit OAuth.
    // The provider mirrors this managed capability into clone-local status.
    return [status[@"scope"] isEqualToString:@"per-app"] &&
           [status[@"outOfProcessAuthCovered"] boolValue];
}

NSString *RBXNetworkLeaseProxyURL(void) {
    NSString *url = RBXValidatedLease(YES)[@"proxyURL"];
    return [url isKindOfClass:[NSString class]] ? url : nil;
}

NSString *RBXNetworkLeaseProxyAddress(void) {
    return [RBXValidatedLease(YES)[@"proxyIPs"] firstObject];
}

NSString *RBXNetworkLeaseGeneration(void) {
    NSString *value = RBXValidatedLease(YES)[@"generation"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

NSString *RBXNetworkLeaseExitIP(void) {
    NSString *value = RBXValidatedLease(YES)[@"exitIP"];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

void RBXMarkAllHooksReady(NSDictionary *installed, NSDictionary *(^behaviorChecks)(void)) {
    if (!RBXRequiredChecksPassed(installed, RBXRequiredHookGroups()) || !behaviorChecks) {
        RBXLogErr("readiness denied: a required hook installation failed");
        return;
    }
    // On a clone's first launch iOS may create its data container only as the
    // process starts. Give the daemon a bounded window to place the armed lease
    // in that new container; no socket is allowed during this wait.
    NSDate *armedDeadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    NSDictionary *lease = nil;
    do {
        lease = RBXCurrentLease();
        if ([lease[@"state"] isEqualToString:@"armed"] &&
            RBXLeaseMatchesCurrentContainer(YES)) break;
        [NSThread sleepForTimeInterval:0.02];
    } while (armedDeadline.timeIntervalSinceNow > 0);
    if (![lease[@"state"] isEqualToString:@"armed"] ||
        !RBXLeaseMatchesCurrentContainer(YES)) return;
    NSDictionary *before = RBXValidatedLease(YES);
    NSDictionary *checks = nil;
    @try { checks = behaviorChecks(); }
    @catch (NSException *exception) {
        RBXLogErr("readiness probe raised %@", exception.name); return;
    }
    for (NSString *group in RBXRequiredBehaviorChecks())
        RBXLog("RBX_SELF_REPORT group=%@ evidence=behavior status=%@ container=%@ generation=%@ bootEpoch=%@ pid=%d",
            group, [checks[group] isEqual:@YES] ? @"CHECKED" : @"FAILED",
            before[@"containerId"], before[@"generation"], before[@"bootEpoch"], getpid());
    if (!RBXRequiredChecksPassed(checks, RBXRequiredBehaviorChecks())) return;
    lease = RBXValidatedLease(YES);
    if (![lease[@"state"] isEqual:@"armed"]) return;
    for (NSString *key in @[@"bootEpoch", @"generation", @"containerId", @"bundleIdentifier", @"proxyURL", @"proxyIPs"])
        if (![before[key] isEqual:lease[key]]) return;
    NSDictionary *ready = @{
        @"containerId": [RBXContainerManager sharedManager].containerId,
        @"bundleIdentifier": NSBundle.mainBundle.bundleIdentifier ?: @"",
        @"generation": lease[@"generation"],
        @"bootEpoch": lease[@"bootEpoch"],
        @"allHooksInstalled": @YES,
        @"installedGroups": [installed copy], @"behaviorChecks": [checks copy],
        @"evidenceVersion": @1, @"pid": @(getpid()),
        @"timestamp": @([NSDate.date timeIntervalSince1970]),
    };
    RBXBeginInternalControlFileAccess();
    BOOL written = [ready writeToFile:RBXControlPath(@"com.redditbox.hook-ready.plist")
            atomically:YES];
    RBXEndInternalControlFileAccess();
    if (!written) { RBXLogErr("failed to persist hook readiness receipt"); return; }
    RBXLog("all isolation hooks ready for container %@ generation %@",
           ready[@"containerId"],
           [ready[@"generation"] substringToIndex:
               MIN((NSUInteger)8, [ready[@"generation"] length])]);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
    while (!RBXNetworkLeaseAllowsCurrentContainer() &&
           [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.02];
    }
    if (RBXNetworkLeaseAllowsCurrentContainer()) {
        RBXLog("network lease opened after hook readiness for container %@",
               ready[@"containerId"]);
    } else {
        RBXLogErr("network lease remained closed after hook readiness timeout");
    }
}

static int RBXAddressFamily(const struct sockaddr *address, socklen_t length) {
    if (!address || length < offsetof(struct sockaddr, sa_data)) return AF_UNSPEC;
    if (address->sa_family == AF_INET && length >= sizeof(struct sockaddr_in)) return AF_INET;
    if (address->sa_family == AF_INET6 && length >= sizeof(struct sockaddr_in6)) return AF_INET6;
    if (address->sa_family == AF_UNIX && length >= offsetof(struct sockaddr_un, sun_path)) return AF_UNIX;
    return AF_UNSPEC;
}
static BOOL RBXLoopback(const struct sockaddr *address, socklen_t length) {
    int family = RBXAddressFamily(address, length);
    if (family == AF_INET) return (ntohl(((const struct sockaddr_in *)address)->sin_addr.s_addr) >> 24) == 127;
    if (family == AF_INET6) return IN6_IS_ADDR_LOOPBACK(&((const struct sockaddr_in6 *)address)->sin6_addr);
    return NO;
}
static BOOL RBXLocalNetworking(void) {
    return [[RBXContainerManager.sharedManager.currentProfile valueForPath:@"security.localNetworking"] isEqual:@"enabled"];
}
// No resolver calls: only the daemon's numeric endpoint set for this exact
// lease is admitted. A missing/invalid item invalidates the entire set.
static NSArray<NSData *> *RBXLeaseEndpoints(NSDictionary *lease) {
    if (!RBXString(lease[@"proxyURL"])) return nil;
    NSURL *url = [NSURL URLWithString:lease[@"proxyURL"]];
    NSInteger port = url.port.integerValue;
    NSArray *ips = lease[@"proxyIPs"];
    if (!url.host.length || port < 1 || port > 65535 ||
        ![@[@"http", @"https", @"socks5"] containsObject:url.scheme.lowercaseString] ||
        ![ips isKindOfClass:NSArray.class] || !ips.count || ips.count > 32) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (id ip in ips) {
        if (!RBXString(ip) || [ip containsString:@"%"] || [ip length] >= INET6_ADDRSTRLEN) return nil;
        struct sockaddr_in v4 = {}; struct sockaddr_in6 v6 = {};
        NSData *data = nil;
        if (inet_pton(AF_INET, [ip UTF8String], &v4.sin_addr) == 1) {
            v4.sin_len = sizeof(v4); v4.sin_family = AF_INET; v4.sin_port = htons((uint16_t)port);
            data = [NSData dataWithBytes:&v4 length:sizeof(v4)];
        } else if (inet_pton(AF_INET6, [ip UTF8String], &v6.sin6_addr) == 1) {
            v6.sin6_len = sizeof(v6); v6.sin6_family = AF_INET6; v6.sin6_port = htons((uint16_t)port);
            data = [NSData dataWithBytes:&v6 length:sizeof(v6)];
        } else return nil;
        if (![result containsObject:data]) [result addObject:data];
    }
    return result;
}
static BOOL RBXMatchesEndpoints(const struct sockaddr *address, socklen_t length, NSArray<NSData *> *endpoints) {
    int family = RBXAddressFamily(address, length);
    for (NSData *data in endpoints) {
        const struct sockaddr *other = (const struct sockaddr *)data.bytes;
        if (family != RBXAddressFamily(other, (socklen_t)data.length)) continue;
        if (family == AF_INET) {
            const struct sockaddr_in *a = (const struct sockaddr_in *)address, *b = (const struct sockaddr_in *)other;
            if (a->sin_port == b->sin_port && a->sin_addr.s_addr == b->sin_addr.s_addr) return YES;
        } else if (family == AF_INET6) {
            const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)address, *b = (const struct sockaddr_in6 *)other;
            if (a->sin6_scope_id == b->sin6_scope_id && a->sin6_port == b->sin6_port &&
                memcmp(&a->sin6_addr, &b->sin6_addr, sizeof(a->sin6_addr)) == 0) return YES;
        }
    }
    return NO;
}
static BOOL RBXAllowDestination(const struct sockaddr *address, socklen_t length) {
    int family = RBXAddressFamily(address, length);
    if (family == AF_UNIX) return YES;
    if (family != AF_INET && family != AF_INET6) return NO;
    NSDictionary *lease = RBXValidatedLease(NO);
    return lease && (RBXMatchesEndpoints(address, length, RBXLeaseEndpoints(lease)) ||
        (RBXLocalNetworking() && RBXLoopback(address, length)));
}
static int RBXDescriptorFamily(int descriptor, BOOL *isSocket, int *socketType) {
    int type = 0; socklen_t size = sizeof(type);
    if (getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) != 0) {
        if (isSocket) *isSocket = errno != ENOTSOCK && errno != EBADF;
        return AF_UNSPEC;
    }
    if (isSocket) *isSocket = YES;
    if (socketType) *socketType = type;
    struct sockaddr_storage address = {}; size = sizeof(address);
    if (getsockname(descriptor, (struct sockaddr *)&address, &size) != 0) return AF_UNSPEC;
    return RBXAddressFamily((const struct sockaddr *)&address, size);
}
static BOOL RBXSocketDestination(int descriptor, const struct sockaddr *address, socklen_t length) {
    int type = 0;
    int family = RBXDescriptorFamily(descriptor, NULL, &type);
    if (family == AF_UNIX) return !address || RBXAddressFamily(address, length) == AF_UNIX;
    if ((family != AF_INET && family != AF_INET6) || type != SOCK_STREAM) return NO;
    struct sockaddr_storage peer = {};
    if (!address) {
        length = sizeof(peer);
        if (getpeername(descriptor, (struct sockaddr *)&peer, &length) != 0) return NO;
        address = (const struct sockaddr *)&peer;
    }
    return family == RBXAddressFamily(address, length) && RBXAllowDestination(address, length);
}

static int (*orig_connect)(int, const struct sockaddr *, socklen_t);
static int (*orig_socket)(int, int, int);
static int (*orig_bind)(int, const struct sockaddr *, socklen_t);
static int (*orig_listen)(int, int);
static ssize_t (*orig_sendto)(int, const void *, size_t, int,
                              const struct sockaddr *, socklen_t);
static ssize_t (*orig_sendmsg)(int, const struct msghdr *, int);
static int (*orig_getaddrinfo)(const char *, const char *, const struct addrinfo *,
                               struct addrinfo **);
static struct hostent *(*orig_gethostbyname)(const char *);
static struct hostent *(*orig_gethostbyname2)(const char *, int);
static DNSServiceErrorType (*orig_DNSServiceGetAddrInfo)(
    DNSServiceRef *, DNSServiceFlags, uint32_t, DNSServiceProtocol,
    const char *, DNSServiceGetAddrInfoReply, void *);
static int (*orig_res_query)(const char *, int, int, unsigned char *, int);
static int (*orig_res_search)(const char *, int, int, unsigned char *, int);
static CFHostRef (*orig_CFHostCreateWithName)(CFAllocatorRef, CFStringRef);
static ssize_t (*orig_send)(int, const void *, size_t, int);
static ssize_t (*orig_write)(int, const void *, size_t);
static ssize_t (*orig_writev)(int, const struct iovec *, int);
static int (*orig_connectx)(int, const sa_endpoints_t *, sae_associd_t, unsigned int,
                            const struct iovec *, unsigned int, size_t *, sae_connid_t *);

static int replaced_socket(int domain, int type, int protocol) {
    if (domain != AF_UNIX && !((domain == AF_INET || domain == AF_INET6) &&
        type == SOCK_STREAM && (protocol == 0 || protocol == IPPROTO_TCP))) {
        errno = EACCES; return -1;
    }
    return orig_socket(domain, type, protocol);
}
static int replaced_bind(int descriptor, const struct sockaddr *address, socklen_t length) {
    int family = RBXDescriptorFamily(descriptor, NULL, NULL);
    if (family == AF_UNIX && RBXAddressFamily(address, length) == AF_UNIX)
        return orig_bind(descriptor, address, length);
    if ((family != AF_INET && family != AF_INET6) || family != RBXAddressFamily(address, length) ||
        !RBXNetworkLeaseAllowsCurrentContainer() || !RBXLocalNetworking() || !RBXLoopback(address, length)) {
        errno = EACCES; return -1;
    }
    return orig_bind(descriptor, address, length);
}
static int replaced_listen(int descriptor, int backlog) {
    int family = RBXDescriptorFamily(descriptor, NULL, NULL);
    if (family == AF_UNIX) return orig_listen(descriptor, backlog);
    struct sockaddr_storage address = {}; socklen_t length = sizeof(address);
    if ((family != AF_INET && family != AF_INET6) ||
        getsockname(descriptor, (struct sockaddr *)&address, &length) != 0 ||
        !RBXNetworkLeaseAllowsCurrentContainer() || !RBXLocalNetworking() ||
        !RBXLoopback((const struct sockaddr *)&address, length)) { errno = EACCES; return -1; }
    return orig_listen(descriptor, backlog);
}
static int replaced_connect(int descriptor, const struct sockaddr *address, socklen_t length) {
    if (!address || !RBXSocketDestination(descriptor, address, length)) { errno = EHOSTUNREACH; return -1; }
    return orig_connect(descriptor, address, length);
}
static ssize_t replaced_sendto(int descriptor, const void *buffer, size_t length, int flags,
    const struct sockaddr *address, socklen_t addressLength) {
    if (!RBXSocketDestination(descriptor, address, addressLength)) { errno = EHOSTUNREACH; return -1; }
    return orig_sendto(descriptor, buffer, length, flags, address, addressLength);
}
static ssize_t replaced_sendmsg(int descriptor, const struct msghdr *message, int flags) {
    if (!message) { errno = EINVAL; return -1; }
    if (!RBXSocketDestination(descriptor, (const struct sockaddr *)message->msg_name,
        (socklen_t)message->msg_namelen)) { errno = EHOSTUNREACH; return -1; }
    return orig_sendmsg(descriptor, message, flags);
}
static ssize_t replaced_send(int descriptor, const void *buffer, size_t length, int flags) {
    if (!RBXSocketDestination(descriptor, NULL, 0)) { errno = ENETDOWN; return -1; }
    return orig_send(descriptor, buffer, length, flags);
}
static ssize_t replaced_write(int descriptor, const void *buffer, size_t length) {
    BOOL isSocket = NO; RBXDescriptorFamily(descriptor, &isSocket, NULL);
    if (isSocket && !RBXSocketDestination(descriptor, NULL, 0)) { errno = ENETDOWN; return -1; }
    return orig_write(descriptor, buffer, length);
}
static ssize_t replaced_writev(int descriptor, const struct iovec *iov, int count) {
    BOOL isSocket = NO; RBXDescriptorFamily(descriptor, &isSocket, NULL);
    if (isSocket && !RBXSocketDestination(descriptor, NULL, 0)) { errno = ENETDOWN; return -1; }
    return orig_writev(descriptor, iov, count);
}
static int replaced_connectx(int descriptor, const sa_endpoints_t *endpoints,
    sae_associd_t associd, unsigned int flags, const struct iovec *iov, unsigned int iovcnt,
    size_t *length, sae_connid_t *connectionId) {
    if (!endpoints || !endpoints->sae_dstaddr ||
        !RBXSocketDestination(descriptor, endpoints->sae_dstaddr, endpoints->sae_dstaddrlen)) {
        errno = EHOSTUNREACH; return -1;
    }
    return orig_connectx(descriptor, endpoints, associd, flags, iov, iovcnt, length, connectionId);
}

// Select an endpoint from the current lease; no name ever reaches a resolver.
// The returned numeric address honors the caller's requested address family.
static NSString *RBXNumericResolverTarget(const char *node, int family) {
    if (!node) return nil;
    NSString *name = [[NSString stringWithUTF8String:node] lowercaseString];
    NSDictionary *lease = RBXValidatedLease(YES);
    if (!lease || !name.length) return nil;
    NSURL *url = [NSURL URLWithString:lease[@"proxyURL"]];
    BOOL proxyName = [name isEqual:url.host.lowercaseString];
    for (NSData *data in RBXLeaseEndpoints(lease)) {
        const struct sockaddr *address = (const struct sockaddr *)data.bytes;
        if (family != AF_UNSPEC && family != address->sa_family) continue;
        char numeric[INET6_ADDRSTRLEN] = {};
        const void *bytes = address->sa_family == AF_INET ?
            (const void *)&((const struct sockaddr_in *)address)->sin_addr :
            (const void *)&((const struct sockaddr_in6 *)address)->sin6_addr;
        if (!inet_ntop(address->sa_family, bytes, numeric, sizeof(numeric))) continue;
        NSString *text = [NSString stringWithUTF8String:numeric];
        struct in_addr v4 = {}; struct in6_addr v6 = {};
        BOOL same = address->sa_family == AF_INET ?
            (inet_pton(AF_INET, node, &v4) == 1 && memcmp(&v4, bytes, sizeof(v4)) == 0) :
            (inet_pton(AF_INET6, node, &v6) == 1 && memcmp(&v6, bytes, sizeof(v6)) == 0);
        if (proxyName || same) return text;
    }
    if (RBXLocalNetworking() && [lease[@"state"] isEqual:@"open"] &&
        [@[@"localhost", @"127.0.0.1", @"::1"] containsObject:name]) {
        if (family == AF_INET || (family == AF_UNSPEC && ![name isEqual:@"::1"])) return @"127.0.0.1";
        if (family == AF_INET6 || family == AF_UNSPEC) return @"::1";
    }
    return nil;
}
static int replaced_getaddrinfo(const char *node, const char *service,
    const struct addrinfo *hints, struct addrinfo **results) {
    if (results) *results = NULL;
    if (!results) return EAI_FAIL;
    struct addrinfo numeric = hints ? *hints : (struct addrinfo){};
    // Address construction is not egress. Folly builds 0.0.0.0/:: before
    // networking starts; rejecting that local operation terminates Facebook.
    // Accept strict literals (or the native NULL-node wildcard/loopback case)
    // with numeric-only flags. Connect, bind and send still require authority.
    struct in_addr literal4 = {}; struct in6_addr literal6 = {};
    BOOL localAddress = !node || (!strchr(node, '%') &&
        (inet_pton(AF_INET, node, &literal4) == 1 || inet_pton(AF_INET6, node, &literal6) == 1));
    if (localAddress) {
        numeric.ai_flags |= AI_NUMERICHOST | AI_NUMERICSERV;
        return orig_getaddrinfo(node, service, &numeric, results);
    }
    NSString *target = RBXNumericResolverTarget(node, numeric.ai_family);
    if (!target || (numeric.ai_socktype && numeric.ai_socktype != SOCK_STREAM) ||
        (numeric.ai_protocol && numeric.ai_protocol != IPPROTO_TCP)) return EAI_FAIL;
    // Numeric service names only; prevent NSS/service lookup side paths too.
    numeric.ai_flags |= AI_NUMERICHOST | AI_NUMERICSERV;
    numeric.ai_socktype = SOCK_STREAM; numeric.ai_protocol = IPPROTO_TCP;
    return orig_getaddrinfo(target.UTF8String, service, &numeric, results);
}
static struct hostent *RBXNumericHostEntry(const char *name, int family) {
    if (family != AF_INET && family != AF_INET6) { h_errno = NO_RECOVERY; return NULL; }
    NSString *numeric = RBXNumericResolverTarget(name, family);
    if (!numeric) { h_errno = HOST_NOT_FOUND; return NULL; }
    // Preserve gethostbyname's borrowed-result lifetime per thread without any
    // resolver invocation. The next legacy call on this thread replaces it.
    struct LegacyAnswer { struct hostent host; char name[INET6_ADDRSTRLEN];
        unsigned char address[16]; char *addresses[2]; char *aliases[1]; };
    static thread_local LegacyAnswer answer = {};
    memset(&answer, 0, sizeof(answer));
    if (inet_pton(family, numeric.UTF8String, answer.address) != 1) { h_errno = HOST_NOT_FOUND; return NULL; }
    strlcpy(answer.name, numeric.UTF8String, sizeof(answer.name));
    answer.addresses[0] = (char *)answer.address;
    answer.host.h_name = answer.name; answer.host.h_aliases = answer.aliases;
    answer.host.h_addrtype = family; answer.host.h_length = family == AF_INET ? 4 : 16;
    answer.host.h_addr_list = answer.addresses;
    h_errno = 0;
    return &answer.host;
}
static struct hostent *replaced_gethostbyname(const char *name) { return RBXNumericHostEntry(name, AF_INET); }
static struct hostent *replaced_gethostbyname2(const char *name, int family) { return RBXNumericHostEntry(name, family); }
static DNSServiceErrorType replaced_DNSServiceGetAddrInfo(DNSServiceRef *service,
    DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceProtocol protocols,
    const char *hostname, DNSServiceGetAddrInfoReply callback, void *context) {
    // This API starts a DNSService transaction, even for a textual numeric
    // name. Unsupported resolver paths fail instead of contacting mDNSResponder.
    return kDNSServiceErr_Refused;
}
static int replaced_res_query(const char *name, int dnsClass, int type,
    unsigned char *answer, int answerLength) { h_errno = HOST_NOT_FOUND; return -1; }
static int replaced_res_search(const char *name, int dnsClass, int type,
    unsigned char *answer, int answerLength) { h_errno = HOST_NOT_FOUND; return -1; }
static CFHostRef replaced_CFHostCreateWithName(CFAllocatorRef allocator, CFStringRef hostname) {
    NSString *numeric = RBXNumericResolverTarget(hostname ? [(__bridge NSString *)hostname UTF8String] : NULL, AF_UNSPEC);
    if (!numeric) return NULL;
    struct sockaddr_in v4 = {}; struct sockaddr_in6 v6 = {};
    NSData *address = nil;
    if (inet_pton(AF_INET, numeric.UTF8String, &v4.sin_addr) == 1) {
        v4.sin_family = AF_INET; v4.sin_len = sizeof(v4);
        address = [NSData dataWithBytes:&v4 length:sizeof(v4)];
    } else if (inet_pton(AF_INET6, numeric.UTF8String, &v6.sin6_addr) == 1) {
        v6.sin6_family = AF_INET6; v6.sin6_len = sizeof(v6);
        address = [NSData dataWithBytes:&v6 length:sizeof(v6)];
    }
    return address ? CFHostCreateWithAddress(allocator, (__bridge CFDataRef)address) : NULL;
}

BOOL RBXVerifySocketGuard(NSError **error) {
    NSDictionary *lease = RBXValidatedLease(YES);
    BOOL ok = sSocketGuardInstalled && [lease[@"state"] isEqual:@"armed"];
    if (!ok) {
        if (error) *error = [NSError errorWithDomain:@"com.redditbox.socket-guard" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Socket hooks and a current ARMED numeric lease are required"}];
        return NO;
    }
    // Real local IPC must work while Internet traffic is ARMED/denied.
    int pair[2] = {-1, -1};
    if (ok) ok = socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0;
    if (ok) {
        char received = 0;
        ok = send(pair[0], "x", 1, 0) == 1 && recv(pair[1], &received, 1, MSG_DONTWAIT) == 1 && received == 'x';
    }
    if (pair[0] >= 0) close(pair[0]); if (pair[1] >= 0) close(pair[1]);
    int families[] = {AF_INET, AF_INET6};
    for (NSUInteger i = 0; i < 2; i++) {
        int family = families[i];
        errno = 0;
        int denied = socket(family, SOCK_DGRAM, 0);
        BOOL blocked = denied < 0 && errno == EACCES;
        if (denied >= 0) close(denied);
        ok = ok && blocked;
    }
    NSArray<NSData *> *endpoints = RBXLeaseEndpoints(lease);
    for (NSData *data in endpoints) {
        if (!ok) break;
        const struct sockaddr *address = (const struct sockaddr *)data.bytes;
        int descriptor = socket(address->sa_family, SOCK_STREAM, 0);
        BOOL denied = NO;
        if (descriptor >= 0) {
            int flags = fcntl(descriptor, F_GETFL);
            if (flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0) {
                errno = 0;
                denied = connect(descriptor, address, (socklen_t)data.length) < 0 && errno == EHOSTUNREACH;
            }
            close(descriptor);
        }
        ok = ok && denied;
        struct addrinfo hints = {}; hints.ai_family = address->sa_family; hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *answers = NULL;
        NSURL *url = [NSURL URLWithString:lease[@"proxyURL"]];
        int status = getaddrinfo(url.host.UTF8String, url.port.stringValue.UTF8String, &hints, &answers);
        BOOL resolved = status == 0 && answers && RBXMatchesEndpoints(answers->ai_addr, (socklen_t)answers->ai_addrlen, endpoints);
        if (answers) freeaddrinfo(answers);
        ok = ok && resolved && !RBXAllowDestination(address, (socklen_t)data.length);
    }
    NSDictionary *latest = RBXValidatedLease(YES);
    for (NSString *key in @[@"bootEpoch", @"generation", @"containerId", @"bundleIdentifier", @"proxyURL", @"proxyIPs"])
        ok = ok && [latest[key] isEqual:lease[key]];
    if (!ok && error) *error = [NSError errorWithDomain:@"com.redditbox.socket-guard" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Local IPC, numeric proxy endpoints or ARMED socket denial was not verified"}];
    return ok;
}

BOOL RBXInstallSocketGuard(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{

        MSHookFunction((void *)socket, (void *)replaced_socket, (void **)&orig_socket);
        MSHookFunction((void *)bind, (void *)replaced_bind, (void **)&orig_bind);
        MSHookFunction((void *)listen, (void *)replaced_listen, (void **)&orig_listen);
        MSHookFunction((void *)connect, (void *)replaced_connect, (void **)&orig_connect);
        MSHookFunction((void *)sendto, (void *)replaced_sendto, (void **)&orig_sendto);
        MSHookFunction((void *)sendmsg, (void *)replaced_sendmsg, (void **)&orig_sendmsg);
        MSHookFunction((void *)send, (void *)replaced_send, (void **)&orig_send);
        MSHookFunction((void *)write, (void *)replaced_write, (void **)&orig_write);
        MSHookFunction((void *)writev, (void *)replaced_writev, (void **)&orig_writev);
        MSHookFunction((void *)getaddrinfo, (void *)replaced_getaddrinfo,
                       (void **)&orig_getaddrinfo);
        MSHookFunction((void *)gethostbyname, (void *)replaced_gethostbyname,
                       (void **)&orig_gethostbyname);
        MSHookFunction((void *)gethostbyname2, (void *)replaced_gethostbyname2,
                       (void **)&orig_gethostbyname2);
        void *dnsService = dlsym(RTLD_DEFAULT, "DNSServiceGetAddrInfo");
        if (dnsService) {
            MSHookFunction(dnsService, (void *)replaced_DNSServiceGetAddrInfo,
                           (void **)&orig_DNSServiceGetAddrInfo);
        }
        static void *resolverImage = dlopen("/usr/lib/libresolv.9.dylib", RTLD_NOW | RTLD_LOCAL);
        auto installResolver = [&](const char *plain, const char *versioned, void *replacement, void **original) {
            void *first = dlsym(RTLD_DEFAULT, plain);
            void *second = dlsym(resolverImage ?: RTLD_DEFAULT, versioned);
            void *target = first ?: second;
            MSHookFunction(target, replacement, original);
            if (second && second != target) {
                void *otherOriginal = NULL;
                MSHookFunction(second, replacement, &otherOriginal);
            }
        };
        installResolver("res_query", "res_9_query", (void *)replaced_res_query, (void **)&orig_res_query);
        installResolver("res_search", "res_9_search", (void *)replaced_res_search, (void **)&orig_res_search);
        MSHookFunction((void *)CFHostCreateWithName,
                       (void *)replaced_CFHostCreateWithName,
                       (void **)&orig_CFHostCreateWithName);
        void *connectxSymbol = dlsym(RTLD_DEFAULT, "connectx");
        if (connectxSymbol) {
            MSHookFunction(connectxSymbol, (void *)replaced_connectx, (void **)&orig_connectx);
        }

        sSocketGuardInstalled = RBXHookInstallationPassed() && orig_socket && orig_bind && orig_listen && orig_connect &&
            orig_sendto && orig_sendmsg && orig_send && orig_write && orig_writev &&
            orig_getaddrinfo && orig_gethostbyname && orig_gethostbyname2 &&
            orig_DNSServiceGetAddrInfo && orig_res_query && orig_res_search &&
            orig_CFHostCreateWithName && orig_connectx;
        RBXLog("socket guard installed=%d; readiness waits for the daemon's numeric lease", sSocketGuardInstalled);
    });
    return RBXHookInstallationPassed() && sSocketGuardInstalled;
}
