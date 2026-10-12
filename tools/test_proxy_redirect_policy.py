#!/usr/bin/env python3
"""Real Foundation redirects on loopback, using the shipped tweak wrapper.

The fixture maps 127.0.0.1/localhost to allowed Reddit/denied tracker host policy.
Both actual destinations are loopback; no real domain is requested. The same
production policy is also checked against original domain names without I/O.
The server independently verifies that denied targets receive no request.
"""
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import urlsplit, parse_qs

ROOT = Path(__file__).resolve().parents[1]
received = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        received.append((self.headers['Host'].split(':')[0], url.path))
        if url.path == '/start':
            case = parse_qs(url.query)['case'][0]
            host = 'localhost' if case in ('denied', 'denied_delegate', 'enabled', 'legacy', 'legacy_default') else '127.0.0.1'
            self.send_response(302)
            self.send_header('Location', f'http://{host}:{self.server.server_port}/{case}')
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            self.send_response(200)
            self.send_header('Content-Length', '2')
            self.end_headers()
            self.wfile.write(b'OK')

    def log_message(self, *args):
        pass


source = (ROOT / 'tweak/Network/RBXProxyHooks.xm').read_text()
policy = source[source.index('static BOOL RBXCriticalHostAllowed('):
                source.index('static NSDictionary *RBXConnectionProxyDictionary(')]
policy = policy.replace('RBXAppRuntimeCriticalHostAllowed(', 'FixtureCriticalHostAllowed(')
start = source.index('    id wrapped = [[RBXHTTPProxyDelegate alloc]')
wrapping = source[start:source.index('    return %orig(configuration, wrapped, queue);', start)]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXHTTPProxy.h"
#import "RBXAppRuntime.h"
static BOOL thirdParty;
static NSInteger originPort;
static BOOL FixtureCriticalHostAllowed(NSDictionary *descriptor, NSString *host) {
    if ([host isEqual:@"127.0.0.1"]) host = @"www.reddit.com";
    else if ([host isEqual:@"localhost"]) host = @"tracker.invalid";
    return RBXAppRuntimeCriticalHostAllowed(descriptor, host);
}
static NSURL *FixtureURL(NSString *host, NSString *path) {
    return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%ld/%@", host, (long)originPort, path]];
}
@interface RBXDeviceProfile : NSObject
@property NSDictionary *rawProfile;
- (id)valueForPath:(NSString *)path;
@end
@implementation RBXDeviceProfile
- (id)valueForPath:(NSString *)path { return thirdParty ? @"enabled" : @"disabled"; }
@end
static RBXDeviceProfile *rbxProfile(void) {
    static RBXDeviceProfile *profile;
    if (!profile) { profile = [RBXDeviceProfile new]; profile.rawProfile = @{}; }
    return profile;
}
static NSDictionary *RBXCurrentProxyCredentials(void) { return nil; }
'''
delegates = r'''
@interface RedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@property NSString *mode;
@property NSUInteger calls;
@end
@implementation RedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    self.calls++;
    if ([self.mode isEqual:@"cancel"]) { completion(nil); return; }
    if ([self.mode isEqual:@"rewrite"]) {
        completion([NSURLRequest requestWithURL:FixtureURL(@"localhost", @"rewrite")]); return;
    }
    if ([self.mode isEqual:@"revoke"]) {
        // The delegate may answer asynchronously after settings change.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            thirdParty = NO;
            completion([NSURLRequest requestWithURL:FixtureURL(@"localhost", @"revoke")]);
        }); return;
    }
    completion(request);
}
@end
static id Wrap(id delegate) {
'''
main = r'''
    return wrapped;
}
int main(int argc, char **argv) { @autoreleasepool {
    originPort = atoi(argv[1]);
    if (!RBXCriticalHostAllowed(@"www.reddit.com") || RBXCriticalHostAllowed(@"tracker.invalid")) return 1;
    NSDictionary *endpoint = RBXParseHTTPProxyURL([NSString stringWithFormat:@"http://127.0.0.1:%s", argv[1]]);
    for (NSString *mode in @[@"denied", @"denied_delegate", @"allowed", @"allowed_default", @"enabled",
            @"rewrite", @"cancel", @"revoke", @"legacy", @"legacy_default"]) {
        thirdParty = [@[@"enabled", @"revoke"] containsObject:mode];
        RedirectDelegate *original = [RedirectDelegate new]; original.mode = mode;
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.connectionProxyDictionary = @{};
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.timeoutIntervalForRequest = 5;
        // Exercise both an app-supplied delegate and NSURLSession's default redirect behavior.
        id delegate = [@[@"denied", @"allowed_default", @"legacy_default"] containsObject:mode] ? nil : original;
        id wrapped = [mode hasPrefix:@"legacy"] ? [[RBXHTTPProxyDelegate alloc]
            initWithDelegate:delegate endpoint:^{ return endpoint; }] : Wrap(delegate);
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:wrapped delegateQueue:nil];
        NSURL *url = FixtureURL(@"127.0.0.1", [NSString stringWithFormat:@"start?case=%@", mode]);
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block NSInteger status = 0; __block NSError *result;
        [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            status = [(NSHTTPURLResponse *)response statusCode]; result = error; dispatch_semaphore_signal(finished);
        }] resume];
        BOOL timedOut = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0;
        NSInteger expected = [@[@"allowed", @"allowed_default", @"enabled", @"legacy", @"legacy_default"] containsObject:mode] ? 200 : 302;
        NSUInteger expectedCalls = delegate && ![mode isEqual:@"denied_delegate"] ? 1 : 0;
        if (timedOut || result || status != expected || original.calls != expectedCalls) {
            fprintf(stderr, "FAIL redirect %s: status=%ld expected=%ld delegate=%lu error=%s\n",
                mode.UTF8String, (long)status, (long)expected, (unsigned long)original.calls, result.description.UTF8String);
            [session invalidateAndCancel]; return 1;
        }
        [session invalidateAndCancel];
    }
    puts("PASS: shipped wrapper denies forbidden redirects and delegate rewrites; allows critical/enabled/legacy requests and preserves delegate cancellation");
} return 0; }
'''

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='rbx-redirect-') as directory:
        p = Path(directory)
        (p / 'test.m').write_text(fixture + policy + delegates + wrapping + main)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-I' + str(ROOT / 'shared'),
                        '-framework', 'Foundation', '-framework', 'CFNetwork', str(p / 'test.m'),
                        str(ROOT / 'shared/RBXHTTPProxy.m'), '-o', str(p / 'test')], check=True)
        result = subprocess.run([str(p / 'test'), str(server.server_port)], timeout=65)
        if result.returncode:
            print(f'Loopback server observed: {received}', flush=True)
        result.check_returncode()
    forbidden = [(host, path) for host, path in received if path in ('/denied', '/denied_delegate', '/rewrite', '/cancel', '/revoke')]
    assert not forbidden, f'Denied redirect reached the loopback server: {forbidden}'
    assert [(host, path) for host, path in received if path != '/start'] == [
        ('127.0.0.1', '/allowed'), ('127.0.0.1', '/allowed_default'), ('localhost', '/enabled'),
        ('localhost', '/legacy'), ('localhost', '/legacy_default')]
    print('PASS: server observed zero requests for every denied target')
finally:
    server.shutdown()
    server.server_close()
