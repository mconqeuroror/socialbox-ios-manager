#import <Foundation/Foundation.h>
#import <math.h>
#import "RBXProfile.h"
#import "RBXAppRuntime.h"
static RBXDeviceProfile *FixtureProfile;
static RBXDeviceProfile *rbxProfile(void) { return FixtureProfile; }
static NSString *RBXRealIDFAString(void) { return @"22222222-2222-4222-8222-222222222222"; }
static NSString *RBXRealIDFVString(void) { return @"33333333-3333-4333-8333-333333333333"; }
static void RBXRecordAuthenticatedActivity(NSURLRequest *request) { (void)request; }
#include "reddit-json.inc"

static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAIL %s\n", message.UTF8String); exit(1); }
}
int main(void) { @autoreleasepool {
    for (NSString *host in @[@"reddit.com", @"oauth.reddit.com", @"CF.GQL-FED.REDDIT.COM",
                            @"redditmedia.com", @"styles.redditmedia.com", @"redditstatic.com",
                            @"www.redditstatic.com", @"redd.it", @"packaged-media.redd.it"]) {
        Check(RBXIsRedditAPIHost(host), [@"observed Reddit domain accepted: " stringByAppendingString:host]);
        Check(RBXCriticalHostAllowed(host), [@"observed critical domain accepted: " stringByAppendingString:host]);
    }
    for (NSString *host in @[@"", @"notreddit.com", @"reddit.com.attacker.invalid",
                            @"redditmedia.attacker.invalid", @"snooguts.attacker.invalid",
                            @"redditstatic-attacker.invalid", @"notredd.it"]) {
        Check(!RBXIsRedditAPIHost(host), [@"unrelated domain rejected: " stringByAppendingString:host]);
        Check(!RBXCriticalHostAllowed(host), [@"unrelated critical domain rejected: " stringByAppendingString:host]);
    }
    Check(!RBXIsRedditAPIHost(nil), @"missing host rejected");
    Check(!RBXCriticalHostAllowed(nil), @"missing critical host rejected");
    RBXDeviceProfile *p = [[RBXDeviceProfile alloc] initWithDictionary:@{
        @"containerId": @"payload-fixture", @"device": @{@"productType": @"iPhone13,2", @"iosVersion": @"16.0.0"},
        @"reddit": @{@"installId": @"11111111-1111-4111-8111-111111111111"}
    } error:nil];
    Check(p != nil, @"fixture profile loads through the shipped profile reader");
    FixtureProfile = p;
    NSDictionary *server = @{@"id": @"session-server-value", @"device_id": @"server-binding",
        @"nested": @{@"installation_id": @"server-owned-install"},
        @"events": @[@{@"device_id": @"server-owned-array-value"}]};
    for (NSString *key in @[@"session", @"loid", @"anonymous_loid", @"authorization", @"access_token"]) {
        for (id value in @[server, @[server], @"opaque-server-token"]) {
            NSDictionary *input = @{key: value};
            id output = RBXRewriteJSONValue(input, nil, nil, p);
            Check([output isEqual:input], [@"server-owned subtree must remain unchanged: " stringByAppendingString:key]);
        }
    }
    NSDictionary *mixed = @{@"session":server, @"loid":@"server-loid", @"device_id":@"client-install"};
    NSDictionary *out = RBXRewriteJSONValue(mixed, nil, nil, p);
    Check([out[@"session"] isEqual:server] && [out[@"loid"] isEqual:@"server-loid"], @"mixed client/server object retains server state");
    Check([out[@"device_id"] isEqual:p.redditInstallId], @"existing client-field behavior remains active");
    NSData *json = [NSJSONSerialization dataWithJSONObject:mixed options:0 error:nil];
    NSMutableData *binary = [NSMutableData dataWithBytes:"device_id\0" length:10];
    [binary appendData:[@"44444444-4444-4444-8444-444444444444" dataUsingEncoding:NSUTF8StringEncoding]];
    [binary appendBytes:"\0" length:1];
    for (NSString *host in @[@"metrics.example.invalid", @"reddit.com.attacker.invalid", @"oauth.reddit.com"]) {
        for (NSArray *fixture in @[@[json, @"application/json"], @[binary, @"application/x-protobuf"]]) {
            NSData *bytes = fixture[0];
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://" stringByAppendingString:host]]];
            request.HTTPBody = bytes;
            [request setValue:fixture[1] forHTTPHeaderField:@"Content-Type"];
            BOOL changed = RBXRewriteRequestBody(request);
            if ([host isEqual:@"oauth.reddit.com"]) {
                Check(changed && ![request.HTTPBody isEqual:bytes], @"Reddit request retains scoped identity mutation");
                if ([fixture[1] isEqual:@"application/json"]) {
                    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
                    Check([value[@"session"] isEqual:server], @"request-level mutation preserves server subtree");
                }
            } else {
                Check(!changed && [request.HTTPBody isEqual:bytes], @"non-Reddit body is byte-identical pass-through");
            }
        }
    }
    for (NSString *field in @[@"X-Hmac-Signed-Body", @"x-hmac-signed-result", @"Signature", @"Signature-Input", @"Content-Digest", @"Digest"]) {
        NSMutableURLRequest *signedRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/api/test"]];
        signedRequest.HTTPBody = json;
        [signedRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [signedRequest setValue:@"signature-fixture" forHTTPHeaderField:field];
        NSDictionary *headers = signedRequest.allHTTPHeaderFields;
        NSURLRequest *preserved = RBXRewriteRequest(signedRequest);
        Check([preserved.HTTPBody isEqual:json] && [preserved.allHTTPHeaderFields isEqual:headers],
              @"signed candidate preserves original bytes and all signature/header values");
        Check(!RBXRewriteRequestBody(signedRequest) && [signedRequest.HTTPBody isEqual:json],
              @"signed request-body path never mutates or drops signatures");
    }
    for (NSUInteger builder = 0; builder < 3; builder++) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://oauth.reddit.com/api/test"]];
        if (builder == 0) [request setValue:@"original-client-header" forHTTPHeaderField:@"Client-Vendor-ID"];
        if (builder == 1) [request addValue:@"original-client-header" forHTTPHeaderField:@"Client-Vendor-ID"];
        if (builder == 2) request.allHTTPHeaderFields = @{@"Client-Vendor-ID": @"original-client-header"};
        request.HTTPBody = json;
        [request setValue:@"added-after-client-fields" forHTTPHeaderField:@"Signature"];
        NSURLRequest *output = RBXRewriteRequest(request);
        Check([[output valueForHTTPHeaderField:@"Client-Vendor-ID"] isEqual:@"original-client-header"] &&
              [output.HTTPBody isEqual:json] && [output.allHTTPHeaderFields isEqual:request.allHTTPHeaderFields],
              @"signature added last preserves complete builder output at dispatch");
        [request setValue:nil forHTTPHeaderField:@"Signature"];
        request.URL = [NSURL URLWithString:@"https://metrics.example.invalid/upload"];
        output = RBXRewriteRequest(request);
        Check([output.HTTPBody isEqual:json] && [output.allHTTPHeaderFields isEqual:request.allHTTPHeaderFields],
              @"URL reassigned to foreign host preserves complete builder output");
    }
    puts("Reddit payload tests passed: server subtrees preserved");
}}
