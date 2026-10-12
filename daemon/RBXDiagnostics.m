#import "RBXInstallPaths.h"
#import "RBXCloneEpoch.h"
#import "RBXLiveness.h"
#import "RBXHookReadiness.h"
#import "RBXProc.h"
#import "RBXDiagnostics.h"
#import "RBXContainerRegistry.h"
#import "RBXCloneManager.h"
#import "RBXOperationContext.h"
#import "RBXBoundedProcess.h"
#import "RBXCentralStore.h"
#import "RBXSecureConfig.h"
#import "RBXLicenseGuard.h"
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

static NSString *const RBXLeasePath =
    @"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist";
static NSString *const RBXFirewallPath =
    @"/var/mobile/Library/Preferences/com.redditbox.firewall-status.plist";
static NSString *const RBXSupportLogPath =
    @"/var/mobile/Library/Preferences/com.redditbox.support-log.txt";

static NSDictionary *RBXCheck(NSString *identifier, NSString *title,
                              NSString *status, NSString *detail) {
    return @{
        @"id": identifier ?: @"",
        @"title": title ?: @"",
        @"status": status ?: @"fail",
        @"detail": detail ?: @"",
    };
}

static void RBXStoreDeviceValue(NSString *key, NSDictionary *value) {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    if (!context || ![context check:nil]) return;
    [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *document) {
        if (![context check:nil]) return;
        NSMutableDictionary *device = [document[@"device"] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        device[key] = value ?: @{};
        document[@"device"] = device;
    }];
}

@implementation RBXDiagnostics

+ (NSDictionary *)runWithRegistry:(RBXContainerRegistry *)registry {
    return [self _performInspection:^{ return [self _runWithRegistry:registry]; }];
}
+ (NSDictionary *)exportSupportLog {
    return [self _performInspection:^{ return [self _exportSupportLog]; }];
}
+ (NSDictionary *)_performInspection:(NSDictionary *(^)(void))block {
    RBXOperationContext *context = RBXOperationContext.currentContext;
    NSError *error = nil;
    if (!context || ![context beginWork:&error])
        return @{@"ok": @NO, @"message": error.localizedDescription ?: @"A bounded inspection context is required"};
    __block NSDictionary *result = nil;
    @try {
        [context performBlock:^{ if ([context check:nil]) result = block(); }];
        if (![context check:&error]) result = nil;
    } @finally { [context endWork]; }
    return result ?: @{@"ok": @NO, @"message": error.localizedDescription ?: @"Inspection did not complete"};
}


