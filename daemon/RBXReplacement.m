#import "RBXReplacement.h"
#import "RBXProfileIdentifier.h"
#import "RBXAppLifecycle.h"
#import "RBXAppProfileIdentity.h"
#import <CoreFoundation/CoreFoundation.h>

static NSError *RBXReplacementError(NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.replacement" code:1
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Replacement needs recovery; its journal and profiles were retained"}];
}

static BOOL RBXReplacementJournalValid(NSDictionary *journal, NSString *container) {
    return [journal isKindOfClass:NSDictionary.class] &&
        [journal[@"formatVersion"] isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)journal[@"formatVersion"]) != CFBooleanGetTypeID() &&
        RBXAppReplacementJournalDescriptor(journal) &&
        [journal[@"oldId"] isEqual:container] && [journal[@"newId"] isKindOfClass:NSString.class] &&
        [journal[@"newId"] length] > 0 && ![journal[@"newId"] isEqual:container] &&
        [@[@"prepared", @"created", @"rotated", @"deleting", @"committed"] containsObject:journal[@"phase"]] &&
        [journal[@"name"] isKindOfClass:NSString.class] &&
        [journal[@"country"] isKindOfClass:NSString.class] &&
        [@[@"signup", @"warmup", @"spam", @"default"] containsObject:journal[@"role"]] &&
        [journal[@"previousExitIP"] isKindOfClass:NSString.class];
}

static BOOL RBXReplacementValidateJournal(id journal, NSError **error) {
    if (![journal isKindOfClass:NSDictionary.class] || !RBXReplacementJournalValid(journal, journal[@"oldId"])) {
        if (error) *error = RBXReplacementError(@"Replacement journal has invalid app identity or phase"); return NO;
    }
    return YES;
}

// Verify profiles independently of the caller's selected app. A retained
// failed-create profile may lack app metadata; completed candidates may not.
static BOOL RBXReplacementProfileOwned(NSDictionary *journal, NSDictionary *profile,
    BOOL candidate, BOOL installed, NSError **error) {
    if (!RBXReplacementValidateJournal(journal, error)) return NO;
    NSDictionary *descriptor = RBXAppReplacementJournalDescriptor(journal);
    NSString *container = journal[candidate ? @"newId" : @"oldId"];
    NSString *blocked = RBXAppProfileIdentityBlockReason(descriptor, profile, container);
    if (blocked) { if (error) *error = RBXReplacementError(blocked); return NO; }
    NSDictionary *app = [profile[@"app"] isKindOfClass:NSDictionary.class] ? profile[@"app"] : nil;
    NSString *bundle = RBXAppBundleIdentifier(descriptor, container);
    if (!blocked && installed && (![app[@"bundleIdentifier"] isEqual:bundle] ||
        ![app[@"keychainAccessGroup"] isEqual:RBXAppKeychainGroup(descriptor, bundle)] ||
        !RBXAppKeychainMetadataMatches(descriptor, bundle, app)))
        blocked = @"Replacement profile lacks its complete installed app identity.";
    if (blocked && error) *error = RBXReplacementError(blocked);
    return !blocked;
}

static BOOL RBXReplacementInventoryValid(id journals, NSError **error) {
    if (![journals isKindOfClass:NSDictionary.class]) {
        if (error) *error = RBXReplacementError(@"Replacement inventory is malformed; retain its profiles for recovery");
        return NO;
    }
    NSMutableSet *newIDs = [NSMutableSet set], *pendingIDs = [NSMutableSet set];
    for (id oldID in journals) {
        NSDictionary *journal = journals[oldID];
        if (!RBXCanonicalProfileIdentifier(oldID) || !RBXReplacementJournalValid(journal, oldID) ||
            !RBXCanonicalProfileIdentifier(journal[@"newId"]) || [newIDs containsObject:journal[@"newId"]]) {
            if (error) *error = RBXReplacementError(@"Replacement inventory has invalid or conflicting identities");
            return NO;
        }
        [newIDs addObject:journal[@"newId"]];
        if (![journal[@"phase"] isEqual:@"committed"]) {
            if ([pendingIDs containsObject:oldID] || [pendingIDs containsObject:journal[@"newId"]]) {
                if (error) *error = RBXReplacementError(@"Pending replacements overlap; retain all profiles for recovery");
                return NO;
            }
            [pendingIDs addObject:oldID]; [pendingIDs addObject:journal[@"newId"]];
        }
    }
    return YES;
}

