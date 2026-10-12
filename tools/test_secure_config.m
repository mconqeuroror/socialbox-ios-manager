#import "../shared/RBXLiveness.h"
// Exercise the production normalizer/save path without reading a real Keychain.
#import <Foundation/Foundation.h>
#import <stdio.h>
#import "../shared/RBXSecureConfig.h"

@interface RBXSecureConfig (PersistenceTesting)
+ (BOOL)_persistRotationRecord:(NSDictionary *)record error:(NSError **)error;
@end

static NSDictionary *sSnapshot;
static NSUInteger sWrites;
static BOOL sReadFailure;
static BOOL sWriteFailure;

@interface MemorySecureConfig : RBXSecureConfig
@end

@implementation MemorySecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error {
    if (sReadFailure) {
        if (error) *error = [NSError errorWithDomain:@"SecureConfigTest" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Injected Keychain read failure"}];
        return nil;
    }
    return [sSnapshot copy];
}
+ (BOOL)_persistRotationRecord:(NSDictionary *)record error:(NSError **)error {
    sWrites++;
    if (sWriteFailure) {
        if (error) *error = [NSError errorWithDomain:@"SecureConfigTest" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"Injected Keychain write failure"}];
        return NO;
    }
    sSnapshot = [record copy];
    return YES;
}
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"TestFailure"
        reason:message ?: @"Assertion failed" userInfo:nil];
}

static NSDictionary *Initial(void) {
    return @{@"proxyURL": @"http://test-user:test-password@proxy.example:8080",
        @"rotationURL": @"https://rotation.example/rotate", @"authHeader": @"Authorization",
        @"authorization": @"Bearer fixture-token", @"method": @"POST",
        @"accessKey": @"INITIAL-KEY", @"source": @"launcher", @"updatedAt": @42,
        @"formatVersion": @1};
}

static void Reset(NSDictionary *snapshot) {
    sSnapshot = [snapshot copy];
    sWrites = 0;
    sReadFailure = NO;
    sWriteFailure = NO;
}

static NSDictionary *Effective(NSDictionary *value) {
    return [MemorySecureConfig effectiveRotationConfiguration:value];
}

static void TestNormalization(void) {
    Reset(nil);
    Check([Effective(nil) isEqualToDictionary:Effective(@{})], @"Missing and empty records are operationally equal");
    Check([MemorySecureConfig saveRotationConfiguration:@{} error:nil] && sWrites == 0 && sSnapshot == nil,
        @"An empty initial refresh must not create a timestamp-only record");
    Check([Effective(@{}) isEqualToDictionary:Effective(@{@"proxyURL": @"", @"rotationURL": @"",
        @"authHeader": @"", @"method": @""})], @"Empty endpoints/header/method must retain fallback behavior");
    Check(![Effective(@{}) isEqualToDictionary:Effective(@{@"authorization": @""})],
        @"An explicit empty authorization must override environment fallback");
    NSDictionary *values = @{@"proxyURL": @"http://proxy.example:8080",
        @"rotationURL": @"https://rotation.example/rotate", @"authHeader": @"Authorization", @"method": @"POST"};
    for (NSString *key in values) {
        Check(![Effective(@{}) isEqualToDictionary:Effective(@{key: values[key]})],
            [NSString stringWithFormat:@"A nonempty %@ override must differ from absence", key]);
    }
    NSMutableDictionary *changedBookkeeping = [Initial() mutableCopy];
    [changedBookkeeping addEntriesFromDictionary:@{@"updatedAt": @9000, @"cloudUpdatedAt": @8000, @"source": @"cloud",
        @"formatVersion": @99, @"accessKey": @"OTHER-KEY"}];
    Check([Effective(Initial()) isEqualToDictionary:Effective(changedBookkeeping)],
        @"Local metadata and license data cannot become rotation settings");
}

static void TestIdenticalRefresh(void) {
    NSDictionary *initial = Initial();
    Reset(initial);
    for (NSUInteger index = 0; index < 10; index++) {
        NSMutableDictionary *cloud = [initial mutableCopy];
        cloud[@"source"] = @"cloud";
        cloud[@"updatedAt"] = @(1000 + index);
        cloud[@"cloudUpdatedAt"] = @(2000 + index);
        NSError *error = nil;
        Check([MemorySecureConfig saveRotationConfiguration:cloud error:&error], error.description);
    }
    Check(sWrites == 0, @"Repeated identical cloud refreshes cannot write Keychain records");
    Check([sSnapshot isEqualToDictionary:initial], @"Unchanged refresh must retain timestamp and source bookkeeping");
    Check([MemorySecureConfig saveRotationConfiguration:@{@"source": @"other-source", @"updatedAt": @8000}
        error:nil], @"Bookkeeping-only refresh succeeds without a write");
    Check(sWrites == 0 && [sSnapshot isEqualToDictionary:initial], @"Bookkeeping-only updates must be ignored");
}

