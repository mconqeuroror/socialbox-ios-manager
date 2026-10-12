// Native macOS Foundation tests of the actual Registry journal helpers.
// Run on macOS:
// clang -fobjc-arc -fblocks -Wno-unused-function -Ishared -Idaemon \
//   -framework Foundation tools/test_deletion_journal.m -o /tmp/rbx-deletion-test
// /tmp/rbx-deletion-test
// This does not execute Registry's service-dependent operation, Security,
// LaunchServices, or device cleanup. All filesystem paths are temporary roots.
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <dirent.h>
#import <string.h>
#import <limits.h>

static NSString *TestRoot, *WritingPhase, *FailedPhase, *FailedOperation;
static BOOL FailProfileInspection, FailTemporaryCleanup;
static NSUInteger RemainingFailures;
static NSDictionary *FixtureApp;
static NSUInteger WriteCalls;

static BOOL Fail(NSString *operation) {
    if (RemainingFailures && [FailedOperation isEqual:operation] && [FailedPhase isEqual:WritingPhase]) {
        RemainingFailures--;
        errno = EIO;
        return YES;
    }
    return NO;
}

static ssize_t TestWrite(int descriptor, const void *bytes, size_t length) {
    WriteCalls++;
    NSData *data = [NSData dataWithBytes:bytes length:length];
    id value = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    if ([value isKindOfClass:NSDictionary.class] && [value[@"phase"] isKindOfClass:NSString.class])
        WritingPhase = value[@"phase"];
    if (Fail(@"write")) return -1;
    return write(descriptor, bytes, length);
}

static int TestRename(int oldDirectory, const char *oldName, int newDirectory, const char *newName) {
    if (Fail(@"rename")) return -1;
    return renameat(oldDirectory, oldName, newDirectory, newName);
}

