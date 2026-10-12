#import "LBXContainerStore.h"
#import "LBXHelperClient.h"
#import "../Switching/LBXSocialBoxProduct.h"

NSString *const LBXContainerStoreInstagram = @"com.burbn.instagram";
NSString *const LBXContainerStoreFacebook = @"com.facebook.Facebook";

static NSError *LBXStoreError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"com.socialbox.container-store" code:code
                           userInfo:@{NSLocalizedDescriptionKey : message ?: @"store error"}];
}

@implementation LBXContainerRecord
@end

@implementation LBXContainerStore

- (NSString *)controlRoot {
    return @LBX_SOCIALBOX_CONTROL_CONTAINERS;
}

- (NSString *)profileStoreRoot {
    return [@"/var/jb/var/mobile/Library" stringByAppendingPathComponent:@LBX_SOCIALBOX_PROFILE_STORE];
}

- (NSString *)runtimeRoot {
    return @LBX_SOCIALBOX_CONTROL_RUNTIME;
}

- (NSString *)globalMetadataPath {
    return [self.controlRoot stringByAppendingPathComponent:@"global_metadata.plist"];
}

- (NSString *)appMetadataPath:(NSString *)bundleID {
    return [[self.controlRoot stringByAppendingPathComponent:bundleID]
        stringByAppendingPathComponent:@"metadata.plist"];
}

- (NSString *)controlPathForBundleID:(NSString *)bundleID containerID:(long long)containerID {
    return [[self.controlRoot stringByAppendingPathComponent:bundleID]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", containerID]];
}

- (NSString *)profilePathForContainerID:(long long)containerID {
    return [self.profileStoreRoot
        stringByAppendingPathComponent:[NSString stringWithFormat:@"%lld", containerID]];
}

- (NSDictionary *)readPlist:(NSString *)path {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return @{};
    id obj = [NSDictionary dictionaryWithContentsOfFile:path];
    return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

- (BOOL)writePlist:(NSDictionary *)plist path:(NSString *)path error:(NSError **)error {
    NSString *parent = path.stringByDeletingLastPathComponent;
    NSError *local = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:parent
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&local]) {
        if (error) *error = local ?: LBXStoreError(500, @"mkdir failed");
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:&local];
    if (!data) {
        if (error) *error = local ?: LBXStoreError(500, @"plist serialize failed");
        return NO;
    }
    if (![data writeToFile:path options:NSDataWritingAtomic error:&local]) {
        if (error) *error = local ?: LBXStoreError(500, @"plist write failed");
        return NO;
    }
    return YES;
}

- (LBXContainerRecord *)recordFromDictionary:(NSDictionary *)row {
    if (![row isKindOfClass:NSDictionary.class]) return nil;
    long long cid = [row[@"id"] ?: row[@"containerID"] longLongValue];
    if (cid < 1) return nil;
    LBXContainerRecord *record = [LBXContainerRecord new];
    record.containerID = cid;
    NSString *name = row[@"name"];
    record.name = [name isKindOfClass:NSString.class] && name.length
                      ? name
                      : [NSString stringWithFormat:@"Container %lld", cid];
    NSArray *apps = row[@"apps"];
    if (![apps isKindOfClass:NSArray.class] || apps.count == 0) {
        apps = @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
    }
    record.apps = apps;
    return record;
}

- (NSDictionary *)dictionaryFromRecord:(LBXContainerRecord *)record {
    return @{
        @"id" : @(record.containerID),
        @"containerID" : @(record.containerID),
        @"name" : record.name ?: [NSString stringWithFormat:@"Container %lld", record.containerID],
        @"apps" : record.apps ?: @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ],
    };
}

