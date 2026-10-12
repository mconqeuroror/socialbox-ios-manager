#import "RBXSecureConfig.h"
#import <Security/Security.h>

static NSString *const RBXConfigAccessGroup =
    @"RBXBOXCFG.com.redditbox.config";
static NSString *const RBXConfigService =
    @"com.redditbox.secure.rotation";

static NSMutableDictionary *RBXConfigQuery(void) {
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: RBXConfigService,
        (__bridge id)kSecAttrAccount: @"global",
        (__bridge id)kSecAttrAccessGroup: RBXConfigAccessGroup,
    } mutableCopy];
}

static NSError *RBXConfigError(OSStatus status, NSString *message) {
    return [NSError errorWithDomain:@"com.redditbox.secure-config"
        code:status userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSDictionary *RBXSemanticRecord(NSDictionary *record) {
    NSMutableDictionary *semantic = [record mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *key in @[@"updatedAt", @"cloudUpdatedAt", @"source", @"formatVersion",
        @"proxyURL", @"rotationURL", @"authHeader", @"authorization", @"method"])
        [semantic removeObjectForKey:key];
    [semantic addEntriesFromDictionary:[RBXSecureConfig effectiveRotationConfiguration:record]];
    return semantic;
}

@interface RBXSecureConfig ()
+ (BOOL)_persistRotationRecord:(NSDictionary *)record error:(NSError **)error;
@end

@implementation RBXSecureConfig


+ (NSMutableDictionary *)cloudVaultQuery:(NSString *)identifier response:(BOOL)response {
    NSMutableDictionary *query = RBXConfigQuery();
    query[(__bridge id)kSecAttrService] = @"com.redditbox.private.cloud-vault";
    if (identifier) query[(__bridge id)kSecAttrAccount] = [(response ? @"response:" : @"input:") stringByAppendingString:identifier];
    else [query removeObjectForKey:(__bridge id)kSecAttrAccount];
    return query;
}

+ (BOOL)saveCloudVaultPayload:(NSDictionary *)payload identifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error {
    if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier] || ![payload isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *record = @{@"identifier":identifier,@"createdAt":@(NSDate.date.timeIntervalSince1970),@"payload":payload};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || data.length > 256 * 1024) return NO;
    // Reap expired abandoned requests without replacing another request's slot.
    NSMutableDictionary *all = [self cloudVaultQuery:nil response:NO];
    all[(__bridge id)kSecReturnAttributes] = @YES; all[(__bridge id)kSecReturnData] = @YES;
    all[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    CFTypeRef raw = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)all,&raw);
    id items = CFBridgingRelease(raw);
    if (status != errSecSuccess && status != errSecItemNotFound) {
        if (error) *error = RBXConfigError(status,@"Unlock the phone to access cloud encryption settings."); return NO;
    }
    if (items && ![items isKindOfClass:NSArray.class]) return NO;
    NSUInteger live = 0;
    for (NSDictionary *item in items) {
        NSData *bytes = [item isKindOfClass:NSDictionary.class] ? item[(__bridge id)kSecValueData] : nil;
        id old = [bytes isKindOfClass:NSData.class] && bytes.length <= 256 * 1024 ? [NSPropertyListSerialization propertyListWithData:bytes options:0 format:nil error:nil] : nil;
        id time = [old isKindOfClass:NSDictionary.class] ? old[@"createdAt"] : nil;
        double age = [time isKindOfClass:NSNumber.class] ? NSDate.date.timeIntervalSince1970 - [time doubleValue] : -1;
        NSString *account = [item isKindOfClass:NSDictionary.class] ? item[(__bridge id)kSecAttrAccount] : nil;
        if (!(age >= 0 && age <= 300) && [account isKindOfClass:NSString.class]) {
            NSMutableDictionary *expired = [self cloudVaultQuery:nil response:NO];
            expired[(__bridge id)kSecAttrAccount] = account;
            SecItemDelete((__bridge CFDictionaryRef)expired);
        } else live++;
    }
    if (live >= 64) { if (error) *error = RBXConfigError(errSecAllocate,@"Finish pending cloud operations before starting another."); return NO; }
    NSMutableDictionary *query = [self cloudVaultQuery:identifier response:response];
    // An identifier is write-once. Reuse must never replace another operation.
    query[(__bridge id)kSecValueData] = data;
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
    status = SecItemAdd((__bridge CFDictionaryRef)query,NULL);
    if (status != errSecSuccess && error) *error = RBXConfigError(status,@"Private cloud details could not be stored. Unlock the phone and retry.");
    return status == errSecSuccess;
}

