#import <Foundation/Foundation.h>
#import "LBXNativeControlLayout.h"
#import "../../shared/RBXStorageGate.h"
#include <fcntl.h>
#include <string.h>

// Capture-only family control identities. The caller supplies a fresh 0700
// root-owned directory; observed SocialBox control files are never written.
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
    int fd=openat(directory,"native-family-control-layout.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);struct stat s;
    BOOL good=fd>=0&&!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_uid==0&&s.st_nlink==1&&(s.st_mode&07777)==0600;
    NSUInteger offset=0;unsigned interruptions=0;while(good&&offset<data.length){ssize_t n=write(fd,(const char *)data.bytes+offset,data.length-offset);if(n<0&&errno==EINTR&&++interruptions<=4)continue;if(n<=0){good=NO;break;}offset+=(NSUInteger)n;}
    if(good)good=!fsync(fd)&&!fsync(directory);if(fd>=0&&close(fd))good=NO;return good;
}
int main(int argc,const char **argv) {@autoreleasepool {
    if(argc!=2||getuid()!=0||geteuid()!=0){puts("{\"status\":\"REFUSED\",\"rootRequired\":true,\"runtimeAccepted\":false,\"isolationVerified\":false,\"accountFileContentsRead\":false}");return 77;}
    umask(077);int output=OutputDirectory(argv[1]);if(output<0){puts("{\"status\":\"REFUSED\",\"privateOutputRequired\":true,\"runtimeAccepted\":false,\"isolationVerified\":false,\"accountFileContentsRead\":false}");return 2;}
    NSError *error=nil;LBXNativeControlLayout *layout=[LBXNativeControlLayout observeOfficialFamily:&error];
    NSDictionary *observed=layout.safeStatus;
    NSDictionary *status=@{@"kind":@"native-family-control-layout",@"formatVersion":@1,@"status":layout?@"OBSERVED":@"REFUSED",
        @"layoutStatus":observed[@"layoutStatus"]?:@"REFUSED",
        @"instagramObserved":@(observed[@"instagram"]!=nil),@"facebookObserved":@(observed[@"facebook"]!=nil),
        @"errorCode":@(layout?0:error.code),@"accountFileContentsRead":@NO,@"selectionChanged":@NO,@"hookInstalled":@NO,
        @"installedSwitchConnected":@NO,@"runtimeAccepted":@NO,@"isolationVerified":@NO,@"safeToGate":@NO};
    NSDictionary *record=@{@"kind":@"native-family-control-layout",@"formatVersion":@1,
        @"control":observed?:@{@"layoutStatus":@"REFUSED",@"accountFileContentsRead":@NO},
        @"accountFileContentsRead":@NO,@"selectionChanged":@NO,@"runtimeAccepted":@NO,@"isolationVerified":@NO};
    BOOL saved=Save(output,record);close(output);
    if(!saved){puts("{\"status\":\"REFUSED\",\"privateOutputSaved\":false,\"runtimeAccepted\":false,\"isolationVerified\":false,\"accountFileContentsRead\":false}");return 2;}
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:NSJSONWritingSortedKeys error:nil];
    if(!data||fwrite(data.bytes,1,data.length,stdout)!=data.length||putchar('\n')==EOF)return 2;
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if([text containsString:@"/var/"]||[text containsString:@"/private/"]||[text containsString:@"/tmp/"])return 3;
    BOOL ok=layout&&[observed[@"layoutStatus"] isEqual:@"OBSERVED"]&&observed[@"instagram"]&&observed[@"facebook"]&&
        ![observed[@"accountFileContentsRead"] boolValue]&&![observed[@"isolationVerified"] boolValue]&&![observed[@"runtimeAccepted"] boolValue];
    return ok?0:3;
}}
