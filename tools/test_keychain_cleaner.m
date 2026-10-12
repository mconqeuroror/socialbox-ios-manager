// Execute the actual helper control flow with an in-memory Security backend.
// No test calls the real SecItem/SecTask APIs or changes host credentials.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <errno.h>
#import <grp.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

struct __SecTask;
static uid_t MockGetUID(void);
static gid_t MockGetGID(void);
static int MockGetGroups(int, gid_t *);
static int MockSetGroups(int, const gid_t *);
static int MockSetGID(gid_t);
static int MockSetUID(uid_t);
static void *MockDLOpen(const char *, int);
static void *MockDLSym(void *, const char *);
static int MockDLClose(void *);
static OSStatus MockRandom(SecRandomRef, size_t, void *);
static OSStatus MockAdd(CFDictionaryRef, CFTypeRef *);
static OSStatus MockCopy(CFDictionaryRef, CFTypeRef *);
static OSStatus MockDelete(CFDictionaryRef);
static ssize_t MockWrite(int, const void *, size_t);

#define main RBXCleanerMain
#define getuid MockGetUID
#define geteuid MockGetUID
#define getgid MockGetGID
#define getegid MockGetGID
#define getgroups MockGetGroups
#define setgroups MockSetGroups
#define setgid MockSetGID
#define setuid MockSetUID
#define dlopen MockDLOpen
#define dlsym MockDLSym
#define dlclose MockDLClose
#define SecRandomCopyBytes MockRandom
#define SecItemAdd MockAdd
#define SecItemCopyMatching MockCopy
#define SecItemDelete MockDelete
#define write MockWrite
#include "../daemon/RBXKeychainCleaner.m"
#undef main
#undef getuid
#undef geteuid
#undef getgid
#undef getegid
#undef getgroups
#undef setgroups
#undef setgid
#undef setuid
#undef dlopen
#undef dlsym
#undef dlclose
#undef SecRandomCopyBytes
#undef SecItemAdd
#undef SecItemCopyMatching
#undef SecItemDelete
#undef write

static NSString *const FixtureBundle = @"com.redditbox.profile.p0123456789abcdef";
static NSString *const FixtureGroup = @"RBXCLONE00.com.redditbox.profile.p0123456789abcdef";
static NSString *const OtherGroup = @"RBXCLONE00.com.redditbox.profile.pfedcba9876543210";
static uid_t mockUID;
static gid_t mockGID;
static int mockGroupMode;
static BOOL mockGroupsCleared, mockDropFails, mockReadNotFound, mockRetainKey;
static BOOL probeAdded, probeRead, probeDeleted, probeVerified;
static NSUInteger massDeletes, secTaskCalls, secItemCalls;
static OSStatus mockAddStatus;
static NSMutableDictionary *mockEntitlements;
static NSMutableArray<NSDictionary *> *items;
static NSMutableData *output;
static NSString *targetBundle;
static NSArray<NSString *> *targetGroups;
static NSMutableDictionary<NSString *, NSNumber *> *groupProofs;
static NSString *failingGroup;
static BOOL reinsertEarlierGroup;

static void Require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static void RequireMobile(void) {
    Require(mockUID == 501 && mockGID == 501 && mockGroupsCleared,
        @"Security must only run after all mobile credentials are established");
}

static uid_t MockGetUID(void) { return mockUID; }
static gid_t MockGetGID(void) { return mockGID; }
static int MockGetGroups(int count, gid_t *groups) {
    if (mockGroupMode == 3) { errno = EIO; return -1; }
    int n = mockGroupMode == 0 ? 0 : mockGroupMode == 2 ? 2 : 1;
    if (!mockGroupsCleared) n = 2;
    if (count && count < n) { errno = EINVAL; return -1; }
    if (count && n) { groups[0] = 501; if (n == 2) groups[1] = 0; }
    return n;
}
static int MockSetGroups(int count, const gid_t *groups) {
    Require(mockUID == 0 && count == 0 && !groups, @"supplementary groups must be cleared as root");
    mockGroupsCleared = YES; return 0;
}
static int MockSetGID(gid_t value) {
    if (mockUID != 0) { errno = EPERM; return -1; }
    mockGID = value; return 0;
}
static int MockSetUID(uid_t value) {
    if (mockUID != 0 || mockDropFails) { errno = EPERM; return -1; }
    mockUID = value; return 0;
}