BOOL RBXReplacementMutationAllowed(id journals, NSString *container,
    RBXReplacementMutation mutation, NSError **error) {
    if (!RBXCanonicalProfileIdentifier(container) ||
        (mutation != RBXReplacementUserDelete && mutation != RBXReplacementStartOrResume)) {
        if (error) *error = RBXReplacementError(@"Replacement mutation has an invalid target or action");
        return NO;
    }
    if (!RBXReplacementInventoryValid(journals, error)) return NO;
    for (NSDictionary *journal in [journals allValues]) {
        if ([journal[@"phase"] isEqual:@"committed"]) continue;
        BOOL candidate = [journal[@"newId"] isEqual:container];
        BOOL original = [journal[@"oldId"] isEqual:container];
        if (candidate || (original && mutation == RBXReplacementUserDelete)) {
            if (error) *error = RBXReplacementError([NSString stringWithFormat:
                @"This profile belongs to an unfinished replacement. Resume Replace from %@; deleting either profile or replacing the candidate would destroy recovery state",
                journal[@"oldId"]]);
            return NO;
        }
    }
    return YES;
}

static BOOL RBXReplacementAdvance(NSMutableDictionary *journal, NSString *phase,
    id<RBXReplacementBackend> backend, NSError **error) {
    NSMutableDictionary *next = [journal mutableCopy];
    next[@"phase"] = phase;
    next[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
    if (![backend persistJournal:next error:error]) return NO;
    [journal setDictionary:next];
    return YES;
}

NSString *RBXRunReplacement(NSString *container, id<RBXReplacementBackend> backend, NSError **error) {
    if (![backend replacementAllowedForContainer:container error:error]) return nil;
    NSError *failure = nil;
    NSDictionary *stored = [backend journalForContainer:container error:&failure];
    if (failure) { if (error) *error = failure; return nil; }
    if (!stored) {
        stored = [backend prepareJournalForContainer:container error:error];
        if (!stored) return nil;
        if (!RBXReplacementJournalValid(stored, container) || ![stored[@"phase"] isEqual:@"prepared"]) {
            if (error) *error = RBXReplacementError(@"Replacement preparation produced invalid recovery state"); return nil;
        }
        // Candidate ID is durable before profile generation or installation.
        if (![backend persistJournal:stored error:error]) return nil;
    }
    if (!RBXReplacementJournalValid(stored, container)) {
        if (error) *error = RBXReplacementError(@"Replacement journal is malformed; both identities remain reserved"); return nil;
    }
    NSMutableDictionary *journal = [stored mutableCopy];
    if ([journal[@"phase"] isEqual:@"committed"])
        return [backend validateCandidateForJournal:journal error:error] ? journal[@"newId"] : nil;
    if (![backend establishClosureForJournal:journal error:error]) return nil;
    if ([journal[@"phase"] isEqual:@"prepared"]) {
        if (![backend createCandidateForJournal:journal error:error] ||
            !RBXReplacementAdvance(journal, @"created", backend, error)) return nil;
    }
    if ([journal[@"phase"] isEqual:@"created"]) {
        NSString *exitIP = [backend rotateCandidateForJournal:journal error:error];
        if (!exitIP.length) return nil;
        journal[@"exitIP"] = exitIP;
        if (!RBXReplacementAdvance(journal, @"rotated", backend, error)) return nil;
    }
    if (![backend validateCandidateForJournal:journal error:error]) return nil;
    if ([journal[@"phase"] isEqual:@"rotated"] &&
        !RBXReplacementAdvance(journal, @"deleting", backend, error)) return nil;
    // No path reaches deletion until successful rotation has a durable receipt.
    if (![backend deleteOriginalForJournal:journal error:error] ||
        !RBXReplacementAdvance(journal, @"committed", backend, error)) return nil;
    return journal[@"newId"];
}

#ifndef RBX_REPLACEMENT_TESTING
#import "RBXContainerRegistry.h"
#import "RBXProxyManager.h"
#import "RBXCloudSync.h"
#import "RBXOperationContext.h"
#import "RBXCentralStore.h"
#import "RBXProfileIO.h"
#import "RBXProcessController.h"
#import "RBXAppProcessCoordinator.h"
#import "RBXNetworkGate.h"
#import "RBXProfileMetadata.h"
#import <sys/stat.h>
#import <errno.h>

static NSDictionary *RBXReplacementStore(NSError **error) {
    struct stat info;
    if (lstat(RBXCentralStore.storePath.fileSystemRepresentation, &info) != 0 && errno == ENOENT) return @{};
    return [RBXProfileIO readJSONDictionaryAtPath:RBXCentralStore.storePath error:error];
}

static NSDictionary *RBXReplacementJournals(NSError **error) {
    NSDictionary *store = RBXReplacementStore(error);
    if (!store) return nil;
    id journals = store[@"replacements"];
    if (!journals) return @{};
    return RBXReplacementInventoryValid(journals, error) ? journals : nil;
}

// Async cloud/proxy helpers own and count their descendants. This waiter never
// fabricates quiescence: timeout cancels the owner, whose outer request drains.
static NSDictionary *RBXReplacementWait(RBXOperationContext *context,
    void (^start)(void (^)(BOOL, NSString *, NSString *)), NSError **error) {
    if (![context check:error]) return nil;
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);
    NSObject *lock = [NSObject new];
    __block NSDictionary *result = nil;
    __block BOOL accepting = YES;
    NSString *cancel = [context registerCancellationHandler:^{ dispatch_semaphore_signal(signal); }];
    start(^(BOOL ok, NSString *value, NSString *message) {
        @synchronized (lock) {
            if (accepting) result = @{@"ok": @(ok), @"value": value ?: @"", @"message": message ?: @""};
        }
        dispatch_semaphore_signal(signal);
    });
    long timedOut = dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(MAX(0, context.remainingTime) * NSEC_PER_SEC)));
    [context unregisterCancellationHandler:cancel];
    NSDictionary *observed;
    @synchronized (lock) { accepting = NO; observed = result; }
    if (timedOut) [context cancelWithReason:@"Replacement cloud/proxy deadline expired"];
    if (![context check:error]) return nil;
    if (![observed[@"ok"] boolValue]) {
        if (error) *error = RBXReplacementError([observed[@"message"] length] ? observed[@"message"] : @"Replacement cloud/proxy operation did not succeed");
        return nil;
    }
    return observed;
}

