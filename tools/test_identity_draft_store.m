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
static void Check(BOOL ok) { if(!ok){fprintf(stderr,"FAIL private identity draft fixture\n");exit(1);} }
int main(void){@autoreleasepool{
 items=[NSMutableDictionary dictionary];
 NSDictionary *config=@{@"accessKey":@"FIXTURE-LICENSE",@"proxyURL":@"http://fixture.invalid:9"};
 Check([RBXSecureConfig saveRotationConfiguration:config error:nil]);NSDictionary *before=[RBXSecureConfig rotationConfiguration:nil];
 NSString *request=@"00000000-0000-4000-8000-000000000001";
 NSDictionary *draft=@{@"containerId":@"fixture-a",@"idfv":@"00000000-0000-4000-8000-000000000002"};
 Check([RBXSecureConfig saveIdentityEditorDraft:draft requestID:request error:nil]);
 Check([[RBXSecureConfig identityEditorDraftForRequestID:request container:@"fixture-a" error:nil] isEqual:draft]);
 Check(![RBXSecureConfig identityEditorDraftForRequestID:request container:@"fixture-b" error:nil]);
 Check(![RBXSecureConfig identityEditorDraftForRequestID:@"00000000-0000-4000-8000-000000000003" container:@"fixture-a" error:nil]);
 Check([[RBXSecureConfig rotationConfiguration:nil] isEqual:before]);Check(items.count==2);
 NSString *key=@"com.redditbox.private.identity-editor/latest-draft";NSData *valid=items[key];
 for(NSNumber *offset in @[@(-301),@100]){
  NSMutableDictionary *record=[[NSPropertyListSerialization propertyListWithData:valid options:0 format:nil error:nil] mutableCopy];
  record[@"createdAt"]=@(NSDate.date.timeIntervalSince1970+offset.doubleValue);
  items[key]=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
  Check(![RBXSecureConfig identityEditorDraftForRequestID:request container:@"fixture-a" error:nil]);
 }
 items[key]=valid;locked=YES;Check(![RBXSecureConfig identityEditorDraftForRequestID:request container:@"fixture-a" error:nil]);Check(![RBXSecureConfig saveIdentityEditorDraft:draft requestID:request error:nil]);locked=NO;
 items[key]=[NSPropertyListSerialization dataWithPropertyList:@[] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];Check(![RBXSecureConfig identityEditorDraftForRequestID:request container:@"fixture-a" error:nil]);
 Check(![RBXSecureConfig saveIdentityEditorDraft:@{@"containerId":@"fixture-a",@"large":[@"x" stringByPaddingToLength:70000 withString:@"x" startingAtIndex:0]} requestID:request error:nil]);
 Check([RBXSecureConfig saveIdentityEditorDraft:draft requestID:request error:nil]);Check(items.count==2);
 Check([[RBXSecureConfig rotationConfiguration:nil] isEqual:before]);
 puts("PASS private draft readback, request/container binding, expiration, locked/corrupt/oversized rejection and separate license/proxy preservation; no real Keychain used");
}return 0;}