+ (NSDictionary *)cloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error {
    if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier]) return nil;
    NSMutableDictionary *query = [self cloudVaultQuery:identifier response:response];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef raw = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query,&raw);
    id data = CFBridgingRelease(raw);
    id record = status == errSecSuccess && [data isKindOfClass:NSData.class] && [data length] <= 256 * 1024 ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    id time = [record isKindOfClass:NSDictionary.class] ? record[@"createdAt"] : nil;
    double age = [time isKindOfClass:NSNumber.class] ? NSDate.date.timeIntervalSince1970 - [time doubleValue] : -1;
    if (![record isKindOfClass:NSDictionary.class] || ![record[@"identifier"] isEqual:identifier] || ![record[@"payload"] isKindOfClass:NSDictionary.class] || !(age >= 0 && age <= 300)) {
        if (error) *error = RBXConfigError(status ?: errSecDecode,@"Private cloud details are unavailable or expired. Refresh to try again."); return nil;
    }
    return record[@"payload"];
}

+ (void)clearCloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response {
    if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier]) return;
    SecItemDelete((__bridge CFDictionaryRef)[self cloudVaultQuery:identifier response:response]);
}

// UI-003: raw identifiers never enter the world-readable launcher state or IPC receipt.
+ (NSMutableDictionary *)identityDraftQuery {
    NSMutableDictionary *query = RBXConfigQuery();
    query[(__bridge id)kSecAttrService] = @"com.redditbox.private.identity-editor";
    query[(__bridge id)kSecAttrAccount] = @"latest-draft";
    return query;
}

+ (BOOL)saveIdentityEditorDraft:(NSDictionary *)draft requestID:(NSString *)requestID error:(NSError **)error {
    if (![[NSUUID alloc] initWithUUIDString:requestID] ||
        ![draft[@"containerId"] isKindOfClass:NSString.class] || ![draft[@"containerId"] length]) return NO;
    NSDictionary *record = @{@"requestId":requestID, @"createdAt":@(NSDate.date.timeIntervalSince1970), @"draft":draft};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data || data.length > 64 * 1024) return NO;
    NSMutableDictionary *query = [self identityDraftQuery];
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});
    if (status == errSecItemNotFound) {
        query[(__bridge id)kSecValueData] = data;
        query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    if (status != errSecSuccess && error) *error = RBXConfigError(status, @"Unlock the phone to load the private identity editor.");
    return status == errSecSuccess;
}

+ (NSDictionary *)identityEditorDraftForRequestID:(NSString *)requestID container:(NSString *)container error:(NSError **)error {
    NSMutableDictionary *query = [self identityDraftQuery];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef raw = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &raw);
    id data = CFBridgingRelease(raw);
    id record = status == errSecSuccess && [data isKindOfClass:NSData.class] && [data length] <= 64 * 1024
        ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    NSDictionary *draft = [record isKindOfClass:NSDictionary.class] && [record[@"draft"] isKindOfClass:NSDictionary.class] ? record[@"draft"] : nil;
    NSTimeInterval age = [record isKindOfClass:NSDictionary.class] && [record[@"createdAt"] isKindOfClass:NSNumber.class]
        ? NSDate.date.timeIntervalSince1970 - [record[@"createdAt"] doubleValue] : -1;
    if (!draft || ![record[@"requestId"] isEqual:requestID] || ![draft[@"containerId"] isEqual:container] || !(age >= 0 && age <= 300)) {
        if (error) *error = RBXConfigError(status ?: errSecDecode, @"Identity details are unavailable or expired. Tap Reload.");
        return nil;
    }
    return draft;
}

+ (NSString *)accessGroup {
    return RBXConfigAccessGroup;
}

+ (NSDictionary *)effectiveRotationConfiguration:(NSDictionary *)configuration {
    NSMutableDictionary *effective = [NSMutableDictionary dictionary];
    if (![configuration isKindOfClass:NSDictionary.class]) return effective;
    for (NSString *key in @[@"proxyURL", @"rotationURL", @"authHeader", @"method"]) {
        NSString *value = [configuration[key] isKindOfClass:NSString.class] ? configuration[key] : nil;
        if (value.length) effective[key] = [key isEqualToString:@"method"] ? value.uppercaseString : value;
    }
    // An empty credential is an explicit clear; absence inherits the fallback.
    // With a saved proxy, an empty link explicitly disables optional rotation.
    if ([effective[@"proxyURL"] length] && [configuration[@"rotationURL"] isKindOfClass:NSString.class])
        effective[@"rotationURL"] = configuration[@"rotationURL"];
    if ([configuration[@"authorization"] isKindOfClass:NSString.class])
        effective[@"authorization"] = configuration[@"authorization"];
    return effective;
}

