#import "RBXLicenseGuard.h"
#import "RBXLicenseToken.h"
#import "RBXSecureConfig.h"
#import "RBXCloudSync.h"
#import "RBXOperationContext.h"
#import "RBXCloudOrigin.h"
#import <Security/Security.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <time.h>

#ifndef RBX_LICENSE_CLOUD_PLIST
#define RBX_LICENSE_CLOUD_PLIST @"/var/mobile/Library/Preferences/com.redditbox.cloud.plist"
#endif
#ifndef RBX_LICENSE_STATE_PLIST
#define RBX_LICENSE_STATE_PLIST @"/var/mobile/Library/Preferences/com.redditbox.license-state.plist"
#endif
static const NSTimeInterval kHTTPTimeout = 20;
static NSError *RBXLicenseError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.license" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static BOOL RBXLicenseCheck(RBXOperationContext *context, NSError **error) {
    if (!context || context.inspectionOnly) {
        if (error) *error = RBXLicenseError(@"License changes need an authorized operation owner"); return NO;
    }
    return [context check:error];
}
static NSString *RBXLicenseString(NSDictionary *value, NSString *field) {
    return [value[field] isKindOfClass:NSString.class] ? value[field] : @"";
}
static NSTimeInterval RBXLicenseNumber(NSDictionary *value, NSString *field) {
    id number = value[field];
    return [number isKindOfClass:NSNumber.class] && isfinite([number doubleValue]) ? [number doubleValue] : 0;
}
static uid_t RBXLicenseStateOwner(void) {
#ifdef RBX_LICENSE_TESTING
    return geteuid();
#else
    return 0;
#endif
}
static NSDictionary *RBXLicenseReadState(NSError **error) {
    struct stat info;
    if (lstat([RBX_LICENSE_STATE_PLIST fileSystemRepresentation], &info) != 0) {
        if (errno == ENOENT) return @{};
        if (error) *error = RBXLicenseError(@"License state cannot be inspected"); return nil;
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != RBXLicenseStateOwner() || info.st_nlink != 1 || (info.st_mode & 0077)) {
        if (error) *error = RBXLicenseError(@"License state permissions are unsafe"); return nil;
    }
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:RBX_LICENSE_STATE_PLIST];
    if (![state isKindOfClass:NSDictionary.class] || ![state[@"formatVersion"] isEqual:@1]) {
        if (error) *error = RBXLicenseError(@"License state is corrupt or newer than this build"); return nil;
    }
    return state;
}
static BOOL RBXLicenseWriteState(NSDictionary *state, NSError **error) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    NSString *path = RBX_LICENSE_STATE_PLIST;
    NSString *temporary = [path stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    int descriptor = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    BOOL ok = descriptor >= 0; NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t written = write(descriptor, (const char *)data.bytes + offset, data.length - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { ok = NO; break; }
        offset += (NSUInteger)written;
    }
    if (ok) ok = fchmod(descriptor, 0600) == 0 && fchown(descriptor, RBXLicenseStateOwner(), getegid()) == 0 && fsync(descriptor) == 0;
    if (descriptor >= 0 && close(descriptor) != 0) ok = NO;
    if (ok) ok = rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (ok) {
        int parent = open(path.stringByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        ok = parent >= 0 && fsync(parent) == 0;
        if (parent >= 0) close(parent);
    }
    if (!ok || ![[NSData dataWithContentsOfFile:path] isEqual:data]) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = RBXLicenseError(@"License state could not be durably saved; traffic must remain closed"); return NO;
    }
    return YES;
}

