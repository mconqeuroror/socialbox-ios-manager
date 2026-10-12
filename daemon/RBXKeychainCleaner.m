// Explicit deletion only. The installed binary is an inert template; its
// private runtime copy must carry precisely the target clone's access groups.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <errno.h>
#import <grp.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import "../shared/RBXAppKeychainPolicy.h"

static BOOL RBXMobileIdentity(void) {
    if (getuid() != 501 || geteuid() != 501 || getgid() != 501 || getegid() != 501) return NO;
    // Darwin reports the primary group even after setgroups(0, NULL).
    // Accept only that mobile group (or an empty list), never extra groups.
    gid_t group = (gid_t)-1;
    int count = getgroups(1, &group);
    return count == 0 || (count == 1 && group == 501);
}

static BOOL RBXDropToMobile(NSString **stage) {
    *stage = @"identity-root-required";
    if (getuid() != 0 || geteuid() != 0) return NO;
    *stage = @"identity-clear-groups";
    if (setgroups(0, NULL) != 0) return NO;
    *stage = @"identity-setgid";
    if (setgid(501) != 0) return NO;
    *stage = @"identity-setuid";
    if (setuid(501) != 0) return NO;
    *stage = @"identity-mobile-required";
    if (!RBXMobileIdentity()) return NO;
    // Verify that saved credentials cannot restore root before Security is used.
    *stage = @"identity-saved-gid";
    errno = 0;
    if (setgid(0) == 0 || errno != EPERM) return NO;
    *stage = @"identity-saved-uid";
    errno = 0;
    if (setuid(0) == 0 || errno != EPERM) return NO;
    *stage = @"identity-mobile-required";
    return RBXMobileIdentity();
}

static BOOL RBXEffectiveEntitlementsMatch(NSDictionary *descriptor, NSString *bundle, NSArray *expectedGroups) {
    // SecTask is available at runtime on iOS; avoid a private SDK header.
    typedef struct __SecTask *RBXSecTaskRef;
    typedef RBXSecTaskRef (*CreateTaskFn)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlementFn)(RBXSecTaskRef, CFStringRef, CFErrorRef *);
    void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    CreateTaskFn createTask = security ? (CreateTaskFn)dlsym(security, "SecTaskCreateFromSelf") : NULL;
    CopyEntitlementFn copyValue = security ? (CopyEntitlementFn)dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
    if (!createTask || !copyValue) { if (security) dlclose(security); return NO; }
    RBXSecTaskRef task = createTask(kCFAllocatorDefault);
    if (!task) { dlclose(security); return NO; }
    id application = CFBridgingRelease(copyValue(task, CFSTR("application-identifier"), NULL));
    id team = CFBridgingRelease(copyValue(task, CFSTR("com.apple.developer.team-identifier"), NULL));
    id groups = CFBridgingRelease(copyValue(task, CFSTR("keychain-access-groups"), NULL));
    id appGroups = CFBridgingRelease(copyValue(task, CFSTR("com.apple.security.application-groups"), NULL));
    CFRelease(task);
    dlclose(security);
    // App groups also expand the effective keychain access-group set on iOS.
    return [application isKindOfClass:NSString.class] && [application isEqualToString:RBXAppKeychainGroup(descriptor, bundle)] &&
        [team isKindOfClass:NSString.class] && [team isEqualToString:descriptor[@"teamIdentifier"]] &&
        [groups isKindOfClass:NSArray.class] && [groups isEqualToArray:expectedGroups] &&
        (!appGroups || ([appGroups isKindOfClass:NSArray.class] && [appGroups count] == 0));
}

static NSMutableDictionary *RBXClassQuery(CFStringRef itemClass, NSString *group) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)itemClass,
        (__bridge id)kSecAttrAccessGroup: group,
        (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny,
        (__bridge id)kSecUseDataProtectionKeychain: @YES,
        (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUIFail,
    } mutableCopy];
}

static OSStatus RBXCopyStatus(NSDictionary *query, id *value) {
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    id object = CFBridgingRelease(result);
    if (value) *value = object;
    return status;
}