- (NSArray<LBXContainerRecord *> *)listContainers:(NSError **)error {
    (void)error;
    NSDictionary *global = [self readPlist:self.globalMetadataPath];
    NSArray *rows = global[@"containers"];
    NSMutableArray<LBXContainerRecord *> *out = [NSMutableArray array];
    if ([rows isKindOfClass:NSArray.class]) {
        for (id row in rows) {
            LBXContainerRecord *record = [self recordFromDictionary:row];
            if (record) [out addObject:record];
        }
    }
    // Also discover numeric CID directories under the profile store.
    NSArray *names =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.profileStoreRoot error:nil];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (LBXContainerRecord *record in out) [seen addObject:@(record.containerID)];
    for (NSString *name in names) {
        if (name.length == 0 || [name hasPrefix:@"."]) continue;
        long long cid = name.longLongValue;
        if (cid < 1 || [seen containsObject:@(cid)]) continue;
        LBXContainerRecord *record = [LBXContainerRecord new];
        record.containerID = cid;
        record.name = [NSString stringWithFormat:@"Container %lld", cid];
        record.apps = @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
        [out addObject:record];
        [seen addObject:@(cid)];
    }
    [out sortUsingComparator:^NSComparisonResult(LBXContainerRecord *a, LBXContainerRecord *b) {
        if (a.containerID < b.containerID) return NSOrderedAscending;
        if (a.containerID > b.containerID) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

- (LBXContainerRecord *)containerWithID:(long long)containerID error:(NSError **)error {
    for (LBXContainerRecord *record in [self listContainers:error]) {
        if (record.containerID == containerID) return record;
    }
    if (error) *error = LBXStoreError(404, @"container not found");
    return nil;
}

- (long long)activeContainerIDForBundleID:(NSString *)bundleID error:(NSError **)error {
    (void)error;
    NSDictionary *meta = [self readPlist:[self appMetadataPath:bundleID]];
    long long active = [meta[@"activeContainer"] longLongValue];
    if (active > 0) return active;
    NSDictionary *global = [self readPlist:self.globalMetadataPath];
    return [global[@"activeContainer"] longLongValue];
}

- (BOOL)setActiveContainerID:(long long)containerID
                 forBundleID:(NSString *)bundleID
                       error:(NSError **)error {
    NSMutableDictionary *meta = [[self readPlist:[self appMetadataPath:bundleID]] mutableCopy];
    if (!meta) meta = [NSMutableDictionary dictionary];
    meta[@"activeContainer"] = @(containerID);
    NSMutableArray *ids = [NSMutableArray array];
    for (LBXContainerRecord *record in [self listContainers:nil]) {
        if ([record.apps containsObject:bundleID]) [ids addObject:@(record.containerID)];
    }
    if (containerID > 0 && ![ids containsObject:@(containerID)]) [ids addObject:@(containerID)];
    meta[@"containers"] = ids;
    return [self writePlist:meta path:[self appMetadataPath:bundleID] error:error];
}

- (BOOL)setGlobalActiveContainerID:(long long)containerID error:(NSError **)error {
    NSMutableDictionary *global = [[self readPlist:self.globalMetadataPath] mutableCopy];
    if (!global) global = [NSMutableDictionary dictionary];
    global[@"activeContainer"] = @(containerID);
    NSMutableArray *rows = [NSMutableArray array];
    for (LBXContainerRecord *record in [self listContainers:nil]) {
        [rows addObject:[self dictionaryFromRecord:record]];
    }
    global[@"containers"] = rows;
    return [self writePlist:global path:self.globalMetadataPath error:error];
}

- (long long)nextContainerID:(NSError **)error {
    long long maxID = 0;
    for (LBXContainerRecord *record in [self listContainers:error]) {
        if (record.containerID > maxID) maxID = record.containerID;
    }
    return maxID + 1;
}

- (BOOL)upsertContainer:(LBXContainerRecord *)record error:(NSError **)error {
    if (!record || record.containerID < 1) {
        if (error) *error = LBXStoreError(400, @"invalid container record");
        return NO;
    }
    NSMutableDictionary *global = [[self readPlist:self.globalMetadataPath] mutableCopy];
    if (!global) global = [NSMutableDictionary dictionary];
    NSMutableArray *rows = [NSMutableArray array];
    BOOL replaced = NO;
    NSArray *existing = global[@"containers"];
    if ([existing isKindOfClass:NSArray.class]) {
        for (id row in existing) {
            LBXContainerRecord *old = [self recordFromDictionary:row];
            if (old && old.containerID == record.containerID) {
                [rows addObject:[self dictionaryFromRecord:record]];
                replaced = YES;
            } else if (old) {
                [rows addObject:[self dictionaryFromRecord:old]];
            }
        }
    }
    if (!replaced) [rows addObject:[self dictionaryFromRecord:record]];
    global[@"containers"] = rows;
    if (![self writePlist:global path:self.globalMetadataPath error:error]) return NO;

    for (NSString *bundleID in record.apps) {
        NSMutableDictionary *meta = [[self readPlist:[self appMetadataPath:bundleID]] mutableCopy];
        if (!meta) meta = [NSMutableDictionary dictionary];
        NSMutableArray *ids = [NSMutableArray array];
        NSArray *prev = meta[@"containers"];
        if ([prev isKindOfClass:NSArray.class]) {
            for (id value in prev) {
                long long cid = [value longLongValue];
                if (cid > 0 && ![ids containsObject:@(cid)]) [ids addObject:@(cid)];
            }
        }
        if (![ids containsObject:@(record.containerID)]) [ids addObject:@(record.containerID)];
        meta[@"containers"] = ids;
        if (![self writePlist:meta path:[self appMetadataPath:bundleID] error:error]) return NO;
    }
    return YES;
}

- (BOOL)renameContainerID:(long long)containerID toName:(NSString *)name error:(NSError **)error {
    NSString *trimmed =
        [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || trimmed.length > 64) {
        if (error) *error = LBXStoreError(400, @"name must be 1-64 characters");
        return NO;
    }
    LBXContainerRecord *record = [self containerWithID:containerID error:error];
    if (!record) return NO;
    record.name = trimmed;
    return [self upsertContainer:record error:error];
}

- (BOOL)activateContainerID:(long long)containerID
               forBundleIDs:(NSArray<NSString *> *)bundleIDs
                     helper:(LBXHelperClient *)helper
                      error:(NSError **)error {
    if (![self containerWithID:containerID error:error]) return NO;
    NSArray<NSString *> *phone = @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ];
    (void)bundleIDs;
    long long from = [self activeContainerIDForBundleID:LBXContainerStoreInstagram error:nil];
    if (from < 1) from = [self activeContainerIDForBundleID:LBXContainerStoreFacebook error:nil];
    if (from < 0) from = 0;
    NSError *local = nil;
    if (![helper switchPhoneFromContainer:from toContainer:containerID error:&local]) {
        if (error)
            *error = LBXStoreError(500, local.localizedDescription ?: @"phone switch failed");
        return NO;
    }
    for (NSString *bundleID in phone) {
        if (![self setActiveContainerID:containerID forBundleID:bundleID error:error]) return NO;
        if (![self writeRuntimeSelection:containerID forBundleID:bundleID error:error]) return NO;
    }
    return [self setGlobalActiveContainerID:containerID error:error];
}

- (BOOL)deleteContainerID:(long long)containerID helper:(LBXHelperClient *)helper error:(NSError **)error {
    if (containerID < 1) {
        if (error) *error = LBXStoreError(400, @"invalid container id");
        return NO;
    }
    long long ig = [self activeContainerIDForBundleID:LBXContainerStoreInstagram error:nil];
    long long fb = [self activeContainerIDForBundleID:LBXContainerStoreFacebook error:nil];
    if (containerID == ig || containerID == fb) {
        if (error) *error = LBXStoreError(400, @"switch away from this container before deleting it");
        return NO;
    }
    if (![self containerWithID:containerID error:error]) return NO;
    NSError *local = nil;
    if (![helper deleteContainerStorage:containerID error:&local]) {
        if (error) *error = LBXStoreError(500, local.localizedDescription ?: @"delete storage failed");
        return NO;
    }
    for (NSString *bundleID in @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ]) {
        if (![helper teardownBundleID:bundleID containerID:containerID error:&local]) {
            if (error) *error = LBXStoreError(500, local.localizedDescription ?: @"teardown failed");
            return NO;
        }
    }

    NSMutableDictionary *global = [[self readPlist:self.globalMetadataPath] mutableCopy];
    if (!global) global = [NSMutableDictionary dictionary];
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *existing = global[@"containers"];
    if ([existing isKindOfClass:NSArray.class]) {
        for (id row in existing) {
            LBXContainerRecord *old = [self recordFromDictionary:row];
            if (old && old.containerID != containerID) [rows addObject:[self dictionaryFromRecord:old]];
        }
    }
    global[@"containers"] = rows;
    if (![self writePlist:global path:self.globalMetadataPath error:error]) return NO;

    for (NSString *bundleID in @[ LBXContainerStoreInstagram, LBXContainerStoreFacebook ]) {
        NSMutableDictionary *meta = [[self readPlist:[self appMetadataPath:bundleID]] mutableCopy];
        if (!meta) continue;
        NSMutableArray *ids = [NSMutableArray array];
        NSArray *prev = meta[@"containers"];
        if ([prev isKindOfClass:NSArray.class]) {
            for (id value in prev) {
                long long cid = [value longLongValue];
                if (cid > 0 && cid != containerID && ![ids containsObject:@(cid)]) [ids addObject:@(cid)];
            }
        }
        meta[@"containers"] = ids;
        if (![self writePlist:meta path:[self appMetadataPath:bundleID] error:error]) return NO;
    }
    return YES;
}

