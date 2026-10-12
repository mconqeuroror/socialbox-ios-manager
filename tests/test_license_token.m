#import "RBXLicenseTestSupport.h"

static BOOL Verify(NSString *token, NSDictionary *expected, NSString *nonce, NSTimeInterval now) {
    return [RBXLicenseToken verifyToken:token publicKeyDER:TestLicensePublicDER() keyID:TestLicenseKeyID()
        expected:expected nonce:nonce now:now error:nil] != nil;
}
int main(void) { @autoreleasepool {
    NSTimeInterval now = 1770000000;
    NSDictionary *expected = TestLicenseExpected(@"KEY-A");
    NSMutableDictionary *claims = TestLicenseClaims(@"KEY-A", @"fresh-request", now);
    NSString *token = TestLicenseJWT(claims, nil);
    NSCAssert(Verify(token, expected, @"fresh-request", now), @"Correct signed token rejected");
    NSCAssert(Verify(token, expected, nil, now + 72 * 3600), @"Elapsed signed expiry must remain readable as a diagnostic");
    NSCAssert(!Verify(token, expected, @"other-request", now), @"Nonce replay accepted");
    NSCAssert(!Verify([token stringByAppendingString:@"x"], expected, nil, now), @"Altered signature accepted");
    NSCAssert(!Verify(@"{\"valid\":true}", expected, nil, now), @"Unsigned legacy response accepted");
    NSCAssert(!Verify(TestLicenseJWT(claims, @{@"alg": @"HS256"}), expected, nil, now), @"Algorithm confusion accepted");
    NSCAssert(!Verify(TestLicenseJWT(claims, @{@"kid": @"other"}), expected, nil, now), @"Wrong pin accepted");
    NSUInteger cases = 7;
    for (NSString *field in @[@"server", @"deviceId", @"deviceBinding", @"keyFingerprint"]) {
        NSMutableDictionary *wrong = [expected mutableCopy]; wrong[field] = @"other";
        NSCAssert(!Verify(token, wrong, nil, now), @"Wrong %@ accepted", field); cases++;
    }
    for (NSDictionary *change in @[@{@"v": @YES}, @{@"v": @2}, @{@"aud": @"other"},
        @{@"exp": @(now + 72 * 3600 + 1)}, @{@"iat": @(now + 121)},
        @{@"exp": @"1770000000"}, @{@"iat": @YES}, @{@"status": @"unknown"}, @{@"exp": @(now)}]) {
        NSMutableDictionary *wrong = [claims mutableCopy]; [wrong addEntriesFromDictionary:change];
        NSCAssert(!Verify(TestLicenseJWT(wrong, nil), expected, nil, now), @"Malformed claims accepted: %@", change); cases++;
    }
    for (NSString *status in @[@"revoked", @"expired", @"invalid"]) {
        NSMutableDictionary *denied = [claims mutableCopy]; denied[@"status"] = status; denied[@"exp"] = @(now - 10);
        NSCAssert(Verify(TestLicenseJWT(denied, nil), expected, @"fresh-request", now), @"Signed denial unreadable"); cases++;
    }
    NSCAssert([[RBXLicenseToken canonicalServer:@" HTTPS://Example.TEST:443/ "] isEqual:@"https://example.test"], @"Origin normalization");
    for (NSString *server in @[@"http://example.test", @"https://user:pass@example.test", @"https://example.test/path", @"https://example.test/?q=1"])
        NSCAssert(![RBXLicenseToken canonicalServer:server], @"Ambiguous server accepted");
    NSLog(@"PASS %lu signed-token cases plus HTTPS origin validation", (unsigned long)cases);
} return 0; }