+ (NSDictionary *)_runWithRegistry:(RBXContainerRegistry *)registry {
    NSMutableArray *checks = [NSMutableArray array];
    [checks addObject:RBXCheck(@"daemon", @"RedditBox daemon", @"pass",
        @"The daemon generated this report.")];

    NSDictionary *configuration = [RBXSecureConfig safeSummary];
    struct stat fallbackInfo = {};
    NSString *fallbackPath =
        @"/var/mobile/Library/Preferences/com.redditbox.rotation.plist";
    BOOL fallbackConfigured =
        ![configuration[@"disabled"] boolValue] && stat(fallbackPath.fileSystemRepresentation, &fallbackInfo) == 0 &&
        fallbackInfo.st_uid == 0 && (fallbackInfo.st_mode & 0022) == 0;
    BOOL configurationReady =
        ([configuration[@"configured"] boolValue] &&
         [configuration[@"readable"] boolValue]) || fallbackConfigured;
    [checks addObject:RBXCheck(@"configuration", @"Saved proxy",
        configurationReady ? @"pass" : @"fail",
        [configuration[@"configured"] boolValue]
            ? [NSString stringWithFormat:@"Secure %@ configuration; proxy %@; rotation %@",
                configuration[@"source"] ?: @"launcher",
                configuration[@"proxyHost"] ?: @"",
                configuration[@"rotationHost"] ?: @""]
            : (fallbackConfigured ? @"Using optional root-only plist fallback" :
                (configuration[@"error"] ?: @"Not configured")))];
    NSDictionary *license = RBXLicenseGuard.sharedGuard.safeStatus;
    [checks addObject:RBXCheck(@"package-variant", @"Jailbreak package", @"info",
        [NSString stringWithFormat:@"%@ package; installed tools: %@", RBXInstalledScheme(), RBXInstalledPath(@"/usr/bin")])];
    [checks addObject:RBXCheck(@"license", @"Device license",
        [license[@"unlocked"] boolValue] ? @"pass" : @"fail", license[@"reason"] ?: @"Open the license activation screen")];
    NSError *storeError = nil;
    NSDictionary *store = [RBXCentralStore.sharedStore dictionaryWithError:&storeError];
    NSDictionary *update = [store[@"device"][@"lastAppliedUpdate"] isKindOfClass:NSDictionary.class]
        ? store[@"device"][@"lastAppliedUpdate"] : @{};
    NSDictionary *startup = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist"][@"startupRecovery"];
    [checks addObject:RBXCheck(@"data-schema", @"Data schema and startup",
        !store || (startup.count && ![startup[@"ok"] boolValue]) ? @"fail" : @"pass",
        storeError.localizedDescription ?: startup[@"message"] ?: @"Awaiting startup recovery result")];
    [checks addObject:RBXCheck(@"update-applied", @"Installed update",
        update.count ? @"info" : @"fail", update[@"message"] ?: @"No completed update application has been recorded")];
    if ([update[@"requiresMDMReadoption"] boolValue])
        [checks addObject:RBXCheck(@"update-mdm", @"Clone VPN association", @"info",
            @"This release requires MDM re-adoption. Confirm every clone's per-app VPN association before use.")];
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableArray *missingTools = [NSMutableArray array];
    for (NSString *tool in @[@"ldid", @"appinst", @"zip"]) {
        BOOL found = [files isExecutableFileAtPath:
            RBXInstalledPath([@"/usr/bin" stringByAppendingPathComponent:tool])] ||
            [files isExecutableFileAtPath:
                [@"/usr/bin" stringByAppendingPathComponent:tool]];
        if (!found) [missingTools addObject:tool];
    }
    [checks addObject:RBXCheck(@"clone-tools", @"Clone installation tools",
        missingTools.count ? @"fail" : @"pass",
        missingTools.count ? [NSString stringWithFormat:@"Missing: %@",
            [missingTools componentsJoinedByString:@", "]]
            : @"ldid, appinst and zip are installed")];

    NSDictionary *source = [[RBXCloneManager new] sourceStatus];
    [checks addObject:RBXCheck(@"source", @"Decrypted Reddit source",
        [source[@"decrypted"] boolValue] ? @"pass" : @"fail",
        source[@"message"] ?: @"Source status unavailable")];

    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXLeasePath] ?: @{};
    NSDictionary *firewall =
        [NSDictionary dictionaryWithContentsOfFile:RBXFirewallPath] ?: @{};
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL localClosed = [lease[@"state"] isEqual:@"closed"];
    BOOL deferred = localClosed && ![firewall[@"enforced"] boolValue];
    BOOL heartbeatFresh = RBXHeartbeatFresh(lease[@"heartbeatAt"], now) &&
        RBXHeartbeatFresh(firewall[@"heartbeatAt"], now) &&
        [lease[@"bootEpoch"] isEqual:firewall[@"bootEpoch"]];
    [checks addObject:RBXCheck(@"heartbeat", @"Daemon/firewall heartbeat",
        heartbeatFresh ? @"pass" : (deferred ? @"info" : @"fail"),
        heartbeatFresh ? @"Both safety heartbeats are current" :
            (deferred ? @"VPN setup deferred; local traffic is CLOSED. Start Firewall Setup in Settings when ready." :
                @"Daemon or app-proxy status is stale"))];
    BOOL stateMatch = heartbeatFresh;
    for (NSString *key in @[@"state", @"generation", @"bootEpoch", @"containerId", @"bundleIdentifier"])
        stateMatch = stateMatch && [lease[key] isEqual:firewall[key]];
    [checks addObject:RBXCheck(@"lease", @"Lease and firewall agreement",
        stateMatch ? @"pass" : (deferred ? @"info" : @"fail"), stateMatch
            ? [NSString stringWithFormat:@"Both report %@", lease[@"state"] ?: @"unknown"]
            : (deferred ? @"Local CLOSED; provider agreement is deferred until VPN setup" : @"State or generation mismatch"))];
    [checks addObject:RBXCheck(@"firewall", @"System app proxy",
        (heartbeatFresh && stateMatch && [firewall[@"enforced"] boolValue] &&
            [firewall[@"policyAppliedAt"] doubleValue] > 0) ? @"pass" : (deferred ? @"info" : @"fail"),
        [NSString stringWithFormat:@"State %@; scope %@",
            firewall[@"state"] ?: @"missing", firewall[@"scope"] ?: @"missing"])];
    [checks addObject:RBXCheck(@"vpn-scope", @"Managed per-app VPN",
        heartbeatFresh && [firewall[@"scope"] isEqualToString:@"per-app"] ? @"pass" : (deferred ? @"info" : @"fail"),
        [firewall[@"scope"] isEqualToString:@"per-app"]
            ? @"Provider reports per-app scope; actual clone-to-VPN assignment needs device verification" : @"MDM per-app scope is not active")];

    NSArray *containerIds = registry.containerIds;
    NSMutableSet *bundleIds = [NSMutableSet set];
    NSMutableSet *dataContainers = [NSMutableSet set];
    NSMutableSet *keychainGroups = [NSMutableSet set];
    NSUInteger validClones = 0;
    NSUInteger managedClones = 0;
    for (NSString *containerId in containerIds) {
        if (![RBXOperationContext.currentContext check:nil]) return @{@"ok": @NO, @"message": @"Diagnostics deadline expired"};
        NSError *error = nil;
        NSDictionary *profile = [registry validatedProfileForContainer:containerId error:&error];
        if (!profile) {
            [checks addObject:RBXCheck([@"profile-" stringByAppendingString:containerId],
                [NSString stringWithFormat:@"%@ profile", containerId], @"fail",
                error.localizedDescription ?: @"Profile invalid")];
            continue;
        }
        RBXCloneManager *clones = [RBXCloneManager new];
        BOOL valid = [clones validateCloneForProfile:profile error:&error];
        NSString *bundleId = profile[@"app"][@"bundleIdentifier"];
        NSString *keychain = profile[@"app"][@"keychainAccessGroup"];
        NSString *dataContainer = bundleId.length
            ? [clones dataContainerForBundleIdentifier:bundleId] : nil;
        if (!bundleId.length || [bundleIds containsObject:bundleId] ||
            !keychain.length || [keychainGroups containsObject:keychain] ||
            !dataContainer.length || [dataContainers containsObject:dataContainer]) {
            valid = NO;
            error = [NSError errorWithDomain:@"com.redditbox.diagnostics" code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    @"Clone identity or OS data container is not unique"}];
        }
        if (bundleId.length) [bundleIds addObject:bundleId];
        if (keychain.length) [keychainGroups addObject:keychain];
        if (dataContainer.length) [dataContainers addObject:dataContainer];
        if (valid) validClones++;
        BOOL managed = valid &&
            [clones verifyManagedInstallationForProfile:profile error:&error];
        if (managed) managedClones++;
        [checks addObject:RBXCheck([@"clone-" stringByAppendingString:containerId],
            [NSString stringWithFormat:@"%@ clone", containerId],
            valid && managed ? @"pass" : @"fail",
            valid ? (managed
                ? @"Hidden, isolated, signed and MDM-managed"
                : @"Clone is isolated but not MDM-managed")
                : (error.localizedDescription ?: @"Clone validation failed"))];
    }
    [checks addObject:RBXCheck(@"clones", @"Clone isolation summary",
        !containerIds.count ? @"info" :
            (containerIds.count == validClones && validClones == managedClones ? @"pass" : @"fail"),
        [NSString stringWithFormat:@"%lu profiles; %lu valid; %lu MDM-managed",
            (unsigned long)containerIds.count, (unsigned long)validClones,
            (unsigned long)managedClones])];

    NSString *active = lease[@"containerId"];
    if (active.length &&
        ([lease[@"state"] isEqualToString:@"armed"] ||
         [lease[@"state"] isEqualToString:@"open"])) {
        NSError *error = nil;
        NSDictionary *profile = [registry validatedProfileForContainer:active error:&error];
        NSString *dataContainer = profile
            ? [[RBXCloneManager new] dataContainerForBundleIdentifier:
                profile[@"app"][@"bundleIdentifier"]] : nil;
        NSDictionary *ready = dataContainer.length
            ? [NSDictionary dictionaryWithContentsOfFile:[dataContainer
                stringByAppendingPathComponent:
                    @"Library/Preferences/com.redditbox.hook-ready.plist"]] : nil;
        pid_t pid = [ready[@"pid"] intValue];
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        NSString *bundlePath = profile[@"app"][@"bundlePath"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        NSString *executable = [bundlePath stringByAppendingPathComponent:info[@"CFBundleExecutable"] ?: @""];
        BOOL readyMatches = pid > 1 && proc_pidpath(pid, path, sizeof(path)) > 0 &&
            [[NSString stringWithUTF8String:path] isEqual:executable] &&
            [ready[@"containerId"] isEqualToString:active] &&
            [ready[@"bundleIdentifier"] isEqual:lease[@"bundleIdentifier"]] &&
            [ready[@"generation"] isEqualToString:lease[@"generation"]] &&
            [ready[@"bootEpoch"] isEqual:RBXEpochForClone(lease[@"bootEpoch"], lease[@"bundleIdentifier"])] &&
            RBXHookReceiptTimeMatchesLease(ready, lease, NSDate.date.timeIntervalSince1970) &&
            [ready[@"allHooksInstalled"] isEqual:@YES] && [ready[@"evidenceVersion"] isEqual:@1] &&
            RBXRequiredChecksPassed(ready[@"installedGroups"], RBXRequiredHookGroups()) &&
            RBXRequiredChecksPassed(ready[@"behaviorChecks"], RBXRequiredBehaviorChecks());
        [checks addObject:RBXCheck(@"hooks", @"Active clone hooks",
            readyMatches ? @"pass" : @"fail",
            readyMatches ? @"Hook readiness matches the active lease" :
                @"Active clone has no matching hook-readiness report")];
    } else {
        [checks addObject:RBXCheck(@"hooks", @"Active clone hooks", @"info",
            @"No container is active; test again while Reddit is open")];
    }

    [checks addObject:RBXCheck(@"routing-proof", @"Managed routing verification", @"info",
        @"Managed-app status and configured bundle lists do not prove the OS VPNUUID assignment. Verify clone traffic and disconnect behavior on device; browser authentication remains blocked without coverage.")];
    NSDictionary *fence = RBXOperationContext.safetyFenceStatus;
    [checks addObject:RBXCheck(@"operation-recovery", @"Operation recovery",
        fence ? @"fail" : @"pass", fence[@"message"] ?: @"No unfinished operation safety fence")];
    NSUInteger failures = 0;
    for (NSDictionary *check in checks) {
        if ([check[@"status"] isEqualToString:@"fail"]) failures++;
    }
    NSDictionary *report = @{
        @"generatedAt": @(NSDate.date.timeIntervalSince1970),
        @"ok": @(failures == 0),
        @"failureCount": @(failures),
        @"routingVerified": @NO,
        @"message": failures ? @"Checks found failures; inspect each result" : @"Static/runtime checks completed; managed routing and isolation still require device tests",
        @"checks": checks,
    };
    RBXStoreDeviceValue(@"launcherDiagnostics", report);
    return report;
}