@interface RBXDeviceReplacementBackend : NSObject <RBXReplacementBackend>
@property(nonatomic, strong) RBXContainerRegistry *registry;
@property(nonatomic, strong) RBXProxyManager *proxies;
@property(nonatomic, strong) RBXOperationContext *context;
@end

@implementation RBXDeviceReplacementBackend
- (BOOL)replacementAllowedForContainer:(NSString *)container error:(NSError **)error {
    NSDictionary *journals = RBXReplacementJournals(error);
    return journals && RBXReplacementMutationAllowed(journals, container, RBXReplacementStartOrResume, error);
}
- (NSDictionary *)journalForContainer:(NSString *)container error:(NSError **)error {
    return RBXReplacementJournals(error)[container];
}
- (BOOL)targetStopped:(NSString *)container profile:(NSDictionary *)profile error:(NSError **)error {
    NSDictionary *lease = [NSDictionary dictionaryWithContentsOfFile:RBXNetworkGate.leasePath];
    if (!lease || ![@[@"closed", @"armed", @"open"] containsObject:lease[@"state"]]) {
        if (error) *error = RBXReplacementError(@"Current network lease cannot be verified"); return NO;
    }
    if ([lease[@"containerId"] isEqual:container] && ![lease[@"state"] isEqual:@"closed"]) {
        if (error) *error = RBXReplacementError(@"Replacement refused: the target is active; close it first"); return NO;
    }
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    return descriptor && [[[RBXProcessController alloc] initWithAppDescriptor:descriptor]
        isProfileStopped:profile error:error];
}
- (NSDictionary *)prepareJournalForContainer:(NSString *)container error:(NSError **)error {
    if (![self.context check:error] || !RBXCanonicalProfileIdentifier(container)) return nil;
    NSDictionary *profile = [self.registry validatedProfileForContainer:container error:error];
    if (!profile || ![self targetStopped:container profile:profile error:error]) return nil;
    NSDictionary *store = RBXReplacementStore(error);
    if (!store) return nil;
    NSDictionary *entry = [store[@"containers"][container] isKindOfClass:NSDictionary.class] ? store[@"containers"][container] : @{};
    NSString *name = RBXProfileDisplayName(profile, entry[@"nickname"], container);
    NSString *previous = [entry[@"lastIP"] isKindOfClass:NSString.class] ? entry[@"lastIP"] : nil;
    if (!previous.length) previous = RBXNetworkGate.lastExitIP;
    NSDictionary *descriptor = RBXAppDescriptorForProfile(profile);
    if (!descriptor || (store[@"containers"][container] && ![RBXAppDescriptorForProfile(entry) isEqual:descriptor])) {
        if (error) *error = RBXReplacementError(@"Replacement app ownership conflicts with its stored profile"); return nil;
    }
    NSString *candidate = [@"c-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString];
    NSMutableDictionary *journal = [RBXAppReplacementJournalIdentity(descriptor, container, candidate) mutableCopy];
    if (!journal) { if (error) *error = RBXReplacementError(@"Replacement could not derive distinct app identities"); return nil; }
    [journal addEntriesFromDictionary:@{@"phase":@"prepared", @"name":name, @"role":RBXProfileMetadata(profile)[@"role"],
        @"country":profile[@"proxy"][@"country"] ?: @"US", @"previousExitIP":previous ?: @"",
        @"createdAt":@(NSDate.date.timeIntervalSince1970)}];
    return RBXReplacementProfileOwned(journal, profile, NO, YES, error) ? journal : nil;
}
- (BOOL)persistJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self.context check:error]) return NO;
    NSDictionary *existing = RBXReplacementJournals(error);
    if (!RBXReplacementValidateJournal(journal, error) || !existing) {
        if (error && !*error) *error = RBXReplacementError(@"Invalid replacement checkpoint; prior journal retained"); return NO;
    }
    NSDictionary *previous = existing[journal[@"oldId"]];
    if (previous && (![RBXAppReplacementJournalDescriptor(previous) isEqual:RBXAppReplacementJournalDescriptor(journal)] ||
        ![previous[@"newId"] isEqual:journal[@"newId"]])) {
        if (error) *error = RBXReplacementError(@"Replacement cannot change its published app or candidate identity"); return NO;
    }
    __block BOOL conflict = NO;
    BOOL saved = [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        id raw = doc[@"replacements"] ?: @{};
        if (!RBXReplacementInventoryValid(raw, nil)) { conflict = YES; return; }
        NSDictionary *previous = raw[journal[@"oldId"]];
        if (previous && (![RBXAppReplacementJournalDescriptor(previous) isEqual:RBXAppReplacementJournalDescriptor(journal)] ||
            ![previous[@"newId"] isEqual:journal[@"newId"]])) { conflict = YES; return; }
        NSMutableDictionary *journals = [raw mutableCopy];
        journals[journal[@"oldId"]] = journal;
        if (!RBXReplacementInventoryValid(journals, nil)) { conflict = YES; return; }
        doc[@"replacements"] = journals;
    } error:error];
    if (conflict && error) *error = RBXReplacementError(@"Replacement identities changed or overlapped; prior checkpoints retained");
    return saved && !conflict;
}
- (BOOL)establishClosureForJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self.context check:error] || !RBXReplacementValidateJournal(journal, error)) return NO;
    NSString *oldID = journal[@"oldId"];
    NSDictionary *deletion = [self.registry deletionStateForContainer:oldID];
    if ([journal[@"phase"] isEqual:@"deleting"] && deletion) {
        NSDictionary *identity = [self.registry deletionIdentityForContainer:oldID error:error];
        if (![identity isEqual:RBXAppDeletionTargetIdentity(RBXAppReplacementJournalDescriptor(journal), oldID)]) {
            if (error && !*error) *error = RBXReplacementError(@"Replacement deletion journal belongs to another or unknown app"); return NO;
        }
    } else {
        NSDictionary *profile = [self.registry validatedProfileForContainer:oldID error:error];
        if (!RBXReplacementProfileOwned(journal, profile, NO, YES, error) || ![self targetStopped:oldID profile:profile error:error] ||
            ![self.registry reserveIdentityForProfile:profile error:error]) return NO;
    }
    NSString *generation = [RBXNetworkGate closeTrafficWithReason:@"container replacement" error:error];
    if (!generation.length) return NO;
    if (![[RBXAppProcessCoordinator new] killAllAndWait:8] ||
        ![RBXNetworkGate waitForMaintenanceClosure:generation timeout:8]) {
        if (error) *error = RBXReplacementError(@"Replacement needs verified CLOSED traffic and stopped clones"); return NO;
    }
    return [self.context check:error];
}
- (BOOL)createCandidateForJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self.context check:error] || !RBXReplacementValidateJournal(journal, error)) return NO;
    NSString *identifier = journal[@"newId"];
    NSArray *identifiers = [self.registry containerIdsWithError:error];
    if (!identifiers) return NO;
    if ([identifiers containsObject:identifier]) {
        // A failed install may have left its profile and transaction. Recover
        // that exact identity; never generate another one for this journal.
        NSDictionary *profile = [self.registry validatedProfileForContainer:identifier error:error];
        if (!RBXReplacementProfileOwned(journal, profile, YES, NO, error) ||
            ![self.registry ensureAppCloneForContainer:identifier error:error]) return NO;
    } else if (![self.registry createContainerWithId:identifier appType:RBXAppReplacementJournalDescriptor(journal)[@"appType"]
        proxyCountry:journal[@"country"]
        proxyURL:@"" nickname:journal[@"name"] error:error]) return NO;
    NSDictionary *created = [self.registry validatedProfileForContainer:identifier error:error];
    if (!RBXReplacementProfileOwned(journal, created, YES, YES, error)) return NO;
    if (![self.registry updateMetadata:@{@"role": journal[@"role"], @"notes": @""}
        forContainer:identifier local:YES error:error]) return NO;
    return [[RBXCentralStore sharedStore] update:^(NSMutableDictionary *doc) {
        NSMutableDictionary *entry = [doc[@"containers"][identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"nickname"] = journal[@"name"];
        entry[@"username"] = @"";
        entry[@"requiresLoginVerification"] = @YES;
        doc[@"containers"][identifier] = entry;
    } error:error];
}
- (NSString *)rotateCandidateForJournal:(NSDictionary *)journal error:(NSError **)error {
    NSString *identifier = journal[@"newId"];
    NSDictionary *profile = [self.registry validatedProfileForContainer:identifier error:error];
    if (!RBXReplacementProfileOwned(journal, profile, YES, YES, error)) return nil;
    if ([RBXCloudSync sharedSync].paired && !RBXReplacementWait(self.context,
        ^(void (^done)(BOOL, NSString *, NSString *)) {
            [[RBXCloudSync sharedSync] syncProfileInventoryWithContext:self.context
                completion:^(BOOL ok, NSString *message) { done(ok, nil, message); }];
        }, error)) return nil;
    NSDictionary *authorization = RBXReplacementWait(self.context, ^(void (^done)(BOOL, NSString *, NSString *)) {
        [[RBXCloudSync sharedSync] syncRotationAuthForContainer:identifier context:self.context
            completion:^(BOOL ok, NSString *message) { done(ok, nil, message); }];
    }, error);
    if (!authorization) return nil;

    NSDictionary *store = RBXReplacementStore(error);
    if (!store) return nil;
    id latestOldIP = store[@"containers"][journal[@"oldId"]][@"lastIP"];
    NSString *previous = RBXNetworkGate.lastExitIP;
    if (!previous.length && [latestOldIP isKindOfClass:NSString.class]) previous = latestOldIP;
    if (!previous.length) previous = journal[@"previousExitIP"];
    NSDictionary *rotated = RBXReplacementWait(self.context, ^(void (^done)(BOOL, NSString *, NSString *)) {
        [self.proxies rotateAndActivateProfile:profile previousExitIP:previous
            generation:NSUUID.UUID.UUIDString context:self.context completion:done];
    }, error);
    if (!rotated) return nil;
    NSString *exitIP = rotated[@"value"];
    if (([latestOldIP isKindOfClass:NSString.class] && [latestOldIP isEqual:exitIP]) ||
        ([journal[@"previousExitIP"] length] && [journal[@"previousExitIP"] isEqual:exitIP])) {
        if (error) *error = RBXReplacementError(@"Rotation returned a known previous exit; the original container was retained"); return nil;
    }
    NSDictionary *current = [self.registry validatedProfileForContainer:identifier error:error];
    return RBXReplacementProfileOwned(journal, current, YES, YES, error) &&
        [self.registry syncProfileToCloneForContainer:identifier error:error] ? rotated[@"value"] : nil;
}
- (BOOL)validateCandidateForJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self.context check:error] || !RBXReplacementValidateJournal(journal, error)) return NO;
    NSDictionary *profile = [self.registry validatedProfileForContainer:journal[@"newId"] error:error];
    if (!RBXReplacementProfileOwned(journal, profile, YES, YES, error)) return NO;
    if (![profile[@"proxy"][@"url"] isKindOfClass:NSString.class] || ![profile[@"proxy"][@"url"] length] ||
        ![journal[@"exitIP"] isKindOfClass:NSString.class] || ![journal[@"exitIP"] length]) {
        if (error) *error = RBXReplacementError(@"Replacement has no durable successful rotation receipt"); return NO;
    }
    return YES;
}
- (BOOL)deleteOriginalForJournal:(NSDictionary *)journal error:(NSError **)error {
    if (![self.context check:error] || !RBXReplacementValidateJournal(journal, error)) return NO;
    NSError *profileError = nil;
    NSDictionary *profile = [self.registry validatedProfileForContainer:journal[@"oldId"] error:&profileError];
    if (profile) {
        if (!RBXReplacementProfileOwned(journal, profile, NO, YES, error)) return NO;
    } else {
        NSDictionary *identity = [self.registry deletionIdentityForContainer:journal[@"oldId"] error:error];
        if (![identity isEqual:RBXAppDeletionTargetIdentity(RBXAppReplacementJournalDescriptor(journal), journal[@"oldId"])]) {
            if (error && !*error) *error = profileError ?: RBXReplacementError(@"Original replacement owner cannot be proven from its profile or deletion journal"); return NO;
        }
    }
    return [self.registry deleteContainer:journal[@"oldId"] error:error];
}
@end

