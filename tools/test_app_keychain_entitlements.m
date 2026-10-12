#import "RBXAppKeychainPolicy.h"
#import "RBXAppRuntime.h"
#import "RBXAppProfileIdentity.h"
#import <dlfcn.h>

static NSDictionary *Entitlements;
static NSMutableDictionary *Items;
static NSMutableArray *Added;
static NSString *FailedGroup;
static BOOL WrongValue, FailCleanup;
static unsigned Checks, Deletes;
static void Check(BOOL okay, NSString *why) {
    Checks++;
    if (!okay) { fprintf(stderr, "FAIL: %s\n", why.UTF8String); exit(1); }
}
static CFTypeRef CreateTask(CFAllocatorRef allocator) { (void)allocator; return CFBridgingRetain(@{}); }
static CFTypeRef CopyEntitlement(CFTypeRef task, CFStringRef key, CFErrorRef *error) {
    (void)task; (void)error;
    return Entitlements[(__bridge NSString *)key] ? CFBridgingRetain(Entitlements[(__bridge NSString *)key]) : NULL;
}
static void *Open(const char *path, int flags) { (void)path; (void)flags; return (void *)1; }
static void *Symbol(void *handle, const char *name) {
    (void)handle;
    return !strcmp(name, "SecTaskCreateFromSelf") ? (void *)CreateTask : (void *)CopyEntitlement;
}
static int Close(void *handle) { (void)handle; return 0; }
static OSStatus Add(CFDictionaryRef dictionary, CFTypeRef *result) {
    (void)result;
    NSDictionary *query = (__bridge NSDictionary *)dictionary;
    NSString *group = query[(__bridge id)kSecAttrAccessGroup];
    if ([group isEqual:FailedGroup]) return errSecInteractionNotAllowed;
    Items[group] = query[(__bridge id)kSecValueData]; [Added addObject:group];
    return errSecSuccess;
}
static OSStatus Copy(CFDictionaryRef dictionary, CFTypeRef *result) {
    id data = Items[((__bridge NSDictionary *)dictionary)[(__bridge id)kSecAttrAccessGroup]];
    if (WrongValue) data = [NSData data];
    if (result) *result = data ? CFBridgingRetain(data) : NULL;
    return data ? errSecSuccess : errSecItemNotFound;
}
static OSStatus Delete(CFDictionaryRef dictionary) {
    Deletes++;
    if (FailCleanup && Deletes == 2) return errSecInteractionNotAllowed;
    [Items removeObjectForKey:((__bridge NSDictionary *)dictionary)[(__bridge id)kSecAttrAccessGroup]];
    return errSecSuccess;
}
#define dlopen Open
#define dlsym Symbol
#define dlclose Close
#define SecItemAdd Add
#define SecItemCopyMatching Copy
#define SecItemDelete Delete
#include "app-keychain-entitlements.inc"

int main(void) { @autoreleasepool {
    for (NSDictionary *descriptor in RBXRegisteredAppDescriptors()) {
        NSString *bundle = RBXAppBundleIdentifier(descriptor, @"test");
        NSArray *groups = RBXAppKeychainGroups(descriptor, bundle);
        NSMutableDictionary *app = [@{@"bundleIdentifier":bundle, @"keychainAccessGroup":groups[0]} mutableCopy];
        [app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor, bundle)];
        NSMutableDictionary *profile = [@{@"appType":descriptor[@"appType"], @"containerId":@"test", @"app":app} mutableCopy];
        Entitlements = @{@"application-identifier":groups[0], @"com.apple.developer.team-identifier":descriptor[@"teamIdentifier"], @"keychain-access-groups":groups};
        Check(RBXCloneEntitlementsMatchProfile(profile), @"actual runtime accepts exactly its derived team/application/groups");
        Check(!RBXAppProfileIdentityBlockReason(descriptor, profile, @"test"), @"complete metadata admitted by actual profile identity policy");
        NSDictionary *valid = Entitlements;
        for (NSString *key in @[@"application-identifier", @"com.apple.developer.team-identifier", @"keychain-access-groups"]) {
            NSMutableDictionary *bad = valid.mutableCopy; [bad removeObjectForKey:key]; Entitlements = bad;
            Check(!RBXCloneEntitlementsMatchProfile(profile), @"missing effective entitlement denied");
            bad[key] = @"foreign";
            Check(!RBXCloneEntitlementsMatchProfile(profile), @"foreign or malformed effective entitlement denied");
        }
        for (id extra in @[@[], @[groups[0], groups[0]], [groups arrayByAddingObject:@"group.com.facebook.family"], [groups arrayByAddingObject:@"sibling.group"]]) {
            NSMutableDictionary *bad = valid.mutableCopy; bad[@"keychain-access-groups"] = extra; Entitlements = bad;
            Check(!RBXCloneEntitlementsMatchProfile(profile), @"duplicate/missing/source/foreign effective groups rejected");
        }
        for (NSString *key in @[@"com.apple.security.application-groups", @"aps-environment", @"com.apple.developer.ubiquity-container-identifiers", @"com.apple.developer.ubiquity-kvstore-identifier", @"com.apple.developer.icloud-container-identifiers", @"com.apple.developer.icloud-services", @"com.apple.developer.associated-domains", @"get-task-allow"]) {
            NSMutableDictionary *bad = valid.mutableCopy; bad[key] = @YES; Entitlements = bad;
            Check(!RBXCloneEntitlementsMatchProfile(profile), @"forbidden shared/private entitlement rejected");
        }
        NSMutableDictionary *attest = valid.mutableCopy; attest[@"com.apple.developer.devicecheck.appattest-environment"] = @"production"; Entitlements = attest;
        Check(!RBXCloneEntitlementsMatchProfile(profile), @"unexpected AppAttest entitlement denied");
        profile[@"security"] = @{@"appAttest":@"enabled"};
        Check(RBXCloneEntitlementsMatchProfile(profile), @"explicit legacy AppAttest entitlement policy retained");
        Entitlements = valid;
        Check(!RBXCloneEntitlementsMatchProfile(profile), @"enabled AppAttest requires actual entitlement");
        [profile removeObjectForKey:@"security"];
        if ([descriptor[@"appType"] isEqual:@"facebook"]) {
            [app removeObjectForKey:@"keychainAccessGroups"];
            Check(RBXAppProfileIdentityBlockReason(descriptor, profile, @"test") != nil, @"profile IO identity boundary rejects downgraded Facebook app metadata");
            [app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor, bundle)];
        }
        Items = [NSMutableDictionary dictionary]; Added = [NSMutableArray array];
        Check(RBXCloneKeychainProbe(profile) && [Added isEqual:groups] && !Items.count, @"actual startup probe adds, reads and removes a canary in every required group");
        for (NSString *group in groups) {
            FailedGroup = group; Added = [NSMutableArray array];
            Check(!RBXCloneKeychainProbe(profile), @"failure/locked error in any required group denies startup readiness");
        }
        FailedGroup = nil; WrongValue = YES;
        Check(!RBXCloneKeychainProbe(profile), @"wrong own canary value denied");
        WrongValue = NO; FailCleanup = YES; Deletes = 0;
        Check(!RBXCloneKeychainProbe(profile), @"failed canary cleanup cannot report a completed startup probe");
        FailCleanup = NO; [Items removeAllObjects];
    }
    printf("PASS: %u actual runtime entitlement and group-probe assertions\n", Checks);
} return 0; }