static void TestOperationalChanges(void) {
    NSDictionary *changes = @{@"proxyURL": @"http://other.example:9000",
        @"rotationURL": @"https://other.example/rotate", @"authHeader": @"X-Proxy-Key",
        @"authorization": @"Bearer new-fixture-token", @"method": @"GET"};
    for (NSString *key in changes) {
        Reset(Initial());
        NSError *error = nil;
        Check([MemorySecureConfig saveRotationConfiguration:@{key: changes[key]} error:&error], error.description);
        Check(sWrites == 1 && [sSnapshot[key] isEqual:changes[key]],
            [NSString stringWithFormat:@"Real %@ changes must persist", key]);
        Check([sSnapshot[@"updatedAt"] doubleValue] > 42, @"A real change receives a new local revision timestamp");
        Check([sSnapshot[@"accessKey"] isEqual:@"INITIAL-KEY"], @"Partial rotation changes must retain the license key");
        Check([MemorySecureConfig saveRotationConfiguration:@{key: changes[key]} error:nil] && sWrites == 1,
            @"Repeating the new value must not write again");
    }
}

static void TestEmptyAuthorizationOverride(void) {
    Reset(@{@"proxyURL": @"http://proxy.example:8080", @"updatedAt": @42});
    Check([MemorySecureConfig saveRotationConfiguration:@{@"authorization": @""} error:nil],
        @"Clearing authorization explicitly must succeed");
    Check(sWrites == 1 && [sSnapshot[@"authorization"] isEqual:@""],
        @"An explicit empty authorization must be persisted instead of falling back");
    Check([MemorySecureConfig saveRotationConfiguration:@{@"authorization": @""} error:nil] && sWrites == 1,
        @"Repeated explicit empty authorization is unchanged");
}

static void TestOptionalRotation(void) {
    Reset(@{@"proxyURL": @"http://proxy.example:8080", @"updatedAt": @42});
    Check([[MemorySecureConfig safeSummary][@"configured"] boolValue],
        @"A proxy without rotation is configured");
    Check(![Effective(sSnapshot) isEqualToDictionary:Effective(@{
        @"proxyURL": @"http://proxy.example:8080", @"rotationURL": @""})],
        @"Explicitly disabling rotation must be persisted rather than inheriting a fallback");
    Check([MemorySecureConfig saveRotationConfiguration:@{@"rotationURL": @""} error:nil] && sWrites == 1,
        @"Proxy-only settings record the explicit empty rotation link");
    Check([MemorySecureConfig saveRotationConfiguration:@{@"rotationURL": @""} error:nil] && sWrites == 1,
        @"Saving proxy-only settings twice is idempotent");
}

static void TestAccessKeyChange(void) {
    Reset(Initial());
    NSDictionary *before = Effective(sSnapshot);
    Check([MemorySecureConfig saveAccessKey:@"  new-license-key\n" error:nil], @"License update succeeds");
    Check(sWrites == 1 && [sSnapshot[@"accessKey"] isEqual:@"NEW-LICENSE-KEY"], @"License changes must be persisted");
    Check([before isEqualToDictionary:Effective(sSnapshot)], @"License changes cannot change effective rotation settings");
    Check([MemorySecureConfig saveAccessKey:@"NEW-LICENSE-KEY" error:nil] && sWrites == 1,
        @"Repeated normalized license keys must not rewrite the record");
}

static void TestReadFailure(void) {
    NSDictionary *initial = Initial();
    Reset(initial);
    sReadFailure = YES;
    NSError *error = nil;
    Check(![MemorySecureConfig saveRotationConfiguration:@{@"proxyURL": @"http://other.example:9000"}
        error:&error] && error != nil, @"Read errors must prevent rotation writes");
    error = nil;
    Check(![MemorySecureConfig saveAccessKey:@"NEW-KEY" error:&error] && error != nil,
        @"Read errors must prevent license writes");
    Check(sWrites == 0 && [sSnapshot isEqualToDictionary:initial], @"Read failure cannot overwrite unavailable existing settings");
}

static void TestWriteFailure(void) {
    NSDictionary *initial = Initial();
    Reset(initial);
    sWriteFailure = YES;
    NSError *error = nil;
    Check(![MemorySecureConfig saveRotationConfiguration:@{@"method": @"GET"} error:&error] && error != nil,
        @"Persistence errors must reach the caller");
    Check(sWrites == 1 && [sSnapshot isEqualToDictionary:initial], @"Failed persistence cannot claim an updated snapshot");
}

int main(void) {
    @autoreleasepool {
        Check(RBXHeartbeatFresh(@100, 102.5), @"heartbeat exact 2.5-second boundary accepted");
        Check(!RBXHeartbeatFresh(@100, 102.5001), @"heartbeat beyond boundary expires");
        Check(!RBXHeartbeatFresh(@100, 99), @"future heartbeat rejected");
        Check(!RBXHeartbeatFresh(nil, 100) && !RBXHeartbeatFresh(@"100", 100), @"missing/wrong-type heartbeat rejected");
        Check(!RBXHeartbeatFresh(@(NAN), 100) && !RBXHeartbeatFresh(@100, INFINITY), @"nonfinite heartbeat rejected");

        @try {
            TestNormalization(); TestIdenticalRefresh(); TestOperationalChanges();
            TestEmptyAuthorizationOverride(); TestOptionalRotation(); TestAccessKeyChange(); TestReadFailure(); TestWriteFailure();
            puts("Secure configuration tests: 8 scenarios passed");
            return 0;
        } @catch (NSException *error) {
            fprintf(stderr, "Secure configuration tests failed: %s\n", error.reason.UTF8String);
            return 1;
        }
    }
}
