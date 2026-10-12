#import <Foundation/Foundation.h>
#import "RBXStagedExecutable.h"
#include <sys/stat.h>
static unsigned Checks;
static void Check(BOOL b){Checks++;if(!b){fprintf(stderr,"FAIL staged executable check %u\n",Checks);exit(1);}}
static mode_t Mode(NSString *path){struct stat s;Check(lstat(path.fileSystemRepresentation,&s)==0);return s.st_mode&07777;}
int main(int argc,char **argv){@autoreleasepool{
 Check(argc==2);NSString *root=@(argv[1]);NSFileManager *fm=NSFileManager.defaultManager;
 NSString *transactions=[root stringByAppendingPathComponent:@"transactions"],*bundle=[transactions stringByAppendingPathComponent:@"owned/Payload/App.app"];
 Check([fm createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
 NSString *main=[bundle stringByAppendingPathComponent:@"Main"];
 Check([@{@"CFBundleExecutable":@"Main"} writeToFile:[bundle stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
 Check([@"code bytes" writeToFile:main atomically:YES encoding:NSUTF8StringEncoding error:nil]);chmod(main.fileSystemRepresentation,0600);
 Check(RBXPrepareStagedExecutable(bundle,transactions,getuid(),getgid(),nil));Check(Mode(main)==0755&&Mode(bundle)==0755);
 Check([[NSString stringWithContentsOfFile:main encoding:NSUTF8StringEncoding error:nil] isEqual:@"code bytes"]);
 chmod(main.fileSystemRepresentation,0600);Check(link(main.fileSystemRepresentation,[main stringByAppendingString:@"-alias"].fileSystemRepresentation)==0);
 Check(!RBXPrepareStagedExecutable(bundle,transactions,getuid(),getgid(),nil));Check(Mode(main)==0600);unlink([main stringByAppendingString:@"-alias"].fileSystemRepresentation);
 NSString *outside=[root stringByAppendingPathComponent:@"Installed.app"];Check([fm copyItemAtPath:bundle toPath:outside error:nil]);
 Check(!RBXPrepareStagedExecutable(outside,transactions,getuid(),getgid(),nil));Check(Mode([outside stringByAppendingPathComponent:@"Main"])==0600);
 Check([fm removeItemAtPath:main error:nil]);Check(symlink([[outside stringByAppendingPathComponent:@"Main"] fileSystemRepresentation],main.fileSystemRepresentation)==0);
 Check(!RBXPrepareStagedExecutable(bundle,transactions,getuid(),getgid(),nil));Check(Mode([outside stringByAppendingPathComponent:@"Main"])==0600);
 chmod(transactions.fileSystemRepresentation,0755);Check(!RBXPrepareStagedExecutable(bundle,transactions,getuid(),getgid(),nil));
 printf("PASS %u staged executable assertions: private export modes restored, live data and aliases refused\n",Checks);
}return 0;}
