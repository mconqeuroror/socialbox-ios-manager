#!/usr/bin/env python3
"""Actual Foundation transactions against loopback only, using the shipped wrapper."""
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '2')
        self.end_headers()
        self.wfile.write(b'OK')
    def log_message(self, *args):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
origin = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=origin.serve_forever, daemon=True).start()
source = (ROOT / 'daemon/RBXProxyManager.m').read_text()
wrapper = source[source.index('@implementation RBXProxyRouteObserver'):source.index('static BOOL RBXProxyProfileAvailable')]
fixture = r'''
#import <Foundation/Foundation.h>
#import "RBXHTTPProxy.h"
#import "RBXProxyRouteEvidence.h"
@interface RBXNetworkGate : NSObject
+ (NSArray *)proxyAddressesForURL:(NSString *)url;
@end
@implementation RBXNetworkGate
+ (NSArray *)proxyAddressesForURL:(NSString *)url { return @[@"127.0.0.1"]; }
@end
@interface RBXOperationContext : NSObject
@property NSTimeInterval remainingTime;
@end
@implementation RBXOperationContext
- (BOOL)check:(NSError **)error { return YES; }
- (void)trackSession:(id)value {} - (void)untrackSession:(id)value {}
- (void)trackTask:(id)value {} - (void)untrackTask:(id)value {}
- (void)performBlock:(dispatch_block_t)block { block(); }
@end
static NSError *RBXProxyError(NSString *message) { return [NSError errorWithDomain:@"route-test" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
static BOOL RBXProxyCheck(RBXOperationContext *context,NSError **error) { return [context check:error]; }
'''
main = r'''
int main(int argc,char **argv) { @autoreleasepool {
    NSInteger port=atoi(argv[1]);
    NSString *address=[NSString stringWithFormat:@"http://127.0.0.1:%ld",(long)port];
    NSDictionary *endpoint=RBXParseHTTPProxyURL(address);
    for (NSUInteger direct=0;direct<2;direct++) {
        RBXOperationContext *context=[RBXOperationContext new]; context.remainingTime=10;
        NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        if (!direct) config.connectionProxyDictionary=RBXHTTPProxySettings(endpoint);
        NSURL *url=[NSURL URLWithString:direct ? [NSString stringWithFormat:@"http://127.0.0.1:%s",argv[2]] : @"http://proxy-route-fixture.invalid/check"];
        __block BOOL finished=NO; __block NSError *result;
        RBXProxyRequest(context,config,[NSMutableURLRequest requestWithURL:url],endpoint,^(NSData *data,NSURLResponse *response,NSError *error) { result=error; finished=YES; });
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:12];
        while (!finished && deadline.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        if (!finished || (direct ? ![result.localizedDescription containsString:@"route leak"] : result!=nil)) {
            fprintf(stderr,"Route case %lu failed: %s\n",(unsigned long)direct,result.localizedDescription.UTF8String); return 1;
        }
    }
    puts("PASS: real Foundation proxy transaction accepted; direct transaction blocked by shipped wrapper");
} return 0; }
'''
try:
    with tempfile.TemporaryDirectory(prefix='rbx-route-') as directory:
        p=Path(directory)
        (p/'test.m').write_text(fixture+wrapper+main)
        subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-I'+str(ROOT/'shared'),
            '-framework','Foundation','-framework','CFNetwork',str(p/'test.m'),str(ROOT/'shared/RBXHTTPProxy.m'),'-o',str(p/'test')],check=True)
        subprocess.run([str(p/'test'),str(server.server_port),str(origin.server_port)],check=True,timeout=35)
finally:
    server.shutdown()
    server.server_close()

    origin.shutdown()
    origin.server_close()
