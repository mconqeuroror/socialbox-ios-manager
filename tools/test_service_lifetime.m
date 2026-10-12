// Actual RBXLicenseGuard source with an adversarial in-memory HTTP backend.
// No real HTTP, keychain, process termination or production-path writes occur.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sys/stat.h>
#import <unistd.h>
#import "RBXOperationContext.h"
#import "RBXSecureConfig.h"
#import "RBXCentralStore.h"
#import "RBXProcessController.h"
#import "RBXCloudSync.h"
#import "../tests/RBXLicenseTestSupport.h"

#ifndef RBX_LICENSE_CLOUD_PLIST
#error The runner must supply a private temporary RBX_LICENSE_CLOUD_PLIST path.
#endif

static NSObject *sKeyLock;
static NSString *sAccessKey;
static NSTimeInterval sReplyDelay;
static dispatch_semaphore_t sRequestStarted;
static NSUInteger sKills, sAlerts;
static NSTimeInterval sClock = 1770000000;
static NSInteger sHTTPStatus = 200;
static NSString *sLicenseStatus = @"active";
static BOOL sUnsignedReply;
static NSTimeInterval sMonotonic = 1000;
static NSString *sMigrationExpectedPath;
static NSURLRequest *sLastRequest;

@interface RBXLifetimeTask : NSURLSessionDataTask
@property(nonatomic, copy) void (^reply)(NSData *, NSURLResponse *, NSError *);
@property(nonatomic, strong) NSURLRequest *request;
@property(nonatomic) NSTimeInterval delay;
@property(nonatomic) NSInteger responseStatus;
@property(nonatomic, copy) NSString *licenseStatus;
@property(nonatomic) BOOL unsignedReply;
@end
@implementation RBXLifetimeTask
- (void)cancel { /* Deliberately delivers its response after cancellation. */ }
- (void)resume {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
            statusCode:self.responseStatus HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:self.request.HTTPBody options:0 error:nil];
        NSMutableDictionary *claims = TestLicenseClaims(body[@"key"] ?: @"", body[@"nonce"], sClock);
        claims[@"status"] = self.licenseStatus;
        NSDictionary *json = self.unsignedReply ? @{@"valid": @YES, @"revoked": @NO} : @{
            @"licenseToken": TestLicenseJWT(claims, nil), @"deviceId": @"fixture-device",
            @"token": @"0000000000000000000000000000000000000000000000000000000000000000",
            @"name": @"fixture", @"role": @"worker"};
        self.reply([NSJSONSerialization dataWithJSONObject:json options:0 error:nil], response, nil);
        self.reply = nil;
    });
}
@end

@interface RBXLifetimeSession : NSObject
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue;
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
@end
@implementation RBXLifetimeSession
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue {
    (void)configuration;
    (void)delegate; (void)queue;
    return [self new];
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    sLastRequest = request;
    if (sMigrationExpectedPath) {
        NSCAssert([request.URL.path isEqual:sMigrationExpectedPath], @"Migration used %@ instead of %@", request.URL.path, sMigrationExpectedPath);
        NSDictionary *body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
        NSCAssert([body[@"key"] isEqual:@"ZZZZ-YYYY-XXXX-WWWW"], @"Migration dropped or changed the saved legacy key");
        NSCAssert([body[@"deviceIdentity"] isEqual:TestLicenseIdentity], @"Migration changed the installation binding");
        NSCAssert([[request valueForHTTPHeaderField:@"Authorization"] isEqual:
            @"Bearer 0000000000000000000000000000000000000000000000000000000000000000"], @"Migration did not preserve the existing paired bearer");
    }
    RBXLifetimeTask *task = [RBXLifetimeTask new];
    task.request = request;
    task.reply = completion;
    task.delay = sReplyDelay;
    task.responseStatus = sHTTPStatus; task.licenseStatus = sLicenseStatus; task.unsignedReply = sUnsignedReply;
    dispatch_semaphore_signal(sRequestStarted);
    return task;
}
@end

