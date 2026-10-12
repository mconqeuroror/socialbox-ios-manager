#import "LBXNativeInstalledManagerPin.h"
#import "LBXSocialBoxProduct.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifndef LBX_NATIVE_INSTALLED_MANAGER_PIN_TESTING
#define LBX_NATIVE_INSTALLED_MANAGER_PIN_TESTING 0
#endif

static NSString *const Path=@LBX_SOCIALBOX_MANAGER_PATH;
static NSString *const Digest=@LBX_SOCIALBOX_MANAGER_SHA256;
static const unsigned long long ExpectedSize=LBX_SOCIALBOX_MANAGER_SIZE;

static BOOL Fail(NSError **error,NSInteger code){
    if(error)*error=[NSError errorWithDomain:@"com.socialbox.native-installed-manager-pin" code:code userInfo:@{NSLocalizedDescriptionKey:
        code==2?@"Root context is required to pin the SocialBox manager":
        code==3?@"SocialBox manager is not packaged":@"SocialBox manager pin refused"}];
    return NO;
}
static NSDictionary *Immutable(id value){
    if(![NSJSONSerialization isValidJSONObject:value])return nil;
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    return bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;
}
static NSArray *RequiredOperations(void){
    return @[
        @{@"class":@"_Xc9m",@"selector":@"performSwitchToContainer:",@"encoding":@"v24@0:8@16"},
        @{@"class":@"_Xc9m",@"selector":@"performDeactivate",@"encoding":@"v16@0:8"},
        @{@"class":@"_Xc9m",@"selector":@"doDeleteContainer:",@"encoding":@"v24@0:8@16"},
        @{@"class":@"_Xc9m",@"selector":@"saveApps:forContainer:",@"encoding":@"v32@0:8@16@24"},
        @{@"class":@"HomeViewController",@"selector":@"performCreateContainerWithApps:",@"encoding":@"v24@0:8@16"},
        @{@"class":@"HomeViewController",@"selector":@"performBatchCreateContainers:withApps:",@"encoding":@"v32@0:8Q16@24"}
    ];
}
static NSDictionary *Status(BOOL matched){
    return Immutable(@{@"kind":@"native-installed-manager-pin",@"formatVersion":@1,
        @"expectedPath":Path,@"expectedSHA256":Digest,@"expectedSize":@(ExpectedSize),
        @"packaged":@(ExpectedSize>0),@"digestMatched":@(matched),@"identityMatched":@(matched),
        @"requiredOperations":RequiredOperations(),
        @"hookInstalled":@NO,@"invokedOriginalSwitchWorker":@NO,@"installedSwitchConnected":@NO,
        @"runtimeAccepted":@NO,@"isolationVerified":@NO});
}
static NSString *HexSHA256(const void *bytes,size_t length){
    if(!bytes||length>UINT32_MAX)return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,(CC_LONG)length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:64];
    for(unsigned i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
static BOOL StableRegular(int fd,unsigned long long expectedSize,uid_t owner){
    struct stat before,after;
    return expectedSize>0&&!fstat(fd,&before)&&S_ISREG(before.st_mode)&&before.st_uid==owner&&!(before.st_mode&0022)&&
        (unsigned long long)before.st_size==expectedSize&&before.st_nlink==1&&
        !fstat(fd,&after)&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&
        before.st_size==after.st_size&&before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&
        before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&
        before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
}
@interface LBXNativeInstalledManagerPin ()
@property(nonatomic,copy)NSDictionary *status;
- (instancetype)initPrivate;
@end
static LBXNativeInstalledManagerPin *Make(NSDictionary *status){
    LBXNativeInstalledManagerPin *pin=[[LBXNativeInstalledManagerPin alloc] initPrivate];
    pin.status=status;return pin;
}
static LBXNativeInstalledManagerPin *Read(NSString *path,NSString *expectedHex,unsigned long long expectedSize,uid_t owner,NSError **error){
    if(error)*error=nil;
    if(!expectedSize){Fail(error,3);return nil;}
    if(![path isKindOfClass:NSString.class]||!path.isAbsolutePath||path.length>=4096||[path containsString:@"\\"]){Fail(error,1);return nil;}
    if(![expectedHex isKindOfClass:NSString.class]||expectedHex.length!=64){Fail(error,1);return nil;}
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);if(fd<0){Fail(error,1);return nil;}
    BOOL identity=StableRegular(fd,expectedSize,owner);
    NSMutableData *data=identity?[NSMutableData dataWithLength:(NSUInteger)expectedSize]:nil;
    size_t readBytes=0;ssize_t count=0;
    while(identity&&data&&readBytes<data.length&&(count=read(fd,(char *)data.mutableBytes+readBytes,data.length-readBytes))>0)readBytes+=(size_t)count;
    identity=identity&&count>=0&&readBytes==(size_t)expectedSize&&StableRegular(fd,expectedSize,owner);
    close(fd);
    NSString *hex=identity?HexSHA256(data.bytes,data.length):nil;
    if(!identity||![hex isEqual:expectedHex]){Fail(error,1);return nil;}
    return Make(Status(YES));
}
@implementation LBXNativeInstalledManagerPin
- (instancetype)initPrivate{return [super init];}
- (NSDictionary *)safeStatus{return _status?:Status(NO);}
- (NSString *)description{return @"<LBXNativeInstalledManagerPin>";}
+ (instancetype)observeOriginalManager:(NSError **)error {
    if(getuid()!=0||geteuid()!=0){Fail(error,2);return nil;}
    return Read(Path,Digest,ExpectedSize,0,error);
}
#if LBX_NATIVE_INSTALLED_MANAGER_PIN_TESTING
+ (instancetype)testObservePath:(NSString *)path expectedSHA256:(NSString *)hex expectedSize:(unsigned long long)size error:(NSError **)error {
    LBXNativeInstalledManagerPin *pin=Read(path,hex,size,getuid(),error);
    if(!pin)return nil;
    pin.status=Immutable(@{@"kind":@"native-installed-manager-pin",@"formatVersion":@1,@"expectedPath":Path,@"fixturePathPresent":@YES,
        @"packaged":@YES,@"digestMatched":@YES,@"identityMatched":@YES,@"requiredOperations":RequiredOperations(),
        @"hookInstalled":@NO,@"invokedOriginalSwitchWorker":@NO,@"installedSwitchConnected":@NO,@"runtimeAccepted":@NO,@"isolationVerified":@NO});
    return pin;
}
#endif
@end
