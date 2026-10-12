#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
static unsigned Checks,Failures,Reads,Closed,Interrupts;
static BOOL WrongOwner,TruncateDuringRead,ReplaceDuringRead,ChmodDuringRead,AlwaysInterrupt,ShortRead;
static NSString *FixturePath;
static void Check(BOOL value,const char *why){Checks++;if(!value){Failures++;fprintf(stderr,"FAIL %s\n",why);}}
static NSString *Digest(NSData *bytes){unsigned char d[32];char s[65];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,d);for(unsigned i=0;i<32;i++)snprintf(s+i*2,3,"%02x",d[i]);return @(s);}
static int FixtureStat(int fd,struct stat *node){int rc=fstat(fd,node);if(!rc)node->st_uid=WrongOwner?501:0;return rc;}
static int FixtureLstat(const char *path,struct stat *node){int rc=lstat(path,node);if(!rc)node->st_uid=WrongOwner?501:0;return rc;}
static int FixtureOpen(const char *path,int flags,...){
    Check((flags&O_NOFOLLOW)&&(flags&O_NONBLOCK)&&(flags&O_CLOEXEC)&&!(flags&(O_CREAT|O_TRUNC|O_RDWR|O_WRONLY)),"read-only nonblocking descriptor, no following links");
    return open(path,flags);
}
static ssize_t FixtureRead(int fd,void *out,size_t count){
    Reads++;
    if(AlwaysInterrupt || Interrupts){if(Interrupts)Interrupts--;errno=EINTR;return -1;}
    ssize_t rc=read(fd,out,ShortRead?MIN(count,7):count);
    if(TruncateDuringRead){TruncateDuringRead=NO;truncate(FixturePath.fileSystemRepresentation,1);}
    if(ReplaceDuringRead){ReplaceDuringRead=NO;[[NSData dataWithBytes:"new" length:3] writeToFile:FixturePath atomically:YES];chmod(FixturePath.fileSystemRepresentation,0755);}
    if(ChmodDuringRead){ChmodDuringRead=NO;chmod(FixturePath.fileSystemRepresentation,0775);}
    return rc;
}
static int FixtureClose(int fd){Closed++;return close(fd);}
#define open FixtureOpen
#define fstat FixtureStat
#define lstat FixtureLstat
#define read FixtureRead
#define close FixtureClose
#import "../lucid/HelperSafety/LBXCallerFile.m"
#undef open
#undef fstat
#undef lstat
#undef read
#undef close
static void Restore(NSData *bytes){Check([bytes writeToFile:FixturePath atomically:YES],"restore only owned fixture");chmod(FixturePath.fileSystemRepresentation,0755);}
int main(void){@autoreleasepool{
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    Check([NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:nil],"create private test directory");
    FixturePath=[root stringByAppendingPathComponent:@"program"];
    NSMutableData *original=[NSMutableData dataWithLength:40001];memset(original.mutableBytes,'A',original.length);
    NSString *digest=Digest(original);Restore(original);
    Check(LBXVerifyCallerFile(FixturePath,original.length,digest)&&Closed==1,"exact pinned bytes accepted, descriptor closed");
    Check(!LBXVerifyCallerFile(FixturePath,original.length+1,digest),"different byte count rejected");
    NSMutableData *changed=[original mutableCopy];((char *)changed.mutableBytes)[20000]='B';Restore(changed);
    Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"same-size different program rejected");Restore(original);
    WrongOwner=YES;Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"non-root owner rejected");WrongOwner=NO;
    for(NSNumber *mode in @[@0775,@0757]){chmod(FixturePath.fileSystemRepresentation,mode.intValue);Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"group/world writable program rejected");}chmod(FixturePath.fileSystemRepresentation,0755);
    NSString *link=[root stringByAppendingPathComponent:@"link"];
    symlink(FixturePath.fileSystemRepresentation,link.fileSystemRepresentation);
    Check(!LBXVerifyCallerFile(link,original.length,digest),"symlink cannot acquire executable authority");unlink(link.fileSystemRepresentation);
    linkat(AT_FDCWD,FixturePath.fileSystemRepresentation,AT_FDCWD,link.fileSystemRepresentation,0);
    Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"hardlinked program rejected");unlink(link.fileSystemRepresentation);
    mkfifo(link.fileSystemRepresentation,0600);
    Check(!LBXVerifyCallerFile(link,original.length,digest),"FIFO rejected without waiting for writer");unlink(link.fileSystemRepresentation);
    Check(!LBXVerifyCallerFile(root,original.length,digest),"directory rejected");
    ShortRead=YES;Interrupts=2;Check(LBXVerifyCallerFile(FixturePath,original.length,digest),"short reads and bounded EINTR are handled");ShortRead=NO;
    unsigned reads=Reads;AlwaysInterrupt=YES;Check(!LBXVerifyCallerFile(FixturePath,original.length,digest)&&Reads-reads==5,"persistent EINTR bounded without authorization");AlwaysInterrupt=NO;
    TruncateDuringRead=YES;Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"truncation during read revokes authority");Restore(original);
    ReplaceDuringRead=YES;Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"atomic name replacement during read rejected despite old descriptor");Restore(original);
    ChmodDuringRead=YES;Check(!LBXVerifyCallerFile(FixturePath,original.length,digest),"permission change during hash rejected");Restore(original);
    for(id path in @[@42,@"relative",@"/path\0tail"]){Check(!LBXVerifyCallerFile(path,original.length,digest),"invalid path rejected");}
    for(NSNumber *size in @[@0,@(-1),@(33*1024*1024)])Check(!LBXVerifyCallerFile(FixturePath,size.longLongValue,digest),"invalid size rejected before open");
    Check(!LBXVerifyCallerFile(FixturePath,original.length,@"bad"),"invalid digest rejected");
    Check([NSFileManager.defaultManager removeItemAtPath:root error:nil],"remove only private fixtures");
    printf("%s caller executable: %u checks, %u failures; real filesystem, fixture uid mapped to root\n",Failures?"FAIL":"PASS",Checks,Failures);return Failures?1:0;
}}
