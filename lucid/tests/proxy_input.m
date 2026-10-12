#import <Foundation/Foundation.h>
#import "../ProxyInput/LBXProxyInput.h"
static NSUInteger checks, failures;
static NSMutableArray *calls;
static void Check(BOOL ok, NSString *label) { checks++; if (!ok) { failures++; fprintf(stderr,"FAIL: %s\n",label.UTF8String); } }
@interface ProxyViewController : NSObject
@end
@implementation ProxyViewController
- (void)addHTTPProxyWithHost:(NSString *)host port:(NSInteger)port user:(NSString *)user password:(NSString *)password title:(NSString *)title tls:(BOOL)tls {
    [calls addObject:@{ @"host":host,@"port":@(port),@"user":user?:@"",@"password":password?:@"",@"tls":@(tls),@"kind":@"http",@"title":title?:@"" }];
}
- (void)addSOCKS5ProxyWithHost:(NSString *)host port:(NSInteger)port user:(NSString *)user password:(NSString *)password title:(NSString *)title rotationUrl:(NSString *)rotation {
    [calls addObject:@{ @"host":host,@"port":@(port),@"user":user?:@"",@"password":password?:@"",@"kind":@"socks5",@"title":title?:@"",@"rotation":rotation?:@"" }];
}
- (void)openProxyImportURL:(NSString *)url { [calls addObject:@{@"kind":@"legacy",@"value":url}]; }
@end
@interface UnrelatedController : ProxyViewController @end
@implementation UnrelatedController @end
static LBXProxyInputPlan *Plan(NSString *s) { return LBXPlanProxyInput(s); }
int main(void) { @autoreleasepool {
    calls=[NSMutableArray array]; ProxyViewController *controller=[ProxyViewController new];
    NSArray *good=@[
        @[@"HTTP proxy.example:8080:user:pa:ss@word%2F",@"http",@"proxy.example",@8080,@"user",@"pa:ss@word%2F"],
        @[@"https://user:p%3Ass%40word@PROXY.EXAMPLE:8443/",@"https",@"proxy.example",@8443,@"user",@"p:ss@word"],
        @[@" SOCKS5 [2001:db8::1]:1080:u:p ",@"socks5",@"2001:db8::1",@1080,@"u",@"p "],
        @[@"proxy.example:1080",@"socks5",@"proxy.example",@1080,@"",@""],
        @[@"HTTP u:p%2F@proxy.example:80",@"http",@"proxy.example",@80,@"u",@"p%2F"],
        @[@"socks://u:p@proxy.example:1080",@"socks5",@"proxy.example",@1080,@"u",@"p"],
        @[@"http://u:p%252F@proxy.example:80",@"http",@"proxy.example",@80,@"u",@"p%2F"],
        @[@"HTTP proxy.example:80:user:pass ",@"http",@"proxy.example",@80,@"user",@"pass "],
        @[@"HTTP user:pass @proxy.example:80",@"http",@"proxy.example",@80,@"user",@"pass "]
    ];
    for (NSArray *row in good) {
        LBXProxyInputPlan *p=Plan(row[0]); NSDictionary *e=p.endpoints.firstObject;
        Check(!p.useOriginalInput&&!p.issue&&p.endpoints.count==1,@"recognized endpoint never becomes subscription");
        Check([e[@"protocol"] isEqual:row[1]]&&[e[@"host"] isEqual:row[2]]&&[e[@"port"] isEqual:row[3]],@"protocol authority and port retained");
        Check([e[@"username"] isEqual:row[4]]&&[e[@"password"] isEqual:row[5]],@"credentials decoded exactly once for URLs, literally for provider text");
        NSUInteger before=calls.count; NSError *error=nil;
        Check(LBXDispatchProxyInput(controller,p,&error)&&!error&&calls.count==before+1,@"pinned original typed add called once");
        NSDictionary *c=calls.lastObject;
        Check([c[@"password"] isEqual:row[5]]&&[c[@"host"] isEqual:row[2]],@"dispatch preserves exact parsed secret and host");
        Check([c[@"tls"] boolValue]==[row[1] isEqual:@"https"],@"HTTPS never downgraded to HTTP");
    }
    for (NSString *text in @[@"https://subscriptions.example/list?token=keep",@"https://subscriptions.example",@"https://subscriptions.example:8443/list",@"vmess://preserved",@"custom-original-input"]) {
        LBXProxyInputPlan *p=Plan(text); Check(p.useOriginalInput&&!p.issue&&!p.endpoints.count,@"subscription and unknown features stay with original handler");
    }
    NSArray *bad=@[@"HTTP proxy.example:0",@"HTTP proxy.example:65536",@"HTTP proxy.example:80junk",@"HTTP proxy.example:80/u",@"http://u:p%0A@proxy.example:80",@"HTTP proxy.example:80:u:p\tbad",@"http://u:p%ZZ@proxy.example:80",@"HTTP proxy.example:80::p",@"HTTP user:p@proxy.example",@"HTTP [fe80::1%en0]:80",@"HTTP -bad.example:80",@"HTTP 127.0.0.1:80\nHTTPS bad.example:0",@"HTTP https://proxy.example:80",@"HTTP proxy.example:80\nhttps://subscriptions.example/list",@"http://proxy.example:bad",@"https://user:pass@proxy.example:bad",@"http://[broken:80",@"HTTP proxy.example:80:u:p\t"];
    bad=[bad arrayByAddingObjectsFromArray:@[@"http://",@"https:///list",@"https://sub.example:65536/list",@"https://sub.example:0/list",@"https://sub.example/list?token=%ZZ"]];
    for (NSString *text in bad) {
        LBXProxyInputPlan *p=Plan(text); NSUInteger before=calls.count;
        Check(!p.useOriginalInput&&p.issue.length&&p.endpoints.count==0,@"invalid recognized input rejects entire plan");
        Check(!LBXDispatchProxyInput(controller,p,nil)&&calls.count==before,@"invalid input performs no original add");
        Check(![p.issue containsString:@"proxy.example"]&&![p.description containsString:@"subscriptions.example"],@"errors and description exclude supplied values");
    }
    LBXProxyInputPlan *mixed=Plan(@"HTTP p.example:80:u:p\nHTTPS p.example:443:u:p\nSOCKS5 p.example:1080\nss://original-format");
    NSUInteger before=calls.count; Check(mixed.endpoints.count==4&&LBXDispatchProxyInput(controller,mixed,nil)&&calls.count==before+4,@"mixed protocols retain order and existing Shadowsocks route");
    Check(calls.count>=before+4&&[calls[before][@"kind"] isEqual:@"http"]&&[calls[before+1][@"tls"] boolValue]&&[calls[before+2][@"kind"] isEqual:@"socks5"]&&[calls.lastObject[@"value"] isEqual:@"ss://original-format"],@"typed dispatch maintains protocol choices and legacy bytes");
    LBXProxyInputPlan *dedup=Plan(@"HTTP proxy.example:80:u:p\nhttp://u:p@PROXY.EXAMPLE:80/\nHTTPS proxy.example:80:u:p");
    Check(dedup.endpoints.count==2&&[dedup.safeStatus[@"duplicateCount"] unsignedIntegerValue]==1,@"deduplicate identical endpoints without merging different protocols");
    Check(![dedup.description containsString:@"proxy.example"]&&![dedup.safeStatus.description containsString:@"username"],@"safe summaries omit all endpoint fields");
    before=calls.count;Check(!LBXDispatchProxyInput([UnrelatedController new],dedup,nil)&&calls.count==before,@"subclasses/unrelated controllers never dispatched");
    Check(!LBXDispatchProxyInput(controller,Plan(@"https://subscription.example/list"),nil),@"dispatcher cannot accidentally fetch subscription");
    for (id input in @[(id)NSNull.null,@42,@"",[@"HTTP x:80" stringByPaddingToLength:262145 withString:@"a" startingAtIndex:0]]) {
        LBXProxyInputPlan *p=LBXPlanProxyInput(input);Check(p.issue.length&&!p.useOriginalInput,@"nontext empty and oversized input rejected");
    }
    NSMutableArray *forty=[NSMutableArray array]; for(int i=0;i<40;i++)[forty addObject:[NSString stringWithFormat:@"HTTP p%d.example:80",i]];
    LBXProxyInputPlan *many=Plan([forty componentsJoinedByString:@"\r\n"]);before=calls.count;
    Check(many.endpoints.count==40&&LBXDispatchProxyInput(controller,many,nil)&&calls.count==before+40,@"forty proxy rows dispatch with no three-container restriction");
    fprintf(stdout,"%s proxy input: %lu assertions, %lu failures\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);
    return failures?1:0;
} }