+ (NSDictionary *)rotationConfiguration:(NSError **)error {
    NSMutableDictionary *query = RBXConfigQuery();
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) return nil;
    if (status != errSecSuccess) {
        if (result) CFRelease(result);
        if (error) *error = RBXConfigError(status,
            @"Secure proxy settings could not be read.");
        return nil;
    }
    NSData *data = CFBridgingRelease(result);
    id value = [NSPropertyListSerialization propertyListWithData:data
        options:0 format:nil error:error];
    if (![value isKindOfClass:[NSDictionary class]]) {
        if (error && !*error) *error = RBXConfigError(errSecDecode,
            @"Secure proxy settings are corrupt.");
        return nil;
    }
    return value;
}

+ (BOOL)saveRotationConfiguration:(NSDictionary *)configuration
                             error:(NSError **)error {
    @synchronized (self) {
    NSError *readError = nil;
    NSDictionary *previous = [self rotationConfiguration:&readError];
    if (readError) { if (error) *error = readError; return NO; }
    NSMutableDictionary *record = [previous mutableCopy] ?: [NSMutableDictionary dictionary];
    [record addEntriesFromDictionary:configuration ?: @{}];
    if ([record[@"proxyDisabled"] boolValue] && [configuration[@"proxyURL"] isKindOfClass:NSString.class] && [configuration[@"proxyURL"] length] && !configuration[@"proxyDisabled"])
        record[@"proxyDisabled"] = @NO;
    if ([RBXSemanticRecord(previous) isEqualToDictionary:RBXSemanticRecord(record)]) return YES;
    record[@"formatVersion"] = @1;
    record[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
    return [self _persistRotationRecord:record error:error];
    }
}

+ (BOOL)_persistRotationRecord:(NSDictionary *)record error:(NSError **)error {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:record
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;

    NSMutableDictionary *query = RBXConfigQuery();
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
        (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status == errSecItemNotFound) {
        query[(__bridge id)kSecValueData] = data;
        query[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    }
    if (status != errSecSuccess && error) {
        *error = RBXConfigError(status, @"Secure proxy settings could not be saved.");
    }
    return status == errSecSuccess;
}

+ (NSString *)accessKey:(NSError **)error {
    NSDictionary *record = [self rotationConfiguration:error];
    return [record[@"accessKey"] isKindOfClass:[NSString class]]
        ? record[@"accessKey"] : nil;
}

+ (BOOL)saveAccessKey:(NSString *)accessKey error:(NSError **)error {
    NSString *normalized = [[accessKey ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        uppercaseString];
    if (normalized.length > 256) {
        if (error) *error = RBXConfigError(errSecParam, @"Access key is too long.");
        return NO;
    }
    return [self saveRotationConfiguration:@{@"accessKey": normalized} error:error];
}

+ (BOOL)clearRotationConfiguration:(NSError **)error {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)RBXConfigQuery());
    if (status == errSecSuccess || status == errSecItemNotFound) return YES;
    if (error) *error = RBXConfigError(status,
        @"Secure proxy settings could not be removed.");
    return NO;
}

+ (NSDictionary *)safeSummary {
    NSError *error = nil;
    NSDictionary *config = [self rotationConfiguration:&error];
    NSString *proxyText = [config[@"proxyURL"] isKindOfClass:[NSString class]]
        ? config[@"proxyURL"] : @"";
    NSString *rotationText = [config[@"rotationURL"] isKindOfClass:[NSString class]]
        ? config[@"rotationURL"] : @"";
    NSURL *proxy = proxyText.length ? [NSURL URLWithString:proxyText] : nil;
    NSURL *rotation = rotationText.length ? [NSURL URLWithString:rotationText] : nil;
    return @{
        @"configured": @(proxyText.length > 0 && ![config[@"proxyDisabled"] boolValue]),
        @"disabled": @([config[@"proxyDisabled"] boolValue]),
        @"readable": @(error == nil),
        @"source": [config[@"source"] isKindOfClass:[NSString class]]
            ? config[@"source"] : @"none",
        @"proxyHost": proxy.host ?: @"",
        @"rotationHost": rotation.host ?: @"",
        @"method": [config[@"method"] isKindOfClass:[NSString class]]
            ? config[@"method"] : @"",
        @"hasAuthorization": @([config[@"authorization"] isKindOfClass:[NSString class]] &&
                                [config[@"authorization"] length] > 0),
        @"updatedAt": [config[@"updatedAt"] isKindOfClass:[NSNumber class]]
            ? config[@"updatedAt"] : @0,
        @"error": error.localizedDescription ?: @"",
    };
}

@end
