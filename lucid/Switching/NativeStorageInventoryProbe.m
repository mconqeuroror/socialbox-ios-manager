#import <Foundation/Foundation.h>
#import "LBXNativeStorageInventory.h"
#import "LBXNativeStorageLayout.h"
#import "LBXNativeFamilyStorageLayout.h"
#import "../../shared/RBXStorageGate.h"
#include <fcntl.h>
#include <string.h>

// The caller supplies a fresh, private root-owned directory on the physical
// filesystem. Only this output file is created; observed storage is read-only.
static int OutputDirectory(const char *argument) {
    NSString *path=argument?[[NSString alloc] initWithUTF8String:argument]:nil;
    if(!path.isAbsolutePath||path.length>=4096||[path containsString:@"\\"])return -1;
    NSArray *parts=[path componentsSeparatedByString:@"/"];int fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    for(NSUInteger i=1;i<parts.count;i++){
        NSString *part=parts[i];if(!part.length||[part isEqual:@"."]||[part isEqual:@".."]||[part rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){if(fd>=0)close(fd);return -1;}
        int child=fd>=0?openat(fd,part.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;if(fd>=0)close(fd);fd=child;struct stat s;
        if(fd<0||fstat(fd,&s)||s.st_uid!=0||(s.st_mode&0022)||!RBXStorageGateNoACL(fd)||(i==parts.count-1&&(s.st_mode&07777)!=0700)){if(fd>=0)close(fd);return -1;}
    }
    return fd;
}
static BOOL Save(int directory,NSDictionary *record) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];if(!data.length||data.length>8*1024*1024)return NO;
    int fd=openat(directory,"native-storage-inventory.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;
    BOOL good=fd>=0&&!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_uid==0&&s.st_nlink==1&&(s.st_mode&07777)==0600;
    NSUInteger offset=0;unsigned interruptions=0;while(good&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}
    if(good)good=!fsync(fd)&&!fsync(directory);if(fd>=0&&close(fd))good=NO;return good;
}
static BOOL Observed(LBXNativeStorageInventory *inventory){
    return inventory&&[@[@"OBSERVED",@"OBSERVED_WITH_UNAVAILABLE_COMPONENT"] containsObject:inventory.safeStatus[@"layoutStatus"]];
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=2||getuid()!=0||geteuid()!=0){puts("{\"status\":\"REFUSED\",\"rootRequired\":true,\"runtimeAccepted\":false,\"isolationVerified\":false}");return 77;}
    umask(077);int output=OutputDirectory(argv[1]);if(output<0){puts("{\"status\":\"REFUSED\",\"privateOutputRequired\":true,\"runtimeAccepted\":false,\"isolationVerified\":false}");return 2;}
    NSError *instagramError=nil,*facebookError=nil,*familyError=nil;
    LBXNativeStorageInventory *instagram=[LBXNativeStorageInventory observeOfficialInstagram:&instagramError];
    LBXNativeStorageInventory *facebook=[LBXNativeStorageInventory observeOfficialFacebook:&facebookError];
    LBXNativeStorageLayout *instagramLayout=instagram?[LBXNativeStorageLayout layoutForInventory:instagram error:nil]:nil;
    LBXNativeStorageLayout *facebookLayout=facebook?[LBXNativeStorageLayout layoutForInventory:facebook error:nil]:nil;
    LBXNativeFamilyStorageLayout *family=(instagramLayout&&facebookLayout)?[LBXNativeFamilyStorageLayout layoutWithInstagram:instagramLayout facebook:facebookLayout error:&familyError]:nil;
    NSDictionary *status=@{@"kind":@"native-family-storage-inventory",@"formatVersion":@1,
        @"instagramLayoutStatus":instagram.safeStatus[@"layoutStatus"]?:@"REFUSED",
        @"facebookLayoutStatus":facebook.safeStatus[@"layoutStatus"]?:@"REFUSED",
        @"familyLayoutAttached":@(family!=nil),
        @"familyAllowedContainerCount":family.safeStatus[@"allowedContainerCount"]?:@0,
        @"instagramErrorCode":@(instagram?0:instagramError.code),
        @"facebookErrorCode":@(facebook?0:facebookError.code),
        @"familyErrorCode":@(family?0:familyError.code),
        @"runtimeAccepted":@NO,@"isolationVerified":@NO,@"safeToGate":@NO,@"accountFileContentsRead":@NO,@"completeSharedWriters":@NO};
    NSDictionary *record=@{@"kind":@"native-family-storage-inventory",@"formatVersion":@1,
        @"instagram":instagram.privateDictionary?:@{@"layoutStatus":@"REFUSED"},
        @"facebook":facebook.privateDictionary?:@{@"layoutStatus":@"REFUSED"},
        @"family":family.safeStatus?:@{@"allowedContainerCount":@0,@"runtimeAccepted":@NO,@"isolationVerified":@NO},
        @"runtimeAccepted":@NO,@"isolationVerified":@NO,@"accountFileContentsRead":@NO};
    BOOL saved=Save(output,record);close(output);
    if(!saved){puts("{\"status\":\"REFUSED\",\"privateOutputSaved\":false,\"runtimeAccepted\":false,\"isolationVerified\":false}");return 2;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil];
    if(!data||fwrite(data.bytes,1,data.length,stdout)!=data.length||putchar('\n')==EOF)return 2;
    BOOL ok=Observed(instagram)&&Observed(facebook)&&family&&![family.safeStatus[@"isolationVerified"] boolValue]&&![family.safeStatus[@"runtimeAccepted"] boolValue];
    return ok?0:3;
}}
