#import "../shared/RBXCloneAcceptanceProbe.h"

static NSMutableDictionary *Items;
static NSString *CurrentGroup;
static NSUInteger SecurityCalls;
static NSMutableDictionary *DefaultsItems;
static BOOL DefaultsCanary(NSString *nonce, BOOL cleanup) {
    if (!DefaultsItems) DefaultsItems = [NSMutableDictionary dictionary];
    NSString *key = [CurrentGroup stringByAppendingString:nonce];
    if (cleanup) [DefaultsItems removeObjectForKey:key];
    else DefaultsItems[key] = nonce;
    return cleanup ? DefaultsItems[key] == nil : [DefaultsItems[key] isEqual:nonce];
}
static NSString *Root, *A, *B;
static NSString *BundleA = @"com.redditbox.profile.pacceptanceA";
static NSString *BundleB = @"com.redditbox.profile.pacceptanceB";
static NSString *Nonce;
static NSTimeInterval Now;
static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSString *ItemKey(NSDictionary *query) {
    Check([query[(__bridge id)kSecAttrService] isEqual:@"com.redditbox.acceptance.canary.v1"], @"only dedicated canary service accessed");
    Check([query[(__bridge id)kSecAttrSynchronizable] isEqual:@NO], @"all canary operations local-only");
    return [CurrentGroup stringByAppendingString:query[(__bridge id)kSecAttrAccount]];
}
static OSStatus Add(CFDictionaryRef input, CFTypeRef *result) {
    (void)result;
    SecurityCalls++; NSDictionary *q = (__bridge NSDictionary *)input;
    Check(!q[(__bridge id)kSecAttrAccessGroup], @"seed uses actual default group");
    NSString *key = ItemKey(q);
    if (Items[key]) return errSecDuplicateItem;
    Items[key] = q[(__bridge id)kSecValueData]; return errSecSuccess;
}
static OSStatus Copy(CFDictionaryRef input, CFTypeRef *result) {
    SecurityCalls++; NSDictionary *q = (__bridge NSDictionary *)input;
    NSString *key = ItemKey(q), *group = q[(__bridge id)kSecAttrAccessGroup];
    if (group && ![group isEqual:CurrentGroup]) return errSecMissingEntitlement;
    NSData *value = Items[key];
    if (!value) return errSecItemNotFound;
    *result = CFBridgingRetain(value); return errSecSuccess;
}
static OSStatus Remove(CFDictionaryRef input) {
    SecurityCalls++; NSDictionary *q = (__bridge NSDictionary *)input;
    Check(!q[(__bridge id)kSecAttrAccessGroup], @"cleanup only own default group");
    NSString *key = ItemKey(q);
    if (!Items[key]) return errSecItemNotFound;
    [Items removeObjectForKey:key]; return errSecSuccess;
}
static NSString *Directory(NSString *home) {
    return [home stringByAppendingPathComponent:@"Library/Application Support/RedditBox/acceptance"];
}
static NSString *ResultPath(NSString *home, NSString *operation) {
    return [[Directory(home) stringByAppendingPathComponent:@"results"] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@-%@.json", Nonce, operation]];
}
static NSDictionary *Request(NSString *operation, NSString *target) {
    return @{@"schemaVersion": @1, @"nonce": Nonce, @"operation": operation,
        @"targetBundleId": target, @"sourceBundleId": BundleA,
        @"sourceDataUUID": A.lastPathComponent, @"expiresAt": @(Now + 3600)};
}
static void WriteRequest(NSString *home, id request) {
    NSString *path = [Directory(home) stringByAppendingPathComponent:@"request.json"];
    unlink(path.fileSystemRepresentation);
    NSData *data = [request isKindOfClass:NSData.class] ? request :
        [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    Check([data writeToFile:path atomically:NO], @"write fixture request");
    Check(chmod(path.fileSystemRepresentation, 0444) == 0, @"request read-only");
}
static void SetupHome(NSString *home, NSString *bundle) {
    NSString *results = [Directory(home) stringByAppendingPathComponent:@"results"];
    Check([NSFileManager.defaultManager createDirectoryAtPath:results withIntermediateDirectories:YES attributes:nil error:nil], @"create fixture hierarchy");
    chmod(Directory(home).fileSystemRepresentation, 0755);
    chmod(results.fileSystemRepresentation, 0700);
    NSString *prefs = [home stringByAppendingPathComponent:@"Library/Preferences"];
    [NSFileManager.defaultManager createDirectoryAtPath:prefs withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *ready = @{@"bundleIdentifier": bundle, @"pid": @(getpid()), @"generation": NSUUID.UUID.UUIDString,
        @"bootEpoch": @"fixture-epoch", @"timestamp": @(Now), @"allHooksInstalled": @YES};
    NSString *path = [prefs stringByAppendingPathComponent:@"com.redditbox.hook-ready.plist"];
    Check([ready writeToFile:path atomically:YES], @"write readiness fixture"); chmod(path.fileSystemRepresentation, 0600);
}
static BOOL Run(NSString *home, NSString *bundle, uid_t owner) {
    CurrentGroup = [@"RBXCLONE00." stringByAppendingString:bundle];
    RBXAcceptanceSecurity api = {Add, Copy, Remove, DefaultsCanary};
    return RBXAcceptanceRun(home, bundle, CurrentGroup, Root, owner, getuid(), getpid(), Now, api);
}
static NSDictionary *ReadResult(NSString *home, NSString *operation) {
    NSData *bytes = [NSData dataWithContentsOfFile:ResultPath(home, operation)];
    return bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
}
static NSString *Status(NSDictionary *report, NSString *identifier) {
    for (NSDictionary *row in report[@"checks"]) if ([row[@"id"] isEqual:identifier]) return row[@"status"];
    return nil;
}
static void ExpectRejected(NSString *home, NSString *bundle, uid_t owner, NSString *message) {
    NSUInteger before = SecurityCalls;
    Check(!Run(home, bundle, owner) && SecurityCalls == before, message);
}
int main(void) {
    @autoreleasepool {
        char path[] = "/tmp/redditbox-acceptance.XXXXXX";
        Check(mkdtemp(path) != NULL, @"create temporary directory");
        char canonical[PATH_MAX]; Check(realpath(path, canonical) != NULL, @"resolve fixture root");
        Root = [NSString stringWithUTF8String:canonical];
        A = [Root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        B = [Root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        Items = [NSMutableDictionary dictionary]; Nonce = NSUUID.UUID.UUIDString; Now = NSDate.date.timeIntervalSince1970;
        SetupHome(A, BundleA); SetupHome(B, BundleB);
        ExpectRejected(A, BundleA, getuid(), @"absent request is inert");
        NSDictionary *valid = Request(@"seed", BundleA);
        NSArray *changes = @[@{@"schemaVersion": @2}, @{@"nonce": @"../../outside"},
            @{@"sourceDataUUID": @"../other"}, @{@"targetBundleId": BundleB}, @{@"sourceBundleId": BundleB},
            @{@"operation": @"shell"}, @{@"expiresAt": @(Now - 1)}, @{@"expiresAt": @(Now + 86401)},
            @{@"expiresAt": @"tomorrow"}, @{@"path": @"/private/arbitrary"}];
        for (NSDictionary *change in changes) {
            NSMutableDictionary *request = valid.mutableCopy; [request addEntriesFromDictionary:change];
            WriteRequest(A, request); ExpectRejected(A, BundleA, getuid(), @"malformed, expired or wrong binding rejected");
        }
        WriteRequest(A, [@"not JSON" dataUsingEncoding:NSUTF8StringEncoding]);
        ExpectRejected(A, BundleA, getuid(), @"malformed JSON inert");
        WriteRequest(A, [NSMutableData dataWithLength:4097]);
        ExpectRejected(A, BundleA, getuid(), @"oversized request inert");
        WriteRequest(A, valid);
        ExpectRejected(A, BundleA, getuid() + 999, @"wrong challenge owner rejected");
        NSString *requestPath = [Directory(A) stringByAppendingPathComponent:@"request.json"];
        chmod(requestPath.fileSystemRepresentation, 0666);
        ExpectRejected(A, BundleA, getuid(), @"writable challenge rejected");
        chmod(requestPath.fileSystemRepresentation, 0444);
        NSString *target = [Root stringByAppendingPathComponent:@"root-fixture.json"];
        Check(rename(requestPath.fileSystemRepresentation, target.fileSystemRepresentation) == 0 &&
            symlink(target.fileSystemRepresentation, requestPath.fileSystemRepresentation) == 0, @"symlink request fixture");
        ExpectRejected(A, BundleA, getuid(), @"symlink challenge rejected"); unlink(requestPath.fileSystemRepresentation);
        Check(link(target.fileSystemRepresentation, requestPath.fileSystemRepresentation) == 0, @"hardlink fixture");
        ExpectRejected(A, BundleA, getuid(), @"hardlinked challenge rejected"); unlink(requestPath.fileSystemRepresentation);
        WriteRequest(A, valid);
        NSString *resultDir = [Directory(A) stringByAppendingPathComponent:@"results"];
        chmod(resultDir.fileSystemRepresentation, 0755);
        ExpectRejected(A, BundleA, getuid(), @"results must be private"); chmod(resultDir.fileSystemRepresentation, 0700);
        NSString *parked = [Directory(A) stringByAppendingPathComponent:@"parked"];
        Check(rename(resultDir.fileSystemRepresentation, parked.fileSystemRepresentation) == 0 &&
            symlink(parked.fileSystemRepresentation, resultDir.fileSystemRepresentation) == 0, @"result directory symlink fixture");
        ExpectRejected(A, BundleA, getuid(), @"symlink result directory rejected");
        unlink(resultDir.fileSystemRepresentation); rename(parked.fileSystemRepresentation, resultDir.fileSystemRepresentation);
        NSString *readyPath = [A stringByAppendingPathComponent:@"Library/Preferences/com.redditbox.hook-ready.plist"];
        NSMutableDictionary *wrongReceipt = [[NSDictionary dictionaryWithContentsOfFile:readyPath] mutableCopy];
        wrongReceipt[@"pid"] = @(getpid() + 1); [wrongReceipt writeToFile:readyPath atomically:YES];
        ExpectRejected(A, BundleA, getuid(), @"different process receipt cannot authorize clone probe");
        SetupHome(A, BundleA);
        // Existing final-result symlinks are never followed or replaced.
        Check(symlink(target.fileSystemRepresentation, ResultPath(A, @"seed").fileSystemRepresentation) == 0, @"receipt symlink fixture");
        ExpectRejected(A, BundleA, getuid(), @"existing result cannot be overwritten");
        unlink(ResultPath(A, @"seed").fileSystemRepresentation);
        Check(Run(A, BundleA, getuid()), @"A seed receipt published");
        NSDictionary *seed = ReadResult(A, @"seed");
        Check([seed[@"defaultsSeeded"] isEqual:@YES] && DefaultsItems.count == 1, @"own defaults seed receipt");
        Check([Status(seed, @"keychain-seed-default") isEqual:@"PASS"] &&
            [Status(seed, @"keychain-seed-own-group") isEqual:@"PASS"] &&
            [Status(seed, @"storage-seed") isEqual:@"PASS"], @"actual canary seed behavior");
        Check([seed[@"pid"] isEqual:@(getpid())] && [seed[@"bundleIdentifier"] isEqual:BundleA] &&
            [seed[@"nonce"] isEqual:Nonce], @"receipt binds process, bundle and nonce");
        ExpectRejected(A, BundleA, getuid(), @"same stage does not replay/overwrite");
        WriteRequest(B, Request(@"verify", BundleB));
        Check(Run(B, BundleB, getuid()), @"B verify receipt published");
        NSDictionary *verified = ReadResult(B, @"verify");
        Check(DefaultsItems.count == 1 && [verified[@"defaultsSeeded"] isEqual:@NO], @"verify never seeds sibling or own defaults");
        Check([Status(verified, @"keychain-default-absent") isEqual:@"PASS"] &&
            [Status(verified, @"keychain-foreign-group-denied") isEqual:@"PASS"] &&
            [Status(verified, @"storage-own-absent") isEqual:@"PASS"], @"mock Security default/foreign contexts distinct");
        Check([Status(verified, @"storage-foreign-denied") isEqual:@"FAIL"], @"unsandboxed host CAN read A; never claim physical isolation");
        WriteRequest(A, Request(@"cleanup", BundleA));
        Check(Run(A, BundleA, getuid()), @"cleanup receipt published");
        NSDictionary *cleaned = ReadResult(A, @"cleanup");
        Check([Status(cleaned, @"keychain-before-cleanup") isEqual:@"PASS"] &&
            [Status(cleaned, @"keychain-cleanup") isEqual:@"PASS"] &&
            [Status(cleaned, @"storage-cleanup") isEqual:@"PASS"] && Items.count == 0 && DefaultsItems.count == 0, @"exact keychain, file and defaults canaries cleaned");
        // Missing source must not accidentally become a successful foreign denial.
        unlink(ResultPath(B, @"verify").fileSystemRepresentation);
        Check(Run(B, BundleB, getuid()), @"post-cleanup verification fixture published");
        Check([Status(ReadResult(B, @"verify"), @"storage-foreign-denied") isEqual:@"NOT_RUN"], @"ENOENT never proves denied foreign access");
        // Cleanup must not remove wrong contents, even at the exact test name.
        Nonce = NSUUID.UUID.UUIDString;
        WriteRequest(A, Request(@"cleanup", BundleA));
        NSString *sentinelPath = [resultDir stringByAppendingPathComponent:[Nonce stringByAppendingString:@".sentinel"]];
        NSData *untouched = [@"unrelated fixture bytes" dataUsingEncoding:NSUTF8StringEncoding];
        Check([untouched writeToFile:sentinelPath atomically:NO], @"unrelated sentinel fixture"); chmod(sentinelPath.fileSystemRepresentation, 0600);
        CurrentGroup = [@"RBXCLONE00." stringByAppendingString:BundleA];
        Items[[CurrentGroup stringByAppendingString:Nonce]] = untouched;
        Check(Run(A, BundleA, getuid()), @"mismatched cleanup reports its failure");
        Check([Status(ReadResult(A, @"cleanup"), @"keychain-cleanup") isEqual:@"FAIL"] &&
            [Status(ReadResult(A, @"cleanup"), @"storage-cleanup") isEqual:@"FAIL"] &&
            [[NSData dataWithContentsOfFile:sentinelPath] isEqual:untouched] && Items.count == 1,
            @"wrong canary bytes never deleted");
        [NSFileManager.defaultManager removeItemAtPath:Root error:nil];
        puts("PASS clone acceptance: schema, ownership, bounds, symlinks, stage idempotence, process binding, exact cleanup; mocked Security only");
        puts("NOT RUN actual iOS sandbox/Keychain boundaries; unsandboxed host correctly reports foreign access FAIL");
    }
    return 0;
}