+ (NSDictionary *)_exportSupportLog {
    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"redditbox-support-%@.txt", NSUUID.UUID.UUIDString]];
    RBXOperationContext *context = RBXOperationContext.currentContext;
    NSError *error = nil;
    NSString *predicate = @"process == \"redditboxd\" OR eventMessage CONTAINS \"RBX_SELF_REPORT\" OR eventMessage CONTAINS \"RBX_SENTINEL\" OR eventMessage CONTAINS \"RedditBox\"";
    NSString *logTool = RBXInstalledPath(@"/usr/bin/log");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:logTool]) logTool = @"/usr/bin/log";
    BOOL logAvailable = [NSFileManager.defaultManager isExecutableFileAtPath:logTool];
    if (!logAvailable) error = [NSError errorWithDomain:NSPOSIXErrorDomain code:ENOENT
        userInfo:@{NSLocalizedDescriptionKey:
            @"Unified log export is unavailable: this jailbreak has no executable log tool. Collect device logs over USB from a Mac."}];
    BOOL collected = logAvailable && [RBXBoundedProcess runExecutable:logTool
        arguments:@[@"show", @"--info", @"--last", @"30m", @"--style", @"compact", @"--predicate", predicate]
        context:context outputPath:temporary maximumOutputBytes:2 * 1024 * 1024 error:&error];
    NSData *data = collected && [context check:&error] ? [NSData dataWithContentsOfFile:temporary] : nil;
    if (collected || [error.userInfo[@"childQuiescent"] boolValue])
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    NSString *text = data.length
        ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    if (text.length > 2 * 1024 * 1024) {
        text = [text substringFromIndex:text.length - 2 * 1024 * 1024];
    }
    NSArray *patterns = @[
        @"://[^/@\\s]+:[^/@\\s]+@",
        @"(?i)Bearer\\s+[A-Za-z0-9._~+/-]+",
        @"(?i)(authorization|token|password)=?\\s*[^\\s,;]+",
    ];
    for (NSString *pattern in patterns) {
        NSRegularExpression *regex = [NSRegularExpression
            regularExpressionWithPattern:pattern options:0 error:nil];
        text = [regex stringByReplacingMatchesInString:text options:0
            range:NSMakeRange(0, text.length) withTemplate:@"<redacted>"];
    }
    BOOL wrote = collected && [context check:&error] &&
        [text writeToFile:RBXSupportLogPath atomically:YES
                  encoding:NSUTF8StringEncoding error:nil];
    if (wrote) {
        chmod(RBXSupportLogPath.fileSystemRepresentation, 0600);
        chown(RBXSupportLogPath.fileSystemRepresentation, 501, 501);
    }
    NSDictionary *result = @{
        @"ok": @(wrote),
        @"generatedAt": @(NSDate.date.timeIntervalSince1970),
        @"path": wrote ? RBXSupportLogPath : @"",
        @"message": wrote ? @"Support log ready to share" :
            (error.localizedDescription ?: @"Could not collect unified logs"),
    };
    RBXStoreDeviceValue(@"launcherSupportLog", result);
    return result;
}

@end
