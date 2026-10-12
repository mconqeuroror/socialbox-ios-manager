#import "LBXLicenseTransport.h"
#import "LBXLicenseExchange.h"

static NSError *LBXTransportError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.socialbox.license-transport" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}
@interface LBXLicenseTransport () <NSURLSessionDataDelegate>
- (instancetype)initPrivate;
@end
@implementation LBXLicenseTransport {
    LBXLicenseExchange *_exchange;
    NSURLSession *_session;
    NSURLSessionDataTask *_task;
    NSOperationQueue *_queue;
    NSHTTPURLResponse *_response;
    NSMutableData *_data;
    NSDictionary *(^_provider)(void);
    void (^_completion)(NSDictionary *, NSError *);
    NSString *_state;
    BOOL _cancelled, _finished;
}
- (instancetype)initPrivate { return [super init]; }
+ (instancetype)startWithConfiguration:(NSDictionary *)configuration claim:(BOOL)claim
    currentConfiguration:(NSDictionary *(^)(void))provider
    completion:(void (^)(NSDictionary *, NSError *))completion error:(NSError **)error {
    if (!provider || !completion) { if(error)*error=LBXTransportError(1,@"License operation owner is missing");return nil; }
    LBXLicenseExchange *exchange=[LBXLicenseExchange exchangeWithConfiguration:configuration claim:claim error:error];
    return exchange ? [self startExchange:exchange provider:provider protocolClass:Nil completion:completion] : nil;
}
+ (instancetype)startExchange:(LBXLicenseExchange *)exchange provider:(NSDictionary *(^)(void))provider
    protocolClass:(Class)protocolClass completion:(void (^)(NSDictionary *, NSError *))completion {
    LBXLicenseTransport *owner=[[self alloc] initPrivate];
    owner->_exchange=exchange;owner->_provider=[provider copy];owner->_completion=[completion copy];
    owner->_state=@"pending";owner->_data=[NSMutableData data];
    owner->_queue=[NSOperationQueue new];owner->_queue.maxConcurrentOperationCount=1;
    owner->_queue.name=@"com.socialbox.license-transport";
    NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage=nil;config.HTTPShouldSetCookies=NO;
    config.URLCache=nil;config.URLCredentialStorage=nil;
    config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest=20;config.timeoutIntervalForResource=20;
#if LBX_LICENSE_TRANSPORT_TESTING
    if(protocolClass)config.protocolClasses=@[protocolClass];
#else
    (void)protocolClass;
#endif
    owner->_session=[NSURLSession sessionWithConfiguration:config delegate:owner delegateQueue:owner->_queue];
    owner->_task=[owner->_session dataTaskWithRequest:exchange.request];
    [owner->_task resume];return owner;
}
- (NSString *)description { return @"<LBXLicenseTransport: private credential exchange>"; }
- (NSDictionary *)safeStatus {
    @synchronized(self) { return @{@"state":_state ?: @"invalid",@"recoveredEngineAuthorized":@NO}; }
}
- (void)finish:(NSDictionary *)receipt error:(NSError *)error {
    void (^completion)(NSDictionary *,NSError *);
    @synchronized(self) {
        if(_finished)return;
        _finished=YES;
        if(_cancelled) { receipt=nil;error=LBXTransportError(2,@"License request cancelled"); }
        _state=_cancelled?@"cancelled":receipt?@"verified":@"failed";
        completion=_completion;_completion=nil;_provider=nil;
        _data=nil;_response=nil;
    }
    if(!receipt)[_exchange cancel];
    [_session invalidateAndCancel];
    if(completion)completion(receipt,error);
}
- (void)cancel {
    @synchronized(self) { if(_finished)return;_cancelled=YES;[_exchange cancel];[_task cancel]; }
    [_queue addOperationWithBlock:^{ [self finish:nil error:LBXTransportError(2,@"License request cancelled")]; }];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session;(void)task;(void)response;(void)request;
    completionHandler(nil);
    [self finish:nil error:LBXTransportError(3,@"License redirects are not allowed")];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session;(void)task;
    @synchronized(self) { if(_finished||_cancelled) { completionHandler(NSURLSessionResponseCancel);return; } }
    if(![response isKindOfClass:NSHTTPURLResponse.class] ||
       ![response.URL.absoluteString isEqual:_exchange.request.URL.absoluteString] || response.expectedContentLength>65536) {
        completionHandler(NSURLSessionResponseCancel);
        [self finish:nil error:LBXTransportError(4,@"License response endpoint or size is invalid")];return;
    }
    NSHTTPURLResponse *http=(NSHTTPURLResponse *)response;
    if(http.statusCode!=200) {
        completionHandler(NSURLSessionResponseCancel);
        // Do not expose an arbitrary server error body, URL, credential or token.
        [self finish:nil error:LBXTransportError(http.statusCode,@"License server rejected the request")];return;
    }
    _response=http;completionHandler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;(void)task;
    @synchronized(self) { if(_finished||_cancelled)return; }
    if(!_response || data.length>65536-_data.length) {
        [self finish:nil error:LBXTransportError(4,@"License response exceeds the allowed size")];return;
    }
    [_data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;(void)task;
    NSDictionary *(^provider)(void);
    @synchronized(self) { if(_finished)return;provider=_provider; }
    if(error) { [self finish:nil error:LBXTransportError(5,@"License connection is unavailable")];return; }
    NSDictionary *configuration=provider ? provider() : nil;
    NSError *verificationError=nil;
    NSDictionary *receipt=[_exchange consumeResponse:_response data:_data currentConfiguration:configuration error:&verificationError];
    [self finish:receipt error:receipt?nil:LBXTransportError(6,@"Signed license response failed verification")];
}
#if LBX_LICENSE_TRANSPORT_TESTING
+ (instancetype)testStartWithConfiguration:(NSDictionary *)configuration claim:(BOOL)claim
    currentConfiguration:(NSDictionary *(^)(void))provider protocolClass:(Class)protocolClass
    publicKeyDER:(NSData *)key keyID:(NSString *)keyID
    completion:(void (^)(NSDictionary *, NSError *))completion error:(NSError **)error {
    if(!provider||!completion||!protocolClass)return nil;
    LBXLicenseExchange *exchange=[LBXLicenseExchange testExchangeWithConfiguration:configuration claim:claim
        publicKeyDER:key keyID:keyID error:error];
    return exchange?[self startExchange:exchange provider:provider protocolClass:protocolClass completion:completion]:nil;
}
#endif
@end
