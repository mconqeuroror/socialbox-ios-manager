#!/usr/bin/env python3
"""Run the shipped proxy config/test methods with in-memory providers, no network."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'daemon/RBXProxyManager.m').read_text()

def section(start, end):
    return source[source.index(start):source.index(end, source.index(start))]

prefix = r'''
#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import <sys/stat.h>
#import "RBXHTTPProxy.h"
static NSDictionary *saved;
static BOOL readFailure, healthy = YES;
static NSUInteger requests, activations;
static NSString *const kRotationConfigPath = @"/nonexistent-rbx-fixture/rotation.plist";
static NSError *RBXProxyError(NSString *message) { return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; }
@interface RBXSecureConfig : NSObject
+ (NSDictionary *)rotationConfiguration:(NSError **)error;
@end
@implementation RBXSecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error { if (readFailure) { if(error)*error=RBXProxyError(@"locked"); return nil; } return saved; }
@end
@interface RBXRotationSecrets : NSObject
+ (NSDictionary *)overrideForProfile:(NSString *)profile error:(NSError **)error;
@end
@implementation RBXRotationSecrets
+ (NSDictionary *)overrideForProfile:(NSString *)profile error:(NSError **)error { return nil; }
@end
@interface RBXOperationContext : NSObject
@end
@implementation RBXOperationContext
@end
static BOOL RBXProxyCheck(RBXOperationContext *context, NSError **error) { if (!context && error) *error=RBXProxyError(@"no owner"); return context != nil; }
static void RBXProxyRequest(RBXOperationContext *context, NSURLSessionConfiguration *configuration,
 NSMutableURLRequest *request, NSDictionary *endpoint, void (^done)(NSData *,NSURLResponse *,NSError *)) {
 requests++; NSCAssert([request.URL.scheme isEqual:@"https"],@"rotation must use TLS");
 done([NSData data],[[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:nil headerFields:nil],nil);
}
static NSDictionary *RBXDaemonProxyDictionary(NSURL *url) { NSDictionary *endpoint=RBXParseHTTPProxyURL(url.absoluteString); return endpoint ? RBXHTTPProxySettings(endpoint) : nil; }
'''
# String-fields helper ends before the environment helper (intervening profile
# helper code is deliberately excluded).
start = source.index('static BOOL RBXProxyStringFields(')
end = source.index('\n}\n', start) + 3
config = source[start:end] + '\n' + section('static NSString *RBXEnvironmentString(', 'static NSDictionary *RBXDaemonProxyDictionary(NSURL *proxyURL) {')
method = section('- (void)testCurrentConfigurationWithContext:', '- (void)activateProxyForProfile:')
fixture = r'''
@interface TestProxy : NSObject
- (void)testCurrentConfigurationWithContext:(RBXOperationContext *)context completion:(void (^)(NSDictionary *))done;
@end
@implementation TestProxy
- (void)_removeCacheForContainer:(NSString *)container context:(RBXOperationContext *)context {}
- (void)_activateProxyForProfile:(NSDictionary *)profile persistProfile:(BOOL)persist context:(RBXOperationContext *)context completion:(void (^)(BOOL,NSString *,NSError *))done {
 NSCAssert(!persist && context != nil,@"test must not persist or lose ownership");
 NSCAssert([profile[@"proxy"][@"url"] isEqual:@"http://proxy.example:8080"],@"selected proxy preserved");
 activations++; done(healthy, healthy ? @"203.0.113.10" : nil, healthy ? nil : RBXProxyError(@"offline"));
}
'''
tests = r'''
@end
int main(void) { @autoreleasepool {
 setenv("RBX_PROXY_URL","http://fallback.example:9000",1);
 setenv("RBX_ROTATION_URL","https://fallback.example/rotate",1);
 for (const char **p=(const char *[]){"RBX_ROTATION_AUTHORIZATION","RBX_ROTATION_AUTH_HEADER","RBX_ROTATION_METHOD",NULL};*p;p++) unsetenv(*p);
 saved=@{@"proxyURL":@"http://proxy.example:8080",@"rotationURL":@"",@"method":@"GET"};
 NSError *error=nil; NSDictionary *config=RBXRotationConfiguration(@{},&error);
 NSCAssert(config && !error && ![config[@"rotationURL"] length],@"empty saved link must disable fallback rotation");
 RBXOperationContext *context=[RBXOperationContext new]; TestProxy *proxy=[TestProxy new];
 __block NSDictionary *result=nil;
 [proxy testCurrentConfigurationWithContext:context completion:^(NSDictionary *value){ result=value; }];
 NSCAssert([result[@"ok"] boolValue] && [result[@"rotationSkipped"] boolValue] && requests==0 && activations==1,@"proxy-only test must validate proxy without rotation request");
 healthy=NO;
 [proxy testCurrentConfigurationWithContext:context completion:^(NSDictionary *value){ result=value; }];
 NSCAssert(![result[@"ok"] boolValue] && requests==0 && activations==2,@"failed proxy cannot report success");
 healthy=YES; saved=@{@"proxyURL":@"http://proxy.example:8080",@"rotationURL":@"https://rotate.example/",@"method":@"GET"};
 [proxy testCurrentConfigurationWithContext:context completion:^(NSDictionary *value){ result=value; }];
 NSCAssert([result[@"ok"] boolValue] && requests==1 && activations==3,@"optional link used once before proxy test");
 for (id bad in @[@"http://rotate.example/",@"https://user:pass@rotate.example/",@42]) {
  saved=@{@"proxyURL":@"http://proxy.example:8080",@"rotationURL":bad}; error=nil;
  NSCAssert(!RBXRotationConfiguration(@{},&error) && error,@"malformed optional link rejected");
 }
 saved=@{@"proxyURL":@"http://proxy.example:8080",@"proxyDisabled":@YES};
 error=nil; NSCAssert(!RBXRotationConfiguration(@{},&error) && error,@"Deleted selection cannot use environment or plist fallback");
 readFailure=YES; error=nil; NSCAssert(!RBXRotationConfiguration(@{},&error) && error,@"Keychain read error cannot choose fallback");
 [proxy testCurrentConfigurationWithContext:nil completion:^(NSDictionary *value){ result=value; }];
 NSCAssert(![result[@"ok"] boolValue] && requests==1 && activations==3,@"missing owner cannot send requests");
 puts("PASS: shipped proxy-only and rotation tests, fallback suppression, invalid settings, ownership and health failure");
} }
'''
with tempfile.TemporaryDirectory(prefix='rbx-proxy-config-') as directory:
    path = Path(directory)
    (path / 'fixture.m').write_text(prefix + config + fixture + method + tests)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-nullability-completeness',
                    '-I' + str(ROOT / 'shared'), '-framework', 'Foundation', '-framework', 'CFNetwork',
                    str(path / 'fixture.m'), str(ROOT / 'shared/RBXHTTPProxy.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
