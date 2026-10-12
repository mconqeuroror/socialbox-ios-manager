#import "RBXAppRegistry.h"
#import "RBXLiveness.h"
#import "RBXLaunchSafety.h"
#import "RBXSentinelController.h"
#import "RBXLauncherState.h"
#import "RBXProfileMetadata.h"
#import "RBXReplacement.h"
#import "RBXLicenseGuard.h"
#import "RBXContainerRegistry.h"
#import "RBXCentralStore.h"
#import "RBXCloneManager.h"
#import "RBXSecureConfig.h"
#import "RBXNetworkGate.h"
#import "RBXProfileIO.h"
#import "RBXConsistencyValidator.h"
#import "RBXOperationContext.h"
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <errno.h>

static NSString *const RBXLauncherStatePath =
    @"/var/mobile/Library/Preferences/com.redditbox.launcher-state.plist";
static NSString *const RBXLeasePath =
    @"/var/mobile/Library/Preferences/com.redditbox.network-lease.plist";
static NSString *const RBXFirewallStatusPath =
    @"/var/mobile/Library/Preferences/com.redditbox.firewall-status.plist";
static NSDictionary *RBXStartupRecoveryResult;

static dispatch_queue_t RBXPublicationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.redditbox.launcher-state", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Add a type only when persisted data carries one. Legacy rows keep their
// exact field shape, and malformed types remain an unknown (hidden) scope.
static NSDictionary *RBXAppRowWithOwnership(NSDictionary *row, NSDictionary *owner) {
    if (![owner isKindOfClass:NSDictionary.class] || !owner[@"appType"]) return row;
    NSMutableDictionary *typed = [row mutableCopy];
    typed[@"appType"] = [owner[@"appType"] isKindOfClass:NSString.class] ? owner[@"appType"] : @"invalid";
    return typed;
}

@implementation RBXLauncherState
+ (void)publishStartupRecoveryResult:(NSDictionary *)result registry:(RBXContainerRegistry *)registry {
    dispatch_async(RBXPublicationQueue(), ^{
        RBXStartupRecoveryResult = [result copy];
        [self _publishWithRegistry:registry];
    });
}

+ (NSString *)statePath {
    return RBXLauncherStatePath;
}

+ (void)publishWithRegistry:(RBXContainerRegistry *)registry {
    // Capture the snapshot on this queue too: an older caller cannot finish
    // assembling a document late and overwrite a newer publication.
    dispatch_async(RBXPublicationQueue(), ^{ [self _publishWithRegistry:registry]; });
}

+ (BOOL)refreshBeforeLaunchWithRegistry:(RBXContainerRegistry *)registry {
    // Launch operations run on the operation queue. Drain the serial observer
    // publication before evaluating retained findings or killing the old clone.
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(RBXPublicationQueue(), ^{
        [self _publishWithRegistry:registry]; dispatch_semaphore_signal(finished);
    });
    return dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC))==0;
}

