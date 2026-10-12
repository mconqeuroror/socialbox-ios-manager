#import "RBXHTTPProxy.h"
#import <CFNetwork/CFNetwork.h>
#import <arpa/inet.h>

static NSString *RBXProxyHost(NSString *host) {
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"])
        host = [host substringWithRange:NSMakeRange(1, host.length - 2)];
    return host.lowercaseString;
}
NSDictionary *RBXParseHTTPProxyURL(NSString *text) {
    if (![text isKindOfClass:NSString.class] || text.length > 4096) return nil;
    if ([text rangeOfString:@"%(?![0-9a-fA-F]{2})" options:NSRegularExpressionSearch].location != NSNotFound)
        return nil;
    NSURLComponents *url = [NSURLComponents componentsWithString:text];
    NSString *host = RBXProxyHost(url.host);
    BOOL validHost = host.length > 0;
    if ([host containsString:@":"]) {
        struct in6_addr address;
        validHost = inet_pton(AF_INET6, host.UTF8String, &address) == 1;
    } else {
        for (NSString *label in [host componentsSeparatedByString:@"."])
            if (!label.length || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"]) validHost = NO;
    }
    NSCharacterSet *badHost = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789.-:"] invertedSet];
    if (![url.scheme.lowercaseString isEqual:@"http"] || !validHost || host.length > 253 ||
        [host rangeOfCharacterFromSet:badHost].location != NSNotFound ||
        !url.port || url.port.integerValue < 1 || url.port.integerValue > 65535 ||
        (url.path.length && ![url.path isEqual:@"/"]) || url.query || url.fragment) return nil;
    // Decode exactly once. NSURL user/password behavior differs between SDKs;
    // percentEncodedUser/Password make the source encoding explicit.
    NSString *user = url.percentEncodedUser.stringByRemovingPercentEncoding;
    NSString *password = url.percentEncodedPassword.stringByRemovingPercentEncoding;
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    if ((url.percentEncodedUser && !user) || (url.percentEncodedPassword && !password) ||
        (url.percentEncodedUser && !user.length) || (password && !user.length) ||
        user.length > 256 || password.length > 1024 ||
        (user && [user rangeOfCharacterFromSet:controls].location != NSNotFound) ||
        (password && [password rangeOfCharacterFromSet:controls].location != NSNotFound) ||
        [user containsString:@":"]) return nil;
    return @{@"host": host, @"port": url.port, @"username": user ?: @"", @"password": password ?: @""};
}
NSDictionary *RBXHTTPProxySettings(NSDictionary *endpoint) {
    NSString *host = endpoint[@"host"];
    NSNumber *port = endpoint[@"port"];
    if (!host.length || port.integerValue < 1 || port.integerValue > 65535) return nil;
    NSString *authority = [host containsString:@":"] ? [NSString stringWithFormat:@"[%@]", host] : host;
    NSString *script = [NSString stringWithFormat:
        @"function FindProxyForURL(url, host) { return 'PROXY %@:%ld'; }", authority, (long)port.integerValue];
    // PAC applies to HTTP and HTTPS destinations with iOS-supported keys.
    // There is deliberately no DIRECT alternative and no credential in the PAC.
    return @{(__bridge id)kCFNetworkProxiesProxyAutoConfigEnable: @YES,
        (__bridge id)kCFNetworkProxiesProxyAutoConfigJavaScript: script};
}

@implementation RBXHTTPProxyDelegate {
    id _delegate;
    NSDictionary *(^_endpoint)(void);
    BOOL (^_requestAllowed)(NSURLRequest *);
}
- (instancetype)initWithDelegate:(id)delegate endpoint:(NSDictionary *(^)(void))endpoint {
    return [self initWithDelegate:delegate endpoint:endpoint requestAllowed:nil];
}
- (instancetype)initWithDelegate:(id)delegate endpoint:(NSDictionary *(^)(void))endpoint
    requestAllowed:(BOOL (^)(NSURLRequest *))requestAllowed {
    if ((self = [super init])) {
        _delegate = delegate; _endpoint = [endpoint copy]; _requestAllowed = [requestAllowed copy];
    }
    return self;
}
- (BOOL)respondsToSelector:(SEL)selector {
    // Preserve Foundation's native redirect handling for existing callers that
    // supply neither a destination policy nor an application redirect delegate.
    if (selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:))
        return _requestAllowed != nil || [_delegate respondsToSelector:selector];
    return [super respondsToSelector:selector] || [_delegate respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [_delegate respondsToSelector:selector] ? _delegate : [super forwardingTargetForSelector:selector];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    if (_requestAllowed && !_requestAllowed(request)) { completion(nil); return; }
    void (^checked)(NSURLRequest *) = ^(NSURLRequest *next) {
        completion(next && (!_requestAllowed || _requestAllowed(next)) ? next : nil);
    };
    if ([_delegate respondsToSelector:_cmd])
        [_delegate URLSession:session task:task willPerformHTTPRedirection:response
            newRequest:request completionHandler:checked];
    else checked(request);
}
- (BOOL)answerProxyChallenge:(NSURLAuthenticationChallenge *)challenge
    completion:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    return [self answerProxyChallenge:challenge session:nil task:nil completion:completion];
}
- (BOOL)answerProxyChallenge:(NSURLAuthenticationChallenge *)challenge session:(NSURLSession *)session
    task:(NSURLSessionTask *)task
    completion:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    NSURLProtectionSpace *space = challenge.protectionSpace;
    if (!space.isProxy) return NO;
    NSDictionary *endpoint = _endpoint ? _endpoint() : nil;
    BOOL supported = [@[NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest]
        containsObject:space.authenticationMethod];
    BOOL proxyType = [@[NSURLProtectionSpaceHTTPProxy, NSURLProtectionSpaceHTTPSProxy]
        containsObject:space.proxyType ?: @""];
    BOOL authorityMatches = [RBXProxyHost(space.host) isEqual:endpoint[@"host"]];
    // iOS CONNECT may identify the destination in a proxy challenge. Bind this
    // exception to this task and our exact credential-free, single-proxy PAC;
    // no DIRECT fallback, origin challenge, session-only alias or other route.
    NSURL *destination = task.currentRequest.URL;
    BOOL boundTunnel = task && [space.proxyType isEqual:NSURLProtectionSpaceHTTPSProxy] &&
        [destination.scheme.lowercaseString isEqual:@"https"] &&
        [RBXProxyHost(space.host) isEqual:RBXProxyHost(destination.host)] &&
        [session.configuration.connectionProxyDictionary isEqualToDictionary:RBXHTTPProxySettings(endpoint)];
    if (!supported || !proxyType || challenge.previousFailureCount != 0 ||
        (!authorityMatches && !boundTunnel) ||
        space.port != [endpoint[@"port"] integerValue] || ![endpoint[@"username"] length]) {
        completion(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil); return YES;
    }
    NSURLCredential *credential = [NSURLCredential credentialWithUser:endpoint[@"username"]
        password:endpoint[@"password"] persistence:NSURLCredentialPersistenceNone];
    completion(NSURLSessionAuthChallengeUseCredential, credential);
    return YES;
}
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if ([self answerProxyChallenge:challenge completion:completion]) return;
    if ([_delegate respondsToSelector:_cmd])
        [_delegate URLSession:session didReceiveChallenge:challenge completionHandler:completion];
    else completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    if ([self answerProxyChallenge:challenge session:session task:task completion:completion]) return;
    if ([_delegate respondsToSelector:_cmd])
        [_delegate URLSession:session task:task didReceiveChallenge:challenge completionHandler:completion];
    else completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end
