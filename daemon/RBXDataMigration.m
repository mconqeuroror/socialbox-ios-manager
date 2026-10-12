#import "RBXDataMigration.h"
#import "RBXDataSchema.h"
#import "RBXProfileIO.h"
#import "RBXAppLifecycle.h"

@implementation RBXDataMigration
+ (NSString *)_preferencesRoot { return @"/var/mobile/Library/Preferences"; }
+ (NSString *)_applicationRoot { return @"/var/mobile/Library/RedditBox"; }
+ (NSDictionary *)currentVersions {
    return @{@"store": @(RBX_STORE_SCHEMA_VERSION), @"profile": @(RBX_PROFILE_SCHEMA_VERSION),
        @"deletionJournal": @1, @"cloneTransaction": @2,
        @"appRecoveryVersions": @{@"reddit":@{@"deletionJournal":@1,@"cloneTransaction":@2},
                                  @"facebook":@{@"deletionJournal":@2,@"cloneTransaction":@3}}};
}
+ (NSArray *)_entries:(NSString *)path error:(NSError **)error {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno == ENOENT) return @[];
        if (error) *error = RBXSchemaError(@"Data directory cannot be inspected; migration did not start");
        return nil;
    }
    if (!S_ISDIR(info.st_mode)) {
        if (error) *error = RBXSchemaError(@"Data directory is unsafe; migration did not start");
        return nil;
    }
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:error];
    return [entries sortedArrayUsingSelector:@selector(compare:)];
}
+ (BOOL)_addPath:(NSString *)path kind:(NSString *)kind identifier:(NSString *)identifier
        toRecords:(NSMutableArray *)records error:(NSError **)error {
    BOOL missing = NO;
    NSData *data = RBXSchemaReadBytes(path, &missing, error);
    if (missing) return YES;
    if (!data) return NO;
    NSDictionary *document = nil;
    if ([kind isEqual:@"store"]) document = RBXSchemaDecode(data, RBXDataStore, error);
    else if ([kind isEqual:@"profile"])
        document = [RBXProfileIO profileDictionaryFromData:data containerId:identifier error:error];
    else {
        id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
        if ([kind isEqual:@"retired"]) {
            if (![value isKindOfClass:NSArray.class]) {
                if (error) *error = RBXSchemaError(@"Retired container registry is corrupt; retain it for recovery");
                return NO;
            }
            for (id entry in value) if (![RBXProfileIO isSafeContainerIdentifier:entry]) {
                if (error) *error = RBXSchemaError(@"Retired container registry contains an invalid identity; retain it");
                return NO;
            }
            [records addObject:@{@"path":path, @"kind":kind, @"bytes":data}]; return YES;
        }
        // Recovery format support is independent of runtime admission. A
        // disabled app can still have valid committed or interrupted journals.
        NSDictionary *owner = [kind isEqual:@"clone"] ? RBXAppInstallationRecordDescriptor(value)
            : ([kind isEqual:@"deletion"] ? RBXAppDeletionJournalDescriptor(value) : nil);
        BOOL extended = owner && ![owner[@"appType"] isEqual:@"reddit"];
        if (([kind isEqual:@"clone"] || [kind isEqual:@"deletion"]) &&
            [value isKindOfClass:NSDictionary.class] && value[@"appType"] &&
            ![value[@"appType"] isEqual:@"reddit"] && !owner) {
            if(error)*error=RBXSchemaError(@"Recovery app ownership is invalid; original bytes retained");
            return NO;
        }
        NSInteger supported = [kind isEqual:@"clone"] ? (extended ? 3 : 2) : (extended ? 2 : 1);
        if (![value isKindOfClass:NSDictionary.class] ||
            !RBXSchemaReadVersion(value, @"formatVersion", supported, NO, error)) {
            if (error && !*error) *error = RBXSchemaError(@"Recovery journal is corrupt; retain it without migration");
            return NO;
        }
        if ([kind isEqual:@"clone"] && [value[@"formatVersion"] integerValue] != supported) {
            // Version 1 did not record the install-attempt boundary needed for
            // safe rollback. Do not invent that missing recovery evidence.
            if (error) *error = RBXSchemaError(@"Legacy clone transaction lacks safe rollback phases; retained for manual recovery");
            return NO;
        }
        if ((![kind isEqual:@"capture"] && ![RBXProfileIO isSafeContainerIdentifier:value[@"containerId"]]) ||
            ([kind isEqual:@"capture"] && (![value[@"bundleIdentifier"] isKindOfClass:NSString.class] || ![value[@"state"] isEqual:@"captured"])) ||
            ([kind isEqual:@"deletion"] && (![identifier isEqual:value[@"containerId"]] ||
              ![@[@"prepared", @"keychain-cleared", @"uninstalled", @"cleanup-complete", @"committed"] containsObject:value[@"phase"]] ||
              ![value[@"target"] isKindOfClass:NSDictionary.class])) ||
            ([kind isEqual:@"clone"] && (![value[@"bundleIdentifier"] isKindOfClass:NSString.class] ||
              ![@[@"prepared", @"install-attempted", @"installed", @"committed"] containsObject:value[@"state"]]))) {
            if (error) *error = RBXSchemaError(@"Recovery journal has invalid ownership or phase; retain it for recovery");
            return NO;
        }
        if ([kind isEqual:@"deletion"] &&
            (!RBXSchemaReadVersion(value[@"target"], @"formatVersion", extended ? 2 : 1, NO, error) ||
             ![value[@"target"][@"containerId"] isEqual:identifier])) {
            if (error && !*error) *error = RBXSchemaError(@"Deletion target has invalid ownership; retained for recovery");
            return NO;
        }
        for (NSString *key in @[@"profileEvidence", @"finalProfileEvidence"]) {
            if (!value[key]) continue;
            if (![value[key] isKindOfClass:NSData.class]) {
                if (error) *error = RBXSchemaError(@"Recovery evidence is not retained as bytes");
                return NO;
            }
            // H05 intentionally retains malformed live profile bytes so explicit
            // cleanup can recover them. Never reinterpret/reconstruct evidence.
            id embedded = [NSJSONSerialization JSONObjectWithData:value[key] options:0 error:nil];
            if ([embedded isKindOfClass:NSDictionary.class] && RBXSchemaInteger(embedded[@"profileVersion"]) &&
                [embedded[@"profileVersion"] integerValue] > RBX_PROFILE_SCHEMA_VERSION) {
                RBXSchemaReadVersion(embedded, @"profileVersion", RBX_PROFILE_SCHEMA_VERSION, YES, error);
                return NO;
            }
        }
        document = value;
    }
    if (!document) return NO;
    [records addObject:@{@"path":path, @"kind":kind, @"bytes":data, @"document":document}];
    return YES;
}
+ (NSArray *)_preflight:(NSError **)error {
    NSMutableArray *records = [NSMutableArray array];
    NSString *prefs = [self _preferencesRoot], *application = [self _applicationRoot];
    if (![self _addPath:[prefs stringByAppendingPathComponent:@"com.redditbox.store.json"]
        kind:@"store" identifier:nil toRecords:records error:error]) return nil;
    NSString *profiles = [prefs stringByAppendingPathComponent:@"com.redditbox.profiles"];
    NSArray *entries = [self _entries:profiles error:error]; if (!entries) return nil;
    for (NSString *entry in entries) if ([entry.pathExtension isEqual:@"json"] &&
        ![self _addPath:[profiles stringByAppendingPathComponent:entry] kind:@"profile"
            identifier:entry.stringByDeletingPathExtension toRecords:records error:error]) return nil;
    if (![self _addPath:[prefs stringByAppendingPathComponent:@"com.redditbox.deleted-containers.plist"]
        kind:@"retired" identifier:nil toRecords:records error:error]) return nil;
    NSString *deletions = [application stringByAppendingPathComponent:@"deletions"];
    entries = [self _entries:deletions error:error]; if (!entries) return nil;
    for (NSString *entry in entries) if ([entry.pathExtension isEqual:@"plist"] &&
        ![self _addPath:[deletions stringByAppendingPathComponent:entry] kind:@"deletion"
            identifier:entry.stringByDeletingPathExtension toRecords:records error:error]) return nil;
    NSString *transactions = [application stringByAppendingPathComponent:@"transactions"];
    entries = [self _entries:transactions error:error]; if (!entries) return nil;
    for (NSString *entry in entries) {
        if ([entry isEqual:@".lock"]) continue;
        NSString *directory = [transactions stringByAppendingPathComponent:entry];
        struct stat info;
        if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode)) {
            if (error) *error = RBXSchemaError(@"Clone transaction directory is unsafe; migration did not start");
            return nil;
        }
        if ([entry isEqual:@"uninstall-evidence"]) {
            NSArray *captures = [self _entries:directory error:error]; if (!captures) return nil;
            for (NSString *capture in captures) {
                NSString *captureRoot = [directory stringByAppendingPathComponent:capture];
                if (![self _entries:captureRoot error:error] ||
                    ![self _addPath:[captureRoot stringByAppendingPathComponent:@"transaction.plist"]
                        kind:@"capture" identifier:nil toRecords:records error:error]) return nil;
            }
            continue;
        }
        if (![self _addPath:[directory stringByAppendingPathComponent:@"transaction.plist"]
            kind:@"clone" identifier:nil toRecords:records error:error]) return nil;
    }
    return records;
}
+ (BOOL)_publishDocument:(NSDictionary *)document record:(NSDictionary *)record error:(NSError **)error {
    return RBXSchemaWriteJSONExpected(document, record[@"path"],
        [record[@"kind"] isEqual:@"store"] ? RBXDataStore : RBXDataProfile, record[@"bytes"], error);
}
+ (BOOL)preflightAndMigrateWithError:(NSError **)error {
    // No creates, defaults, backups, notifications or cleanup in this pass.
    NSArray *records = [self _preflight:error];
    if (!records) return NO;
    for (NSDictionary *record in records) {
        BOOL store = [record[@"kind"] isEqual:@"store"];
        if (!store && ![record[@"kind"] isEqual:@"profile"]) continue;
        NSString *versionKey = store ? @"storeVersion" : @"profileVersion";
        NSDictionary *document = record[@"document"];
        if ([document[versionKey] integerValue] == 2) continue;
        // Repeat the read-only global check before every publication, including
        // files introduced by another writer since the initial preflight.
        if (![self _preflight:error]) return NO;
        NSDictionary *next = RBXSchemaMigrate(document, store ? RBXDataStore : RBXDataProfile, error);
        if (!next || ![self _publishDocument:next record:record error:error]) return NO;
    }
    return [self _preflight:error] != nil;
}
@end