static BOOL RBXProveGroupAccess(NSString *group, NSString *nonce, NSString **stage, OSStatus *status) {
    *stage = @"canary-random";
    NSMutableData *bytes = [NSMutableData dataWithLength:32];
    *status = SecRandomCopyBytes(kSecRandomDefault, bytes.length, bytes.mutableBytes);
    if (*status != errSecSuccess) return NO;
    NSMutableDictionary *probe = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccessGroup: group,
        (__bridge id)kSecAttrService: @"com.redditbox.keychain-cleaner.authorization",
        (__bridge id)kSecAttrAccount: [NSString stringWithFormat:@"%@.%@", nonce, NSUUID.UUID.UUIDString],
        (__bridge id)kSecAttrSynchronizable: @NO,
        (__bridge id)kSecUseDataProtectionKeychain: @YES,
    } mutableCopy];
    NSMutableDictionary *addition = [probe mutableCopy];
    addition[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    addition[(__bridge id)kSecValueData] = bytes;
    *stage = @"canary-add";
    *status = SecItemAdd((__bridge CFDictionaryRef)addition, NULL);
    // In particular, an entitlement error or duplicate is never proof. Do not
    // delete an existing item when this unique add did not establish ownership.
    if (*status != errSecSuccess) return NO;

    NSMutableDictionary *read = [probe mutableCopy];
    read[(__bridge id)kSecReturnData] = @YES;
    read[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    read[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;
    *stage = @"canary-read";
    id value = nil;
    *status = RBXCopyStatus(read, &value);
    if (*status != errSecSuccess || ![value isKindOfClass:NSData.class] || ![value isEqualToData:bytes]) {
        // Only remove the fresh canary which this process successfully added.
        // An unsuccessful cleanup remains an incomplete operation and is never
        // promoted into permission to erase the rest of the clone group.
        SecItemDelete((__bridge CFDictionaryRef)probe);
        if (*status == errSecSuccess) *status = errSecDecode;
        return NO;
    }
    *stage = @"canary-delete";
    *status = SecItemDelete((__bridge CFDictionaryRef)probe);
    if (*status != errSecSuccess) return NO;
    *stage = @"canary-verify";
    *status = RBXCopyStatus(read, NULL);
    if (*status != errSecItemNotFound) return NO;
    *status = errSecSuccess;
    return YES;
}

static int RBXEmitReceipt(NSMutableDictionary *receipt, NSString *stage, OSStatus status, BOOL cleared) {
    receipt[@"stage"] = stage ?: @"internal";
    receipt[@"osStatus"] = @(status);
    receipt[@"status"] = cleared ? @"cleared" : @"incomplete";
    receipt[@"uid"] = @(getuid());
    receipt[@"gid"] = @(getgid());
    NSData *json = [NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
    if (!json.length || json.length + 1 > 4096) return 1;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = line.bytes;
    NSUInteger offset = 0;
    while (offset < line.length) {
        ssize_t count = write(STDOUT_FILENO, bytes + offset, line.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 1;
        offset += (NSUInteger)count;
    }
    return cleared ? 0 : 1;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        umask(077);
        NSMutableDictionary *receipt = [@{
            @"formatVersion": @1, @"nonce": @"", @"bundleIdentifier": @"", @"accessGroup": @"",
            @"status": @"incomplete", @"proof": @NO, @"classes": @[],
        } mutableCopy];
        @try {
            if (argc != 3 || strnlen(argv[1], 128) >= 128 || strnlen(argv[2], 37) != 36)
                return RBXEmitReceipt(receipt, @"arguments", errSecParam, NO);
            NSString *identifier = [NSString stringWithUTF8String:argv[1]];
            NSString *nonce = [NSString stringWithUTF8String:argv[2]];
            NSUUID *uuid = nonce ? [[NSUUID alloc] initWithUUIDString:nonce] : nil;
            NSDictionary *descriptor = RBXAppDescriptorForBundleIdentifier(identifier);
            NSArray<NSString *> *groups = RBXAppKeychainGroups(descriptor, identifier);
            if (!groups.count || !uuid ||
                [uuid.UUIDString caseInsensitiveCompare:nonce] != NSOrderedSame)
                return RBXEmitReceipt(receipt, @"arguments", errSecParam, NO);
            receipt[@"nonce"] = nonce;
            receipt[@"bundleIdentifier"] = identifier;
            receipt[@"accessGroup"] = groups.firstObject;
            BOOL multiGroup = RBXAppKeychainMappingEnabled(descriptor);
            NSMutableArray *groupReceipts = [NSMutableArray array];
            if (multiGroup) {
                receipt[@"formatVersion"] = @2;
                receipt[@"appType"] = descriptor[@"appType"];
                [receipt addEntriesFromDictionary:RBXAppKeychainMetadata(descriptor, identifier)];
                receipt[@"groups"] = groupReceipts;
            }

            NSString *stage = nil;
            // No SecTask, SecRandom or SecItem operation precedes this drop.
            if (!RBXDropToMobile(&stage)) return RBXEmitReceipt(receipt, stage, errSecAuthFailed, NO);
            if (!RBXEffectiveEntitlementsMatch(descriptor, identifier, groups))
                return RBXEmitReceipt(receipt, @"effective-entitlements", errSecMissingEntitlement, NO);
            OSStatus status = errSecSuccess;

            // Identities pair certificates and private keys; they are not a
            // fifth independent stored class. Clear and prove both underlying
            // classes instead of accepting an unsupported identity query.
            NSArray *classes = @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword,
                (__bridge id)kSecClassCertificate, (__bridge id)kSecClassKey];
            NSArray<NSString *> *names = @[@"genp", @"inet", @"cert", @"keys"];
            for (NSString *group in groups) {
                NSMutableArray *verified = [NSMutableArray array];
                NSMutableDictionary *groupReceipt = [@{@"accessGroup":group, @"proof":@NO, @"classes":verified} mutableCopy];
                if (multiGroup) { [groupReceipts addObject:groupReceipt]; receipt[@"activeGroup"] = group; }
                if (!RBXProveGroupAccess(group, nonce, &stage, &status))
                    return RBXEmitReceipt(receipt, stage, status, NO);
                groupReceipt[@"proof"] = @YES;
                // Preserve the existing single-group receipt throughout failure
                // and success. Multi-group success requires every group below.
                if (!multiGroup) { receipt[@"proof"] = @YES; receipt[@"classes"] = verified; }
                for (NSUInteger index = 0; index < classes.count; index++) {
                    if (!RBXMobileIdentity()) return RBXEmitReceipt(receipt, @"identity-before-erase", errSecAuthFailed, NO);
                    NSMutableDictionary *query = RBXClassQuery((__bridge CFStringRef)classes[index], group);
                    status = SecItemDelete((__bridge CFDictionaryRef)query);
                    if (status != errSecSuccess && status != errSecItemNotFound)
                        return RBXEmitReceipt(receipt, [@"delete-" stringByAppendingString:names[index]], status, NO);
                    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
                    query[(__bridge id)kSecReturnAttributes] = @YES;
                    status = RBXCopyStatus(query, NULL);
                    if (status != errSecItemNotFound)
                        return RBXEmitReceipt(receipt, [@"verify-" stringByAppendingString:names[index]], status, NO);
                    [verified addObject:names[index]];
                }
            }
            receipt[@"proof"] = @YES;
            receipt[@"classes"] = names;
            // Recheck every class after all mutations; the parent also requires
            // stopped clone processes and CLOSED traffic throughout deletion.
            for (NSString *group in groups) {
                if (multiGroup) receipt[@"activeGroup"] = group;
                for (NSUInteger index = 0; index < classes.count; index++) {
                    NSMutableDictionary *query = RBXClassQuery((__bridge CFStringRef)classes[index], group);
                    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
                    query[(__bridge id)kSecReturnAttributes] = @YES;
                    status = RBXCopyStatus(query, NULL);
                    if (status != errSecItemNotFound)
                        return RBXEmitReceipt(receipt, [@"final-verify-" stringByAppendingString:names[index]], status, NO);
                }
            }
            if (!RBXMobileIdentity()) return RBXEmitReceipt(receipt, @"identity-final", errSecAuthFailed, NO);
            [receipt removeObjectForKey:@"activeGroup"];
            return RBXEmitReceipt(receipt, @"complete", errSecSuccess, YES);
        } @catch (NSException *exception) {
            return RBXEmitReceipt(receipt, @"internal", errSecInternalComponent, NO);
        }
    }
}