@implementation RBXReplacement
+ (NSString *)replaceContainer:(NSString *)container registry:(RBXContainerRegistry *)registry
    proxies:(RBXProxyManager *)proxies context:(RBXOperationContext *)context error:(NSError **)error {
    if (!context || context.inspectionOnly || ![context check:error]) {
        if (error && !*error) *error = RBXReplacementError(@"Replacement needs a live mutation owner"); return nil;
    }
    RBXDeviceReplacementBackend *backend = [RBXDeviceReplacementBackend new];
    backend.registry = registry; backend.proxies = proxies; backend.context = context;
    return RBXRunReplacement(container, backend, error);
}
+ (NSDictionary *)replacementStateForContainer:(NSString *)container error:(NSError **)error {
    NSDictionary *journals = RBXReplacementJournals(error);
    if (!journals) return nil;
    // An original may itself have been a committed candidate in an older chain.
    if (journals[container]) return journals[container];
    for (NSDictionary *journal in journals.allValues) if ([journal[@"newId"] isEqual:container]) return journal;
    return nil;
}
+ (BOOL)launchAllowedForContainer:(NSString *)container error:(NSError **)error {
    NSError *failure = nil;
    NSDictionary *journals = RBXReplacementJournals(&failure);
    if (!journals) { if (error) *error = failure; return NO; }
    for (NSDictionary *journal in journals.allValues) {
        BOOL candidate = [journal[@"newId"] isEqual:container];
        BOOL original = [journal[@"oldId"] isEqual:container];
        if ((candidate && ![journal[@"phase"] isEqual:@"committed"]) ||
            (original && [@[@"deleting", @"committed"] containsObject:journal[@"phase"]])) {
            if (error) *error = RBXReplacementError(@"This profile belongs to a pending replacement or is retired; retry replacement from the original row");
            return NO;
        }
    }
    return YES;
}
+ (BOOL)userDeletionAllowedForContainer:(NSString *)container error:(NSError **)error {
    NSDictionary *journals = RBXReplacementJournals(error);
    return journals && RBXReplacementMutationAllowed(journals, container, RBXReplacementUserDelete, error);
}
@end
#endif