+ (void)_publishWithRegistry:(RBXContainerRegistry *)registry {
    NSDictionary *store = [[RBXCentralStore sharedStore] dictionary];
    NSDictionary *deviceState = [store[@"device"] isKindOfClass:[NSDictionary class]]
        ? store[@"device"] : @{};
    NSDictionary *storedContainers = [store[@"containers"] isKindOfClass:[NSDictionary class]]
        ? store[@"containers"] : @{};
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXLeasePath] ?: @{};
    NSDictionary *firewall =
        [NSDictionary dictionaryWithContentsOfFile:RBXFirewallStatusPath] ?: @{};
    NSString *active = [lease[@"containerId"] isKindOfClass:[NSString class]]
        ? lease[@"containerId"] : @"";

    NSMutableArray *rows = [NSMutableArray array];
    NSError *inventoryError = nil;
    NSArray *profileIds = [registry containerIdsWithError:&inventoryError];
    NSString *profileWarning = inventoryError.localizedDescription ?: @"";
    NSMutableSet *visibleIds = [NSMutableSet set];
    for (id containerId in profileIds) {
        if ([RBXProfileIO isSafeContainerIdentifier:containerId]) [visibleIds addObject:containerId];
        else profileWarning = @"A profile filename has an unsafe identifier and needs recovery inspection.";
    }
    // A missing profile file must remain visible when its store entry survives.
    for (id containerId in storedContainers) {
        if ([RBXProfileIO isSafeContainerIdentifier:containerId]) [visibleIds addObject:containerId];
    }
    NSString *deletionWarning = @"";
    for (NSDictionary *deletion in [registry pendingDeletionStates]) {
        if ([deletion[@"globalError"] boolValue]) {
            deletionWarning = [deletion[@"message"] isKindOfClass:NSString.class]
                ? deletion[@"message"] : @"Deletion records could not be read. Cleanup needs recovery.";
        }
        NSString *containerId = deletion[@"containerId"];
        if ([containerId isKindOfClass:NSString.class] && containerId.length)
            [visibleIds addObject:containerId];
    }
    for (NSString *containerId in [visibleIds.allObjects
            sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
        NSError *replacementError = nil;
        NSDictionary *replacement = [RBXReplacement replacementStateForContainer:containerId error:&replacementError] ?: @{};
        if (replacementError) profileWarning = replacementError.localizedDescription;
        NSDictionary *deletion = [registry deletionStateForContainer:containerId];
        if (deletion) {
            if ([deletion[@"completed"] boolValue]) continue;
            // A crash can remove the profile before retirement commits. Keep
            // the durable cleanup record visible without loading that profile
            // or asking identity/clone code to reconstruct it.
            [rows addObject:RBXAppRowWithOwnership(@{
                @"id": containerId,
                @"name": containerId,
                @"isActive": @NO,
                @"cloneState": @"deletion-pending",
                @"deletionState": deletion,
                @"replacementState": replacement,
            }, storedContainers[containerId])];
            continue;
        }
        NSDictionary *stored = [storedContainers[containerId]
            isKindOfClass:[NSDictionary class]] ? storedContainers[containerId] : @{};
        NSError *profileError = nil;
        NSDictionary *profile = [RBXProfileIO loadProfileForContainer:containerId error:&profileError];
        if (profile) profile = [RBXConsistencyValidator validatedProfile:profile error:&profileError];
        if (!profile) {
            NSDictionary *ownership = [RBXProfileIO readProfileOwnershipForContainer:containerId error:nil] ?: stored;
            [rows addObject:RBXAppRowWithOwnership(@{
                @"id": containerId,
                @"name": [stored[@"nickname"] isKindOfClass:NSString.class] ? stored[@"nickname"] : containerId,
                @"isActive": @NO,
                @"cloneState": @"unavailable",
                @"replacementState": replacement,
                @"profileError": @{
                    @"message": profileError.localizedDescription ?: @"Profile could not be read.",
                    @"code": @(profileError.code),
                },
            }, ownership)];
            continue;
        }
        NSDictionary *device = [profile[@"device"] isKindOfClass:[NSDictionary class]]
            ? profile[@"device"] : @{};
        NSDictionary *proxy = [profile[@"proxy"] isKindOfClass:[NSDictionary class]]
            ? profile[@"proxy"] : @{};
        NSDictionary *app = [profile[@"app"] isKindOfClass:[NSDictionary class]]
            ? profile[@"app"] : @{};
        NSDictionary *health = [stored[@"lastHealth"] isKindOfClass:[NSDictionary class]]
            ? stored[@"lastHealth"] : @{};
        BOOL isActive = [active isEqualToString:containerId] &&
            ([lease[@"state"] isEqualToString:@"armed"] ||
             [lease[@"state"] isEqualToString:@"open"]);

        BOOL hooksReady = NO;
        NSString *bundleIdentifier = app[@"bundleIdentifier"];
        NSString *dataContainer = isActive && bundleIdentifier.length
            ? [[RBXCloneManager new] dataContainerForBundleIdentifier:bundleIdentifier] : nil;
        if (dataContainer.length) {
            NSDictionary *ready = [NSDictionary dictionaryWithContentsOfFile:
                [dataContainer stringByAppendingPathComponent:
                    @"Library/Preferences/com.redditbox.hook-ready.plist"]];
            hooksReady = [ready[@"containerId"] isEqualToString:containerId] &&
                [ready[@"generation"] isEqualToString:lease[@"generation"]];
        }

        NSString *proxyStatus = isActive ? (lease[@"state"] ?: @"closed") :
            (proxy[@"url"] ? @"configured" : @"awaiting rotation");
        NSDictionary *identityEditor =
            [registry identityEditorStateForContainer:containerId error:nil] ?: @{};
        NSError *managedError = nil;
        BOOL managed = [[RBXCloneManager new] verifyManagedInstallationForProfile:profile error:&managedError];
        NSDictionary *sentinel = [RBXSentinelController summaryForProfile:profile siblings:visibleIds.allObjects store:store lease:lease];
        NSString *launchBlock = RBXIsolationLaunchBlock(RBXCentralStore.sharedStore.dictionary,containerId);
        if ([sentinel[@"recoveryRequired"] isEqual:@YES]) launchBlock = sentinel[@"message"];
        [rows addObject:RBXAppRowWithOwnership(@{
            @"id": containerId,
            @"bundleIdentifier": bundleIdentifier ?: @"",
            @"name": RBXProfileDisplayName(profile, stored[@"nickname"], containerId),
            @"country": [proxy[@"country"] isKindOfClass:[NSString class]]
                ? proxy[@"country"] : @"—",
            @"identity": [device[@"marketingName"] isKindOfClass:[NSString class]]
                ? device[@"marketingName"] : (device[@"productType"] ?: @"—"),
            @"locale": [device[@"locale"] isKindOfClass:[NSString class]]
                ? device[@"locale"] : @"—",
            @"proxyStatus": proxyStatus,
            @"isActive": @(isActive),
            @"lastActiveAt": [stored[@"lastActiveAt"] isKindOfClass:[NSNumber class]]
                ? stored[@"lastActiveAt"] : @0,
            @"lastLoginAt": [stored[@"lastLoginAt"] isKindOfClass:[NSNumber class]]
                ? stored[@"lastLoginAt"] : @0,
            @"requiresLoginVerification": @([stored[@"requiresLoginVerification"] boolValue]),
            @"loginKnown": @(![stored[@"requiresLoginVerification"] boolValue] && [stored[@"username"] isKindOfClass:[NSString class]] &&
                              [stored[@"username"] length] > 0),
            @"hooksReady": @(hooksReady),
            @"vpnArmed": @(isActive && RBXHeartbeatFresh(lease[@"heartbeatAt"], NSDate.date.timeIntervalSince1970) &&
                RBXHeartbeatFresh(firewall[@"heartbeatAt"], NSDate.date.timeIntervalSince1970) &&
                [lease[@"generation"] isEqual:firewall[@"generation"]] && [lease[@"bootEpoch"] isEqual:firewall[@"bootEpoch"]] &&
                [firewall[@"enforced"] boolValue] &&
                ([firewall[@"state"] isEqualToString:@"armed"] ||
                 [firewall[@"state"] isEqualToString:@"open"])),
            @"health": [health[@"result"] isKindOfClass:[NSString class]]
                ? health[@"result"] : @"unknown",
            @"cloneState": [app[@"cloneState"] isKindOfClass:[NSString class]]
                ? app[@"cloneState"] : @"missing",
            @"identityEditor": identityEditor,
            @"isolationSentinel": sentinel,
            @"launchBlockReason": launchBlock ?: @"",
            @"managedInstallation": @{@"verified":@(managed),@"checkedAt":@(NSDate.date.timeIntervalSince1970),
                @"message":managed ? @"MDM-managed installation observed. Effective VPN routing still needs device verification."
                    : (managedError.localizedDescription ?: @"Export this clone IPA and have MDM install and assign it.")},
            @"role": RBXProfileMetadata(profile)[@"role"],
            @"notes": RBXProfileMetadata(profile)[@"notes"],
            @"metadataDirty": @([profile[@"metadataDirty"] boolValue]),
            @"replacementState": replacement,
            @"username": [stored[@"username"] isKindOfClass:NSString.class] ? stored[@"username"] : @"",
        }, profile)];
    }

    // Additive per-app source status. The legacy source/import fields below
    // remain byte-for-byte Reddit values for existing launcher consumers.
    NSMutableDictionary *sources = [NSMutableDictionary dictionary];
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        RBXCloneManager *manager = [[RBXCloneManager alloc] initWithAppType:descriptor[@"appType"] operationContext:nil];
        sources[descriptor[@"appType"]] = [manager sourceStatus];
    }
    NSMutableDictionary *sourceImports = [deviceState[@"launcherSourceImports"] isKindOfClass:NSDictionary.class]
        ? [deviceState[@"launcherSourceImports"] mutableCopy] : [NSMutableDictionary dictionary];
    if ([deviceState[@"launcherSourceImport"] isKindOfClass:NSDictionary.class])
        sourceImports[@"reddit"] = deviceState[@"launcherSourceImport"];
    NSDictionary *document = @{
        @"formatVersion": @1,
        @"sources": sources,
        @"sourceImports": sourceImports,
        @"license": RBXLicenseGuard.sharedGuard.safeStatus,
        @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        @"activeContainer": active,
        @"workspaceSelection": [deviceState[@"workspaceSelection"] isKindOfClass:NSDictionary.class] ? deviceState[@"workspaceSelection"] : @{},
        @"networkState": [lease[@"state"] isKindOfClass:[NSString class]]
            ? lease[@"state"] : @"closed",
        @"firewallScope": [firewall[@"scope"] isKindOfClass:[NSString class]]
            ? firewall[@"scope"] : @"unknown",
        @"configuration": [RBXSecureConfig safeSummary],
        @"configurationTest": [deviceState[@"launcherConfigurationTest"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherConfigurationTest"] : @{},
        @"source": sources[@"reddit"],
        @"firewallSetup": [RBXNetworkGate setupStatus],
        @"sourceImport": [deviceState[@"launcherSourceImport"] isKindOfClass:NSDictionary.class]
            ? deviceState[@"launcherSourceImport"] : @{},
        @"diagnostics": [deviceState[@"launcherDiagnostics"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherDiagnostics"] : @{},
        @"supportLog": [deviceState[@"launcherSupportLog"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherSupportLog"] : @{},
        @"cloneExport": [deviceState[@"launcherCloneExport"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherCloneExport"] : @{},
        @"cloud": [deviceState[@"launcherCloudStatus"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherCloudStatus"] : @{},
        @"operation": [deviceState[@"launcherOperation"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherOperation"] : @{},
        @"identityResult": [deviceState[@"launcherIdentityResult"]
            isKindOfClass:[NSDictionary class]]
            ? deviceState[@"launcherIdentityResult"] : @{},
        @"containers": rows,
        @"deletionWarning": deletionWarning,
        @"profileWarning": profileWarning,
        @"operationRecovery": [RBXOperationContext safetyFenceStatus] ?: @{},
        @"startupRecovery": RBXStartupRecoveryResult ?: @{},
    };
    NSString *temporary = [RBXLauncherStatePath stringByAppendingFormat:@".%@.tmp", NSUUID.UUID.UUIDString];
    if ([document writeToFile:temporary atomically:YES]) {
        // Set metadata before publishing; readers never observe an unreadable
        // replacement. POSIX rename replaces an existing file without a gap.
        if (chmod(temporary.fileSystemRepresentation, 0644) != 0 ||
            chown(temporary.fileSystemRepresentation, 501, 501) != 0 ||
            rename(temporary.fileSystemRepresentation, RBXLauncherStatePath.fileSystemRepresentation) != 0) {
            NSLog(@"redditboxd: launcher publication failed (errno=%d)", errno);
            [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
            return;
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.redditbox.launcherStateChanged"), NULL, NULL, TRUE);
    } else {
        NSLog(@"redditboxd: cannot stage launcher publication");
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];
    }
}

+ (void)startPeriodicPublisherWithRegistry:(RBXContainerRegistry *)registry {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = RBXPublicationQueue();
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            [self _publishWithRegistry:registry];
        });
        dispatch_resume(timer);
    });
}

@end
