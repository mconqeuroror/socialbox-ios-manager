#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#define LBX_NATIVE_INSTALLED_MANAGER_PIN_TESTING 1
#import "../lucid/Switching/LBXNativeInstalledManagerPin.h"
#import "../lucid/Switching/LBXNativeInstalledManagerPin.m"
static NSUInteger Checks;
static void Check(BOOL ok,NSString *label){Checks++;if(!ok){fprintf(stderr,"FAIL: %s\n",label.UTF8String);exit(1);}}
static NSString *Hex(NSData *data){
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString string];for(unsigned i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];return hex;
}
int main(void){@autoreleasepool{
    NSError *error=nil;
    if(getuid()!=0||geteuid()!=0){
        Check([LBXNativeInstalledManagerPin observeOriginalManager:&error]==nil&&error.code==2,@"production pin requires real and effective root");
    }
    NSString *raw=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"socialbox-manager-pin-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    Check([[NSFileManager defaultManager] createDirectoryAtPath:raw withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil],@"fixture directory");
    NSString *file=[raw stringByAppendingPathComponent:@"SocialBox"];
    NSData *payload=[@"socialbox-inert-manager-pin-fixture\n" dataUsingEncoding:NSUTF8StringEncoding];
    Check([payload writeToFile:file atomically:YES],@"fixture bytes");
    Check([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0644} ofItemAtPath:file error:nil],@"fixture mode");
    NSString *hex=Hex(payload);
    LBXNativeInstalledManagerPin *pin=[LBXNativeInstalledManagerPin testObservePath:file expectedSHA256:hex expectedSize:payload.length error:&error];
    Check(pin&&!error,@"matching fixture pin admitted");
    Check([pin.safeStatus[@"hookInstalled"] isEqual:@NO],@"pin never installs a method hook");
    Check([pin.safeStatus[@"installedSwitchConnected"] isEqual:@NO],@"digest match is not an installed switch");
    Check([pin.safeStatus[@"invokedOriginalSwitchWorker"] isEqual:@NO],@"pin never invokes the original worker");
    Check([pin.safeStatus[@"isolationVerified"] isEqual:@NO]&&[pin.safeStatus[@"runtimeAccepted"] isEqual:@NO],@"pin never claims isolation");
    NSArray *operations=pin.safeStatus[@"requiredOperations"];
    Check(operations.count==6,@"family switch ABI table is complete");
    Check([operations[0][@"selector"] isEqual:@"performSwitchToContainer:"]&&[operations[0][@"encoding"] isEqual:@"v24@0:8@16"],@"switch selector encoding pinned");
    Check([operations[1][@"selector"] isEqual:@"performDeactivate"],@"deactivate stays on the refuse list");
    Check([operations[2][@"selector"] isEqual:@"doDeleteContainer:"],@"delete stays on the refuse list");
    error=nil;Check([LBXNativeInstalledManagerPin testObservePath:file expectedSHA256:@"0000000000000000000000000000000000000000000000000000000000000000" expectedSize:payload.length error:&error]==nil&&error.code==1,@"wrong digest refused");
    error=nil;Check([LBXNativeInstalledManagerPin testObservePath:file expectedSHA256:hex expectedSize:payload.length+1 error:&error]==nil,@"wrong size refused");
    error=nil;Check([LBXNativeInstalledManagerPin testObservePath:@"/tmp/missing-socialbox-manager" expectedSHA256:hex expectedSize:payload.length error:&error]==nil,@"missing manager refused");
    Check([[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0666} ofItemAtPath:file error:nil],@"world-writable fixture");
    error=nil;Check([LBXNativeInstalledManagerPin testObservePath:file expectedSHA256:hex expectedSize:payload.length error:&error]==nil,@"world-writable manager refused");
    [[NSFileManager defaultManager] removeItemAtPath:raw error:nil];
    printf("PASS: %lu native installed-manager pin assertions\n",(unsigned long)Checks);return 0;
}}