static struct __SecTask *MockCreateTask(CFAllocatorRef allocator) {
    (void)allocator; RequireMobile(); secTaskCalls++;
    return (struct __SecTask *)CFBridgingRetain(@{});
}
static CFTypeRef MockCopyEntitlement(struct __SecTask *task, CFStringRef name, CFErrorRef *error) {
    (void)task; (void)error; RequireMobile();
    id value = mockEntitlements[(__bridge NSString *)name];
    return value ? CFBridgingRetain(value) : NULL;
}
static void *MockDLOpen(const char *path, int mode) { (void)path; (void)mode; RequireMobile(); return (void *)1; }
static int MockDLClose(void *handle) { (void)handle; return 0; }
static void *MockDLSym(void *handle, const char *name) {
    (void)handle;
    if (!strcmp(name, "SecTaskCreateFromSelf")) return (void *)&MockCreateTask;
    if (!strcmp(name, "SecTaskCopyValueForEntitlement")) return (void *)&MockCopyEntitlement;
    return NULL;
}
static OSStatus MockRandom(SecRandomRef random, size_t count, void *bytes) {
    (void)random; RequireMobile(); memset(bytes, 0x5a, count); return errSecSuccess;
}

static NSDictionary *Query(CFDictionaryRef value) {
    RequireMobile(); secItemCalls++;
    NSDictionary *query = (__bridge NSDictionary *)value;
    Require([targetGroups containsObject:query[(__bridge id)kSecAttrAccessGroup]], @"every query must explicitly name a group owned by this exact target");
    Require([query[(__bridge id)kSecUseDataProtectionKeychain] boolValue], @"use the data protection keychain");
    return query;
}
static BOOL IsProbe(NSDictionary *query) { return query[(__bridge id)kSecAttrService] != nil; }
static BOOL Matches(NSDictionary *item, NSDictionary *query) {
    for (id key in @[(__bridge id)kSecClass, (__bridge id)kSecAttrAccessGroup,
        (__bridge id)kSecAttrService, (__bridge id)kSecAttrAccount, (__bridge id)kSecAttrSynchronizable]) {
        id expected = query[key];
        if (!expected || (key == (__bridge id)kSecAttrSynchronizable && [expected isEqual:(__bridge id)kSecAttrSynchronizableAny])) continue;
        if (![item[key] isEqual:expected]) return NO;
    }
    return YES;
}
static OSStatus MockAdd(CFDictionaryRef value, CFTypeRef *result) {
    (void)result;
    NSDictionary *query = Query(value);
    Require(IsProbe(query), @"the only added item is the fresh authorization canary");
    if ([failingGroup isEqual:query[(__bridge id)kSecAttrAccessGroup]]) return errSecInteractionNotAllowed;
    if (mockAddStatus != errSecSuccess) return mockAddStatus;
    for (NSDictionary *item in items) if (Matches(item, query)) return errSecDuplicateItem;
    [items addObject:[query copy]]; probeAdded = YES;
    groupProofs[query[(__bridge id)kSecAttrAccessGroup]] = @1;
    return errSecSuccess;
}
static OSStatus MockCopy(CFDictionaryRef value, CFTypeRef *result) {
    NSDictionary *query = Query(value);
    if (result) *result = NULL;
    if (IsProbe(query) && mockReadNotFound) return errSecItemNotFound;
    if (!IsProbe(query)) Require([query[(__bridge id)kSecAttrSynchronizable] isEqual:(__bridge id)kSecAttrSynchronizableAny],
        @"emptiness checks must include synchronizable and local items");
    for (NSDictionary *item in items) {
        if (!Matches(item, query)) continue;
        if (IsProbe(query)) {
            probeRead = YES;
            NSString *group = query[(__bridge id)kSecAttrAccessGroup];
            groupProofs[group] = @([groupProofs[group] unsignedIntegerValue] | 2);
        }
        id returned = [query[(__bridge id)kSecReturnData] boolValue] ? item[(__bridge id)kSecValueData] : item;
        if (result) *result = CFBridgingRetain(returned);
        return errSecSuccess;
    }
    if (IsProbe(query) && probeAdded && probeRead && probeDeleted) probeVerified = YES;
    if (IsProbe(query)) {
        NSString *group = query[(__bridge id)kSecAttrAccessGroup];
        if ([groupProofs[group] unsignedIntegerValue] == 7) groupProofs[group] = @15;
    }
    return errSecItemNotFound;
}
static OSStatus MockDelete(CFDictionaryRef value) {
    NSDictionary *query = Query(value);
    if (!IsProbe(query)) {
        Require(probeAdded && probeRead && probeDeleted && probeVerified, @"mass erase cannot precede the complete canary proof");
        Require([groupProofs[query[(__bridge id)kSecAttrAccessGroup]] unsignedIntegerValue] == 15,
            @"each group requires its own complete authorization proof before erasure");
        Require([query[(__bridge id)kSecAttrSynchronizable] isEqual:(__bridge id)kSecAttrSynchronizableAny],
            @"mass erase must include synchronizable and local items");
        massDeletes++;
        if (mockRetainKey && [query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassKey]) return errSecSuccess;
    }
    NSUInteger removed = 0;
    for (NSInteger index = (NSInteger)items.count - 1; index >= 0; index--) {
        if (Matches(items[(NSUInteger)index], query)) { [items removeObjectAtIndex:(NSUInteger)index]; removed++; }
    }
    if (IsProbe(query) && removed) {
        probeDeleted = YES;
        NSString *group = query[(__bridge id)kSecAttrAccessGroup];
        groupProofs[group] = @([groupProofs[group] unsignedIntegerValue] | 4);
    }
    if (!IsProbe(query) && reinsertEarlierGroup &&
        [query[(__bridge id)kSecAttrAccessGroup] isEqual:targetGroups.lastObject] &&
        [query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassKey]) {
        [items addObject:@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccessGroup:targetGroups.firstObject, (__bridge id)kSecAttrSynchronizable:@NO}];
        reinsertEarlierGroup = NO;
    }
    return removed ? errSecSuccess : errSecItemNotFound;
}
static ssize_t MockWrite(int fd, const void *bytes, size_t count) {
    Require(fd == STDOUT_FILENO, @"helper only emits its receipt on stdout");
    [output appendBytes:bytes length:count]; return (ssize_t)count;
}

