#!/usr/bin/env python3
"""Compile shipped private cloud actions and chunk transport against inert services."""
from pathlib import Path
import subprocess,tempfile
ROOT=Path(__file__).resolve().parents[1]
s=(ROOT/'daemon/RBXCloudSync.m').read_text()
def code(signature):
 start=s.index(signature);return s[start:s.index('\n}\n',start)+3]
methods='\n'.join(code(x) for x in ['- (NSDictionary *)_transferJSON:', '- (BOOL)_uploadSealed:(NSData *)sealed metadata:(NSDictionary *)metadata context:(RBXOperationContext *)context error:(NSError **)error {','- (NSData *)_downloadParts:(NSDictionary *)manifest path:(NSString *)path context:(RBXOperationContext *)context error:(NSError **)error {','- (NSArray *)_vaultBackupsForApp:', '- (BOOL)_handleVaultRequest:'])
fixture=r'''
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "RBXCloudSync.h"
#import "RBXSecureConfig.h"
#import "RBXLicenseGuard.h"
#import "RBXAppRegistry.h"
static BOOL Allowed=YES,Licensed=YES,Paired=YES,WriteOK=YES,PrivateOK=YES;
static NSUInteger Checks;
static NSString *Fault,*RestoreApp,*RestoreID;
static NSMutableDictionary *Settings,*Private,*Parts;
static NSMutableArray *Requests;
static NSDictionary *Upload;
static void Check(BOOL ok,NSString *message){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}}
@interface RBXOperationContext:NSObject
@property NSString *requestID;
@end
@implementation RBXOperationContext @end
static NSError *RBXCloudInputError(NSString *s){return [NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:s}];}
static BOOL RBXCloudCheck(RBXOperationContext *c,NSError **e){if(c&&Allowed)return YES;if(e)*e=RBXCloudInputError(@"cancelled");return NO;}
static BOOL RBXCloudMessageCheck(RBXOperationContext *c,NSString **m){if(c&&Allowed)return YES;if(m)*m=@"cancelled";return NO;}
static NSString *RBXCloudString(NSDictionary *d,NSString *k){return [d[k] isKindOfClass:NSString.class]?d[k]:nil;}
static NSString *RBXCloudSHA256Hex(NSData *d){unsigned char out[CC_SHA256_DIGEST_LENGTH];CC_SHA256(d.bytes,(CC_LONG)d.length,out);NSMutableString *s=[NSMutableString string];for(int i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[s appendFormat:@"%02x",out[i]];return s;}
static NSMutableDictionary *RBXCloudReadPlist(void){return [Settings mutableCopy];}
static BOOL RBXCloudWritePlist(NSDictionary *d){if(WriteOK)Settings=[d mutableCopy];return WriteOK;}
static double kCloudHTTPTimeout=30;
@implementation RBXLicenseGuard
+ (instancetype)sharedGuard{static id instance;return instance?: (instance=[self new]);}
- (BOOL)isUnlocked{return Licensed;}
@end
@implementation RBXSecureConfig
+ (BOOL)saveCloudVaultPayload:(NSDictionary *)payload identifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error {if(!PrivateOK)return NO;Private[[NSString stringWithFormat:@"%@-%d",identifier,response]]=payload;return YES;}
+ (NSDictionary *)cloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response error:(NSError **)error{return Private[[NSString stringWithFormat:@"%@-%d",identifier,response]];}
+ (void)clearCloudVaultPayloadForIdentifier:(NSString *)identifier response:(BOOL)response{[Private removeObjectForKey:[NSString stringWithFormat:@"%@-%d",identifier,response]];}
@end
@interface RBXCloudSync (Fixture)
- (BOOL)_importWithBackupId:(NSString *)identifier expectedAppType:(NSString *)app context:(RBXOperationContext *)c message:(NSString **)m;
- (NSData *)_performDataRequest:(NSMutableURLRequest *)r context:(RBXOperationContext *)c error:(NSError **)e;
@end
@implementation RBXCloudSync
- (BOOL)paired{return Paired;}
- (NSString *)serverURL{return @"https://fixture.invalid";}
- (NSString *)deviceToken{return @"synthetic-bearer";}
- (NSString *)passphrase{return Settings[@"passphrase"];}
- (BOOL)_importWithBackupId:(NSString *)identifier expectedAppType:(NSString *)app context:(RBXOperationContext *)c message:(NSString **)m{RestoreApp=app;RestoreID=identifier;return Allowed;}
- (NSData *)_performDataRequest:(NSMutableURLRequest *)r context:(RBXOperationContext *)c error:(NSError **)e{
 if(!RBXCloudCheck(c,e))return nil;
 [Requests addObject:r];Check([r.URL.host isEqual:@"fixture.invalid"]&&[[r valueForHTTPHeaderField:@"Authorization"] isEqual:@"Bearer synthetic-bearer"],@"all requests use configured origin and device auth");
 Check(r.HTTPBody.length<1100000,@"each request is below Vercel limit");
 NSString *body=r.HTTPBody?[[NSString alloc]initWithData:r.HTTPBody encoding:NSUTF8StringEncoding]:@"";
 Check(![body containsString:@"synthetic-private-key"],@"HTTP never contains encryption key");
 if([Fault isEqual:@"transport"]){if(e)*e=RBXCloudInputError(@"network down");return nil;}
 NSURLComponents *url=[NSURLComponents componentsWithURL:r.URL resolvingAgainstBaseURL:NO];NSMutableDictionary *q=[NSMutableDictionary dictionary];for(NSURLQueryItem *item in url.queryItems)q[item.name]=item.value;
 id result=@{};
 if([r.URL.path isEqual:@"/api/backups"]){result=@{@"backups":@[@{@"id":@"abc123",@"appType":@"reddit",@"name":@"Research",@"size":@99},@{@"id":@"foreign",@"appType":@"facebook"},@{@"id":@"../bad",@"appType":@"reddit"}]};}
 else if([r.HTTPMethod isEqual:@"DELETE"]){result=@{@"ok":@YES};}
 else if([r.HTTPMethod isEqual:@"PUT"]){Parts[q[@"part"]]=r.HTTPBody;result=[Fault isEqual:@"part-receipt"]?@{}:@{@"ok":@YES};}
 else if([r.HTTPMethod isEqual:@"POST"]){NSDictionary *v=[NSJSONSerialization JSONObjectWithData:r.HTTPBody options:0 error:nil];if(v[@"complete"])result=[Fault isEqual:@"complete-receipt"]?@{}:@{@"backupId":v[@"complete"]};else{Upload=v;result=@{@"uploadId":@"0123456789abcdef0123456789abcdef",@"partBytes":@1048576};}}
 else if(q[@"part"]){return [Fault isEqual:@"corrupt-part"]?[@"wrong bytes" dataUsingEncoding:NSUTF8StringEncoding]:Parts[q[@"part"]];}
 return [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
}
__METHODS__
@end
static NSDictionary *Action(NSString *action){return @{@"action":action,@"appType":@"reddit",@"backupId":@"abc123",@"vaultInputId":@"input"};}
int main(void){@autoreleasepool{
 RBXCloudSync *cloud=[RBXCloudSync new];RBXOperationContext *context=[RBXOperationContext new];context.requestID=@"receipt";
 Settings=[@{@"passphrase":@"synthetic-private-key-original",@"serverURL":@"unchanged"} mutableCopy];Private=[NSMutableDictionary dictionary];Requests=[NSMutableArray array];Parts=[NSMutableDictionary dictionary];NSString *message=nil;NSError *error=nil;
 Check([cloud _handleVaultRequest:Action(@"cloudVaultKey") context:context message:&message],@"key reaches private response");Check([Private[@"receipt-1"][@"passphrase"] isEqual:Settings[@"passphrase"]]&&Requests.count==0&&! [message containsString:@"synthetic-private-key"],@"key is never HTTP or receipt data");
 [Private removeAllObjects];Licensed=NO;Check(![cloud _handleVaultRequest:Action(@"cloudVaultKey") context:context message:&message]&&!Private.count,@"locked license cannot obtain private key");Licensed=YES;Allowed=NO;Check(![cloud _handleVaultRequest:Action(@"cloudVaultList") context:context message:&message]&&!Requests.count,@"expired context starts no HTTP");Allowed=YES;
 Private[@"input-0"]=@{@"appType":@"facebook",@"passphrase":@"synthetic-private-key-replacement"};Check(![cloud _handleVaultRequest:Action(@"cloudVaultSetKey") context:context message:&message],@"foreign input cannot replace key");
 Private[@"input-0"]=@{@"appType":@"reddit",@"passphrase":@"synthetic-private-key-replacement"};Check([cloud _handleVaultRequest:Action(@"cloudVaultSetKey") context:context message:&message],@"valid private input replaces local key");Check(!Private[@"input-0"]&&[Settings[@"serverURL"] isEqual:@"unchanged"]&&Requests.count==0,@"only key changes and own input is consumed");
 Check([cloud _handleVaultRequest:Action(@"cloudVaultList") context:context message:&message],@"list succeeds");Check([Private[@"receipt-1"][@"backups"] count]==1,@"foreign and malformed list rows excluded");
 NSUInteger count=Requests.count;Check([cloud _handleVaultRequest:Action(@"cloudVaultDelete") context:context message:&message]&&Requests.count==count+2,@"deletion rechecks scoped inventory before request");
 NSMutableDictionary *bad=[Action(@"cloudVaultDelete") mutableCopy];bad[@"backupId"]=@"foreign";count=Requests.count;Check(![cloud _handleVaultRequest:bad context:context message:&message]&&Requests.count==count+1,@"cannot delete backup absent from selected app");
 Check([cloud _handleVaultRequest:Action(@"cloudVaultRestore") context:context message:&message]&&[RestoreApp isEqual:@"reddit"]&&[RestoreID isEqual:@"abc123"],@"restore passes explicit app and selected backup to validation");
 PrivateOK=NO;Check(![cloud _handleVaultRequest:Action(@"cloudVaultKey") context:context message:&message],@"private storage failure is not success");PrivateOK=YES;
 NSMutableData *sealed=[NSMutableData dataWithLength:3*1048576+71];memset(sealed.mutableBytes,17,sealed.length);
 NSDictionary *metadata=@{@"containerId":@"profile-a",@"checksum":RBXCloudSHA256Hex(sealed),@"salt":@"synthetic-salt",@"iv":@"synthetic-iv"};
 Check([cloud _uploadSealed:sealed metadata:metadata context:context error:&error],@"multi-part upload confirmed");Check(Parts.count==4&&[Upload[@"parts"] count]==4,@"upload carries expected hashes and bounded parts");
 NSMutableArray *manifestParts=[NSMutableArray array];for(NSUInteger i=0;i<Parts.count;i++){NSData *part=Parts[@(i).stringValue];[manifestParts addObject:@{@"size":@(part.length),@"checksum":RBXCloudSHA256Hex(part)}];}
 NSDictionary *manifest=@{@"size":@(sealed.length),@"parts":manifestParts,@"checksum":RBXCloudSHA256Hex(sealed)};
 Check([[cloud _downloadParts:manifest path:@"/api/backups/abc123?transfer=1" context:context error:&error] isEqual:sealed],@"download restores exact sealed bytes");
 for(NSString *fault in @[@"corrupt-part",@"transport"]){Fault=fault;error=nil;Check(![cloud _downloadParts:manifest path:@"/api/backups/abc123?transfer=1" context:context error:&error]&&error,@"corrupt/failed download returns no archive");}
 for(NSString *fault in @[@"part-receipt",@"complete-receipt"]){Fault=fault;error=nil;Check(![cloud _uploadSealed:sealed metadata:metadata context:context error:&error]&&error,@"missing acknowledgement never reports published backup");}
 Fault=nil;Allowed=NO;count=Requests.count;Check(![cloud _uploadSealed:sealed metadata:metadata context:context error:nil]&&Requests.count==count,@"cancelled upload never starts a part");
 printf("PASS: %lu actual private cloud/transport assertions\n",(unsigned long)Checks);return 0;
}}
'''.replace('__METHODS__',methods)
with tempfile.TemporaryDirectory(prefix='rbx-cloud-bridge-') as tmp:
 p=Path(tmp);(p/'test.m').write_text(fixture)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-incomplete-implementation','-Wno-deprecated-declarations','-Wno-nullability-completeness','-Wno-incompatible-pointer-types','-I'+str(ROOT/'daemon'),'-I'+str(ROOT/'shared'),'-framework','Foundation',str(p/'test.m'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
