// Execute the actual private editor channel with synthetic Security calls.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
static OSStatus MockCopy(CFDictionaryRef,CFTypeRef *);
static OSStatus MockAdd(CFDictionaryRef,CFTypeRef *);
static OSStatus MockUpdate(CFDictionaryRef,CFDictionaryRef);
static OSStatus MockDelete(CFDictionaryRef);
#define SecItemCopyMatching MockCopy
#define SecItemAdd MockAdd
#define SecItemUpdate MockUpdate
#define SecItemDelete MockDelete
#import "../shared/RBXSecureConfig.m"
#undef SecItemCopyMatching
#undef SecItemAdd
#undef SecItemUpdate
#undef SecItemDelete
static NSMutableDictionary *items;
static BOOL locked;
static NSString *Key(NSDictionary *query) {
    NSCAssert([query[(__bridge id)kSecAttrAccessGroup] isEqual:@"RBXBOXCFG.com.redditbox.config"],@"exact app access group");
    return [NSString stringWithFormat:@"%@/%@",query[(__bridge id)kSecAttrService],query[(__bridge id)kSecAttrAccount]];
}
static OSStatus MockCopy(CFDictionaryRef raw,CFTypeRef *out) {
    if(locked)return errSecInteractionNotAllowed;
    NSDictionary *query=(__bridge NSDictionary *)raw;
    if ([query[(__bridge id)kSecMatchLimit] isEqual:(__bridge id)kSecMatchLimitAll]) {
        NSMutableArray *found=[NSMutableArray array];NSString *prefix=[query[(__bridge id)kSecAttrService] stringByAppendingString:@"/"];
        for(NSString *key in items) if([key hasPrefix:prefix]) [found addObject:@{(__bridge id)kSecAttrAccount:[key substringFromIndex:prefix.length],(__bridge id)kSecValueData:items[key]}];
        if(out)*out=CFBridgingRetain(found);return errSecSuccess;
    }
    NSData *value=items[Key((__bridge NSDictionary *)raw)];
    if(!value)return errSecItemNotFound;
    if(out)*out=CFBridgingRetain(value);return errSecSuccess;
}
static OSStatus MockAdd(CFDictionaryRef raw,CFTypeRef *out) {
    if(locked)return errSecInteractionNotAllowed;
    NSDictionary *q=(__bridge NSDictionary *)raw;
    NSCAssert([q[(__bridge id)kSecAttrAccessible] isEqual:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly],@"private device-only item");
    NSString *key=Key(q);if(items[key])return errSecDuplicateItem;
    items[key]=q[(__bridge id)kSecValueData];return errSecSuccess;
}
static OSStatus MockUpdate(CFDictionaryRef raw,CFDictionaryRef attributes) {
    if(locked)return errSecInteractionNotAllowed;
    NSString *key=Key((__bridge NSDictionary *)raw);if(!items[key])return errSecItemNotFound;
    items[key]=((__bridge NSDictionary *)attributes)[(__bridge id)kSecValueData];return errSecSuccess;
}
static OSStatus MockDelete(CFDictionaryRef raw) { [items removeObjectForKey:Key((__bridge NSDictionary *)raw)];return errSecSuccess; }
static void Check(BOOL ok) { if(!ok){fprintf(stderr,"FAIL private cloud vault fixture\n");exit(1);} }
int main(void){@autoreleasepool{
 items=[NSMutableDictionary dictionary];
 NSString *identifier=@"00000000-0000-4000-8000-000000000001";
 NSDictionary *payload=@{@"appType":@"reddit",@"passphrase":@"synthetic-secret-phrase"};
 Check([RBXSecureConfig saveCloudVaultPayload:payload identifier:identifier response:NO error:nil]);
 Check([[RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:NO error:nil] isEqual:payload]);
 Check(![RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:YES error:nil]);
 Check(![RBXSecureConfig cloudVaultPayloadForIdentifier:NSUUID.UUID.UUIDString response:NO error:nil]);
 Check(![RBXSecureConfig saveCloudVaultPayload:payload identifier:@"invalid" response:NO error:nil]);
 Check([RBXSecureConfig saveCloudVaultPayload:@{@"backups":@[]} identifier:identifier response:YES error:nil]);
 Check(items.count==2);
 NSString *key=[@"com.redditbox.private.cloud-vault/input:" stringByAppendingString:identifier];NSData *valid=items[key];
 for(NSNumber *offset in @[@(-301),@100]){
  NSMutableDictionary *record=[[NSPropertyListSerialization propertyListWithData:valid options:0 format:nil error:nil] mutableCopy];record[@"createdAt"]=@(NSDate.date.timeIntervalSince1970+offset.doubleValue);
  items[key]=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  Check(![RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:NO error:nil]);
 }
 items[key]=valid;locked=YES;Check(![RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:NO error:nil]);Check(![RBXSecureConfig saveCloudVaultPayload:payload identifier:identifier response:NO error:nil]);locked=NO;
 Check(![RBXSecureConfig saveCloudVaultPayload:@{@"large":[@"x" stringByPaddingToLength:300000 withString:@"x" startingAtIndex:0]} identifier:identifier response:NO error:nil]);
 [RBXSecureConfig clearCloudVaultPayloadForIdentifier:NSUUID.UUID.UUIDString response:NO];Check(items.count==2);
 [RBXSecureConfig clearCloudVaultPayloadForIdentifier:identifier response:NO];Check(items.count==1);
 Check([RBXSecureConfig cloudVaultPayloadForIdentifier:identifier response:YES error:nil]!=nil);
 Check(![RBXSecureConfig safeSummary][@"passphrase"]);
 puts("PASS private cloud channel: request/direction binding, device-only Keychain, expiry, locked/oversized rejection, targeted cleanup and no secret publication");
}return 0;}
