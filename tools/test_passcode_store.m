#import <Foundation/Foundation.h>
#import <Security/Security.h>

// All Keychain entry points used by the shipped store are inert fixture APIs.
// Credential bytes stay in memory and are never printed or persisted.
static OSStatus FixtureCopy(CFDictionaryRef query, CFTypeRef *result);
static OSStatus FixtureAdd(CFDictionaryRef query, CFTypeRef *result);
static OSStatus FixtureUpdate(CFDictionaryRef query, CFDictionaryRef attributes);
static OSStatus FixtureDelete(CFDictionaryRef query);
#define SecItemCopyMatching FixtureCopy
#define SecItemAdd FixtureAdd
#define SecItemUpdate FixtureUpdate
#define SecItemDelete FixtureDelete
#import "../launcher/RBXPasscodeStore.m"
#undef SecItemCopyMatching
#undef SecItemAdd
#undef SecItemUpdate
#undef SecItemDelete

static NSData *stored, *racingRecord;
static BOOL failWrites, duplicateOnAdd;
static OSStatus deleteStatus = errSecSuccess;
static OSStatus readStatus = errSecSuccess;
static id corruptReadValue;
static BOOL nullReadResult;
static NSUInteger addCalls, updateCalls, deleteCalls;

static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAIL passcode store: %s\n", message.UTF8String); exit(1); }
}
static void CheckIdentity(CFDictionaryRef query) {
    NSDictionary *identity = (__bridge NSDictionary *)query;
    Check([identity[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword] &&
        [identity[(__bridge id)kSecAttrService] isEqual:@"com.redditbox.launcher.passcode"] &&
        [identity[(__bridge id)kSecAttrAccount] isEqual:@"owner"] &&
        [identity[(__bridge id)kSecAttrAccessGroup] isEqual:@"RBXBOXCFG.com.redditbox.launcher"],
        @"every provider call must keep the exact passcode item boundary");
}
static OSStatus FixtureCopy(CFDictionaryRef query, CFTypeRef *result) {
    CheckIdentity(query);
    if (readStatus != errSecSuccess) return readStatus;
    if (nullReadResult) return errSecSuccess;
    if (corruptReadValue) {
        if (result) *result = CFBridgingRetain(corruptReadValue);
        return errSecSuccess;
    }
    if (!stored) return errSecItemNotFound;
    if (result) *result = CFBridgingRetain(stored);
    return errSecSuccess;
}
static OSStatus FixtureAdd(CFDictionaryRef query, CFTypeRef *result) {
    CheckIdentity(query); addCalls++;
    if (duplicateOnAdd) { duplicateOnAdd = NO; stored = racingRecord; return errSecDuplicateItem; }
    if (failWrites) return errSecInteractionNotAllowed;
    if (stored) return errSecDuplicateItem;
    NSDictionary *attributes = (__bridge NSDictionary *)query;
    Check([attributes[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly], @"new passcode retains device-only unlocked accessibility");
    stored = attributes[(__bridge id)kSecValueData];
    return errSecSuccess;
}
static OSStatus FixtureUpdate(CFDictionaryRef query, CFDictionaryRef attributesRef) {
    CheckIdentity(query); updateCalls++;
    if (!stored) return errSecItemNotFound;
    if (failWrites) return errSecInteractionNotAllowed;
    NSDictionary *attributes = (__bridge NSDictionary *)attributesRef;
    Check([attributes[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly], @"replacement retains device-only unlocked accessibility");
    stored = attributes[(__bridge id)kSecValueData];
    return errSecSuccess;
}
static OSStatus FixtureDelete(CFDictionaryRef query) {
    CheckIdentity(query); deleteCalls++;
    if (deleteStatus != errSecSuccess) return deleteStatus;
    if (!stored) return errSecItemNotFound;
    stored = nil; return errSecSuccess;
}

int main(void) { @autoreleasepool {
    NSError *error = nil;
    Check(![RBXPasscodeStore hasPasscode] && ![RBXPasscodeStore verifyPasscode:@"fixture-original"],
        @"actual fresh not-found permits initial setup and cannot verify a credential");
    readStatus = errSecInteractionNotAllowed;
    Check([RBXPasscodeStore hasPasscode] && ![RBXPasscodeStore verifyPasscode:@"fixture-original"],
        @"denied read must keep the passcode gate configured instead of claiming absence");
    for (NSNumber *status in @[@(errSecNotAvailable), @(errSecAuthFailed), @(errSecDecode)]) {
        readStatus = status.intValue;
        Check([RBXPasscodeStore hasPasscode] && ![RBXPasscodeStore verifyPasscode:@"fixture-original"],
            @"unknown, unavailable and decode failures must retain the gate and deny verification");
    }
    readStatus = errSecSuccess;
    nullReadResult = YES;
    Check([RBXPasscodeStore hasPasscode] && ![RBXPasscodeStore verifyPasscode:@"fixture-original"],
        @"successful read with no result must retain the gate and deny verification");
    nullReadResult = NO;
    for (id corrupt in @[@"not-data", [@"not-a-property-list" dataUsingEncoding:NSUTF8StringEncoding],
        [NSPropertyListSerialization dataWithPropertyList:@[] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil],
        [NSPropertyListSerialization dataWithPropertyList:@{} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil],
        [NSPropertyListSerialization dataWithPropertyList:@{@"salt":@"wrong-type",@"digest":NSData.data} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil],
        [NSPropertyListSerialization dataWithPropertyList:@{@"salt":NSData.data,@"digest":RBXPasscodeDigest(@"fixture-original", NSData.data)} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]]) {
        corruptReadValue = corrupt;
        Check([RBXPasscodeStore hasPasscode] && ![RBXPasscodeStore verifyPasscode:@"fixture-original"],
            @"malformed successful reads must keep the gate and must not authenticate a malformed verifier");
    }
    corruptReadValue = nil;
    Check([RBXPasscodeStore setPasscode:@"fixture-original" error:&error], @"initial setup succeeds");
    NSData *original = stored;
    failWrites = YES; addCalls = updateCalls = deleteCalls = 0; error = nil;
    Check(![RBXPasscodeStore setPasscode:@"fixture-replacement" error:&error] && error.code == errSecInteractionNotAllowed,
        @"provider replacement failure must be reported");
    Check([stored isEqual:original] && [RBXPasscodeStore hasPasscode] && [RBXPasscodeStore verifyPasscode:@"fixture-original"],
        @"failed replacement must retain the existing passcode gate and verifier");
    Check(![RBXPasscodeStore verifyPasscode:@"fixture-replacement"] && deleteCalls == 0 && addCalls == 0 && updateCalls == 1,
        @"failed update must not delete or fall through to add");
    failWrites = NO; error = nil;
    Check([RBXPasscodeStore setPasscode:@"fixture-replacement" error:&error] && [RBXPasscodeStore verifyPasscode:@"fixture-replacement"] &&
        ![RBXPasscodeStore verifyPasscode:@"fixture-original"] && deleteCalls == 0, @"successful replacement updates only the existing record");
    NSData *replacement = stored;
    Check(![RBXPasscodeStore setPasscode:@"" error:&error] && [stored isEqual:replacement], @"empty set request cannot implicitly disable the gate");
    stored = nil; addCalls = updateCalls = deleteCalls = 0; failWrites = YES;
    Check(![RBXPasscodeStore setPasscode:@"fixture-fresh" error:&error] && !stored && updateCalls == 1 && addCalls == 1 && deleteCalls == 0,
        @"first creation adds only after not-found and propagates add failure");
    failWrites = NO; stored = replacement; racingRecord = replacement; stored = nil;
    duplicateOnAdd = YES; addCalls = updateCalls = deleteCalls = 0;
    Check([RBXPasscodeStore setPasscode:@"fixture-race-new" error:&error] && [RBXPasscodeStore verifyPasscode:@"fixture-race-new"] &&
        updateCalls == 2 && addCalls == 1 && deleteCalls == 0, @"duplicate insertion race retries a bounded update without deletion");
    stored = nil; duplicateOnAdd = YES; failWrites = YES; addCalls = updateCalls = deleteCalls = 0;
    Check(![RBXPasscodeStore setPasscode:@"fixture-race-fail" error:&error] && [stored isEqual:racingRecord] &&
        [RBXPasscodeStore verifyPasscode:@"fixture-replacement"] && updateCalls == 2 && addCalls == 1 && deleteCalls == 0,
        @"failed race retry preserves the competing existing record");
    failWrites = NO; deleteStatus = errSecInteractionNotAllowed;
    Check(![RBXPasscodeStore clearPasscode:&error] && [stored isEqual:racingRecord], @"explicit deletion failure retains the gate");
    deleteStatus = errSecSuccess;
    Check([RBXPasscodeStore clearPasscode:&error] && !stored && [RBXPasscodeStore clearPasscode:&error], @"explicit clear still removes the record and accepts already absent");
    puts("PASS passcode store: only not-found means absent; unknown/corrupt reads deny verification; failed replacement and race preserve gate; explicit clear checked");
} return 0; }
