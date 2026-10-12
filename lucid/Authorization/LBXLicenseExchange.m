#import "LBXLicenseExchange.h"
#import "../../daemon/RBXLicenseToken.h"
#import <math.h>

static NSError *LBXExchangeError(NSString *message) {
    return [NSError errorWithDomain:@"com.socialbox.license-exchange" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL LBXMatch(NSString *value, NSString *pattern) {
    // ICU '$' accepts a position before a terminal line separator. Pairing
    // identifiers and bearer headers must match every code unit, not a prefix.
    NSRange match=[value rangeOfString:pattern options:NSRegularExpressionSearch];
    return NSEqualRanges(match,NSMakeRange(0,value.length));
}
static NSDictionary *LBXConfiguration(id input) {
    if (![input isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for (NSString *field in @[@"server",@"deviceIdentity",@"key",@"deviceId",@"deviceToken"]) {
        id value=input[field] ?: @"";
        if (![value isKindOfClass:NSString.class] || [value length]>4096) return nil;
        result[field]=[value copy];
    }
    id revision=input[@"revision"];
    if (![revision isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)revision)==CFBooleanGetTypeID()
        || !isfinite([revision doubleValue]) || [revision doubleValue]<0 || [revision doubleValue]>=9007199254740992.0
        || floor([revision doubleValue])!=[revision doubleValue]) return nil;
    result[@"revision"]=[revision copy];
    NSString *server=[RBXLicenseToken canonicalServer:result[@"server"]];
    NSString *identity=[result[@"deviceIdentity"] lowercaseString];
    NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:identity];
    if (!server || !uuid || ![uuid.UUIDString.lowercaseString isEqual:identity]) return nil;
    NSString *key=[[result[@"key"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
    if (key.length && !LBXMatch(key,@"^[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$")) return nil;
    if ([result[@"deviceId"] length] && !LBXMatch(result[@"deviceId"],@"^[A-Za-z0-9_-]{1,128}$")) return nil;
    if ([result[@"deviceToken"] length] && !LBXMatch(result[@"deviceToken"],@"^[0-9a-f]{64}$")) return nil;
    result[@"server"]=server; result[@"deviceIdentity"]=identity; result[@"key"]=key;
    return [result copy];
}

@implementation LBXLicenseExchange {
    NSDictionary *_configuration;
    NSURLRequest *_request;
    NSString *_nonce, *_state;
    BOOL _claim;
    NSTimeInterval _startedWall, _startedUptime;
#if LBX_LICENSE_EXCHANGE_TESTING
    NSData *_testKey;
    NSString *_testKeyID;
    NSTimeInterval (^_testClock)(BOOL);
    void (^_testBeforeVerification)(void);
#endif
}
+ (instancetype)exchangeWithConfiguration:(NSDictionary *)configuration claim:(BOOL)claim error:(NSError **)error {
    NSDictionary *snapshot=LBXConfiguration(configuration);
    if (!snapshot || (![snapshot[@"key"] length] && ![snapshot[@"deviceToken"] length])
        || (!claim && (![snapshot[@"deviceToken"] length] || ![snapshot[@"deviceId"] length]))) {
        if (error) *error=LBXExchangeError(@"License configuration is incomplete or invalid"); return nil;
    }
    LBXLicenseExchange *exchange=[[self alloc] initPrivate];
    exchange->_configuration=snapshot; exchange->_claim=claim;
    exchange->_nonce=NSUUID.UUID.UUIDString.lowercaseString;
    exchange->_state=@"pending";
    exchange->_startedWall=NSDate.date.timeIntervalSince1970;
    exchange->_startedUptime=NSProcessInfo.processInfo.systemUptime;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:[snapshot[@"server"]
        stringByAppendingString:claim ? @"/api/devices/claim" : @"/api/licenses/validate"]]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    request.HTTPMethod=@"POST"; request.HTTPShouldHandleCookies=NO;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([snapshot[@"deviceToken"] length]) [request setValue:[@"Bearer " stringByAppendingString:snapshot[@"deviceToken"]]
        forHTTPHeaderField:@"Authorization"];
    NSMutableDictionary *body=[@{@"deviceIdentity":snapshot[@"deviceIdentity"],@"nonce":exchange->_nonce} mutableCopy];
    if ([snapshot[@"key"] length]) body[@"key"]=snapshot[@"key"];
    request.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!request.HTTPBody) return nil;
    exchange->_request=[request copy]; return exchange;
}
- (instancetype)initPrivate { return [super init]; }
- (NSTimeInterval)wallTime {
#if LBX_LICENSE_EXCHANGE_TESTING
    if (_testClock) return _testClock(NO);
#endif
    return NSDate.date.timeIntervalSince1970;
}
- (NSTimeInterval)uptime {
#if LBX_LICENSE_EXCHANGE_TESTING
    if (_testClock) return _testClock(YES);
#endif
    return NSProcessInfo.processInfo.systemUptime;
}
- (BOOL)timeIsValidAtWall:(NSTimeInterval)wall uptime:(NSTimeInterval)uptime {
    return isfinite(wall) && wall>0 && isfinite(uptime) && uptime>=0
        && wall>=_startedWall-5 && wall-_startedWall<=20
        && uptime>=_startedUptime && uptime-_startedUptime<=20;
}
- (NSURLRequest *)request { return [_request copy]; }
- (void)cancel { @synchronized(self) { _state=@"cancelled"; } }
- (NSString *)description { return @"<LBXLicenseExchange: private credential exchange>"; }
- (NSDictionary *)safeStatus {
    @synchronized(self) { return @{@"state":_state ?: @"invalid", @"scope":@"SocialBox cloud response only", @"recoveredEngineAuthorized":@NO}; }
}
- (NSDictionary *)consumeResponse:(NSHTTPURLResponse *)response data:(NSData *)data
    currentConfiguration:(NSDictionary *)configuration error:(NSError **)error {
    @synchronized(self) {
        if (![_state isEqual:@"pending"]) { if (error) *error=LBXExchangeError(@"Exchange was cancelled or already consumed"); return nil; }
        _state=@"consumed";
    }
    NSTimeInterval now=[self wallTime], uptime=[self uptime];
    if (![self timeIsValidAtWall:now uptime:uptime]
        || ![LBXConfiguration(configuration) isEqual:_configuration]) {
        if (error) *error=LBXExchangeError(@"Exchange expired or license configuration changed"); return nil;
    }
    if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode!=200
        || ![response.URL.absoluteString isEqual:_request.URL.absoluteString]
        || ![data isKindOfClass:NSData.class] || data.length>65536) {
        if (error) *error=LBXExchangeError(@"License response transport or size is invalid"); return nil;
    }
    id json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"licenseToken"] isKindOfClass:NSString.class]) {
        if (error) *error=LBXExchangeError(@"License response has no signed token"); return nil;
    }
    NSString *device=_claim ? json[@"deviceId"] : _configuration[@"deviceId"];
    if (![device isKindOfClass:NSString.class] || !LBXMatch(device,@"^[A-Za-z0-9_-]{1,128}$")
        || ([_configuration[@"deviceId"] length] && ![device isEqual:_configuration[@"deviceId"]])) {
        if (error) *error=LBXExchangeError(@"Device response does not match installation pairing"); return nil;
    }
    NSString *fingerprintInput=[_configuration[@"key"] length] ? _configuration[@"key"] : [@"admin:" stringByAppendingString:device];
    NSDictionary *expected=@{@"server":_configuration[@"server"],@"deviceId":device,
        @"deviceBinding":[RBXLicenseToken fingerprint:_configuration[@"deviceIdentity"]],
        @"keyFingerprint":[RBXLicenseToken fingerprint:fingerprintInput]};
    NSDictionary *claims=nil;
