#!/usr/bin/env python3
"""Execute the shipped region method with injected storage/HTTP boundaries."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
fixture_source = (ROOT / 'tools/test_proxy_configuration.py').read_text()
parts = {'__file__': str(ROOT / 'tools/test_proxy_configuration.py')}
exec(compile(fixture_source[:fixture_source.index('with tempfile.TemporaryDirectory')], parts['__file__'], 'exec'), parts)
source = (ROOT / 'daemon/RBXProxyManager.m').read_text()
method = source[source.index('- (void)detectRegionForContainer:'):source.index('+ (NSString *)poolPath')]
prefix = parts['prefix']
start = prefix.index('static void RBXProxyRequest(')
end = prefix.index('static NSDictionary *RBXDaemonProxyDictionary', start)
prefix = prefix[:start] + prefix[end:]
fixture = r'''
#define RBX_CATALOG_TESTING 1
#import "RBXDeviceCatalog.m"
#import "RBXProxyRegion.h"
static NSString *const kGeoLookup = @"https://ipinfo.io/json";
static NSDictionary *storedProfile, *httpJSON;
static BOOL locked, changedSelection, changedAssignment, offline;
static NSUInteger httpStatus = 200;
static NSString *expectedHost;
static NSDictionary *RBXProxyLoadProfile(NSString *container, NSError **error) { return storedProfile; }
@interface RBXContainerRegistry : NSObject
- (NSDictionary *)identityEditorStateForContainer:(NSString *)container error:(NSError **)error;
@end
@implementation RBXContainerRegistry
- (NSDictionary *)identityEditorStateForContainer:(NSString *)container error:(NSError **)error { return @{@"locked":@(locked)}; }
@end
static void RBXProxyRequest(RBXOperationContext *context, NSURLSessionConfiguration *configuration,
    NSMutableURLRequest *request, NSDictionary *endpoint, void (^done)(NSData *,NSURLResponse *,NSError *)) {
    requests++;
    NSCAssert([request.URL.absoluteString isEqual:kGeoLookup] && [request.HTTPMethod isEqual:@"GET"], @"lookup must not rotate or send an unrelated request");
    NSCAssert([endpoint[@"host"] isEqual:expectedHost] && [configuration.connectionProxyDictionary isEqual:RBXHTTPProxySettings(endpoint)], @"request uses the exact assigned/selected proxy");
    NSCAssert(!configuration.URLCache && !configuration.HTTPCookieStorage && configuration.timeoutIntervalForResource <= 30, @"ephemeral bounded request");
    if(changedSelection) saved=@{@"proxyURL":@"http://other.example:8080"};
    if(changedAssignment) storedProfile=@{@"proxy":@{@"url":@"http://other-assigned.example:8080",@"country":@"US"}};
    done([NSJSONSerialization dataWithJSONObject:httpJSON options:0 error:nil],
        [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:httpStatus HTTPVersion:nil headerFields:nil],
        offline ? RBXProxyError(@"failed") : nil);
}
@interface RegionTest : NSObject
- (void)detectRegionForContainer:(NSString *)container context:(RBXOperationContext *)context completion:(void (^)(NSDictionary *))done;
@end
@implementation RegionTest
'''
tests = r'''
@end
int main(int argc, const char **argv) { @autoreleasepool {
    RBXCatalogTestPaths=@[[NSString stringWithUTF8String:argv[1]]];
    for (const char **p=(const char *[]){"RBX_PROXY_URL","RBX_ROTATION_URL","RBX_ROTATION_AUTHORIZATION","RBX_ROTATION_AUTH_HEADER","RBX_ROTATION_METHOD",NULL};*p;p++) unsetenv(*p);
    NSDictionary *selection=@{@"proxyURL":@"http://device.example:8080",@"rotationURL":@"https://rotate.example/",@"method":@"GET"};
    saved=selection; expectedHost=@"device.example";
    httpJSON=@{@"ip":@"203.0.113.10",@"country":@"US",@"city":@"Los Angeles",@"timezone":@"America/Los_Angeles"};
    RegionTest *manager=[RegionTest new]; RBXOperationContext *context=[RBXOperationContext new];
    __block NSDictionary *result;
    void (^lookup)(NSString *)=^(NSString *container) { [manager detectRegionForContainer:container context:context completion:^(NSDictionary *value){result=value;}]; };
    lookup(nil); NSCAssert([result[@"ok"] boolValue] && [result[@"proxySource"] isEqual:@"selected-device"] && requests==1,@"fresh device lookup with rotation configured sends only GET geo");
    storedProfile=@{@"proxy":@{@"url":@"http://assigned.example:8080",@"country":@"US"}};
    expectedHost=@"assigned.example"; NSDictionary *before=storedProfile;
    lookup(@"test"); NSCAssert([result[@"ok"] boolValue] && [result[@"proxySource"] isEqual:@"assigned"] && [before isEqual:storedProfile],@"assigned URL wins and lookup never persists");
    storedProfile=@{@"proxy":@{@"url":@"http://assigned.example:8080",@"country":@"GB"}};
    lookup(@"test"); NSCAssert(![result[@"ok"] boolValue],@"cloud-assigned country mismatch rejected");
    changedAssignment=YES; lookup(@"test"); NSCAssert(![result[@"ok"] boolValue],@"changed assignment rejected"); changedAssignment=NO;
    storedProfile=@{@"proxy":@{@"url":@"",@"country":@"GB"}}; expectedHost=@"device.example";
    lookup(@"test"); NSCAssert([result[@"ok"] boolValue],@"unassigned profile may preview selected device region");
    changedSelection=YES; lookup(@"test"); NSCAssert(![result[@"ok"] boolValue],@"changed selection rejected"); changedSelection=NO; saved=selection;
    locked=YES; NSUInteger count=requests; lookup(@"test"); NSCAssert(![result[@"ok"] boolValue] && requests==count,@"frozen identity stops before HTTP"); locked=NO;
    offline=YES; lookup(nil); NSCAssert(![result[@"ok"] boolValue],@"network failure never returns guessed success"); offline=NO;
    httpStatus=429; lookup(nil); NSCAssert(![result[@"ok"] boolValue],@"provider rate limiting is a failure"); httpStatus=200;
    count=requests; [manager detectRegionForContainer:nil context:nil completion:^(NSDictionary *value){result=value;}];
    NSCAssert(![result[@"ok"] boolValue] && requests==count,@"missing operation sends nothing");
    saved=@{@"proxyDisabled":@YES}; lookup(nil); NSCAssert(![result[@"ok"] boolValue] && requests==count,@"deleted selection has no direct or fallback request");
    puts("PASS: shipped proxy region transport, assignment binding, stale-result rejection, no rotation/persistence, failure and freeze behavior");
} }
'''
with tempfile.TemporaryDirectory(prefix='rbx-region-transport-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(prefix + parts['config'] + fixture + method + tests)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wno-nullability-completeness',
                    '-I'+str(ROOT/'daemon'), '-I'+str(ROOT/'shared'), '-framework','Foundation','-framework','CFNetwork',
                    str(path/'test.m'),str(ROOT/'daemon/RBXProfileIO.m'),str(ROOT/'shared/RBXHTTPProxy.m'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test'),str(ROOT/'profiles/catalog.json')],check=True)