@interface RBXLicenseRedirectPolicy : NSObject <NSURLSessionTaskDelegate>
@end
@implementation RBXLicenseRedirectPolicy
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    // Never forward access-key bodies or device credentials through redirects.
    completionHandler(nil);
}
@end
static NSURLSession *RBXLicenseHTTPSession(void) {
    static NSURLSession *session; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = kHTTPTimeout;
        configuration.timeoutIntervalForResource = kHTTPTimeout * 2;
        configuration.HTTPCookieStorage = nil; configuration.URLCache = nil;
#ifndef RBX_LICENSE_SESSION_CLASS
#define RBX_LICENSE_SESSION_CLASS NSURLSession
#endif
        session = (NSURLSession *)[RBX_LICENSE_SESSION_CLASS sessionWithConfiguration:configuration delegate:[RBXLicenseRedirectPolicy new] delegateQueue:nil];
    });
    return session;
}

@implementation RBXLicenseGuard {
    dispatch_queue_t _queue;
    NSUInteger _configurationRevision;
    NSMutableSet<RBXOperationContext *> *_validations;
    NSTimeInterval _highestObservedAt;
    BOOL _persistenceFailed;
    NSString *_trafficToken;
    NSObject *_trafficLock;
    BOOL _trafficGranted;
    NSTimeInterval _trafficDeadlineMonotonic, _trafficWallDeadline, _trafficLastWall;
}
+ (instancetype)sharedGuard { static id guard; static dispatch_once_t once; dispatch_once(&once, ^{ guard = [self new]; }); return guard; }
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.redditbox.license", DISPATCH_QUEUE_SERIAL);
        _validations = [NSMutableSet set];
        _trafficLock = [NSObject new];
    }
    return self;
}
- (NSTimeInterval)_now { return NSDate.date.timeIntervalSince1970; }
- (NSTimeInterval)_monotonicNow {
    struct timespec value;
    return clock_gettime(CLOCK_MONOTONIC, &value) == 0 ? value.tv_sec + value.tv_nsec / 1e9 : NAN;
}
- (NSTimeInterval)trafficEntitlementExpiresAt {
    @synchronized (_trafficLock) {
        NSTimeInterval wall = [self _now], monotonic = [self _monotonicNow];
        if (!_trafficGranted || !isfinite(wall) || !isfinite(monotonic) || wall < _trafficLastWall - 5 ||
            wall >= _trafficWallDeadline || monotonic >= _trafficDeadlineMonotonic) {
            _trafficGranted = NO; return 0;
        }
        _trafficLastWall = MAX(_trafficLastWall, wall);
        return MIN(_trafficWallDeadline, wall + (_trafficDeadlineMonotonic - monotonic));
    }
}
- (BOOL)trafficEntitlementValid { return [self trafficEntitlementExpiresAt] > 0; }
- (NSDictionary *)_identityQuery {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.redditbox.license-device",
        (__bridge id)kSecAttrAccount: @"installation-id",
        (__bridge id)kSecAttrAccessGroup: @"RBXBOXCFG.com.redditbox.daemon-control"};
}
- (NSString *)_readDeviceIdentity:(NSError **)error {
    NSMutableDictionary *query = [[self _identityQuery] mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) return nil;
    if (status != errSecSuccess) {
        if (result) CFRelease(result);
        if (error) *error = RBXLicenseError(@"License device identity cannot be read from Keychain"); return nil;
    }
    NSData *bytes = CFBridgingRelease(result);
    NSString *identity = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
    NSUUID *uuid = identity ? [[NSUUID alloc] initWithUUIDString:identity] : nil;
    if (!uuid || ![uuid.UUIDString.lowercaseString isEqual:identity]) {
        if (error) *error = RBXLicenseError(@"License device identity is corrupt; it was not regenerated"); return nil;
    }
    return identity;
}
- (NSString *)deviceIdentityWithContext:(RBXOperationContext *)context error:(NSError **)error {
    if (!RBXLicenseCheck(context, error)) return nil;
    @synchronized (self) {
        NSError *readError = nil; NSString *identity = [self _readDeviceIdentity:&readError];
        if (identity || readError) { if (error) *error = readError; return identity; }
        identity = NSUUID.UUID.UUIDString.lowercaseString;
        NSMutableDictionary *item = [[self _identityQuery] mutableCopy];
        item[(__bridge id)kSecValueData] = [identity dataUsingEncoding:NSUTF8StringEncoding];
        item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        if (!RBXLicenseCheck(context, error)) return nil;
        OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        if (status != errSecSuccess && status != errSecDuplicateItem) {
            if (error) *error = RBXLicenseError(@"License device identity could not be saved"); return nil;
        }
        return [self _readDeviceIdentity:error];
    }
}
- (NSDictionary *)_configuration {
    @synchronized (self) {
        NSDictionary *cloud = [NSDictionary dictionaryWithContentsOfFile:RBX_LICENSE_CLOUD_PLIST] ?: @{};
        NSError *keyError = nil, *identityError = nil;
        NSString *rawKey = [RBXSecureConfig accessKey:&keyError] ?: @"";
        NSString *key = [[rawKey stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] uppercaseString];
        NSString *identity = [self _readDeviceIdentity:&identityError] ?: @"";
        NSString *device = RBXLicenseString(cloud, @"deviceId");
        NSString *server = [RBXLicenseToken canonicalServer:RBXCloudConfiguredOrigin(cloud[@"serverURL"])] ?: @"";
        NSString *fingerprintInput = key.length ? key : [@"admin:" stringByAppendingString:device];
        return @{@"key": key, @"server": server, @"deviceId": device,
            @"deviceToken": RBXLicenseString(cloud, @"deviceToken"), @"deviceIdentity": identity,
            @"deviceBinding": [RBXLicenseToken fingerprint:identity],
            @"keyFingerprint": [RBXLicenseToken fingerprint:fingerprintInput],
            @"revision": @(_configurationRevision), @"configurationError": @(keyError != nil || identityError != nil)};
    }
}
- (BOOL)_checkConfiguration:(NSDictionary *)captured context:(RBXOperationContext *)context error:(NSError **)error {
    if (!RBXLicenseCheck(context, error)) return NO;
    if (![captured isEqual:[self _configuration]]) {
        if (error) *error = RBXLicenseError(@"License configuration changed during validation; retry with current settings"); return NO;
    }
    return YES;
}
- (NSDictionary *)_verifyToken:(NSString *)token expected:(NSDictionary *)expected nonce:(NSString *)nonce now:(NSTimeInterval)now error:(NSError **)error {
    return [RBXLicenseToken verifyToken:token expected:expected nonce:nonce now:now error:error];
}
- (NSDictionary *)_statusForConfiguration:(NSDictionary *)configuration {
    NSError *error = nil; NSDictionary *state = RBXLicenseReadState(&error);
    NSString *status = @"activation-required", *reason = @"Enter an access key and activate this device.";
    BOOL unlocked = NO, grace = NO; NSTimeInterval now = [self _now], expires = 0;
    @synchronized (self) {
        NSTimeInterval observed = MAX(_highestObservedAt, RBXLicenseNumber(state, @"lastObservedAt"));
        BOOL backwards = !isfinite(now) || now < observed - 5;
        if (!backwards) _highestObservedAt = MAX(observed, now);
        if (_persistenceFailed || error || [configuration[@"configurationError"] boolValue]) {
            status = @"state-error"; reason = @"License storage is unavailable or unsafe; review diagnostics.";
        } else if (backwards) {
            status = @"clock-error"; reason = @"Device time moved backward; correct the clock and validate online.";
        } else if (![configuration[@"server"] length]) {
            status = @"configuration-required"; reason = @"Set an HTTPS cloud server origin before activation.";
        } else if ([state[@"forcedLocked"] boolValue]) {
            status = RBXLicenseString(state, @"status"); reason = RBXLicenseString(state, @"reason");
        } else if (![configuration[@"deviceIdentity"] length] || ![configuration[@"deviceId"] length] || ![configuration[@"deviceToken"] length]) {
            status = @"activation-required";
        } else if ([state[@"token"] isKindOfClass:NSString.class]) {
            NSDictionary *claims = [self _verifyToken:state[@"token"] expected:configuration nonce:nil now:now error:&error];
            expires = RBXLicenseNumber(claims, @"exp");
            if (!claims) { status = @"invalid-token"; reason = @"The signed license is invalid for this device, key or deployment."; }
            else if (![claims[@"status"] isEqual:@"active"]) {
                status = claims[@"status"]; reason = @"License is invalid, revoked or expired. Contact the administrator or enter another key.";
            } else if (now >= expires) {
                status = @"grace-expired"; reason = @"License expiry or the 72-hour offline grace deadline was reached. Validate online.";
            } else {
                unlocked = YES; grace = [state[@"offlineGrace"] boolValue];
                status = grace ? @"offline-grace" : @"active";
                reason = grace ? @"Cloud is unavailable. Existing signed access remains valid until the displayed deadline." : @"Device license is active.";
            }
        }
        @synchronized (_trafficLock) {
        if (unlocked) {
            NSTimeInterval monotonic = [self _monotonicNow];
            NSTimeInterval proposed = monotonic + MAX(0, expires - now);
            NSString *token = RBXLicenseString(state, @"token");
            // Re-reading one cached token never resets its monotonic lifetime.
            if ([_trafficToken isEqual:token]) proposed = MIN(proposed, _trafficDeadlineMonotonic);
            if (!isfinite(monotonic) || proposed <= monotonic) {
                unlocked = NO; grace = NO; status = @"grace-expired";
                reason = @"The verified license lifetime elapsed; validate online.";
            } else {
                _trafficToken = token; _trafficDeadlineMonotonic = proposed;
                _trafficWallDeadline = expires; _trafficLastWall = now;
            }
        }
        _trafficGranted = unlocked;
        }
    }
    return @{@"unlocked": @(unlocked), @"status": status.length ? status : @"invalid", @"reason": reason.length ? reason : @"License validation is required.",
        @"offlineGrace": @(grace), @"retryAt": @(RBXLicenseNumber(state, @"retryAt")),
        @"lastValidatedAt": @(RBXLicenseNumber(state, @"lastValidatedAt")), @"expiresAt": @(expires), @"graceUntil": @(expires),
        @"serverURL": configuration[@"server"] ?: @"", @"paired": @([configuration[@"deviceToken"] length] > 0 && [configuration[@"deviceId"] length] > 0)};
}
- (NSDictionary *)safeStatus { return [self _statusForConfiguration:[self _configuration]]; }
- (BOOL)isUnlocked { return [[self safeStatus][@"unlocked"] boolValue]; }
- (BOOL)validationDue {
    NSDictionary *status = [self safeStatus]; NSTimeInterval now = [self _now];
    if (now < RBXLicenseNumber(status, @"retryAt")) return NO;
    return now - RBXLicenseNumber(status, @"lastValidatedAt") >= 24 * 3600 || ![status[@"unlocked"] boolValue] || [status[@"offlineGrace"] boolValue];
}
- (void)invalidatePendingValidation {
    NSArray *contexts;
    @synchronized (_trafficLock) { _trafficGranted = NO; }
    @synchronized (self) { _configurationRevision++; contexts = _validations.allObjects; }
    for (RBXOperationContext *context in contexts) [context cancelWithReason:@"License configuration changed during validation"];
}
- (BOOL)_persist:(NSDictionary *)changes configuration:(NSDictionary *)configuration context:(RBXOperationContext *)context error:(NSError **)error {
    if ([changes[@"forcedLocked"] boolValue]) @synchronized (_trafficLock) { _trafficGranted = NO; }
    @synchronized (self) {
        if (![self _checkConfiguration:configuration context:context error:error]) return NO;
        NSMutableDictionary *state = [RBXLicenseReadState(error) mutableCopy];
        if (!state) { _persistenceFailed = YES; @synchronized (_trafficLock) { _trafficGranted = NO; } return NO; }
        [state addEntriesFromDictionary:changes]; state[@"formatVersion"] = @1;
        // A new nonce-bound successful server check can recover a corrected
        // clock. An offline read/failure can never move the high-water mark back.
        if (changes[@"lastValidatedAt"] && ![changes[@"forcedLocked"] boolValue]) {
            _highestObservedAt = [self _now]; state[@"lastObservedAt"] = @(_highestObservedAt);
        } else state[@"lastObservedAt"] = @(MAX(MAX([self _now], _highestObservedAt), RBXLicenseNumber(state, @"lastObservedAt")));
        if (![self _checkConfiguration:configuration context:context error:error]) return NO;
        BOOL saved = RBXLicenseWriteState(state, error); _persistenceFailed = !saved;
        if (!saved) @synchronized (_trafficLock) { _trafficGranted = NO; }
        return saved;
    }
}
- (BOOL)_lockStatus:(NSString *)status reason:(NSString *)reason configuration:(NSDictionary *)configuration context:(RBXOperationContext *)context error:(NSError **)error {
    return [self _persist:@{@"forcedLocked": @YES, @"status": status, @"reason": reason,
        @"offlineGrace": @NO, @"retryAt": @([self _now] + 60)} configuration:configuration context:context error:error];
}
- (BOOL)enforceLockWithContext:(RBXOperationContext *)context error:(NSError **)error {
    return [self _lockStatus:@"invalid" reason:@"License access is locked; validate online."
        configuration:[self _configuration] context:context error:error];
}
- (void)enforceLock { RBXOperationContext *context = RBXOperationContext.currentContext; if (context) [self enforceLockWithContext:context error:nil]; }
- (void)start { /* main owns serialized scheduling and traffic revocation */ }
- (void)validateAndThen:(void (^)(BOOL))done {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!context) { if (done) done(NO); return; }
    [self validateWithContext:context completion:^(BOOL unlocked, NSString *message) { if (done) done(unlocked); }];
}
- (void)validateWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *))done {
    [self _runWithContext:context activate:NO completion:done];
}
- (void)activateWithContext:(RBXOperationContext *)context completion:(void (^)(BOOL, NSString *))done {
    [self _runWithContext:context activate:YES completion:done];
}
- (void)_runWithContext:(RBXOperationContext *)context activate:(BOOL)activate completion:(void (^)(BOOL, NSString *))done {
    NSError *error = nil;
    if (!RBXLicenseCheck(context, &error)) { if (done) done(NO, error.localizedDescription); return; }
    @synchronized (self) { [_validations addObject:context]; }
    BOOL queued = [context dispatchAsyncOnQueue:_queue block:^{
        @try {
            NSError *failure = nil; BOOL unlocked = [self _validateWithContext:context activate:activate error:&failure];
            if (unlocked && ![self isUnlocked]) {
                unlocked = NO; failure = RBXLicenseError(@"License configuration changed before completion");
            }
            if (done) done(unlocked, failure.localizedDescription);
        } @finally { @synchronized (self) { [self->_validations removeObject:context]; } }
    }];
    if (!queued) {
        @synchronized (self) { [_validations removeObject:context]; }
        [context check:&error]; if (done) done(NO, error.localizedDescription ?: @"License validation could not be scheduled");
    }
}
- (BOOL)_validateWithContext:(RBXOperationContext *)context activate:(BOOL)activate error:(NSError **)error {
    if (!RBXLicenseCheck(context, error)) return NO;
    NSDictionary *configuration = [self _configuration];
    if ([configuration[@"configurationError"] boolValue] || ![configuration[@"server"] length]) {
        if (error) *error = RBXLicenseError(@"License Keychain or HTTPS server configuration is unavailable"); return NO;
    }
    if (![configuration[@"key"] length] && ![configuration[@"deviceToken"] length]) {
        if (error) *error = RBXLicenseError(@"Enter an access key to activate this device"); return NO;
    }
    if (![configuration[@"deviceIdentity"] length]) {
        if (![self deviceIdentityWithContext:context error:error]) return NO;
        configuration = [self _configuration];
    }
    NSDictionary *status = [self _statusForConfiguration:configuration];
    if ([self _now] < RBXLicenseNumber(status, @"retryAt") && ![status[@"status"] isEqual:@"clock-error"]) {
        if (error && ![status[@"unlocked"] boolValue]) *error = RBXLicenseError(@"License check is temporarily rate limited; retry at the displayed time");
        return [status[@"unlocked"] boolValue];
    }
    NSDictionary *previousState = RBXLicenseReadState(error);
    if (!previousState) return NO;
    // Pre-paired upgrades can retain a legacy key and even an initial signed
    // denial. Bootstrap their installation binding until the first verified
    // active grant; a denial alone must not trap them on the validate endpoint.
    BOOL neverValidated = RBXLicenseNumber(previousState, @"lastValidatedAt") <= 0;
    BOOL claim = activate || ![configuration[@"deviceToken"] length] || ![configuration[@"deviceId"] length] ||
        !RBXLicenseString(previousState, @"token").length || neverValidated;
    NSString *nonce = NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *body = [@{@"deviceIdentity": configuration[@"deviceIdentity"], @"nonce": nonce} mutableCopy];
    if ([configuration[@"key"] length]) body[@"key"] = configuration[@"key"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[configuration[@"server"]
        stringByAppendingString:claim ? @"/api/devices/claim" : @"/api/licenses/validate"]]];
    request.HTTPMethod = @"POST"; request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([configuration[@"deviceToken"] length]) [request setValue:[@"Bearer " stringByAppendingString:configuration[@"deviceToken"]] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!request.HTTPBody) return NO;
    NSError *networkError = nil;
    NSDictionary *response = [self _performDataRequest:request context:context error:&networkError];
    if (![self _checkConfiguration:configuration context:context error:error]) return NO;
    NSInteger code = [response[@"status"] integerValue];
    if (!response || code == 429 || code >= 500) {
        NSTimeInterval delay = MAX(60, MIN(3600, RBXLicenseNumber(response, @"retryAfter")));
        BOOL usable = [[self _statusForConfiguration:configuration][@"unlocked"] boolValue];
        if (![self _persist:@{@"offlineGrace": @(usable), @"retryAt": @([self _now] + delay)}
            configuration:configuration context:context error:error]) return NO;
        if (!usable && error) *error = RBXLicenseError(@"Cloud is unavailable and there is no current signed offline entitlement");
        return usable;
    }
    NSDictionary *json = [response[@"data"] length] ? [NSJSONSerialization JSONObjectWithData:response[@"data"] options:0 error:nil] : nil;
    if (code == 401 || code == 403 || code == 404 || code == 409) {
        // Unsigned error text never grants access and is not displayed verbatim.
        // Keep a useful rejection visible even before the first pairing exists.
        NSString *status = code == 404 ? @"invalid-key" : code == 409 ? @"activation-conflict" : @"activation-denied";
        NSString *reason = code == 404 ? @"This license key was not found. Check the key and try again." :
            code == 409 ? @"This installation or license is already bound. Its saved credential or administrator recovery is required." :
            @"The license or saved device credential was rejected. Check its status with the administrator.";
        if (![self _lockStatus:status reason:reason configuration:configuration context:context error:error]) return NO;
        if (error) *error = RBXLicenseError(reason);
        return NO;
    }
    NSMutableDictionary *expected = [configuration mutableCopy];
    if (claim && [json isKindOfClass:NSDictionary.class]) {
        expected[@"deviceId"] = RBXLicenseString(json, @"deviceId");
        if (![configuration[@"key"] length]) expected[@"keyFingerprint"] = [RBXLicenseToken fingerprint:[@"admin:" stringByAppendingString:expected[@"deviceId"]]];
    }
    NSError *tokenError = nil;
    NSDictionary *claims = code == 200 && [json isKindOfClass:NSDictionary.class] ?
        [self _verifyToken:RBXLicenseString(json, @"licenseToken") expected:expected nonce:nonce now:[self _now] error:&tokenError] : nil;
    if (!claims) {
        [self _lockStatus:@"invalid-token" reason:@"Activation or signed license validation failed; verify the key and deployment pin."
            configuration:configuration context:context error:error];
        if (error && !*error) *error = RBXLicenseError(@"Activation or signed license validation failed; verify the key and deployment pin"); return NO;
    }
    BOOL active = [claims[@"status"] isEqual:@"active"] && RBXLicenseNumber(claims, @"exp") > [self _now];
    if (claim && active) {
        NSMutableDictionary *pairing = [json mutableCopy]; pairing[@"serverURL"] = configuration[@"server"];
        if (![self _checkConfiguration:configuration context:context error:error] ||
            ![[RBXCloudSync sharedSync] acceptLicensePairing:pairing context:context error:error]) return NO;
        configuration = [self _configuration];
        if (![configuration[@"deviceId"] isEqual:expected[@"deviceId"]] ||
            ![configuration[@"server"] isEqual:expected[@"server"]] ||
            ![configuration[@"keyFingerprint"] isEqual:expected[@"keyFingerprint"]] ||
            ![configuration[@"deviceBinding"] isEqual:expected[@"deviceBinding"]]) {
            if (error) *error = RBXLicenseError(@"License pairing changed before token publication"); return NO;
        }
    }
    NSString *reason = active ? @"Device license is active." : @"License is invalid, revoked or expired. Contact the administrator or enter another key.";
    NSMutableDictionary *changes = [@{@"token": json[@"licenseToken"], @"forcedLocked": @(!active),
        @"status": active ? @"active" : ([claims[@"status"] isEqual:@"active"] ? @"expired" : claims[@"status"]), @"reason": reason, @"offlineGrace": @NO,
        @"retryAt": @([self _now] + (active ? 0 : 60))} mutableCopy];
    if (active) changes[@"lastValidatedAt"] = @([self _now]);
    if (![self _persist:changes configuration:configuration context:context error:error]) return NO;
    if (!active && error) *error = RBXLicenseError(reason);
    return active;
}
- (NSDictionary *)_performDataRequest:(NSMutableURLRequest *)request context:(RBXOperationContext *)context error:(NSError **)error {
    if (!RBXLicenseCheck(context, error)) return nil;
    request.timeoutInterval = MAX(0.001, MIN(kHTTPTimeout, context.remainingTime));
    NSObject *lock = [NSObject new]; __block BOOL accepting = YES;
    __block NSDictionary *output = nil; __block NSError *networkError = nil;
    dispatch_semaphore_t signal = dispatch_semaphore_create(0); __block NSURLSessionDataTask *task = nil;
    task = [RBXLicenseHTTPSession() dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *failure) {
        @try {
            @synchronized (lock) { if (accepting) {
                NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
                networkError = failure;
                output = @{@"data": data ?: NSData.data, @"status": @(http.statusCode),
                    @"retryAfter": @([[http valueForHTTPHeaderField:@"Retry-After"] doubleValue])};
            } }
            dispatch_semaphore_signal(signal);
        } @finally { [context untrackTask:task]; task = nil; }
    }];
    [context trackTask:task];
    NSString *cancel = [context registerCancellationHandler:^{ dispatch_semaphore_signal(signal); }];
    if (RBXLicenseCheck(context, nil)) [task resume]; else [task cancel];
    long expired = dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0, context.remainingTime) * NSEC_PER_SEC)));
    [context unregisterCancellationHandler:cancel];
    NSDictionary *result; NSError *failure;
    @synchronized (lock) { accepting = NO; result = output; failure = networkError; }
    if (expired) [context cancelWithReason:@"License validation deadline expired"];
    if (!RBXLicenseCheck(context, error)) return nil;
    if (failure) { if (error) *error = failure; return nil; }
    return result;
}
@end
