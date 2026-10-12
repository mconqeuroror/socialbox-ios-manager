#import "../shared/RBXSentinelIO.h"

@interface RBXDefaultsBoundary : NSObject
@property(nonatomic, strong) id value;
@property(nonatomic) BOOL raises;
@property(nonatomic) BOOL cleanupRaises;
@property(nonatomic) NSUInteger added, removed;
@end
@implementation RBXDefaultsBoundary
- (void)addSuiteNamed:(NSString *)suite { (void)suite; self.added++; }
- (id)objectForKey:(NSString *)key {
    (void)key;
    if (self.raises) @throw [NSException exceptionWithName:@"MockDefaultsFailure" reason:nil userInfo:nil];
    return self.value;
}
- (void)removeSuiteNamed:(NSString *)suite {
    (void)suite; self.removed++;
    if (self.cleanupRaises) @throw [NSException exceptionWithName:@"MockDefaultsCleanupFailure" reason:nil userInfo:nil];
}
@end

// Inert public-API receiver: no OS descriptor is allocated by this fixture.
@interface RBXReadHandleBoundary : NSObject
@property(nonatomic) BOOL raises;
@property(nonatomic) NSUInteger closes;
@end
@implementation RBXReadHandleBoundary
- (void)closeFile {
    self.closes++;
    if (self.raises) @throw [NSException exceptionWithName:@"MockHandleCleanupFailure" reason:nil userInfo:nil];
}
@end

