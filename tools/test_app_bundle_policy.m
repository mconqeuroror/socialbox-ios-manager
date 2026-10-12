#import <Foundation/Foundation.h>
#import "RBXAppBundlePolicy.h"
static void check(BOOL ok, NSString *label) { if (!ok) { NSLog(@"FAIL: %@", label); exit(1); } }
int main(void) { @autoreleasepool {
 NSDictionary *rd=RBXRedditAppDescriptor(), *fb=RBXAppDescriptorForType(@"facebook");
 NSString *rdBundle=RBXAppBundleIdentifier(rd,@"test"), *fbBundle=RBXAppBundleIdentifier(fb,@"test");
 NSDictionary *source=@{@"CFBundleIdentifier":@"com.facebook.Facebook",@"FBKeychainAccessGroup":@"T84QZS65DQ.platformFamily",@"Unrelated":@[@"keep"]};
 NSMutableDictionary *legacy=[source mutableCopy];
 check(RBXRewriteAppKeychainInfo(legacy,rd,rdBundle,nil) && [legacy isEqual:source],@"Reddit metadata remains byte-equivalent");
 NSMutableDictionary *clone=[source mutableCopy];
 check(RBXRewriteAppKeychainInfo(clone,fb,fbBundle,nil),@"Facebook policy succeeds");
 check([clone[@"FBKeychainAccessGroup"] isEqual:@"SBXFBCLN00.socialbox.profile.fb.p975819681a395537"],@"Facebook family keychain replaced with exact clone group");
 check(RBXAppKeychainInfoMatches(clone,fb,fbBundle) && !RBXAppKeychainInfoMatches(source,fb,fbBundle),@"validation rejects unchanged shared family group");
 check([source[@"FBKeychainAccessGroup"] isEqual:@"T84QZS65DQ.platformFamily"],@"source dictionary unchanged");
 NSMutableDictionary *expected=[source mutableCopy]; expected[@"FBKeychainAccessGroup"]=clone[@"FBKeychainAccessGroup"];
 check([clone isEqual:expected],@"only audited key changes");
 NSMutableDictionary *again=[clone mutableCopy];
 check(RBXRewriteAppKeychainInfo(again,fb,fbBundle,nil) && [again isEqual:clone],@"idempotent rewrite");
 NSMutableDictionary *absent=[@{@"Unrelated":@"keep"} mutableCopy];
 check(RBXRewriteAppKeychainInfo(absent,fb,fbBundle,nil) && absent.count==1,@"no guessed source key inserted");
 for (id invalid in @[@42,@[],NSNull.null]) {
  NSMutableDictionary *bad=[source mutableCopy];bad[@"FBKeychainAccessGroup"]=invalid;
  NSDictionary *before=[bad copy];NSError *error=nil;
  check(!RBXRewriteAppKeychainInfo(bad,fb,fbBundle,&error) && error && [bad isEqual:before],@"malformed field fails before mutation");
 }
 for (NSString *wrong in @[rdBundle,@"com.facebook.Facebook",[fbBundle stringByAppendingString:@".suffix"]]) {
  NSMutableDictionary *bad=[source mutableCopy];NSError *error=nil;
  check(!RBXRewriteAppKeychainInfo(bad,fb,wrong,&error) && error && [bad isEqual:source],@"unowned bundle fails before mutation");
 }
 NSMutableDictionary *forged=[fb mutableCopy];forged[@"keychainInfoKeys"]=@[@"Unrelated"];
 check(!RBXRewriteAppKeychainInfo([source mutableCopy],forged,fbBundle,nil),@"forged descriptor rejected");
 puts("PASS: exact app keychain Info policy, Reddit preservation, foreign groups and malformed inputs");
} return 0; }
