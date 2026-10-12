#import "../Authorization/LBXLicenseVault.h"
#import "../../tests/RBXLicenseTestSupport.h"
#include <sys/stat.h>
#include <unistd.h>
static NSUInteger checks,failures;
static void Check(BOOL value,NSString *why){checks++;if(!value){failures++;fprintf(stderr,"FAIL: %s\n",why.UTF8String);}}
static NSString *const Key=@"AAAA-BBBB-CCCC-DDDD";
static NSString *Bearer(void){return [@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0];}
static NSMutableDictionary *Receipt(NSDictionary *config,NSString *status) {
    NSString *nonce=NSUUID.UUID.UUIDString.lowercaseString;
    NSMutableDictionary *claims=TestLicenseClaims(Key,nonce,NSDate.date.timeIntervalSince1970);
    claims[@"iss"]=config[@"server"];claims[@"deviceBinding"]=[RBXLicenseToken fingerprint:config[@"deviceIdentity"]];
    claims[@"status"]=status;
    return [@{@"deviceId":@"fixture-device",@"deviceToken":Bearer(),@"requestNonce":nonce,
        @"licenseToken":TestLicenseJWT(claims,nil),@"activeAtReceipt":@YES} mutableCopy];
}
static LBXLicenseVault *Open(NSString *path){LBXLicenseVault *v=[LBXLicenseVault openDirectory:path error:nil];[v testUsePublicKey:TestLicensePublicDER() keyID:TestLicenseKeyID()];return v;}
int main(int argc,char **argv){@autoreleasepool{
    if(argc==3&&!strcmp(argv[1],"--reserve")) {
        LBXLicenseVault *child=[LBXLicenseVault openDirectory:[NSString stringWithUTF8String:argv[2]] error:nil];
        if(!child)return 2;
        for(unsigned i=0;i<10;i++) {
            NSDictionary *c=[child beginWithKey:nil error:nil];if(!c)return 3;
            printf("%llu\n",[c[@"revision"] unsignedLongLongValue]);
        }
        return 0;
    }
    char parent[]="/tmp/socialbox-vault.XXXXXX";Check(mkdtemp(parent)!=NULL,@"private test parent");
    NSString *base=[NSString stringWithUTF8String:parent],*path=[base stringByAppendingPathComponent:@"installation"];
    LBXLicenseVault *vault=Open(path);Check(vault!=nil,@"create vault");
    NSDictionary *initial=[vault configuration:nil];Check([initial[@"deviceIdentity"] length]==36,@"installation UUID created");
    Check(![vault.safeStatus[@"paired"] boolValue]&&![vault.safeStatus[@"engineAuthorized"] boolValue],@"vault is not an admission grant");
    Check([[Open(path) configuration:nil] isEqual:initial],@"reopen preserves identity and generation");
    Check([vault beginWithKey:@"invalid" error:nil]==nil,@"invalid key rejected before mutation");
    Check([[vault configuration:nil] isEqual:initial],@"invalid key did not mutate record");
    NSDictionary *first=[vault beginWithKey:@" aaaa-bbbb-cccc-dddd\n" error:nil];
    Check([first[@"key"] isEqual:Key]&&[first[@"revision"] isEqual:@2],@"normalized key and durable generation");
    Check([first[@"deviceIdentity"] isEqual:initial[@"deviceIdentity"]],@"key entry preserves installation");
    Check(![vault.description containsString:Key]&&![vault.safeStatus.description containsString:first[@"deviceIdentity"]],@"public status redacts private identity/key");
    NSMutableDictionary *receipt=Receipt(first,@"active"),*bad=[receipt mutableCopy];
    bad[@"licenseToken"]=@"unsigned";
    Check(![vault commitReceipt:bad expectedConfiguration:first error:nil],@"unsigned active flag rejected");
    bad=[receipt mutableCopy];bad[@"requestNonce"]=NSUUID.UUID.UUIDString.lowercaseString;
    Check(![vault commitReceipt:bad expectedConfiguration:first error:nil],@"wrong nonce rejected");
    bad=[receipt mutableCopy];bad[@"deviceId"]=@"foreign-device";
    Check(![vault commitReceipt:bad expectedConfiguration:first error:nil],@"wrong device rejected");
    bad=[receipt mutableCopy];bad[@"deviceToken"]=[Bearer() stringByAppendingString:@"\n"];
    Check(![vault commitReceipt:bad expectedConfiguration:first error:nil],@"credential trailing newline rejected");
    NSDictionary *second=[Open(path) beginWithKey:nil error:nil];
    NSError *stale=nil;
    Check(![vault commitReceipt:receipt expectedConfiguration:first error:&stale]&&stale.code==2,@"other owner invalidates old reply");
    Check([[vault configuration:nil] isEqual:second],@"stale reply does not overwrite newer state");
    receipt=Receipt(second,@"active");
    // Unsigned projections cannot override verified claims in a minted commit.
    receipt[@"status"]=@"revoked";receipt[@"expiresAt"]=@1;
    LBXLicenseVerifiedCommit *activeCommit=[vault commitVerifiedReceipt:receipt expectedConfiguration:second error:nil];
    Check(activeCommit!=nil,@"authentic pairing durable commit");
    Check([activeCommit.status isEqual:@"active"]&&activeCommit.expiresAt>NSDate.date.timeIntervalSince1970,@"commit uses signed status and expiry instead of receipt hints");
    NSDictionary *paired=[Open(path) configuration:nil];
    Check([paired[@"deviceToken"] isEqual:Bearer()]&&[paired[@"deviceId"] isEqual:@"fixture-device"],@"restart recovers same paired credential");
    Check([paired[@"deviceIdentity"] isEqual:initial[@"deviceIdentity"]],@"pairing preserves UUID");
    Check([activeCommit matchesConfiguration:paired]&&![activeCommit matchesConfiguration:second],@"verified commit pins the post-commit generation only");
    Check(![activeCommit.description containsString:Key]&&![activeCommit.description containsString:Bearer()]&&![activeCommit.description containsString:paired[@"deviceIdentity"]],@"verified commit description redacts binding credentials");
    Check(![vault commitReceipt:receipt expectedConfiguration:second error:nil],@"receipt cannot commit twice");
    NSDictionary *validating=[vault beginWithKey:nil error:nil];
    bad=Receipt(validating,@"active");bad[@"deviceToken"]=[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];
    Check(![vault commitReceipt:bad expectedConfiguration:validating error:nil],@"paired credential cannot be silently replaced");
    receipt=Receipt(validating,@"revoked");[receipt removeObjectForKey:@"deviceToken"];
    receipt[@"status"]=@"active";receipt[@"expiresAt"]=@(NSDate.date.timeIntervalSince1970+999999);
    LBXLicenseVerifiedCommit *denialCommit=[vault commitVerifiedReceipt:receipt expectedConfiguration:validating error:nil];
    Check(denialCommit!=nil,@"authentic denial recorded despite forged active hint");
    Check([denialCommit.status isEqual:@"revoked"],@"signed denial cannot mint an active commit from a forged projection");
    NSDictionary *denied=[Open(path) configuration:nil];
    Check([denied[@"deviceToken"] isEqual:Bearer()],@"denial keeps credential for later authorized validation");
    Check([denialCommit matchesConfiguration:denied]&&![activeCommit matchesConfiguration:denied],@"denial supersedes the earlier active generation");
    Check(![vault commitReceipt:Receipt(validating,@"active") expectedConfiguration:validating error:nil],@"pre-denial generation cannot replay active receipt");
    NSData *bytes=[NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:@"pairing.json"]];
    NSDictionary *stored=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    Check([stored[@"lastStatus"] isEqual:@"revoked"]&&!stored[@"licenseToken"],@"descriptive denial; no reusable offline grant");
    Check(![vault.safeStatus[@"engineAuthorized"] boolValue],@"paired vault never grants engine admission");
    NSString *recordPath=[path stringByAppendingPathComponent:@"pairing.json"];
    NSMutableDictionary *malformed=[stored mutableCopy];malformed[@"formatVersion"]=@YES;
    NSData *malformedData=[NSJSONSerialization dataWithJSONObject:malformed options:0 error:nil];
    [malformedData writeToFile:recordPath atomically:NO];
    Check(Open(path)==nil,@"Boolean schema version is not numeric version one");
    [bytes writeToFile:recordPath atomically:NO];
    Check(chmod(recordPath.fileSystemRepresentation,0644)==0,@"fixture insecure file");
    Check([vault configuration:nil]==nil && Open(path)==nil,@"insecure record rejected");
    chmod(recordPath.fileSystemRepresentation,0600);
    NSString *alias=[base stringByAppendingPathComponent:@"alias.json"];
    Check(link(recordPath.fileSystemRepresentation,alias.fileSystemRepresentation)==0,@"fixture hardlink");
    Check([vault configuration:nil]==nil,@"hardlinked record rejected");unlink(alias.fileSystemRepresentation);
    Check([[vault configuration:nil] isEqual:denied],@"original state still intact after read denials");
    NSString *lockPath=[path stringByAppendingPathComponent:@"owner.lock"];
    unlink(lockPath.fileSystemRepresentation);
    Check([vault configuration:nil]==nil&&Open(path)==nil,@"missing established lock is not recreated");
    Check(![NSFileManager.defaultManager fileExistsAtPath:lockPath],@"missing lock stays missing for explicit recovery");
    [NSData.data writeToFile:lockPath atomically:NO];chmod(lockPath.fileSystemRepresentation,0600);
    Check(unlink(recordPath.fileSystemRepresentation)==0,@"fixture missing established record");
    Check(Open(path)==nil && [vault configuration:nil]==nil,@"missing established identity is not regenerated");
    Check(![NSFileManager.defaultManager fileExistsAtPath:recordPath],@"missing record stays missing for explicit recovery");
    Check(symlink("owner.lock",recordPath.fileSystemRepresentation)==0,@"fixture symlink");
    Check(Open(path)==nil,@"record symlink refused");unlink(recordPath.fileSystemRepresentation);
    Check(mkfifo(recordPath.fileSystemRepresentation,0600)==0,@"fixture FIFO");
    Check(Open(path)==nil,@"FIFO refused without waiting for a writer");unlink(recordPath.fileSystemRepresentation);
    Check([@"{\"broken\":" writeToFile:recordPath atomically:NO encoding:NSUTF8StringEncoding error:nil],@"fixture corrupt record");chmod(recordPath.fileSystemRepresentation,0600);
    Check(Open(path)==nil,@"corruption does not replace installation");
    NSString *publicParent=[base stringByAppendingPathComponent:@"public"];
    mkdir(publicParent.fileSystemRepresentation,0777);chmod(publicParent.fileSystemRepresentation,0777);
    Check(Open([publicParent stringByAppendingPathComponent:@"vault"])==nil,@"writable parent refused");
    NSString *linkDir=[base stringByAppendingPathComponent:@"link"];
    symlink(path.fileSystemRepresentation,linkDir.fileSystemRepresentation);
    Check(Open(linkDir)==nil,@"directory symlink refused");
    NSString *parallelPath=[base stringByAppendingPathComponent:@"parallel"];
    LBXLicenseVault *a=Open(parallelPath),*b=Open(parallelPath);[a beginWithKey:Key error:nil];
    NSMutableSet *revisions=[NSMutableSet set];NSObject *resultLock=[NSObject new];
    dispatch_apply(20,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){@autoreleasepool{
        NSDictionary *c=[(i%2?a:b) beginWithKey:nil error:nil];
        @synchronized(resultLock){if(c)[revisions addObject:c[@"revision"]];}
    }});
    Check(revisions.count==20,@"concurrent owners reserve twenty distinct durable generations");
    Check([[[Open(parallelPath) configuration:nil] objectForKey:@"revision"] isEqual:@22],@"no update lost across separate vault objects");
    NSMutableArray<NSTask *> *children=[NSMutableArray array];NSMutableArray<NSPipe *> *pipes=[NSMutableArray array];
    for(unsigned i=0;i<2;i++) {
        NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[0]]];
        task.arguments=@[@"--reserve",parallelPath];NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;
        [children addObject:task];[pipes addObject:pipe];Check([task launchAndReturnError:nil],@"independent owner process launched");
    }
    NSMutableSet *processRevisions=[NSMutableSet set];
    for(unsigned i=0;i<children.count;i++) {
        NSString *output=[[NSString alloc] initWithData:[pipes[i].fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding];
        [children[i] waitUntilExit];Check(children[i].terminationStatus==0,@"independent owner completed");
        for(NSString *line in [output componentsSeparatedByString:@"\n"])if(line.length)[processRevisions addObject:line];
    }
    Check(processRevisions.count==20,@"independent processes reserve distinct generations");
    Check([[[Open(parallelPath) configuration:nil] objectForKey:@"revision"] isEqual:@42],@"no update lost across process boundaries");
    [NSFileManager.defaultManager removeItemAtPath:base error:nil];
    NSLog(@"%@: %lu license vault assertions, %lu failures (actual filesystem and RSA)",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures);
    return failures?1:0;
}}