static void Check(BOOL condition, NSString *name) {
    if (!condition) { fprintf(stderr,"FAIL: %s\n",name.UTF8String); exit(1); }
}
static NSString *Status(NSArray *rows, NSString *probe) {
    for (NSDictionary *row in rows) if ([row[@"probe"] isEqual:probe]) return row[@"status"];
    return nil;
}
int main(void) { @autoreleasepool {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *bundle = @"com.redditbox.profile.pA", *uuid = NSUUID.UUID.UUIDString;
    NSDictionary *settings = @{@"enabled":@YES,@"intervalMinutes":@15,@"clipboardChallenge":@NO};
    Check([RBXSentinelSettings(nil)[@"enabled"] isEqual:@NO],@"default off");
    Check(!RBXSentinelSettings(@{}),@"missing settings rejected without crashing");
    Check(!RBXSentinelSettings(@{@"enabled":@"yes",@"intervalMinutes":@15,@"clipboardChallenge":@NO}),@"typed booleans");
    for (NSNumber *n in @[@0,@(-1),@1.5,@1441,@(NAN),@YES]) {
        NSMutableDictionary *bad = [settings mutableCopy]; bad[@"intervalMinutes"] = n;
        Check(!RBXSentinelSettings(bad),@"invalid interval rejected");
    }
    __block NSUInteger installs = 0;
    Check(!RBXSentinelRegister(nil,YES,^{ installs++; }),@"off installs no thread");
    Check(!RBXSentinelRegister(settings,NO,^{ installs++; }),@"wait for readiness");
    Check(installs == 0,@"no observer/queue/timer allocated while off");
    Check(RBXSentinelRegister(settings,YES,^{ installs++; }) && installs == 1,@"on installs exactly once per registration");
    RBXDefaultsBoundary *defaultsBoundary = [RBXDefaultsBoundary new];
    defaultsBoundary.value = @"synthetic-only";
    Check([RBXSentinelReadDefaults((NSUserDefaults *)defaultsBoundary,@"suite",@"key") isEqual:@"synthetic-only"] &&
        defaultsBoundary.added == 1 && defaultsBoundary.removed == 1,@"actual defaults wrapper removes its temporary suite");
    defaultsBoundary.raises = YES;
    BOOL defaultsRaised = NO;
    @try { RBXSentinelReadDefaults((NSUserDefaults *)defaultsBoundary,@"suite",@"key"); }
    @catch (__unused NSException *e) { defaultsRaised = YES; }
    Check(defaultsRaised && defaultsBoundary.removed == 2,@"defaults exception remains inconclusive and suite is removed");
    for (NSDictionary *challenge in @[RBXSentinelClipboardChallenge(NO,YES,NO),
        RBXSentinelClipboardChallenge(NO,NO,NO), RBXSentinelClipboardChallenge(YES,YES,YES)])
        Check([challenge[@"status"] isEqual:@"NOT_RUN"],@"unwitnessed, unavailable and shared clipboard challenges never pass");
    Check([RBXSentinelClipboardChallenge(NO,YES,YES)[@"status"] isEqual:@"LEAK"],@"visible blocked challenge still alerts");
    Check([RBXSentinelFileObservation(nil) isEqual:@"unknown"] &&
        [RBXSentinelFileObservation([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:nil]) isEqual:@"denied"] &&
        [RBXSentinelFileObservation([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil]) isEqual:@"absent"],
        @"file missing, access denied and unavailable result remain distinct");

    __block OSStatus security = errSecItemNotFound;
    __block BOOL fileVisible = NO, handleVisible = NO, clipboard = NO, apiException = NO;
    __block BOOL handleRaises = NO, handleCleanupFailure = NO, defaultsCleanupFailure = NO;
    RBXReadHandleBoundary *readHandle = [RBXReadHandleBoundary new];
    Check(!RBXSentinelCloseReadHandle(nil),@"missing read handle does not claim visibility");
    Check(RBXSentinelCloseReadHandle((NSFileHandle *)readHandle) && readHandle.closes == 1,
        @"read-handle helper attempts normal cleanup and preserves successful open");
    RBXDefaultsBoundary *cleanupBoundary = [RBXDefaultsBoundary new];
    __block NSInteger fileError = EACCES;
    __block id defaultsValue = nil;
    __block BOOL defaultsUnavailable = NO;
    __block NSUInteger calls = 0;
    RBXSentinelAPIs api = {
        .keychain = ^OSStatus(NSDictionary *query) {
            calls++;
            Check([query[(__bridge id)kSecAttrService] isEqual:@"com.redditbox.acceptance.canary.v1"],@"same acceptance service");
            Check([query[(__bridge id)kSecUseAuthenticationUI] isEqual:(__bridge id)kSecUseAuthenticationUIFail],@"no keychain prompt");
            Check(!query[(__bridge id)kSecValueData],@"read-only keychain query");
            if (apiException) @throw [NSException exceptionWithName:@"mock" reason:nil userInfo:nil];
            return security;
        },
        .attributes = ^NSDictionary *(NSString *path, NSError **error) {
            Check([path hasPrefix:@"/var/mobile/Containers/Data/Application/"],@"sibling path constructed");
            if (fileVisible) return @{};
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:fileError userInfo:nil]; return nil;
        },
        .openReadOnly = ^BOOL(NSString *path, NSError **error) {
            Check([path hasSuffix:@".sentinel"],@"actual acceptance canary path");
            if (handleRaises) @throw [NSException exceptionWithName:@"MockReadFailure" reason:nil userInfo:nil];
            if (handleCleanupFailure) return RBXSentinelCloseReadHandle((NSFileHandle *)readHandle);
            if (handleVisible) return YES;
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:fileError userInfo:nil]; return NO;
        },
        .defaults = ^id(NSString *suite, NSString *key) {
            Check([suite isEqual:@"com.redditbox.profile.pB"],@"sibling suite");
            if (defaultsUnavailable) return RBXSentinelReadDefaults(nil,suite,key);
            if (defaultsCleanupFailure) return RBXSentinelReadDefaults((NSUserDefaults *)cleanupBoundary,suite,key);
            Check([key hasPrefix:@"RBXAcceptanceCanary."],@"specific seeded key"); return defaultsValue;
        },
        .clipboardHasContent = ^BOOL { return clipboard; }
    };
    NSMutableDictionary *target = [@{@"bundleIdentifier":@"com.redditbox.profile.pB",@"dataUUID":NSUUID.UUID.UUIDString,
        @"nonce":NSUUID.UUID.UUIDString,@"keychainSeeded":@YES,@"defaultsSeeded":@YES,@"witnessAt":@(now),@"expiresAt":@(now+60)} mutableCopy];
    NSArray *rows = RBXSentinelProbe(@[target],NO,now,api);
    Check(rows.count == 5 && !RBXSentinelHasLeak(rows),@"all fixed probes execute");
    Check([Status(rows,@"keychain-default") isEqual:@"NOT_RUN"] &&
        [Status(rows,@"keychain-group") isEqual:@"NOT_RUN"],
        @"not-found cannot prove isolation from a historical Keychain seed receipt");
    Check([Status(rows,@"pasteboard") isEqual:@"NOT_RUN"],
        @"empty clipboard without an independently witnessed marker is inconclusive");
    Check([Status(rows,@"filesystem") isEqual:@"PASS"] && [Status(rows,@"defaults") isEqual:@"PASS"],
        @"fresh filesystem/defaults witnesses support their bounded absent/denied observations");
    security = errSecSuccess;
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"keychain-group") isEqual:@"LEAK"] && [Status(rows,@"keychain-default") isEqual:@"LEAK"],@"any successful Security read leaks");
    security = errSecMissingEntitlement;
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"keychain-group") isEqual:@"PASS"] && [Status(rows,@"keychain-default") isEqual:@"NOT_RUN"],@"explicit foreign group denial distinguished");
    for (NSDictionary *row in rows) if ([row[@"probe"] isEqual:@"keychain-group"])
        Check([row[@"detail"] containsString:@"denied"],@"entitlement rejection described as denial");
    security = errSecInteractionNotAllowed;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"keychain-group") isEqual:@"NOT_RUN"],@"locked Security is inconclusive");
    security = errSecItemNotFound; fileVisible = YES;
    Check(RBXSentinelHasLeak(RBXSentinelProbe(@[target],NO,now,api)),@"stat visibility alone alerts");
    handleRaises = YES;
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"filesystem") isEqual:@"LEAK"] && RBXSentinelHasLeak(rows),
        @"later filesystem exception cannot erase already observed foreign metadata");
    fileVisible = NO;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"filesystem") isEqual:@"NOT_RUN"],
        @"filesystem exception without a positive observation remains inconclusive");
    handleRaises = NO;
    handleCleanupFailure = YES; readHandle.raises = YES;
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"filesystem") isEqual:@"LEAK"] && RBXSentinelHasLeak(rows) && readHandle.closes == 2,
        @"opened foreign handle remains LEAK when closeFile throws and cleanup was attempted");
    handleCleanupFailure = NO;
    fileVisible = NO; handleVisible = YES;
    Check(RBXSentinelHasLeak(RBXSentinelProbe(@[target],NO,now,api)),@"read handle alone alerts");
    handleVisible = NO; fileError = EIO;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"filesystem") isEqual:@"NOT_RUN"],@"IO error not PASS");
    fileError = ENOENT;
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"filesystem") isEqual:@"PASS"],@"known witnessed path hidden as ENOENT");
    for (NSDictionary *row in rows) if ([row[@"probe"] isEqual:@"filesystem"])
        Check([row[@"detail"] containsString:@"absent"],@"ENOENT described as absence rather than denial");
    defaultsValue = @"unexpected-content";
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"defaults") isEqual:@"LEAK"],@"any foreign key value alerts");
    defaultsCleanupFailure = YES; cleanupBoundary.cleanupRaises = YES;
    cleanupBoundary.value = @"already-read-canary";
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"defaults") isEqual:@"LEAK"] && RBXSentinelHasLeak(rows) && cleanupBoundary.removed == 1,
        @"post-read defaults cleanup exception preserves the foreign value and still attempts cleanup");
    cleanupBoundary.value = nil;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"defaults") isEqual:@"NOT_RUN"] && cleanupBoundary.removed == 2,
        @"absent defaults value plus cleanup failure must not report PASS");
    cleanupBoundary.raises = YES; cleanupBoundary.value = @"unread-canary";
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"defaults") isEqual:@"NOT_RUN"] && cleanupBoundary.removed == 3,
        @"query and cleanup failures without a returned value remain inconclusive");
    defaultsCleanupFailure = NO;
    defaultsUnavailable = YES;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"defaults") isEqual:@"NOT_RUN"],@"nil defaults receiver must not report absent-key PASS");
    defaultsUnavailable = NO;
    defaultsValue = nil; clipboard = YES;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"pasteboard") isEqual:@"LEAK"],@"blocked clipboard content alerts");
    Check([Status(RBXSentinelProbe(@[target],YES,now,api),@"pasteboard") isEqual:@"NOT_RUN"],@"compatibility is not isolation");
    clipboard = NO; apiException = YES;
    Check([Status(RBXSentinelProbe(@[target],NO,now,api),@"keychain-default") isEqual:@"NOT_RUN"],@"exception is inconclusive");
    apiException = NO;
    target[@"witnessAt"] = @(now-61);
    rows = RBXSentinelProbe(@[target],NO,now,api);
    Check([Status(rows,@"filesystem") isEqual:@"NOT_RUN"] && [Status(rows,@"defaults") isEqual:@"NOT_RUN"],@"expired witnesses never pass");
    target[@"witnessAt"] = @(now);
    Check([Status(RBXSentinelProbe(@[],NO,now,api),@"keychain-group") isEqual:@"NOT_RUN"],@"zero siblings never all clear");

    NSMutableDictionary *control = [@{@"schemaVersion":@1,@"bundleIdentifier":bundle,@"dataUUID":uuid,@"revision":NSUUID.UUID.UUIDString,
        @"settings":settings,@"issuedAt":@(now),@"targets":@[target]} mutableCopy];
    Check(RBXSentinelControlValid(control,bundle,uuid,now),@"valid scoped control");
    Check(!RBXSentinelControlValid(control,@"wrong",uuid,now),@"wrong clone rejected");
    target[@"dataUUID"] = uuid;
    Check(!RBXSentinelControlValid(control,bundle,uuid,now),@"self target rejected");
    target[@"dataUUID"] = @"../sibling";
    Check(!RBXSentinelControlValid(control,bundle,uuid,now),@"path traversal rejected");
    target[@"dataUUID"] = NSUUID.UUID.UUIDString;
    NSDictionary *ready = @{@"allHooksInstalled":@YES,@"containerId":@"a",@"bundleIdentifier":bundle,
        @"generation":@"generation",@"bootEpoch":@"epoch",@"pid":@42,@"timestamp":@(now-1)};
    Check(RBXSentinelReady(ready,bundle,42) && !RBXSentinelReady(ready,bundle,43),@"current process readiness");
    NSMutableDictionary *report = [ready mutableCopy];
    [report addEntriesFromDictionary:@{@"schemaVersion":@1,@"timestamp":@(now),@"revision":control[@"revision"],
        @"rows":RBXSentinelProbe(@[target],NO,now,api)}];
    Check(RBXSentinelReportValid(report,control,ready,now),@"complete receipt accepted");
    NSArray *honestRows = report[@"rows"];
    NSMutableArray *mixedOldRows = [NSMutableArray array];
    for (NSDictionary *row in honestRows) {
        NSMutableDictionary *copy = row.mutableCopy;
        if ([row[@"probe"] isEqual:@"filesystem"]) copy[@"status"] = @"LEAK";
        if ([row[@"probe"] isEqual:@"keychain-default"] || [row[@"probe"] isEqual:@"pasteboard"])
            copy[@"status"] = @"PASS";
        [mixedOldRows addObject:copy];
    }
    report[@"rows"] = mixedOldRows;
    Check(RBXSentinelReportValid(report,control,ready,now),
        @"structurally valid old report with LEAK must survive weak PASS classification for normalization");
    NSArray *mixedNormalized = RBXSentinelNormalizedRows(report[@"rows"]);
    Check(RBXSentinelHasLeak(mixedNormalized) &&
        [Status(mixedNormalized,@"filesystem") isEqual:@"LEAK"] &&
        [Status(mixedNormalized,@"keychain-default") isEqual:@"NOT_RUN"] &&
        [Status(mixedNormalized,@"pasteboard") isEqual:@"NOT_RUN"],
        @"actual summary normalization retains LEAK and removes weak PASS claims");
    Check([Status(mixedOldRows,@"pasteboard") isEqual:@"PASS"],@"normalization does not mutate receipt evidence");
    NSDictionary *explicitDenial = RBXSentinelRow(@"keychain-group",@"sibling-1",@"PASS",@"explicit denial",errSecMissingEntitlement);
    Check([Status(RBXSentinelNormalizedRows(@[explicitDenial]),@"keychain-group") isEqual:@"PASS"],
        @"normalization retains bounded explicit-group denial");
    report[@"rows"] = honestRows;
    NSMutableArray *duplicateRows = honestRows.mutableCopy; [duplicateRows addObject:honestRows[0]];
    report[@"rows"] = duplicateRows;
    Check(!RBXSentinelReportValid(report,control,ready,now),@"duplicate report rows rejected before normalization");
    for (NSDictionary *mutation in @[@{@"target":@"foreign"}, @{@"status":@"UNKNOWN"}, @{@"code":@"0"}]) {
        NSMutableArray *badRows = honestRows.mutableCopy;
        NSMutableDictionary *badRow = [badRows[0] mutableCopy]; [badRow addEntriesFromDictionary:mutation]; badRows[0] = badRow;
        report[@"rows"] = badRows;
        Check(!RBXSentinelReportValid(report,control,ready,now),@"foreign or malformed row rejected before normalization");
    }
    report[@"rows"] = honestRows;
    for (NSString *probe in @[@"keychain-default", @"keychain-group", @"pasteboard"]) {
        NSMutableArray *fabricated = [NSMutableArray array];
        for (NSDictionary *row in honestRows) {
            NSMutableDictionary *copy = row.mutableCopy;
            if ([row[@"probe"] isEqual:probe]) copy[@"status"] = @"PASS";
            [fabricated addObject:copy];
        }
        report[@"rows"] = fabricated;
        Check(RBXSentinelReportValid(report,control,ready,now) &&
            [Status(RBXSentinelNormalizedRows(report[@"rows"]),probe) isEqual:@"NOT_RUN"],
            @"structural receipt validation and unsupported PASS downgrade are separate");
    }
    report[@"rows"] = honestRows;
    NSMutableDictionary *challengeControl = control.mutableCopy;
    NSMutableDictionary *challengeSettings = settings.mutableCopy;
    challengeSettings[@"clipboardChallenge"] = @YES;
    challengeControl[@"settings"] = challengeSettings;
    NSMutableArray *challengeRows = [honestRows mutableCopy];
    NSMutableDictionary *challenge = [RBXSentinelClipboardChallenge(NO,YES,NO) mutableCopy];
    [challengeRows addObject:challenge]; report[@"rows"] = challengeRows;
    Check(RBXSentinelReportValid(report,challengeControl,ready,now),@"honest inconclusive challenge receipt accepted");
    challenge[@"status"] = @"PASS";
    Check(RBXSentinelReportValid(report,challengeControl,ready,now) &&
        [Status(RBXSentinelNormalizedRows(report[@"rows"]),@"pasteboard-challenge") isEqual:@"NOT_RUN"],
        @"old own-marker challenge PASS receipt is downgraded");
    report[@"rows"] = honestRows;
    report[@"rows"] = @[];
    Check(!RBXSentinelReportValid(report,control,ready,now),@"empty receipt never all clear");
    report[@"rows"] = RBXSentinelProbe(@[target],NO,now,api);
    report[@"generation"] = @"stale";
    Check(!RBXSentinelReportValid(report,control,ready,now),@"replay from another generation rejected");
    Check(!RBXSentinelControlValid(control,bundle,uuid,now+61),@"stale daemon witness rejected");
    printf("Isolation sentinel: settings, registration, API probes, exceptions, stale/self/replay and missing-evidence cases PASS (%lu Security mock calls).\n",(unsigned long)calls);
    return 0;
} }
