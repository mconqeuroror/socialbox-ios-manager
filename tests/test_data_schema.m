#import <Foundation/Foundation.h>
#import "RBXDataSchema.h"
#import "RBXAppLifecycle.h"
#import "RBXProfileIO.h"
#import "RBXDataMigration.h"
#import "RBXCentralStore.h"

@interface RBXDataMigration (Fixture)
+ (NSString *)_preferencesRoot;
+ (NSString *)_applicationRoot;
+ (BOOL)_publishDocument:(NSDictionary *)document record:(NSDictionary *)record error:(NSError **)error;
@end
static NSString *fixtureRoot;
static NSInteger publicationCount, failPublication;
@interface RBXFixtureMigration : RBXDataMigration @end
@implementation RBXFixtureMigration
+ (NSString *)_preferencesRoot { return [fixtureRoot stringByAppendingPathComponent:@"prefs"]; }
+ (NSString *)_applicationRoot { return [fixtureRoot stringByAppendingPathComponent:@"app"]; }
+ (BOOL)_publishDocument:(NSDictionary *)document record:(NSDictionary *)record error:(NSError **)error {
    if (++publicationCount == failPublication) {
        if (error) *error = RBXSchemaError(@"Injected interruption before publication");
        return NO;
    }
    return [super _publishDocument:document record:record error:error];
}
@end
static void Check(BOOL value, NSString *message) {
    if (!value) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSString *StorePath(void) {
    return [[RBXFixtureMigration _preferencesRoot] stringByAppendingPathComponent:@"com.redditbox.store.json"];
}
@interface RBXFixtureStore : RBXCentralStore @end
@implementation RBXFixtureStore
+ (NSString *)storePath { return StorePath(); }
@end
static NSString *ProfilePath(NSString *identifier) {
    return [[[RBXFixtureMigration _preferencesRoot] stringByAppendingPathComponent:@"com.redditbox.profiles"]
        stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];
}
static NSData *Bytes(NSString *path) { return [NSData dataWithContentsOfFile:path]; }
static void WriteJSON(NSDictionary *document, NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    Check([[NSJSONSerialization dataWithJSONObject:document options:0 error:nil] writeToFile:path atomically:YES], @"fixture JSON write");
}
static void WritePlist(id document, NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    Check([data writeToFile:path atomically:YES], @"fixture plist write");
}
static NSDictionary *Profile(NSInteger version, NSString *identifier) {
    return @{@"profileVersion":@(version), @"containerId":identifier,
        @"device":@{@"productType":@"iPhone14,5"}, @"serials":@{@"udid":[@"udid-" stringByAppendingString:identifier]},
        @"ids":@{@"idfv":[@"idfv-" stringByAppendingString:identifier]}, @"reddit":@{@"installId":identifier},
        @"proxy":@{@"url":@"http://proxy.example:8080"}, @"name":@"Existing name",
        @"role":@"warmup", @"notes":@"Keep this note", @"metadataRevision":@7,
        @"metadataDirty":@YES, @"opaqueFutureExtension":@{@"keep":@YES}};
}
static void FreshFixture(void) {
    fixtureRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"rbx-schema-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    publicationCount = 0; failPublication = -1;
    NSMutableDictionary *containers = [NSMutableDictionary dictionary];
    for (NSInteger index = 0; index < 5; index++) {
        NSString *identifier = [NSString stringWithFormat:@"existing-%ld", (long)index];
        WriteJSON(Profile(1, identifier), ProfilePath(identifier));
        containers[identifier] = @{@"nickname":identifier, @"username":@"saved-login", @"lastIP":@"203.0.113.1"};
    }
    WriteJSON(@{@"storeVersion":@1, @"containers":containers, @"device":@{@"attestKeysUsed":@[]},
        @"identityReservations":@{@"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef":@"existing-0"},
        @"replacements":@{@"retired-old":@{@"formatVersion":@1, @"oldId":@"retired-old", @"newId":@"existing-0", @"phase":@"committed"}},
        @"cloudBinding":@{@"deviceId":@"keep-pairing"}, @"unknown":@[@1,@2,@3]}, StorePath());
}
static void Cleanup(void) { [NSFileManager.defaultManager removeItemAtPath:fixtureRoot error:nil]; }

int main(void) { @autoreleasepool {
    NSError *error = nil;
    // Inactive applications still own retained recovery records. Accept only
    // their exact registered versions/identities; never loosen Reddit limits.
    for (NSString *kind in @[@"clone",@"deletion",@"replacement"]) {
      for (NSString *variation in @[@"valid",@"future",@"unknown-owner",@"foreign-group",@"missing-owner"]) {
        FreshFixture();
        NSDictionary *fb=RBXAppDescriptorForType(@"facebook");
        NSMutableDictionary *record=nil;NSString *recordPath=nil;
        if([kind isEqual:@"clone"]){
          record=[RBXAppInstallationRecord(fb,@"fb-retired") mutableCopy];record[@"hadPreviousInstall"]=@NO;record[@"state"]=@"committed";
          recordPath=[[RBXFixtureMigration _applicationRoot] stringByAppendingPathComponent:@"transactions/fb-transaction/transaction.plist"];
        }else if([kind isEqual:@"deletion"]){
          record=[RBXAppDeletionJournalIdentity(RBXAppDeletionTargetIdentity(fb,@"fb-retired")) mutableCopy];record[@"phase"]=@"committed";
          recordPath=[[RBXFixtureMigration _applicationRoot] stringByAppendingPathComponent:@"deletions/fb-retired.plist"];
        }else{
          record=[RBXAppReplacementJournalIdentity(fb,@"fb-retired",@"fb-new") mutableCopy];record[@"phase"]=@"committed";recordPath=StorePath();
        }
        if([variation isEqual:@"future"])record[@"formatVersion"]=@99;
        if([variation isEqual:@"unknown-owner"])record[@"appType"]=@"unknown";
        if([variation isEqual:@"missing-owner"])[record removeObjectForKey:@"appType"];
        if([variation isEqual:@"foreign-group"]){
          if([kind isEqual:@"clone"])record[@"keychainAccessGroup"]=@"foreign";
          else {NSString *key=[kind isEqual:@"deletion"]?@"target":@"newTarget";NSMutableDictionary *target=[record[key] mutableCopy];target[@"keychainAccessGroup"]=@"foreign";record[key]=target;}
        }
        if([kind isEqual:@"replacement"]){NSMutableDictionary *store=[[NSJSONSerialization JSONObjectWithData:Bytes(StorePath()) options:0 error:nil] mutableCopy];store[@"replacements"]=@{@"fb-retired":record};WriteJSON(store,StorePath());}
        else WritePlist(record,recordPath);
        NSData *recordBefore=Bytes(recordPath),*storeBefore=Bytes(StorePath());error=nil;
        BOOL ok=[RBXFixtureMigration preflightAndMigrateWithError:&error];
        if([variation isEqual:@"valid"]){
          Check(ok,[@"inactive Facebook record supported: " stringByAppendingString:kind]);
          if(![kind isEqual:@"replacement"])Check([recordBefore isEqual:Bytes(recordPath)],@"valid Facebook journal bytes are never rewritten by preflight");
          else Check([RBXSchemaDecode(Bytes(StorePath()),RBXDataStore,nil)[@"replacements"][@"fb-retired"] isEqual:record],@"Facebook replacement identity preserved");
        }else Check(!ok&&error&&publicationCount==0&&[storeBefore isEqual:Bytes(StorePath())]&&[recordBefore isEqual:Bytes(recordPath)],@"invalid Facebook record rejects before any mutation");
        Cleanup();
      }
    }
    FreshFixture();
    NSDictionary *oldStore = RBXSchemaDecode(Bytes(StorePath()), RBXDataStore, nil);
    NSMutableDictionary *oldProfiles = [NSMutableDictionary dictionary];
    for (NSInteger i = 0; i < 5; i++) {
        NSString *identifier = [NSString stringWithFormat:@"existing-%ld", (long)i];
        oldProfiles[identifier] = RBXSchemaDecode(Bytes(ProfilePath(identifier)), RBXDataProfile, nil);
    }
    Check([RBXFixtureMigration preflightAndMigrateWithError:&error], @"five-profile migration succeeds");
    NSMutableDictionary *expectedStore = [oldStore mutableCopy]; expectedStore[@"storeVersion"] = @2;
    Check([RBXSchemaDecode(Bytes(StorePath()), RBXDataStore, nil) isEqual:expectedStore], @"all store IDs, metadata, bindings, reservations and journals preserved");
    for (NSString *identifier in oldProfiles) {
        NSMutableDictionary *expected = [oldProfiles[identifier] mutableCopy]; expected[@"profileVersion"] = @2;
        Check([RBXSchemaDecode(Bytes(ProfilePath(identifier)), RBXDataProfile, nil) isEqual:expected], @"every profile identity/login/proxy/metadata preserved");
    }
    NSData *currentBytes = Bytes(StorePath()); publicationCount = 0;
    Check([RBXFixtureMigration preflightAndMigrateWithError:&error] && publicationCount == 0 &&
        [currentBytes isEqual:Bytes(StorePath())], @"current schema is a byte-preserving no-op");
    Cleanup();

    // A later profile must veto the earlier store migration before its first write.
    for (NSString *failure in @[@"newer", @"corrupt", @"empty", @"boolean-version", @"bad-section"]) {
        FreshFixture(); NSData *before = Bytes(StorePath()); NSString *path = ProfilePath(@"existing-4");
        if ([failure isEqual:@"newer"]) WriteJSON(Profile(3, @"existing-4"), path);
        else if ([failure isEqual:@"corrupt"]) [@"{" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else if ([failure isEqual:@"empty"]) [[NSData data] writeToFile:path atomically:YES];
        else {
            NSMutableDictionary *bad = [Profile(1, @"existing-4") mutableCopy];
            bad[[failure isEqual:@"boolean-version"] ? @"profileVersion" : @"device"] = @YES;
            WriteJSON(bad, path);
        }
        NSData *badBytes = Bytes(path); error = nil;
        Check(![RBXFixtureMigration preflightAndMigrateWithError:&error] && error && publicationCount == 0,
            [@"all-document preflight rejects " stringByAppendingString:failure]);
        Check([before isEqual:Bytes(StorePath())] && [badBytes isEqual:Bytes(path)], @"rejection preserves original bytes");
        Cleanup();
    }

    for (NSNumber *size in @[@0, @99, @100, @101, @250]) {
        FreshFixture(); NSMutableArray *alerts = [NSMutableArray array];
        for (NSInteger index = 0; index < size.integerValue; index++)
            [alerts addObject:@{@"message":[NSString stringWithFormat:@"alert-%ld", (long)index]}];
        WriteJSON(@{@"storeVersion":@2, @"alerts":alerts}, StorePath());
        RBXFixtureStore *ringStore = [RBXFixtureStore new];
        [ringStore addAlertType:@"NEW FAILURE" containerId:@"existing-0" message:@"newest-alert"];
        NSArray *retainedAlerts = ringStore.alerts;
        Check(retainedAlerts.count == MIN(size.unsignedIntegerValue + 1, (NSUInteger)100) &&
            [retainedAlerts.lastObject[@"message"] isEqual:@"newest-alert"], @"alert cap retains newest diagnostic and bounded count");
        if (size.integerValue > 0) Check([retainedAlerts.firstObject[@"message"] isEqual:
            [NSString stringWithFormat:@"alert-%ld", (long)MAX(0, size.integerValue + 1 - 100)]],
            @"alert cap removes only the oldest overflow in chronological order");
        Cleanup();
    }

    FreshFixture(); failPublication = 3;
    Check(![RBXFixtureMigration preflightAndMigrateWithError:&error], @"injected interruption fails transition");
    failPublication = -1; publicationCount = 0;
    Check([RBXFixtureMigration preflightAndMigrateWithError:&error] && publicationCount == 4, @"restart skips completed files and resumes remaining four profiles");
    Cleanup();

    FreshFixture(); NSString *path = ProfilePath(@"existing-0"); WriteJSON(Profile(3, @"existing-0"), path);
    NSData *before = Bytes(path); error = nil;
    Check(![RBXProfileIO writeProfile:Profile(1,@"existing-0") containerId:@"existing-0" toPath:path error:&error] &&
        [before isEqual:Bytes(path)], @"ordinary ProfileIO writes cannot downgrade future data");
    WriteJSON(@{@"storeVersion":@3}, StorePath()); before = Bytes(StorePath());
    Check(!RBXSchemaWriteJSON(@{@"storeVersion":@1}, StorePath(), RBXDataStore, &error) &&
        [before isEqual:Bytes(StorePath())], @"shared background writers cannot downgrade future store");
    Cleanup();

    FreshFixture(); path = ProfilePath(@"existing-0"); before = Bytes(path);
    WriteJSON(Profile(2,@"existing-0"), path); NSData *changed = Bytes(path);
    Check(!RBXSchemaWriteJSONExpected(Profile(1,@"existing-0"), path, RBXDataProfile, before, &error) &&
        [changed isEqual:Bytes(path)], @"publication rejects changed preflight bytes");
    Cleanup();

    FreshFixture();
    NSString *journal = [[[RBXFixtureMigration _applicationRoot] stringByAppendingPathComponent:@"deletions"] stringByAppendingPathComponent:@"retired.plist"];
    NSDictionary *retained = @{@"formatVersion":@1, @"containerId":@"retired", @"phase":@"committed",
        @"target":@{@"formatVersion":@1, @"containerId":@"retired"},
        @"profileEvidence":[@"malformed historical evidence" dataUsingEncoding:NSUTF8StringEncoding]};
    WritePlist(retained, journal); NSData *journalBytes = Bytes(journal);
    Check([RBXFixtureMigration preflightAndMigrateWithError:&error] && [journalBytes isEqual:Bytes(journal)], @"historical malformed deletion evidence is preserved without interpretation");
    NSMutableDictionary *futureJournal = [retained mutableCopy]; futureJournal[@"formatVersion"] = @2;
    WritePlist(futureJournal, journal); before = Bytes(journal); publicationCount = 0;
    Check(![RBXFixtureMigration preflightAndMigrateWithError:&error] && publicationCount == 0 &&
        [before isEqual:Bytes(journal)], @"future deletion journal prevents startup and remains intact");
    Cleanup();

    for (NSString *kind in @[@"future-clone", @"legacy-clone", @"future-capture", @"future-target", @"future-evidence", @"corrupt-retired"]) {
        FreshFixture(); NSData *originalStore = Bytes(StorePath()); NSString *blockedPath = nil;
        if ([kind hasSuffix:@"clone"]) {
            blockedPath = [[RBXFixtureMigration _applicationRoot] stringByAppendingPathComponent:@"transactions/transaction-one/transaction.plist"];
            WritePlist(@{@"formatVersion":[kind isEqual:@"future-clone"] ? @3 : @1,
                @"containerId":@"existing-0", @"bundleIdentifier":@"com.redditbox.profile.pexisting0", @"state":@"prepared"}, blockedPath);
        } else if ([kind isEqual:@"future-capture"]) {
            blockedPath = [[RBXFixtureMigration _applicationRoot] stringByAppendingPathComponent:@"transactions/uninstall-evidence/com.redditbox.profile.pexisting0/transaction.plist"];
            WritePlist(@{@"formatVersion":@2, @"bundleIdentifier":@"com.redditbox.profile.pexisting0", @"state":@"captured"}, blockedPath);
        } else if ([kind isEqual:@"corrupt-retired"]) {
            blockedPath = [[RBXFixtureMigration _preferencesRoot] stringByAppendingPathComponent:@"com.redditbox.deleted-containers.plist"];
            WritePlist(@{@"unexpected":@YES}, blockedPath);
        } else {
            blockedPath = [[RBXFixtureMigration _applicationRoot] stringByAppendingPathComponent:@"deletions/retired.plist"];
            NSMutableDictionary *bad = [retained mutableCopy];
            if ([kind isEqual:@"future-target"]) bad[@"target"] = @{@"formatVersion":@2, @"containerId":@"retired"};
            else bad[@"profileEvidence"] = [NSJSONSerialization dataWithJSONObject:Profile(3,@"retired") options:0 error:nil];
            WritePlist(bad, blockedPath);
        }
        NSData *blockedBytes = Bytes(blockedPath); error = nil;
        Check(![RBXFixtureMigration preflightAndMigrateWithError:&error] && error && publicationCount == 0 &&
            [originalStore isEqual:Bytes(StorePath())] && [blockedBytes isEqual:Bytes(blockedPath)],
            [@"global preflight preserves journal failure " stringByAppendingString:kind]);
        Cleanup();
    }

    FreshFixture(); RBXFixtureStore *store = [RBXFixtureStore new];
    WriteJSON(@{@"containers":@{}}, StorePath()); before = Bytes(StorePath());
    Check(![store dictionaryWithError:&error][@"storeVersion"] && [before isEqual:Bytes(StorePath())],
        @"unversioned read neither stamps v2 nor publishes defaults");
    [NSFileManager.defaultManager removeItemAtPath:StorePath() error:nil];
    Check([store dictionaryWithError:&error] && ![NSFileManager.defaultManager fileExistsAtPath:StorePath()],
        @"missing store defaults remain read-only");
    for (id invalid in @[@{@"storeVersion":@3}, @{@"storeVersion":@1, @"containers":@YES}]) {
        WriteJSON(invalid, StorePath()); before = Bytes(StorePath()); __block BOOL ran = NO;
        Check(![store dictionaryWithError:&error] && ![store update:^(NSMutableDictionary *doc) { ran = YES; doc[@"mutation"] = @YES; } error:&error] &&
            !ran && [before isEqual:Bytes(StorePath())], @"invalid store blocks reads/mutations and preserves bytes");
    }
    WriteJSON(@{@"storeVersion":@2, @"containers":@{}}, StorePath());
    __block NSData *concurrent = nil;
    error = nil;
    Check(![store update:^(NSMutableDictionary *doc) {
        doc[@"firstWriter"] = @YES;
        WriteJSON(@{@"storeVersion":@2, @"containers":@{}, @"reservedByConcurrentWriter":@YES}, StorePath());
        concurrent = Bytes(StorePath());
    } error:&error] && error.code == 2 && [concurrent isEqual:Bytes(StorePath())],
        @"stale central mutation cannot erase concurrently published reservations");
    error = nil;
    Check(!RBXSchemaWriteJSONCompared(@{@"storeVersion":@2}, StorePath(), RBXDataStore, nil, YES, &error) &&
        error.code == 2 && [concurrent isEqual:Bytes(StorePath())], @"missing-file comparison cannot overwrite a concurrently created store");
    Cleanup();

    // The actual store append must keep recent A/B traffic evidence at the cap,
    // including an oversized batch left by an earlier publisher/version.
    for (NSNumber *size in @[@0, @499, @500, @501, @1200]) {
        FreshFixture(); NSMutableArray *requests = [NSMutableArray array];
        for (NSInteger index = 0; index < size.integerValue; index++)
            [requests addObject:@{@"host":[NSString stringWithFormat:@"host-%ld", (long)index]}];
        WriteJSON(@{@"storeVersion":@2, @"requests":requests}, StorePath());
        RBXFixtureStore *ringStore = [RBXFixtureStore new];
        [ringStore addRequestForContainer:@"existing-0" host:@"newest-host" proxyId:@"new-proxy"];
        NSArray *retainedRequests = ringStore.requests;
        Check(retainedRequests.count == MIN(size.unsignedIntegerValue + 1, (NSUInteger)500) &&
            [retainedRequests.lastObject[@"host"] isEqual:@"newest-host"], @"request cap retains newest evidence and bounded count");
        if (size.integerValue > 0) Check([retainedRequests.firstObject[@"host"] isEqual:
            [NSString stringWithFormat:@"host-%ld", (long)MAX(0, size.integerValue + 1 - 500)]],
            @"request cap removes only the oldest overflow in chronological order");
        Cleanup();
    }

    FreshFixture(); path = ProfilePath(@"existing-0");
    NSMutableDictionary *legacy = [Profile(1,@"existing-0") mutableCopy];
    [legacy removeObjectForKey:@"profileVersion"]; [legacy removeObjectForKey:@"role"];
    [legacy removeObjectForKey:@"notes"]; [legacy removeObjectForKey:@"metadataRevision"];
    WriteJSON(legacy, path);
    Check([RBXFixtureMigration preflightAndMigrateWithError:&error], @"unversioned original document migrates");
    NSDictionary *updated = RBXSchemaDecode(Bytes(path), RBXDataProfile, nil);
    Check([updated[@"role"] isEqual:@"default"] && [updated[@"notes"] isEqual:@""] &&
        [updated[@"metadataRevision"] isEqual:@0] && [updated[@"serials"] isEqual:legacy[@"serials"]], @"missing metadata added without identity generation");
    Cleanup();
    NSLog(@"PASS: native data schema, all-document preflight, preservation and interruption tests");
    return 0;
} }