static int TestSync(int descriptor) {
    struct stat info;
    char path[PATH_MAX] = {0};
    if (fstat(descriptor, &info) == 0 && fcntl(descriptor, F_GETPATH, path) == 0) {
        NSString *value = [[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath];
        NSString *root = [[TestRoot stringByAppendingPathComponent:@"deletions"] stringByResolvingSymlinksInPath];
        if (([value isEqual:root] || [value hasPrefix:[root stringByAppendingString:@"/"]]) &&
            Fail(S_ISDIR(info.st_mode) ? @"directory-fsync" : @"file-fsync")) return -1;
    }
    return fsync(descriptor);
}

static int TestLstat(const char *path, struct stat *info) {
    NSString *value = [[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath];
    if (FailProfileInspection && [value isEqual:[TestRoot stringByAppendingPathComponent:@"profiles/alpha.json"]]) {
        errno = EACCES;
        return -1;
    }
    return lstat(path, info);
}

static int TestUnlink(int directory, const char *name, int flags) {
    if (FailTemporaryCleanup && [[NSString stringWithUTF8String:name] hasSuffix:@".tmp"]) {
        errno = EIO;
        return -1;
    }
    return unlinkat(directory, name, flags);
}

#define RBX_REGISTRY_TESTING 1
#define RBX_REGISTRY_JOURNAL_TESTING 1
#define write TestWrite
#define renameat TestRename
#define fsync TestSync
#define lstat TestLstat
#define unlinkat TestUnlink
#import "../daemon/RBXContainerRegistry.m"
#undef write
#undef renameat
#undef fsync
#undef lstat
#undef unlinkat

static void Check(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"TestFailure" reason:message userInfo:nil];
}

static NSDictionary *FixtureTarget(NSString *container) {
    NSString *bundle=RBXAppBundleIdentifier(FixtureApp,container);
    NSMutableDictionary *target=[@{@"formatVersion":@1,@"containerId":container,@"bundleIdentifier":bundle,
        @"keychainAccessGroup":RBXAppKeychainGroup(FixtureApp,bundle),@"transactions":@[]} mutableCopy];
    if(![FixtureApp[@"appType"] isEqual:@"reddit"]) {
        target[@"formatVersion"]=@2;target[@"appType"]=FixtureApp[@"appType"];
        target[@"sourceBundleIdentifier"]=FixtureApp[@"sourceBundleIdentifier"];
        [target addEntriesFromDictionary:RBXAppKeychainMetadata(FixtureApp,bundle)];
    }
    return target;
}
static NSMutableDictionary *NewJournal(void) {
    NSMutableDictionary *journal=[@{@"formatVersion": @1, @"containerId": @"alpha", @"createdAt": @1,
        @"cloudBinding": @{@"serverURL": @"https://fixture.invalid", @"deviceId": @"fixture-device"},
        @"target":FixtureTarget(@"alpha")} mutableCopy];
    if(![FixtureApp[@"appType"] isEqual:@"reddit"]) {journal[@"formatVersion"]=@2;journal[@"appType"]=FixtureApp[@"appType"];}
    return journal;
}

static void ResetFailure(void) {
    WritingPhase = FailedPhase = FailedOperation = nil;
    RemainingFailures = 0;
    FailTemporaryCleanup = FailProfileInspection = NO;
}

static void TestOwnerRejection(int directory) {
    ResetFailure();
    NSMutableDictionary *journal=NewJournal();
    Check(RBXWriteDeletion(directory,journal,@"prepared",nil),@"valid owner checkpoint established");
    for(NSDictionary *change in @[@{@"appType":@"unknown"},@{@"containerId":@"sibling"},@{@"formatVersion":@99}]) {
        NSMutableDictionary *bad=journal.mutableCopy;[bad addEntriesFromDictionary:change];
        NSUInteger writes=WriteCalls;NSError *error=nil;
        Check(!RBXWriteDeletion(directory,bad,@"prepared",&error) && error && WriteCalls==writes,
            @"invalid deletion owner must be rejected before replacing any checkpoint");
        Check([RBXReadDeletion(directory,@"alpha",nil) isEqual:journal],@"invalid owner preserves last valid checkpoint");
    }
    NSDictionary *target=journal[@"target"];
    NSMutableArray *keys=[@[@"containerId",@"bundleIdentifier",@"keychainAccessGroup",@"formatVersion"] mutableCopy];
    if(![FixtureApp[@"appType"] isEqual:@"reddit"]) [keys addObjectsFromArray:@[@"appType",@"sourceBundleIdentifier",@"keychainAccessGroups",@"keychainPolicyVersion"]];
    for(NSString *key in keys) {
        NSMutableDictionary *bad=journal.mutableCopy,*badTarget=target.mutableCopy;[badTarget removeObjectForKey:key];bad[@"target"]=badTarget;
        NSUInteger writes=WriteCalls;NSError *error=nil;
        Check(!RBXWriteDeletion(directory,bad,@"prepared",&error) && error && WriteCalls==writes,@"incomplete target tuple rejected before publication");
        Check([RBXReadDeletion(directory,@"alpha",nil) isEqual:journal],@"incomplete target cannot replace durable authority");
    }
}

static void TestCheckpoints(int directory) {
    NSError *error = nil;
    Check(RBXReadDeletion(directory, @"alpha", &error) == nil && error == nil, @"missing journal is absence");
    Check(RBXReadDeletion(directory, @"../alpha", &error) == nil && error != nil, @"unsafe identifier is an error");
    NSMutableDictionary *journal = NewJournal();
    Check(RBXWriteDeletion(directory, journal, @"prepared", &error), @"prepared checkpoint publishes");
    Check([RBXReadDeletion(directory, @"alpha", nil) isEqual:journal], @"prepared checkpoint readback matches");

    for (NSString *operation in @[@"write", @"file-fsync", @"rename", @"directory-fsync"]) {
        FailedOperation = operation;
        FailedPhase = @"keychain-cleared";
        RemainingFailures = 1;
        error = nil;
        Check(!RBXWriteDeletion(directory, journal, @"keychain-cleared", &error) && error != nil,
            [NSString stringWithFormat:@"%@ failure propagates", operation]);
        Check(RemainingFailures == 0, @"fault reached the actual publication syscall");
        Check([journal[@"phase"] isEqual:@"prepared"], @"failed publication does not advance caller's checkpoint");
        NSDictionary *observed = RBXReadDeletion(directory, @"alpha", nil);
        // A directory-fsync failure occurs AFTER atomic rename. The new file
        // may be visible, but the caller still must report failure and retry.
        Check([observed[@"phase"] isEqual:([operation isEqual:@"directory-fsync"] ? @"keychain-cleared" : @"prepared")],
            @"failure preserves a complete, readable checkpoint");
        ResetFailure();
        Check(RBXWriteDeletion(directory, journal, @"prepared", &error), @"retry re-establishes durable checkpoint");
    }

    FailedOperation = @"write"; FailedPhase = @"keychain-cleared"; RemainingFailures = 1;
    FailTemporaryCleanup = YES;
    Check(!RBXWriteDeletion(directory, journal, @"keychain-cleared", &error), @"failed temporary unlink cannot turn write failure into success");
    Check([RBXReadDeletion(directory, @"alpha", nil)[@"phase"] isEqual:@"prepared"], @"failed temporary cleanup preserves authority");
    ResetFailure();

    for (NSString *phase in @[@"keychain-cleared", @"uninstalled", @"cleanup-complete", @"committed"]) {
        Check(RBXWriteDeletion(directory, journal, phase, &error), @"next checkpoint publishes");
        Check([RBXReadDeletion(directory, @"alpha", nil) isEqual:journal], @"phase survives a fresh read");
        Check(RBXWriteDeletion(directory, journal, phase, &error), @"same phase can be republished on retry");
    }
    Check([RBXDeletionSummary(@"alpha", journal, nil)[@"completed"] boolValue], @"committed absent profile is complete");
    NSString *profile = [kProfilesDir stringByAppendingPathComponent:@"alpha.json"];
    Check([[@"{}" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:profile options:0 error:&error], @"reappeared profile fixture");
    NSDictionary *pending = RBXDeletionSummary(@"alpha", journal, nil);
    Check(![pending[@"completed"] boolValue] && [pending[@"phase"] isEqual:@"cleanup-complete"], @"reappeared profile remains visible and retryable");
    FailProfileInspection = YES;
    pending = RBXDeletionSummary(@"alpha", journal, nil);
    Check(![pending[@"completed"] boolValue] && [pending[@"phase"] isEqual:@"recovery-required"], @"unreadable profile absence is not success");
    ResetFailure();

    NSString *path = [kDeletionRoot stringByAppendingPathComponent:@"alpha.plist"];
    Check([[@"corrupt" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:path options:0 error:&error], @"corrupt fixture");
    error = nil;
    Check(RBXReadDeletion(directory, @"alpha", &error) == nil && error != nil, @"corrupt existing journal is not absence");
}

static void TestProfileEvidence(int directory) {
    NSError *error = nil;
    BOOL missing = NO;
    Check(!RBXDeletionProfileData(@"evidence", &missing, &error) && missing && !error,
        @"missing canonical profile is distinct from invalid bytes");
    missing = NO; error = nil;
    Check(!RBXDeletionProfileData(@"../evidence", &missing, &error) && !missing && error,
        @"unsafe evidence identity never becomes a path");
    NSString *path = [kProfilesDir stringByAppendingPathComponent:@"evidence.json"];
    for (NSData *raw in @[[NSData data], [@"{malformed" dataUsingEncoding:NSUTF8StringEncoding],
        [@"{\"containerId\":\"someone-else\",\"app\":[]}" dataUsingEncoding:NSUTF8StringEncoding]]) {
        error = nil; missing = NO;
        Check([raw writeToFile:path options:NSDataWritingAtomic error:&error], @"raw profile fixture writes");
        NSData *observed = RBXDeletionProfileData(@"evidence", &missing, &error);
        Check(observed && [observed isEqual:raw] && !missing && !error,
            @"invalid JSON is preserved byte-for-byte without interpreting paths");
        NSMutableDictionary *journal = NewJournal();
        journal[@"containerId"] = @"evidence";
        journal[@"target"] = FixtureTarget(@"evidence");
        journal[@"profileEvidence"] = observed;
        FailedOperation = @"write"; FailedPhase = @"prepared"; RemainingFailures = 1;
        error = nil;
        Check(!RBXWriteDeletion(directory, journal, @"prepared", &error) && error,
            @"failed preparation returns an explicit error");
        Check([RBXDeletionProfileData(@"evidence", NULL, nil) isEqual:raw],
            @"failed preparation preserves exact source bytes");
        ResetFailure();
        Check(RBXWriteDeletion(directory, journal, @"prepared", &error), @"evidence journal publishes");
        Check([RBXReadDeletion(directory, @"evidence", nil)[@"profileEvidence"] isEqual:raw],
            @"raw profile evidence survives actual journal serialization and fresh read");
    }
    NSDictionary *previous = RBXReadDeletion(directory, @"evidence", nil);
    NSMutableDictionary *oversized = [previous mutableCopy];
    oversized[@"finalProfileEvidence"] = [NSMutableData dataWithLength:2 * 1024 * 1024];
    error = nil;
    Check(!RBXWriteDeletion(directory, oversized, @"cleanup-complete", &error) && error,
        @"serialized evidence limit rejects before publication");
    Check([RBXReadDeletion(directory, @"evidence", nil) isEqual:previous],
        @"oversized journal cannot replace the previous readable authority");
    Check([RBXDeletionProfileData(@"evidence", NULL, nil) isEqual:previous[@"profileEvidence"]],
        @"oversized publication leaves source profile unchanged");
    NSMutableDictionary *finishing = [previous mutableCopy];
    finishing[@"profileReadError"] = @"malformed fixture";
    error = nil;
    Check(!RBXCommitDeletion(directory, finishing, &error) && error,
        @"evidence cannot be scrubbed while a profile remains");
    Check(finishing[@"profileEvidence"] != nil, @"failed absence proof preserves recovery bytes");
    Check([NSFileManager.defaultManager removeItemAtPath:path error:&error], @"remove own fixture");
    FailedOperation = @"write"; FailedPhase = @"committed"; RemainingFailures = 1;
    error = nil;
    Check(!RBXCommitDeletion(directory, finishing, &error) && error,
        @"failed tombstone publication reports failure");
    Check(finishing[@"profileEvidence"] && RBXReadDeletion(directory, @"evidence", nil)[@"profileEvidence"],
        @"failed tombstone write preserves both in-memory and persisted evidence");
    ResetFailure();
    Check(RBXCommitDeletion(directory, finishing, &error), @"durable absence permits compact tombstone");
    NSDictionary *tombstone = RBXReadDeletion(directory, @"evidence", nil);
    Check(!tombstone[@"profileEvidence"] && !tombstone[@"finalProfileEvidence"] && !tombstone[@"profileReadError"] &&
        [RBXDeletionSummary(@"evidence", tombstone, nil)[@"completed"] boolValue],
        @"successful Delete leaves no raw profile recovery copy in its permanent tombstone");
    NSString *outside = [TestRoot stringByAppendingPathComponent:@"unrelated.json"];
    NSData *outsideBytes = [@"unrelated data" dataUsingEncoding:NSUTF8StringEncoding];
    Check([outsideBytes writeToFile:outside options:0 error:&error], @"unrelated fixture writes");
    Check(symlink(outside.fileSystemRepresentation, path.fileSystemRepresentation) == 0, @"symlink fixture creates");
    error = nil; missing = NO;
    Check(!RBXDeletionProfileData(@"evidence", &missing, &error) && error && !missing,
        @"symlink cannot supply deletion profile evidence");
    Check([[NSData dataWithContentsOfFile:outside] isEqual:outsideBytes], @"symlink target remains unchanged");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TestRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rbx-journal-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        kProfilesDir = [TestRoot stringByAppendingPathComponent:@"profiles"];
        kDeletedContainerIds = [TestRoot stringByAppendingPathComponent:@"legacy.plist"];
        kDeletionRoot = [TestRoot stringByAppendingPathComponent:@"deletions"];
        kActiveBindingPath = [TestRoot stringByAppendingPathComponent:@"binding"];
        kLegacyDataRoots = @[[TestRoot stringByAppendingPathComponent:@"legacy-containers"]];
        int directory = -1;
        int result = 0;
        @try {
            NSError *error = nil;
            Check(argc == 2, @"canonical ID fixture path required");
            NSData *fixtureData = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
            Check(fixtureData != nil, @"canonical ID fixtures readable");
            NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:fixtureData options:0 error:&error];
            Check([fixture isKindOfClass:NSDictionary.class], @"canonical ID fixtures parsed");
            for (NSString *identifier in fixture[@"accepted"])
                Check(RBXCanonicalProfileIdentifier(identifier), @"wire-valid ID remains byte-for-byte valid on phone");
            for (NSString *identifier in fixture[@"rejected"])
                Check(!RBXCanonicalProfileIdentifier(identifier), @"ambiguous ID rejected by phone");
            Check(RBXCanonicalProfileIdentifier([@"a" stringByPaddingToLength:128 withString:@"a" startingAtIndex:0]), @"128 character limit accepted");
            Check(!RBXCanonicalProfileIdentifier([@"a" stringByPaddingToLength:129 withString:@"a" startingAtIndex:0]), @"129 characters rejected");
            Check([NSFileManager.defaultManager createDirectoryAtPath:kProfilesDir withIntermediateDirectories:YES
                attributes:@{NSFilePosixPermissions: @0700} error:&error], @"temporary fixtures created");
            // Darwin F_GETPATH reports canonical /private/var paths even when
            // NSTemporaryDirectory originally returned the /var alias.
            TestRoot = TestRoot.stringByResolvingSymlinksInPath;
            kProfilesDir = [TestRoot stringByAppendingPathComponent:@"profiles"];
            kDeletedContainerIds = [TestRoot stringByAppendingPathComponent:@"legacy.plist"];
            kDeletionRoot = [TestRoot stringByAppendingPathComponent:@"deletions"];
            kActiveBindingPath = [TestRoot stringByAppendingPathComponent:@"binding"];
            kLegacyDataRoots = @[[TestRoot stringByAppendingPathComponent:@"legacy-containers"]];
            directory = RBXOpenDeletionRoot(YES, &error);
            Check(directory >= 0, error.localizedDescription ?: @"journal directory opens");
            for(NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
                FixtureApp=descriptor;ResetFailure();
                for(NSString *name in @[@"alpha.json",@"evidence.json"])
                    [NSFileManager.defaultManager removeItemAtPath:[kProfilesDir stringByAppendingPathComponent:name] error:nil];
                for(NSString *name in @[@"alpha.plist",@"evidence.plist"])
                    [NSFileManager.defaultManager removeItemAtPath:[kDeletionRoot stringByAppendingPathComponent:name] error:nil];
                TestCheckpoints(directory);
                TestProfileEvidence(directory);
                TestOwnerRejection(directory);
                printf("PASS: %s actual deletion journal publication faults, phase retries, receipt state, and exact malformed-profile evidence\n",[descriptor[@"appType"] UTF8String]);
            }
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: %s\n", exception.reason.UTF8String);
            result = 1;
        } @finally {
            ResetFailure();
            if (directory >= 0) close(directory);
            [NSFileManager.defaultManager removeItemAtPath:TestRoot error:nil];
        }
        return result;
    }
}
