#import <Foundation/Foundation.h>
#import "RBXProxyLibrary.h"
#import "RBXSecureConfig.h"
static NSDictionary *record;
static BOOL readFailure, writeFailure;
static NSUInteger writes, checks;
static void Check(BOOL ok, NSString *label) { checks++; if (!ok) { fprintf(stderr,"FAIL: %s\n",label.UTF8String); exit(1); } }
@implementation RBXSecureConfig
+ (NSDictionary *)rotationConfiguration:(NSError **)error {
 if(readFailure){if(error)*error=[NSError errorWithDomain:@"fixture" code:1 userInfo:nil];return nil;}return record;
}
+ (BOOL)saveRotationConfiguration:(NSDictionary *)update error:(NSError **)error {
 writes++; if(writeFailure)return NO;
 Check(!update[@"accessKey"] && !update[@"proxyURL"] && !update[@"selectedProxyId"],@"import cannot change license or selected connection");
 NSMutableDictionary *next=[record mutableCopy]?:[NSMutableDictionary dictionary];[next addEntriesFromDictionary:update];record=next;return YES;
}
@end
static NSDictionary *Preview(NSString *text) { return [RBXProxyLibrary importPreviewForText:text error:nil]; }
int main(void){@autoreleasepool{
 record=@{@"accessKey":@"KEEP",@"proxyURL":@"http://old:secret@old.example:80",@"source":@"cloud"};
 NSDictionary *original=record;
 NSString *text=@" HTTP proxy.example:8080:u:p\r\n\nhttp://u:p@PROXY.EXAMPLE:8080/\n[2001:db8::1]:8080:user:pa:ss@word%2F\nold.example:80:old:secret\n";
 NSDictionary *p=Preview(text);
 Check(p!=nil && [p[@"canImport"] boolValue],@"valid provider and IPv6 list can import");
 Check([p[@"newCount"] unsignedIntegerValue]==2 && [p[@"duplicateCount"] unsignedIntegerValue]==2 && [p[@"invalidCount"] unsignedIntegerValue]==0,@"semantic duplicates across list and existing library counted");
 Check([p[@"inputCount"] unsignedIntegerValue]==4,@"blank lines ignored and CRLF counted once");
 Check([record isEqual:original]&&writes==0,@"preview never writes");
 Check([RBXProxyLibrary importText:text reviewedPreview:p error:nil],@"reviewed import saves");
 Check(writes==1 && [RBXProxyLibrary entries:nil].count==3,@"batch stored with one write including legacy row");
 Check([record[@"proxyURL"] isEqual:original[@"proxyURL"]]&&[record[@"accessKey"] isEqual:@"KEEP"]&&[record[@"source"] isEqual:@"cloud"],@"selected connection, license and ownership preserved");
 Check([[RBXProxyLibrary selectedIdentifier:nil] isEqual:@"current"],@"legacy selection preserved");
 p=Preview(text);Check([p[@"newCount"] unsignedIntegerValue]==0 && ![p[@"canImport"] boolValue],@"repeated import has no new entries");
 Check(![RBXProxyLibrary importText:text reviewedPreview:p error:nil] && writes==1,@"empty duplicate-only import rejected without write");
 for(NSString *bad in @[@"socks5://host.example:80",@"SOCKS host.example:80",@"https://host.example:80",@"host.example:99999",@"user%0a:secret@host.example:80",@"host.example:80/path"]) {
  NSString *mixed=[@"good.example:81\n" stringByAppendingString:bad];p=Preview(mixed);original=record;NSUInteger before=writes;
  Check([p[@"invalidCount"] unsignedIntegerValue]==1 && ![p[@"canImport"] boolValue],@"unsupported or invalid row blocks complete batch");
  Check(![RBXProxyLibrary importText:mixed reviewedPreview:p error:nil] && writes==before && [record isEqual:original],@"no partial import");
  Check(![[p[@"issues"] description] containsString:@"secret"],@"issue messages never echo credentials");
 }
 p=Preview(@"fresh.example:8080");original=record;
 NSMutableDictionary *changed=[record mutableCopy];changed[@"proxyLibrary"]=@[];record=changed;
 Check(![RBXProxyLibrary importText:@"fresh.example:8080" reviewedPreview:p error:nil],@"changed library invalidates review");record=original;
 Check(![RBXProxyLibrary importText:@"different.example:8080" reviewedPreview:p error:nil],@"changed input invalidates review");
 NSMutableDictionary *forged=[p mutableCopy];forged[@"newCount"]=@50;
 Check(![RBXProxyLibrary importText:@"fresh.example:8080" reviewedPreview:forged error:nil],@"forged preview rejected");
 readFailure=YES;Check(Preview(@"fresh.example:8080")==nil,@"read failure cannot form preview");
 Check(![RBXProxyLibrary importText:@"fresh.example:8080" reviewedPreview:p error:nil] && [record isEqual:original],@"read failure preserves state");readFailure=NO;
 writeFailure=YES;NSUInteger before=writes;Check(![RBXProxyLibrary importText:@"fresh.example:8080" reviewedPreview:p error:nil]&&writes==before+1&&[record isEqual:original],@"failed secure write preserves complete library");writeFailure=NO;
 record=@{@"accessKey":@"KEEP",@"proxyDisabled":@YES};p=Preview(@"new.example:80");
 Check([RBXProxyLibrary importText:@"new.example:80" reviewedPreview:p error:nil],@"empty library import");
 Check(![RBXProxyLibrary selectedIdentifier:nil].length && [record[@"proxyDisabled"] boolValue] && !record[@"proxyURL"],@"first import never silently selects or enables network");
 NSMutableArray *hundred=[NSMutableArray array];
 for(NSUInteger i=0;i<100;i++)[hundred addObject:@{@"id":[NSString stringWithFormat:@"%lu",(unsigned long)i],@"name":@"Existing",@"proxyURL":[NSString stringWithFormat:@"http://host.example:%lu",(unsigned long)(1000+i)],@"rotationURL":@"",@"authorization":@"",@"authHeader":@"Authorization",@"method":@"GET"}];
 record=@{@"proxyLibrary":hundred};p=Preview(@"new.example:80");
 Check(![p[@"canImport"] boolValue] && [p[@"capacityExceeded"] boolValue],@"capacity enforced before save");
 original=record;before=writes;Check(![RBXProxyLibrary importText:@"new.example:80" reviewedPreview:p error:nil]&&writes==before&&[record isEqual:original],@"capacity failure preserves rows");
 for(id invalid in @[(id)NSNull.null,@42])Check(Preview(invalid)==nil,@"nontext rejected");
 Check(![Preview(@" \n\r\n")[@"canImport"] boolValue],@"empty list not importable");
 Check(Preview([@"x" stringByPaddingToLength:262145 withString:@"x" startingAtIndex:0])==nil,@"input bytes bounded");
 NSString *tooMany=[@"host:80\n" stringByPaddingToLength:9*501 withString:@"host:80\n" startingAtIndex:0];
 Check(Preview(tooMany)==nil,@"input lines bounded");
 fprintf(stdout,"PASS proxy import: %lu checks; preview, duplicates, all-or-none validation, one secure write, stale review, capacity, selection/license retention.\n",(unsigned long)checks);
}return 0;}
