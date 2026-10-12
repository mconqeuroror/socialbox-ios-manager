// Actual secret-store implementation with synthetic Keychain calls. No live
// credentials are read. Runtime execution requires macOS Foundation/Security.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
static NSMutableDictionary *Items;
static OSStatus ReadStatus, WriteStatus;
static BOOL WrongReadback;
static NSDictionary *LastQuery, *LastAttributes;

static NSString *Key(CFDictionaryRef query) {
    NSDictionary *q = (__bridge NSDictionary *)query;
    LastQuery = [q copy];
    return [NSString stringWithFormat:@"%@/%@/%@", q[(__bridge id)kSecAttrAccessGroup],
        q[(__bridge id)kSecAttrService], q[(__bridge id)kSecAttrAccount]];
}
static OSStatus Copy(CFDictionaryRef query, CFTypeRef *result) {
    NSString *key = Key(query);
    if (ReadStatus) return ReadStatus;
    NSData *data = Items[key];
    if (!data) return errSecItemNotFound;
    *result = CFRetain((__bridge CFTypeRef)(WrongReadback ? [@"corrupt" dataUsingEncoding:NSUTF8StringEncoding] : data));
    return errSecSuccess;
}
static OSStatus Update(CFDictionaryRef query, CFDictionaryRef attributes) {
    NSString *key = Key(query);
    if (WriteStatus) return WriteStatus;
    if (!Items[key]) return errSecItemNotFound;
    LastAttributes = [(__bridge NSDictionary *)attributes copy];
    Items[key] = LastAttributes[(__bridge id)kSecValueData];
    return errSecSuccess;
}
static OSStatus Add(CFDictionaryRef query, CFTypeRef *result) {
    (void)result;
    NSString *key = Key(query);
    if (WriteStatus) return WriteStatus;
    LastAttributes = [(__bridge NSDictionary *)query copy];
    Items[key] = LastAttributes[(__bridge id)kSecValueData];
    return errSecSuccess;
}
static OSStatus Delete(CFDictionaryRef query) {
    NSString *key = Key(query);
    if (WriteStatus) return WriteStatus;
    [Items removeObjectForKey:key]; return errSecSuccess;
}
#define SecItemCopyMatching Copy
#define SecItemUpdate Update
#define SecItemAdd Add
#define SecItemDelete Delete
#import "../daemon/RBXRotationSecrets.m"
#undef SecItemCopyMatching
#undef SecItemUpdate
#undef SecItemAdd
#undef SecItemDelete

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}
int main(void) {
    @autoreleasepool {
        @try {
            Items = [NSMutableDictionary dictionary];
            NSDictionary *auth = @{@"header": @"Authorization", @"value": @"fixture-control-secret"};
            NSDictionary *legacy = @{@"containerId": @"alpha", @"device": @{@"productType": @"fixture"},
                @"proxy": @{@"url": @"http://connection-user:connection-secret@proxy.invalid:8080",
                    @"country": @"US", @"rotationAuthHeader": auth[@"header"], @"rotationAuthValue": auth[@"value"],
                    @"rotationURL": @"https://control.invalid/private-token"}, @"rotationAuth": auth};
            NSError *error = nil;
            NSDictionary *safe = [RBXRotationSecrets migrateLegacyProfile:legacy error:&error];
            Check(safe && !error, @"legacy migration saves before redacting");
            Check([LastQuery[(__bridge id)kSecAttrAccessGroup] isEqual:@"RBXBOXCFG.com.redditbox.daemon-control"], @"daemon-only access group");
            Check([LastAttributes[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly], @"device-only unlocked accessibility");
            Check([LastQuery[(__bridge id)kSecAttrSynchronizable] isEqual:@NO], @"iCloud synchronization disabled");
            Check([[RBXRotationSecrets overrideForProfile:@"alpha" error:nil] isEqual:auth], @"stored rotation auth recovered");
            Check(![RBXRotationSecrets overrideForProfile:@"beta" error:nil], @"different profile cannot read alpha secret");
            Check([safe[@"proxy"] count] == 2 && [safe[@"proxy"][@"url"] isEqual:legacy[@"proxy"][@"url"]], @"required connection credentials retained");
            Check(!safe[@"rotationAuth"] && [safe[@"device"] isEqual:legacy[@"device"]], @"control metadata removed, identity retained");
            Check([RBXProfileForTransport(safe) isEqual:safe], @"redaction idempotent");
            Check([RBXRotationSecrets saveOverride:@{} profile:@"alpha" error:&error], @"explicit clear persisted");
            Check([RBXRotationSecrets migrateLegacyProfile:legacy error:&error] != nil &&
                [[RBXRotationSecrets overrideForProfile:@"alpha" error:nil] count] == 0, @"legacy copy cannot override later clear");
            ReadStatus = errSecInteractionNotAllowed; error = nil;
            Check(![RBXRotationSecrets migrateLegacyProfile:legacy error:&error] && error, @"locked store cannot fall back to plaintext");
            ReadStatus = 0; WriteStatus = errSecNotAvailable; error = nil;
            Check(![RBXRotationSecrets saveOverride:auth profile:@"beta" error:&error] && error, @"write failure explicit");
            WriteStatus = 0; WrongReadback = YES; error = nil;
            Check(![RBXRotationSecrets saveOverride:auth profile:@"beta" error:&error] && error, @"corrupt write readback fails");
            WrongReadback = NO;
            Check(![RBXRotationSecrets saveOverride:@{@"header": @"Authorization", @"value": @"a\r\nb"} profile:@"alpha" error:nil], @"header injection rejected");
            Check([RBXRotationSecrets removeProfile:@"alpha" error:nil] && [RBXRotationSecrets removeProfile:@"alpha" error:nil], @"delete is verified and idempotent");
            puts("PASS: rotation-secret scope, read/write faults, migration, redaction, clear and deletion");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String); return 1;
        }
    }
    return 0;
}
