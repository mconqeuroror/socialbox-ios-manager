#import "../shared/RBXKeychainSyncPolicy.h"
#include "keychain-sync-wrappers.inc"

static NSDictionary *ObservedQuery, *ObservedAttributes;
static NSUInteger Calls;
static CFTypeRef *ObservedResult;
static OSStatus Provider(CFDictionaryRef query, CFTypeRef *result) {
    ObservedQuery = [(__bridge NSDictionary *)query copy];
    ObservedResult = result;
    Calls++;
    return errSecMissingEntitlement;
}
static OSStatus UpdateProvider(CFDictionaryRef query, CFDictionaryRef attributes) {
    ObservedAttributes = [(__bridge NSDictionary *)attributes copy];
    return Provider(query, NULL);
}
static OSStatus DeleteProvider(CFDictionaryRef query) { return Provider(query, NULL); }

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL OS-011: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        id sync = (__bridge id)kSecAttrSynchronizable;
        id group = (__bridge id)kSecAttrAccessGroup;
        id service = (__bridge id)kSecAttrService;
        id account = (__bridge id)kSecAttrAccount;
        id value = (__bridge id)kSecValueData;
        Check(RBXKeychainSyncPolicyValid(nil) && RBXKeychainSyncPolicyValid(@"unchanged") &&
              RBXKeychainSyncPolicyValid(@"local-only"), @"only documented configurations accepted");
        for (id invalid in @[@YES, @1, @{}, @[], @"enabled", @"LOCAL-ONLY", NSNull.null])
            Check(!RBXKeychainSyncPolicyValid(invalid), @"invalid configuration rejected");
        Check(!RBXKeychainSyncPolicyEnabled(nil) && !RBXKeychainSyncPolicyEnabled(@"unchanged") &&
              RBXKeychainSyncPolicyEnabled(@"local-only"), @"default preserves login behavior");
        NSArray *selectors = @[@YES, @NO, (__bridge id)kSecAttrSynchronizableAny];
        for (id selector in selectors) {
            NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                group: @"TEAM.clone-A", service: @"oauth", account: @"test-account", sync: selector,
                (__bridge id)kSecReturnPersistentRef: @YES};
            Check(RBXKeychainSyncDictionary(query, NO) == query, @"disabled query is byte-for-byte object pass-through");
            NSDictionary *local = RBXKeychainSyncDictionary(query, YES);
            Check([local[sync] isEqual:@NO], @"enabled query excludes synchronized records even for Any");
            NSMutableDictionary *expected = query.mutableCopy; expected[sync] = @NO;
            Check([local isEqual:expected], @"only synchronizable selector changes; groups, refs, service and account retained");
            Check([query[sync] isEqual:selector], @"caller query never mutated");
        }
        NSDictionary *ungrouped = @{service: @"oauth", account: @"test-account"};
        NSDictionary *local = RBXKeychainSyncDictionary(ungrouped, YES);
        Check(local == ungrouped && !local[group] && !local[sync], @"absent selector remains local without changing reference/access-group semantics");
        NSDictionary *update = @{value: [@"test-bytes" dataUsingEncoding:NSUTF8StringEncoding]};
        Check(RBXKeychainSyncDictionary(update, YES) == update, @"update without selector is unchanged");
        NSMutableDictionary *syncUpdate = update.mutableCopy; syncUpdate[sync] = @YES;
        Check([RBXKeychainSyncDictionary(syncUpdate, YES)[sync] isEqual:@NO],
            @"explicit update cannot turn local item into synced item");
        Check(RBXKeychainSyncDictionary(syncUpdate, NO) == syncUpdate, @"disabled update unchanged");
        Check(!RBXKeychainSyncDictionary(nil, YES), @"invalid nil dictionary stays nil for Security validation");
        NSDictionary *invalid = @{sync: @"not-a-synchronizable-selector"};
        Check(RBXKeychainSyncDictionary(invalid, YES) == invalid, @"malformed selector reaches Security unchanged");

        sync_orig_SecItemAdd = Provider;
        sync_orig_SecItemCopyMatching = Provider;
        sync_orig_SecItemUpdate = UpdateProvider;
        sync_orig_SecItemDelete = DeleteProvider;
        NSDictionary *request = @{sync: (__bridge id)kSecAttrSynchronizableAny, service: @"test-only",
            group: @"TEAM.clone-A", (__bridge id)kSecValuePersistentRef: [NSData data]};
        CFTypeRef output = NULL;
        Calls = 0;
        Check(sync_SecItemAdd((__bridge CFDictionaryRef)request, &output) == errSecMissingEntitlement &&
            Calls == 1 && ObservedResult == &output && [ObservedQuery[sync] isEqual:@NO],
            @"shipped add wrapper preserves Security error/result pointer with no retry");
        Calls = 0;
        Check(sync_SecItemCopyMatching((__bridge CFDictionaryRef)request, &output) == errSecMissingEntitlement &&
            Calls == 1 && ObservedResult == &output && [ObservedQuery[sync] isEqual:@NO],
            @"shipped matching wrapper cannot fall back to synchronized items");
        Calls = 0;
        Check(sync_SecItemUpdate((__bridge CFDictionaryRef)request, (__bridge CFDictionaryRef)syncUpdate) ==
            errSecMissingEntitlement && Calls == 1 && [ObservedQuery[sync] isEqual:@NO] &&
            [ObservedAttributes[sync] isEqual:@NO] && [ObservedQuery[group] isEqual:@"TEAM.clone-A"],
            @"shipped update wrapper constrains query/attributes and preserves access group and error");
        Calls = 0;
        Check(sync_SecItemDelete((__bridge CFDictionaryRef)request) == errSecMissingEntitlement &&
            Calls == 1 && [ObservedQuery[sync] isEqual:@NO], @"shipped delete wrapper is local with no retry");
        printf("PASS OS-011: optional local-only dictionary policy; real iOS Security/SDK behavior NOT RUN\n");
    }
    return 0;
}
