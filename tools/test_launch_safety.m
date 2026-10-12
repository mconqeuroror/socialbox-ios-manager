#import <Foundation/Foundation.h>
#import "RBXLaunchSafety.h"
#import "RBXProxyRouteEvidence.h"
#import "RBXSetupChecklist.h"
@interface Metric : NSObject
@property NSURLSessionTaskMetricsResourceFetchType resourceFetchType;
@property(getter=isProxyConnection) BOOL proxyConnection;
@property NSURLResponse *response;
@property NSString *remoteAddress;
@property NSNumber *remotePort;
@end
@implementation Metric
@end
int main(void) { @autoreleasepool {
    NSDictionary *clear=@{@"containers":@{@"a":@{},@"b":@{@"sentinelAlert":@YES}},@"alerts":@[]};
    NSCAssert(!RBXIsolationLaunchBlock(clear,@"a"), @"Sibling alert does not quarantine innocent profile");
    NSCAssert(RBXIsolationLaunchBlock(clear,@"b"), @"Retained alert blocks next launch");
    NSCAssert(RBXIsolationLaunchBlock(@{@"containers":@{@"a":@{@"sentinelAlert":@YES,@"isolationSentinel":@{@"enabled":@NO}}}},@"a"), @"OFF cannot bypass quarantine");
    NSCAssert(RBXIsolationLaunchBlock(@{@"containers":@{@"a":@{}},@"alerts":@[@{@"containerId":@"a",@"type":@"ISOLATION SENTINEL"}]},@"a"), @"Historical alert blocks even before flag migration");
    for (id state in @[NSNull.null,@{},@{@"containers":@{@"a":@{}},@"alerts":@"broken"},@{@"containers":@{@"a":@{@"sentinelAlert":@"no"}}}])
        NSCAssert(RBXIsolationLaunchBlock(state,@"a"), @"Unreadable or malformed safety state cannot authorize launch");
    NSCAssert([RBXProxyRouteVerdict(nil,@[@"127.0.0.1"],8080) isEqual:@"NOT_RUN"] && [RBXProxyRouteVerdict(@[],@[@"127.0.0.1"],8080) isEqual:@"NOT_RUN"], @"No route metrics means no proof");
    Metric *proxy=[Metric new];proxy.proxyConnection=YES;proxy.resourceFetchType=NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad;
    proxy.remoteAddress=@"127.0.0.1";proxy.remotePort=@8080;
    proxy.response=[[NSURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.invalid"] MIMEType:nil expectedContentLength:1 textEncodingName:nil];
    NSCAssert([RBXProxyRouteVerdict(@[proxy],@[@"127.0.0.1"],8080) isEqual:@"PASS"], @"Network transaction through proxy");
    Metric *direct=[Metric new];direct.remoteAddress=@"127.0.0.2";direct.remotePort=@8080;direct.resourceFetchType=NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad;direct.response=proxy.response;
    NSCAssert([RBXProxyRouteVerdict(@[proxy,direct],@[@"127.0.0.1"],8080) isEqual:@"LEAK"], @"One direct redirected transaction rejects the whole check");
    direct.resourceFetchType=NSURLSessionTaskMetricsResourceFetchTypeLocalCache;
    NSCAssert([RBXProxyRouteVerdict(@[proxy,direct],@[@"127.0.0.1"],8080) isEqual:@"NOT_RUN"], @"Cache cannot prove a current connection");
    proxy.response=nil;NSCAssert([RBXProxyRouteVerdict(@[proxy],@[@"127.0.0.1"],8080) isEqual:@"NOT_RUN"], @"Incomplete transaction cannot pass");
    puts("PASS: isolation quarantine, malformed safety state and proxy route evidence");
    NSDictionary *state=@{@"updatedAt":@100,@"configuration":@{@"configured":@YES,@"readable":@YES,@"updatedAt":@90}};
    NSDictionary *test=@{@"testedAt":@99,@"configurationUpdatedAt":@90,@"ok":@YES};
    NSCAssert(RBXProxyTestCurrent(state,test,105), @"Same configuration and fresh test");
    NSCAssert(!RBXProxyTestCurrent(state,@{@"testedAt":@99,@"configurationUpdatedAt":@89},105), @"Changing credentials/selection invalidates old green");
    NSCAssert(!RBXProxyTestCurrent(state,test,111), @"Stale service cannot show a green test");
    NSCAssert(!RBXProxyTestCurrent(state,@{@"testedAt":@106,@"configurationUpdatedAt":@90},105), @"Future tests rejected");
    for (NSDictionary *row in RBXSetupChecklist(@{},100)) NSCAssert(![row[@"status"] isEqual:@"PASS"], @"Missing setup never green");
    NSMutableDictionary *ready=[state mutableCopy];
    ready[@"configurationTest"]=test; ready[@"source"]=@{@"decrypted":@YES};
    ready[@"license"]=@{@"unlocked":@YES,@"expiresAt":@200};ready[@"firewallSetup"]=@{@"ready":@YES};
    ready[@"operationRecovery"]=@{};ready[@"profileWarning"]=@"";ready[@"deletionWarning"]=@"";
    ready[@"containers"]=@[@{@"managedInstallation":@{@"verified":@YES,@"checkedAt":@100},@"launchBlockReason":@""}];
    for (NSDictionary *row in RBXSetupChecklist(ready,105)) {
        NSCAssert([row[@"status"] isEqual:[row[@"id"] isEqual:@"acceptance"] ? @"NOT_RUN" : @"PASS"], @"Green scoped setup never invents packet/A-B proof");
    }
    puts("PASS: red/green setup checklist, configuration binding and expiry");
    NSDictionary *oldSuccess=@{@"ok":@YES,@"testedAt":@100,@"updatedAt":@101};
    NSDictionary *newFailure=@{@"ok":@NO,@"testedAt":@110};
    NSCAssert([RBXLatestProxyTest(newFailure,oldSuccess)[@"ok"] isEqual:@NO], @"Cached success cannot hide a newer failure from another screen");
    NSCAssert([RBXLatestProxyTest(@{@"ok":@NO,@"pending":@YES,@"testedAt":@110},oldSuccess)[@"pending"] isEqual:@YES], @"New test invalidates earlier success immediately");
    NSCAssert([RBXLatestProxyTest(oldSuccess,@{@"ok":@NO,@"updatedAt":@110})[@"ok"] isEqual:@NO], @"Timeout receipt overrides old success even without testedAt");
} return 0; }