static void Reset(void) {
    mockUID = 0; mockGID = 0; mockGroupsCleared = NO; mockGroupMode = 1;
    mockDropFails = mockReadNotFound = mockRetainKey = NO;
    probeAdded = probeRead = probeDeleted = probeVerified = NO;
    massDeletes = secTaskCalls = secItemCalls = 0;
    mockAddStatus = errSecSuccess;
    output = [NSMutableData data]; items = [NSMutableArray array];
    targetBundle = FixtureBundle; targetGroups = @[FixtureGroup];
    groupProofs = [NSMutableDictionary dictionary]; failingGroup = nil; reinsertEarlierGroup = NO;
    mockEntitlements = [@{@"application-identifier": FixtureGroup,
        @"com.apple.developer.team-identifier": @"RBXCLONE00", @"keychain-access-groups": @[FixtureGroup]} mutableCopy];
    for (NSString *group in @[FixtureGroup, OtherGroup]) {
        for (id itemClass in @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword,
            (__bridge id)kSecClassCertificate, (__bridge id)kSecClassKey]) {
            for (NSNumber *sync in @[@NO, @YES]) {
                [items addObject:@{(__bridge id)kSecClass: itemClass, (__bridge id)kSecAttrAccessGroup: group,
                    (__bridge id)kSecAttrSynchronizable: sync, (__bridge id)kSecValueData: [@"synthetic value" dataUsingEncoding:NSUTF8StringEncoding]}];
            }
        }
    }
}
static NSArray *ItemsForGroup(NSString *group) {
    return [items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
        (void)bindings; return [item[(__bridge id)kSecAttrAccessGroup] isEqual:group];
    }]];
}
static NSDictionary *Run(BOOL success) {
    char *argv[] = {"redditbox-keychain-cleaner", (char *)targetBundle.UTF8String,
        "00000000-0000-4000-8000-000000000005", NULL};
    int result = RBXCleanerMain(3, argv);
    Require(success ? result == 0 : result != 0, @"helper exit code must match the proven cleanup outcome");
    Require(output.length > 0 && output.length <= 4096, @"receipt must fit the bounded contract");
    NSDictionary *receipt = [NSJSONSerialization JSONObjectWithData:output options:0 error:nil];
    Require([receipt isKindOfClass:NSDictionary.class] && [receipt[@"formatVersion"] integerValue] == (targetGroups.count == 1 ? 1 : 2), @"valid versioned JSON receipt");
    Require([receipt[@"nonce"] isEqual:@"00000000-0000-4000-8000-000000000005"] &&
        [receipt[@"bundleIdentifier"] isEqual:targetBundle] && [receipt[@"accessGroup"] isEqual:targetGroups.firstObject], @"receipt is bound to this target and nonce");
    Require([receipt[@"status"] isEqual:success ? @"cleared" : @"incomplete"], @"receipt status must match exit outcome");
    NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(targetBundle);
    Require(RBXAppKeychainCleanupReceiptBound(descriptor, targetBundle, receipt[@"nonce"], receipt),
        @"parent must bind the actual helper receipt to its canonical target");
    Require(RBXAppKeychainCleanupReceiptComplete(descriptor, targetBundle, receipt[@"nonce"], receipt) == success,
        @"parent completion verdict must match the actual helper outcome");
    return receipt;
}