@implementation RBXSecureConfig
+ (NSString *)accessKey:(NSError **)error {
    (void)error;
    @synchronized (sKeyLock) { return sAccessKey; }
}
@end
@implementation RBXCentralStore
+ (instancetype)sharedStore { static id store; if (!store) store = [self new]; return store; }
- (void)addAlertType:(NSString *)type containerId:(NSString *)containerId message:(NSString *)message {
    (void)type; (void)containerId; (void)message; sAlerts++;
}
@end
@implementation RBXProcessController
+ (void)killAllRedditProcesses { sKills++; }
@end
@implementation RBXCloudSync
+ (instancetype)sharedSync { static id sync; if (!sync) sync = [self new]; return sync; }
- (BOOL)acceptLicensePairing:(NSDictionary *)pairing context:(RBXOperationContext *)context error:(NSError **)error {
    if (![context check:error]) return NO;
    NSMutableDictionary *cloud = [[NSDictionary dictionaryWithContentsOfFile:RBX_LICENSE_CLOUD_PLIST] mutableCopy];
    cloud[@"deviceId"] = pairing[@"deviceId"]; cloud[@"deviceToken"] = pairing[@"token"];
    return [cloud writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];
}
@end

// Replace only dependencies; all validation, wait, callback and publication code
// below is the daemon's production implementation.
#define RBX_LICENSE_SESSION_CLASS RBXLifetimeSession
#import "../daemon/RBXLicenseGuard.m"
#undef RBX_LICENSE_SESSION_CLASS

@interface RBXLifetimeGuard : RBXLicenseGuard
@end
@implementation RBXLifetimeGuard
- (NSString *)_readDeviceIdentity:(NSError **)error { (void)error; return TestLicenseIdentity; }
- (NSTimeInterval)_now { return sClock; }
- (NSTimeInterval)_monotonicNow { return sMonotonic; }
- (NSDictionary *)_verifyToken:(NSString *)token expected:(NSDictionary *)expected nonce:(NSString *)nonce now:(NSTimeInterval)now error:(NSError **)error {
    return [RBXLicenseToken verifyToken:token publicKeyDER:TestLicensePublicDER() keyID:TestLicenseKeyID()
        expected:expected nonce:nonce now:now error:error];
}
@end

static void SetKey(NSString *key) { @synchronized (sKeyLock) { sAccessKey = [key copy]; } }
static void Wait(dispatch_semaphore_t semaphore, NSString *label) {
    NSCAssert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
        @"Timed out waiting for %@", label);
}
static RBXOperationContext *Context(NSString *name, NSTimeInterval timeout) {
    return [RBXOperationContext contextWithRequestID:name bootEpoch:RBXOperationContext.daemonBootEpoch timeout:timeout];
}

static void ValidateMigration(RBXLicenseGuard *guard) {
    RBXOperationContext *operation = Context(NSUUID.UUID.UUIDString, 2);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    [guard validateWithContext:operation completion:^(BOOL unlocked, NSString *message) {
        NSCAssert(unlocked, @"Verified migrated entitlement was rejected: %@", message);
        dispatch_semaphore_signal(completed);
    }];
    Wait(sRequestStarted, @"migration HTTP start");
    Wait(completed, @"migration signed result");
    NSCAssert([operation waitForQuiescence:1], @"Migration callback did not drain");
    [operation finish];
}

