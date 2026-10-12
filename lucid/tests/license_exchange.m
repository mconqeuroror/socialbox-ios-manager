#import "../Authorization/LBXLicenseExchange.h"
#import "../../tests/RBXLicenseTestSupport.h"
#import <math.h>

static NSUInteger checks, failures;
static void Check(BOOL ok, NSString *reason) { checks++; if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", reason.UTF8String); } }
static NSString *const AccessKey = @"AAAA-BBBB-CCCC-DDDD";
static NSString *Bearer(void) { return [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0]; }
static NSDictionary *Config(void) {
    return @{@"server":@"https://license.example.test", @"deviceIdentity":TestLicenseIdentity,
             @"key":AccessKey, @"deviceId":@"fixture-device", @"deviceToken":Bearer(), @"revision":@1};
}
static LBXLicenseExchange *Exchange(NSDictionary *config, BOOL claim) {
    return [LBXLicenseExchange testExchangeWithConfiguration:config claim:claim
        publicKeyDER:TestLicensePublicDER() keyID:TestLicenseKeyID() error:nil];
}
static NSDictionary *Reply(LBXLicenseExchange *exchange, NSDictionary *overrides) {
    NSDictionary *body = [NSJSONSerialization JSONObjectWithData:exchange.request.HTTPBody options:0 error:nil];
    NSMutableDictionary *claims = TestLicenseClaims(AccessKey, body[@"nonce"], NSDate.date.timeIntervalSince1970);
    [claims addEntriesFromDictionary:overrides ?: @{}];
    return @{@"licenseToken":TestLicenseJWT(claims,nil), @"deviceId":@"fixture-device", @"token":Bearer(),
             @"valid":@YES, @"name":@"UNTRUSTED SECRET", @"role":@"admin"};
}
static NSDictionary *Consume(LBXLicenseExchange *exchange, NSDictionary *reply, NSInteger code, NSString *url, NSDictionary *configuration) {
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:url ?: exchange.request.URL.absoluteString]
        statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:@{}];
    return [exchange consumeResponse:response data:[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]
        currentConfiguration:configuration ?: Config() error:nil];
}
int main(void) { @autoreleasepool {
    LBXLicenseExchange *exchange=Exchange(Config(),NO);
    Check(exchange != nil,@"valid existing configuration accepted");
    Check([exchange.request.URL.path isEqual:@"/api/licenses/validate"],@"validation endpoint");
    Check([exchange.request.HTTPMethod isEqual:@"POST"],@"POST method");
    Check(!exchange.request.HTTPShouldHandleCookies,@"no cookies");
    Check([exchange.request.allHTTPHeaderFields[@"Authorization"] isEqual:[@"Bearer " stringByAppendingString:Bearer()]],@"device bearer");
    NSDictionary *reply=Reply(exchange,nil);
    NSDictionary *accepted=Consume(exchange,reply,200,nil,nil);
    Check([accepted[@"status"] isEqual:@"active"],@"authentic signed reply accepted");
    Check(!accepted[@"role"] && !accepted[@"name"] && !accepted[@"valid"],@"unsigned metadata never forwarded as authority");
    Check(!Consume(exchange,reply,200,nil,nil),@"replay consumed once");
    Check([[exchange safeStatus][@"state"] isEqual:@"consumed"],@"safe consumed status");
    Check(![[exchange description] containsString:Bearer()],@"description omits bearer");
    Check(![[exchange safeStatus].description containsString:AccessKey],@"status omits key");
    for (NSString *status in @[@"revoked",@"invalid",@"expired"]) {
        exchange=Exchange(Config(),NO);
        accepted=Consume(exchange,Reply(exchange,@{@"status":status}),200,nil,nil);
        Check([accepted[@"status"] isEqual:status],@"signed denial retained");
        Check(![accepted[@"activeAtReceipt"] boolValue],@"denial never active");
    }
    exchange=Exchange(Config(),NO);
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    accepted=Consume(exchange,Reply(exchange,@{@"iat":@((long long)now-100), @"exp":@((long long)now-1)}),200,nil,nil);
    Check([accepted[@"status"] isEqual:@"expired"] && ![accepted[@"activeAtReceipt"] boolValue],@"expired signed active token does not grant");
    for (NSDictionary *change in @[@{@"sub":@"other-device"},@{@"nonce":@"wrong-request"},@{@"deviceBinding":@"other-installation"},
                                   @{@"keyFingerprint":@"other-key"},@{@"iss":@"https://other.test"}]) {
        exchange=Exchange(Config(),NO);
        Check(!Consume(exchange,Reply(exchange,change),200,nil,nil),@"signed wrong binding rejected");
    }
    exchange=Exchange(Config(),NO);
    Check(!Consume(exchange,@{@"valid":@YES},200,nil,nil),@"unsigned valid flag rejected");
    for (NSNumber *status in @[@301,@401,@403,@429,@500]) {
        exchange=Exchange(Config(),NO);
        Check(!Consume(exchange,Reply(exchange,nil),status.integerValue,nil,nil),@"non-200 cannot authorize");
    }
    for (NSString *url in @[@"http://license.example.test/api/licenses/validate",@"https://other.test/api/licenses/validate",
                           @"https://license.example.test/api/devices/claim"]) {
        exchange=Exchange(Config(),NO);
        Check(!Consume(exchange,Reply(exchange,nil),200,url,nil),@"response endpoint bound");
    }
    exchange=Exchange(Config(),NO); reply=Reply(exchange,nil); [exchange cancel];
    Check(!Consume(exchange,reply,200,nil,nil),@"cancelled reply rejected");
    for (NSString *field in @[@"server",@"deviceIdentity",@"key",@"deviceId",@"deviceToken"]) {
        exchange=Exchange(Config(),NO); NSMutableDictionary *changed=[Config() mutableCopy]; changed[field]=@"changed";
        Check(!Consume(exchange,Reply(exchange,nil),200,nil,changed),@"changed configuration rejects pending reply");
    }
    for (NSDictionary *change in @[@{@"server":@"http://license.example.test"},@{@"server":@"https://user:pass@license.example.test"},
                                    @{@"deviceIdentity":@"serial-number"},@{@"key":@[]},@{@"deviceToken":@"bad"},@{@"deviceId":@""}]) {
        NSMutableDictionary *bad=[Config() mutableCopy]; [bad addEntriesFromDictionary:change];
        Check(!Exchange(bad,NO),@"malformed input rejected");
    }
    NSMutableDictionary *fresh=[Config() mutableCopy]; fresh[@"deviceId"]=@""; fresh[@"deviceToken"]=@"";
    exchange=Exchange(fresh,YES); Check(exchange != nil,@"new claim with key");
    Check([exchange.request.URL.path isEqual:@"/api/devices/claim"],@"claim endpoint");
    Check(!exchange.request.allHTTPHeaderFields[@"Authorization"],@"new claim has no invented bearer");
    accepted=Consume(exchange,Reply(exchange,nil),200,nil,fresh);
    Check([accepted[@"deviceToken"] isEqual:Bearer()] && [accepted[@"deviceId"] isEqual:@"fixture-device"],@"claim validated pairing");
    exchange=Exchange(fresh,YES); NSMutableDictionary *badReply=[Reply(exchange,nil) mutableCopy]; badReply[@"token"]=@"bad";
    Check(!Consume(exchange,badReply,200,nil,fresh),@"malformed active pairing rejected");
    exchange=Exchange(Config(),YES); badReply=[Reply(exchange,nil) mutableCopy]; badReply[@"deviceId"]=@"other-device";
    Check(!Consume(exchange,badReply,200,nil,nil),@"claim cannot replace bound device");
    exchange=[LBXLicenseExchange exchangeWithConfiguration:Config() claim:NO error:nil];
    Check(!Consume(exchange,Reply(exchange,nil),200,nil,nil),@"production build missing pin fails closed");
    // ICU '$' can match before a terminal line break. Header and pairing
    // identifiers must match the entire string, including CR/LF/Unicode ends.
    for (NSString *ending in @[@"\n",@"\r",@"\r\n",[NSString stringWithCharacters:(unichar[]){0x85} length:1],@"\u2028",@"\u2029"]) {
        for (NSString *field in @[@"deviceId",@"deviceToken"]) {
            NSMutableDictionary *bad=[Config() mutableCopy];bad[field]=[bad[field] stringByAppendingString:ending];
            Check(!Exchange(bad,NO),[@"reject terminal line separator in configuration " stringByAppendingString:field]);
        }
        exchange=Exchange(fresh,YES);badReply=[Reply(exchange,nil) mutableCopy];badReply[@"token"]=[Bearer() stringByAppendingString:ending];
        Check(!Consume(exchange,badReply,200,nil,fresh),@"reject terminal line separator in returned pairing token");
    }
    exchange=Exchange(Config(),NO);reply=Reply(exchange,nil);NSMutableDictionary *aba=[Config() mutableCopy];aba[@"revision"]=@3;
    Check(!Consume(exchange,reply,200,nil,aba),@"configuration ABA rejected even when all credentials restored");
    for (NSDictionary *times in @[@{@"wall":@21,@"uptime":@0},@{@"wall":@0,@"uptime":@21},@{@"wall":@(-6),@"uptime":@0},@{@"wall":@0,@"uptime":@(-1)}]) {
        exchange=Exchange(Config(),NO);__block NSTimeInterval wall=NSDate.date.timeIntervalSince1970,up=1000;
        [exchange testUseClock:^NSTimeInterval(BOOL uptime){return uptime?up:wall;} beforeVerification:nil];
        reply=Reply(exchange,nil);wall+=[times[@"wall"] doubleValue];up+=[times[@"uptime"] doubleValue];
        Check(!Consume(exchange,reply,200,nil,nil),@"wall/uptime deadline and rollback checked before verification");
    }
    exchange=Exchange(Config(),NO);__block NSTimeInterval wall=NSDate.date.timeIntervalSince1970,up=1000;
    [exchange testUseClock:^NSTimeInterval(BOOL uptime){return uptime?up:wall;} beforeVerification:^{wall+=21;up+=21;}];
    Check(!Consume(exchange,Reply(exchange,nil),200,nil,nil),@"reply finishing verification beyond exchange deadline rejected");
    exchange=Exchange(Config(),NO);wall=NSDate.date.timeIntervalSince1970;up=1000;
    [exchange testUseClock:^NSTimeInterval(BOOL uptime){return uptime?up:wall;} beforeVerification:^{wall+=2;up+=2;}];
    accepted=Consume(exchange,Reply(exchange,@{@"iat":@((long long)wall-1),@"exp":@((long long)wall+1)}),200,nil,nil);
    Check([accepted[@"status"] isEqual:@"expired"] && ![accepted[@"activeAtReceipt"] boolValue],@"token crossing expiry during verify is inactive at receipt");
    exchange=Exchange(Config(),NO);__weak LBXLicenseExchange *weakExchange=exchange;wall=NSDate.date.timeIntervalSince1970;up=1000;
    [exchange testUseClock:^NSTimeInterval(BOOL uptime){return uptime?up:wall;} beforeVerification:^{[weakExchange cancel];}];
    Check(!Consume(exchange,Reply(exchange,nil),200,nil,nil),@"cancellation during verification rejects result");
    exchange=Exchange(Config(),NO);NSMutableDictionary *during=[Config() mutableCopy];wall=NSDate.date.timeIntervalSince1970;up=1000;
    [exchange testUseClock:^NSTimeInterval(BOOL uptime){return uptime?up:wall;} beforeVerification:^{during[@"revision"]=@2;}];
    Check(!Consume(exchange,Reply(exchange,nil),200,nil,during),@"supplied configuration mutation during verification rejects result");
    for (id revision in @[@YES,@(-1),@1.5,@(NAN),@(INFINITY),@9007199254740992.0,@"1",NSNull.null]) {
        NSMutableDictionary *bad=[Config() mutableCopy];bad[@"revision"]=revision;
        Check(!Exchange(bad,NO),@"revision rejects bool/fraction/nonfinite/unsafe-integer/nonnumber values");
    }
    for (NSString *field in @[@"server",@"deviceIdentity",@"key",@"deviceId",@"deviceToken"]) {
        NSMutableDictionary *bad=[Config() mutableCopy];bad[field]=[@"x" stringByPaddingToLength:4097 withString:@"x" startingAtIndex:0];
        Check(!Exchange(bad,NO),@"configuration string size bounded");bad[field]=NSNull.null;
        Check(!Exchange(bad,NO),@"configuration null string rejected");
    }
    Check(!Exchange((id)@[],NO)&&!Exchange((id)NSNull.null,YES),@"configuration root requires dictionary");
    exchange=Exchange(Config(),NO);NSMutableURLRequest *changedRequest=[exchange.request mutableCopy];changedRequest.URL=[NSURL URLWithString:@"https://different.test"];changedRequest.HTTPBody=NSData.data;
    Check([exchange.request.URL.host isEqual:@"license.example.test"]&&exchange.request.HTTPBody.length>0,@"returned request copy does not mutate exchange binding");
    for(id data in @[[NSMutableData dataWithLength:65537],[@"not JSON" dataUsingEncoding:NSUTF8StringEncoding],[@"[]" dataUsingEncoding:NSUTF8StringEncoding],@"not data",NSNull.null]) {
        exchange=Exchange(Config(),NO);NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:exchange.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        Check(![exchange consumeResponse:response data:data currentConfiguration:Config() error:nil],@"response data type/size/JSON shape bounded");
        Check(!Consume(exchange,Reply(exchange,nil),200,nil,nil),@"malformed response still consumes exchange once");
    }
    exchange=Exchange(Config(),NO);wall=NSDate.date.timeIntervalSince1970;up=1000;
    [exchange testUseClock:^NSTimeInterval(BOOL uptime){return uptime?up:wall;} beforeVerification:^{wall-=4;up+=1;}];
    Check(!Consume(exchange,Reply(exchange,@{@"iat":@((long long)wall+120),@"exp":@((long long)wall+180)}),200,nil,nil),@"clock rollback cannot expand signed issue-time tolerance after verification");
    printf("%s: %lu SocialBox authorization exchange assertions, %lu failures (no recovered-engine grant)\n",failures?"FAIL":"PASS",(unsigned long)checks,(unsigned long)failures);
} return failures?1:0; }