- (BOOL)writeRuntimeSelection:(long long)containerID
                  forBundleID:(NSString *)bundleID
                        error:(NSError **)error {
    NSString *path = [self.runtimeRoot
        stringByAppendingPathComponent:[bundleID stringByAppendingString:@".plist"]];
    NSDictionary *plist = @{
        @"activeContainer" : @(containerID),
        @"bundleIdentifier" : bundleID ?: @"",
        @"updatedAt" : @(NSDate.date.timeIntervalSince1970),
    };
    return [self writePlist:plist path:path error:error];
}

- (NSDictionary *)verifyIsolationForBundleID:(NSString *)bundleID
                                 containerID:(long long)containerID {
    NSString *profile = [self profilePathForContainerID:containerID];
    NSString *control = [self controlPathForBundleID:bundleID containerID:containerID];
    NSString *prefs = [profile stringByAppendingPathComponent:@"Library/Preferences"];
    NSString *controlPrefs = [control stringByAppendingPathComponent:@"Library/Preferences"];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL profileOK = [fm fileExistsAtPath:profile];
    BOOL controlOK = [fm fileExistsAtPath:control];
    BOOL prefsOK = [fm fileExistsAtPath:prefs];
    BOOL controlPrefsOK = [fm fileExistsAtPath:controlPrefs];
    long long active = [self activeContainerIDForBundleID:bundleID error:nil];
    BOOL selectionOK = (active == containerID);
    NSString *agrp = [NSString stringWithFormat:@"%%.%s.%lld", LBX_SOCIALBOX_KEYCHAIN_TOKEN, containerID];
    BOOL treesPass = profileOK && controlOK;
    BOOL prefsPass = prefsOK && controlPrefsOK;
    // Sandbox redirect + keychain agrp rewrite require Securityd/CfPrefsd inject
    // dylibs, which are intentionally omitted until a clean source rebuild exists.
    return @{
        @"bundleID" : bundleID ?: @"",
        @"containerID" : @(containerID),
        @"agrpPattern" : agrp,
        @"layer1_trees" : @{
            @"pass" : @(treesPass),
            @"profileStore" : profile ?: @"",
            @"controlPath" : control ?: @"",
            @"profileExists" : @(profileOK),
            @"controlExists" : @(controlOK),
        },
        @"layer2_prefs" : @{
            @"pass" : @(prefsPass),
            @"profilePrefs" : prefs ?: @"",
            @"controlPrefs" : controlPrefs ?: @"",
            @"profilePrefsExists" : @(prefsOK),
            @"controlPrefsExists" : @(controlPrefsOK),
        },
        @"selection" : @{
            @"pass" : @(selectionOK),
            @"activeContainer" : @(active),
            @"expected" : @(containerID),
        },
        @"keychain" : @{
            @"pass" : @NO,
            @"status" : @"SKIPPED",
            @"reason" : @"Securityd inject omitted until clean source rebuild",
        },
        @"sandboxRedirect" : @{
            @"pass" : @NO,
            @"status" : @"SKIPPED",
            @"reason" : @"CfPrefsd/Containermanagerd inject omitted until clean source rebuild",
        },
        @"pass" : @(treesPass && prefsPass),
        @"isolationVerified" : @NO,
        @"honestGap" : @"Legacy tree check only. Use verifyDataSeparationForContainerID.",
    };
}