int main(void) {
    @autoreleasepool {
        sKeyLock = [NSObject new];
        sRequestStarted = dispatch_semaphore_create(0);
        NSString *root = [RBX_LICENSE_CLOUD_PLIST stringByDeletingLastPathComponent];
        NSCAssert([root hasPrefix:NSTemporaryDirectory()] || [root hasPrefix:@"/tmp/"], @"Private fixture required");
        [RBXOperationContext setSafetyFenceDirectoryForTesting:[root stringByAppendingPathComponent:@"fences"]];
        [@{@"serverURL": @"https://license.example.test", @"deviceId": @"fixture-device",
            @"deviceToken": @"0000000000000000000000000000000000000000000000000000000000000000"}
            writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];
        (void)TestLicensePrivateKey(); // Key generation is outside deadline tests.

        NSDictionary *initialConfiguration = [NSDictionary dictionaryWithContentsOfFile:RBX_LICENSE_CLOUD_PLIST];
        RBXLicenseGuard *fresh = [RBXLifetimeGuard new];
        for (id origin in @[NSNull.null, @"", @"  \n"]) {
            NSDictionary *configuration = origin == NSNull.null ? @{} : @{@"serverURL": origin};
            [configuration writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];
            NSCAssert([[fresh safeStatus][@"serverURL"] isEqual:@"https://redditspoof.vercel.app"], @"Fresh installs must use our deployment");
            NSCAssert(!fresh.isUnlocked, @"A default server alone never authorizes the app");
        }
        for (id origin in @[@42, @"http://untrusted.invalid", @"https://host.invalid/path"]) {
            [@{@"serverURL": origin} writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];
            NSCAssert([fresh safeStatus][@"serverURL"] && ![[fresh safeStatus][@"serverURL"] length], @"Invalid settings cannot silently select another deployment");
        }
        [@{@"serverURL": @"https://license.example.test"} writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];
        SetKey(@"ZZZZ-YYYY-XXXX-WWWW"); sReplyDelay = 0.01;
        sHTTPStatus = 404;
        RBXOperationContext *denied = Context(@"first-activation-denied", 2);
        dispatch_semaphore_t deniedDone = dispatch_semaphore_create(0);
        [fresh activateWithContext:denied completion:^(BOOL unlocked, NSString *message) {
            NSCAssert(!unlocked && message.length, @"Invalid key must not unlock");
            dispatch_semaphore_signal(deniedDone);
        }];
        Wait(sRequestStarted, @"denied activation start"); Wait(deniedDone, @"denied activation result");
        NSCAssert([denied waitForQuiescence:1], @"Denied request did not drain"); [denied finish];
        NSCAssert([[fresh safeStatus][@"status"] isEqual:@"invalid-key"], @"First-run denial must remain visible without a pairing");
        NSCAssert(!fresh.trafficEntitlementValid, @"Unsigned HTTP denial cannot grant access");
        NSCAssert(unlink([RBX_LICENSE_STATE_PLIST fileSystemRepresentation]) == 0, @"Could not clear denied fixture");
        sHTTPStatus = 200;
        ValidateMigration(fresh);
        NSCAssert([sLastRequest.URL.path isEqual:@"/api/devices/claim"] && ![sLastRequest valueForHTTPHeaderField:@"Authorization"], @"First activation claims without fabricated credentials");
        NSCAssert(fresh.isUnlocked && fresh.trafficEntitlementValid, @"Our verified grant must reach actual daemon admission");
        ValidateMigration(fresh);
        NSCAssert([sLastRequest.URL.path isEqual:@"/api/licenses/validate"] && [sLastRequest valueForHTTPHeaderField:@"Authorization"].length, @"Next validation uses the persisted pairing");
        NSCAssert(unlink([RBX_LICENSE_STATE_PLIST fileSystemRepresentation]) == 0, @"Could not clear fresh activation fixture");
        [initialConfiguration writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];

        // An upgraded admin can have a saved account key and no device binding.
        // An initial failed migration may also have saved a signed INVALID
        // response. Neither state proves that the server accepted a binding.
        NSDictionary *originalPairing = [NSDictionary dictionaryWithContentsOfFile:RBX_LICENSE_CLOUD_PLIST];
        SetKey(@"  zzzz-yyyy-xxxx-wwww  ");
        sReplyDelay = 0.01;
        for (NSNumber *cachedDenial in @[@NO, @YES]) {
            NSCAssert(unlink([RBX_LICENSE_STATE_PLIST fileSystemRepresentation]) == 0 || errno == ENOENT, @"Could not reset private license fixture");
            if (cachedDenial.boolValue) {
                NSMutableDictionary *claims = TestLicenseClaims(@"ZZZZ-YYYY-XXXX-WWWW", @"initial-migration-denial", sClock);
                claims[@"status"] = @"invalid"; claims[@"exp"] = @((long long)sClock + 300);
                NSCAssert(RBXLicenseWriteState(@{@"formatVersion": @1, @"token": TestLicenseJWT(claims, nil),
                    @"forcedLocked": @YES, @"status": @"invalid", @"reason": @"Device binding not established",
                    @"retryAt": @0, @"lastObservedAt": @(sClock)}, nil), @"Could not save private migration denial");
            }
            RBXLicenseGuard *migration = [RBXLifetimeGuard new];
            NSCAssert(!migration.isUnlocked && !migration.trafficEntitlementValid, @"Uninitialized migration authorized traffic");
            sMigrationExpectedPath = @"/api/devices/claim";
            ValidateMigration(migration);
            NSCAssert([[NSDictionary dictionaryWithContentsOfFile:RBX_LICENSE_CLOUD_PLIST] isEqual:originalPairing], @"Migration replaced existing cloud pairing");
            NSCAssert(migration.isUnlocked && migration.trafficEntitlementValid, @"Signed migrated entitlement did not unlock");
            sMigrationExpectedPath = @"/api/licenses/validate";
            ValidateMigration(migration);
        }
        sMigrationExpectedPath = nil;
        NSCAssert(unlink([RBX_LICENSE_STATE_PLIST fileSystemRepresentation]) == 0, @"Could not remove private migration fixture");
        RBXLicenseGuard *guard = [RBXLifetimeGuard new];
        NSCAssert(!guard.trafficEntitlementValid, @"Unverified grant authorized traffic");

        // A times out but its backend ignores cancel. Queue B while A's response
        // is outstanding, then prove A neither overwrites B nor unlocks old A.
        SetKey(@"key-A");
        sReplyDelay = 0.30;
        RBXOperationContext *a = Context(@"license-A", 0.05);
        dispatch_semaphore_t aDone = dispatch_semaphore_create(0);
        __block NSUInteger aCompletions = 0;
        [guard validateWithContext:a completion:^(BOOL unlocked, NSString *message) {
            NSCAssert(!unlocked && message.length, @"Timeout must report failure");
            aCompletions++;
            dispatch_semaphore_signal(aDone);
        }];
        Wait(sRequestStarted, @"A HTTP start");
        Wait(aDone, @"A timeout result");
        NSCAssert(![a waitForQuiescence:0.01], @"Late HTTP callback must remain counted");
        NSCAssert(![guard isUnlocked], @"Canceled A cannot unlock");
        [guard invalidatePendingValidation];
        SetKey(@"key-B");
        sReplyDelay = 0.01;
        RBXOperationContext *b = Context(@"license-B", 2);
        dispatch_semaphore_t bDone = dispatch_semaphore_create(0);
        [guard validateWithContext:b completion:^(BOOL unlocked, NSString *message) {
            NSCAssert(unlocked && !message.length, @"B must validate: %@", message);
            dispatch_semaphore_signal(bDone);
        }];
        Wait(sRequestStarted, @"B HTTP start");
        Wait(bDone, @"B completion");
        NSCAssert([b waitForQuiescence:1], @"B must drain");
        NSData *bState = [NSData dataWithContentsOfFile:RBX_LICENSE_STATE_PLIST];
        NSCAssert([a waitForQuiescence:1], @"A response must eventually drain");
        NSCAssert(aCompletions == 1, @"A must complete only once");
        NSCAssert([[NSData dataWithContentsOfFile:RBX_LICENSE_STATE_PLIST] isEqual:bState], @"Late A overwrote B");
        NSCAssert([guard isUnlocked], @"B authorization must survive late A");
        NSCAssert(guard.trafficEntitlementValid && guard.trafficEntitlementExpiresAt == 1770000000 + 72 * 3600,
            @"Verified grant did not bound traffic expiry");
        [a finish]; [b finish];

        // A separate process can change settings without calling invalidation.
        // Capture the old key, change it during HTTP, reject the late result.
        sReplyDelay = 0.10;
        RBXOperationContext *changed = Context(@"changed-key", 2);
        dispatch_semaphore_t changedDone = dispatch_semaphore_create(0);
        [guard validateWithContext:changed completion:^(BOOL unlocked, NSString *message) {
            NSCAssert(!unlocked && [message containsString:@"changed"], @"Changed key must reject result");
            dispatch_semaphore_signal(changedDone);
        }];
        Wait(sRequestStarted, @"changed-key HTTP start");
        SetKey(@"key-C");
        NSCAssert(![guard isUnlocked], @"Cached B cannot authorize C");
        Wait(changedDone, @"changed-key result");
        NSCAssert([changed waitForQuiescence:1], @"Changed-key operation must drain");
        NSCAssert([[NSData dataWithContentsOfFile:RBX_LICENSE_STATE_PLIST] isEqual:bState], @"Changed key published stale state");
        [changed finish];

        SetKey(@"key-B");
        NSMutableDictionary *state = [NSMutableDictionary dictionaryWithContentsOfFile:RBX_LICENSE_CLOUD_PLIST];
        state[@"serverURL"] = @"https://other-license.example.test";
        [state writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];
        NSCAssert(![guard isUnlocked], @"Cached authorization must be bound to its server");
        NSCAssert(sKills == 0 && sAlerts == 0, @"Obsolete validations must not enforce a lock or alert");
        state[@"serverURL"] = @"https://license.example.test";
        [state writeToFile:RBX_LICENSE_CLOUD_PLIST atomically:YES];

        BOOL (^validate)(BOOL) = ^BOOL(BOOL expected) {
            RBXOperationContext *operation = Context(NSUUID.UUID.UUIDString, 2);
            dispatch_semaphore_t completed = dispatch_semaphore_create(0);
            __block BOOL actual = NO;
            [guard validateWithContext:operation completion:^(BOOL unlocked, NSString *message) {
                actual = unlocked; NSCAssert(unlocked == expected, @"Unexpected license decision: %@", message);
                dispatch_semaphore_signal(completed);
            }];
            Wait(completed, @"license result");
            NSCAssert([operation waitForQuiescence:1], @"License test operation did not drain");
            [operation finish]; return actual;
        };
        sReplyDelay = 0.01; sHTTPStatus = 503; sClock += 1;
        NSCAssert(validate(YES), @"Offline signed grace should allow access");
        NSDictionary *offline = [guard safeStatus];
        NSCAssert([offline[@"offlineGrace"] boolValue], @"Offline reason missing");
        NSCAssert([offline[@"lastValidatedAt"] doubleValue] == 1770000000, @"Offline failure refreshed last success");
        NSCAssert([offline[@"expiresAt"] doubleValue] == 1770000000 + 72 * 3600, @"Offline failure extended signed expiry");
        NSCAssert(![guard validationDue], @"Retry backoff ignored");
        sClock = 1770000000 + 72 * 3600;
        NSCAssert(![guard isUnlocked] && [[guard safeStatus][@"status"] isEqual:@"grace-expired"], @"Grace boundary accepted");
        NSCAssert(!guard.trafficEntitlementValid && guard.trafficEntitlementExpiresAt == 0, @"Fast gate outlived signed expiry");
        NSCAssert(!validate(NO), @"Offline expired token accepted");

        sClock += 61; sHTTPStatus = 200;
        NSCAssert(validate(YES), @"Online recovery failed");
        sClock += 1; sLicenseStatus = @"revoked";
        NSCAssert(!validate(NO) && ![guard isUnlocked], @"Signed revocation accepted");
        NSCAssert(!guard.trafficEntitlementValid, @"Fast gate survived signed revocation");
        sClock += 61; sHTTPStatus = 503;
        NSCAssert(!validate(NO), @"Offline grace resurrected revoked token");
        sClock += 61; sHTTPStatus = 200; sLicenseStatus = @"active";
        NSCAssert(validate(YES), @"Re-enabled entitlement failed");
        sClock += 1; sUnsignedReply = YES;
        NSCAssert(!validate(NO) && ![guard isUnlocked], @"Unsigned legacy response unlocked device");
        sUnsignedReply = NO; sClock += 61;
        NSCAssert(validate(YES), @"Signed recovery after invalid response failed");
        sClock -= 30;
        NSCAssert(![guard isUnlocked] && [[guard safeStatus][@"status"] isEqual:@"clock-error"], @"Clock rollback reused offline token");
        NSCAssert(validate(YES), @"Fresh nonce-bound check failed to recover corrected clock");
        sMonotonic += 72 * 3600 + 1;
        NSCAssert(!guard.trafficEntitlementValid, @"Frozen wall clock extended monotonic traffic deadline");
        NSCAssert(![guard isUnlocked], @"Cache reread renewed an unchanged token's monotonic deadline");
        NSCAssert(sKills == 0 && sAlerts == 0, @"Guard performed unsynchronized network/process enforcement");
        puts("PASS: actual signed license guard migration bootstrap, cached migration denial, lifetime, stale settings, 72h grace, retry, revocation, unsigned denial and clock rollback tests");
    }
    return 0;
}
