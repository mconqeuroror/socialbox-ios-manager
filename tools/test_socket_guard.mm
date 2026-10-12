// Exercise the actual wrappers against real local sockets. No hook engine is
// installed on the host; detour reachability is a separate on-device self-test.
#define RBX_SOCKET_GUARD_TESTING 1
#import "../tweak/Network/RBXSocketGuard.xm"
#undef MSHookFunction
#undef MSHookMessageEx
#import <sys/stat.h>
#include <initializer_list>

static BOOL LocalEnabled;
static NSUInteger InternetConnects, NumericLookups;
static void Check(BOOL ok, NSString *reason) {
    if (!ok) @throw [NSException exceptionWithName:@"SocketFixture" reason:reason userInfo:nil];
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation RBXContainerManager
+ (instancetype)sharedManager { static id manager = [self new]; return manager; }
- (NSString *)containerId { return @"fixture"; }
- (RBXDeviceProfile *)currentProfile { static id profile = [RBXDeviceProfile new]; return profile; }
@end
@implementation RBXDeviceProfile
- (NSString *)valueForPath:(NSString *)path { return LocalEnabled ? @"enabled" : @"disabled"; }
@end
#pragma clang diagnostic pop
void RBXBeginInternalControlFileAccess(void) { }
void RBXEndInternalControlFileAccess(void) { }
void MSHookFunction(void *symbol, void *hook, void **original) { *original = symbol; }

static int FixtureConnect(int fd, const struct sockaddr *address, socklen_t length) {
    if (address->sa_family == AF_UNIX) return connect(fd, address, length);
    InternetConnects++; return 42; // Never transmit to synthetic Internet endpoints.
}
static int FixtureConnectx(int fd, const sa_endpoints_t *endpoints, sae_associd_t id,
    unsigned int flags, const struct iovec *iov, unsigned int count, size_t *length, sae_connid_t *connection) { return 43; }
static int FixtureNumericLookup(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **out) {
    struct in_addr v4 = {}; struct in6_addr v6 = {};
    Check(hints && (hints->ai_flags & AI_NUMERICHOST) && (hints->ai_flags & AI_NUMERICSERV), @"actual resolver receives numeric-only flags");
    Check(!node || inet_pton(AF_INET, node, &v4) == 1 || inet_pton(AF_INET6, node, &v6) == 1, @"proxy hostname never reaches the system resolver");
    NumericLookups++;
    return getaddrinfo(node, service, hints, out);
}
static void State(NSString *state) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    sTestLease = @{@"state": state, @"containerId": @"fixture", @"bundleIdentifier": RBX_GUARD_BUNDLE,
        @"bootEpoch": @"boot-a", @"generation": @"generation-a", @"heartbeatAt": @(now),
        @"expiresAt": @(now + 120), @"proxyURL": @"http://proxy.invalid:8080",
        @"proxyIPs": @[@"203.0.113.5", @"2001:db8::5"]};
    NSMutableDictionary *status = [sTestLease mutableCopy];
    [status addEntriesFromDictionary:@{@"heartbeatAt": @(now), @"enforced": @YES, @"scope": @"per-app",
        @"transport": @"app-proxy", @"providerBundleId": @"com.redditbox.firewall.PacketTunnel"}];
    sTestFirewall = status;
}
static void CheckIPC(NSString *state, NSString *directory) {
    State(state);
    int pair[2];
    Check(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0, @"Unix pair opens");
    char byte = 0; struct iovec vector = {(void *)"x", 1}; struct msghdr message = {};
    message.msg_iov = &vector; message.msg_iovlen = 1;
    Check(replaced_send(pair[0], "x", 1, 0) == 1 && recv(pair[1], &byte, 1, MSG_DONTWAIT) == 1, @"Unix send survives lease state");
    Check(replaced_sendto(pair[0], "x", 1, 0, NULL, 0) == 1 && recv(pair[1], &byte, 1, MSG_DONTWAIT) == 1, @"connected Unix sendto survives");
    Check(replaced_sendmsg(pair[0], &message, 0) == 1 && recv(pair[1], &byte, 1, MSG_DONTWAIT) == 1, @"Unix sendmsg survives");
    Check(replaced_write(pair[0], "x", 1) == 1 && recv(pair[1], &byte, 1, MSG_DONTWAIT) == 1, @"Unix write survives");
    Check(replaced_writev(pair[0], &vector, 1) == 1 && recv(pair[1], &byte, 1, MSG_DONTWAIT) == 1, @"Unix writev survives");
    close(pair[0]); close(pair[1]);
    Check(socketpair(AF_UNIX, SOCK_DGRAM, 0, pair) == 0, @"Unix datagram pair opens");
    Check(replaced_sendmsg(pair[0], &message, 0) == 1 && recv(pair[1], &byte, 1, MSG_DONTWAIT) == 1,
        @"Internet datagram restriction does not affect Unix datagrams");
    close(pair[0]); close(pair[1]);
    int pipeFD[2]; Check(pipe(pipeFD) == 0, @"ordinary pipe opens");
    Check(replaced_write(pipeFD[1], "x", 1) == 1 && read(pipeFD[0], &byte, 1) == 1,
        @"non-socket descriptor writes retain native behavior");
    close(pipeFD[0]); close(pipeFD[1]);

    struct sockaddr_un address = {}; address.sun_family = AF_UNIX; address.sun_len = sizeof(address);
    NSString *path = [directory stringByAppendingPathComponent:state];
    Check(path.length < sizeof(address.sun_path), @"fixture Unix path fits");
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    int server = replaced_socket(AF_UNIX, SOCK_STREAM, 0), client = replaced_socket(AF_UNIX, SOCK_STREAM, 0);
    Check(server >= 0 && client >= 0, @"Unix sockets created through wrapper");
    Check(replaced_bind(server, (const struct sockaddr *)&address, sizeof(address)) == 0 && replaced_listen(server, 1) == 0, @"Unix bind/listen survive");
    Check(replaced_connect(client, (const struct sockaddr *)&address, sizeof(address)) == 0, @"Unix connect survives");
    int accepted = accept(server, NULL, NULL); Check(accepted >= 0, @"Unix connection accepted");
    sa_endpoints_t endpoints = {}; endpoints.sae_dstaddr = (const struct sockaddr *)&address; endpoints.sae_dstaddrlen = sizeof(address);
    Check(replaced_connectx(client, &endpoints, 0, 0, NULL, 0, NULL, NULL) == 43, @"Unix connectx reaches native implementation");
    close(accepted); close(client); close(server); unlink(path.fileSystemRepresentation);
}
static void CheckInternet(void) {
    for (NSString *state in @[@"closed", @"armed", @"open"]) {
        State(state);
        for (NSData *endpoint in RBXLeaseEndpoints(sTestLease)) {
            const struct sockaddr *address = (const struct sockaddr *)endpoint.bytes;
            int fd = socket(address->sa_family, SOCK_STREAM, 0);
            Check(fd >= 0, @"Internet stream fixture opens without connecting");
            NSUInteger before = InternetConnects;
            BOOL open = [state isEqual:@"open"];
            Check((replaced_connect(fd, address, (socklen_t)endpoint.length) == 42) == open, @"only OPEN permits the exact numeric endpoint");
            Check(InternetConnects == before + (open ? 1 : 0), @"denial never invokes original connect");
            NSMutableData *wrongPort = [endpoint mutableCopy];
            if (address->sa_family == AF_INET) ((struct sockaddr_in *)wrongPort.mutableBytes)->sin_port = htons(443);
            else ((struct sockaddr_in6 *)wrongPort.mutableBytes)->sin6_port = htons(443);
            Check(replaced_connect(fd, (const struct sockaddr *)wrongPort.bytes, (socklen_t)wrongPort.length) < 0, @"wrong port denied");
            Check(replaced_connect(fd, address, 1) < 0, @"truncated sockaddr denied");
            Check(replaced_send(fd, "x", 1, 0) < 0 && replaced_sendto(fd, "x", 1, 0, NULL, 0) < 0, @"unproven connected peer cannot send");
            close(fd);
            Check(replaced_socket(address->sa_family, SOCK_DGRAM, 0) < 0 && errno == EACCES, @"Internet datagrams denied in every state");
            Check(replaced_socket(address->sa_family, SOCK_RAW, 0) < 0, @"raw socket denied");
        }
    }
    State(@"open");
    NSData *allowed = RBXLeaseEndpoints(sTestLease).firstObject;
    Check(RBXAllowDestination((const struct sockaddr *)allowed.bytes, (socklen_t)allowed.length), @"fixture starts allowed");
    NSMutableDictionary *changed = [sTestLease mutableCopy]; changed[@"proxyIPs"] = @[@"203.0.113.6"];
    sTestLease = changed;
    Check(!RBXAllowDestination((const struct sockaddr *)allowed.bytes, (socklen_t)allowed.length), @"old endpoint is not cached across lease changes");
    State(@"open"); changed = [sTestFirewall mutableCopy]; changed[@"generation"] = @"old"; sTestFirewall = changed;
    Check(!RBXNetworkLeaseAllowsCurrentContainer(), @"obsolete provider receipt denied");
    State(@"open"); changed = [sTestLease mutableCopy]; changed[@"heartbeatAt"] = @(NSDate.date.timeIntervalSince1970 - 3); sTestLease = changed;
    Check(!RBXNetworkLeaseAllowsCurrentContainer(), @"expired daemon heartbeat denied");
    for (id invalid in @[@[], @[@"proxy.invalid"], @[@"203.0.113.5", @42], @[@"fe80::1%en0"], NSNull.null]) {
        State(@"open"); changed = [sTestLease mutableCopy]; changed[@"proxyIPs"] = invalid; sTestLease = changed;
        Check(!RBXNetworkLeaseAllowsCurrentContainer(), @"invalid numeric set fails closed");
    }
}
static void CheckResolvers(void) {
    State(@"armed");
    int families[] = {AF_INET, AF_INET6};
    for (NSUInteger i = 0; i < 2; i++) {
        struct addrinfo hints = {}; hints.ai_family = families[i]; hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *answer = NULL;
        Check(replaced_getaddrinfo("proxy.invalid", "8080", &hints, &answer) == 0 && answer && answer->ai_family == families[i], @"ARMED resolves proxy from numeric lease in both families");
        Check(RBXMatchesEndpoints(answer->ai_addr, (socklen_t)answer->ai_addrlen, RBXLeaseEndpoints(sTestLease)), @"numeric answer belongs to current lease");
        freeaddrinfo(answer);
        NSUInteger before = NumericLookups;
        Check(replaced_getaddrinfo("reddit.com", "443", &hints, &answer) != 0 && !answer && NumericLookups == before, @"other hostname never reaches resolver");
        struct hostent *legacy = replaced_gethostbyname2("proxy.invalid", families[i]);
        Check(legacy && legacy->h_addrtype == families[i] && legacy->h_length == (i == 0 ? 4 : 16),
            @"legacy host entry is synthesized without invoking an original resolver");
    }
    CFHostRef host = replaced_CFHostCreateWithName(kCFAllocatorDefault, CFSTR("proxy.invalid"));
    Check(host != NULL, @"CFHost object is constructed from a numeric sockaddr");
    CFRelease(host);
    Check(replaced_DNSServiceGetAddrInfo(NULL, 0, 0, 0, "proxy.invalid", NULL, NULL) == kDNSServiceErr_Refused, @"DNSService transaction blocked");
    Check(replaced_res_query("proxy.invalid", 1, 1, NULL, 0) < 0 && replaced_res_search("proxy.invalid", 1, 1, NULL, 0) < 0, @"raw DNS query/search blocked");
    State(@"closed"); struct addrinfo *answer = NULL;
    Check(replaced_getaddrinfo("proxy.invalid", "8080", NULL, &answer) != 0 && !answer, @"CLOSED has no resolver authority");
    Check(!RBXVerifySocketGuard(nil), @"uninstalled detours cannot claim readiness");
}
static void CheckLocalAddressConstruction(void) {
    // Facebook Folly constructs anyAddress("0.0.0.0") before opening a socket.
    // Creating an address is local computation, not a DNS or network grant.
    for (NSString *state in @[@"closed", @"armed", @"open"]) {
        State(state);
        const char *nodes[] = {"0.0.0.0", "::", "127.0.0.1", "::1", "198.51.100.12", "2001:db8::12", NULL};
        for (const char *node : nodes) for (int type : {SOCK_STREAM, SOCK_DGRAM}) {
            struct addrinfo hints = {}; hints.ai_family=AF_UNSPEC; hints.ai_socktype=type;
            hints.ai_flags=AI_PASSIVE;
            struct addrinfo *answer=NULL;
            Check(replaced_getaddrinfo(node,"0",&hints,&answer)==0 && answer,
                @"literal/wildcard address construction works without lease authority");
            for(struct addrinfo *a=answer;a;a=a->ai_next) {
                Check(a->ai_socktype==type,@"address construction preserves requested socket type");
                Check(!RBXAllowDestination(a->ai_addr,(socklen_t)a->ai_addrlen),
                    @"parsed literal does not authorize a connection");
            }
            freeaddrinfo(answer);
        }
        struct addrinfo *answer=NULL;
        Check(replaced_getaddrinfo("198.51.100.12","https",NULL,&answer)!=0 && !answer,
            @"literal path still forbids service-name resolution");
        NSUInteger before=NumericLookups;
        for(const char *name : {"example.com", "0.0.0.0.evil.invalid", "127.1", "0x7f000001", "fe80::1%en0", ""})
            Check(replaced_getaddrinfo(name,"443",NULL,&answer)!=0 && !answer && NumericLookups==before,
                @"noncanonical literal or hostname never reaches resolver");
    }
    sTestLease=nil; sTestFirewall=nil;
    struct addrinfo *answer=NULL;
    Check(replaced_getaddrinfo("0.0.0.0",NULL,NULL,&answer)==0 && answer,
        @"startup anyAddress succeeds before any lease exists");
    freeaddrinfo(answer);
}
static void CheckConnectedPeer(void) {
    int server = socket(AF_INET, SOCK_STREAM, 0), client = socket(AF_INET, SOCK_STREAM, 0);
    Check(server >= 0 && client >= 0, @"local TCP fixture sockets open");
    struct sockaddr_in address = {}; address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    Check(bind(server, (const struct sockaddr *)&address, sizeof(address)) == 0 && listen(server, 1) == 0, @"local fixture listener starts");
    socklen_t length = sizeof(address); Check(getsockname(server, (struct sockaddr *)&address, &length) == 0, @"assigned local fixture port reads");
    Check(connect(client, (const struct sockaddr *)&address, sizeof(address)) == 0, @"fixture connects only to its local listener");
    int accepted = accept(server, NULL, NULL); Check(accepted >= 0, @"local connection accepted");
    State(@"open");
    Check(replaced_send(client, "x", 1, 0) < 0, @"connected descriptor to an unapproved peer remains blocked in OPEN");
    NSMutableDictionary *lease = [sTestLease mutableCopy];
    lease[@"proxyURL"] = [NSString stringWithFormat:@"http://proxy.invalid:%u", ntohs(address.sin_port)];
    lease[@"proxyIPs"] = @[@"127.0.0.1"]; sTestLease = lease;
    char byte = 0;
    struct timeval receiveTimeout = {2, 0};
    Check(setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout)) == 0, @"bounded receive timeout configured");
    Check(replaced_send(client, "x", 1, 0) == 1 && recv(accepted, &byte, 1, 0) == 1,
        @"connected descriptor sends only after the exact peer becomes authorized");
    State(@"closed");
    Check(replaced_write(client, "x", 1) < 0, @"revocation also gates an already-connected descriptor");
    close(accepted); close(client); close(server);
}
int main(void) {
    @autoreleasepool {
        char directory[] = "/tmp/rbx-socket.XXXXXX";
        if (!mkdtemp(directory)) return 1;
        int result = 0;
        @try {
            orig_socket = socket; orig_bind = bind; orig_listen = listen; orig_connect = FixtureConnect;
            orig_send = send; orig_sendto = sendto; orig_sendmsg = sendmsg; orig_write = write; orig_writev = writev;
            orig_connectx = FixtureConnectx; orig_getaddrinfo = FixtureNumericLookup;
            for (NSString *state in @[@"closed", @"armed", @"open"]) CheckIPC(state, [NSString stringWithUTF8String:directory]);
            CheckInternet(); CheckResolvers(); CheckLocalAddressConstruction(); CheckConnectedPeer();
            puts("PASS actual socket wrappers: local IPC, IPv4/IPv6 policy, numeric resolver, stale and malformed leases");
        } @catch (NSException *exception) { fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); result = 1; }
        @finally { [NSFileManager.defaultManager removeItemAtPath:[NSString stringWithUTF8String:directory] error:nil]; }
        return result;
    }
}