- (NSDictionary *)verifyDataSeparationForContainerID:(long long)containerID helper:(LBXHelperClient *)helper {
    long long ig = [self activeContainerIDForBundleID:LBXContainerStoreInstagram error:nil];
    long long fb = [self activeContainerIDForBundleID:LBXContainerStoreFacebook error:nil];
    BOOL selectionOK = (ig == containerID && fb == containerID);
    NSDictionary *physical = @{};
    if (helper) {
        NSDictionary *report = [helper dataSeparationReportForContainer:containerID error:nil];
        if ([report isKindOfClass:NSDictionary.class]) physical = report;
    }
    long long loadedIG = [physical[@"loadedInstagram"] longLongValue];
    long long loadedFB = [physical[@"loadedFacebook"] longLongValue];
    long long loadedShared = [physical[@"loadedShared"] longLongValue];
    BOOL liveOK = [physical[@"instagramLive"] length] > 0 && [physical[@"facebookLive"] length] > 0;
    BOOL loadedOK = (loadedIG == containerID && loadedFB == containerID);
    BOOL sharedOK = (loadedShared == containerID) || (loadedShared < 0 && selectionOK);
    BOOL parkedOK = [physical[@"phoneLoadedHere"] boolValue] || [physical[@"parkedSlotPresent"] boolValue];
    BOOL pass = selectionOK && loadedOK && sharedOK && liveOK && parkedOK;
    return @{
        @"containerID" : @(containerID),
        @"selection" : @{
            @"pass" : @(selectionOK),
            @"instagram" : @(ig),
            @"facebook" : @(fb),
        },
        @"loaded" : @{
            @"pass" : @(loadedOK),
            @"instagram" : @(loadedIG),
            @"facebook" : @(loadedFB),
            @"shared" : @(loadedShared),
        },
        @"sharedFolders" : @{
            @"pass" : @(sharedOK),
            @"groups" : physical[@"sharedGroupsPresent"] ?: @[],
            @"pluginKit" : physical[@"pluginKitPresent"] ?: @[],
            @"unitWithApps" : @(loadedShared == containerID || (loadedShared < 0 && loadedOK)),
        },
        @"liveRoots" : @{
            @"pass" : @(liveOK),
            @"instagram" : physical[@"instagramLive"] ?: @"",
            @"facebook" : physical[@"facebookLive"] ?: @"",
        },
        @"slots" : @{
            @"pass" : @(parkedOK),
            @"instagram" : physical[@"instagramSlotPresent"] ?: @NO,
            @"facebook" : physical[@"facebookSlotPresent"] ?: @NO,
            @"shared" : physical[@"sharedSlotPresent"] ?: @NO,
            @"phoneLoadedHere" : physical[@"phoneLoadedHere"] ?: @NO,
        },
        @"keychain" : physical[@"keychain"] ?: @{
            @"separated" : @NO,
            @"status" : @"NOT_SEPARATED",
        },
        @"pass" : @(pass),
        @"isolationVerified" : @NO,
        @"honestGap" : @"Data-container + shared-folder swap only. Keychain is not partitioned.",
    };
}

@end