#if LBX_LICENSE_EXCHANGE_TESTING
    void (^checkpoint)(void)=_testBeforeVerification; _testBeforeVerification=nil;
    if (checkpoint) checkpoint();
    if (_testKey) claims=[RBXLicenseToken verifyToken:json[@"licenseToken"] publicKeyDER:_testKey keyID:_testKeyID
        expected:expected nonce:_nonce now:now error:error];
    else
#endif
    claims=[RBXLicenseToken verifyToken:json[@"licenseToken"] expected:expected nonce:_nonce now:now error:error];
    if (!claims) return nil;
    // Parsing/signature work can be suspended and resume after the exchange or
    // token expires. Classify the result at completion, not at the first check.
    NSTimeInterval completionWall=[self wallTime], completionUptime=[self uptime];
    if (![self timeIsValidAtWall:completionWall uptime:completionUptime] || completionUptime<uptime
        || completionWall<now-5 || [claims[@"iat"] doubleValue]>completionWall+120
        || ![LBXConfiguration(configuration) isEqual:_configuration]) {
        if (error) *error=LBXExchangeError(@"Exchange expired or license configuration changed during verification"); return nil;
    }
    now=completionWall;
    BOOL active=[claims[@"status"] isEqual:@"active"] && [claims[@"exp"] doubleValue]>now;
    NSString *status=([claims[@"status"] isEqual:@"active"] && !active) ? @"expired" : claims[@"status"];
    NSMutableDictionary *verified=[@{@"status":status,@"activeAtReceipt":@(active),@"expiresAt":claims[@"exp"],
        @"issuedAt":claims[@"iat"],@"deviceId":device,@"server":expected[@"server"],
        @"deviceBinding":expected[@"deviceBinding"],@"keyFingerprint":expected[@"keyFingerprint"],
        @"licenseToken":json[@"licenseToken"],@"requestNonce":_nonce,@"recoveredEngineAuthorized":@NO} mutableCopy];
    if (_claim && active) {
        id token=json[@"token"];
        if (![token isKindOfClass:NSString.class] || !LBXMatch(token,@"^[0-9a-f]{64}$")) {
            if (error) *error=LBXExchangeError(@"Active claim has no valid pairing credential"); return nil;
        }
        verified[@"deviceToken"]=[token copy];
    }
    @synchronized(self) {
        if ([_state isEqual:@"cancelled"]) { if (error) *error=LBXExchangeError(@"Exchange was cancelled"); return nil; }
    }
    return [verified copy];
}
#if LBX_LICENSE_EXCHANGE_TESTING
- (void)testUseClock:(NSTimeInterval (^)(BOOL))clock beforeVerification:(void (^)(void))checkpoint {
    _testClock=[clock copy]; _testBeforeVerification=[checkpoint copy];
    _startedWall=[self wallTime]; _startedUptime=[self uptime];
}
+ (instancetype)testExchangeWithConfiguration:(NSDictionary *)configuration claim:(BOOL)claim
    publicKeyDER:(NSData *)key keyID:(NSString *)keyID error:(NSError **)error {
    LBXLicenseExchange *exchange=[self exchangeWithConfiguration:configuration claim:claim error:error];
    if (exchange) { exchange->_testKey=[key copy]; exchange->_testKeyID=[keyID copy]; }
    return exchange;
}
#endif
@end
