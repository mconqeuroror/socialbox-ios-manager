#import "RBXAppKeychainPolicy.h"
#import "RBXKeychainSyncPolicy.h"
#import "RBXAppRuntime.h"

@interface TestProfile : NSObject
@property NSDictionary *rawProfile;
@end
@implementation TestProfile @end
@interface RBXContainerManager : NSObject
@property TestProfile *currentProfile;
@property NSString *containerId;
@property BOOL validatedProfileLoaded;
@end
@implementation RBXContainerManager @end
static NSString *TestBundleID;
@interface TestBundle : NSObject
+ (instancetype)mainBundle;
- (NSString *)bundleIdentifier;
@end
@implementation TestBundle
+ (instancetype)mainBundle { return [self new]; }
- (NSString *)bundleIdentifier { return TestBundleID; }
@end
static unsigned HookCount;
static BOOL RBXHookInstallationPassed(void) { return YES; }
static void MSHookFunction(void *function, void *replacement, void **original) {
    (void)replacement; HookCount++; *original = function;
}
#define RBXLog(...) ((void)0)
#define NSBundle TestBundle
#include "app-keychain-wrappers.inc"
#undef NSBundle

static unsigned Checks, Calls;
static NSDictionary *Query, *Changes;
static CFTypeRef *OutputPointer;
static OSStatus ReplyStatus;
static id ReplyValue;
static void Check(BOOL okay, NSString *why) {
    Checks++;
    if (!okay) { fprintf(stderr, "FAIL: %s\n", why.UTF8String); exit(1); }
}
static OSStatus Item(CFDictionaryRef query, CFTypeRef *result) {
    Calls++; Query = (__bridge NSDictionary *)query; OutputPointer = result;
    if (result) *result = ReplyValue ? CFBridgingRetain(ReplyValue) : NULL;
    return ReplyStatus;
}
static OSStatus Update(CFDictionaryRef query, CFDictionaryRef changes) {
    Changes = (__bridge NSDictionary *)changes; return Item(query, NULL);
}
static OSStatus Delete(CFDictionaryRef query) { return Item(query, NULL); }
static SecKeyRef Key(CFDictionaryRef query, CFErrorRef *error) {
    Item(query, NULL);
    if (error) *error = CFErrorCreate(NULL, CFSTR("synthetic-provider"), 1234, NULL);
    return NULL;
}
static SecKeyRef KeyData(CFDataRef data, CFDictionaryRef query, CFErrorRef *error) {
    Check(data != NULL, @"key data reaches provider"); return Key(query, error);
}
static OSStatus Pair(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    Check(publicKey && privateKey, @"pair output pointers preserved"); return Item(query, NULL);
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 2) {
        NSString *mode = @(argv[1]);
        BOOL facebook = [mode hasPrefix:@"facebook"], local = [mode hasSuffix:@"local"];
        NSDictionary *descriptor = RBXAppDescriptorForType(facebook ? @"facebook" : @"reddit");
        TestBundleID = RBXAppBundleIdentifier(descriptor, @"test");
        NSMutableDictionary *app = [@{@"bundleIdentifier":TestBundleID, @"keychainAccessGroup":RBXAppKeychainGroup(descriptor, TestBundleID)} mutableCopy];
        [app addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor, TestBundleID)];
        BOOL invalid = [mode hasSuffix:@"invalid"], unvalidated = [mode hasSuffix:@"unvalidated"];
        if (invalid) [app removeObjectForKey:@"keychainAccessGroups"];
        RBXContainerManager *manager = [RBXContainerManager new];
        manager.containerId = @"test"; manager.validatedProfileLoaded = !unvalidated;
        manager.currentProfile = [TestProfile new];
        manager.currentProfile.rawProfile = @{@"containerId":@"test", @"appType":descriptor[@"appType"], @"app":app,
            @"security":local ? @{@"keychainSync":@"local-only"} : @{}};
        Check(RBXInstallKeychainSyncPolicy(manager) == !(invalid || unvalidated), @"actual installer rejects unvalidated/downgraded FB profile");
        Check(HookCount == (invalid || unvalidated ? 0 : facebook ? 7 : local ? 4 : 0), @"Reddit default remains unhooked; local policy installs four, Facebook seven exactly once");
        if (!invalid && !unvalidated) {
            unsigned before = HookCount;
            Check(RBXInstallKeychainSyncPolicy(manager) && HookCount == before, @"repeat installation adds no hook layer");
        }
        printf("PASS: actual installer %s (%u assertions)\n", argv[1], Checks);
        return 0;
    }
    appkey_descriptor = RBXAppDescriptorForType(@"facebook");
    appkey_bundle = RBXAppBundleIdentifier(appkey_descriptor, @"test");
    appkey_orig_SecItemAdd = Item; appkey_orig_SecItemCopyMatching = Item;
    appkey_orig_SecItemUpdate = Update; appkey_orig_SecItemDelete = Delete;
    appkey_orig_SecKeyCreateRandomKey = Key; appkey_orig_SecKeyCreateWithData = KeyData;
    appkey_orig_SecKeyGeneratePair = Pair;
    id group = (__bridge id)kSecAttrAccessGroup, sync = (__bridge id)kSecAttrSynchronizable;
    NSData *opaque = [@"test-reference" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *request = @{group:@"group.com.facebook.family", sync:@YES, (__bridge id)kSecValuePersistentRef:opaque};
    NSArray *groups = RBXAppKeychainGroups(appkey_descriptor, appkey_bundle);
    for (NSNumber *local in @[@NO, @YES]) {
        appkey_localOnly = local.boolValue;
        for (NSNumber *providerStatus in @[@(errSecSuccess), @(errSecItemNotFound), @(errSecInteractionNotAllowed), @(errSecMissingEntitlement), @(errSecParam)]) {
            ReplyStatus = providerStatus.intValue;
            for (id result in @[@{group:groups[1], (__bridge id)kSecValuePersistentRef:opaque}, @[@{group:groups[0]}, @{group:groups[1]}], opaque, NSNull.null]) {
                ReplyValue = ReplyStatus == errSecSuccess && result != NSNull.null ? result : nil;
                CFTypeRef out = NULL; Calls = 0;
                Check(appkey_SecItemAdd((__bridge CFDictionaryRef)request, &out) == ReplyStatus && Calls == 1 && OutputPointer == &out, @"actual add wrapper forwards status and result pointer once");
                Check([Query[group] isEqual:groups[1]] && [Query[sync] isEqual:local.boolValue ? @NO : @YES], @"mapping composes once with optional local-only policy");
                Check((__bridge id)out == ReplyValue, @"returned attributes/arrays/data/refs preserve exact provider object and ownership");
                if (out) CFRelease(out);
                out = NULL; Calls = 0;
                Check(appkey_SecItemCopyMatching((__bridge CFDictionaryRef)request, &out) == ReplyStatus && Calls == 1 && OutputPointer == &out, @"matching preserves error and never broadens or retries");
                if (out) CFRelease(out);
            }
            Calls = 0;
            Check(appkey_SecItemUpdate((__bridge CFDictionaryRef)request, (__bridge CFDictionaryRef)request) == ReplyStatus && Calls == 1 && [Changes[group] isEqual:groups[1]], @"update independently validates/maps query and update attributes");
            Calls = 0;
            Check(appkey_SecItemDelete((__bridge CFDictionaryRef)request) == ReplyStatus && Calls == 1, @"delete calls provider once");
        }
    }
    appkey_localOnly = NO; ReplyValue = nil;
    for (id bad in @[@"group.foreign", @42, NSNull.null]) {
        NSDictionary *input = @{group:bad}; CFTypeRef out = NULL; Calls = 0;
        Check(appkey_SecItemAdd((__bridge CFDictionaryRef)input, &out) != errSecSuccess && !Calls && !out, @"bad add never reaches provider");
        Check(appkey_SecItemCopyMatching((__bridge CFDictionaryRef)input, &out) != errSecSuccess && !Calls, @"bad lookup never reaches provider");
        Check(appkey_SecItemUpdate((__bridge CFDictionaryRef)request, (__bridge CFDictionaryRef)input) != errSecSuccess && !Calls, @"foreign update attributes do not migrate items");
        Check(appkey_SecItemDelete((__bridge CFDictionaryRef)input) != errSecSuccess && !Calls, @"bad deletion never reaches provider");
    }
    NSDictionary *attrs = @{(__bridge id)kSecPrivateKeyAttrs:request, (__bridge id)kSecPublicKeyAttrs:@{group:@"group.com.facebook.Facebook"}};
    CFErrorRef error = NULL; Calls = 0;
    Check(!appkey_SecKeyCreateRandomKey((__bridge CFDictionaryRef)attrs, &error) && Calls == 1 && CFErrorGetCode(error) == 1234, @"random-key creation retains provider error");
    CFRelease(error); error = NULL;
    Check([Query[(__bridge id)kSecPrivateKeyAttrs][group] isEqual:groups[1]] && [Query[(__bridge id)kSecPublicKeyAttrs][group] isEqual:groups[2]], @"key-specific groups remain distinct");
    Calls = 0;
    Check(!appkey_SecKeyCreateWithData((__bridge CFDataRef)opaque, (__bridge CFDictionaryRef)attrs, &error) && Calls == 1, @"data-backed key import uses same policy");
    CFRelease(error); error = NULL;
    SecKeyRef publicKey = NULL, privateKey = NULL; Calls = 0;
    Check(appkey_SecKeyGeneratePair((__bridge CFDictionaryRef)attrs, &publicKey, &privateKey) == ReplyStatus && Calls == 1, @"legacy pair creation uses same policy");
    NSDictionary *badKey = @{(__bridge id)kSecPrivateKeyAttrs:@{group:@"foreign"}}; Calls = 0;
    Check(!appkey_SecKeyCreateRandomKey((__bridge CFDictionaryRef)badKey, &error) && !Calls && CFErrorGetCode(error) == errSecMissingEntitlement, @"foreign key creation returns Security-domain entitlement error");
    Check(CFEqual(CFErrorGetDomain(error), kCFErrorDomainOSStatus), @"policy error uses OSStatus domain");
    CFRelease(error);
    printf("PASS: %u actual app Keychain wrapper assertions\n", Checks);
} return 0; }