static void ResetFacebook(void) {
    Reset();
    targetBundle = @"socialbox.profile.fb.p0123456789abcdef";
    NSString *primary = [@"SBXFBCLN00." stringByAppendingString:targetBundle];
    targetGroups = @[primary, [primary stringByAppendingString:@".family"], [primary stringByAppendingString:@".app"]];
    mockEntitlements = [@{@"application-identifier":primary,
        @"com.apple.developer.team-identifier":@"SBXFBCLN00", @"keychain-access-groups":targetGroups} mutableCopy];
    // Original Reddit fixtures and a second Facebook clone must survive.
    NSArray *fixtureItems = ItemsForGroup(FixtureGroup);
    for (NSString *group in [targetGroups arrayByAddingObject:@"SBXFBCLN00.socialbox.profile.fb.pfedcba9876543210.family"]) {
        for (NSDictionary *item in fixtureItems) {
            NSMutableDictionary *copy = item.mutableCopy;
            copy[(__bridge id)kSecAttrAccessGroup] = group; [items addObject:copy];
        }
    }
}

static void VerifyFacebookReceipt(NSDictionary *receipt) {
    Require([receipt[@"appType"] isEqual:@"facebook"] && [receipt[@"keychainPolicyVersion"] isEqual:@1] &&
        [receipt[@"keychainAccessGroups"] isEqual:targetGroups], @"Facebook receipt binds complete compiled group policy");
    Require([receipt[@"groups"] count] == 3, @"Facebook cleanup must prove all three groups");
    for (NSUInteger i = 0; i < targetGroups.count; i++) {
        NSDictionary *group = receipt[@"groups"][i];
        Require([group[@"accessGroup"] isEqual:targetGroups[i]] && [group[@"proof"] isEqual:@YES] &&
            [group[@"classes"] isEqual:@[@"genp", @"inet", @"cert", @"keys"]], @"each group proves all four classes");
    }
    NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(targetBundle);
    for (NSString *key in @[@"formatVersion", @"appType", @"keychainPolicyVersion", @"keychainAccessGroups",
        @"groups", @"nonce", @"bundleIdentifier", @"accessGroup", @"status", @"proof", @"classes", @"uid", @"gid", @"stage", @"osStatus"]) {
        NSMutableDictionary *changed = receipt.mutableCopy; [changed removeObjectForKey:key];
        Require(!RBXAppKeychainCleanupReceiptComplete(descriptor, targetBundle, receipt[@"nonce"], changed),
            [@"missing receipt field must deny parent advancement: " stringByAppendingString:key]);
    }
    for (NSUInteger i = 0; i < targetGroups.count; i++) {
        for (NSDictionary *change in @[@{@"accessGroup":OtherGroup}, @{@"proof":@NO}, @{@"classes":@[@"genp", @"inet", @"cert"]}]) {
            NSMutableDictionary *changed = receipt.mutableCopy, *group = [receipt[@"groups"][i] mutableCopy];
            [group addEntriesFromDictionary:change];
            NSMutableArray *records = [receipt[@"groups"] mutableCopy]; records[i] = group; changed[@"groups"] = records;
            Require(!RBXAppKeychainCleanupReceiptComplete(descriptor, targetBundle, receipt[@"nonce"], changed),
                @"each group must independently prove exact ownership, authorization and all classes");
        }
    }
    Require(!RBXAppKeychainCleanupReceiptComplete(RBXRedditAppDescriptor(), targetBundle, receipt[@"nonce"], receipt),
        @"Facebook receipt cannot authorize Reddit cleanup");
}

