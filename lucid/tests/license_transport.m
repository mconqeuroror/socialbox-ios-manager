#import "../Authorization/LBXLicenseTransport.h"
#import "../../tests/RBXLicenseTestSupport.h"

static NSUInteger checks,failures,requests;
static NSString *mode;
static void Check(BOOL ok,NSString *why) { checks++;if(!ok){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);} }
static NSString *const Key=@"AAAA-BBBB-CCCC-DDDD";
static NSDictionary *Config(void) {
    return @{@"server":@"https://license.example.test",@"deviceIdentity":TestLicenseIdentity,@"key":Key,
        @"deviceId":@"fixture-device",@"deviceToken":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"revision":@1};
}
@interface LicenseProtocol:NSURLProtocol
@end
@implementation LicenseProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request;return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)stopLoading {}
- (void)startLoading {
    requests++;
    Check([self.request.URL.scheme isEqual:@"https"],@"HTTPS request");
    Check([self.request.HTTPMethod isEqual:@"POST"]&&!self.request.HTTPShouldHandleCookies,@"credential request method and cookie policy");
    if([mode isEqual:@"hang"])return;
    if([mode isEqual:@"network"]) { [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey:@"SECRET ERROR CONTENT"}]];return; }
    if([mode isEqual:@"redirect"]) {
        NSURLRequest *next=[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://foreign.example.test/steal"]];
        NSHTTPURLResponse *redirect=[[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:302 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Location":next.URL.absoluteString}];
        [self.client URLProtocol:self wasRedirectedToRequest:next redirectResponse:redirect];return;
    }
    NSData *body=self.request.HTTPBody;
    if(!body && self.request.HTTPBodyStream) {
        NSInputStream *stream=self.request.HTTPBodyStream;[stream open];NSMutableData *bytes=[NSMutableData data];uint8_t buffer[1024];NSInteger n;
        while((n=[stream read:buffer maxLength:sizeof(buffer)])>0)[bytes appendBytes:buffer length:(NSUInteger)n];[stream close];body=bytes;
    }
    NSDictionary *request=[NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSMutableDictionary *claims=TestLicenseClaims(Key,request[@"nonce"],NSDate.date.timeIntervalSince1970);
    if([mode isEqual:@"revoked"])claims[@"status"]=@"revoked";
    if([mode isEqual:@"wrong-device"])claims[@"sub"]=@"different-device";
    NSDictionary *reply=@{@"licenseToken":TestLicenseJWT(claims,nil),@"deviceId":@"fixture-device",@"token":Config()[@"deviceToken"]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if([mode isEqual:@"malformed"])data=[@"invalid JSON" dataUsingEncoding:NSUTF8StringEncoding];
    if([mode isEqual:@"stream-overflow"])data=[NSMutableData dataWithLength:65537];
    NSURL *url=[mode isEqual:@"wrong-url"]?[NSURL URLWithString:@"https://foreign.example.test/response"]:self.request.URL;
    NSDictionary *headers=[mode isEqual:@"length-overflow"]?@{@"Content-Length":@"65537"}:@{};
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:url statusCode:[mode isEqual:@"rejected"]?409:200 HTTPVersion:@"HTTP/1.1" headerFields:headers];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if([mode isEqual:@"stream-overflow"]) {
        [self.client URLProtocol:self didLoadData:[data subdataWithRange:NSMakeRange(0,32768)]];
        [self.client URLProtocol:self didLoadData:[data subdataWithRange:NSMakeRange(32768,data.length-32768)]];
    } else [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
@end

int main(void) { @autoreleasepool {
    for(NSString *kind in @[@"active",@"revoked",@"network",@"redirect",@"wrong-device",@"malformed",@"stream-overflow",@"length-overflow",@"wrong-url",@"rejected",@"stale",@"hang"]) {
        mode=kind;requests=0;__block NSUInteger completions=0;__block NSDictionary *receipt;__block NSError *receivedError;
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        LBXLicenseTransport *transport=[LBXLicenseTransport testStartWithConfiguration:Config() claim:YES
            currentConfiguration:^NSDictionary *{ if([kind isEqual:@"stale"]){NSMutableDictionary *changed=[Config() mutableCopy];changed[@"revision"]=@2;return changed;}return Config(); }
            protocolClass:LicenseProtocol.class publicKeyDER:TestLicensePublicDER() keyID:TestLicenseKeyID()
            completion:^(NSDictionary *value,NSError *error){completions++;receipt=value;receivedError=error;dispatch_semaphore_signal(done);} error:nil];
        Check(transport!=nil,@"valid transport starts");
        Check(![transport.description containsString:Key]&&![transport.safeStatus.description containsString:Config()[@"deviceToken"]],@"diagnostics omit secrets");
        if([kind isEqual:@"hang"]){[transport cancel];[transport cancel];}
        Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))==0,@"bounded completion");
        Check(completions==1,@"single completion");
        if([kind isEqual:@"active"]||[kind isEqual:@"revoked"]) {
            Check(receipt!=nil&&receivedError==nil,@"authentic receipt returned");
            Check([receipt[@"activeAtReceipt"] boolValue]==[kind isEqual:@"active"],@"signed revoked verdict preserved");
            Check(![receipt[@"recoveredEngineAuthorized"] boolValue],@"transport does not grant retained-engine access");
        } else {
            Check(receipt==nil&&receivedError!=nil,[@"failure cannot return a receipt: " stringByAppendingString:kind]);
            Check(![receivedError.description containsString:@"SECRET ERROR CONTENT"],@"transport errors redacted");
            if([kind isEqual:@"rejected"])Check(receivedError.code==409,@"bounded HTTP status preserved for recovery");
            if([kind isEqual:@"redirect"])Check(requests==1,@"redirect did not forward credentials");
        }
        Check(![transport.safeStatus[@"state"] isEqual:@"pending"],@"terminal state");
        [transport cancel];
    }
    NSLog(@"%@: %lu license transport assertions, %lu failures (mock transport, real signatures)",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);
    return failures?1:0;
} }
