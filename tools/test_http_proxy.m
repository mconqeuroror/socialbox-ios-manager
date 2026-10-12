#import "../shared/RBXHTTPProxy.h"
#import <CFNetwork/CFNetwork.h>

static void Check(BOOL ok, NSString *message) {
    if (!ok) @throw [NSException exceptionWithName:@"HTTPProxyFixture" reason:message userInfo:nil];
}
@interface OriginalDelegate : NSObject <NSURLSessionTaskDelegate>
@property NSUInteger originCalls;
@end
@implementation OriginalDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completion {
    self.originCalls++;
    completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

static NSURLAuthenticationChallenge *Challenge(BOOL proxy, NSString *host, NSInteger port, NSInteger failures) {
    NSURLProtectionSpace *space = proxy ?
        [[NSURLProtectionSpace alloc] initWithProxyHost:host port:port type:NSURLProtectionSpaceHTTPProxy
            realm:@"fixture" authenticationMethod:NSURLAuthenticationMethodHTTPBasic] :
        [[NSURLProtectionSpace alloc] initWithHost:host port:port protocol:@"https"
            realm:@"fixture" authenticationMethod:NSURLAuthenticationMethodHTTPBasic];
    return [[NSURLAuthenticationChallenge alloc] initWithProtectionSpace:space proposedCredential:nil
        previousFailureCount:failures failureResponse:nil error:nil sender:nil];
}
int main(void) {
    @autoreleasepool {
        NSDictionary *endpoint = RBXParseHTTPProxyURL(@"http://u%40x:p%2540%3A%40@proxy.example:8080");
        Check([endpoint[@"username"] isEqual:@"u@x"] && [endpoint[@"password"] isEqual:@"p%40:@"],
            @"credentials decoded exactly once");
        for (NSString *url in @[@"https://proxy.example:8080", @"socks5://proxy.example:1080",
            @"http://u%0a:p@proxy.example:8080", @"http://u%3a:p@proxy.example:8080",
            @"http://u:%xx@proxy.example:8080", @"http://:p@proxy.example:8080",
            @"http://proxy.example:8080/path", @"http://proxy.example", @"http://proxy.example:0"])
            Check(!RBXParseHTTPProxyURL(url), @"unsupported or malformed endpoint denied");
        Check(RBXParseHTTPProxyURL(@"http://[2001:db8::1]:80") != nil, @"IPv6 and explicit default port accepted");
        NSDictionary *settings = RBXHTTPProxySettings(endpoint);
        NSString *script = settings[(__bridge id)kCFNetworkProxiesProxyAutoConfigJavaScript];
        Check([script rangeOfString:@"p%40"].location == NSNotFound, @"PAC contains no secret");
        for (NSString *scheme in @[@"http", @"https"]) {
            NSURL *url = [NSURL URLWithString:[scheme stringByAppendingString:@"://example.invalid/"]];
            CFErrorRef error = NULL;
            NSArray *proxies = CFBridgingRelease(CFNetworkCopyProxiesForAutoConfigurationScript(
                (__bridge CFStringRef)script, (__bridge CFURLRef)url, &error));
            Check(!error && proxies.count == 1, @"actual PAC evaluator yields one route");
            if (error) CFRelease(error);
            // CFNetwork labels HTTP CONNECT routes for HTTPS destinations as HTTPS;
            // this denotes tunneling through the HTTP proxy, not TLS to the proxy.
            CFStringRef expectedType = [scheme isEqual:@"https"] ? kCFProxyTypeHTTPS : kCFProxyTypeHTTP;
            Check([proxies[0][(__bridge id)kCFProxyTypeKey] isEqual:(__bridge id)expectedType] &&
                [proxies[0][(__bridge id)kCFProxyHostNameKey] isEqual:@"proxy.example"] &&
                [proxies[0][(__bridge id)kCFProxyPortNumberKey] isEqual:@8080],
                @"HTTP and HTTPS destinations select the HTTP proxy without DIRECT");
        }
        __block BOOL active = YES;
        OriginalDelegate *original = [OriginalDelegate new];
        RBXHTTPProxyDelegate *delegate = [[RBXHTTPProxyDelegate alloc] initWithDelegate:original
            endpoint:^{ return active ? endpoint : nil; }];
        __block NSUInteger calls = 0;
        [delegate URLSession:nil task:nil didReceiveChallenge:Challenge(YES, @"proxy.example", 8080, 0)
            completionHandler:^(NSURLSessionAuthChallengeDisposition result, NSURLCredential *credential) {
                calls++;
                Check(result == NSURLSessionAuthChallengeUseCredential &&
                    [credential.user isEqual:@"u@x"] && [credential.password isEqual:@"p%40:@"] &&
                    credential.persistence == NSURLCredentialPersistenceNone, @"only scoped ephemeral proxy credential returned");
            }];
        for (NSURLAuthenticationChallenge *challenge in @[
            Challenge(YES, @"other.example", 8080, 0), Challenge(YES, @"proxy.example", 8081, 0),
            Challenge(YES, @"proxy.example", 8080, 1)]) {
            [delegate URLSession:nil didReceiveChallenge:challenge completionHandler:
                ^(NSURLSessionAuthChallengeDisposition result, NSURLCredential *credential) {
                    calls++; Check(result == NSURLSessionAuthChallengeCancelAuthenticationChallenge && !credential,
                        @"wrong authority / repeated authentication denied");
                }];
        }
        [delegate URLSession:nil task:nil didReceiveChallenge:Challenge(NO, @"proxy.example", 8080, 0)
            completionHandler:^(NSURLSessionAuthChallengeDisposition result, NSURLCredential *credential) {
                calls++; Check(result == NSURLSessionAuthChallengePerformDefaultHandling && !credential,
                    @"origin challenge receives no proxy password");
            }];
        Check(original.originCalls == 1, @"ordinary delegate behavior preserved");
        // iOS 16 reports the HTTPS destination as the proxy protection-space
        // host for CONNECT authentication. Only our exact single-route PAC
        // and the current task destination may establish that alternate binding.
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.connectionProxyDictionary = RBXHTTPProxySettings(endpoint);
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
        NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:@"https://destination.example/check"]];
        NSURLProtectionSpace *tunnel = [[NSURLProtectionSpace alloc] initWithProxyHost:@"destination.example"
            port:8080 type:NSURLProtectionSpaceHTTPSProxy realm:@"fixture" authenticationMethod:NSURLAuthenticationMethodHTTPBasic];
        NSURLAuthenticationChallenge *tunnelChallenge = [[NSURLAuthenticationChallenge alloc]
            initWithProtectionSpace:tunnel proposedCredential:nil previousFailureCount:0 failureResponse:nil error:nil sender:nil];
        [delegate URLSession:session task:task didReceiveChallenge:tunnelChallenge
            completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                Check(disposition == NSURLSessionAuthChallengeUseCredential && [credential.user isEqual:@"u@x"],
                    @"iOS CONNECT destination challenge bound to exact proxy route and task");
            }];
        NSURLSession *directSession = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        for (NSURLSession *wrongSession in @[directSession]) {
            [delegate URLSession:wrongSession task:task didReceiveChallenge:tunnelChallenge
                completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                    Check(disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge && !credential,
                        @"destination alias requires the exact exclusive proxy route");
                }];
        }
        NSURLSessionDataTask *otherTask = [session dataTaskWithURL:[NSURL URLWithString:@"https://other.example/"]];
        [delegate URLSession:session task:otherTask didReceiveChallenge:tunnelChallenge
            completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                Check(disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge && !credential,
                    @"destination alias cannot authenticate another task origin");
            }];
        [delegate URLSession:session didReceiveChallenge:tunnelChallenge
            completionHandler:^(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential) {
                Check(disposition == NSURLSessionAuthChallengeCancelAuthenticationChallenge && !credential,
                    @"session challenge without a task cannot use the destination alias");
            }];
        [session invalidateAndCancel]; [directSession invalidateAndCancel];
        active = NO;
        [delegate URLSession:nil didReceiveChallenge:Challenge(YES, @"proxy.example", 8080, 0)
            completionHandler:^(NSURLSessionAuthChallengeDisposition result, NSURLCredential *credential) {
                calls++; Check(result == NSURLSessionAuthChallengeCancelAuthenticationChallenge && !credential,
                    @"revoked endpoint cannot authenticate");
            }];
        Check(calls == 6, @"each challenge completed exactly once");
        NSLog(@"HTTP proxy parsing, PAC evaluation and authentication fixtures passed");
    }
    return 0;
}