int main(void) {
    @autoreleasepool {
        for (int mode = 2; mode <= 3; mode++) {
            Reset(); mockGroupMode = mode; Run(NO);
            Require(secItemCalls == 0 && secTaskCalls == 0, @"extra groups and failed group inspection deny Security access");
        }
        Reset(); mockGroupMode = 0; Run(YES);
        puts("PASS  zero groups is accepted; extra groups and inspection errors are denied");
        Reset(); mockDropFails = YES;
        Run(NO);
        Require(secTaskCalls == 0 && secItemCalls == 0 && massDeletes == 0, @"credential failure precedes all Security operations");
        puts("PASS  failed privilege drop prevents every Security operation");

        Reset(); mockEntitlements[@"keychain-access-groups"] = @[FixtureGroup, OtherGroup];
        Run(NO);
        Require(secItemCalls == 0 && massDeletes == 0, @"extra access groups are rejected before a canary or erase");
        Reset(); mockEntitlements[@"com.apple.security.application-groups"] = @[@"group.unrelated"];
        Run(NO);
        Require(secItemCalls == 0 && massDeletes == 0, @"app-group keychain access expansion is rejected");
        puts("PASS  extra keychain or app-group entitlements stop cleanup");

        Reset(); mockAddStatus = errSecMissingEntitlement;
        NSDictionary *receipt = Run(NO);
        Require(![receipt[@"proof"] boolValue] && massDeletes == 0 && ItemsForGroup(FixtureGroup).count == 8,
            @"unauthorized empty queries cannot authorize cleanup");
        Reset(); mockReadNotFound = YES;
        receipt = Run(NO);
        Require(![receipt[@"proof"] boolValue] && massDeletes == 0 && ItemsForGroup(FixtureGroup).count == 8,
            @"item-not-found during canary read is failure, even after add success");
        puts("PASS  missing entitlement or item-not-found without canary proof never reaches mass erase");

        Reset(); mockAddStatus = errSecInteractionNotAllowed;
        receipt = Run(NO);
        Require(![receipt[@"proof"] boolValue] && massDeletes == 0 && [receipt[@"stage"] isEqual:@"canary-add"],
            @"locked-keychain failure stops before deleting credentials");
        puts("PASS  locked-keychain failure stops before group deletion");

        Reset(); mockRetainKey = YES;
        NSArray *unrelated = ItemsForGroup(OtherGroup);
        receipt = Run(NO);
        Require([receipt[@"proof"] boolValue] && [receipt[@"stage"] isEqual:@"verify-keys"] &&
            ![receipt[@"classes"] containsObject:@"keys"] && ItemsForGroup(FixtureGroup).count == 2,
            @"a successful delete return cannot hide remaining key records");
        Require([ItemsForGroup(OtherGroup) isEqual:unrelated], @"failed target cleanup preserves the second group");
        puts("PASS  a retained class prevents a successful cleanup receipt");

        Reset(); unrelated = ItemsForGroup(OtherGroup);
        receipt = Run(YES);
        Require([receipt[@"proof"] boolValue] && [receipt[@"classes"] isEqual:@[@"genp", @"inet", @"cert", @"keys"]] &&
            [receipt[@"uid"] integerValue] == 501 && [receipt[@"gid"] integerValue] == 501 && massDeletes == 4,
            @"successful receipt proves every supported class under mobile credentials");
        Require(ItemsForGroup(FixtureGroup).count == 0 && [ItemsForGroup(OtherGroup) isEqual:unrelated],
            @"only the selected group is emptied, including both synchronization modes");
        puts("PASS  exact-group erase clears four classes and preserves the second group");
        puts("7 actual-helper test groups passed with synthetic Security calls; no real keychain was accessed.");

        ResetFacebook();
        NSArray *redditBefore = ItemsForGroup(FixtureGroup), *otherBefore = ItemsForGroup(OtherGroup);
        receipt = Run(YES); VerifyFacebookReceipt(receipt);
        Require(massDeletes == 12 && items.count == 24, @"three target groups erased, every unrelated item retained");
        Require([ItemsForGroup(FixtureGroup) isEqual:redditBefore] && [ItemsForGroup(OtherGroup) isEqual:otherBefore],
            @"Facebook erasure preserves both Reddit fixtures");
        for (NSString *group in targetGroups) Require(ItemsForGroup(group).count == 0, @"every target group empty");
        puts("PASS  Facebook three-group erase has individual authorization and complete class receipts");

        for (NSUInteger index = 0; index < 3; index++) {
            ResetFacebook(); failingGroup = targetGroups[index]; receipt = Run(NO);
            Require(massDeletes == index * 4 && ![receipt[@"proof"] boolValue] &&
                [receipt[@"groups"] count] == index + 1, @"partial authorization failure cannot produce overall proof");
            Require(ItemsForGroup(failingGroup).count == 8, @"failed group keeps its data for retry");
            // Retry with the same actual store, including already empty groups.
            mockUID = mockGID = 0; mockGroupsCleared = NO; failingGroup = nil; massDeletes = 0;
            output = [NSMutableData data]; groupProofs = [NSMutableDictionary dictionary];
            receipt = Run(YES); VerifyFacebookReceipt(receipt);
            Require(items.count == 24 && massDeletes == 12, @"retry safely completes every group without touching siblings");
        }
        puts("PASS  failure at each Facebook group leaves incomplete evidence and supports exact-target retry");

        ResetFacebook(); reinsertEarlierGroup = YES; receipt = Run(NO);
        Require([receipt[@"stage"] isEqual:@"final-verify-genp"] && ItemsForGroup(targetGroups.firstObject).count == 1,
            @"late writes to an earlier group invalidate aggregate success");
        for (NSUInteger index = 0; index < 3; index++) {
            ResetFacebook(); NSMutableArray *groups = targetGroups.mutableCopy; [groups removeObjectAtIndex:index];
            mockEntitlements[@"keychain-access-groups"] = groups; Run(NO);
            Require(secItemCalls == 0, @"missing any expected group denies all Security mutations");
        }
        ResetFacebook(); mockEntitlements[@"com.apple.developer.team-identifier"] = @"RBXCLONE00"; Run(NO);
        Require(secItemCalls == 0, @"cross-app signing team denies Security mutations");
        ResetFacebook(); mockEntitlements[@"keychain-access-groups"] = [targetGroups arrayByAddingObject:OtherGroup]; Run(NO);
        Require(secItemCalls == 0, @"foreign extra group denies Security mutations");
        puts("PASS  final cross-group sweep, missing groups and foreign entitlement sets fail closed");
    }
    return 0;
}
