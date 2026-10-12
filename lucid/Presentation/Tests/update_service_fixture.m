#import <Foundation/Foundation.h>
#import "SBUpdateService.h"
static NSUInteger Checks,Requests;
static NSMutableArray *Failures;
static NSData *ResponseData;
static NSInteger ResponseStatus=200;
static NSString *ResponseType=@"application/json";
static BOOL HoldResponse;
static NSURLRequest *LastRequest;
static void Check(BOOL pass,NSString *name) { Checks++;if(!pass)[Failures addObject:name]; }
static NSMutableDictionary *Manifest(void) {
    return [@{@"schemaVersion":@1,@"channel":@"stable",@"available":@YES,@"package":@"com.socialbox",@"packageVersion":@"3.1.0-1+socialbox.16",@"sequence":@16,@"supportedFrom":@[@"3.1.0-1+socialbox.15"],@"architecture":@"iphoneos-arm64",@"minimumIOS":@"16.0",@"publishedAt":@"2026-09-28T12:00:00.000Z",@"notes":@"A tested interface update.",@"sha256":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"updateURL":@"https://redditspoof.vercel.app/updates"} mutableCopy];
}
static NSString *State(id manifest) { return SBUpdateEvaluateManifest(manifest,@"3.1.0-1+socialbox.15",@"16.7.16")[@"state"]; }
@interface UpdateProtocol : NSURLProtocol @end
@implementation UpdateProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqual:@"redditspoof.vercel.app"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    @synchronized(UpdateProtocol.class) { Requests++;LastRequest=self.request; }
    if(HoldResponse)return;
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:ResponseStatus HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type":ResponseType}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:ResponseData];[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
static BOOL Wait(BOOL(^predicate)(void)) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!predicate() && end.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return predicate();
}
static void Reply(id json) { ResponseData=[NSJSONSerialization dataWithJSONObject:json options:0 error:nil];ResponseStatus=200;ResponseType=@"application/json";HoldResponse=NO; }
static void Run(SBUpdateService *service) {
    [service checkForUpdates];Check(Wait(^BOOL{return ![service.snapshot[@"state"] isEqual:@"checking"];}),@"network fixture completes");
}
@interface SBUpdateService (DelegateTest)
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion;
@end
int main(void) { @autoreleasepool {
    Failures=[NSMutableArray array];
    Check([SBUpdateSequence(@"3.1.0-1+socialbox.15") isEqual:@15],@"derivative version uses SocialBox sequence");
    for(id value in @[@"3.1.0",@"3.1.0-1+socialbox.015",@"3.1.0-1+socialbox.0",@"3.1.0-1+socialbox.16\n",@"3.1.0-1+socialbox.2147483648",@16,NSNull.null])Check(!SBUpdateSequence(value),@"unsupported installed version rejected");
    Check([State(Manifest()) isEqual:@"available"],@"exact supported successor offered");
    Check([SBUpdateEvaluateManifest(Manifest(),@"3.1.0-1+socialbox.16",@"16.7")[@"state"] isEqual:@"current"],@"same version current");
    Check([SBUpdateEvaluateManifest(Manifest(),@"3.1.0-1+socialbox.17",@"16.7")[@"state"] isEqual:@"current"],@"private newer candidate never downgraded");
    Check([SBUpdateEvaluateManifest(Manifest(),@"3.1.0-1+socialbox.13",@"16.7")[@"state"] isEqual:@"incompatible"],@"skipped unsupported predecessor not offered");
    Check([SBUpdateEvaluateManifest(Manifest(),@"3.1.0-1+socialbox.15",@"15.8")[@"state"] isEqual:@"incompatible"],@"minimum system enforced");
    Check([SBUpdateEvaluateManifest(Manifest(),@"3.1.0-1+socialbox.15",@"16.10")[@"state"] isEqual:@"available"],@"system version comparison is numeric");
    Check([State(@{@"schemaVersion":@1,@"channel":@"stable",@"available":@NO}) isEqual:@"no-release"],@"empty stable pointer does not claim up to date");
    for(id wrong in @[@[],NSNull.null,@{},@{@"schemaVersion":@YES,@"channel":@"stable",@"available":@NO},@{@"schemaVersion":@1,@"channel":@"candidate",@"available":@NO},@{@"schemaVersion":@1,@"channel":@"stable",@"available":@0}])Check([State(wrong) isEqual:@"unavailable"],@"malformed manifest safely unavailable");
    NSArray *invalid=@[@[@"schemaVersion",@2],@[@"channel",@"beta"],@[@"available",@1],@[@"package",@"com.other.app"],@[@"packageVersion",@"3.1.0"],@[@"sequence",@YES],@[@"sequence",@17],@[@"sequence",@16.1],@[@"architecture",@"iphoneos-arm"],@[@"minimumIOS",@"16"],@[@"minimumIOS",NSNull.null],@[@"supportedFrom",@"3.1.0-1+socialbox.15"],@[@"supportedFrom",@[]],@[@"supportedFrom",@[@"bad"]],@[@"supportedFrom",@[@"3.1.0-1+socialbox.16"]],@[@"supportedFrom",@[@"3.1.0-1+socialbox.15",@"3.1.0-1+socialbox.15"]],@[@"sha256",@"abc"],@[@"notes",NSNull.null],@[@"notes",[@"n" stringByPaddingToLength:2001 withString:@"n" startingAtIndex:0]],@[@"publishedAt",@"not a date"],@[@"publishedAt",NSNull.null],@[@"updateURL",@"http://redditspoof.vercel.app/updates"],@[@"updateURL",@"https://evil.test/updates"],@[@"updateURL",@"https://redditspoof.vercel.app/updates?key=anything"]];
    for(NSArray *entry in invalid) { NSMutableDictionary *m=Manifest();m[entry[0]]=entry[1];Check([State(m) isEqual:@"unavailable"],[@"reject field: " stringByAppendingString:entry[0]]); }
    Check([SBUpdatePageURL().absoluteString isEqual:@"https://redditspoof.vercel.app/updates"],@"only fixed owned instructions URL");
    NSArray *expectedURLs=@[@"sileo://source/https://redditspoof.vercel.app/apt/socialbox/",
                            @"zbra://sources/add/https://redditspoof.vercel.app/apt/socialbox/",
                            @"https://redditspoof.vercel.app/updates"];
    for(NSUInteger successIndex=0;successIndex<4;successIndex++) {
        NSMutableArray *opened=[NSMutableArray array];__block NSUInteger completed=0;__block BOOL outcome=NO;
        SBUpdateOpenRelease(@{@"state":@"available",@"updateURL":@"https://untrusted.invalid/"},^(NSURL *url,void (^reply)(BOOL)){
            [opened addObject:url.absoluteString];reply(opened.count-1==successIndex);
            reply(NO); // A repeated old callback must not launch another app.
        },^(BOOL value){completed++;outcome=value;});
        Check([opened isEqual:[expectedURLs subarrayWithRange:NSMakeRange(0,MIN(successIndex+1,3))]],@"handoff tries only fixed Sileo, Zebra, web URLs in order");
        Check(completed==1 && outcome==(successIndex<3),@"handoff completes exactly once after success or exhausted fallback");
    }
    for(NSString *state in @[@"unchecked",@"checking",@"no-release",@"unavailable",@"incompatible",@"current"]) {
        __block NSUInteger opened=0,completed=0;
        SBUpdateOpenRelease(@{@"state":state},^(__unused NSURL *url,__unused void (^reply)(BOOL)){opened++;},
            ^(BOOL value){if(!value)completed++;});
        Check(opened==0 && completed==1,@"nonavailable release never opens a package manager");
    }
    __block void (^pendingReply)(BOOL);NSMutableArray *asyncURLs=[NSMutableArray array];__block BOOL asyncCompleted=NO;
    SBUpdateOpenRelease(@{@"state":@"available"},^(NSURL *url,void (^reply)(BOOL)){
        [asyncURLs addObject:url.absoluteString];pendingReply=[reply copy];
    },^(BOOL opened){asyncCompleted=opened;});
    Check(asyncURLs.count==1 && !asyncCompleted,@"handoff waits for actual open completion");
    void (^firstReply)(BOOL)=[pendingReply copy];firstReply(NO);
    Check(asyncURLs.count==2 && !asyncCompleted,@"failed asynchronous Sileo open advances to Zebra");
    pendingReply(YES);firstReply(NO);
    Check(asyncURLs.count==2 && asyncCompleted,@"Zebra success prevents web fallback and late callback effects");
    pendingReply=nil;
    NSString *suite=[@"com.socialbox.updates.fixture." stringByAppendingString:NSUUID.UUID.UUIDString];NSUserDefaults *defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.protocolClasses=@[UpdateProtocol.class];
    SBUpdateService *service=[[SBUpdateService alloc] initWithInstalledVersion:@"3.1.0-1+socialbox.15" systemVersion:@"16.7.16" configuration:configuration defaults:defaults];
    Check([service.snapshot[@"state"] isEqual:@"unchecked"] && Requests==0,@"service creation and state read issue no request");
    Reply(Manifest());Run(service);
    Check([service.snapshot[@"state"] isEqual:@"available"]&&Requests==1,@"explicit check publishes available result");
    Check([LastRequest.URL.absoluteString isEqual:@"https://redditspoof.vercel.app/api/releases/socialbox/latest"]&&[LastRequest.HTTPMethod isEqual:@"GET"]&&!LastRequest.HTTPBody&&!LastRequest.URL.query,@"fixed metadata-only GET contains no identifiers");
    Check(![LastRequest valueForHTTPHeaderField:@"Authorization"]&&![LastRequest valueForHTTPHeaderField:@"Cookie"],@"no license or session credentials sent");
    NSURLSessionConfiguration *actual=[service valueForKey:@"configuration"];
    Check(!actual.HTTPCookieStorage&&!actual.HTTPShouldSetCookies&&!actual.URLCache&&!actual.URLCredentialStorage,@"ephemeral metadata request has no shared credentials cookies or cache");
    Check(actual.timeoutIntervalForRequest==12&&actual.timeoutIntervalForResource==20,@"network work has bounded timeouts");
    [service checkAutomaticallyIfDue];Check(Requests==1,@"automatic check is rate limited after manual check");
    [defaults setDouble:NSDate.date.timeIntervalSince1970-21601 forKey:@"lastAttempt"];[service checkAutomaticallyIfDue];
    Check(Wait(^BOOL{return Requests==2 && ![service.snapshot[@"state"] isEqual:@"checking"];}),@"automatic check runs after six hours");
    ResponseData=[@"invalid json" dataUsingEncoding:NSUTF8StringEncoding];Run(service);Check([service.snapshot[@"state"] isEqual:@"unavailable"],@"invalid response does not retain stale update success");
    Reply(Manifest());ResponseStatus=503;Run(service);Check([service.snapshot[@"state"] isEqual:@"unavailable"],@"non-200 unavailable");
    Reply(Manifest());ResponseType=@"text/html";Run(service);Check([service.snapshot[@"state"] isEqual:@"unavailable"],@"HTML login page cannot masquerade as release");
    Reply(Manifest());ResponseData=[NSMutableData dataWithLength:64*1024+1];Run(service);Check([service.snapshot[@"state"] isEqual:@"unavailable"],@"streamed body above 64KiB is cancelled");
    Reply(Manifest());HoldResponse=YES;NSUInteger before=Requests;[service checkForUpdates];[service checkForUpdates];
    Check(Wait(^BOOL{return Requests==before+1;}),@"concurrent checks coalesce to one request");
    NSURLSession *oldSession=[service valueForKey:@"session"];NSURLSessionTask *oldTask=[service valueForKey:@"task"];
    __block BOOL redirectRejected=NO;
    [service URLSession:oldSession task:oldTask willPerformHTTPRedirection:[[NSHTTPURLResponse alloc] initWithURL:LastRequest.URL statusCode:302 HTTPVersion:nil headerFields:nil] newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://elsewhere.test/release"]] completionHandler:^(NSURLRequest *request){redirectRejected=request==nil;}];
    Check(redirectRejected&&[service.snapshot[@"state"] isEqual:@"unavailable"],@"all redirects rejected without forwarding request");
    Reply(Manifest());HoldResponse=YES;before=Requests;[service checkForUpdates];
    Check(Wait(^BOOL{return Requests==before+1;}),@"new request starts after cancelled predecessor");
    NSURLSession *currentSession=[service valueForKey:@"session"];NSURLSessionDataTask *currentTask=[service valueForKey:@"task"];
    NSHTTPURLResponse *okResponse=[[NSHTTPURLResponse alloc] initWithURL:LastRequest.URL statusCode:200 HTTPVersion:nil headerFields:@{@"Content-Type":@"application/json"}];
    [service URLSession:currentSession dataTask:currentTask didReceiveResponse:okResponse completionHandler:^(__unused NSURLSessionResponseDisposition disposition){}];
    [service URLSession:oldSession dataTask:(id)oldTask didReceiveResponse:okResponse completionHandler:^(__unused NSURLSessionResponseDisposition disposition){}];
    Check([[service valueForKey:@"responseAccepted"] boolValue],@"late old response cannot corrupt current response acceptance");
    [service URLSession:currentSession task:currentTask willPerformHTTPRedirection:nil newRequest:nil completionHandler:^(__unused NSURLRequest *request){}];
    Reply(@{@"schemaVersion":@1,@"channel":@"stable",@"available":@NO});Run(service);
    [service URLSession:oldSession task:oldTask willPerformHTTPRedirection:nil newRequest:nil completionHandler:^(__unused NSURLRequest *request){}];
    Check([service.snapshot[@"state"] isEqual:@"no-release"],@"late old-session callback cannot overwrite current result");
    [defaults removePersistentDomainForName:suite];
    NSDictionary *result=@{@"ok":@(!Failures.count),@"checks":@(Checks),@"requests":@(Requests),@"failures":Failures,@"scope":@"Native Foundation evaluator and mocked transport; no production network"};
    [NSFileHandle.fileHandleWithStandardOutput writeData:[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]];return Failures.count?1:0;
} }
