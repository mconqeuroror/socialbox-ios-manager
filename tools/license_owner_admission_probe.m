// Unshipped root acceptance tool. The private build pins a separate vault
// beneath its own trusted test directory; this never changes the owner app.
#import "../lucid/Authorization/LBXLicenseOwner.h"
#import "../lucid/Authorization/LBXLicenseVault.h"
#import "../lucid/Authorization/LBXLicenseIPC.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#ifndef LBX_ADMISSION_PROBE_DIRECTORY
#error A private acceptance directory must be pinned at build time
#endif

static BOOL ProtectedWrite(LBXLicenseOwner *owner) {
    if(![owner sourceAuthorizationCurrent])return NO;
    int directory=open(LBX_ADMISSION_PROBE_DIRECTORY,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    struct stat node;
    if(directory<0||fstat(directory,&node)||!S_ISDIR(node.st_mode)||node.st_uid!=0||(node.st_mode&0077)) {
        if(directory>=0)close(directory);return NO;
    }
    NSString *name=[@"owned-canary-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int file=-1;BOOL ok=NO;
    if([owner sourceAuthorizationCurrent])file=openat(directory,name.UTF8String,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(file>=0) {
        const char marker[]="source-owned";char readback[sizeof(marker)]={0};
        ok=[owner sourceAuthorizationCurrent]&&!fstat(file,&node)&&S_ISREG(node.st_mode)&&node.st_uid==0&&
            node.st_nlink==1&&(node.st_mode&0777)==0600&&write(file,marker,sizeof(marker))==sizeof(marker)&&
            !fsync(file)&&lseek(file,0,SEEK_SET)==0&&read(file,readback,sizeof(readback))==sizeof(readback)&&
            !memcmp(marker,readback,sizeof(marker));
        if(close(file))ok=NO;
        if(unlinkat(directory,name.UTF8String,0))ok=NO;
    }
    close(directory);return ok;
}
int main(int argc,char **argv) {@autoreleasepool {
    if(getuid()!=0||geteuid()!=0)return 77;
    if(argc!=2||strcmp(argv[1],"--stdio"))return 64;
    NSString *vaultPath=[@LBX_ADMISSION_PROBE_DIRECTORY stringByAppendingPathComponent:@"pairing"];
    LBXLicenseVault *vault=[LBXLicenseVault openDirectory:vaultPath error:nil];
    LBXLicenseOwner *owner=vault?[[LBXLicenseOwner alloc] initWithVault:vault]:nil;
    if(!owner)return 74;
    for(;;) {@autoreleasepool {
        NSMutableData *data=[NSMutableData data];int byte;
        while((byte=fgetc(stdin))!=EOF&&byte!='\n') {
            if(data.length>=4096)return 65;
            unsigned char value=(unsigned char)byte;[data appendBytes:&value length:1];
        }
        if(byte==EOF&&!data.length)break;
        id input=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if(![input isKindOfClass:NSDictionary.class])return 65;
        NSString *operation=input[@"operation"];
        if([operation isEqual:@"quit"]&&[input count]==1)break;
        NSDictionary *reply;
        if([operation isEqual:@"query"]&&[input count]==1)reply=@{@"result":@"internal_check"};
        else {
            NSSet *expected=[NSSet setWithArray:[operation isEqual:@"activate"]?@[@"operation",@"key"]:@[@"operation"]];
            if(![[NSSet setWithArray:[input allKeys]] isEqual:expected])return 65;
            NSDictionary *request=LBXLicenseIPCRequest(operation,input[@"key"]);
            if(!request)return 65;
            dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *value;
            [owner handleRequest:request completion:^(NSDictionary *result){value=result;dispatch_semaphore_signal(done);}];
            if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC)))return 75;
            reply=value;
        }
        NSDictionary *projection=@{@"operation":operation,@"result":reply[@"result"],
            @"sourceAuthorized":@([owner sourceAuthorizationCurrent]),@"protectedWrite":@(ProtectedWrite(owner)),
            @"paired":@([vault.safeStatus[@"paired"] boolValue]),@"retainedEngineAuthorized":@NO};
        NSData *output=[NSJSONSerialization dataWithJSONObject:projection options:NSJSONWritingSortedKeys error:nil];
        if(!output.length||fwrite(output.bytes,1,output.length,stdout)!=output.length||fputc('\n',stdout)==EOF||fflush(stdout))return 74;
    }}
    return 0;
}}
