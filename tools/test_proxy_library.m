#import <Foundation/Foundation.h>
#import "RBXProxyLibrary.h"
#import "RBXSecureConfig.h"
#import "RBXHTTPProxy.h"
static NSDictionary *record;
static BOOL readFailure;
@implementation RBXSecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error {if(readFailure){if(error)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];return nil;}return record;}
+ (BOOL)saveRotationConfiguration:(NSDictionary *)update error:(NSError **)error {
 NSCAssert(!update[@"accessKey"],@"Library mutations must never replace the license");
 NSMutableDictionary *next=[record mutableCopy]?:[NSMutableDictionary dictionary];[next addEntriesFromDictionary:update];record=next;return YES;
}
@end
static NSDictionary *Entry(NSString *identifier,NSString *url) {return @{@"id":identifier,@"name":identifier,@"proxyURL":url,@"rotationURL":@""};}
int main(void){@autoreleasepool{
 for (id input in @[(id)NSNull.null, @42, @"", @"HTTP host:80:u:p\nother", @"host:+80:u:p", @"host:8.0:u:p", @"http://[bad::ip]:80", @"http://-bad.example:80"]) {
  NSCAssert(![RBXProxyLibrary normalizedURL:input], @"Unsafe/ambiguous input must be rejected without throwing");
 }
 for (NSString *input in @[@" HTTP proxy.example:8080:u:p \n", @"proxy.example:8080:u:p", @"u:p@proxy.example:8080", @"HTTP://u:p@PROXY.EXAMPLE:8080/"]) {
  NSString *normalized=[RBXProxyLibrary normalizedURL:input];
  NSCAssert([normalized isEqual:@"http://u:p@proxy.example:8080"], @"Common pasted formats canonicalize identically");
  NSCAssert([[RBXProxyLibrary normalizedURL:normalized] isEqual:normalized], @"Normalization must be idempotent");
 }
 NSDictionary *ipv6=RBXParseHTTPProxyURL([RBXProxyLibrary normalizedURL:@"[2001:db8::1]:8080:user:pa:ss@word%2F"]);
 NSCAssert([ipv6[@"host"] isEqual:@"2001:db8::1"] && [ipv6[@"password"] isEqual:@"pa:ss@word%2F"], @"Bracketed IPv6 provider format preserves literal credentials");
 record=@{@"proxyURL":@"http://old:secret@proxy.example:8080",@"accessKey":@"UNCHANGED"};
 NSCAssert([RBXProxyLibrary entries:nil].count==1, @"Legacy configured proxy appears without writing");
 NSCAssert(!record[@"proxyLibrary"],@"Listing is read-only");
 NSCAssert([[RBXProxyLibrary selectedIdentifier:nil] isEqual:@"current"],@"Legacy selection retained");
 NSCAssert([RBXProxyLibrary saveEntry:Entry(@"second",@"proxy.example:8081:new:secret") error:nil],@"Provider colon format accepted");
 NSCAssert([RBXProxyLibrary entries:nil].count==2 && [record[@"proxyURL"] isEqual:@"http://old:secret@proxy.example:8080"],@"Adding another proxy preserves selected connection");
 NSCAssert([RBXProxyLibrary selectIdentifier:@"second" error:nil],@"Selection succeeds");
 NSCAssert([record[@"proxyURL"] isEqual:@"http://new:secret@proxy.example:8081"],@"Selected connection normalized");
 NSCAssert([RBXProxyLibrary saveEntry:Entry(@"second",@"proxy.example:8082:new:secret") error:nil],@"Edit selected proxy");
 NSCAssert([record[@"proxyURL"] hasSuffix:@":8082"],@"Selected edit applied");
 NSCAssert([RBXProxyLibrary deleteIdentifier:@"current" error:nil] && ![record[@"proxyDisabled"] boolValue],@"Deleting inactive proxy preserves selected connection");
 NSCAssert([RBXProxyLibrary deleteIdentifier:@"second" error:nil] && [record[@"proxyDisabled"] boolValue] && ![record[@"proxyURL"] length],@"Deleting selected proxy explicitly blocks fallback");
 NSCAssert([record[@"accessKey"] isEqual:@"UNCHANGED"],@"License preserved through entire CRUD sequence");
 NSCAssert([RBXProxyLibrary entries:nil].count==0,@"Deleted list remains empty");
 NSDictionary *before=record;readFailure=YES;
 NSCAssert(![RBXProxyLibrary saveEntry:Entry(@"new",@"proxy.example:80") error:nil] && [record isEqual:before],@"Unreadable Keychain cannot overwrite existing data");readFailure=NO;
 NSCAssert(![RBXProxyLibrary selectIdentifier:@"missing" error:nil],@"Missing selection fails");
 for(NSString *url in @[@"host:99999:user:pass",@"socks5://host:80",@"https://host:80",@"http://host:80/path",@"http://user%0a:pass@host:80"]) NSCAssert(![RBXProxyLibrary normalizedURL:url],@"Malformed proxy rejected");
 NSCAssert([RBXProxyLibrary normalizedURL:@"host:80:user:pa:ss@word"],@"Special credentials are URL encoded");
 NSCAssert([RBXProxyLibrary saveEntry:Entry(@"new",@"proxy.example:80") error:nil] && ![record[@"proxyDisabled"] boolValue],@"Adding the first proxy enables the explicit new selection");
 NSLog(@"Proxy library migration, CRUD, credential format, license retention and fail-closed tests passed");
}return 0;}
