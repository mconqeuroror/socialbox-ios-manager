#import "RBXSentinelController.h"
#import "RBXSentinelIO.h"
#import "RBXCloneManager.h"
#import "RBXProfileIO.h"
#import "RBXCentralStore.h"
#import "RBXProc.h"
#import "RBXHookReadiness.h"
#import "RBXCloneEpoch.h"
#import "RBXProcessIdentity.h"
#import "RBXOperationContext.h"

static NSDictionary *(^RBXSentinelIdentityProvider)(void);

static BOOL RBXSentinelInteger(id value, double minimum, double maximum) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number >= minimum && number <= maximum && floor(number) == number;
}

// Readiness/report contents come from the clone. Bind them to the launch held
// by the daemon and freshly observed kernel birth, not just a reusable PID.
static BOOL RBXSentinelProcessBound(NSDictionary *identity, NSDictionary *profile,
    NSDictionary *lease, NSDictionary *ready, NSTimeInterval now) {
    if (![identity isKindOfClass:NSDictionary.class]) return NO;
    NSString *container = profile[@"containerId"], *bundle = profile[@"app"][@"bundleIdentifier"];
    for (NSString *key in @[@"containerId",@"bundleIdentifier",@"generation",@"bootEpoch",@"executable"])
        if (![identity[key] isKindOfClass:NSString.class] || ![identity[key] length]) return NO;
    if (![identity[@"containerId"] isEqual:container] || ![identity[@"bundleIdentifier"] isEqual:bundle] ||
        ![ready[@"containerId"] isEqual:container] ||
        ![lease[@"containerId"] isEqual:container] || ![lease[@"bundleIdentifier"] isEqual:bundle] ||
        ![identity[@"generation"] isEqual:lease[@"generation"]] ||
        ![identity[@"bootEpoch"] isEqual:lease[@"bootEpoch"]] ||
        ![ready[@"generation"] isEqual:identity[@"generation"]] ||
        ![ready[@"bootEpoch"] isEqual:RBXEpochForClone(identity[@"bootEpoch"],bundle)] ||
        !RBXSentinelInteger(identity[@"pid"],2,INT_MAX) ||
        !RBXSentinelInteger(identity[@"processStartSeconds"],1,now) ||
        !RBXSentinelInteger(identity[@"processStartMicroseconds"],0,999999) ||
        !RBXSentinelReady(ready,bundle,[identity[@"pid"] intValue]) ||
        !RBXHookReceiptTimeMatchesLease(ready,lease,now)) return NO;
    double birth = [identity[@"processStartSeconds"] doubleValue] +
        [identity[@"processStartMicroseconds"] doubleValue]/1e6;
    if ([ready[@"timestamp"] doubleValue] < birth) return NO;
    NSString *bundlePath = profile[@"app"][@"bundlePath"];
    if (![bundlePath isKindOfClass:NSString.class] || !bundlePath.isAbsolutePath) return NO;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *name = info[@"CFBundleExecutable"];
    if (![name isKindOfClass:NSString.class] || !name.length || ![name isEqual:name.lastPathComponent] ||
        [@[@".",@".."] containsObject:name]) return NO;
    NSString *executable = [[bundlePath stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
    if (![identity[@"executable"] isEqual:executable]) return NO;
    RBXObservedProcess process;
    return RBXObserveProcess([identity[@"pid"] intValue],&process) == RBXProcessObserved &&
        process.pid == [identity[@"pid"] intValue] &&
        process.startSeconds == [identity[@"processStartSeconds"] longLongValue] &&
        process.startMicroseconds == [identity[@"processStartMicroseconds"] intValue] &&
        [[[NSString stringWithUTF8String:process.executable] stringByResolvingSymlinksInPath] isEqual:executable];
}

static NSDictionary *RBXSentinelTarget(NSDictionary *profile, RBXCloneManager *manager, NSTimeInterval now) {
    NSString *bundle = profile[@"app"][@"bundleIdentifier"];
    if (!RBXAcceptanceBundle(bundle)) return nil;
    NSString *home = [manager dataContainerForBundleIdentifier:bundle];
    if (!RBXAcceptanceUUID(home.lastPathComponent)) return nil;
    int root = open(home.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (root < 0) return nil;
    int acceptance = RBXAcceptanceDescend(root,@[@"Library",@"Application Support",@"RedditBox",@"acceptance"]);
    close(root);
    NSString *nonce = @"";
    BOOL keychain = NO, defaults = NO;
    NSTimeInterval expires = now+60;
    if (acceptance >= 0 && RBXAcceptanceDirectoryOwner(acceptance,0,0022)) {
        NSData *bytes = RBXAcceptanceRead(acceptance,@"request.json",0,4096);
        NSDictionary *request = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        if (RBXAcceptanceRequest(request,bundle,home.lastPathComponent,now) && [request[@"operation"] isEqual:@"seed"]) {
            NSString *candidate = request[@"nonce"];
            int results = RBXAcceptanceDescend(acceptance,@[@"results"]);
            if (results >= 0 && RBXAcceptanceDirectoryOwner(results,501,0077)) {
                NSData *raw = RBXAcceptanceRead(results,[candidate stringByAppendingString:@"-seed.json"],501,16384);
                id receipt = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
                NSData *marker = RBXAcceptanceRead(results,[candidate stringByAppendingString:@".sentinel"],501,128);
                BOOL valid = [receipt isKindOfClass:NSDictionary.class] && [receipt[@"nonce"] isEqual:candidate] &&
                    [receipt[@"operation"] isEqual:@"seed"] && [receipt[@"bundleIdentifier"] isEqual:bundle] &&
                    [receipt[@"uid"] isEqual:@501] && RBXSentinelFresh(receipt[@"timestamp"],now,3600) &&
                    [receipt[@"checks"] isKindOfClass:NSArray.class] &&
                    [marker isEqual:[candidate dataUsingEncoding:NSUTF8StringEncoding]];
                NSSet *required = [NSSet setWithArray:@[@"keychain-seed-default",@"keychain-seed-own-group",@"storage-seed"]];
                NSMutableSet *passed = [NSMutableSet set];
                if (valid) for (id row in receipt[@"checks"])
                    if ([row isKindOfClass:NSDictionary.class] && [required containsObject:row[@"id"]] &&
                        [row[@"status"] isEqual:@"PASS"] && [row[@"statusCode"] isEqual:@0]) [passed addObject:row[@"id"]];
                if (valid && [passed isEqual:required]) {
                    nonce = candidate; keychain = YES; expires = [request[@"expiresAt"] doubleValue];
                    int prefs = RBXSentinelPrefs(home);
                    NSDictionary *domain = RBXSentinelRead(prefs,[bundle stringByAppendingString:@".plist"],501);
                    defaults = [receipt[@"defaultsSeeded"] isEqual:@YES] &&
                        [domain[[@"RBXAcceptanceCanary." stringByAppendingString:nonce]] isEqual:nonce];
                    if (prefs >= 0) close(prefs);
                }
            }
            if (results >= 0) close(results);
        }
    }
    if (acceptance >= 0) close(acceptance);
    return @{@"bundleIdentifier":bundle,@"dataUUID":home.lastPathComponent,@"nonce":nonce,
        @"keychainSeeded":@(keychain),@"defaultsSeeded":@(defaults),@"witnessAt":@(now),@"expiresAt":@(expires)};
}

@implementation RBXSentinelController
+ (void)setProcessIdentityProvider:(NSDictionary *(^)(void))provider {
    @synchronized (self) { RBXSentinelIdentityProvider = [provider copy]; }
}
+ (NSDictionary *)_currentProcessIdentity {
    NSDictionary *(^provider)(void);
    @synchronized (self) { provider = RBXSentinelIdentityProvider; }
    return provider ? [provider() copy] : nil;
}
+ (NSDictionary *)summaryForProfile:(NSDictionary *)profile siblings:(NSArray *)identifiers
                             store:(NSDictionary *)store lease:(NSDictionary *)lease {
    NSString *container = profile[@"containerId"], *bundle = profile[@"app"][@"bundleIdentifier"];
    NSDictionary *settings = RBXSentinelSettings(store[@"containers"][container][@"isolationSentinel"]) ?: RBXSentinelSettings(nil);
    BOOL enabled = [settings[@"enabled"] isEqual:@YES];
    NSDictionary *stored = store[@"containers"][container];
    BOOL alert = [stored[@"sentinelAlert"] isEqual:@YES] || [RBXCentralStore.sharedStore hasAlertType:@"ISOLATION SENTINEL" containerId:container];
    NSMutableDictionary *summary = [@{@"settings":settings,@"enabled":@(enabled),@"alert":@(alert),@"timestamp":[stored[@"sentinelLastRunAt"] isKindOfClass:NSNumber.class] ? stored[@"sentinelLastRunAt"] : @0,@"current":@NO,@"rows":@[],
        @"message":enabled ? @"Waiting for a current in-clone run. Reopen the clone after enabling." : @"Off. No sentinel probe thread is installed on launch."} mutableCopy];
    if (alert) summary[@"message"] = @"Isolation alert retained. Opening blocked · review Diagnostics, even if the sentinel is now off.";
    // Read each OFF profile once per daemon lifetime to revoke any older ON
    // control; later OFF publications do not rescan that clone.
    static NSMutableDictionary *controls;
    if (!controls) controls = [NSMutableDictionary dictionary];
    NSDictionary *cached = controls[container];
    if (!enabled && [cached[@"settings"] isEqual:settings]) return summary;
    RBXCloneManager *manager = [RBXCloneManager new];
    NSString *home = [manager dataContainerForBundleIdentifier:bundle];
    if (!RBXAcceptanceUUID(home.lastPathComponent)) return summary;
    int prefs = RBXSentinelPrefs(home);
    if (prefs < 0) return summary;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary *control = RBXSentinelRead(prefs,RBXSentinelControlName,0);
    if (!enabled && !control) { controls[container] = @{@"settings":settings}; close(prefs); return summary; }
    if (![control[@"targets"] isKindOfClass:NSArray.class]) control = nil;
    if (![control[@"settings"] isEqual:settings] || !RBXSentinelFresh(control[@"issuedAt"],now,15)) {
        NSMutableArray *targets = [NSMutableArray array];
        if (enabled) for (NSString *sibling in [identifiers sortedArrayUsingSelector:@selector(compare:)]) {
            if ([sibling isEqual:container]) continue;
            NSDictionary *other = [RBXProfileIO loadProfileForContainer:sibling error:nil];
            NSDictionary *target = other ? RBXSentinelTarget(other,manager,now) : nil;
            if (target && ![target[@"dataUUID"] isEqual:home.lastPathComponent] && targets.count < 64) [targets addObject:target];
        }
        // Stable revision for the same target identities/seed nonces. Witness
        // refreshes alone do not invalidate a 15-minute report.
        NSMutableArray *(^identities)(NSArray *) = ^NSMutableArray *(NSArray *input) {
            NSMutableArray *output = [NSMutableArray array];
            for (NSDictionary *item in input) { NSMutableDictionary *copy = [item mutableCopy];
                [copy removeObjectsForKeys:@[@"witnessAt",@"expiresAt"]]; [output addObject:copy]; }
            return output;
        };
        BOOL same = [control[@"settings"] isEqual:settings] && [control[@"dataUUID"] isEqual:home.lastPathComponent] &&
            [identities(control[@"targets"]) isEqual:identities(targets)] && RBXAcceptanceUUID(control[@"revision"]);
        control = @{@"schemaVersion":@1,@"bundleIdentifier":bundle,@"dataUUID":home.lastPathComponent,
            @"revision":same ? control[@"revision"] : NSUUID.UUID.UUIDString,@"settings":settings,
            @"issuedAt":@(now),@"targets":targets};
        if (!RBXSentinelWrite(prefs,RBXSentinelControlName,control,0)) {
            summary[@"message"] = @"Sentinel control could not be delivered; no runtime coverage is claimed.";
            close(prefs); return summary;
        }
        controls[container] = control;
    }
    if (!enabled) { close(prefs); return summary; }
    NSDictionary *identity = [self _currentProcessIdentity];
    NSDictionary *ready = RBXSentinelRead(prefs,@"com.redditbox.hook-ready.plist",501);
    BOOL bound = RBXSentinelProcessBound(identity,profile,lease,ready,now) &&
        RBXRequiredChecksPassed(ready[@"installedGroups"],RBXRequiredHookGroups()) &&
        RBXRequiredChecksPassed(ready[@"behaviorChecks"],RBXRequiredBehaviorChecks());
    NSString *unavailable = alert ? @"Isolation alert retained. No current runtime report; review the earlier finding before OPEN." :
        @"No current, process-bound sentinel result. The clone may be closed, suspended, or awaiting its first run.";
    if (!bound || !RBXSentinelControlValid(control,bundle,home.lastPathComponent,now) ||
        ![identity isEqual:[self _currentProcessIdentity]]) {
        summary[@"message"] = unavailable;
        close(prefs); return summary;
    }
    // Receiving a report can discover a quarantine that must survive restart.
    // Establish durable ownership BEFORE reading it; only a completed checked
    // store publication may retire this journal. No network operation is made.
    RBXOperationContext *receipt = [RBXOperationContext contextWithRequestID:@"sentinel-observation"
        bootEpoch:RBXOperationContext.daemonBootEpoch timeout:2.0];
    if (![receipt beginWork:nil]) {
        [receipt markUnsafeWithReason:@"Sentinel evidence could not establish durable ownership; recovery is required" error:nil];
        summary[@"recoveryRequired"] = @YES;
        summary[@"message"] = @"Isolation evidence could not be recorded safely. Further launches are blocked; open Diagnostics.";
        [receipt finish];
        close(prefs); return summary;
    }
    @try {
        NSDictionary *report = RBXSentinelRead(prefs,RBXSentinelReportName,501);
        if (!RBXSentinelReportValid(report,control,ready,now) ||
            ![identity isEqual:[self _currentProcessIdentity]]) {
            summary[@"message"] = unavailable;
            return summary;
        }
        NSArray *rows = RBXSentinelNormalizedRows(report[@"rows"]);
        BOOL leak = RBXSentinelHasLeak(rows) || [report[@"alert"] isEqual:@YES];
        if (leak && !alert)
            NSLog(@"RBX_SENTINEL container=%@ result=LEAK review-before-network-open",container);
        summary[@"alert"] = @(alert || leak);
        summary[@"timestamp"] = report[@"timestamp"];
        summary[@"current"] = @YES;
        __block BOOL persisted = YES;
        // Always confirm a LEAK against the current store, even when the older
        // launcher snapshot already had that flag. Publish flag + alert together.
        if (leak || ![stored[@"sentinelLastRunAt"] isEqual:report[@"timestamp"]]) {
            [receipt performBlock:^{
                __block BOOL entryFound = NO;
                persisted = [RBXCentralStore.sharedStore update:^(NSMutableDictionary *doc) {
                    NSMutableDictionary *containers = [doc[@"containers"] mutableCopy];
                    NSMutableDictionary *entry = [containers[container] mutableCopy];
                    if (!entry) return; // Never recreate a deleted profile from diagnostics.
                    entryFound = YES;
                    entry[@"sentinelLastRunAt"] = report[@"timestamp"];
                    if (leak) {
                        entry[@"sentinelAlert"] = @YES;
                        NSMutableArray *alerts = [doc[@"alerts"] mutableCopy] ?: [NSMutableArray array];
                        BOOL duplicate = NO;
                        for (NSDictionary *item in alerts)
                            if ([item[@"type"] isEqual:@"ISOLATION SENTINEL"] && [item[@"containerId"] isEqual:container]) duplicate = YES;
                        if (!duplicate) [alerts addObject:@{@"type":@"ISOLATION SENTINEL",@"containerId":container,
                            @"timestamp":report[@"timestamp"],
                            @"message":@"In-clone sentinel reported visible isolated data. Review diagnostics before network OPEN. Observer did not change the gate."}];
                        if (alerts.count > 100) [alerts removeObjectsInRange:NSMakeRange(0,alerts.count-100)];
                        doc[@"alerts"] = alerts;
                    }
                    containers[container] = entry; doc[@"containers"] = containers;
                } error:nil] && entryFound;
            }];
            NSDictionary *committed = RBXCentralStore.sharedStore.dictionary[@"containers"][container];
            persisted = persisted && [committed[@"sentinelLastRunAt"] isEqual:report[@"timestamp"]] &&
                (!leak || [committed[@"sentinelAlert"] isEqual:@YES]);
        }
        if (!persisted) {
            [receipt markUnsafeWithReason:@"Sentinel evidence publication could not be verified; recovery is required before another launch" error:nil];
            summary[@"recoveryRequired"] = @YES;
        }
        summary[@"persistenceVerified"] = @(persisted);
        // Never publish clone-controlled free text, canary contents, group names
        // or sibling UUIDs into the public launcher state.
        NSMutableArray *safe = [NSMutableArray array];
        BOOL allPassed = YES;
        for (NSDictionary *row in rows) {
            NSString *status = row[@"status"];
            allPassed &= [status isEqual:@"PASS"];
            [safe addObject:@{@"probe":row[@"probe"],@"target":row[@"target"],@"status":status,@"code":row[@"code"],
                @"detail":[status isEqual:@"LEAK"] ? @"Unexpected visibility: review before network OPEN." :
                    ([status isEqual:@"PASS"] ? @"The stated public-API probe passed." : @"Missing seed, compatibility sharing, or inconclusive API result.")}];
        }
        summary[@"rows"] = safe;
        summary[@"message"] = !persisted ? @"Isolation evidence could not be retained safely. Further launches are blocked; open Diagnostics." :
            (alert || leak ? @"Isolation alert. Review before network OPEN; the observer did not change network access." :
            (allPassed && [control[@"targets"] count] && [control[@"targets"] count] == (identifiers.count ? identifiers.count-1 : 0) ? @"All configured sibling-isolation probes passed for this run. This is bounded runtime evidence, not a guarantee of complete isolation." :
                @"Some probes or sibling targets are not verified. Prepare SSH acceptance seeds in siblings and inspect each result."));
    } @catch (__unused NSException *exception) {
        [receipt markUnsafeWithReason:@"Sentinel evidence processing was interrupted; recovery is required" error:nil];
        summary[@"current"] = @NO;
        summary[@"persistenceVerified"] = @NO;
        summary[@"recoveryRequired"] = @YES;
        summary[@"message"] = @"Isolation evidence processing failed. Further launches are blocked; open Diagnostics.";
    } @finally {
        close(prefs);
        [receipt endWork];
        [receipt finish];
    }
    return summary;
}
@end
