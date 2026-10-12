#import "LBXLicenseVault.h"
#import "LBXLicenseTransport.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// Root-only acceptance caller for the future license owner. No engine/UI calls.
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=5||strcmp(argv[1],"--vault")||strcmp(argv[3],"--private-result")||geteuid()!=0){
        fputs("Usage (root): socialbox-license-vault-probe --vault PRIVATE_DIRECTORY --private-result NEW_PRIVATE_FILE < private-input.json\n",stderr);return 2;
    }
    int fd=open(argv[4],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);struct stat node;
    if(fd<0||fstat(fd,&node)||!S_ISREG(node.st_mode)||node.st_uid!=0||node.st_nlink!=1||(node.st_mode&0077)){
        if(fd>=0)close(fd);fputs("Private result unavailable; no request sent\n",stderr);return 2;
    }
    NSData *input=[NSFileHandle.fileHandleWithStandardInput readDataOfLength:1025];
    id request=input.length<=1024?[NSJSONSerialization JSONObjectWithData:input options:0 error:nil]:nil;
    if(![request isKindOfClass:NSDictionary.class]||[request count]>1||(request[@"key"]&&![request[@"key"] isKindOfClass:NSString.class])||
       ([request count]==1&&!request[@"key"])){close(fd);fputs("Invalid private input; no request sent\n",stderr);return 2;}
    NSError *failure=nil;LBXLicenseVault *vault=[LBXLicenseVault openDirectory:[NSString stringWithUTF8String:argv[2]] error:&failure];
    NSDictionary *configuration=[vault beginWithKey:request[@"key"] error:&failure];
    if(!configuration){close(fd);fputs("Private pairing unavailable; no identity recovery or request attempted\n",stderr);return 2;}
    BOOL claim=request[@"key"]!=nil||![configuration[@"deviceId"] length];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *result;
    LBXLicenseTransport *transport=[LBXLicenseTransport startWithConfiguration:configuration claim:claim
        currentConfiguration:^NSDictionary *{return [vault configuration:nil];}
        completion:^(NSDictionary *receipt,NSError *error){
            NSError *saveError=nil;
            BOOL saved=receipt&&[vault commitReceipt:receipt expectedConfiguration:configuration error:&saveError];
            result=@{@"exchangeStatus":receipt[@"status"]?:@"rejected",@"pairingCommitted":@(saved),
                @"httpOrVerificationError":@(error.code),@"storageError":@(saveError.code),@"state":vault.safeStatus,
                @"claim":@(claim),@"engineAuthorized":@NO};
            dispatch_semaphore_signal(done);
        } error:&failure];
    if(!transport){close(fd);fputs("License exchange did not start\n",stderr);return 2;}
    if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,25*NSEC_PER_SEC))){
        [transport cancel];close(fd);fputs("Request timed out; preserve the existing identity for recovery\n",stderr);return 2;
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];NSUInteger offset=0;
    while(offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR)continue;if(n<=0)break;offset+=(NSUInteger)n;}
    BOOL saved=data.length&&offset==data.length&&fsync(fd)==0;int closed=close(fd);
    if(!saved||closed){fputs("Private result write failed; inspect the existing vault without resetting it\n",stderr);return 2;}
    fputs("Private lifecycle result saved; engine admission unchanged\n",stdout);return 0;
}}
