// Device-only synthetic Security test. Never queries account services or mutates
// an app profile. Run as mobile with precisely derived A/B fixture entitlements.
#import "RBXAppKeychainPolicy.h"
#import <dlfcn.h>
#import <unistd.h>

static NSMutableArray *Results;
static BOOL Failed;
static void Record(NSString *probe, OSStatus status, BOOL pass) {
    [Results addObject:@{@"probe":probe, @"status":@(status), @"pass":@(pass)}];
    if (!pass) Failed = YES;
}
static NSDictionary *Map(NSDictionary *descriptor, NSString *bundle, NSDictionary *query, BOOL key) {
    OSStatus status;
    NSDictionary *mapped = RBXAppKeychainDictionary(descriptor, bundle, query, key, &status);
    if (!mapped) { Record(@"query-policy", status, NO); }
    return mapped;
}
static BOOL Entitled(NSDictionary *descriptor, NSString *bundle) {
    typedef CFTypeRef (*Create)(CFAllocatorRef);
    typedef CFTypeRef (*Copy)(CFTypeRef, CFStringRef, CFErrorRef *);
    Create create = (Create)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    Copy copy = (Copy)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) return NO;
    CFTypeRef task = create(NULL);
    if (!task) return NO;
    NSDictionary *expected = @{@"application-identifier":RBXAppKeychainGroup(descriptor, bundle),
        @"com.apple.developer.team-identifier":descriptor[@"teamIdentifier"],
        @"keychain-access-groups":RBXAppKeychainGroups(descriptor, bundle)};
    BOOL okay = YES;
    for (NSString *key in expected) {
        id actual = CFBridgingRelease(copy(task, (__bridge CFStringRef)key, NULL));
        okay &= [actual isEqual:expected[key]];
    }
    for (NSString *key in @[@"com.apple.security.application-groups", @"keychain-access-groups-wildcard", @"platform-application", @"get-task-allow"])
        okay &= CFBridgingRelease(copy(task, (__bridge CFStringRef)key, NULL)) == nil;
    CFRelease(task);
    return okay;
}
static NSDictionary *ItemQuery(id itemClass, NSString *group, NSString *service) {
    NSMutableDictionary *query = [@{(__bridge id)kSecClass:itemClass, (__bridge id)kSecAttrAccessGroup:group} mutableCopy];
    if ([itemClass isEqual:(__bridge id)kSecClassGenericPassword]) {
        query[(__bridge id)kSecAttrService] = service;
        query[(__bridge id)kSecAttrAccount] = @"synthetic";
    } else if ([itemClass isEqual:(__bridge id)kSecClassInternetPassword]) {
        query[(__bridge id)kSecAttrServer] = [service stringByAppendingString:@".invalid"];
        query[(__bridge id)kSecAttrAccount] = @"synthetic";
    } else if ([itemClass isEqual:(__bridge id)kSecClassKey]) {
        query[(__bridge id)kSecAttrApplicationTag] = [service dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        query[(__bridge id)kSecAttrLabel] = service;
    }
    return query;
}

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 4 || getuid() != 501 || geteuid() != 501) return 64;
    NSString *role = @(argv[1]), *phase = @(argv[2]), *nonce = @(argv[3]);
    if (![@[@"A", @"B"] containsObject:role] || ![@[@"seed", @"verify", @"clean"] containsObject:phase] ||
        nonce.length != 32 || [nonce rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return 64;
    NSDictionary *descriptor = RBXAppDescriptorForType(@"facebook");
    NSString *container = [@"fb-keychain-acceptance-" stringByAppendingString:role];
    NSString *bundle = RBXAppBundleIdentifier(descriptor, container);
    if (!Entitled(descriptor, bundle)) return 65;
    Results = [NSMutableArray array];
    NSString *service = [@"com.redditbox.acceptance.fbkey." stringByAppendingString:nonce];
    NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
    NSDictionary *payload = input.length ? [NSJSONSerialization JSONObjectWithData:input options:0 error:nil] : @{};
    if (![payload isKindOfClass:NSDictionary.class]) return 64;
    id certificate = nil;
    if ([phase isEqual:@"seed"]) {
        id encoded = payload[@"certificateDER"];
        if (![encoded isKindOfClass:NSString.class]) return 64;
        NSData *der = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!der.length) return 64;
        certificate = CFBridgingRelease(SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der));
        if (!certificate) return 64; // Validate all seed inputs before any write.
    }
    NSMutableArray *references = [NSMutableArray array];
    NSArray *sources = descriptor[@"keychainSourceGroups"], *groups = RBXAppKeychainGroups(descriptor, bundle);
    NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate, (__bridge id)kSecClassKey];
    for (NSUInteger index = 0; index < groups.count; index++) {
        for (id itemClass in classes) {
            NSString *name = [NSString stringWithFormat:@"%@.%lu", itemClass, (unsigned long)index];
            NSDictionary *query = Map(descriptor, bundle, ItemQuery(itemClass, sources[index], service), NO);
            if (!query) return 66;
            if ([phase isEqual:@"clean"]) {
                OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
                Record([@"delete." stringByAppendingString:name], status, status == errSecSuccess || status == errSecItemNotFound);
                status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
                Record([@"empty." stringByAppendingString:name], status, status == errSecItemNotFound);
                continue;
            }
            if ([phase isEqual:@"seed"]) {
                // A duplicate is a failed, safely resumable fixture, not authority
                // to delete whatever was already present under a reused nonce.
                OSStatus status;
                if ([itemClass isEqual:(__bridge id)kSecClassKey]) {
                    NSDictionary *attributes = Map(descriptor, bundle, @{
                        (__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                        (__bridge id)kSecAttrKeySizeInBits:@256,
                        (__bridge id)kSecPrivateKeyAttrs:@{(__bridge id)kSecAttrIsPermanent:@YES,
                            (__bridge id)kSecAttrAccessGroup:sources[index],
                            (__bridge id)kSecAttrApplicationTag:[service dataUsingEncoding:NSUTF8StringEncoding]}}, YES);
                    CFErrorRef error = NULL;
                    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes, &error);
                    status = key ? errSecSuccess : error ? (OSStatus)CFErrorGetCode(error) : errSecInternalError;
                    if (key) CFRelease(key);
                    if (error) CFRelease(error);
                } else {
                    NSMutableDictionary *add = query.mutableCopy;
                    if ([itemClass isEqual:(__bridge id)kSecClassCertificate]) {
                        add[(__bridge id)kSecValueRef] = certificate;
                    } else {
                        add[(__bridge id)kSecValueData] = [[NSString stringWithFormat:@"%@-%lu", role, (unsigned long)index] dataUsingEncoding:NSUTF8StringEncoding];
                    }
                    status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                }
                Record([@"seed." stringByAppendingString:name], status, status == errSecSuccess);
            }
            NSMutableDictionary *lookup = query.mutableCopy;
            lookup[(__bridge id)kSecReturnPersistentRef] = @YES;
            CFTypeRef ref = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &ref);
            id value = CFBridgingRelease(ref);
            BOOL found = status == errSecSuccess && [value isKindOfClass:NSData.class];
            Record([@"own-ref." stringByAppendingString:name], status, found);
            if (found) [references addObject:@{@"name":name, @"reference":[value base64EncodedStringWithOptions:0]}];
            if ([itemClass isEqual:(__bridge id)kSecClassGenericPassword] || [itemClass isEqual:(__bridge id)kSecClassInternetPassword]) {
                [lookup removeObjectForKey:(__bridge id)kSecReturnPersistentRef];
                lookup[(__bridge id)kSecReturnData] = @YES; ref = NULL;
                status = SecItemCopyMatching((__bridge CFDictionaryRef)lookup, &ref);
                NSData *expected = [[NSString stringWithFormat:@"%@-%lu", role, (unsigned long)index] dataUsingEncoding:NSUTF8StringEncoding];
                id actual = CFBridgingRelease(ref);
                Record([@"own-value." stringByAppendingString:name], status, status == errSecSuccess && [actual isEqual:expected]);
            }
        }
    }
    if ([phase isEqual:@"verify"]) {
        NSArray *foreignRefs = payload[@"references"];
        if (![foreignRefs isKindOfClass:NSArray.class] || foreignRefs.count != 12) return 64;
        for (NSDictionary *item in foreignRefs) {
            NSData *ref = [[NSData alloc] initWithBase64EncodedString:item[@"reference"] options:0];
            if (!ref.length) return 64;
            NSDictionary *query = @{(__bridge id)kSecValuePersistentRef:ref, (__bridge id)kSecReturnAttributes:@YES};
            CFTypeRef found = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
            Record([@"foreign-reference." stringByAppendingString:item[@"name"]], status,
                !found && (status == errSecItemNotFound || status == errSecMissingEntitlement));
            if (found) CFRelease(found);
        }
        NSString *other = RBXAppBundleIdentifier(descriptor, [@"fb-keychain-acceptance-" stringByAppendingString:[role isEqual:@"A"] ? @"B" : @"A"]);
        for (NSString *foreign in RBXAppKeychainGroups(descriptor, other)) {
            // Raw Security call deliberately verifies the entitlement boundary,
            // separately from the earlier same-API wrapper policy host tests.
            for (id itemClass in classes) {
                NSDictionary *query = ItemQuery(itemClass, foreign, service);
                OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
                Record([NSString stringWithFormat:@"foreign-group.%@.%lu", itemClass, (unsigned long)[RBXAppKeychainGroups(descriptor, other) indexOfObject:foreign]], status,
                    status == errSecItemNotFound || status == errSecMissingEntitlement);
            }
        }
        NSMutableDictionary *all = [ItemQuery((__bridge id)kSecClassGenericPassword, groups[0], service) mutableCopy];
        [all removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        all[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
        all[(__bridge id)kSecReturnAttributes] = @YES;
        CFTypeRef found = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)all, &found);
        id objects = CFBridgingRelease(found);
        NSMutableSet *visible = [NSMutableSet set];
        if ([objects isKindOfClass:NSArray.class]) for (NSDictionary *item in objects)
            if ([item isKindOfClass:NSDictionary.class] && item[(__bridge id)kSecAttrAccessGroup]) [visible addObject:item[(__bridge id)kSecAttrAccessGroup]];
        Record(@"omitted-group-search", status, status == errSecSuccess && [objects isKindOfClass:NSArray.class] && [objects count] == 3 && [visible isEqual:[NSSet setWithArray:groups]]);
    }
    NSDictionary *report = @{@"role":role, @"phase":phase, @"passed":@(!Failed), @"results":Results, @"references":references};
    NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:nil];
    [[NSFileHandle fileHandleWithStandardOutput] writeData:json];
    return Failed ? 1 : 0;
} }
