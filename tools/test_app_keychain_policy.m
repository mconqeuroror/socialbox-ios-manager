#import "RBXAppKeychainPolicy.h"

static unsigned Checks;
static void Check(BOOL okay, NSString *message) {
    Checks++;
    if (!okay) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) { @autoreleasepool {
    NSDictionary *rd = RBXRedditAppDescriptor(), *fb = RBXAppDescriptorForType(@"facebook");
    NSString *bundle = @"socialbox.profile.fb.p975819681a395537";
    NSArray *groups = @[@"SBXFBCLN00.socialbox.profile.fb.p975819681a395537",
        @"SBXFBCLN00.socialbox.profile.fb.p975819681a395537.family",
        @"SBXFBCLN00.socialbox.profile.fb.p975819681a395537.app"];
    Check([RBXAppKeychainGroups(fb, bundle) isEqual:groups], @"audited FB groups stay distinct and ordered");
    NSString *reddit = @"com.redditbox.profile.p975819681a395537";
    Check([RBXAppKeychainGroups(rd, reddit) isEqual:@[@"RBXCLONE00.com.redditbox.profile.p975819681a395537"]], @"Reddit keeps its exact singleton entitlement");
    Check(!RBXAppKeychainGroups(fb, reddit) && !RBXAppKeychainGroups(fb, @"com.facebook.Facebook") &&
        !RBXAppKeychainGroups(nil, bundle), @"only exact registered clones derive groups");
    NSMutableDictionary *forged = fb.mutableCopy; forged[@"keychainGroupSuffixes"] = @[@""];
    Check(!RBXAppKeychainGroups(forged, bundle), @"caller cannot downgrade compiled policy");
    Check([RBXAppKeychainMetadata(rd, reddit) isEqual:@{}], @"legacy profile and marker shape remain unchanged");
    NSDictionary *metadata = @{@"keychainPolicyVersion":@1, @"keychainAccessGroups":groups};
    Check([RBXAppKeychainMetadata(fb, bundle) isEqual:metadata] && RBXAppKeychainMetadataMatches(fb, bundle, metadata), @"versioned metadata binds entire ordered set");
    NSMutableDictionary *marker = [@{@"formatVersion":@2, @"appType":@"facebook", @"sourceBundleIdentifier":@"com.facebook.Facebook", @"keychainAccessGroup":groups[0]} mutableCopy];
    [marker addEntriesFromDictionary:metadata];
    Check(RBXAppKeychainMarkerMatches(fb, bundle, marker), @"complete Facebook marker binds version, source and primary group");
    for (NSString *key in @[@"formatVersion", @"appType", @"sourceBundleIdentifier", @"keychainAccessGroup", @"keychainPolicyVersion", @"keychainAccessGroups"]) {
        NSMutableDictionary *bad = marker.mutableCopy; [bad removeObjectForKey:key];
        Check(!RBXAppKeychainMarkerMatches(fb, bundle, bad), @"incomplete or downgraded Facebook marker rejected");
    }
    Check(RBXAppKeychainMarkerMatches(rd, reddit, @{}), @"legacy Reddit marker policy does not add required fields");
    for (id bad in @[NSNull.null, @{}, @{@"keychainPolicyVersion":@0, @"keychainAccessGroups":groups},
        @{@"keychainPolicyVersion":@1, @"keychainAccessGroups":@[groups[0]]},
        @{@"keychainPolicyVersion":@1, @"keychainAccessGroups":@[groups[0], groups[1], groups[1]]},
        @{@"keychainPolicyVersion":@1, @"keychainAccessGroups":@[groups[1], groups[0], groups[2]]},
        @{@"keychainPolicyVersion":@1, @"keychainAccessGroups":[groups arrayByAddingObject:@"group.com.facebook.family"]}])
        Check(!RBXAppKeychainMetadataMatches(fb, bundle, bad), @"missing, reordered, duplicated, downgraded or expanded metadata fails closed");

    id groupKey = (__bridge id)kSecAttrAccessGroup;
    NSArray *sources = @[@"T84QZS65DQ.platformFamily", @"group.com.facebook.family", @"group.com.facebook.Facebook"];
    NSData *opaque = [@"synthetic-persistent-reference" dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *base = @{(__bridge id)kSecAttrService:@"synthetic-service", (__bridge id)kSecAttrAccount:@"synthetic-account",
        (__bridge id)kSecValuePersistentRef:opaque, (__bridge id)kSecMatchItemList:@[opaque]};
    OSStatus status = errSecSuccess;
    Check(RBXAppKeychainDictionary(rd, reddit, base, YES, &status) == base && status == errSecSuccess, @"Reddit dictionary is object-identical pass-through");
    Check(RBXAppKeychainDictionary(fb, bundle, base, NO, &status) == base, @"omitted group stays omitted, including reference-only queries");
    for (NSUInteger i = 0; i < sources.count; i++) {
        NSMutableDictionary *input = base.mutableCopy; input[groupKey] = sources[i];
        NSDictionary *mapped = RBXAppKeychainDictionary(fb, bundle, input, NO, &status);
        NSMutableDictionary *expected = input.mutableCopy; expected[groupKey] = groups[i];
        Check(status == errSecSuccess && [mapped isEqual:expected] && [input[groupKey] isEqual:sources[i]], @"only explicit audited group changes; input never mutated");
        Check(mapped[(__bridge id)kSecValuePersistentRef] == opaque && mapped[(__bridge id)kSecMatchItemList] == base[(__bridge id)kSecMatchItemList], @"opaque values and reference arrays untouched");
        Check(RBXAppKeychainDictionary(fb, bundle, mapped, NO, &status) == mapped, @"own mapped group is idempotent");
        NSDictionary *nested = @{(__bridge id)kSecPrivateKeyAttrs:input, (__bridge id)kSecPublicKeyAttrs:input, (__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom};
        NSDictionary *keys = RBXAppKeychainDictionary(fb, bundle, nested, YES, &status);
        Check([keys[(__bridge id)kSecPrivateKeyAttrs][groupKey] isEqual:groups[i]] && [keys[(__bridge id)kSecPublicKeyAttrs][groupKey] isEqual:groups[i]], @"both key creation attribute dictionaries map without changing key material");
        Check(RBXAppKeychainDictionary(fb, bundle, nested, NO, &status) == nested, @"ordinary item operations do not traverse unrelated dictionaries");
    }
    for (id forbidden in @[@"", @"group.com.facebook.family.extra", @"SBXFBCLN00.socialbox.profile.fb.p44bd8ad473cd9906.family", @"RBXCLONE00.com.redditbox.profile.p975819681a395537", NSNull.null, @7, @[]]) {
        Check(!RBXAppKeychainDictionary(fb, bundle, @{groupKey:forbidden}, NO, &status) && status != errSecSuccess, @"foreign and malformed explicit groups are not retried or promoted");
    }
    Check(!RBXAppKeychainDictionary(fb, bundle, @{(__bridge id)kSecPrivateKeyAttrs:@7}, YES, &status) && status == errSecParam, @"malformed nested key attributes rejected");
    Check(!RBXAppKeychainDictionary(fb, bundle, nil, NO, &status) && status == errSecParam, @"nil FB request rejected");
    printf("PASS: %u app Keychain policy assertions (host policy; securityd device proof separate)\n", Checks);
} return 0; }
